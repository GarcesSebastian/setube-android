package com.sebxstt.setube

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionToken
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** URLs firmadas de googlevideo por video y formato. Se renuevan con yt-dlp si YouTube responde 403/410. */
object Sources {
    data class Src(val url: String, val headers: Map<String, String>, val size: Long?)

    private val map = ConcurrentHashMap<String, ConcurrentHashMap<String, Src>>()
    private val refreshedAt = ConcurrentHashMap<String, Long>()

    fun put(videoId: String, formatId: String, s: Src) {
        map.getOrPut(videoId) { ConcurrentHashMap() }[formatId] = s
    }

    fun get(videoId: String, formatId: String): Src? = map[videoId]?.get(formatId)

    /** Vuelve a extraer la info del video. Devuelve false si ya se renovó hace menos de 20 s o falló. */
    fun refresh(videoId: String): Boolean = synchronized(this) {
        val last = refreshedAt[videoId] ?: 0
        if (System.currentTimeMillis() - last < 20_000) return true
        refreshedAt[videoId] = System.currentTimeMillis()
        val r = Engine.info(listOf(videoId)).firstOrNull()?.path ?: return false
        return try {
            val formats = JSONObject(File(r).readText()).optJSONArray("formats") ?: return false
            for (i in 0 until formats.length()) {
                val f = formats.optJSONObject(i) ?: continue
                val id = f.optString("format_id")
                val url = f.optString("url")
                if (id.isEmpty() || !url.startsWith("https://")) continue
                val h = HashMap<String, String>()
                f.optJSONObject("http_headers")?.let { o -> for (k in o.keys()) if (!k.equals("cookie", true)) h[k] = o.optString(k) }
                val size = if (f.has("filesize") && !f.isNull("filesize")) f.optLong("filesize") else null
                put(videoId, id, Src(url, h, size))
            }
            true
        } catch (e: Exception) {
            false
        }
    }
}

/**
 * Fuente de datos para `setube://media/<videoId>/<formatId>`: pide a googlevideo tramos de 10 MiB como máximo
 * (las peticiones abiertas YouTube las sirve lentísimo), los encadena y renueva la URL ante 403/410.
 */
@OptIn(UnstableApi::class)
class SetubeDataSource(private val http: HttpDataSource.Factory) : BaseDataSource(true) {
    private var upstream: HttpDataSource? = null
    private var uri: Uri? = null
    private var videoId = ""
    private var formatId = ""
    private var position = 0L
    private var end = -1L // inclusivo; -1 = hasta el final
    private var total: Long? = null
    private var opened = false

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        val segs = dataSpec.uri.pathSegments
        if (dataSpec.uri.scheme != "setube" || segs.size < 2) throw java.io.IOException("uri no soportada")
        videoId = segs[0]
        formatId = segs[1]
        transferInitializing(dataSpec)
        if (Sources.get(videoId, formatId) == null) Sources.refresh(videoId)
        val src = Sources.get(videoId, formatId) ?: throw java.io.IOException("formato no disponible")
        total = src.size
        position = dataSpec.position
        end = if (dataSpec.length != C.LENGTH_UNSET.toLong()) position + dataSpec.length - 1 else (total?.minus(1) ?: -1L)
        if (end < 0 || position <= end) openChunk(retry = true)
        transferStarted(dataSpec)
        opened = true
        return when {
            dataSpec.length != C.LENGTH_UNSET.toLong() -> dataSpec.length
            total != null -> total!! - position
            else -> C.LENGTH_UNSET.toLong()
        }
    }

    private fun openChunk(retry: Boolean) {
        val src = Sources.get(videoId, formatId) ?: throw java.io.IOException("formato no disponible")
        val chunkEnd = if (end >= 0) minOf(end, position + CHUNK - 1) else position + CHUNK - 1
        val ds = http.createDataSource()
        ds.setRequestProperty("Accept-Encoding", "identity")
        for ((k, v) in src.headers) ds.setRequestProperty(k, v)
        // El UA del cliente de YouTube que firmó la URL; si no viene, el de Chrome móvil
        if (src.headers.keys.none { it.equals("User-Agent", true) }) ds.setRequestProperty("User-Agent", browserUserAgent(PlayerHub.app))
        val s = DataSpec.Builder().setUri(src.url).setPosition(position).setLength(chunkEnd - position + 1).build()
        try {
            ds.open(s)
            if (total == null) {
                ds.responseHeaders.entries.firstOrNull { it.key.equals("Content-Range", true) }?.value?.firstOrNull()
                    ?.substringAfter('/')?.toLongOrNull()?.let { t ->
                        total = t
                        if (end < 0) end = t - 1
                    }
            }
            upstream = ds
        } catch (e: HttpDataSource.InvalidResponseCodeException) {
            ds.close()
            if (retry && (e.responseCode == 403 || e.responseCode == 410) && Sources.refresh(videoId)) {
                openChunk(retry = false)
            } else throw e
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (end >= 0 && position > end) return C.RESULT_END_OF_INPUT
        var n = upstream?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT
        if (n == C.RESULT_END_OF_INPUT) {
            upstream?.close()
            upstream = null
            if (end >= 0 && position > end) return C.RESULT_END_OF_INPUT
            if (end < 0 && total == null) return C.RESULT_END_OF_INPUT
            openChunk(retry = true)
            n = upstream?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT
            if (n == C.RESULT_END_OF_INPUT) return n
        }
        position += n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        try {
            upstream?.close()
        } finally {
            upstream = null
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }

    companion object {
        const val CHUNK = 10L * 1024 * 1024
    }
}
