package com.sebxstt.setube

import android.app.Notification
import android.app.PendingIntent
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
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Date
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Estado de las descargas y puente de eventos con Dart. Vive mientras viva el proceso. */
object Downloads {
    private const val TAG = "SetubeDownloads"
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var sink: EventChannel.EventSink? = null

    val jobs = ConcurrentHashMap<String, Job>()
    private val finisher = Executors.newSingleThreadExecutor()

    class Item(
        val itemId: String,
        val videoId: String,
        val title: String?,
        val author: String?,
        val sel: String?,
        val bytes: Long?,
        val hls: Boolean,
    ) {
        @Volatile var status = "queued"
        @Volatile var pct = 0.0
        @Volatile var speed = 0.0
        @Volatile var error: String? = null
        @Volatile var message: String? = null
        @Volatile var file: File? = null
        @Volatile var canceled = false
        @Volatile var procId: String? = null
        @Volatile var timing: String? = null
        @Volatile var conv = 0.0
        @Volatile var dlBytes = 0L
        @Volatile var dlMs = 0L
        @Volatile var convMs = 0L
        // Estado entre etapas de la tubería
        @Volatile var dir: File? = null
        @Volatile var info: File? = null
        @Volatile var selected: String? = null
        @Volatile var cover: File? = null
        @Volatile var fastBytes = 0L
        @Volatile var tStart = 0L
        @Volatile var tInfo = 0L
        @Volatile var tDownload = 0L
        var lastEmit = 0L

        fun toMap(jobId: String) = mapOf(
            "type" to "item", "jobId" to jobId, "itemId" to itemId, "videoId" to videoId, "title" to title, "status" to status, "pct" to pct,
            "speed" to speed, "error" to error, "message" to message,
            "conv" to conv, "dlBytes" to dlBytes, "dlMs" to dlMs, "convMs" to convMs,
        )
    }

    class Job(val id: String, val format: String, val quality: Int?, val items: List<Item>, val dryRun: Boolean = false) {
        val pending = AtomicInteger(items.size)
        @Volatile var canceled = false
        @Volatile var status = "active"
        @Volatile var entry: JSONObject? = null
        val createdAt = System.currentTimeMillis()

        fun toMap(): Map<String, Any?> = mapOf(
            "jobId" to id, "status" to status, "format" to format, "quality" to quality,
            "items" to items.map { it.toMap(id) }, "entry" to entry?.toString(),
        )
    }

    fun emit(m: Map<String, Any?>) = main.post { sink?.success(m) }

