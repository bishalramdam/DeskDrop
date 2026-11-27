package com.bishal.deskdrop

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class PairedMac(
    val host: String,
    val port: Int,
    val name: String,
    val certFingerprint: String,
    val deviceId: String,
    val tokenHex: String,
    val knownEndpoints: List<String> = emptyList()
)

object DeskDropPrefs {
    private const val PREFS_NAME = "deskdrop_secure_prefs"
    private const val KEY_PAYLOAD = "paired_mac_enc"
    private const val KEY_ALIAS = "DeskDropMasterKey"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    fun getPairedMac(context: Context): PairedMac? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val encoded = prefs.getString(KEY_PAYLOAD, null) ?: return null
        return try {
            val jsonStr = decrypt(encoded)
            val obj = JSONObject(jsonStr)
            val host = obj.getString("host")
            val port = obj.getInt("port")
            val endpoints = mutableListOf<String>()
            val arr = obj.optJSONArray("endpoints")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val ep = arr.optString(i).trim()
                    if (ep.isNotEmpty() && !endpoints.contains(ep)) {
                        endpoints.add(ep)
                    }
                }
            }
            val primary = "$host:$port"
            if (!endpoints.contains(primary)) {
                endpoints.add(0, primary)
            }
            PairedMac(
                host = host,
                port = port,
                name = obj.optString("name", "Mac"),
                certFingerprint = obj.getString("fp"),
                deviceId = obj.getString("deviceId"),
                tokenHex = obj.getString("tokenHex"),
                knownEndpoints = endpoints
            )
        } catch (_: Exception) {
            null
        }
    }

    fun savePairedMac(context: Context, mac: PairedMac) {
        val cleanHost = mac.host.trim()
        val primary = "$cleanHost:${mac.port}"
        val merged = mutableListOf(primary)
        for (ep in mac.knownEndpoints) {
            val cleanEp = ep.trim()
            if (cleanEp.isNotEmpty() && !merged.contains(cleanEp)) {
                merged.add(cleanEp)
            }
            if (merged.size >= 10) break
        }

        val obj = JSONObject().apply {
            put("host", cleanHost)
            put("port", mac.port)
            put("name", mac.name)
            put("fp", mac.certFingerprint.lowercase())
            put("deviceId", mac.deviceId)
            put("tokenHex", mac.tokenHex)
            put("endpoints", JSONArray(merged))
        }
        val encrypted = encrypt(obj.toString())
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PAYLOAD, encrypted)
            .apply()
    }

    fun clearPairedMac(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_PAYLOAD)
            .apply()
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        keyStore.getKey(KEY_ALIAS, null)?.let { return it as SecretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun encrypt(plainText: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val cipherBytes = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(1 + iv.size + cipherBytes.size)
        combined[0] = iv.size.toByte()
        System.arraycopy(iv, 0, combined, 1, iv.size)
        System.arraycopy(cipherBytes, 0, combined, 1 + iv.size, cipherBytes.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        val ivLen = combined[0].toInt() and 0xFF
        val iv = combined.copyOfRange(1, 1 + ivLen)
        val cipherBytes = combined.copyOfRange(1 + ivLen, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        val plain = cipher.doFinal(cipherBytes)
        return String(plain, Charsets.UTF_8)
    }
}
