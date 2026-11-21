package com.sebxstt.setube

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Servidor HTTP en 127.0.0.1 que usa el plugin de yt-dlp (assets/ytdlp-plugins) para dos cosas que en la API
 * hacían Node y bgutil: PO tokens de BotGuard y los retos JS de YouTube. Las dos corren en WebViews (V8).
 */
object Helper {
    private const val TAG = "SetubeHelper"
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    private var server: ServerSocket? = null
    private lateinit var secret: String
    lateinit var app: Context
        private set

    val pluginDir get() = File(app.filesDir, "ytdlp-plugins")

    /** Copia el plugin, arranca el servidor y escribe helper.json con su URL. Idempotente. */
    @Synchronized
    fun start(ctx: Context) {
        app = ctx.applicationContext
        if (server != null) return
        try {
            installPlugin()
            val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
            secret = bytes.joinToString("") { "%02x".format(it) }
            // IPv4 explícito: en Android getLoopbackAddress() es ::1 y el plugin se conecta a 127.0.0.1
            val s = ServerSocket(0, 50, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            server = s
            File(pluginDir, "setube/helper.json").writeText(JSONObject().put("url", "http://127.0.0.1:${s.localPort}/$secret").toString())
            Thread({ acceptLoop(s) }, "setube-helper").apply { isDaemon = true }.start()
        } catch (e: Throwable) {
            Log.e(TAG, "helper start", e)
        }
    }

    val base: String get() = "http://127.0.0.1:${server?.localPort ?: 0}/$secret"

    private fun installPlugin() {
        val dst = File(pluginDir, "setube/yt_dlp_plugins/extractor").apply { mkdirs() }
        for (name in app.assets.list("ytdlp-plugins/setube/yt_dlp_plugins/extractor") ?: emptyArray()) {
            app.assets.open("ytdlp-plugins/setube/yt_dlp_plugins/extractor/$name").use { input ->
                File(dst, name).outputStream().use { input.copyTo(it) }
            }
        }
        // Una caché de bytecode de una versión anterior del plugin no debe quedarse
        File(dst, "__pycache__").deleteRecursively()
    }

    private fun acceptLoop(s: ServerSocket) {
        while (!s.isClosed) {
            val c = try {
                s.accept()
            } catch (_: Exception) {
                break
            }
            pool.execute { handle(c) }
        }
    }

    private class Req(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

    private fun readLine(i: InputStream): String? {
        val b = ByteArrayOutputStream()
        while (true) {
            val c = i.read()
            if (c < 0) return if (b.size() == 0) null else b.toString("UTF-8")
            if (c == '\n'.code) return b.toString("UTF-8").trimEnd('\r')
            b.write(c)
        }
    }

    private fun read(sock: Socket): Req? {
        val i = BufferedInputStream(sock.getInputStream())
        val line = readLine(i) ?: return null
        val parts = line.split(' ')
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        while (true) {
            val h = readLine(i) ?: break
            if (h.isEmpty()) break
            val k = h.substringBefore(':').trim().lowercase()
            headers[k] = h.substringAfter(':').trim()
        }
        val len = headers["content-length"]?.toIntOrNull() ?: 0
        val body = ByteArray(len)
        var off = 0
        while (off < len) {
            val n = i.read(body, off, len - off)
            if (n < 0) break
            off += n
        }
        return Req(parts[0], parts[1], headers, body)
    }

    private fun respond(sock: Socket, code: Int, type: String, body: ByteArray) {
        val o = sock.getOutputStream()
        o.write("HTTP/1.1 $code OK\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
        o.write(body)
        o.flush()
    }

    private fun json(sock: Socket, j: JSONObject) = respond(sock, 200, "application/json", j.toString().toByteArray())

    private fun handle(sock: Socket) {
        sock.use {
            try {
                sock.soTimeout = 120_000
                val r = read(sock) ?: return
                val prefix = "/$secret/"
                if (!r.path.startsWith(prefix)) {
                    respond(sock, 404, "text/plain", ByteArray(0))
                    return
                }
                val route = r.path.removePrefix(prefix)
                when {
                    r.method == "POST" && route == "pot" -> {
                        val binding = JSONObject(String(r.body)).optString("binding")
                        val tok = try {
                            PotMinter.mint(binding)
                        } catch (e: Throwable) {
                            Log.w(TAG, "pot", e)
                            null
                        }
                        json(sock, if (tok != null) JSONObject().put("poToken", tok) else JSONObject().put("error", "botguard_failed"))
                    }
                    r.method == "POST" && route == "js" -> {
                        val script = JSONObject(String(r.body)).optString("script")
                        val out = try {
                            JsRunner.run(script)
                        } catch (e: Throwable) {
                            Log.w(TAG, "js", e)
                            null
                        }
                        json(sock, if (out != null) JSONObject().put("stdout", out) else JSONObject().put("error", "webview_js_failed"))
                    }
                    else -> respond(sock, 404, "text/plain", ByteArray(0))
                }
            } catch (e: Throwable) {
                Log.w(TAG, "handle", e)
            }
        }
    }
}

/**
 * Retos JS de YouTube (scripts EJS de yt-dlp) en un WebView: V8 con JIT, mucho más rápido que QuickJS.
 * El script entra y el resultado sale por una interfaz JavaScript (sin red); cada reto corre dentro de una función
 * con su propio console.log, así empieza limpio.
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
object JsRunner {
    private const val TAG = "SetubeJs"
    private const val JS = "SetubeJs"
    private val main = Handler(Looper.getMainLooper())
    private var web: WebView? = null
    private val jobs = ConcurrentHashMap<String, Job>()

    private class Job(val source: String) {
        val done = CountDownLatch(1)
        @Volatile var out: String? = null
        @Volatile var error: String? = null
    }

    private class Bridge {
        @JavascriptInterface
        fun source(id: String): String = jobs[id]?.source ?: ""

        @JavascriptInterface
        fun done(id: String, out: String, error: Boolean) {
            val j = jobs[id] ?: return
            if (error) j.error = out else j.out = out
            j.done.countDown()
        }
    }

    private fun snippet(id: String) = """(function () {
        if (typeof $JS === 'undefined') return 'nobridge';
        var id = '$id';
        try {
            var src = $JS.source(id);
            var out = [];
            var c = { log: function () { out.push(Array.prototype.join.call(arguments, ' ')) }, error: function () {}, warn: function () {}, info: function () {}, debug: function () {} };
            new Function('console', src)(c);
            $JS.done(id, out.join('\n'), false);
        } catch (e) {
            $JS.done(id, String(e && e.stack || e), true);
        }
        return 'ok';
    })()"""

    /** Crea el WebView (una vez). Hay que llamarlo en el hilo principal. */
    private fun webView(): WebView {
        web?.let { return it }
        val w = WebView(Helper.app)
        w.settings.javaScriptEnabled = true
        w.settings.blockNetworkLoads = true
        if (WebViewFeature.isFeatureSupported(WebViewFeature.SAFE_BROWSING_ENABLE)) WebSettingsCompat.setSafeBrowsingEnabled(w.settings, false)
        w.addJavascriptInterface(Bridge(), JS)
        w.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(m: ConsoleMessage): Boolean = true
        }
        w.loadDataWithBaseURL("https://www.youtube.com", "<!DOCTYPE html><html><head></head><body></body></html>", "text/html", "utf-8", null)
        web = w
        return w
    }

    fun run(script: String): String? {
        val id = java.util.UUID.randomUUID().toString()
        val job = Job(script)
        jobs[id] = job
        try {
            // El WebView recién creado tarda un momento en tener la página y la interfaz: se reintenta
            val deadline = System.currentTimeMillis() + 15_000
            var started = false
            while (!started && System.currentTimeMillis() < deadline) {
                val ack = CountDownLatch(1)
                var reply: String? = null
                main.post {
                    try {
                        webView().evaluateJavascript(snippet(id)) { v ->
                            reply = v
                            ack.countDown()
                        }
                    } catch (e: Throwable) {
                        Log.e(TAG, "webview", e)
                        ack.countDown()
                    }
                }
                if (!ack.await(45, TimeUnit.SECONDS)) break
                started = reply?.contains("ok") == true
                if (!started) Thread.sleep(150)
            }
            if (!started || !job.done.await(30, TimeUnit.SECONDS)) {
                Log.w(TAG, "js timeout")
                main.post {
                    web?.destroy()
                    web = null
                }
                return null
            }
            if (job.error != null) {
                Log.w(TAG, "js error: ${job.error?.take(500)}")
                return null
            }
            return job.out
        } finally {
            jobs.remove(id)
        }
    }
}

/**
 * PO tokens de BotGuard con un WebView, como NewPipe (PoTokenWebView): se pide el reto a
 * youtube.com/api/jnn/v1/Create, se ejecuta BotGuard, se canjea en GenerateIT por un integrity token y con él
 * se generan los tokens para cada identificador (video ID, visitor data o data sync ID).
 */
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
object PotMinter {
    private const val TAG = "SetubePot"
    private const val API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private const val REQUEST_KEY = "O43z0dpjhgX20SCx4KAo"
    private const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private const val JS = "SetubePot"
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val lock = Any()

