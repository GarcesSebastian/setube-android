package com.sebxstt.setube

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Registro de descargas guardadas (archivo o ZIP), de la más reciente a la más antigua. */
object History {
    private const val MAX = 1000
    private val lock = Any()

    private fun file(ctx: Context) = File(ctx.filesDir, "history.json")

    fun list(ctx: Context): JSONArray = synchronized(lock) {
        val f = file(ctx)
        if (!f.isFile) return JSONArray()
        try {
            JSONArray(f.readText())
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun write(ctx: Context, arr: JSONArray) {
        val f = file(ctx)
        val tmp = File(f.path + ".tmp")
        tmp.writeText(arr.toString())
        tmp.renameTo(f)
    }

    fun add(ctx: Context, entry: JSONObject) = synchronized(lock) {
        val old = list(ctx)
        val arr = JSONArray().put(entry)
        for (i in 0 until minOf(old.length(), MAX - 1)) arr.put(old.get(i))
        write(ctx, arr)
    }

    fun remove(ctx: Context, id: String): JSONObject? = synchronized(lock) {
        val old = list(ctx)
        val arr = JSONArray()
        var removed: JSONObject? = null
        for (i in 0 until old.length()) {
            val e = old.optJSONObject(i) ?: continue
            if (e.optString("id") == id) removed = e else arr.put(e)
        }
        write(ctx, arr)
        removed
    }

    fun clear(ctx: Context) = synchronized(lock) { write(ctx, JSONArray()) }
}
