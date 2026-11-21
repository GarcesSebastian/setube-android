package com.sebxstt.setube

import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Cola única para extraer la info de videos con yt-dlp. Junta los videos en lotes (un proceso de yt-dlp para
 * varios, así Python, el reproductor de YouTube y los retos JS se cargan una vez por lote) y corre varios lotes
 * a la vez. Si la interfaz y las descargas piden el mismo video, se extrae una sola vez.
 */
object InfoBatcher {
    private const val TAG = "SetubeInfo"
    private const val BATCH = 8
    private const val PARALLEL = 4
    private const val WAIT_MIN = 10L

    private class Pending {
        val latch = CountDownLatch(1)
        @Volatile var result: Engine.Info? = null
    }

    private val lock = Any()
    private val queue = ArrayDeque<String>()
    private val waiting = HashMap<String, Pending>()
    private var running = 0
    private val pool = Executors.newCachedThreadPool()

    /** Encola sin esperar (lo que se va a necesitar pronto). */
    fun prefetch(ids: List<String>) {
        synchronized(lock) {
            for (id in ids) enqueueLocked(id, false)
            pumpLocked()
        }
    }

    fun get(id: String, priority: Boolean = false): Engine.Info = getAll(listOf(id), priority).first()

    fun getAll(ids: List<String>, priority: Boolean = false): List<Engine.Info> {
        val ps = synchronized(lock) {
            val l = ids.map { enqueueLocked(it, priority) }
            pumpLocked()
            l
        }
        return ids.mapIndexed { i, id ->
            val p = ps[i]
            if (!p.latch.await(WAIT_MIN, TimeUnit.MINUTES)) Engine.Info(id, null, "upstreamTimeout", "timeout")
            else p.result ?: Engine.Info(id, null, "upstreamError", null)
        }
    }

    private fun enqueueLocked(id: String, priority: Boolean): Pending {
        val existing = waiting[id]
        if (existing != null) {
            // Ya pedido: si ahora es urgente, pasa al principio de la cola (si aún no está en un lote)
            if (priority && queue.remove(id)) queue.addFirst(id)
            return existing
        }
        val p = Pending()
        waiting[id] = p
        if (priority) queue.addFirst(id) else queue.addLast(id)
        return p
    }

    private fun pumpLocked() {
        while (running < PARALLEL && queue.isNotEmpty()) {
            // Repartido entre los procesos libres: 9 videos con 4 procesos son 3+2+2+2, no 8+1. Dentro de un
            // proceso los videos van uno tras otro, así que lotes grandes con procesos parados es lo más lento.
            val free = PARALLEL - running
            val size = ((queue.size + free - 1) / free).coerceIn(1, BATCH)
            val batch = ArrayList<String>()
            while (batch.size < size && queue.isNotEmpty()) batch += queue.removeFirst()
            running++
            pool.execute { runBatch(batch) }
        }
    }

    private fun resolve(r: Engine.Info) {
        synchronized(lock) {
            val p = waiting.remove(r.id) ?: return
            p.result = r
            p.latch.countDown()
        }
    }

    private fun runBatch(batch: List<String>) {
        val results = try {
            // Cada video se entrega en cuanto yt-dlp lo tiene, sin esperar al resto del lote
            Engine.info(batch) { resolve(it) }
        } catch (e: Throwable) {
            Log.w(TAG, "batch", e)
            batch.map { Engine.Info(it, null, "upstreamError", e.message) }
        }
        synchronized(lock) {
            val byId = results.associateBy { it.id }
            for (id in batch) {
                val p = waiting.remove(id) ?: continue
                p.result = byId[id] ?: Engine.Info(id, null, "upstreamError", null)
                p.latch.countDown()
            }
            running--
            pumpLocked()
        }
    }
}
