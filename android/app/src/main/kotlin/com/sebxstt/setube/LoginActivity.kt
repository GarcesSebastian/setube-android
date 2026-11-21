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