    private var web: WebView? = null
    private var expiresAt = 0L
    private var initLatch: CountDownLatch? = null
    @Volatile private var initError: String? = null
    private val pending = ConcurrentHashMap<String, Pair<CountDownLatch, Array<String?>>>()
    private val cache = ConcurrentHashMap<String, Pair<String, Long>>()

    fun mint(identifier: String): String? {
        if (identifier.isEmpty()) return null
        cache[identifier]?.let { (t, exp) -> if (System.currentTimeMillis() < exp) return t }
        for (attempt in 0..1) {
            if (!ensureReady(force = attempt > 0)) continue
            val t = obtain(identifier)
            if (t != null) {
                cache[identifier] = t to minOf(expiresAt, System.currentTimeMillis() + 6 * 3600_000L)
                return t
            }
        }
        return null
    }

    private fun ensureReady(force: Boolean): Boolean {
        val latch: CountDownLatch
        synchronized(lock) {
            val ok = web != null && System.currentTimeMillis() < expiresAt && initLatch?.count == 0L && initError == null
            if (ok && !force) return true
            if (initLatch == null || initLatch!!.count == 0L || force) {
                initLatch = CountDownLatch(1)
                initError = null
                val l = initLatch!!
                main.post { create(l) }
            }
            latch = initLatch!!
        }
        if (!latch.await(30, TimeUnit.SECONDS)) {
            initError = "timeout"
            return false
        }
        return initError == null
    }

