package com.bishal.deskdrop

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

data class DiscoveredMac(
    val host: String,
    val port: Int,
    val name: String,
    val certFingerprint: String,
    val shortFingerprint: String,
    val pairingActive: Boolean
)

sealed class MacCheckResult {
    data class Online(val mac: PairedMac) : MacCheckResult()
    data object Revoked : MacCheckResult()
    data object Unreachable : MacCheckResult()
}

object DeskDropClient {
    private const val SERVICE_TYPE = "_deskdrop._tcp."
    private val secureRandom = SecureRandom()

    fun fetchMacInfo(host: String, port: Int, timeoutMs: Int = 1800): DiscoveredMac? {
        return try {
            val capturedFingerprint = AtomicReference<String?>(null)
            val url = URL("https://$host:$port/info")
            val conn = (url.openConnection() as HttpsURLConnection).apply {
                sslSocketFactory = buildCapturingSocketFactory(capturedFingerprint)
                hostnameVerifier = HostnameVerifier { _, _ -> true }
                requestMethod = "GET"
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
            }
            try {
                if (conn.responseCode == 200) {
                    val body = conn.inputStream.bufferedReader().readText()
                    val json = JSONObject(body)
                    val fp = capturedFingerprint.get() ?: return null
                    if (json.optString("app") == "DeskDrop") {
                        DiscoveredMac(
                            host = host,
                            port = json.optInt("port", port),
                            name = json.optString("name", "Mac"),
                            certFingerprint = fp,
                            shortFingerprint = json.optString("fp", formatShortFp(fp)),
                            pairingActive = json.optBoolean("pairing", false)
                        )
                    } else null
                } else null
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            null
        }
    }

    fun pairWithMac(
        context: Context,
        host: String,
        port: Int,
        expectedFingerprint: String,
        code: String
    ): Result<PairedMac> {
        return try {
            val deviceName = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
            val bodyJson = JSONObject().apply {
                put("code", code.trim())
                put("deviceName", deviceName)
            }.toString().toByteArray(Charsets.UTF_8)

            val url = URL("https://$host:$port/pair")
            val conn = openPinnedConnection(url, expectedFingerprint, timeoutMs = 4000).apply {
                requestMethod = "POST"
                doOutput = true
                setFixedLengthStreamingMode(bodyJson.size)
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }

            try {
                conn.outputStream.use { it.write(bodyJson) }
                val codeResp = conn.responseCode
                val respText = if (codeResp in 200..299) {
                    conn.inputStream.bufferedReader().readText()
                } else {
                    conn.errorStream?.bufferedReader()?.readText() ?: ""
                }

                if (codeResp in 200..299) {
                    val obj = JSONObject(respText)
                    val paired = PairedMac(
                        host = host,
                        port = port,
                        name = obj.optString("name", "Mac"),
                        certFingerprint = expectedFingerprint.lowercase(),
                        deviceId = obj.getString("deviceId"),
                        tokenHex = obj.getString("token"),
                        knownEndpoints = listOf("$host:$port")
                    )
                    DeskDropPrefs.savePairedMac(context, paired)
                    Result.success(paired)
                } else {
                    val errMsg = try {
                        JSONObject(respText).optString("error", "Pairing failed ($codeResp)")
                    } catch (_: Exception) {
                        "Pairing failed (HTTP $codeResp)"
                    }
                    Result.failure(RuntimeException(errMsg))
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun pingPairedMacStatus(mac: PairedMac, timeoutMs: Int = 800): MacCheckResult {
        return try {
            val path = "/ping"
            val url = URL("https://${mac.host}:${mac.port}$path")
            val conn = openPinnedConnection(url, mac.certFingerprint, timeoutMs = timeoutMs, readTimeoutMs = timeoutMs).apply {
                requestMethod = "GET"
                applyHmacAuth(this, mac, "GET", path)
            }
            try {
                val code = conn.responseCode
                when {
                    code == 200 -> {
                        val body = conn.inputStream.bufferedReader().readText()
                        val json = JSONObject(body)
                        if (json.optString("app") == "DeskDrop") {
                            MacCheckResult.Online(
                                mac.copy(
                                    port = json.optInt("port", mac.port),
                                    name = json.optString("name", mac.name)
                                )
                            )
                        } else MacCheckResult.Unreachable
                    }
                    code == 401 -> MacCheckResult.Revoked
                    else -> MacCheckResult.Unreachable
                }
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            MacCheckResult.Unreachable
        }
    }

    fun updateEndpointAndPing(context: Context, host: String, port: Int): MacCheckResult {
        val saved = DeskDropPrefs.getPairedMac(context) ?: return MacCheckResult.Unreachable
        val candidate = saved.copy(host = host.trim(), port = port)
        return when (val res = pingPairedMacStatus(candidate, timeoutMs = 1500)) {
            is MacCheckResult.Online -> {
                DeskDropPrefs.savePairedMac(context, res.mac)
                res
            }
            MacCheckResult.Revoked -> {
                DeskDropPrefs.clearPairedMac(context)
                MacCheckResult.Revoked
            }
            MacCheckResult.Unreachable -> MacCheckResult.Unreachable
        }
    }

    fun discoverEndpointOnWifi(context: Context, timeoutMs: Long = 2200): Pair<String, Int>? {
        return discoverAllEndpointsOnWifi(context, timeoutMs).firstOrNull()
    }

    @Suppress("DEPRECATION")
    fun discoverAllEndpointsOnWifi(context: Context, timeoutMs: Long = 2200): List<Pair<String, Int>> {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val multicastLock = wifi?.createMulticastLock("DeskDropNsdLock")?.apply {
            setReferenceCounted(false)
            acquire()
        }

        val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val results = Collections.synchronizedList(mutableListOf<Pair<String, Int>>())
        val firstFoundLatch = CountDownLatch(1)
        val callbacks = mutableListOf<NsdManager.ServiceInfoCallback>()

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                firstFoundLatch.countDown()
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    val cb = object : NsdManager.ServiceInfoCallback {
                        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                        override fun onServiceLost() {}
                        override fun onServiceInfoCallbackUnregistered() {}
                        override fun onServiceUpdated(updated: NsdServiceInfo) {
                            val ipv4 = updated.hostAddresses.firstOrNull { it is Inet4Address }?.hostAddress
                            if (ipv4 != null && updated.port > 0) {
                                val ep = ipv4 to updated.port
                                if (!results.contains(ep)) {
                                    results.add(ep)
                                }
                                firstFoundLatch.countDown()
                            }
                        }
                    }
                    synchronized(callbacks) { callbacks.add(cb) }
                    try {
                        nsdManager.registerServiceInfoCallback(serviceInfo, Executors.newSingleThreadExecutor(), cb)
                    } catch (_: Exception) {
                    }
                } else {
                    nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
                        override fun onServiceResolved(resolved: NsdServiceInfo) {
                            val host = resolved.host
                            val ipv4 = if (host is Inet4Address) host.hostAddress else null
                            if (ipv4 != null && resolved.port > 0) {
                                val ep = ipv4 to resolved.port
                                if (!results.contains(ep)) {
                                    results.add(ep)
                                }
                                firstFoundLatch.countDown()
                            }
                        }
                    })
                }
            }
        }

        return try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            // Wait up to timeoutMs; if at least one appears early, wait briefly for additional Macs
            if (firstFoundLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && results.isNotEmpty()) {
                Thread.sleep(250)
            }
            results.toList()
        } catch (_: Exception) {
            results.toList()
        } finally {
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (_: Exception) {
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                synchronized(callbacks) {
                    for (cb in callbacks) {
                        try {
                            nsdManager.unregisterServiceInfoCallback(cb)
                        } catch (_: Exception) {
                        }
                    }
                }
            }
            try {
                if (multicastLock?.isHeld == true) multicastLock.release()
            } catch (_: Exception) {
            }
        }
    }