    fun enqueue(ctx: Context, j: JSONObject) {
        val arr = j.optJSONArray("items") ?: JSONArray()
        // Los null de Dart llegan como JSONObject.NULL y optString los convertiría en "null"
        fun JSONObject.str(k: String): String? = if (!has(k) || isNull(k)) null else optString(k).ifEmpty { null }
        val items = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            Item(
                o.str("itemId") ?: UUID.randomUUID().toString(), o.str("videoId") ?: return@mapNotNull null, o.str("title"),
                o.str("author"), o.str("sel"),
                if (o.has("bytes") && !o.isNull("bytes")) o.optLong("bytes") else null, o.optBoolean("hls"),
            )
        }
        if (items.isEmpty()) return
        val q = if (j.has("quality") && !j.isNull("quality")) j.optInt("quality") else null
        val job = Job(j.str("jobId") ?: UUID.randomUUID().toString(), j.str("format") ?: "mp3", q, items)
        jobs[job.id] = job
        DownloadService.start(ctx)
        // La info que falta se pide toda de golpe, en lotes, antes de que las etapas la necesiten
        InfoBatcher.prefetch(items.map { it.videoId }.filter { freshInfo(it) == null })
        for (it in items) {
            emitItem(job, it, force = true)
            runItem(ctx, job, it)
        }
    }

    fun cancelJob(id: String) {
        val job = jobs[id] ?: return
        job.canceled = true
        for (it in job.items) cancelItem(job, it)
    }

    fun cancelItem(jobId: String, itemId: String) {
        val job = jobs[jobId] ?: return
        job.items.firstOrNull { it.itemId == itemId }?.let { cancelItem(job, it) }
    }

    private fun cancelItem(job: Job, it: Item) {
        it.canceled = true
        it.procId?.let { p -> Engine.cancel(p) }
        if (it.status == "queued") {
            it.status = "canceled"
            emitItem(job, it, force = true)
        }
    }

    fun active(): List<Map<String, Any?>> = jobs.values.sortedBy { it.createdAt }.map { it.toMap() }

    private fun emitItem(job: Job, it: Item, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - it.lastEmit < 250) return
        it.lastEmit = now
        emit(it.toMap(job.id))
        DownloadService.update()
    }

    // Una descarga

    private val PROGRESS = "SETUBE_PROGRESS "
    private val PP = "SETUBE_PP "
    private const val INFO_MAX_AGE_MS = 3 * 60 * 60 * 1000L

    private fun formatArgs(format: String, quality: Int?): List<String> = when (format) {
        "mp3" -> listOf(
            "-x", "--audio-format", "mp3", "--audio-quality", "${quality ?: 192}K",
            // Sin forzar 44,1 kHz: el Opus de YouTube es de 48 kHz y remuestrear cuesta tiempo; MP3 admite 48 kHz
            "--postprocessor-args", "ExtractAudio:-ac 2 -compression_level 7",
            "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
        )
        "m4a" -> listOf(
            "-x", "--audio-format", "m4a", "--audio-quality", "192K",
            "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
        )
        "wav" -> listOf("-x", "--audio-format", "wav", "--postprocessor-args", "ExtractAudio:-ar 44100 -ac 2 -sample_fmt s16")
        else -> listOf("--merge-output-format", "mp4", "--embed-metadata")
    }

    private fun genericSel(format: String, quality: Int?): String {
        if (format != "mp4") return if (format == "m4a") "ba[ext=m4a]/ba/b" else "ba/b"
        val h = if (quality == null || quality == 0) 1080 else quality
        return "bv*[vcodec^=avc1][ext=mp4][height<=$h]+ba[ext=m4a]/bv*[height<=$h]+ba/b[height<=$h]/bv*+ba/b"
    }

    private fun freshInfo(videoId: String): File? {
        val f = File(Engine.infoDir, "$videoId.json")
        return if (f.isFile && System.currentTimeMillis() - f.lastModified() < INFO_MAX_AGE_MS) f else null
    }

    // Tubería en tres etapas para que ninguna espere a otra: preparar (info, limitada por InfoBatcher),
    // descargar (red) y convertir (CPU, un ffmpeg por núcleo). Con cientos de canciones, mientras unas se
    // convierten otras ya se descargan y otras se preparan.
    private class Exec(val prep: (Runnable) -> Unit, val net: (Runnable) -> Unit, val cpu: (Runnable) -> Unit)

    private val prepPool = Executors.newFixedThreadPool(16)
    private val netPool = Executors.newFixedThreadPool(3)
    private val cpuPool = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors().coerceIn(2, 8))
    private val pipeline = Exec({ prepPool.execute(it) }, { netPool.execute(it) }, { cpuPool.execute(it) })
    private val inline = Exec({ it.run() }, { it.run() }, { it.run() })

    private fun simpleSel(sel: String) = !sel.contains('/') && !sel.contains('[')

    private fun runItem(ctx: Context, job: Job, it: Item, ex: Exec = pipeline) =
        ex.prep(Runnable { stage(ctx, job, it) { prepare(ctx, job, it, ex) } })

    /** Ejecuta una etapa. `block` devuelve true si pasó el item a la etapa siguiente; si no, el item terminó. */
    private fun stage(ctx: Context, job: Job, it: Item, block: () -> Boolean) {
        var handedOver = false
        try {
            if (it.canceled || job.canceled) {
                markCanceled(job, it)
            } else {
                handedOver = block()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "stage ${it.videoId}", e)
            it.status = "error"
            it.error = "unknown"
            it.message = e.message
            it.speed = 0.0
            emitItem(job, it, true)
        } finally {
            if (!handedOver && job.pending.decrementAndGet() == 0) finisher.execute { finish(ctx, job) }
        }
    }

    private fun markCanceled(job: Job, it: Item) {
        it.status = "canceled"
        it.speed = 0.0
        emitItem(job, it, true)
    }

    private fun prepare(ctx: Context, job: Job, it: Item, ex: Exec): Boolean {
        Engine.ensure(ctx)
        val dir = File(ctx.cacheDir, "dl/${job.id}/${it.itemId}").apply {
            deleteRecursively()
            mkdirs()
        }
        it.dir = dir
        it.status = "fetching"
        emitItem(job, it, true)
        it.tStart = System.currentTimeMillis()
        var info = freshInfo(it.videoId)
        if (info == null) {
            val r = InfoBatcher.get(it.videoId)
            info = freshInfo(it.videoId)
            if (info == null && r.code != null && r.code in Errors.DEFINITIVE) {
                it.status = "error"
                it.error = r.code
                it.message = r.message
                emitItem(job, it, true)
                return false
            }
        }
        it.tInfo = System.currentTimeMillis()
        it.info = info
        val sel = it.sel ?: info?.let { f -> FastDownload.pick(f, job.format, job.quality) } ?: genericSel(job.format, job.quality)
        it.selected = sel
        it.status = "queued"
        emitItem(job, it, true)
        if (info != null && simpleSel(sel)) ex.net(Runnable { stage(ctx, job, it) { download(ctx, job, it, ex) } })
        else ex.cpu(Runnable { stage(ctx, job, it) { slow(job, it) } })
        return true
    }

    private fun download(ctx: Context, job: Job, it: Item, ex: Exec): Boolean {
        val dir = it.dir!!
        val info = it.info!!
        val sel = it.selected!!
        it.status = "downloading"
        emitItem(job, it, true)
        val t0 = System.currentTimeMillis()
        var fastBytes = 0L
        try {
            fastBytes = FastDownload.run(info, it.videoId, sel, dir, { it.canceled || job.canceled }) { done, total, bps ->
                it.status = "downloading"
                it.pct = if (total > 0) done.toDouble() / total * 85.0 else 0.0
                it.speed = bps
                it.dlBytes = done
                emitItem(job, it)
            }
        } catch (e: FastDownload.Canceled) {
            markCanceled(job, it)
            return false
        } catch (e: Exception) {
            Log.w(TAG, "fast path ${it.videoId}: ${e.message}")
            dir.listFiles()?.forEach { f -> f.deleteRecursively() }
        }
        it.fastBytes = fastBytes
        // La portada se baja aquí (red) para que la etapa de CPU solo convierta
        if (fastBytes > 0 && (job.format == "mp3" || job.format == "m4a")) it.cover = Convert.cover(it.videoId, dir)
        it.tDownload = System.currentTimeMillis()
        if (fastBytes > 0) {
            it.dlBytes = fastBytes
            it.dlMs = it.tDownload - t0
        }
        it.status = "queued"
        it.pct = if (fastBytes > 0) 85.0 else 0.0
        it.speed = 0.0
        emitItem(job, it, true)
        ex.cpu(Runnable { stage(ctx, job, it) { if (fastBytes > 0 && Convert.available) convert(job, it) else slow(job, it) } })
        return true
    }

    private fun convert(job: Job, it: Item): Boolean {
        val direct = try {
            convertDirect(job, it, it.info!!, it.selected!!, it.dir!!)
        } catch (e: Convert.Canceled) {
            markCanceled(job, it)
            return false
        } catch (e: Exception) {
            Log.w(TAG, "direct convert ${it.videoId}: ${e.message}")
            null
        }
        if (direct == null) return slow(job, it)
        complete(job, it, direct, viaDirect = true)
        return false
    }

    /** Descarga y conversión completas con yt-dlp: el camino de siempre cuando el rápido no se puede. */
    private fun slow(job: Job, it: Item): Boolean {
        val dir = it.dir!!
        val info = it.info
        val sel = it.selected ?: genericSel(job.format, job.quality)
        if (it.tDownload == 0L) it.tDownload = System.currentTimeMillis()
        val streams = sel.substringBefore('/').count { c -> c == '+' } + 1
        val base = listOf(
            "--no-playlist", "--newline", "--progress", "--no-colors", "--no-mtime", "--no-warnings",
            "--progress-template", "download:$PROGRESS%(progress)j",
            "--progress-template", "postprocess:$PP%(progress.status)s",
            "--retries", "3", "--fragment-retries", "3", "--http-chunk-size", "10M",
            // Nombre fijo: así yt-dlp encuentra lo que bajó la descarga directa; al final se renombra con el título
            "-o", "${dir.absolutePath}/media.%(ext)s",
            "--concurrent-fragments", "4",
        )

        fun attempt(sel: String, embedThumb: Boolean, info: File?): Engine.Result {
            var fmt = formatArgs(job.format, job.quality)
            if (!embedThumb) fmt = fmt.filterNot { a -> a == "--embed-thumbnail" || a == "--convert-thumbnails" || a == "jpg" }
            val target = if (info != null) listOf("--load-info-json", info.absolutePath) else listOf("--", "https://www.youtube.com/watch?v=${it.videoId}")
            val tracker = Progress(streams, it.bytes)
            val pid = "dl-${job.id}-${it.itemId}-" + UUID.randomUUID().toString().take(8)
            it.procId = pid
            val r = Engine.runWithSession(base + fmt + listOf("-f", sel) + target, pid, canceled = { it.canceled }) { line ->
                when {
                    line.startsWith(PROGRESS) -> {
                        val p = try {
                            JSONObject(line.substring(PROGRESS.length))
                        } catch (_: Exception) {
                            null
                        }
                        if (p != null) {
                            tracker.update(p)
                            it.status = "downloading"
                            it.pct = tracker.pct()
                            it.speed = p.optDouble("speed", 0.0).let { s -> if (s.isNaN()) 0.0 else s }
                            emitItem(job, it)
                        }
                    }
                    line.startsWith(PP) -> {
                        if (it.status != "converting") {
                            it.status = "converting"
                            it.pct = maxOf(it.pct, 85.0)
                            it.speed = 0.0
                            emitItem(job, it, true)
                        } else if (it.pct < 99) {
                            it.pct = minOf(99.0, it.pct + 2)
                            emitItem(job, it)
                        }
                    }
                }
            }
            it.procId = null
            return r
        }

        var r = attempt(sel, true, info)
        if (!r.ok && !r.canceled && !it.canceled) {
            val code = Errors.classify(r.err)
            if (code !in Errors.DEFINITIVE) {
                Log.i(TAG, "retry ${it.videoId}: $code")
                dir.listFiles()?.forEach { f -> f.deleteRecursively() }
                // Info nueva (las URLs pudieron caducar) y, si el formato ya no está, el selector genérico
                val retrySel = if (code == "formatUnavailable") genericSel(job.format, job.quality) else sel
                r = attempt(retrySel, true, null)
                if (!r.ok && !r.canceled && !it.canceled && r.err.contains("thumbnail", true)) {
                    dir.listFiles()?.forEach { f -> f.deleteRecursively() }
                    r = attempt(retrySel, false, null)
                }
            }
        }
        if (r.canceled || it.canceled) {
            markCanceled(job, it)
            return false
        }
        val out = finalFile(dir, job.format)
        if (!r.ok || out == null) {
            it.status = "error"
            it.error = if (r.ok) "storage" else Errors.classify(r.err)
            it.message = r.err.lineSequence().lastOrNull { l -> l.contains("ERROR") }?.take(300)
            Log.w(TAG, "item failed ${it.videoId}: ${r.err.takeLast(600)}")
            emitItem(job, it, true)
            return false
        }
        complete(job, it, out, viaDirect = false)
        return false
    }

    private fun complete(job: Job, it: Item, out: File, viaDirect: Boolean) {
        val dir = it.dir!!
        val title = it.title ?: it.info?.let { f -> runCatching { JSONObject(f.readText()).optString("title") }.getOrNull() }
        val named = File(dir, safeName(title?.ifBlank { null } ?: it.videoId) + "." + out.extension)
        it.file = if (out.renameTo(named)) named else out
        val tEnd = System.currentTimeMillis()
        it.convMs = tEnd - it.tDownload
        it.timing = "info ${it.tInfo - it.tStart} ms · descarga ${it.tDownload - it.tInfo} ms" +
            (if (it.fastBytes > 0) " (directa, ${it.fastBytes / 1024} KB, %.2f MB/s)".format(it.fastBytes / (it.dlMs.coerceAtLeast(1) / 1000.0) / 1e6) else " (yt-dlp)") +
            (if (viaDirect) " · ffmpeg ${it.convMs} ms (%.0f× tiempo real)".format(it.conv) else " · yt-dlp + ffmpeg ${it.convMs} ms") +
            " · total ${tEnd - it.tStart} ms"
        Log.i(TAG, "timing ${it.videoId}: ${it.timing}")
        it.status = "done"
        it.pct = 100.0
        it.speed = 0.0
        emitItem(job, it, true)
    }

    /** Convierte con una llamada a ffmpeg lo que bajó FastDownload. `null` si no se pudo (se usa yt-dlp). */
    private fun convertDirect(job: Job, it: Item, info: File, sel: String, dir: File): File? {
        val j = JSONObject(info.readText())
        val formats = j.optJSONArray("formats") ?: return null
        fun fmt(id: String): JSONObject? = (0 until formats.length()).mapNotNull { i -> formats.optJSONObject(i) }.lastOrNull { f -> f.optString("format_id") == id }
        val ids = sel.split('+')
        val fs = ids.map { id -> fmt(id) ?: return null }
        val inputs = if (ids.size > 1) ids.mapIndexed { i, id -> File(dir, "media.f$id.${fs[i].optString("ext")}") }
        else listOf(File(dir, "media.${fs[0].optString("ext")}"))
        if (inputs.any { f -> !f.isFile }) return null
        val transcode = job.format == "m4a" && !fs.last().optString("acodec").startsWith("mp4a")
        val title = it.title ?: j.optString("title").ifEmpty { null }
        val artist = it.author ?: j.optString("channel").ifEmpty { null } ?: j.optString("uploader").ifEmpty { null }
        val duration = j.optDouble("duration", 0.0).let { d -> if (d.isNaN()) 0.0 else d }
        val out = File(dir, "out.${job.format}")
        it.status = "converting"
        it.pct = 85.0
        it.speed = 0.0
        emitItem(job, it, true)
        val cover = it.cover
        for (tryCover in listOf(true, false)) {
            if (!tryCover && cover == null) break
            val c = if (tryCover) cover else null
            val res = Convert.run(Convert.args(job.format, job.quality, inputs, c, title, artist, transcode, out), duration, { it.canceled || job.canceled }) { frac, x ->
                it.pct = 85.0 + 14.0 * frac
                if (x > 0) it.conv = x
                emitItem(job, it)
            }
            if (res.ok && out.isFile && out.length() > 0) {
                inputs.forEach { f -> f.delete() }
                cover?.delete()
                return out
            }
            Log.w(TAG, "ffmpeg ${it.videoId} (portada=$tryCover): ${res.err.take(500)}")
            out.delete()
            if (c == null) break
        }
        cover?.delete()
        return null
    }

    /** «21 nov 2026, 2.05 p. m.» para el nombre del ZIP (sin «:», que Windows no admite). */
    private fun friendlyStamp(d: Date): String {
        val c = java.util.Calendar.getInstance().apply { time = d }
        val months = arrayOf("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
        val h24 = c.get(java.util.Calendar.HOUR_OF_DAY)
        val h = if (h24 % 12 == 0) 12 else h24 % 12
        val m = c.get(java.util.Calendar.MINUTE).toString().padStart(2, '0')
        return "${c.get(java.util.Calendar.DAY_OF_MONTH)} ${months[c.get(java.util.Calendar.MONTH)]} ${c.get(java.util.Calendar.YEAR)}, $h.$m ${if (h24 < 12) "a. m." else "p. m."}"
    }

    /** Nombre de archivo válido también en Windows (mismos reemplazos que --windows-filenames de yt-dlp). */
    fun safeName(title: String): String {
        val map = mapOf(':' to '：', '/' to '⧸', '\\' to '⧹', '?' to '？', '*' to '＊', '"' to '＂', '<' to '＜', '>' to '＞', '|' to '｜')
        var s = title.map { c -> map[c] ?: if (c.code < 32) ' ' else c }.joinToString("").replace(Regex("\\s+"), " ").trim().trimEnd('.')
        while (s.toByteArray().size > 150) s = s.dropLast(1)
        return s.ifEmpty { "Setube" }
    }

    /** Descarga de prueba para el diagnóstico (no guarda nada): devuelve los tiempos de cada fase. */
    fun benchmark(ctx: Context, videoId: String, format: String, quality: Int?): String {
        val item = Item(UUID.randomUUID().toString(), videoId, null, null, null, null, false)
        val job = Job("bench-" + UUID.randomUUID(), format, quality, listOf(item), dryRun = true)
        runItem(ctx, job, item, inline)
        return if (item.status == "done") (item.timing ?: "ok") else "falló: ${item.error} ${item.message ?: ""}"
    }

    private fun finalFile(dir: File, format: String): File? {
        val files = dir.listFiles()?.filter { f ->
            f.isFile && !f.name.endsWith(".part") && !f.name.endsWith(".ytdl") && !f.name.endsWith(".json") &&
                f.extension.lowercase() !in setOf("jpg", "jpeg", "png", "webp")
        } ?: return null
        return files.firstOrNull { f -> f.extension.equals(format, true) } ?: files.maxByOrNull { f -> f.length() }
    }

    private fun finish(ctx: Context, job: Job) {
        if (job.dryRun) {
            File(ctx.cacheDir, "dl/${job.id}").deleteRecursively()
            return
        }
        val done = job.items.filter { it.status == "done" && it.file != null }
        try {
            if (done.isNotEmpty()) {
                val saved: Saver.Saved
                val kind: String
                if (job.items.size > 1 && done.size > 1) {
                    val noun = if (job.format == "mp4") "videos" else "canciones"
                    saved = Saver.saveZip(ctx, done.map { it.file!! to it.file!!.name }, "Setube - ${done.size} $noun del ${friendlyStamp(Date())}.zip")
                    kind = "zip"
                } else {
                    val f = done.first().file!!
                    saved = Saver.saveFile(ctx, f, f.name)
                    kind = "file"
                }
                val entry = JSONObject()
                    .put("id", UUID.randomUUID().toString())
                    .put("createdAt", System.currentTimeMillis())
                    .put("kind", kind)
                    .put("name", saved.name)
                    .put("uri", saved.uri.toString())
                    .put("relativePath", saved.relativePath)
                    .put("mime", saved.mime)
                    .put("bytes", saved.bytes)
                    .put("format", job.format)
                    .put("quality", job.quality ?: JSONObject.NULL)
                    .put("count", done.size)
                    .put("failed", job.items.count { it.status == "error" })
                    .put("items", JSONArray().apply {
                        for (it in done) put(JSONObject().put("videoId", it.videoId).put("title", it.title ?: JSONObject.NULL).put("author", it.author ?: JSONObject.NULL))
                    })
                History.add(ctx, entry)
                job.entry = entry
                job.status = "done"
                Notifications.done(ctx, saved, done.size)
            } else {
                job.status = if (job.canceled || job.items.all { it.status == "canceled" }) "canceled" else "failed"
                if (job.status == "failed") Notifications.failed(ctx, job.items.size)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "finish", e)
            job.status = "failed"
            for (it in done) {
                it.status = "error"
                it.error = "storage"
                emitItem(job, it, true)
            }
        } finally {
            File(ctx.cacheDir, "dl/${job.id}").deleteRecursively()
            emit(mapOf("type" to "job", "jobId" to job.id, "status" to job.status, "entry" to job.entry?.toString()))
            // Se conserva un rato para que la app pueda reengancharse; después se olvida
            main.postDelayed({ jobs.remove(job.id) }, 10 * 60 * 1000L)
            DownloadService.update()
        }
    }

    fun running(): Boolean = jobs.values.any { it.status == "active" }

    fun overall(): Triple<Int, Int, Double> {
        val act = jobs.values.filter { it.status == "active" }.flatMap { it.items }
        if (act.isEmpty()) return Triple(0, 0, 0.0)
        val finished = act.count { it.status in setOf("done", "error", "canceled") }
        return Triple(finished, act.size, act.sumOf { if (it.status in setOf("error", "canceled")) 100.0 else it.pct } / act.size)
    }

    /** Progreso combinado de las descargas de un item (video + audio en mp4). 0–85 % descarga, 85–100 % conversión. */
    class Progress(private val streams: Int, private val expected: Long?) {
        private val order = ArrayList<String>()
        private val done = HashMap<String, Long>()
        private val total = HashMap<String, Long>()

        fun update(p: JSONObject) {
            val name = p.optString("filename", p.optString("tmpfilename", "?"))
            if (name !in order) order += name
            val d = p.optLong("downloaded_bytes", 0)
            val t = if (p.has("total_bytes") && !p.isNull("total_bytes")) p.optLong("total_bytes")
            else p.optDouble("total_bytes_estimate", 0.0).let { if (it.isNaN()) 0L else it.toLong() }
            done[name] = d
            if (t > 0) total[name] = t
            if (p.optString("status") == "finished") total[name] = maxOf(d, total[name] ?: 0)
        }

        fun pct(): Double {
            val sumDone = done.values.sum().toDouble()
            val frac = if (expected != null && expected > 0) {
                sumDone / expected
            } else {
                var f = 0.0
                for (n in order) {
                    val t = total[n] ?: 0
                    f += if (t > 0) (done[n] ?: 0).toDouble() / t else 0.0
                }
                f / maxOf(streams, order.size)
            }
            return (frac.coerceIn(0.0, 1.0) * 85.0)
        }
    }
}

