package com.sebxstt.setube

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import android.webkit.CookieManager
import java.io.File
import java.util.UUID

/**
 * Sesión de YouTube para yt-dlp a partir de la base SQLite de cookies del WebView de la app
 * (`app_webview/Default/Cookies`). Es el mismo lector de `cookies-db.ts` de la API para Chromium: en Android
 * el WebView no cifra las cookies, así que se leen tal cual. Se relee cuando cambia la base, de modo que las
 * cookies que el WebView rota siguen valiendo.
 */
object CookieStore {
    private const val TAG = "SetubeCookies"
    private const val PREFS = "setube_session"
    private val DOMAINS = listOf("youtube.com", "google.com")
    private val AUTH = setOf("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID", "__Secure-3PSID", "__Secure-1PSID", "SID")
    private const val CHROMIUM_EPOCH_OFFSET_SEC = 11644473600L

    data class Snapshot(val netscape: String, val count: Int, val loggedIn: Boolean, val undecryptable: Int, val signature: String)

    @Volatile
    private var cached: Snapshot? = null

    fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun mode(ctx: Context): String = prefs(ctx).getString("mode", "auto") ?: "auto"
    fun setMode(ctx: Context, m: String) = prefs(ctx).edit().putString("mode", if (m in setOf("auto", "always", "off")) m else "auto").apply()
    fun lastRefresh(ctx: Context) = prefs(ctx).getLong("lastRefresh", 0L)
    fun markRefreshed(ctx: Context) = prefs(ctx).edit().putLong("lastRefresh", System.currentTimeMillis()).apply()

    private fun importedFile(ctx: Context) = File(File(ctx.filesDir, "session").apply { mkdirs() }, "imported.txt")

    fun dbFile(ctx: Context): File? {
        val base = File(ctx.dataDir, "app_webview")
        return listOf("Default/Cookies", "Cookies").map { File(base, it) }.firstOrNull { it.isFile }
    }

    private fun signature(f: File): String {
        fun part(x: File) = if (x.exists()) "${x.lastModified()}:${x.length()}" else "-"
        return "${part(f)}|${part(File(f.path + "-wal"))}|${part(File(f.path + "-journal"))}"
    }

    private fun allowed(host: String): Boolean {
        val h = host.removePrefix(".").lowercase()
        return DOMAINS.any { h == it || h.endsWith(".$it") }
    }

    private fun clean(s: String) = s.replace(Regex("[\t\r\n]"), "")

    /** Lee la base si cambió desde la última lectura. `null` si no hay base. */
    fun snapshot(ctx: Context): Snapshot? {
        val db = dbFile(ctx) ?: return null
        val sig = signature(db)
        cached?.let { if (it.signature == sig) return it }
        return try {
            read(ctx, db, sig).also { cached = it }
        } catch (e: Exception) {
            Log.w(TAG, "cookies_db_refresh_failed", e)
            cached
        }
    }

