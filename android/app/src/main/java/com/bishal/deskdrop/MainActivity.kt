package com.bishal.deskdrop

import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    private lateinit var statusText: TextView
    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var quickTextInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        hostInput = findViewById(R.id.hostInput)
        portInput = findViewById(R.id.portInput)
        quickTextInput = findViewById(R.id.quickTextInput)

        DeskDropPrefs.getTarget(this)?.let { saved ->
            hostInput.setText(saved.host)
            portInput.setText(saved.port.toString())
            statusText.text = "Saved: ${saved.name} (${saved.host}:${saved.port})"
        }

        findViewById<Button>(R.id.scanButton).setOnClickListener {
            scanForMac()
        }

        findViewById<Button>(R.id.saveTestButton).setOnClickListener {
            saveAndPing()
        }

        findViewById<Button>(R.id.sendTextButton).setOnClickListener {
            sendQuickText()
        }
    }

    private fun scanForMac() {
        statusText.text = "Scanning Wi-Fi for DeskDrop..."
        executor.execute {
            val found = DeskDropClient.discoverMac(this)
            runOnUiThread {
                if (found != null) {
                    DeskDropPrefs.saveTarget(this, found)
                    hostInput.setText(found.host)
                    portInput.setText(found.port.toString())
                    statusText.text = "Connected: ${found.name} (${found.host}:${found.port})"
                    Toast.makeText(this, "Found ${found.name}", Toast.LENGTH_SHORT).show()
                } else {
                    statusText.text = "No Mac found via Bonjour. Enter IP manually or check Wi-Fi."
                }
            }
        }
    }

    private fun saveAndPing() {
        val host = hostInput.text.toString().trim()
        val port = portInput.text.toString().trim().toIntOrNull() ?: 51234
        if (host.isEmpty()) {
            Toast.makeText(this, "Enter Mac IP address", Toast.LENGTH_SHORT).show()
            return
        }

        statusText.text = "Pinging $host:$port..."
        executor.execute {
            val verified = DeskDropClient.ping(host, port)
            runOnUiThread {
                if (verified != null) {
                    DeskDropPrefs.saveTarget(this, verified)
                    statusText.text = "Connected: ${verified.name} (${verified.host}:${verified.port})"
                    Toast.makeText(this, "Connected to ${verified.name}!", Toast.LENGTH_SHORT).show()
                } else {
                    statusText.text = "Could not reach DeskDrop at $host:$port"
                }
            }
        }
    }

    private fun sendQuickText() {
        val text = quickTextInput.text.toString()
        if (text.isBlank()) {
            Toast.makeText(this, "Enter some text first", Toast.LENGTH_SHORT).show()
            return
        }

        executor.execute {
            val target = DeskDropClient.resolveTarget(this)
            if (target == null) {
                runOnUiThread {
                    Toast.makeText(this, "Mac not found on Wi-Fi", Toast.LENGTH_SHORT).show()
                }
                return@execute
            }
            val result = DeskDropClient.sendText(target, text)
            runOnUiThread {
                result.onSuccess {
                    quickTextInput.setText("")
                    Toast.makeText(this, "Sent to ${target.name}!", Toast.LENGTH_SHORT).show()
                }.onFailure { err ->
                    Toast.makeText(this, "Failed: ${err.message}", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}
