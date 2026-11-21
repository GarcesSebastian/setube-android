package com.sebxstt.setube

import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Conversión con una sola llamada a ffmpeg, como `args.ts` de la API, en vez de los postprocesadores de yt-dlp
 * (arrancar Python, ffprobe, convertir, una pasada para los metadatos y otra para la portada). La portada se baja
 * en JPEG de i.ytimg.com y entra en la misma pasada. Además da el progreso real de la conversión.
 */
object Convert {
    private const val TAG = "SetubeConvert"

    class Canceled : Exception()

    data class Result(val ok: Boolean, val err: String, val speedX: Double)

    private fun field(name: String): Any? =
        YoutubeDL::class.java.getDeclaredField(name).apply { isAccessible = true }.get(null)

    /** El ffmpeg de youtubedl-android con su LD_LIBRARY_PATH (el mismo entorno con el que lo lanza yt-dlp). */
    private fun binary(): Pair<File, String>? = try {
        val bin = field("ffmpegPath") as? File
        val ld = field("ENV_LD_LIBRARY_PATH") as? String
        if (bin != null && ld != null && bin.isFile) bin to ld else null
    } catch (e: Throwable) {
        Log.w(TAG, "ffmpeg", e)
        null
    }

    val available get() = binary() != null

    /** Portada en JPEG (sin convertir): la de máxima resolución si existe, si no la de alta calidad. */
    fun cover(videoId: String, dir: File): File? {
        for (name in listOf("maxresdefault.jpg", "hqdefault.jpg")) {
            try {
                val c = URL("https://i.ytimg.com/vi/$videoId/$name").openConnection() as HttpURLConnection
                c.connectTimeout = 8_000
                c.readTimeout = 10_000
                if (c.responseCode != 200) {
                    c.disconnect()
                    continue
                }
                val f = File(dir, "cover.jpg")
                c.inputStream.use { i -> f.outputStream().use { i.copyTo(it) } }
                if (f.length() > 2048) return f
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun clean(s: String?) = (s ?: "").replace(Regex("[\\u0000-\\u001f\\u007f-\\u009f]"), " ").replace(Regex("\\s+"), " ").trim()

    /** Argumentos de ffmpeg para cada salida. `inputs`: el audio, o el video y el audio en MP4. */
    fun args(format: String, quality: Int?, inputs: List<File>, cover: File?, title: String?, artist: String?, transcode: Boolean, out: File): List<String> {
        val a = ArrayList<String>()
        for (i in inputs) a += listOf("-i", i.absolutePath)
        val withCover = cover != null && (format == "mp3" || format == "m4a")
        if (withCover) a += listOf("-i", cover!!.absolutePath)
        val meta = listOf("-metadata", "title=${clean(title)}") + if (artist != null) listOf("-metadata", "artist=${clean(artist)}") else emptyList()
        val coverMaps = if (withCover) {
            listOf("-map", "${inputs.size}:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic")
        } else {
            emptyList()
        }
        when (format) {
            "mp3" -> {
                a += listOf("-map", "0:a:0") + coverMaps
                // compression_level 7: LAME rápido. A 128–320 kbps la diferencia no se oye y codifica unas 2–3 veces más rápido
                a += listOf("-c:a", "libmp3lame", "-b:a", "${quality ?: 192}k", "-compression_level", "7", "-ac", "2", "-id3v2_version", "3")
                if (withCover) a += listOf("-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)")
                a += meta + listOf("-f", "mp3")
            }
            "m4a" -> {
                a += listOf("-map", "0:a:0") + coverMaps
                a += if (transcode) listOf("-c:a", "aac", "-b:a", "192k") else listOf("-c:a", "copy")
                a += meta + listOf("-movflags", "+faststart", "-f", "mp4")
            }
            "wav" -> a += listOf("-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "2", "-f", "wav")
            else -> a += listOf("-map", "0:v:0", "-map", "1:a:0", "-c", "copy") + meta.take(2) + listOf("-movflags", "+faststart", "-f", "mp4")
        }
        a += out.absolutePath
        return a
    }

    /** Ejecuta ffmpeg. `onProgress(fracción, velocidad × tiempo real)`. */
    fun run(args: List<String>, durationSec: Double, canceled: () -> Boolean, onProgress: (Double, Double) -> Unit): Result {
        val (bin, ld) = binary() ?: return Result(false, "ffmpeg no disponible", 0.0)
        val cmd = listOf(bin.absolutePath, "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1") + args
        val pb = ProcessBuilder(cmd)
        pb.environment()["LD_LIBRARY_PATH"] = ld
        val p = pb.start()
        val err = StringBuilder()
        val errThread = Thread {
            try {
                p.errorStream.bufferedReader().forEachLine { l -> if (err.length < 4000) err.append(l).append('\n') }
            } catch (_: Exception) {
            }
        }.apply { start() }
        var speed = 0.0
        try {
            p.inputStream.bufferedReader().useLines { lines ->
                for (l in lines) {
                    if (canceled()) {
                        p.destroy()
                        throw Canceled()
                    }
                    when {
                        l.startsWith("out_time_us=") -> {
                            val us = l.substringAfter('=').toLongOrNull() ?: continue
                            if (durationSec > 0) onProgress((us / 1e6 / durationSec).coerceIn(0.0, 1.0), speed)
                        }
                        l.startsWith("speed=") -> speed = l.substringAfter('=').trim().removeSuffix("x").toDoubleOrNull() ?: speed
                    }
                }
            }
        } finally {
            if (canceled()) p.destroy()
        }
        val code = p.waitFor()
        errThread.join(2000)
        if (canceled()) throw Canceled()
        return Result(code == 0, err.toString(), speed)
    }
}