    private fun read(ctx: Context, db: File, sig: String): Snapshot {
        // Se copia la base y su WAL/journal: no bloquea al WebView y entran las cookies recientes
        val dir = File(ctx.cacheDir, "ckdb-" + UUID.randomUUID()).apply { mkdirs() }
        try {
            val copy = File(dir, "c.sqlite")
            db.copyTo(copy, true)
            for (suf in listOf("-wal", "-journal")) {
                val s = File(db.path + suf)
                if (s.exists()) s.copyTo(File(copy.path + suf), true)
            }
            val sq = SQLiteDatabase.openDatabase(copy.path, null, SQLiteDatabase.OPEN_READWRITE)
            try {
                val cols = HashSet<String>()
                sq.rawQuery("PRAGMA table_info(cookies)", null).use { c -> while (c.moveToNext()) cols += c.getString(1) }
                val secure = if ("is_secure" in cols) "is_secure" else "secure"
                val httpOnly = when {
                    "is_httponly" in cols -> "is_httponly"
                    "httponly" in cols -> "httponly"
                    else -> "0"
                }
                val now = System.currentTimeMillis() / 1000
                val lines = StringBuilder("# Netscape HTTP Cookie File\n")
                val seen = HashSet<String>()
                var count = 0
                var undecryptable = 0
                var loggedIn = false
                sq.rawQuery(
                    "SELECT host_key, name, value, encrypted_value, path, expires_utc / 1000000, $secure, $httpOnly FROM cookies",
                    null,
                ).use { c ->
                    while (c.moveToNext()) {
                        val host = c.getString(0) ?: continue
                        if (!allowed(host)) continue
                        val name = c.getString(1) ?: ""
                        var value = c.getString(2) ?: ""
                        if (value.isEmpty()) {
                            val enc = c.getBlob(3)
                            if (enc != null && enc.isNotEmpty()) {
                                undecryptable++
                                continue
                            }
                        }
                        val sec = c.getLong(5)
                        val expiry = if (sec > 0) sec - CHROMIUM_EPOCH_OFFSET_SEC else 0
                        if (expiry != 0L && expiry <= now) continue
                        val path = c.getString(4) ?: "/"
                        if (!seen.add("$host\t$path\t$name")) continue
                        val domain = clean(host)
                        lines.append(if (c.getInt(7) == 1) "#HttpOnly_" else "").append(domain).append('\t')
                            .append(if (domain.startsWith(".")) "TRUE" else "FALSE").append('\t')
                            .append(clean(path).ifEmpty { "/" }).append('\t')
                            .append(if (c.getInt(6) == 1) "TRUE" else "FALSE").append('\t')
                            .append(expiry).append('\t')
                            .append(clean(name)).append('\t')
                            .append(clean(value)).append('\n')
                        count++
                        if (name in AUTH && host.removePrefix(".").endsWith("youtube.com")) loggedIn = true
                    }
                }
                return Snapshot(lines.toString(), count, loggedIn, undecryptable, sig)
            } finally {
                sq.close()
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun importedLoggedIn(text: String) = text.lineSequence().any { l ->
        val p = l.removePrefix("#HttpOnly_").split('\t')
        p.size >= 7 && p[0].removePrefix(".").endsWith("youtube.com") && p[5] in AUTH
    }

    /** cookies.txt (formato Netscape) pegado por el usuario, como alternativa al login en el WebView. */
    fun import(ctx: Context, text: String): Boolean {
        val body = text.lineSequence().map { it.trimEnd('\r') }.filter { l ->
            if (l.isBlank()) return@filter false
            if (l.startsWith("#") && !l.startsWith("#HttpOnly_")) return@filter false
            val p = l.removePrefix("#HttpOnly_").split('\t')
            p.size >= 7 && allowed(p[0])
        }.joinToString("\n")
        if (body.isEmpty()) return false
        val f = importedFile(ctx)
        f.writeText("# Netscape HTTP Cookie File\n$body\n")
        f.setReadable(false, false)
        f.setReadable(true, true)
        return true
    }

    data class Status(val loggedIn: Boolean, val count: Int, val source: String)

    fun status(ctx: Context): Status {
        val s = snapshot(ctx)
        if (s != null && s.loggedIn) return Status(true, s.count, "webview")
        val imp = importedFile(ctx)
        if (imp.isFile) {
            val t = imp.readText()
            if (importedLoggedIn(t)) return Status(true, t.lineSequence().count { it.isNotBlank() && !it.startsWith("# ") }, "imported")
        }
        return Status(false, s?.count ?: 0, "none")
    }

    /** Escribe las cookies vigentes en un archivo temporal 0600 para un proceso de yt-dlp. `null` sin sesión. */
    fun materialize(ctx: Context): File? {
        val s = snapshot(ctx)
        val text = when {
            s != null && s.loggedIn -> s.netscape
            importedFile(ctx).isFile -> importedFile(ctx).readText()
            else -> return null
        }
        val f = File(ctx.cacheDir, "ck-" + UUID.randomUUID() + ".txt")
        f.writeText(text)
        f.setReadable(false, false)
        f.setReadable(true, true)
        f.setWritable(false, false)
        f.setWritable(true, true)
        return f
    }

    fun logout(ctx: Context, done: () -> Unit) {
        importedFile(ctx).delete()
        cached = null
        val cm = CookieManager.getInstance()
        cm.removeAllCookies {
            cm.flush()
            done()
        }
    }
}
