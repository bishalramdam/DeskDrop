package com.bishal.deskdrop

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.IntentCompat
import java.util.concurrent.Executors

class ShareActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var progress: ProgressBar
    private lateinit var titleText: TextView
    private lateinit var subtitleText: TextView
    private lateinit var retryButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_share)

        progress = findViewById(R.id.shareProgress)
        titleText = findViewById(R.id.shareTitle)
        subtitleText = findViewById(R.id.shareSubtitle)
        retryButton = findViewById(R.id.shareRetryButton)

        retryButton.setOnClickListener {
            retryButton.visibility = View.GONE
            progress.visibility = View.VISIBLE
            titleText.text = "Sending to Mac..."
            subtitleText.text = "Connecting securely over Wi-Fi"
            handleShareIntent(intent)
        }

        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) {
            finish()
            return
        }

        val uris = mutableListOf<Uri>()
        var sharedText: String? = null

        when (intent.action) {
            Intent.ACTION_SEND -> {
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let {
                    uris.add(it)
                }
                if (uris.isEmpty()) {
                    sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let {
                    uris.addAll(it)
                }
            }
        }

        if (uris.isEmpty() && sharedText.isNullOrBlank()) {
            showFailure("Nothing shareable found")
            return
        }

        if (DeskDropPrefs.getPairedMac(this) == null) {
            showFailure("Not paired with Mac. Open DeskDrop to scan QR or enter pairing code.")
            return
        }

        executor.execute {
            val target = when (val status = DeskDropClient.resolvePairedMacStatus(this)) {
                is MacCheckResult.Online -> status.mac
                MacCheckResult.Revoked -> {
                    runOnUiThread {
                        showFailure("Device was revoked on Mac. Open DeskDrop to pair again.")
                    }
                    return@execute
                }
                MacCheckResult.Unreachable -> {
                    runOnUiThread {
                        showFailure("Mac is locked, paused, or unreachable on Wi-Fi.")
                    }
                    return@execute
                }
            }

            runOnUiThread {
                subtitleText.text = "Sending encrypted to ${target.name}..."
            }

            if (uris.isNotEmpty()) {
                var lastSuccessName = ""
                for ((index, uri) in uris.withIndex()) {
                    if (uris.size > 1) {
                        runOnUiThread {
                            subtitleText.text = "Sending ${index + 1} of ${uris.size} to ${target.name}..."
                        }
                    }
                    val res = DeskDropClient.sendUri(this, target, uri)
                    if (res.isFailure) {
                        val msg = res.exceptionOrNull()?.message ?: "Upload failed"
                        runOnUiThread { showFailure(msg) }
                        return@execute
                    }
                    lastSuccessName = res.getOrDefault("file")
                }
                val summary = if (uris.size == 1) lastSuccessName else "${uris.size} items"
                runOnUiThread {
                    showSuccess("Sent to ${target.name}", summary)
                }
            } else if (!sharedText.isNullOrBlank()) {
                val res = DeskDropClient.sendText(this, target, sharedText)
                runOnUiThread {
                    res.onSuccess {
                        showSuccess("Sent to ${target.name}", "Copied text to Mac clipboard")
                    }.onFailure { err ->
                        showFailure(err.message ?: "Failed to send text")
                    }
                }
            }
        }
    }

    private fun showSuccess(title: String, subtitle: String) {
        progress.visibility = View.GONE
        retryButton.visibility = View.GONE
        titleText.text = title
        subtitleText.text = subtitle
        mainHandler.postDelayed({ finish() }, 550)
    }

    private fun showFailure(message: String) {
        progress.visibility = View.GONE
        titleText.text = "Send Failed"
        subtitleText.text = message
        retryButton.visibility = View.VISIBLE
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}