class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    private var lastStartId = 0

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val n = Notifications.progress(this, Downloads.overall())
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, Notifications.PROGRESS_ID, n, type)
        if (!Downloads.running()) stopSelfSafely()
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 limita dataSync a 6 h al día: se cancela lo que quede
        for (j in Downloads.jobs.values) if (j.status == "active") Downloads.cancelJob(j.id)
        stopSelfSafely()
    }

    private fun stopSelfSafely() {
        // Con el último startId: si llegó otro start mientras tanto, el servicio sigue vivo
        if (stopSelfResult(lastStartId)) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile private var instance: DownloadService? = null
        private var lastUpdate = 0L
        private val main = Handler(Looper.getMainLooper())

        fun start(ctx: Context) {
            main.post {
                val i = Intent(ctx, DownloadService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
            }
        }

        fun update() {
            main.post {
                val s = instance ?: return@post
                if (!Downloads.running()) {
                    s.stopSelfSafely()
                    return@post
                }
                val now = System.currentTimeMillis()
                if (now - lastUpdate < 1000) return@post
                lastUpdate = now
                try {
                    NotificationManagerCompat.from(s).notify(Notifications.PROGRESS_ID, Notifications.progress(s, Downloads.overall()))
                } catch (_: SecurityException) {
                }
            }
        }
    }
}

