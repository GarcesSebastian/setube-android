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

/** Reproductor único de la app (ExoPlayer) con sesión multimedia para la pantalla de bloqueo. */
@OptIn(UnstableApi::class)
object PlayerHub {
    private const val TAG = "SetubePlayer"
    private val main = Handler(Looper.getMainLooper())
    private var exo: ExoPlayer? = null
    var session: SessionPlayer? = null
        private set
    private var controller: MediaController? = null
    private var connecting = false
    var sink: EventChannel.EventSink? = null
    private var textures: TextureRegistry? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var key: String? = null
    private var mode = "audio"
    private var ticking = false
    lateinit var app: Context

    fun player(ctx: Context): ExoPlayer {
        exo?.let { return it }
        app = ctx.applicationContext
        val p = ExoPlayer.Builder(app)
            .setMediaSourceFactory(DefaultMediaSourceFactory(factory()))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        p.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) = emitState()
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) tick()
            }
            override fun onPlayerError(error: PlaybackException) {
                Log.w(TAG, "player error", error)
                sink?.success(mapOf("type" to "error", "key" to key, "mode" to mode, "code" to error.errorCodeName, "message" to error.message))
            }
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                val pr = producer
                if (pr != null && videoSize.width > 0 && videoSize.height > 0 && (pr.width != videoSize.width || pr.height != videoSize.height)) {
                    pr.setSize(videoSize.width, videoSize.height)
                    exo?.setVideoSurface(pr.surface)
                }
                emitState()
            }
        })
        exo = p
        session = SessionPlayer(p)
        return p
    }

    private fun factory(): DataSource.Factory {
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(20_000)
            .setUserAgent(null)
        return DataSource.Factory { SetubeDataSource(http) }
    }

    private fun connectSession() {
        if (controller != null || connecting) return
        connecting = true
        val token = SessionToken(app, ComponentName(app, PlaybackService::class.java))
        val f = MediaController.Builder(app, token)
            .setListener(object : MediaController.Listener {
                override fun onDisconnected(c: MediaController) {
                    if (controller === c) controller = null
                }
            })
            .buildAsync()
        f.addListener({
            connecting = false
            try {
                controller = f.get()
            } catch (e: Exception) {
                Log.w(TAG, "media session", e)
            }
        }, { main.post(it) })
    }

    fun load(ctx: Context, a: Map<*, *>) {
        val p = player(ctx)
        connectSession()
        val videoId = a["videoId"] as String
        key = a["key"] as? String
        mode = a["mode"] as? String ?: "audio"
        (a["sources"] as? List<*>)?.forEach { s ->
            val m = s as? Map<*, *> ?: return@forEach
            @Suppress("UNCHECKED_CAST")
            val h = (m["headers"] as? Map<String, String>) ?: emptyMap()
            Sources.put(videoId, m["formatId"] as String, Sources.Src(m["url"] as String, h, (m["size"] as? Number)?.toLong()))
        }
        val meta = MediaMetadata.Builder()
            .setTitle(a["title"] as? String ?: "Video de YouTube")
            .setArtist(a["author"] as? String)
            .setArtworkUri((a["artwork"] as? String)?.let { Uri.parse(it) })
            .build()
        val item = MediaItem.Builder()
            .setMediaId(key ?: videoId)
            .setUri("setube://media/$videoId/${a["audioFormat"]}")
            .setMediaMetadata(meta)
            .build()
        val pos = (a["positionMs"] as? Number)?.toLong() ?: 0L
        val mpd = a["mpd"] as? String
        val source = if (mode == "video" && mpd != null) {
            val manifest = DashManifestParser().parse(Uri.parse("setube://manifest/$videoId"), ByteArrayInputStream(mpd.toByteArray()))
            DashMediaSource.Factory(factory()).createMediaSource(manifest, item)
        } else {
            mode = "audio"
            ProgressiveMediaSource.Factory(factory()).createMediaSource(item)
        }
        p.setMediaSource(source, pos)
        p.prepare()
        p.playWhenReady = a["autoplay"] != false
        emitState()
    }

    fun play() = exo?.play()
    fun pause() = exo?.pause()
    fun seek(ms: Long) = exo?.seekTo(ms)
    fun setVolume(v: Float) {
        exo?.volume = v
    }

    fun stop() {
        exo?.stop()
        exo?.clearMediaItems()
        key = null
        emitState()
    }

    fun setNeighbors(prev: Boolean, next: Boolean) = session?.setNeighbors(prev, next)

    /** El registro de texturas cambió (motor de Flutter nuevo): la textura vieja ya no vale. */
    fun setTextures(t: TextureRegistry?) {
        if (textures !== t) detachVideo()
        textures = t
    }

    fun attachVideo(ctx: Context): Long {
        val p = player(ctx)
        val reg = textures ?: throw IllegalStateException("sin registro de texturas")
        val prod = producer ?: reg.createSurfaceProducer().also { pr ->
            pr.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    exo?.setVideoSurface(pr.surface)
                }

                override fun onSurfaceCleanup() {
                    exo?.clearVideoSurface()
                }
            })
            producer = pr
        }
        val vs = p.videoSize
        if (vs.width > 0 && vs.height > 0) prod.setSize(vs.width, vs.height) else prod.setSize(1280, 720)
        p.setVideoSurface(prod.surface)
        return prod.id()
    }

    fun detachVideo() {
        exo?.clearVideoSurface()
        producer?.release()
        producer = null
    }

    fun emitState() {
        val p = exo ?: return
        val state = when (p.playbackState) {
            Player.STATE_IDLE -> "idle"
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> if (p.isPlaying) "playing" else "paused"
            Player.STATE_ENDED -> "ended"
            else -> "idle"
        }
        val vs = p.videoSize
        sink?.success(
            mapOf(
                "type" to "state", "key" to key, "mode" to mode, "state" to state, "playWhenReady" to p.playWhenReady,
                "positionMs" to p.currentPosition, "durationMs" to (if (p.duration == C.TIME_UNSET) 0L else p.duration),
                "bufferedMs" to p.bufferedPosition, "width" to vs.width, "height" to vs.height,
            ),
        )
    }

    private fun tick() {
        if (ticking) return
        ticking = true
        main.post(object : Runnable {
            override fun run() {
                val p = exo
                if (p == null || !p.isPlaying) {
                    ticking = false
                    return
                }
                emitState()
                main.postDelayed(this, 250)
            }
        })
    }

    fun command(cmd: String) = main.post { sink?.success(mapOf("type" to "cmd", "cmd" to cmd)) }

    fun release() {
        controller?.release()
        controller = null
        detachVideo()
        exo?.release()
        exo = null
        session = null
    }

    fun sessionActivity(ctx: Context): PendingIntent = PendingIntent.getActivity(
        ctx, 7, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

/** El reproductor visto desde la pantalla de bloqueo: anterior y siguiente los decide la cola de Dart. */
@OptIn(UnstableApi::class)
class SessionPlayer(p: Player) : ForwardingPlayer(p) {
    private var prev = false
    private var next = false
    private val wrappers = LinkedHashMap<Player.Listener, Player.Listener>()

    fun setNeighbors(prev: Boolean, next: Boolean) {
        if (this.prev == prev && this.next == next) return
        this.prev = prev
        this.next = next
        val cmds = availableCommands
        for (l in wrappers.keys.toList()) l.onAvailableCommandsChanged(cmds)
    }

    // Los cambios de comandos del reproductor de abajo se reenvían con anterior/siguiente añadidos
    override fun addListener(listener: Player.Listener) {
        val w = object : Player.Listener by listener {
            override fun onAvailableCommandsChanged(availableCommands: Player.Commands) =
                listener.onAvailableCommandsChanged(this@SessionPlayer.availableCommands)
        }
        wrappers[listener] = w
        super.addListener(w)
    }

    override fun removeListener(listener: Player.Listener) {
        val w = wrappers.remove(listener) ?: listener
        super.removeListener(w)
    }

    override fun getAvailableCommands(): Player.Commands {
        val b = super.getAvailableCommands().buildUpon()
        if (prev) b.addAll(Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
        if (next) b.addAll(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
        return b.build()
    }

    override fun isCommandAvailable(command: Int): Boolean = when (command) {
        Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> prev || super.isCommandAvailable(command)
        Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> next
        else -> super.isCommandAvailable(command)
    }

    override fun seekToNext() {
        if (next) PlayerHub.command("next")
    }

    override fun seekToNextMediaItem() = seekToNext()

    override fun seekToPrevious() {
        // Como los reproductores: si ya avanzó unos segundos vuelve al inicio
        if (currentPosition > 3000 || !prev) seekTo(0) else PlayerHub.command("prev")
    }

    override fun seekToPreviousMediaItem() = seekToPrevious()
}

@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        PlayerHub.player(this)
        val sp = PlayerHub.session ?: return
        session = MediaSession.Builder(this, sp).setSessionActivity(PlayerHub.sessionActivity(this)).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }
}
