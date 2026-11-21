package com.sebxstt.setube

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature

/** UA de Chrome móvil sin las marcas del WebView (`; wv`, `Version/4.0`), que Google rechaza al iniciar sesión. */
fun browserUserAgent(ctx: Context): String {
    val def = try {
        WebSettings.getDefaultUserAgent(ctx)
    } catch (_: Exception) {
        "Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
    }
    return def.replace("; wv", "").replace(Regex(" Build/[^;)]+"), "").replace(Regex("Version/\\d+(\\.\\d+)* "), "")
}

@SuppressLint("SetJavaScriptEnabled")
fun configureWebView(w: WebView) {
    val s = w.settings
    s.javaScriptEnabled = true
    s.domStorageEnabled = true
    s.userAgentString = browserUserAgent(w.context)
    s.mediaPlaybackRequiresUserGesture = true
    if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
        WebSettingsCompat.setRequestedWithHeaderOriginAllowList(s, emptySet())
    }
    val cm = CookieManager.getInstance()
    cm.setAcceptCookie(true)
    cm.setAcceptThirdPartyCookies(w, true)
}

private fun hasYoutubeSession(): Boolean {
    val c = CookieManager.getInstance().getCookie("https://www.youtube.com") ?: return false
    return c.contains("SAPISID=") || c.contains("__Secure-3PSID=") || c.contains("__Secure-1PSID=")
}

/** Inicio de sesión en YouTube con el WebView de la app. La sesión queda en la base de cookies del WebView. */
class LoginActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var done: Button
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar

    private val bg = Color.parseColor("#16181b")
    private val panel = Color.parseColor("#1f2226")
    private val ink = Color.parseColor("#e9e7e2")
    private val muted = Color.parseColor("#9ba1a9")
    private val red = Color.parseColor("#d7262c")

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = bg
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(bg)
            fitsSystemWindows = true
        }
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(panel)
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        val close = Button(this).apply {
            text = "Cancelar"
            setTextColor(ink)
            setBackgroundColor(Color.TRANSPARENT)
            isAllCaps = false
            setOnClickListener { finishWith(false) }
        }
        val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(TextView(this).apply {
            text = "Inicia sesión en YouTube"
            setTextColor(ink)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
        })
        status = TextView(this).apply {
            text = "Usa una cuenta secundaria"
            setTextColor(muted)
            textSize = 12f
        }
        texts.addView(status)
        done = Button(this).apply {
            text = "Listo"
            isAllCaps = false
            setTextColor(Color.WHITE)
            setBackgroundColor(red)
            isEnabled = false
            alpha = 0.5f
            setOnClickListener { finishWith(true) }
        }
        bar.addView(close)
        bar.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(done)
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
            visibility = View.VISIBLE
        }
        web = WebView(this)
        configureWebView(web)
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                progress.visibility = View.GONE
                CookieManager.getInstance().flush()
                refreshState()
            }

            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                progress.visibility = View.VISIBLE
            }
        }
        root.addView(bar)
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)))
        root.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        web.loadUrl(START_URL)
        refreshState()
        // Con el «atrás predictivo» (targetSdk 36) onBackPressed ya no se llama
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT) { goBack() }
        }
    }

    private fun goBack() {
        if (web.canGoBack()) web.goBack() else finishWith(hasYoutubeSession())
    }

    private fun refreshState() {
        val ok = hasYoutubeSession()
        done.isEnabled = ok
        done.alpha = if (ok) 1f else 0.5f
        status.text = if (ok) "Sesión iniciada. Toca Listo." else "Usa una cuenta secundaria"
    }

    private fun finishWith(ok: Boolean) {
        CookieManager.getInstance().flush()
        if (ok) CookieStore.markRefreshed(this)
        // El WebView escribe la base de cookies poco después del flush
        Handler(Looper.getMainLooper()).postDelayed({
            setResult(if (ok) RESULT_OK else RESULT_CANCELED)
            finish()
        }, if (ok) 600 else 0)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() = goBack()

    override fun onDestroy() {
        web.destroy()
        super.onDestroy()
    }

    companion object {
        const val START_URL =
            "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&hl=es" +
                "&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm%26hl%3Des%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F"
    }
}

/**
 * Mantiene viva la sesión: abre YouTube unos segundos en un WebView sin interfaz para que su JavaScript rote
 * las cookies (`__Secure-*PSIDTS`). yt-dlp nunca escribe de vuelta en la base.
 */
object SessionKeeper {
    private const val EVERY_MS = 6 * 60 * 60 * 1000L
    private var running = false

    fun due(ctx: Context) = System.currentTimeMillis() - CookieStore.lastRefresh(ctx) > EVERY_MS

    fun refresh(ctx: Context, done: () -> Unit) {
        val main = Handler(Looper.getMainLooper())
        main.post {
            val has = try {
                hasYoutubeSession()
            } catch (_: Throwable) {
                false
            }
            if (running || !has) {
                done()
                return@post
            }
            running = true
            val w = try {
                WebView(ctx.applicationContext).also { configureWebView(it) }
            } catch (e: Throwable) {
                // WebView ausente o actualizándose: se intenta la próxima vez
                running = false
                done()
                return@post
            }
            var finished = false
            val finish = Runnable {
                if (finished) return@Runnable
                finished = true
                CookieManager.getInstance().flush()
                w.stopLoading()
                w.destroy()
                CookieStore.markRefreshed(ctx)
                running = false
                main.postDelayed({ done() }, 500)
            }
            w.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    main.postDelayed(finish, 6000)
                }
            }
            w.loadUrl("https://m.youtube.com/")
            main.postDelayed(finish, 30000)
        }
    }
}
