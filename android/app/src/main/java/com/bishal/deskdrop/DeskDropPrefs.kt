package com.bishal.deskdrop

import android.content.Context

data class MacTarget(
    val host: String,
    val port: Int,
    val name: String = "Mac"
)

object DeskDropPrefs {
    private const val PREFS_NAME = "deskdrop_prefs"
    private const val KEY_HOST = "last_host"
    private const val KEY_PORT = "last_port"
    private const val KEY_NAME = "last_name"

    fun getTarget(context: Context): MacTarget? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val host = prefs.getString(KEY_HOST, null)?.trim() ?: return null
        if (host.isEmpty()) return null
        val port = prefs.getInt(KEY_PORT, 51234)
        val name = prefs.getString(KEY_NAME, "Mac") ?: "Mac"
        return MacTarget(host, port, name)
    }

    fun saveTarget(context: Context, target: MacTarget) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HOST, target.host.trim())
            .putInt(KEY_PORT, target.port)
            .putString(KEY_NAME, target.name)
            .apply()
    }
}
