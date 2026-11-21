package com.sebxstt.setube

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.math.BigInteger
import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipFile
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

/**
 * Envío al PC con el protocolo de LocalSend (v2): el PC solo necesita LocalSend abierto, con «Guardado rápido»
 * para que acepte sin preguntar. Descubre el PC en la Wi‑Fi (multicast y, si no responde, preguntando a cada IP
 * de la red) y le sube los archivos por HTTPS. Los ZIP se envían ya descomprimidos, en una carpeta por tanda.
 *
 * LocalSend exige un certificado de cliente (mTLS): se genera una vez en el Keystore de Android. El certificado del
 * PC es autofirmado; se acepta la primera vez y queda fijado al guardar el PC (si cambia, se avisa).
 */
object PcSend {
    private const val TAG = "SetubePc"
    const val PORT = 53317
    private const val GROUP = "224.0.0.167"
    private const val KEY_ALIAS = "setube_localsend"
    private const val PREFS = "setube_pc"

    data class Device(
        val alias: String,
        val ip: String,
        val port: Int,
        val fingerprint: String,
        val model: String?,
        val type: String?,
        val cert: String,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "alias" to alias, "ip" to ip, "port" to port, "fingerprint" to fingerprint, "model" to model, "type" to type,
        )

        fun toJson(): JSONObject = JSONObject().put("alias", alias).put("ip", ip).put("port", port).put("fingerprint", fingerprint)
            .put("model", model ?: JSONObject.NULL).put("type", type ?: JSONObject.NULL).put("cert", cert)