    private fun fail(l: CountDownLatch, msg: String) {
        Log.w(TAG, "botguard: $msg")
        initError = msg
        l.countDown()
    }

    private fun create(l: CountDownLatch) {
        try {
            web?.destroy()
            val w = WebView(Helper.app)
            web = w
            w.settings.javaScriptEnabled = true
            w.settings.userAgentString = UA
            w.settings.blockNetworkLoads = true
            if (WebViewFeature.isFeatureSupported(WebViewFeature.SAFE_BROWSING_ENABLE)) WebSettingsCompat.setSafeBrowsingEnabled(w.settings, false)
            w.addJavascriptInterface(Bridge(l), JS)
            w.webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                    if (m.message().contains("Uncaught")) fail(l, "uncaught: ${m.message()}")
                    return true
                }
            }
            val html = Helper.app.assets.open("po_token.html").bufferedReader().use { it.readText() }
            w.loadDataWithBaseURL(
                "https://www.youtube.com",
                html.replaceFirst("</script>", "\n$JS.downloadAndRunBotguard()</script>"),
                "text/html", "utf-8", null,
            )
        } catch (e: Throwable) {
            fail(l, "webview: ${e.message}")
        }
    }

    private fun post(url: String, body: String): String {
        val c = URL(url).openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.connectTimeout = 10_000
        c.readTimeout = 15_000
        c.doOutput = true
        c.setRequestProperty("User-Agent", UA)
        c.setRequestProperty("Accept", "application/json")
        c.setRequestProperty("Content-Type", "application/json+protobuf")
        c.setRequestProperty("x-goog-api-key", API_KEY)
        c.setRequestProperty("x-user-agent", "grpc-web-javascript/0.1")
        c.outputStream.use { it.write(body.toByteArray()) }
        if (c.responseCode != 200) throw IllegalStateException("HTTP ${c.responseCode}")
        return c.inputStream.bufferedReader().use { it.readText() }
    }

    /** Métodos que llama el JavaScript de po_token.html. */
    private class Bridge(private val l: CountDownLatch) {
        @JavascriptInterface
        fun downloadAndRunBotguard() {
            io.execute {
                try {
                    val data = parseChallenge(post("https://www.youtube.com/api/jnn/v1/Create", "[ \"$REQUEST_KEY\" ]"))
                    main.post {
                        web?.evaluateJavascript(
                            """try {
                                data = $data
                                runBotGuard(data).then(function (result) {
                                    this.webPoSignalOutput = result.webPoSignalOutput
                                    $JS.onRunBotguardResult(result.botguardResponse)
                                }, function (error) { $JS.onJsInitializationError(error + "\n" + error.stack) })
                            } catch (error) { $JS.onJsInitializationError(error + "\n" + error.stack) }""",
                            null,
                        )
                    }
                } catch (e: Throwable) {
                    fail(l, "create: ${e.message}")
                }
            }
        }

        @JavascriptInterface
        fun onJsInitializationError(error: String) = fail(l, "js: ${error.take(300)}")

        @JavascriptInterface
        fun onRunBotguardResult(botguardResponse: String) {
            io.execute {
                try {
                    val arr = JSONArray(post("https://www.youtube.com/api/jnn/v1/GenerateIT", "[ \"$REQUEST_KEY\", \"$botguardResponse\" ]"))
                    val token = u8(b64(arr.getString(0)))
                    val ttl = arr.optLong(1, 3600)
                    main.post {
                        web?.evaluateJavascript("this.integrityToken = $token") {
                            // 10 minutos de margen
                            expiresAt = System.currentTimeMillis() + (ttl - 600).coerceAtLeast(60) * 1000
                            l.countDown()
                        }
                    }
                } catch (e: Throwable) {
                    fail(l, "generateIT: ${e.message}")
                }
            }
        }

        @JavascriptInterface
        fun onObtainPoTokenResult(identifier: String, u8: String) {
            val p = pending[identifier] ?: return
            p.second[0] = try {
                val bytes = u8.split(",").map { it.trim().toInt().toByte() }.toByteArray()
                Base64.encodeToString(bytes, Base64.NO_WRAP).replace('+', '-').replace('/', '_')
            } catch (_: Throwable) {
                null
            }
            p.first.countDown()
        }

        @JavascriptInterface
        fun onObtainPoTokenError(identifier: String, error: String) {
            Log.w(TAG, "obtain: ${error.take(300)}")
            pending[identifier]?.first?.countDown()
        }
    }

    private fun obtain(identifier: String): String? {
        val latch = CountDownLatch(1)
        val slot = arrayOfNulls<String>(1)
        pending[identifier] = latch to slot
        val idJs = JSONObject.quote(identifier)
        val u8 = u8(identifier.toByteArray())
        main.post {
            web?.evaluateJavascript(
                """try {
                    var identifier = $idJs
                    var poTokenU8 = obtainPoToken(webPoSignalOutput, integrityToken, $u8)
                    var s = ""
                    for (var i = 0; i < poTokenU8.length; i++) { if (i != 0) s += ","; s += poTokenU8[i] }
                    $JS.onObtainPoTokenResult(identifier, s)
                } catch (error) { $JS.onObtainPoTokenError($idJs, error + "\n" + error.stack) }""",
                null,
            ) ?: latch.countDown()
        }
        latch.await(15, TimeUnit.SECONDS)
        pending.remove(identifier)
        return slot[0]
    }

    // Formatos de la API de BotGuard (JavaScriptUtil.kt de NewPipe)

    private fun b64(s: String): ByteArray = Base64.decode(s.replace('-', '+').replace('_', '/').replace('.', '='), Base64.DEFAULT)

    private fun u8(bytes: ByteArray) = "new Uint8Array([" + bytes.joinToString(",") { (it.toInt() and 0xff).toString() } + "])"

    private fun parseChallenge(raw: String): String {
        val scrambled = JSONArray(raw)
        val cd = if (scrambled.length() > 1 && scrambled.opt(1) is String) {
            JSONArray(String(b64(scrambled.getString(1)).map { (it + 97).toByte() }.toByteArray()))
        } else {
            scrambled.getJSONArray(0)
        }
        fun firstString(a: JSONArray?): Any {
            if (a == null) return JSONObject.NULL
            for (i in 0 until a.length()) if (a.opt(i) is String) return a.getString(i)
            return JSONObject.NULL
        }
        return JSONObject()
            .put("messageId", cd.optString(0))
            .put(
                "interpreterJavascript",
                JSONObject()
                    .put("privateDoNotAccessOrElseSafeScriptWrappedValue", firstString(cd.optJSONArray(1)))
                    .put("privateDoNotAccessOrElseTrustedResourceUrlWrappedValue", firstString(cd.optJSONArray(2))),
            )
            .put("interpreterHash", cd.optString(3))
            .put("program", cd.optString(4))
            .put("globalName", cd.optString(5))
            .put("clientExperimentsStateBlob", cd.optString(7))
            .toString()
    }
}
