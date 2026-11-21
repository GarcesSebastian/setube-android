package com.sebxstt.setube

import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Descarga directa de los formatos de googlevideo con varias conexiones a la vez (tramos con Range), como hace
 * el reproductor pero en paralelo. yt-dlp descarga con una sola conexión desde Python, que en un teléfono es
 * bastante más lento. Los archivos quedan con los nombres que yt-dlp espera (`media.<ext>` o
 * `media.f<id>.<ext>`), así que después yt-dlp los da por descargados y solo convierte, une y etiqueta.
 */
object FastDownload {
    private const val TAG = "SetubeFast"
    private const val CONNECTIONS = 4
    private const val MIN_CHUNK = 1L shl 20
    private const val MAX_CHUNK = 8L shl 20

    class Canceled : Exception()

    private class Fmt(val id: String, var url: String, var headers: Map<String, String>, var size: Long, val ext: String) {
        lateinit var file: File
    }

    private class Chunk(val fmt: Fmt, val start: Long, val end: Long)

    private fun clen(url: String): Long = Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull() ?: -1

    private fun headersOf(f: JSONObject): Map<String, String> {
        val h = HashMap<String, String>()
        f.optJSONObject("http_headers")?.let { o -> for (k in o.keys()) if (!k.equals("cookie", true)) h[k] = o.optString(k) }
        return h
    }

    /** Formatos del selector (`251` o `137+140`) en la info. `null` si alguno no es https directo. */
    private fun read(info: File, ids: List<String>): List<Fmt>? {
        val arr = JSONObject(info.readText()).optJSONArray("formats") ?: return null
        return ids.map { id ->
            var found: JSONObject? = null
            for (i in 0 until arr.length()) {
                val f = arr.optJSONObject(i) ?: continue
                if (f.optString("format_id") == id) found = f
            }
            val f = found ?: return null
            val url = f.optString("url")
            if (f.optString("protocol") != "https" || !url.startsWith("https://") || f.optBoolean("has_drm")) return null
            val size = if (f.has("filesize") && !f.isNull("filesize")) f.optLong("filesize") else clen(url)
            Fmt(id, url, headersOf(f), size, f.optString("ext", "bin"))
        }
    }

    /** Elige formatos con la misma regla que la app (formats.dart) cuando no llegó un selector concreto. */
    fun pick(info: File, format: String, quality: Int?): String? {
        val arr = JSONObject(info.readText()).optJSONArray("formats") ?: return null
        val fs = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.filter { it.optString("protocol") == "https" && !it.optBoolean("has_drm") }
        // Las DRC (volumen normalizado) van detrás de la original con el mismo bitrate
        fun rate(f: JSONObject) = f.optDouble("abr", f.optDouble("tbr", 0.0)).let { if (it.isNaN()) 0.0 else it } -
            (if (Regex("(^|-)drc(-|$)").containsMatchIn(f.optString("format_id"))) 0.5 else 0.0)
        // Solo estéreo: las pistas 5.1 pesan el triple y hay que mezclarlas al convertir
        val audio = fs.filter {
            it.optString("vcodec") == "none" && it.optString("acodec").let { a -> a.isNotEmpty() && a != "none" } &&
                it.optInt("audio_channels", 2) <= 2
        }
        val m4a = audio.filter { it.optString("ext") == "m4a" && it.optString("acodec").startsWith("mp4a") }.maxByOrNull(::rate)
        if (format != "mp4") {
            val src = if (format == "m4a") (m4a ?: audio.maxByOrNull(::rate)) else audio.maxByOrNull(::rate)
            return src?.optString("format_id")
        }
        val target = if (quality == null || quality == 0) 1080 else quality
        val video = fs.filter {
            it.optString("vcodec").startsWith("avc1") && it.optString("acodec") == "none" && it.optString("ext") == "mp4" && it.optInt("height") in 1..1080
        }
        if (video.isEmpty() || m4a == null) return null
        val below = video.filter { it.optInt("height") <= target }
        val h = if (below.isNotEmpty()) below.maxOf { it.optInt("height") } else video.minOf { it.optInt("height") }
        val v = video.filter { it.optInt("height") == h }.maxByOrNull { it.optDouble("tbr", 0.0) } ?: return null
        return "${v.optString("format_id")}+${m4a.optString("format_id")}"
    }