    fun scanSubnetForEndpoints(context: Context, port: Int, timeoutMs: Int = 240): List<Pair<String, Int>> {
        val localIp = getActiveWifiIPv4(context) ?: return emptyList()
        val parts = localIp.split(".")
        if (parts.size != 4) return emptyList()
        val prefix = "${parts[0]}.${parts[1]}.${parts[2]}"

        val pool = Executors.newFixedThreadPool(48)
        val openHosts = Collections.synchronizedList(mutableListOf<Pair<String, Int>>())
        val latch = CountDownLatch(254)

        for (i in 1..254) {
            val candidateIp = "$prefix.$i"
            if (candidateIp == localIp) {
                latch.countDown()
                continue
            }
            pool.execute {
                try {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress(candidateIp, port), timeoutMs)
                        openHosts.add(candidateIp to port)
                    }
                } catch (_: Exception) {
                } finally {
                    latch.countDown()
                }
            }
        }

        try {
            latch.await(3200, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        } finally {
            pool.shutdownNow()
        }
        return openHosts.toList()
    }

    private fun getActiveWifiIPv4(context: Context): String? {
        return try {
            val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return null
            val network = cm.activeNetwork ?: return null
            val caps = cm.getNetworkCapabilities(network) ?: return null
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
            val lp = cm.getLinkProperties(network) ?: return null
            lp.linkAddresses
                .map { it.address }
                .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }

    private fun probeCandidatesInParallel(
        context: Context,
        saved: PairedMac,
        candidates: List<Pair<String, Int>>,
        timeoutMs: Int
    ): MacCheckResult {
        if (candidates.isEmpty()) return MacCheckResult.Unreachable

        val pool = Executors.newFixedThreadPool(minOf(candidates.size, 8))
        val winner = AtomicReference<PairedMac?>(null)
        val sawRevoked = AtomicBoolean(false)
        val latch = CountDownLatch(candidates.size)

        for ((host, port) in candidates) {
            pool.execute {
                try {
                    if (winner.get() != null) return@execute
                    val candidate = saved.copy(host = host, port = port)
                    when (val res = pingPairedMacStatus(candidate, timeoutMs = timeoutMs)) {
                        is MacCheckResult.Online -> {
                            winner.compareAndSet(null, res.mac)
                        }
                        MacCheckResult.Revoked -> {
                            sawRevoked.set(true)
                        }
                        MacCheckResult.Unreachable -> {}
                    }
                } finally {
                    latch.countDown()
                }
            }
        }

        try {
            latch.await((timeoutMs + 400).toLong(), TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        } finally {
            pool.shutdownNow()
        }

        winner.get()?.let { verified ->
            DeskDropPrefs.savePairedMac(context, verified)
            return MacCheckResult.Online(verified)
        }
        if (sawRevoked.get()) {
            DeskDropPrefs.clearPairedMac(context)
            return MacCheckResult.Revoked
        }
        return MacCheckResult.Unreachable
    }

    fun resolvePairedMacStatus(context: Context): MacCheckResult {
        val saved = DeskDropPrefs.getPairedMac(context) ?: return MacCheckResult.Unreachable

        // 1. Fast path: check active IP + all remembered IPs (Home, Office, etc.) in parallel
        val knownPairs = saved.knownEndpoints.mapNotNull { ep ->
            val idx = ep.lastIndexOf(':')
            if (idx <= 0) null
            else {
                val h = ep.substring(0, idx)
                val p = ep.substring(idx + 1).toIntOrNull()
                if (h.isNotBlank() && p != null) h to p else null
            }
        }.ifEmpty { listOf(saved.host to saved.port) }

        when (val cachedRes = probeCandidatesInParallel(context, saved, knownPairs, timeoutMs = 650)) {
            is MacCheckResult.Online, MacCheckResult.Revoked -> return cachedRes
            MacCheckResult.Unreachable -> {}
        }

        // 2. Bonjour/mDNS discovery across ALL DeskDrop Macs on current Wi-Fi
        val mDnsCandidates = discoverAllEndpointsOnWifi(context, timeoutMs = 2000)
            .filterNot { knownPairs.contains(it) }
        if (mDnsCandidates.isNotEmpty()) {
            when (val mDnsRes = probeCandidatesInParallel(context, saved, mDnsCandidates, timeoutMs = 900)) {
                is MacCheckResult.Online, MacCheckResult.Revoked -> return mDnsRes
                MacCheckResult.Unreachable -> {}
            }
        }

        // 3. Fallback: fast /24 subnet probe on Wi-Fi (works even when Office Wi-Fi blocks mDNS multicast)
        val subnetCandidates = scanSubnetForEndpoints(context, saved.port, timeoutMs = 240)
            .filterNot { knownPairs.contains(it) || mDnsCandidates.contains(it) }
        if (subnetCandidates.isNotEmpty()) {
            return probeCandidatesInParallel(context, saved, subnetCandidates, timeoutMs = 1000)
        }

        return MacCheckResult.Unreachable
    }

    fun sendText(context: Context, mac: PairedMac, text: String): Result<Unit> {
        return try {
            val path = "/drop/text"
            val payload = text.toByteArray(Charsets.UTF_8)
            val url = URL("https://${mac.host}:${mac.port}$path")
            val conn = openPinnedConnection(url, mac.certFingerprint, timeoutMs = 4000, readTimeoutMs = 8000).apply {
                requestMethod = "POST"
                doOutput = true
                setFixedLengthStreamingMode(payload.size)
                setRequestProperty("Content-Type", "text/plain; charset=utf-8")
                applyHmacAuth(this, mac, "POST", path)
            }
            try {
                conn.outputStream.use { it.write(payload) }
                val code = conn.responseCode
                if (code in 200..299) {
                    Result.success(Unit)
                } else {
                    if (code == 401) DeskDropPrefs.clearPairedMac(context)
                    Result.failure(RuntimeException(httpErrorMessage(code, conn)))
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun sendUri(context: Context, mac: PairedMac, uri: Uri): Result<String> {
        return try {
            val path = "/drop/file"
            val resolver = context.contentResolver
            val mimeType = resolver.getType(uri) ?: "application/octet-stream"
            val filename = queryFilename(context, uri) ?: defaultFilename(mimeType)
            val encodedName = URLEncoder.encode(filename, "UTF-8").replace("+", "%20")
            val knownSize = querySize(context, uri)

            val url = URL("https://${mac.host}:${mac.port}$path")
            val conn = openPinnedConnection(url, mac.certFingerprint, timeoutMs = 4000, readTimeoutMs = 30000).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", mimeType)
                setRequestProperty("X-Filename", encodedName)
                applyHmacAuth(this, mac, "POST", path)
            }

            try {
                val input = resolver.openInputStream(uri)
                    ?: return Result.failure(RuntimeException("Cannot read shared file"))
                if (knownSize > 0) {
                    conn.setFixedLengthStreamingMode(knownSize)
                    BufferedInputStream(input).use { bis ->
                        conn.outputStream.use { out ->
                            bis.copyTo(out, bufferSize = 65536)
                        }
                    }
                } else {
                    val bytes = BufferedInputStream(input).use { it.readBytes() }
                    conn.setFixedLengthStreamingMode(bytes.size)
                    conn.outputStream.use { it.write(bytes) }
                }

                val code = conn.responseCode
                if (code in 200..299) {
                    Result.success(filename)
                } else {
                    if (code == 401) DeskDropPrefs.clearPairedMac(context)
                    Result.failure(RuntimeException(httpErrorMessage(code, conn)))
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun httpErrorMessage(code: Int, conn: HttpsURLConnection): String {
        if (code == 401) return "Unauthorized — re-pair with Mac"
        return try {
            val text = conn.errorStream?.bufferedReader()?.readText().orEmpty()
            JSONObject(text).optString("error", "Mac returned HTTP $code")
        } catch (_: Exception) {
            "Mac returned HTTP $code"
        }
    }

    private fun applyHmacAuth(conn: HttpsURLConnection, mac: PairedMac, method: String, path: String) {
        val timestamp = (System.currentTimeMillis() / 1000L).toString()
        val nonceBytes = ByteArray(16).also { secureRandom.nextBytes(it) }
        val nonce = nonceBytes.joinToString("") { "%02x".format(it) }
        val message = "${method.uppercase()}\n$path\n$timestamp\n$nonce"

        val keyBytes = hexToBytes(mac.tokenHex)
        val hmac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(keyBytes, "HmacSHA256"))
        }
        val sigHex = hmac.doFinal(message.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        conn.setRequestProperty("X-DeskDrop-Device", mac.deviceId)
        conn.setRequestProperty("X-DeskDrop-Timestamp", timestamp)
        conn.setRequestProperty("X-DeskDrop-Nonce", nonce)
        conn.setRequestProperty("X-DeskDrop-Sig", sigHex)
    }

    private fun openPinnedConnection(
        url: URL,
        expectedFingerprintHex: String,
        timeoutMs: Int = 3000,
        readTimeoutMs: Int = 6000
    ): HttpsURLConnection {
        return (url.openConnection() as HttpsURLConnection).apply {
            sslSocketFactory = buildPinnedSocketFactory(expectedFingerprintHex)
            hostnameVerifier = HostnameVerifier { _, _ -> true }
            connectTimeout = timeoutMs
            readTimeout = readTimeoutMs
        }
    }

    private fun buildPinnedSocketFactory(expectedFingerprintHex: String): SSLSocketFactory {
        val expected = expectedFingerprintHex.lowercase()
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull() ?: throw CertificateException("Empty cert chain")
                val actual = sha256Hex(leaf.encoded)
                if (!constantTimeEquals(actual, expected)) {
                    throw CertificateException("TLS certificate fingerprint mismatch")
                }
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), secureRandom)
        }.socketFactory
    }

    private fun buildCapturingSocketFactory(outFingerprint: AtomicReference<String?>): SSLSocketFactory {
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull() ?: throw CertificateException("Empty cert chain")
                outFingerprint.set(sha256Hex(leaf.encoded))
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(trustManager), secureRandom)
        }.socketFactory
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
    }

    private fun formatShortFp(hex: String): String {
        return hex.take(12).uppercase().chunked(4).joinToString(":")
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim()
        val out = ByteArray(clean.length / 2)
        for (i in out.indices) {
            out[i] = clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return out
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) {
            diff = diff or (a[i].code xor b[i].code)
        }
        return diff == 0
    }

    private fun queryFilename(context: Context, uri: Uri): String? {
        return try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun querySize(context: Context, uri: Uri): Long {
        return try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0 && !cursor.isNull(idx)) cursor.getLong(idx) else -1L
                } else -1L
            } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }

    private fun defaultFilename(mimeType: String): String {
        val ext = when {
            mimeType.contains("png") -> "png"
            mimeType.contains("jpeg") || mimeType.contains("jpg") -> "jpg"
            mimeType.contains("webp") -> "webp"
            mimeType.contains("heic") -> "heic"
            mimeType.startsWith("text/") -> "txt"
            else -> "bin"
        }
        return "drop_${System.currentTimeMillis()}.$ext"
    }
}
