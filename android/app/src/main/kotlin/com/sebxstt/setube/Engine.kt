package com.sebxstt.setube

import android.content.Context
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * yt-dlp dentro de la app (youtubedl-android: Python 3.12, yt-dlp, QuickJS y ffmpeg empaquetados).
 * La librería añade sola `--js-runtimes quickjs:<ruta>` y `--ffmpeg-location`.
 */
object Engine {
    private const val TAG = "SetubeEngine"
    private val lock = Any()

    // Actualizar yt-dlp reemplaza el archivo que leen los procesos en curso: espera a que terminen
    private val binLock = ReentrantReadWriteLock()

    /** Clientes de YouTube como en la API: los de por defecto más mweb con PO token (lo genera el WebView). */
    // skip=hls,dash: no pide los manifiestos HLS/DASH de cada cliente (una o dos peticiones más por video); la app
    // solo usa los formatos https directos
    const val PLAYER_CLIENTS = "youtube:player_client=default,mweb;skip=hls,dash"

    @Volatile
    private var ready = false
    lateinit var app: Context
        private set

    data class Result(val exit: Int, val out: String, val err: String, val canceled: Boolean = false) {
        val ok get() = exit == 0 && !canceled
    }

    private val BOT_CHECK = Regex(
        "Sign in to confirm you.?re not a bot|confirm you are not a robot|LOGIN_REQUIRED|confirm your age|age-restricted|inappropriate for some users",
        RegexOption.IGNORE_CASE,
    )

    fun isBotCheck(err: String) = BOT_CHECK.containsMatchIn(err)

    fun attach(ctx: Context) {
        app = ctx.applicationContext
    }

    /** Descomprime Python y ffmpeg la primera vez (unos segundos); después es inmediato. */
    fun ensure(ctx: Context) {
        if (ready) return
        synchronized(lock) {
            if (ready) return
            app = ctx.applicationContext
            YoutubeDL.getInstance().init(app)
            FFmpeg.getInstance().init(app)
            YtdlpDir.activate(app)
            pruneSolverCache()
            ready = true
        }
    }

    private val cacheDir get() = File(app.filesDir, "ytdlp-cache").apply { mkdirs() }

    /** Reproductores preprocesados (~4 MB cada uno): solo se conservan los dos más recientes. */
    private fun pruneSolverCache() {
        try {
            val files = File(cacheDir, "challenge-solver").listFiles()?.filter { it.isFile }?.sortedByDescending { it.lastModified() } ?: return
            files.drop(2).forEach { it.delete() }
        } catch (_: Exception) {
        }
    }
    val infoDir get() = File(app.cacheDir, "info").apply { mkdirs() }

