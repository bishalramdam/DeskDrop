# DeskDrop

Fast, encrypted, local-network-only sharing between **Android** and **macOS**.

Share screenshots, photos, text, and files directly from the Android Share Sheet to your Mac menu bar app (`DeskDrop.app`) and clipboard—with zero cloud servers and zero background battery drain on your phone.

---

## Features

### Android App (`android/`)
- **Native Share Sheet Target:** Tap **Share → Send to Mac** from any screenshot preview, photo, link, or file—uploads over local Wi-Fi and closes automatically.
- **Zero Background Listeners:** No persistent background services or accessibility hacks.
- **1-Time QR or 6-Digit Pairing:** Scan the QR code shown in `DeskDrop.app` (or pair with a 6-digit PIN).
- **Encrypted Key Storage:** Device credentials and pinned Mac certificate fingerprint are encrypted with **AndroidKeyStore AES-256-GCM**.
- **Nothing OS & Material 3 Ready:** Minimal Day/Night Material 3 UI and adaptive `<monochrome>` themed icon.

### macOS Menu Bar App (`mac/`)
- **Instant Clipboard & Storage:** Auto-copies received screenshots/images (`NSImage`) and text to the Mac clipboard, and saves files to `~/Library/Application Support/DeskDrop/Received/` (plus a `latest.<ext>` symlink for images).
- **Native macOS Notifications:** Glassy Notification Center banners with image thumbnails and direct **Copy**, **Copy Path**, and **Show in Finder** actions.
- **Zero-Config Discovery:** Advertises `_deskdrop._tcp` via Bonjour/mDNS.
- **Smart Auto-Pause:** Automatically pauses listening when your Mac locks or sleeps, with optional **Trusted Wi-Fi Only** (SSID allowlist) and one-click **Stop / Start** and **Revoke** controls.

---

## Security Architecture

- **HTTPS Everywhere:** Powered by SwiftNIO SSL (BoringSSL) on macOS with a locally generated self-signed certificate (no Login Keychain prompts). Cleartext HTTP is disabled on Android (`usesCleartextTraffic="false"`).
- **SHA-256 Certificate Pinning:** Android pins the Mac's exact leaf certificate SHA-256 fingerprint during pairing.
- **Per-Request HMAC-SHA256 Auth:** Every `/ping` and `/drop/*` request is signed with a 256-bit device secret, Unix timestamp (±30s window), and anti-replay nonce. Unpaired or revoked devices immediately receive `401 Unauthorized`.

---

## Quick Start

1. **Install & open `DeskDrop.app` on Mac** (from Releases or built from source).
2. **Allow Notifications & Local Network** when macOS prompts.
3. **Install `DeskDrop-android.apk`** on your Android phone (Android 8.0+).
4. Click **Pair** in the Mac menu bar → open **DeskDrop** on your phone → **Scan QR Code on Mac** (or tap **Find** and enter the 6-digit code).
5. Take a screenshot on your phone → **Share → Send to Mac** → **`Cmd + V`** on your Mac.

---

## Build from Source

### macOS (`DeskDrop.app`)
Requires macOS 13+ and Swift 5.10+ / Xcode Command Line Tools:
```bash
cd mac
./build_app.sh
mkdir -p ~/Applications && rm -rf ~/Applications/DeskDrop.app && cp -R build/DeskDrop.app ~/Applications/DeskDrop.app
open ~/Applications/DeskDrop.app
```

### Android (`app-debug.apk`)
Requires JDK 17 and Android SDK (API 35):
```bash
cd android
gradle assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
