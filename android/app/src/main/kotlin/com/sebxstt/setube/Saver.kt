package com.sebxstt.setube

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Guarda los archivos terminados en las carpetas públicas: Music/Setube, Movies/Setube y Download/Setube. */
object Saver {
    data class Saved(val uri: Uri, val name: String, val relativePath: String, val bytes: Long, val mime: String)

    fun mimeOf(ext: String) = when (ext.lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "wav" -> "audio/wav"
        "mp4" -> "video/mp4"
        "zip" -> "application/zip"
        "webm" -> "video/webm"
        "opus", "ogg" -> "audio/ogg"
        else -> "application/octet-stream"
    }

    private fun target(mime: String): Pair<Uri, String> = when {
        mime.startsWith("audio/") -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to
            "${Environment.DIRECTORY_MUSIC}/Setube"
        mime.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to
            "${Environment.DIRECTORY_MOVIES}/Setube"
        else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to
            "${Environment.DIRECTORY_DOWNLOADS}/Setube"
    }

    private fun create(ctx: Context, name: String, mime: String, write: (java.io.OutputStream) -> Unit): Saved {
        val (collection, rel) = target(mime)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val cr = ctx.contentResolver
        val uri = cr.insert(collection, values) ?: throw IllegalStateException("insert failed")
        try {
            cr.openOutputStream(uri)?.use(write) ?: throw IllegalStateException("no output stream")
            cr.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            cr.delete(uri, null, null)
            throw e
        }
        var finalName = name
        var size = 0L
        cr.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                finalName = c.getString(0) ?: name
                size = c.getLong(1)
            }
        }
        return Saved(uri, finalName, rel, size, mime)
    }

    fun saveFile(ctx: Context, src: File, name: String): Saved {
        val mime = mimeOf(src.extension)
        return create(ctx, name, mime) { out -> FileInputStream(src).use { it.copyTo(out, 1 shl 16) } }
    }

    /**
     * ZIP sin compresión (el audio y el video ya van comprimidos). Con DEFLATE de nivel 0 el CRC se calcula al
     * escribir, así cada archivo se lee una sola vez (con cientos de canciones, la mitad de lectura).
     */
    fun saveZip(ctx: Context, files: List<Pair<File, String>>, name: String): Saved {
        val used = HashSet<String>()
        return create(ctx, name, "application/zip") { out ->
            ZipOutputStream(out.buffered(1 shl 17)).use { zip ->
                zip.setLevel(Deflater.NO_COMPRESSION)
                for ((f, wanted) in files) {
                    zip.putNextEntry(ZipEntry(unique(wanted, used)).apply { time = System.currentTimeMillis() })
                    FileInputStream(f).use { it.copyTo(zip, 1 shl 17) }
                    zip.closeEntry()
                }
            }
        }
    }

    private fun unique(name: String, used: MutableSet<String>): String {
        if (used.add(name.lowercase())) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 2
        while (true) {
            val n = "$base ($i)$ext"
            if (used.add(n.lowercase())) return n
            i++
        }
    }

    fun exists(ctx: Context, uri: Uri): Boolean = try {
        ctx.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.moveToFirst() } ?: false
    } catch (_: Exception) {
        false
    }

    fun delete(ctx: Context, uri: Uri): Boolean = try {
        ctx.contentResolver.delete(uri, null, null) > 0
    } catch (_: Exception) {
        false
    }
}