    /** Ejecuta yt-dlp con `args` (después de las opciones fijas). `options` van al mapa de opciones de la librería. */
    fun run(
        args: List<String>,
        id: String? = null,
        cookies: File? = null,
        options: List<String> = emptyList(),
        onLine: ((String) -> Unit)? = null,
    ): Result {
        ensure(app)
        val req = YoutubeDLRequest(emptyList<String>())
        req.addOption("--cache-dir", cacheDir.absolutePath)
        // La librería solo mira su mapa de opciones para decidir si una salida con errores sigue valiendo
        for (o in options) req.addOption(o)
        val cmd = ArrayList<String>()
        cmd += listOf("--ignore-config", "--socket-timeout", "15")
        val plugins = Helper.pluginDir
        if (File(plugins, "setube/helper.json").isFile) {
            cmd += listOf("--plugin-dirs", plugins.absolutePath, "--extractor-args", PLAYER_CLIENTS)
        }
        if (cookies != null) cmd += listOf("--cookies", cookies.absolutePath)
        cmd += args
        req.addCommands(cmd)
        return try {
            val r = binLock.read { YoutubeDL.getInstance().execute(req, id, false) { _, _, line -> onLine?.invoke(line) } }
            Result(r.exitCode, r.out, r.err)
        } catch (e: YoutubeDL.CanceledException) {
            Result(-1, "", "canceled", canceled = true)
        } catch (e: YoutubeDLException) {
            Result(1, "", e.message ?: "")
        } catch (e: InterruptedException) {
            Result(-1, "", "interrupted", canceled = true)
        } catch (e: Exception) {
            Log.w(TAG, "run failed", e)
            Result(1, "", e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * Ejecuta con la política de sesión: `off` nunca usa cookies, `always` siempre, `auto` (por defecto) primero
     * sin cookies y, si YouTube pide confirmar que no eres un bot, otra vez con la sesión.
     */
    fun runWithSession(
        args: List<String>,
        id: String? = null,
        options: List<String> = emptyList(),
        canceled: () -> Boolean = { false },
        onLine: ((String) -> Unit)? = null,
    ): Result {
        val mode = CookieStore.mode(app)
        if (mode == "always") {
            val ck = CookieStore.materialize(app)
            try {
                return run(args, id, ck, options, onLine)
            } finally {
                ck?.delete()
            }
        }
        val first = run(args, id, null, options, onLine)
        if (first.ok || first.canceled || mode == "off" || canceled() || !isBotCheck(first.err)) return first
        val ck = CookieStore.materialize(app) ?: return first
        try {
            return run(args, id?.let { "$it-s" }, ck, options, onLine)
        } finally {
            ck.delete()
        }
    }

    fun cancel(id: String) {
        try {
            YoutubeDL.getInstance().destroyProcessById(id)
            YoutubeDL.getInstance().destroyProcessById("$id-s")
        } catch (_: Exception) {
        }
    }

    // Info de videos

    private val HEAVY_TOP = setOf(
        "automatic_captions", "subtitles", "thumbnails", "heatmap", "tags", "chapters", "comments",
        "_format_sort_fields", "webpage_url", "original_url", "cookies",
    )
    private val ERR_LINE = Regex("""ERROR: \[[^\]]+] ([A-Za-z0-9_-]{11}): (.*)""")

    data class Info(val id: String, val path: String?, val code: String?, val message: String?)

    /**
     * Info de varios videos en un proceso. yt-dlp imprime la de cada video en cuanto la tiene: se guarda (sin campos
     * pesados ni cookies) en cache/info/<id>.json y se avisa con `onEach` sin esperar al resto del lote, así las
     * descargas empiezan mientras se preparan los demás. Con la sesión en «auto», solo se repiten con cookies los
     * videos que YouTube bloqueó.
     */
    fun info(ids: List<String>, procId: String = "info-" + UUID.randomUUID(), onEach: ((Info) -> Unit)? = null): List<Info> {
        val got = LinkedHashMap<String, String>()
        val lock = Any()
        fun handle(line: String) {
            val t = line.trim()
            if (!t.startsWith("{")) return
            try {
                val j = JSONObject(t)
                val id = j.optString("id")
                if (id.isEmpty()) return
                synchronized(lock) { if (got.containsKey(id)) return }
                val f = File(infoDir, "$id.json")
                // Atómico: Dart o un yt-dlp con --load-info-json pueden estar leyéndolo
                val tmp = File(infoDir, "$id.json." + UUID.randomUUID().toString().take(6))
                tmp.writeText(sanitize(j).toString())
                if (!tmp.renameTo(f)) {
                    f.writeText(tmp.readText())
                    tmp.delete()
                }
                synchronized(lock) { got[id] = f.absolutePath }
                onEach?.invoke(Info(id, f.absolutePath, null, null))
            } catch (e: Exception) {
                Log.w(TAG, "info json", e)
            }
        }
        fun pass(list: List<String>, cookies: File?, pid: String): Result {
            val args = listOf("--no-playlist", "--skip-download", "--no-warnings", "--") + list.map { "https://www.youtube.com/watch?v=$it" }
            val r = run(args, pid, cookies, listOf("--dump-json", "--ignore-errors")) { handle(it) }
            // Por si alguna línea no llegó por el aviso de progreso
            for (line in r.out.lineSequence()) handle(line)
            return r
        }

        val mode = CookieStore.mode(app)
        val errs = StringBuilder()
        var canceled = false
        if (mode == "always") {
            val ck = CookieStore.materialize(app)
            try {
                pass(ids, ck, procId).also { errs.append(it.err); canceled = it.canceled }
            } finally {
                ck?.delete()
            }
        } else {
            val r = pass(ids, null, procId)
            errs.append(r.err)
            canceled = r.canceled
            val missing = synchronized(lock) { ids.filter { it !in got } }
            if (missing.isNotEmpty() && mode != "off" && !r.canceled && isBotCheck(r.err)) {
                val ck = CookieStore.materialize(app)
                if (ck != null) {
                    try {
                        val r2 = pass(missing, ck, "$procId-s")
                        errs.append('\n').append(r2.err)
                        canceled = r2.canceled
                    } finally {
                        ck.delete()
                    }
                }
            }
        }
        val errText = errs.toString()
        val perVideo = HashMap<String, String>()
        for (line in errText.lineSequence()) {
            val m = ERR_LINE.find(line) ?: continue
            perVideo[m.groupValues[1]] = m.groupValues[2]
        }
        return ids.map { id ->
            val p = synchronized(lock) { got[id] }
            if (p != null) Info(id, p, null, null)
            else {
                val msg = perVideo[id] ?: errText.lineSequence().lastOrNull { it.contains("ERROR") } ?: errText.takeLast(300)
                Info(id, null, Errors.classify(msg, canceled), msg.take(400))
            }
        }
    }

    fun sanitize(info: JSONObject): JSONObject {
        val out = JSONObject()
        for (k in info.keys()) {
            if (k in HEAVY_TOP || k.startsWith("requested_")) continue
            when (k) {
                "description" -> out.put(k, info.optString(k).take(400))
                "http_headers" -> out.put(k, stripCookie(info.optJSONObject(k)))
                "formats" -> {
                    val arr = info.optJSONArray(k) ?: JSONArray()
                    val fs = JSONArray()
                    for (i in 0 until arr.length()) {
                        val f = arr.optJSONObject(i) ?: continue
                        if (f.optString("format_note") == "storyboard" || f.optString("ext") == "mhtml") continue
                        f.remove("cookies")
                        f.optJSONObject("http_headers")?.let { f.put("http_headers", stripCookie(it)) }
                        fs.put(f)
                    }
                    out.put(k, fs)
                }
                else -> out.put(k, info.get(k))
            }
        }
        return out
    }

    private fun stripCookie(h: JSONObject?): JSONObject {
        val o = JSONObject()
        if (h == null) return o
        for (k in h.keys()) if (!k.equals("cookie", true)) o.put(k, h.get(k))
        return o
    }

    fun version(): String = try {
        YtdlpDir.version(YtdlpDir.current(app)).ifEmpty { YoutubeDL.getInstance().version(app) ?: "" }
    } catch (_: Exception) {
        ""
    }

    fun update(channel: String): Map<String, Any?> {
        ensure(app)
        val st = binLock.write { YtdlpDir.update(app, channel) }
        return mapOf("status" to (if (st == "UP_TO_DATE") "ALREADY_UP_TO_DATE" else st), "version" to version())
    }

    /**
     * Informe para depurar desde el teléfono: salida verbosa de yt-dlp con un video de prueba (sin y con sesión),
     * qué proveedores de PO token y de retos JS se usaron, formatos y la velocidad real de googlevideo.
     */
    fun diagnose(videoId: String): String {
        ensure(app)
        val b = StringBuilder()
        b.append("yt-dlp ").append(version()).append(" · Android ").append(android.os.Build.VERSION.RELEASE)
            .append(" · ").append(android.os.Build.MODEL).append('\n')
        b.append("Sesión: ").append(CookieStore.status(app).let { "${it.loggedIn} (${it.source}, ${it.count})" })
            .append(" · modo ").append(CookieStore.mode(app)).append('\n')
        b.append("Helper: ").append(if (File(Helper.pluginDir, "setube/helper.json").isFile) "activo" else "no").append('\n')
        val t0 = System.currentTimeMillis()
        val pot = try {
            PotMinter.mint(videoId)
        } catch (e: Throwable) {
            null
        }
        b.append("PO token del WebView: ").append(if (pot != null) "ok (${pot.length} car., ${System.currentTimeMillis() - t0} ms)" else "falló").append('\n')
        b.append("yt-dlp desde carpeta: ").append(if (YtdlpDir.current(app) != null) "sí" else "no (zip)").append('\n')
        for (i in 1..2) {
            val s0 = System.currentTimeMillis()
            run(listOf("--version"), "diag-v-" + UUID.randomUUID())
            b.append("Arranque de yt-dlp ").append(i).append(": ").append(System.currentTimeMillis() - s0).append(" ms\n")
        }
        val js0 = System.currentTimeMillis()
        val js = try {
            JsRunner.run("console.log(JSON.stringify({ok: 1 + 1}))")
        } catch (e: Throwable) {
            null
        }
        b.append("WebView JS: ").append(js ?: "falló").append(" (").append(System.currentTimeMillis() - js0).append(" ms)\n")
        b.append("\nPrueba de descarga MP3 192 (sin guardar): ").append(
            try {
                Downloads.benchmark(app, videoId, "mp3", 192)
            } catch (e: Throwable) {
                "error ${e.message}"
            },
        ).append('\n')
        for (withCookies in listOf(false, true)) {
            val ck = if (withCookies) CookieStore.materialize(app) ?: continue else null
            val start = System.currentTimeMillis()
            val r = try {
                run(listOf("-v", "--no-playlist", "-J", "--skip-download", "--", "https://www.youtube.com/watch?v=$videoId"), "diag-" + UUID.randomUUID(), ck)
            } finally {
                ck?.delete()
            }
            b.append("\n== ").append(if (withCookies) "con sesión" else "sin sesión").append(": exit ").append(r.exit)
                .append(" en ").append(System.currentTimeMillis() - start).append(" ms\n")
            for (line in r.err.lineSequence()) {
                if (Regex("(?i)(jsc|pot\\]|po token|challenge|providers|error|warning|sabr|forbidden|skipp|player_client|clients|Solving|n =|missing)").containsMatchIn(line)) {
                    b.append(line.take(400)).append('\n')
                }
            }
            val j = r.out.lineSequence().firstOrNull { it.trim().startsWith("{") } ?: continue
            try {
                val formats = JSONObject(j).optJSONArray("formats") ?: JSONArray()
                var aac: JSONObject? = null
                val ids = ArrayList<String>()
                for (i in 0 until formats.length()) {
                    val f = formats.optJSONObject(i) ?: continue
                    ids += "${f.optString("format_id")}:${f.optString("protocol")}"
                    if (f.optString("format_id").startsWith("140") && f.optString("protocol") == "https") aac = f
                }
                b.append("Formatos (").append(ids.size).append("): ").append(ids.joinToString(" ")).append('\n')
                aac?.let { f -> b.append("Velocidad googlevideo (itag 140, 4 MB): ").append(speedTest(f)).append('\n') }
            } catch (e: Exception) {
                b.append("JSON inválido: ").append(e.message).append('\n')
            }
        }
        return b.toString()
    }

    private fun speedTest(f: JSONObject): String = try {
        val c = java.net.URL(f.getString("url")).openConnection() as java.net.HttpURLConnection
        f.optJSONObject("http_headers")?.let { h -> for (k in h.keys()) if (!k.equals("cookie", true)) c.setRequestProperty(k, h.optString(k)) }
        c.setRequestProperty("Range", "bytes=0-4194303")
        c.connectTimeout = 10_000
        c.readTimeout = 20_000
        val start = System.nanoTime()
        var total = 0L
        val code = c.responseCode
        if (code !in 200..299) "HTTP $code"
        else {
            c.inputStream.use { i ->
                val buf = ByteArray(65536)
                while (true) {
                    val n = i.read(buf)
                    if (n < 0) break
                    total += n
                    if (System.nanoTime() - start > 15_000_000_000L) break
                }
            }
            val s = (System.nanoTime() - start) / 1e9
            "%.2f MB/s (%d KB en %.1f s)".format(total / s / 1e6, total / 1024, s)
        }
    } catch (e: Exception) {
        "error ${e.javaClass.simpleName}: ${e.message}"
    }
}

object Errors {
    private val RULES = listOf(
        Regex("Sign in to confirm you.?re not a bot|confirm you are not a robot|LOGIN_REQUIRED", RegexOption.IGNORE_CASE) to "upstreamBlocked",
        Regex("Private video", RegexOption.IGNORE_CASE) to "privateVideo",
        Regex("confirm your age|age-restricted|inappropriate for some users", RegexOption.IGNORE_CASE) to "ageRestricted",
        Regex("live event will begin|is live|Premieres in|This live stream recording is not available", RegexOption.IGNORE_CASE) to "liveNotSupported",
        Regex("Video unavailable|has been removed|account .* terminated|not (made this video )?available in your country", RegexOption.IGNORE_CASE) to "videoUnavailable",
        Regex("Requested format is not available", RegexOption.IGNORE_CASE) to "formatUnavailable",
        Regex("HTTP Error 403|HTTP Error 410|The info failed to download", RegexOption.IGNORE_CASE) to "upstreamForbidden",
        Regex("No space left|Permission denied", RegexOption.IGNORE_CASE) to "storage",
        Regex("timed out|Connection reset|HTTP Error 5\\d\\d|Unable to download|Network is unreachable|Failed to resolve", RegexOption.IGNORE_CASE) to "upstreamError",
    )

    fun classify(err: String, canceled: Boolean = false): String {
        if (canceled) return "canceled"
        for ((re, code) in RULES) if (re.containsMatchIn(err)) return code
        return "upstreamError"
    }

    val DEFINITIVE = setOf("privateVideo", "ageRestricted", "liveNotSupported", "videoUnavailable")
}
