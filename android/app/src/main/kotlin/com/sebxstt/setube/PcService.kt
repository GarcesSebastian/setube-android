package com.sebxstt.setube

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue

/** Cola de envíos al PC: uno detrás de otro, en primer plano para que no se corte con la pantalla apagada. */
object PcJobs {
    private const val TAG = "SetubePcJobs"
    private val main = Handler(Looper.getMainLooper())
    private val queue = LinkedBlockingQueue<JSONObject>()
    private val worker = Executors.newSingleThreadExecutor()

    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var state: Map<String, Any?>? = null
        private set
    @Volatile private var running = false

    private fun emit(m: Map<String, Any?>) {
        state = m
        main.post { sink?.success(m) }
        PcService.update()
    }

    fun pending() = queue.size

    fun enqueue(ctx: Context, entry: JSONObject) {
        val id = entry.optString("id")
        if (queue.any { it.optString("id") == id } || state?.let { it["entryId"] == id && it["status"] in setOf("connecting", "sending") } == true) return
        queue.add(entry)
        emit(mapOf("entryId" to id, "name" to entry.optString("name"), "status" to "queued", "pending" to queue.size))
        PcService.start(ctx)
        if (!running) {
            running = true
            worker.execute { loop(ctx.applicationContext) }
        }
    }

    fun cancel() {
        queue.clear()
        PcSend.cancel()
    }

    val active get() = running

    private fun loop(ctx: Context) {
        try {
            while (true) {
                val entry = queue.poll() ?: break
                run(ctx, entry)
            }
        } finally {
            running = false
            PcService.update()
        }
    }

    private fun run(ctx: Context, entry: JSONObject) {
        val id = entry.optString("id")
        val name = entry.optString("name")
        fun st(status: String, extra: Map<String, Any?> = emptyMap()) =
            emit(mapOf("entryId" to id, "name" to name, "status" to status, "pending" to queue.size) + extra)
        st("connecting")
        val pc = try {
            PcSend.reachFavorite(ctx)
        } catch (e: Exception) {
            null
        }
        if (pc == null) {
            st("error", mapOf("code" to if (PcSend.favorite(ctx) == null) "no_pc" else "unreachable"))
            Notifications.pc(ctx, "No se encontró el PC", "Abre LocalSend en el PC y conéctalo a la misma Wi‑Fi.")
            return
        }
        var cleanup: () -> Unit = {}
        try {
            val (sources, c) = PcSend.sourcesFor(ctx, entry)
            cleanup = c
            val total = sources.sumOf { it.size }
            st("sending", mapOf("pc" to pc.alias, "sent" to 0L, "total" to total, "files" to 0, "filesTotal" to sources.size))
            val t0 = System.currentTimeMillis()
            PcSend.send(pc, sources) { sent, tot, files, filesTotal ->
                val secs = (System.currentTimeMillis() - t0) / 1000.0
                st("sending", mapOf("pc" to pc.alias, "sent" to sent, "total" to tot, "files" to files, "filesTotal" to filesTotal, "bps" to if (secs > 0) sent / secs else 0.0))
            }
            st("done", mapOf("pc" to pc.alias, "files" to sources.size, "filesTotal" to sources.size, "sent" to total, "total" to total))
            Notifications.pc(ctx, "Enviado a ${pc.alias}", if (sources.size > 1) "${sources.size} archivos de $name" else name)
        } catch (e: PcSend.Failed) {
            st("error", mapOf("code" to e.code, "pc" to pc.alias))
            if (e.code != "canceled") Notifications.pc(ctx, "No se pudo enviar a ${pc.alias}", PcErrors.text(e.code))
        } catch (e: Exception) {
            Log.w(TAG, "send", e)
            st("error", mapOf("code" to "error", "pc" to pc.alias, "message" to e.message))
            Notifications.pc(ctx, "No se pudo enviar a ${pc.alias}", PcErrors.text("error"))
        } finally {
            cleanup()
        }
    }
}

object PcErrors {
    fun text(code: String) = when (code) {
        "rejected" -> "El PC rechazó el envío."
        "busy" -> "El PC está recibiendo otra cosa. Intenta en un momento."
        "pin" -> "LocalSend del PC pide un PIN. Quítalo en sus ajustes."
        "pc_changed" -> "El PC guardado cambió (¿reinstalaste LocalSend?). Vuelve a buscarlo en Ajustes."
        "unreachable" -> "Abre LocalSend en el PC y conéctalo a la misma Wi‑Fi."
        "no_pc" -> "Primero elige el PC en Ajustes."
        else -> "Se cortó la conexión con el PC. Intenta de nuevo."
    }
}

class PcService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    private var lastStartId = 0

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, Notifications.PC_ID, Notifications.pcProgress(this, PcJobs.state), type)
        if (!PcJobs.active && PcJobs.pending() == 0) stopNow()
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        PcJobs.cancel()
        stopNow()
    }

    private fun stopNow() {
        if (stopSelfResult(lastStartId)) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile private var instance: PcService? = null
        private val main = Handler(Looper.getMainLooper())
        private var last = 0L

        fun start(ctx: Context) = main.post {
            val i = Intent(ctx, PcService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun update() = main.post {
            val s = instance ?: return@post
            if (!PcJobs.active && PcJobs.pending() == 0) {
                s.stopNow()
                return@post
            }
            val now = System.currentTimeMillis()
            if (now - last < 1000) return@post
            last = now
            try {
                NotificationManagerCompat.from(s).notify(Notifications.PC_ID, Notifications.pcProgress(s, PcJobs.state))
            } catch (_: SecurityException) {
            }
        }
    }
}

/** Notificaciones del envío al PC (con las demás de Notifications, en DownloadService.kt). */
fun Notifications.pcProgress(ctx: Context, st: Map<String, Any?>?): android.app.Notification {
    val sent = (st?.get("sent") as? Number)?.toLong() ?: 0L
    val total = (st?.get("total") as? Number)?.toLong() ?: 0L
    val pct = if (total > 0) (sent * 100 / total).toInt() else 0
    val pc = st?.get("pc") as? String ?: "el PC"
    val files = st?.get("files") as? Number
    val filesTotal = st?.get("filesTotal") as? Number
    return NotificationCompat.Builder(ctx, CH_PROGRESS)
        .setSmallIcon(R.drawable.ic_stat_setube)
        .setContentTitle(if (st?.get("status") == "sending") "Enviando a $pc" else "Buscando el PC")
        .setContentText(if (files != null && filesTotal != null && filesTotal.toInt() > 1) "${files} de ${filesTotal} · $pct %" else "$pct %")
        .setProgress(100, pct, st?.get("status") != "sending")
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .build()
}

fun Notifications.pc(ctx: Context, title: String, body: String) = notifyPublic(
    ctx,
    NotificationCompat.Builder(ctx, CH_DONE)
        .setSmallIcon(R.drawable.ic_stat_setube)
        .setContentTitle(title)
        .setContentText(body)
        .setAutoCancel(true)
        .build(),
)
