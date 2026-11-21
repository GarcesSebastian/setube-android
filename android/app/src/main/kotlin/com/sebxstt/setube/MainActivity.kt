package com.sebxstt.setube

import android.Manifest
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Engine.attach(this)
        Helper.start(this)
        Notifications.channels(this)
        // Python y ffmpeg se descomprimen en segundo plano al abrir la app por primera vez
        Executors.newSingleThreadExecutor().execute {
            try {
                Engine.ensure(this)
            } catch (_: Exception) {
            }
        }
    }
}

class MainActivity : FlutterActivity() {
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private var loginResult: MethodChannel.Result? = null
    private var notifResult: MethodChannel.Result? = null
    private var routeChannel: MethodChannel? = null

    private fun bg(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: Throwable) {
                main.post { result.error("native", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val m = flutterEngine.dartExecutor.binaryMessenger
        PlayerHub.setTextures(flutterEngine.renderer)

        MethodChannel(m, "setube/engine").setMethodCallHandler { call, result -> engine(call, result) }
        MethodChannel(m, "setube/session").setMethodCallHandler { call, result -> session(call, result) }
        MethodChannel(m, "setube/downloads").setMethodCallHandler { call, result -> downloads(call, result) }
        MethodChannel(m, "setube/player").setMethodCallHandler { call, result -> player(call, result) }
        MethodChannel(m, "setube/pc").setMethodCallHandler { call, result -> pc(call, result) }
        EventChannel(m, "setube/pc/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                PcJobs.sink = events
                PcJobs.state?.let { events?.success(it) }
            }

            override fun onCancel(arguments: Any?) {
                PcJobs.sink = null
            }
        })
        routeChannel = MethodChannel(m, "setube/app").also { ch -> ch.setMethodCallHandler { call, result -> appCall(call, result) } }

        EventChannel(m, "setube/downloads/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Downloads.sink = events
            }

            override fun onCancel(arguments: Any?) {
                Downloads.sink = null
            }
        })
        EventChannel(m, "setube/player/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                PlayerHub.sink = events
                PlayerHub.emitState()
            }

            override fun onCancel(arguments: Any?) {
                PlayerHub.sink = null
            }
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("route")?.let { routeChannel?.invokeMethod("route", it) }
        sharedText(intent)?.let { routeChannel?.invokeMethod("shared", it) }
    }

    private fun sharedText(i: Intent?): String? =
        if (i?.action == Intent.ACTION_SEND) i.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() } else null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        PlayerHub.setTextures(null)
        PlayerHub.sink = null
        Downloads.sink = null
        PcJobs.sink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // yt-dlp

    private fun engine(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> bg(result) {
                val ids = call.argument<List<String>>("ids") ?: emptyList()
                val priority = call.argument<Boolean>("priority") == true
                mapOf("results" to InfoBatcher.getAll(ids, priority).map { mapOf("id" to it.id, "path" to it.path, "code" to it.code, "message" to it.message) })
            }
            "run" -> bg(result) {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val r = Engine.runWithSession(args)
                mapOf("exit" to (if (r.canceled) 1 else r.exit), "out" to r.out, "err" to r.err)
            }
            "version" -> bg(result) {
                Engine.ensure(this)
                mapOf("ytdlp" to Engine.version())
            }
            "update" -> bg(result) { Engine.update(call.argument<String>("channel") ?: "stable") }
            "diagnose" -> bg(result) { Engine.diagnose(call.argument<String>("videoId") ?: "aqz-KE-bpKQ") }
            else -> result.notImplemented()
        }
    }

    // Sesión de YouTube

    private fun sessionStatus(): Map<String, Any?> {
        val s = CookieStore.status(this)
        return mapOf(
            "loggedIn" to s.loggedIn, "count" to s.count, "source" to s.source,
            "lastRefresh" to CookieStore.lastRefresh(this), "mode" to CookieStore.mode(this),
        )
    }

    private fun session(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> bg(result) { sessionStatus() }
            "login" -> {
                loginResult?.success(null)
                loginResult = result
                @Suppress("DEPRECATION")
                startActivityForResult(Intent(this, LoginActivity::class.java), REQ_LOGIN)
            }
            "logout" -> CookieStore.logout(this) { bg(result) { sessionStatus() } }
            "refresh" -> {
                if (call.argument<Boolean>("force") != true && !SessionKeeper.due(this)) {
                    bg(result) { sessionStatus() }
                } else {
                    SessionKeeper.refresh(this) { bg(result) { sessionStatus() } }
                }
            }
            "setMode" -> bg(result) {
                CookieStore.setMode(this, call.argument<String>("mode") ?: "auto")
                sessionStatus()
            }
            "importCookies" -> bg(result) {
                CookieStore.import(this, call.argument<String>("text") ?: "")
                sessionStatus()
            }
            else -> result.notImplemented()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_LOGIN) {
            val r = loginResult ?: return
            loginResult = null
            bg(r) { sessionStatus() }
        }
    }

    // Descargas y archivos

    private fun downloads(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enqueue" -> {
                val job = call.argument<Map<String, Any?>>("job")
                if (job == null) {
                    result.error("args", "job", null)
                    return
                }
                Downloads.enqueue(applicationContext, JSONObject(job))
                result.success(true)
            }
            "cancelJob" -> {
                Downloads.cancelJob(call.argument<String>("jobId") ?: "")
                result.success(true)
            }
            "cancelItem" -> {
                Downloads.cancelItem(call.argument<String>("jobId") ?: "", call.argument<String>("itemId") ?: "")
                result.success(true)
            }
            "active" -> result.success(Downloads.active())
            "history" -> bg(result) { toList(History.list(this)) }
            "deleteHistory" -> bg(result) {
                val e = History.remove(this, call.argument<String>("id") ?: "")
                if (e != null && call.argument<Boolean>("deleteFile") == true) Saver.delete(this, Uri.parse(e.optString("uri")))
                true
            }
            "clearHistory" -> bg(result) { History.clear(this) }
            "exists" -> bg(result) { (call.argument<List<String>>("uris") ?: emptyList()).map { Saver.exists(this, Uri.parse(it)) } }
            "open" -> result.success(openFile(Uri.parse(call.argument<String>("uri")), call.argument<String>("mime") ?: "*/*"))
            "share" -> result.success(
                share((call.argument<List<String>>("uris") ?: emptyList()).map { Uri.parse(it) }, call.argument<String>("mime") ?: "*/*", call.argument<String>("text")),
            )
            "openFolder" -> result.success(openFolder(call.argument<String>("relativePath") ?: "Download/Setube"))
            else -> result.notImplemented()
        }
    }

    private fun toList(a: JSONArray): List<Map<String, Any?>> = (0 until a.length()).mapNotNull { i ->
        val o = a.optJSONObject(i) ?: return@mapNotNull null
        toMap(o)
    }

    private fun toMap(o: JSONObject): Map<String, Any?> = o.keys().asSequence().associateWith { k ->
        when (val v = o.get(k)) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(v)
            is JSONArray -> (0 until v.length()).map { i -> v.get(i).let { x -> if (x is JSONObject) toMap(x) else if (x == JSONObject.NULL) null else x } }
            else -> v
        }
    }

    private fun openFile(uri: Uri, mime: String): Boolean = try {
        startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Abrir con",
            ),
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    private fun share(uris: List<Uri>, mime: String, text: String?): Boolean {
        if (uris.isEmpty()) return false
        val i = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        }
        i.type = mime
        if (text != null) i.putExtra(Intent.EXTRA_TEXT, text)
        // Algunas apps (WhatsApp) leen el ClipData para conceder el permiso de lectura
        i.clipData = ClipData.newRawUri("", uris[0]).apply { for (u in uris.drop(1)) addItem(ClipData.Item(u)) }
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(Intent.createChooser(i, "Compartir"))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    /** Abre la carpeta en el gestor de archivos del sistema; si no se puede, la vista de descargas. */
    private fun openFolder(rel: String): Boolean {
        val docUri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:$rel")
        val attempts = listOf(
            Intent(Intent.ACTION_VIEW).setDataAndType(docUri, DocumentsContract.Document.MIME_TYPE_DIR),
            Intent(Intent.ACTION_VIEW).setDataAndType(docUri, "resource/folder"),
            Intent(Intent.ACTION_VIEW).setData(docUri).setPackage("com.google.android.documentsui"),
            Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS),
        )
        for (i in attempts) {
            try {
                i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    // Envío al PC (LocalSend)

    private fun pcState(): Map<String, Any?> = mapOf(
        "favorite" to PcSend.favorite(this)?.toMap(),
        "auto" to PcSend.autoSend(this),
    )

    private fun pc(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(pcState())
            "discover" -> bg(result) { PcSend.discover(this).map { it.toMap() + ("cert" to it.cert) } }
            "choose" -> bg(result) {
                @Suppress("UNCHECKED_CAST")
                val d = call.arguments as Map<String, Any?>
                PcSend.setFavorite(
                    this,
                    PcSend.Device(
                        d["alias"] as String, d["ip"] as String, (d["port"] as Number).toInt(), d["fingerprint"] as? String ?: "",
                        d["model"] as? String, d["type"] as? String, d["cert"] as? String ?: "",
                    ),
                )
                pcState()
            }
            "forget" -> bg(result) {
                PcSend.setFavorite(this, null)
                pcState()
            }
            "setAuto" -> bg(result) {
                PcSend.setAutoSend(this, call.argument<Boolean>("on") == true)
                pcState()
            }
            "send" -> {
                val e = call.argument<String>("entry")
                if (e == null) result.error("args", "entry", null)
                else {
                    PcJobs.enqueue(applicationContext, JSONObject(e))
                    result.success(true)
                }
            }
            "cancel" -> {
                PcJobs.cancel()
                result.success(true)
            }
            "installLink" -> result.success(
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://localsend.org/download")))
                    true
                } catch (_: ActivityNotFoundException) {
                    false
                },
            )
            else -> result.notImplemented()
        }
    }

    // Reproductor

    private fun player(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "load" -> PlayerHub.load(this, call.arguments as Map<*, *>)
                "play" -> PlayerHub.play()
                "pause" -> PlayerHub.pause()
                "seek" -> PlayerHub.seek((call.argument<Number>("ms") ?: 0).toLong())
                "stop" -> PlayerHub.stop()
                "setVolume" -> PlayerHub.setVolume((call.argument<Number>("volume") ?: 1.0).toFloat())
                "setNeighbors" -> PlayerHub.setNeighbors(call.argument<Boolean>("prev") == true, call.argument<Boolean>("next") == true)
                "attachVideo" -> {
                    result.success(PlayerHub.attachVideo(this))
                    return
                }
                "detachVideo" -> PlayerHub.detachVideo()
                else -> {
                    result.notImplemented()
                    return
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("player", e.message, null)
        }
    }

    // App

    private fun appCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                    result.success(true)
                } else {
                    notifResult?.success(false)
                    notifResult = result
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
                }
            }
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(true)
            }
            "openUrl" -> result.success(
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    true
                } catch (_: ActivityNotFoundException) {
                    false
                },
            )
            "initial" -> {
                result.success(mapOf("route" to intent?.getStringExtra("route"), "shared" to sharedText(intent)))
                intent?.removeExtra("route")
                intent?.action = Intent.ACTION_MAIN
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIF) {
            notifResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            notifResult = null
        }
    }

    companion object {
        const val REQ_LOGIN = 7101
        const val REQ_NOTIF = 7102
    }
}
