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
