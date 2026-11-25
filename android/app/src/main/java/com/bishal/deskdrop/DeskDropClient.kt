package com.bishal.deskdrop

import android.content.Context
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

object DeskDropClient {
    private const val SERVICE_TYPE = "_deskdrop._tcp."

    fun ping(host: String, port: Int, timeoutMs: Int = 900): MacTarget? {
        return try {
            val url = URL("http://$host:$port/ping")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
            }
            try {
                if (conn.responseCode == 200) {
                    val body = conn.inputStream.bufferedReader().readText()
                    val json = JSONObject(body)
                    if (json.optString("app") == "DeskDrop") {
                        MacTarget(
                            host = host,
                            port = json.optInt("port", port),
                            name = json.optString("name", "Mac")
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

    @Suppress("DEPRECATION")
    fun discoverMac(context: Context, timeoutMs: Long = 2800): MacTarget? {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val multicastLock = wifi?.createMulticastLock("DeskDropNsdLock")?.apply {
            setReferenceCounted(false)
            acquire()
        }

        val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val found = AtomicReference<MacTarget?>(null)
        val latch = CountDownLatch(1)
        val stopped = AtomicReference(false)

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                latch.countDown()
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (found.get() != null) return
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val hostAddr = resolved.host?.let { addr ->
                            if (addr is Inet4Address) addr.hostAddress else addr.hostAddress
                        } ?: return
                        val target = MacTarget(
                            host = hostAddr,
                            port = resolved.port,
                            name = resolved.serviceName ?: "Mac"
                        )
                        if (found.compareAndSet(null, target)) {
                            latch.countDown()
                        }
                    }
                })
            }
        }

        return try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            found.get()
        } catch (_: Exception) {
            null
        } finally {
            if (stopped.compareAndSet(false, true)) {
                try {
                    nsdManager.stopServiceDiscovery(discoveryListener)
                } catch (_: Exception) {
                }
            }
            try {
                if (multicastLock?.isHeld == true) multicastLock.release()
            } catch (_: Exception) {
            }
        }
    }

    fun resolveTarget(context: Context): MacTarget? {
        DeskDropPrefs.getTarget(context)?.let { cached ->
            ping(cached.host, cached.port, timeoutMs = 500)?.let { verified ->
                DeskDropPrefs.saveTarget(context, verified)
                return verified
            }
        }
        val discovered = discoverMac(context) ?: return null
        DeskDropPrefs.saveTarget(context, discovered)
        return discovered
    }

    fun sendText(target: MacTarget, text: String): Result<Unit> {
        return try {
            val payload = text.toByteArray(Charsets.UTF_8)
            val url = URL("http://${target.host}:${target.port}/drop/text")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 3000
                readTimeout = 8000
                setFixedLengthStreamingMode(payload.size)
                setRequestProperty("Content-Type", "text/plain; charset=utf-8")
            }
            try {
                conn.outputStream.use { it.write(payload) }
                if (conn.responseCode in 200..299) {
                    Result.success(Unit)
                } else {
                    Result.failure(RuntimeException("Mac returned HTTP ${conn.responseCode}"))
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun sendUri(context: Context, target: MacTarget, uri: Uri): Result<String> {
        return try {
            val resolver = context.contentResolver
            val mimeType = resolver.getType(uri) ?: "application/octet-stream"
            val filename = queryFilename(context, uri) ?: defaultFilename(mimeType)
            val encodedName = URLEncoder.encode(filename, "UTF-8").replace("+", "%20")
            val knownSize = querySize(context, uri)

            val url = URL("http://${target.host}:${target.port}/drop/file")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 3000
                readTimeout = 30000
                setRequestProperty("Content-Type", mimeType)
                setRequestProperty("X-Filename", encodedName)
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

                if (conn.responseCode in 200..299) {
                    Result.success(filename)
                } else {
                    Result.failure(RuntimeException("Mac returned HTTP ${conn.responseCode}"))
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Result.failure(e)
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
