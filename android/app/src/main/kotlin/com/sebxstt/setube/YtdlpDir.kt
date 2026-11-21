package com.sebxstt.setube

import android.content.Context
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * yt-dlp descomprimido en una carpeta en vez del zip que usa youtubedl-android.
 *
 * Python no puede guardar el bytecode (.pyc) de los módulos que importa desde un zip, así que con el zip
 * vuelve a compilar yt-dlp en cada llamada (unos segundos en un teléfono). Desde una carpeta compila una vez
 * y las siguientes llamadas arrancan varias veces más rápido. La librería ejecuta `python <ruta>`, y Python
 * acepta una carpeta con `__main__.py`, así que basta con apuntar su ruta interna (`ytdlpPath`) a la carpeta.
 * Por lo mismo, las actualizaciones las hace esta clase: descarga el zip de la release y lo descomprime.
 */
object YtdlpDir {
    private const val TAG = "SetubeYtdlp"

    private fun root(ctx: Context) = File(ctx.noBackupFilesDir, "ytdlp-run").apply { mkdirs() }
    private fun pointer(ctx: Context) = File(root(ctx), "current")
    private fun libraryZip(ctx: Context) = File(ctx.noBackupFilesDir, "youtubedl-android/yt-dlp/yt-dlp")

    fun current(ctx: Context): File? {
        val name = pointer(ctx).takeIf { it.isFile }?.readText()?.trim() ?: return null
        val d = File(root(ctx), name)
        return if (File(d, "__main__.py").isFile && File(d, "yt_dlp/version.py").isFile) d else null
    }

    fun version(dir: File?): String {
        val f = dir?.let { File(it, "yt_dlp/version.py") } ?: return ""
        return Regex("__version__\\s*=\\s*'([^']+)'").find(f.readText())?.groupValues?.get(1) ?: ""
    }

    /** Después de YoutubeDL.init: usa la carpeta (la crea desde el zip de la librería si hace falta). */
    fun activate(ctx: Context) {
        try {
            var d = current(ctx)
            if (d == null) {
                val zip = libraryZip(ctx)
                if (!zip.isFile) return
                d = FileInputStream(zip).use { install(ctx, it) }
            }
            point(d)
        } catch (e: Throwable) {
            // Si algo falla, la librería sigue con su zip
            Log.w(TAG, "activate", e)
        }
    }

    private fun point(dir: File) {
        val f = YoutubeDL::class.java.getDeclaredField("ytdlpPath")
        f.isAccessible = true
        f.set(null, dir)
    }

    /** Descomprime el zip de yt-dlp (lleva una línea `#!` delante) en una carpeta nueva y la marca como actual. */
    private fun install(ctx: Context, input: InputStream): File {
        val r = root(ctx)
        val tmp = File(r, "tmp-" + System.currentTimeMillis()).apply { mkdirs() }
        try {
            val bin = BufferedInputStream(input, 1 shl 16)
            // Saltar hasta la primera cabecera local «PK\3\4»
            bin.mark(4096)
            val head = ByteArray(4096)
            val n = bin.read(head)
            var start = -1
            for (i in 0 until n - 3) {
                if (head[i] == 'P'.code.toByte() && head[i + 1] == 'K'.code.toByte() && head[i + 2] == 3.toByte() && head[i + 3] == 4.toByte()) {
                    start = i
                    break
                }
            }
            if (start < 0) throw IllegalStateException("no es un zip")
            bin.reset()
            bin.skip(start.toLong())
            val canonical = tmp.canonicalPath + File.separator
            ZipInputStream(bin).use { z ->
                while (true) {
                    val e = z.nextEntry ?: break
                    val out = File(tmp, e.name)
                    if (!out.canonicalPath.startsWith(canonical)) throw SecurityException("ruta fuera del destino")
                    if (e.isDirectory) out.mkdirs()
                    else {
                        out.parentFile?.mkdirs()
                        out.outputStream().use { z.copyTo(it) }
                    }
                }
            }
            if (!File(tmp, "__main__.py").isFile) throw IllegalStateException("zip sin __main__.py")
            val v = version(tmp).ifEmpty { "x" }
            val dst = File(r, "v-$v-${System.currentTimeMillis()}")
            if (!tmp.renameTo(dst)) throw IllegalStateException("rename")
            pointer(ctx).writeText(dst.name)
            // Solo queda la carpeta actual
            r.listFiles()?.forEach { if (it.isDirectory && it.name != dst.name) it.deleteRecursively() }
            return dst
        } catch (e: Throwable) {
            tmp.deleteRecursively()
            throw e
        }
    }

    private fun get(url: String): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        c.setRequestProperty("User-Agent", "Setube-Android")
        c.setRequestProperty("Accept", "application/vnd.github+json")
        return c
    }

    /** `UP_TO_DATE` o `DONE`. Lo llama Engine con el cerrojo de escritura tomado. */
    fun update(ctx: Context, channel: String): String {
        val repo = if (channel == "nightly") "yt-dlp/yt-dlp-nightly-builds" else "yt-dlp/yt-dlp"
        val rel = get("https://api.github.com/repos/$repo/releases/latest").let { c ->
            if (c.responseCode != 200) throw IllegalStateException("GitHub ${c.responseCode}")
            JSONObject(c.inputStream.bufferedReader().use { it.readText() })
        }
        val tag = rel.optString("tag_name")
        if (tag.isNotEmpty() && tag == version(current(ctx))) return "UP_TO_DATE"
        val assets = rel.optJSONArray("assets") ?: throw IllegalStateException("sin assets")
        var url: String? = null
        for (i in 0 until assets.length()) {
            val a = assets.optJSONObject(i) ?: continue
            if (a.optString("name") == "yt-dlp") url = a.optString("browser_download_url")
        }
        val c = get(url ?: throw IllegalStateException("sin binario yt-dlp"))
        c.instanceFollowRedirects = true
        if (c.responseCode != 200) throw IllegalStateException("descarga ${c.responseCode}")
        val d = c.inputStream.use { install(ctx, it) }
        point(d)
        return "DONE"
    }
}