        companion object {
            fun fromJson(o: JSONObject) = Device(
                o.optString("alias"), o.optString("ip"), o.optInt("port", PORT), o.optString("fingerprint"),
                o.optString("model").ifEmpty { null }?.takeIf { it != "null" }, o.optString("type").ifEmpty { null }?.takeIf { it != "null" },
                o.optString("cert"),
            )
        }
    }

    // Identidad (certificado de cliente)

    @Volatile private var ssl: SSLContext? = null
    @Volatile private var myFingerprint = ""

    private fun hex(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02X".format(it) }

    @Synchronized
    private fun context(): SSLContext {
        ssl?.let { return it }
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(KEY_ALIAS)) {
            val now = System.currentTimeMillis()
            val g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            g.initialize(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(X500Principal("CN=Setube"))
                    .setCertificateSerialNumber(BigInteger(63, SecureRandom()).add(BigInteger.ONE))
                    .setCertificateNotBefore(Date(now - 86_400_000L))
                    .setCertificateNotAfter(Date(now + 25L * 365 * 86_400_000L))
                    .build(),
            )
            g.generateKeyPair()
        }
        val key = ks.getKey(KEY_ALIAS, null) as PrivateKey
        val cert = ks.getCertificate(KEY_ALIAS) as X509Certificate
        myFingerprint = hex(cert.encoded)
        val km = object : X509ExtendedKeyManager() {
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = KEY_ALIAS
            override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = KEY_ALIAS
            override fun getCertificateChain(alias: String?) = arrayOf(cert)
            override fun getPrivateKey(alias: String?) = key
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(KEY_ALIAS)
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
        }
        // El certificado del PC es autofirmado: se acepta aquí y se fija por huella (Device.cert)
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val c = SSLContext.getInstance("TLS")
        c.init(arrayOf(km), arrayOf(tm), SecureRandom())
        ssl = c
        return c
    }

    private fun alias() = "Setube (${Build.MODEL})"

    private fun myInfo(): JSONObject {
        context()
        return JSONObject().put("alias", alias()).put("version", "2.1").put("deviceModel", Build.MODEL).put("deviceType", "mobile")
            .put("fingerprint", myFingerprint).put("port", PORT).put("protocol", "https").put("download", false)
    }

    private fun open(ip: String, port: Int, path: String, connectMs: Int, readMs: Int): HttpsURLConnection {
        val c = URL("https://$ip:$port/api/localsend/v2/$path").openConnection() as HttpsURLConnection
        c.sslSocketFactory = context().socketFactory
        c.hostnameVerifier = HostnameVerifier { _, _ -> true }
        c.connectTimeout = connectMs
        c.readTimeout = readMs
        c.useCaches = false
        return c
    }

    private fun serverCert(c: HttpsURLConnection): String = try {
        hex(c.serverCertificates.first().encoded)
    } catch (_: Exception) {
        ""
    }

    /** POST /register: si en esa IP hay un LocalSend, devuelve el dispositivo. */
    private fun register(ip: String, port: Int = PORT, connectMs: Int = 700): Device? {
        return try {
            val c = open(ip, port, "register", connectMs, 2500)
            try {
                c.requestMethod = "POST"
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(myInfo().toString().toByteArray()) }
                if (c.responseCode != 200) return null
                val cert = serverCert(c)
                val j = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
                if (j.optString("fingerprint") == myFingerprint) return null
                Device(
                    j.optString("alias", ip), ip, port, j.optString("fingerprint"),
                    j.optString("deviceModel").ifEmpty { null }, j.optString("deviceType").ifEmpty { null }, cert,
                )
            } finally {
                c.disconnect()
            }
        } catch (_: Exception) {
            null
        }
    }

    // Descubrimiento

    private data class Lan(val address: Inet4Address, val prefix: Int)

    private fun lans(ctx: Context): List<Lan> {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val out = ArrayList<Lan>()
        @Suppress("DEPRECATION")
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            for (la in lp.linkAddresses) {
                val a = la.address
                if (a is Inet4Address && a.isSiteLocalAddress) out += Lan(a, la.prefixLength)
            }
        }
        return out
    }

    private fun hosts(lan: Lan): List<String> {
        // Redes muy grandes: solo el /24 propio
        val prefix = lan.prefix.coerceIn(22, 30)
        val b = lan.address.address
        val ip = ((b[0].toInt() and 255) shl 24) or ((b[1].toInt() and 255) shl 16) or ((b[2].toInt() and 255) shl 8) or (b[3].toInt() and 255)
        val mask = if (prefix == 0) 0 else -1 shl (32 - prefix)
        val net = ip and mask
        val count = 1 shl (32 - prefix)
        return (1 until count - 1).map { net + it }.filter { it != ip }.map {
            "${(it ushr 24) and 255}.${(it ushr 16) and 255}.${(it ushr 8) and 255}.${it and 255}"
        }
    }

    /** Busca LocalSend en la red durante ~4 s. Primero los PC. */
    fun discover(ctx: Context, timeoutMs: Long = 4000): List<Device> {
        context()
        val found = ConcurrentHashMap<String, Device>()
        val pool = Executors.newFixedThreadPool(48)
        val lanList = lans(ctx)
        val mc = Thread({ multicast(ctx, lanList, found, pool, timeoutMs) }, "setube-pc-mc").apply { start() }
        for (lan in lanList) for (h in hosts(lan)) pool.execute { register(h)?.let { found.putIfAbsent(it.ip, it) } }
        mc.join(timeoutMs + 1000)
        pool.shutdown()
        pool.awaitTermination(timeoutMs + 4000, TimeUnit.MILLISECONDS)
        pool.shutdownNow()
        return found.values.sortedWith(compareBy({ if (it.type == "desktop") 0 else 1 }, { it.alias.lowercase() }))
    }

    private fun multicast(ctx: Context, lanList: List<Lan>, found: ConcurrentHashMap<String, Device>, pool: java.util.concurrent.ExecutorService, timeoutMs: Long) {
        val wifi = ctx.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("setube-localsend")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        try {
            MulticastSocket(null).use { s ->
                s.reuseAddress = true
                s.bind(InetSocketAddress(PORT))
                val group = InetAddress.getByName(GROUP)
                for (lan in lanList) {
                    try {
                        s.joinGroup(InetSocketAddress(group, PORT), NetworkInterface.getByInetAddress(lan.address))
                    } catch (_: Exception) {
                    }
                }
                s.soTimeout = 400
                val msg = myInfo().put("announce", true).toString().toByteArray()
                val end = System.currentTimeMillis() + timeoutMs
                var sent = 0
                val buf = ByteArray(8192)
                while (System.currentTimeMillis() < end) {
                    if (sent < 3 && System.currentTimeMillis() >= end - timeoutMs + sent * 1200L) {
                        try {
                            s.send(DatagramPacket(msg, msg.size, group, PORT))
                        } catch (_: Exception) {
                        }
                        sent++
                    }
                    try {
                        val p = DatagramPacket(buf, buf.size)
                        s.receive(p)
                        val j = JSONObject(String(p.data, 0, p.length))
                        if (j.optString("fingerprint") == myFingerprint) continue
                        val ip = p.address.hostAddress ?: continue
                        if (!found.containsKey(ip)) {
                            val port = j.optInt("port", PORT)
                            pool.execute { register(ip, port, 1500)?.let { found.putIfAbsent(it.ip, it) } }
                        }
                    } catch (_: SocketTimeoutException) {
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "multicast: ${e.message}")
        } finally {
            lock?.release()
        }
    }

    // PC guardado

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun favorite(ctx: Context): Device? = prefs(ctx).getString("device", null)?.let {
        try {
            Device.fromJson(JSONObject(it))
        } catch (_: Exception) {
            null
        }
    }

    fun setFavorite(ctx: Context, d: Device?) {
        val e = prefs(ctx).edit()
        if (d == null) e.remove("device") else e.putString("device", d.toJson().toString())
        e.apply()
    }

    fun autoSend(ctx: Context) = prefs(ctx).getBoolean("auto", false)
    fun setAutoSend(ctx: Context, on: Boolean) = prefs(ctx).edit().putBoolean("auto", on).apply()

    /** El PC guardado, en su IP actual (si cambió por DHCP se vuelve a buscar por su huella). */
    fun reachFavorite(ctx: Context): Device? {
        val fav = favorite(ctx) ?: return null
        register(fav.ip, fav.port, 2000)?.let { d -> if (d.fingerprint == fav.fingerprint || fav.fingerprint.isEmpty()) return update(ctx, fav, d) }
        val again = discover(ctx).firstOrNull { it.fingerprint == fav.fingerprint && fav.fingerprint.isNotEmpty() } ?: return null
        return update(ctx, fav, again)
    }

    private fun update(ctx: Context, fav: Device, now: Device): Device {
        val merged = now.copy(alias = now.alias, cert = fav.cert.ifEmpty { now.cert })
        if (merged != fav) setFavorite(ctx, merged)
        return merged
    }

    // Envío

    class Source(val name: String, val size: Long, val mime: String, val open: () -> InputStream)

    class Failed(val code: String, msg: String) : Exception(msg)

    @Volatile private var cancelFlag = false
    @Volatile private var current: Pair<Device, String>? = null

    fun cancel() {
        cancelFlag = true
    }

    /**
     * Sube `sources` al PC. `onProgress(bytesEnviados, bytesTotales, archivosListos, archivos)`.
     * Lanza [Failed] con `rejected`, `busy`, `pin`, `pc_changed`, `canceled` o `error`.
     */
    fun send(d: Device, sources: List<Source>, onProgress: (Long, Long, Int, Int) -> Unit) {
        cancelFlag = false
        val ids = sources.map { UUID.randomUUID().toString() }
        val files = JSONObject()
        for ((i, s) in sources.withIndex()) {
            files.put(ids[i], JSONObject().put("id", ids[i]).put("fileName", s.name).put("size", s.size).put("fileType", s.mime))
        }
        // Puede esperar a que alguien acepte en el PC (sin «Guardado rápido»)
        val prep = open(d.ip, d.port, "prepare-upload", 5000, 5 * 60_000)
        val session: String
        val tokens: JSONObject
        try {
            prep.requestMethod = "POST"
            prep.doOutput = true
            prep.setRequestProperty("Content-Type", "application/json")
            prep.outputStream.use { it.write(JSONObject().put("info", myInfo()).put("files", files).toString().toByteArray()) }
            val code = prep.responseCode
            if (d.cert.isNotEmpty() && serverCert(prep).let { it.isNotEmpty() && it != d.cert }) throw Failed("pc_changed", "certificado distinto")
            when (code) {
                200 -> {}
                204 -> return
                401 -> throw Failed("pin", "PIN")
                403 -> throw Failed("rejected", "rechazado")
                409 -> throw Failed("busy", "ocupado")
                else -> throw Failed("error", "HTTP $code")
            }
            val j = JSONObject(prep.inputStream.bufferedReader().use { it.readText() })
            session = j.getString("sessionId")
            tokens = j.getJSONObject("files")
        } finally {
            prep.disconnect()
        }
        current = d to session
        val total = sources.sumOf { it.size }
        val sent = AtomicLong(0)
        val done = java.util.concurrent.atomic.AtomicInteger(0)
        var last = 0L
        val pool = Executors.newFixedThreadPool(3)
        val error = java.util.concurrent.atomic.AtomicReference<Exception?>(null)
        try {
            for ((i, s) in sources.withIndex()) {
                val token = tokens.optString(ids[i]).ifEmpty { null } ?: continue
                pool.execute {
                    if (error.get() != null || cancelFlag) return@execute
                    try {
                        val q = "upload?sessionId=${enc(session)}&fileId=${enc(ids[i])}&token=${enc(token)}"
                        val c = open(d.ip, d.port, q, 5000, 60_000)
                        try {
                            c.requestMethod = "POST"
                            c.doOutput = true
                            c.setFixedLengthStreamingMode(s.size)
                            c.setRequestProperty("Content-Type", "application/octet-stream")
                            s.open().use { input ->
                                c.outputStream.use { out ->
                                    val buf = ByteArray(1 shl 16)
                                    while (true) {
                                        if (cancelFlag) throw Failed("canceled", "cancelado")
                                        val n = input.read(buf)
                                        if (n < 0) break
                                        out.write(buf, 0, n)
                                        val now = sent.addAndGet(n.toLong())
                                        val t = System.currentTimeMillis()
                                        if (t - last > 300) {
                                            last = t
                                            onProgress(now, total, done.get(), sources.size)
                                        }
                                    }
                                }
                            }
                            if (c.responseCode !in 200..299) throw Failed("error", "HTTP ${c.responseCode} en ${s.name}")
                        } finally {
                            c.disconnect()
                        }
                        onProgress(sent.get(), total, done.incrementAndGet(), sources.size)
                    } catch (e: Exception) {
                        error.compareAndSet(null, e)
                    }
                }
            }
            pool.shutdown()
            pool.awaitTermination(6, TimeUnit.HOURS)
        } finally {
            pool.shutdownNow()
            current = null
        }
        val e = error.get() ?: if (cancelFlag) Failed("canceled", "cancelado") else null
        if (e != null) {
            cancelSession(d, session)
            throw if (e is Failed) e else Failed("error", e.message ?: e.javaClass.simpleName)
        }
    }

    private fun cancelSession(d: Device, session: String) {
        try {
            val c = open(d.ip, d.port, "cancel?sessionId=${enc(session)}", 3000, 3000)
            c.requestMethod = "POST"
            c.responseCode
            c.disconnect()
        } catch (_: Exception) {
        }
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    /** Nombre de carpeta válido en Windows: sin los caracteres que no admite ni puntos o espacios al final. */
    fun cleanFolder(raw: String?): String? {
        val s = (raw ?: "").map { c -> if (c in "\\/:*?\"<>|" || c.code < 32) ' ' else c }.joinToString("")
            .replace(Regex("\\s+"), " ").trim('.', ' ').take(120).trim('.', ' ')
        return s.ifEmpty { null }?.takeIf { it != "." && it != ".." }
    }

    /**
     * Lo que hay que enviar de una entrada del registro, dentro de la carpeta `pcFolder` que eligió el usuario (o la
     * de la tanda). Un ZIP se copia a la caché y se envían sus canciones sueltas en esa carpeta, no el ZIP: en el PC
     * quedan los MP3 listos, sin descomprimir. `cleanup` borra la copia.
     */
    fun sourcesFor(ctx: Context, entry: JSONObject): Pair<List<Source>, () -> Unit> {
        val uri = Uri.parse(entry.optString("uri"))
        val name = entry.optString("name")
        val cr = ctx.contentResolver
        val folder = cleanFolder(entry.optString("pcFolder").takeIf { !entry.isNull("pcFolder") })
            ?: cleanFolder(name.removeSuffix(".zip").takeIf { entry.optString("kind") == "zip" })
        fun inFolder(file: String) = if (folder != null) "$folder/$file" else file
        if (entry.optString("kind") != "zip") {
            var size = entry.optLong("bytes", 0)
            if (size <= 0) cr.openAssetFileDescriptor(uri, "r")?.use { size = it.length }
            return listOf(Source(inFolder(name), size, entry.optString("mime", "application/octet-stream")) { cr.openInputStream(uri)!! }) to {}
        }
        val tmp = File(ctx.cacheDir, "pc-" + UUID.randomUUID() + ".zip")
        cr.openInputStream(uri)!!.use { i -> tmp.outputStream().use { i.copyTo(it, 1 shl 17) } }
        val zf = ZipFile(tmp)
        val list = zf.entries().asSequence().filter { !it.isDirectory && it.size > 0 }.map { e ->
            Source(inFolder(e.name.substringAfterLast('/')), e.size, Saver.mimeOf(e.name.substringAfterLast('.'))) { zf.getInputStream(e) }
        }.toList()
        return list to {
            try {
                zf.close()
            } catch (_: Exception) {
            }
            tmp.delete()
        }
    }
}