object Notifications {
    const val PROGRESS_ID = 4100
    const val PC_ID = 4101
    const val CH_PROGRESS = "downloads"
    const val CH_DONE = "downloads_done"
    private val nextId = AtomicInteger(4200)

    fun channels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(android.app.NotificationManager::class.java)
        nm.createNotificationChannel(android.app.NotificationChannel(CH_PROGRESS, "Descargas en curso", android.app.NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(android.app.NotificationChannel(CH_DONE, "Descargas terminadas", android.app.NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun openApp(ctx: Context, route: String?): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (route != null) putExtra("route", route)
        }
        return PendingIntent.getActivity(ctx, route.hashCode(), i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun progress(ctx: Context, o: Triple<Int, Int, Double>): Notification {
        val (finished, total, pct) = o
        return NotificationCompat.Builder(ctx, CH_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_setube)
            .setContentTitle(if (total == 0) "Preparando descargas" else "Descargando $finished de $total")
            .setContentText("${pct.toInt()} %")
            .setProgress(100, pct.toInt(), total == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp(ctx, null))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    fun done(ctx: Context, s: Saver.Saved, count: Int) {
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(s.uri, s.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val share = Intent.createChooser(
            Intent(Intent.ACTION_SEND).setType(s.mime).putExtra(Intent.EXTRA_STREAM, s.uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            "Compartir",
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val id = nextId.incrementAndGet()
        val n = NotificationCompat.Builder(ctx, CH_DONE)
            .setSmallIcon(R.drawable.ic_stat_setube)
            .setContentTitle(if (count > 1) "Listo: ZIP con $count archivos" else "Listo")
            .setContentText(s.name)
            .setAutoCancel(true)
            .setContentIntent(openApp(ctx, "history"))
            .addAction(0, "Abrir", PendingIntent.getActivity(ctx, id, view, PendingIntent.FLAG_IMMUTABLE))
            .addAction(0, "Compartir", PendingIntent.getActivity(ctx, id + 1, share, PendingIntent.FLAG_IMMUTABLE))
            .build()
        notify(ctx, id, n)
    }

    fun failed(ctx: Context, count: Int) {
        val n = NotificationCompat.Builder(ctx, CH_DONE)
            .setSmallIcon(R.drawable.ic_stat_setube)
            .setContentTitle("No se pudo convertir")
            .setContentText(if (count > 1) "Ninguno de los $count videos terminó. Abre Setube para ver por qué." else "Abre Setube para ver por qué.")
            .setAutoCancel(true)
            .setContentIntent(openApp(ctx, null))
            .build()
        notify(ctx, nextId.incrementAndGet(), n)
    }

    fun notifyPublic(ctx: Context, n: Notification) = notify(ctx, nextId.incrementAndGet(), n)

    private fun notify(ctx: Context, id: Int, n: Notification) {
        try {
            NotificationManagerCompat.from(ctx).notify(id, n)
        } catch (_: SecurityException) {
        }
    }
}