    private fun open(f: Fmt, start: Long, end: Long): HttpURLConnection {
        val c = URL(f.url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 20_000
        for ((k, v) in f.headers) c.setRequestProperty(k, v)
        if (f.headers.keys.none { it.equals("User-Agent", true) }) c.setRequestProperty("User-Agent", browserUserAgent(Engine.app))
        c.setRequestProperty("Accept-Encoding", "identity")
        c.setRequestProperty("Range", "bytes=$start-$end")
        return c
    }

    private class HttpStatus(val code: Int) : IOException("HTTP $code")

    private fun probeSize(f: Fmt) {
        val c = open(f, 0, 0)
        try {
            if (c.responseCode == 403 || c.responseCode == 410) throw HttpStatus(c.responseCode)
            val cr = c.getHeaderField("Content-Range") ?: throw IOException("sin Content-Range")
            f.size = cr.substringAfter('/').toLong()
        } finally {
            c.disconnect()
        }
    }

    /**
     * Descarga `sel` en `dir`. Devuelve los bytes descargados. Lanza [Canceled] si se cancela y cualquier otra
     * excepción si no se pudo (quien llama vuelve a la descarga normal de yt-dlp).
     */
    fun run(
        info: File,
        videoId: String,
        sel: String,
        dir: File,
        canceled: () -> Boolean,
        onProgress: (done: Long, total: Long, bps: Double) -> Unit,
    ): Long {
        val ids = sel.split('+')
        val fmts = read(info, ids) ?: throw IOException("formatos no directos")
        val merged = fmts.size > 1
        for (f in fmts) {
            if (f.size <= 0) probeSize(f)
            f.file = File(dir, if (merged) "media.f${f.id}.${f.ext}" else "media.${f.ext}")
        }
        val total = fmts.sumOf { it.size }
        val chunk = (total / (CONNECTIONS * 2)).coerceIn(MIN_CHUNK, MAX_CHUNK)
        val chunks = ArrayList<Chunk>()
        for (f in fmts) {
            var s = 0L
            while (s < f.size) {
                val e = minOf(f.size - 1, s + chunk - 1)
                chunks += Chunk(f, s, e)
                s = e + 1
            }
        }
        val parts = fmts.associateWith { f -> RandomAccessFile(File(f.file.path + ".dlpart"), "rw").also { it.setLength(f.size) } }
        val next = AtomicInteger(0)
        val done = AtomicLong(0)
        val failure = AtomicReference<Throwable?>(null)
        val refreshed = AtomicInteger(0)
        val started = System.nanoTime()
        var lastEmit = 0L
        val pool = Executors.newFixedThreadPool(minOf(CONNECTIONS, chunks.size.coerceAtLeast(1)))

        // Una URL caducada (403/410) se renueva una vez con yt-dlp para todos los tramos
        val refreshLock = Any()
        fun refresh(): Boolean {
            synchronized(refreshLock) {
                if (refreshed.get() > 0) return true
                refreshed.incrementAndGet()
                if (Engine.info(listOf(videoId)).firstOrNull()?.path == null) return false
                val fresh = read(info, ids) ?: return false
                for ((old, new) in fmts.zip(fresh)) {
                    old.url = new.url
                    old.headers = new.headers
                }
                return true
            }
        }

        fun fetch(c: Chunk) {
            var attempt = 0
            while (true) {
                if (canceled() || failure.get() != null) throw Canceled()
                var got = 0L
                try {
                    val conn = open(c.fmt, c.start, c.end)
                    try {
                        val code = conn.responseCode
                        if (code == 403 || code == 410) throw HttpStatus(code)
                        if (code != 206) throw IOException("HTTP $code")
                        val ch = parts.getValue(c.fmt).channel
                        conn.inputStream.use { input ->
                            val buf = ByteArray(1 shl 16)
                            while (true) {
                                if (canceled()) throw Canceled()
                                val n = input.read(buf)
                                if (n < 0) break
                                ch.write(ByteBuffer.wrap(buf, 0, n), c.start + got)
                                got += n
                                val total2 = done.addAndGet(n.toLong())
                                val now = System.nanoTime()
                                if (now - lastEmit > 250_000_000L) {
                                    lastEmit = now
                                    onProgress(total2, total, total2 / ((now - started) / 1e9))
                                }
                            }
                        }
                    } finally {
                        conn.disconnect()
                    }
                    if (got != c.end - c.start + 1) throw IOException("tramo incompleto")
                    return
                } catch (e: Canceled) {
                    throw e
                } catch (e: Exception) {
                    done.addAndGet(-got)
                    attempt++
                    if (e is HttpStatus && (e.code == 403 || e.code == 410)) {
                        if (attempt > 2 || !refresh()) throw e
                    } else if (attempt > 3) {
                        throw e
                    } else {
                        Thread.sleep(400L * attempt)
                    }
                }
            }
        }

        try {
            repeat(minOf(CONNECTIONS, chunks.size.coerceAtLeast(1))) {
                pool.execute {
                    try {
                        while (failure.get() == null) {
                            val i = next.getAndIncrement()
                            if (i >= chunks.size) break
                            fetch(chunks[i])
                        }
                    } catch (e: Throwable) {
                        failure.compareAndSet(null, e)
                    }
                }
            }
            pool.shutdown()
            while (!pool.awaitTermination(200, TimeUnit.MILLISECONDS)) {
                if (canceled()) failure.compareAndSet(null, Canceled())
            }
        } finally {
            pool.shutdownNow()
            for (raf in parts.values) raf.close()
        }
        failure.get()?.let { e ->
            for (f in fmts) File(f.file.path + ".dlpart").delete()
            if (e is Canceled || canceled()) throw Canceled()
            Log.w(TAG, "fast download failed: ${e.message}")
            throw e
        }
        for (f in fmts) {
            if (!File(f.file.path + ".dlpart").renameTo(f.file)) throw IOException("rename")
        }
        val secs = (System.nanoTime() - started) / 1e9
        onProgress(total, total, total / secs)
        Log.i(TAG, "$videoId $sel: ${total / 1024} KB en ${"%.1f".format(secs)} s")
        return total
    }
}
