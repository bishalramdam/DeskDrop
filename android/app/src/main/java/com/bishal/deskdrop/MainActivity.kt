package com.bishal.deskdrop

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    private lateinit var pairedCard: View
    private lateinit var unpairedCard: View
    private lateinit var quickTextCard: View

    private lateinit var pairedStatusText: TextView
    private lateinit var pairedCertText: TextView
    private lateinit var pairStatusText: TextView

    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var codeInput: EditText
    private lateinit var quickTextInput: EditText

    private var discoveredMac: DiscoveredMac? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        pairedCard = findViewById(R.id.pairedCard)
        unpairedCard = findViewById(R.id.unpairedCard)
        quickTextCard = findViewById(R.id.quickTextCard)

        pairedStatusText = findViewById(R.id.pairedStatusText)
        pairedCertText = findViewById(R.id.pairedCertText)
        pairStatusText = findViewById(R.id.pairStatusText)

        hostInput = findViewById(R.id.hostInput)
        portInput = findViewById(R.id.portInput)
        codeInput = findViewById(R.id.codeInput)
        quickTextInput = findViewById(R.id.quickTextInput)

        findViewById<Button>(R.id.scanQrButton).setOnClickListener { startQrScan() }
        findViewById<Button>(R.id.findMacButton).setOnClickListener { findMac() }
        findViewById<Button>(R.id.pairCodeButton).setOnClickListener { pairWithCode() }
        findViewById<Button>(R.id.pingButton).setOnClickListener { testPairedPing() }
        findViewById<Button>(R.id.unpairButton).setOnClickListener { unpairMac() }
        findViewById<Button>(R.id.sendTextButton).setOnClickListener { sendQuickText() }

        refreshUiState()
    }

    override fun onResume() {
        super.onResume()
        refreshUiState()
        if (DeskDropPrefs.getPairedMac(this) != null) {
            verifyPairedConnection(showToast = false)
        }
    }

    private fun refreshUiState() {
        val paired = DeskDropPrefs.getPairedMac(this)
        if (paired != null) {
            pairedCard.visibility = View.VISIBLE
            unpairedCard.visibility = View.GONE
            quickTextCard.visibility = View.VISIBLE
            pairedStatusText.text = "${paired.name} (${paired.host}:${paired.port})"
            val shortFp = paired.certFingerprint.take(12).uppercase().chunked(4).joinToString(":")
            pairedCertText.text = "TLS Cert: $shortFp • HMAC Auth"
        } else {
            pairedCard.visibility = View.GONE
            unpairedCard.visibility = View.VISIBLE
            quickTextCard.visibility = View.GONE
        }
    }

    private fun startQrScan() {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        val scanner = GmsBarcodeScanning.getClient(this, options)

        scanner.startScan()
            .addOnSuccessListener { barcode ->
                val raw = barcode.rawValue ?: return@addOnSuccessListener
                handleQrPayload(raw)
            }
            .addOnFailureListener { err ->
                Toast.makeText(
                    this,
                    "QR scanner unavailable (${err.message ?: "use 6-digit code"})",
                    Toast.LENGTH_SHORT
                ).show()
            }
    }

    private fun handleQrPayload(raw: String) {
        try {
            val obj = JSONObject(raw)
            val host = obj.getString("h")
            val port = obj.getInt("p")
            val fp = obj.getString("fp")
            val code = obj.getString("c")
            val name = obj.optString("n", "Mac")

            pairStatusText.text = "Pairing with $name ($host)..."
            executor.execute {
                val res = DeskDropClient.pairWithMac(this, host, port, fp, code)
                runOnUiThread {
                    res.onSuccess { paired ->
                        Toast.makeText(this, "Paired with ${paired.name}!", Toast.LENGTH_SHORT).show()
                        refreshUiState()
                    }.onFailure { err ->
                        pairStatusText.text = "Pairing failed: ${err.message}"
                    }
                }
            }
        } catch (_: Exception) {
            Toast.makeText(this, "Invalid DeskDrop QR code", Toast.LENGTH_SHORT).show()
        }
    }

    private fun findMac() {
        val manualHost = hostInput.text.toString().trim()
        val manualPort = portInput.text.toString().trim().toIntOrNull() ?: 51234
        pairStatusText.text = "Looking for DeskDrop on Wi-Fi..."

        executor.execute {
            val endpoint = if (manualHost.isNotEmpty()) {
                manualHost to manualPort
            } else {
                DeskDropClient.discoverEndpointOnWifi(this)
            }

            if (endpoint == null) {
                runOnUiThread {
                    pairStatusText.text = "No Mac found on Wi-Fi. Check DeskDrop is running or enter IP."
                }
                return@execute
            }

            val info = DeskDropClient.fetchMacInfo(endpoint.first, endpoint.second)
            runOnUiThread {
                if (info != null) {
                    discoveredMac = info
                    hostInput.setText(info.host)
                    portInput.setText(info.port.toString())
                    pairStatusText.text = "Found ${info.name} • Cert: ${info.shortFingerprint}" +
                        if (info.pairingActive) " (Ready to pair)" else " (Click Pair on Mac)"
                } else {
                    pairStatusText.text = "Could not reach HTTPS server at ${endpoint.first}:${endpoint.second}"
                }
            }
        }
    }

    private fun pairWithCode() {
        val host = hostInput.text.toString().trim()
        val port = portInput.text.toString().trim().toIntOrNull() ?: 51234
        val code = codeInput.text.toString().trim()

        if (host.isEmpty()) {
            Toast.makeText(this, "Tap Find or enter Mac IP first", Toast.LENGTH_SHORT).show()
            return
        }
        if (code.length != 6) {
            Toast.makeText(this, "Enter the 6-digit code from Mac", Toast.LENGTH_SHORT).show()
            return
        }

        pairStatusText.text = "Verifying code with $host..."
        executor.execute {
            val info = discoveredMac?.takeIf { it.host == host && it.port == port }
                ?: DeskDropClient.fetchMacInfo(host, port)

            if (info == null) {
                runOnUiThread {
                    pairStatusText.text = "Could not connect to $host:$port"
                }
                return@execute
            }

            val res = DeskDropClient.pairWithMac(this, info.host, info.port, info.certFingerprint, code)
            runOnUiThread {
                res.onSuccess { paired ->
                    codeInput.setText("")
                    Toast.makeText(this, "Paired with ${paired.name}!", Toast.LENGTH_SHORT).show()
                    refreshUiState()
                }.onFailure { err ->
                    pairStatusText.text = err.message ?: "Pairing failed"
                }
            }
        }
    }

    private fun testPairedPing() {
        verifyPairedConnection(showToast = true)
    }

    private fun verifyPairedConnection(showToast: Boolean) {
        pairedStatusText.text = "Checking connection..."
        executor.execute {
            when (val status = DeskDropClient.resolvePairedMacStatus(this)) {
                is MacCheckResult.Online -> runOnUiThread {
                    pairedStatusText.text = "${status.mac.name} (${status.mac.host}:${status.mac.port}) • Online"
                    if (showToast) {
                        Toast.makeText(this, "Verified ${status.mac.name}!", Toast.LENGTH_SHORT).show()
                    }
                }
                MacCheckResult.Revoked -> runOnUiThread {
                    discoveredMac = null
                    pairStatusText.text = "Device was revoked on Mac. Pair again."
                    refreshUiState()
                    Toast.makeText(this, "Revoked on Mac", Toast.LENGTH_SHORT).show()
                }
                MacCheckResult.Unreachable -> runOnUiThread {
                    val saved = DeskDropPrefs.getPairedMac(this)
                    if (saved != null) {
                        pairedStatusText.text = "${saved.name} (${saved.host}:${saved.port}) • Offline/Locked"
                    }
                }
            }
        }
    }

    private fun unpairMac() {
        DeskDropPrefs.clearPairedMac(this)
        discoveredMac = null
        pairStatusText.text = "Unpaired. Click Pair on Mac to link again."
        refreshUiState()
        Toast.makeText(this, "Unpaired", Toast.LENGTH_SHORT).show()
    }

    private fun sendQuickText() {
        val text = quickTextInput.text.toString()
        if (text.isBlank()) {
            Toast.makeText(this, "Enter some text first", Toast.LENGTH_SHORT).show()
            return
        }

        executor.execute {
            when (val status = DeskDropClient.resolvePairedMacStatus(this)) {
                is MacCheckResult.Online -> {
                    val result = DeskDropClient.sendText(this, status.mac, text)
                    runOnUiThread {
                        result.onSuccess {
                            quickTextInput.setText("")
                            Toast.makeText(this, "Sent encrypted to ${status.mac.name}!", Toast.LENGTH_SHORT).show()
                        }.onFailure { err ->
                            Toast.makeText(this, "Failed: ${err.message}", Toast.LENGTH_SHORT).show()
                            refreshUiState()
                        }
                    }
                }
                MacCheckResult.Revoked -> runOnUiThread {
                    discoveredMac = null
                    pairStatusText.text = "Device was revoked on Mac. Pair again."
                    refreshUiState()
                    Toast.makeText(this, "Revoked on Mac", Toast.LENGTH_SHORT).show()
                }
                MacCheckResult.Unreachable -> runOnUiThread {
                    Toast.makeText(this, "Mac offline or unreachable", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}
