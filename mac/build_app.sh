#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building DeskDrop (release)..."
swift build -c release --disable-sandbox --disable-automatic-resolution

APP_DIR="$SCRIPT_DIR/build/DeskDrop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/DeskDrop" "$MACOS_DIR/DeskDrop"
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
if [ ! -f "Resources/AppIcon.icns" ] || [ ! -f "Resources/Assets.car" ]; then
    TMP_XCASSETS="/tmp/DeskDrop_Assets_$$.xcassets"
    rm -rf "$TMP_XCASSETS"
    swift "scripts/generate_icon.swift" "Resources/AppIcon.icns" "" "$TMP_XCASSETS"
    if command -v actool >/dev/null 2>&1; then
        actool "$TMP_XCASSETS" \
            --compile "Resources" \
            --app-icon AppIcon \
            --output-partial-info-plist "/tmp/DeskDrop_partial_$$.plist" \
            --platform macosx \
            --minimum-deployment-target 13.0 >/dev/null 2>&1 || true
        rm -f "/tmp/DeskDrop_partial_$$.plist"
    fi
    rm -rf "$TMP_XCASSETS"
fi
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
if [ -f "Resources/Assets.car" ]; then
    cp "Resources/Assets.car" "$RESOURCES_DIR/Assets.car"
fi

# Ad-hoc sign so macOS local network & notification permissions behave consistently
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "To install into ~/Applications:"
echo "  mkdir -p ~/Applications && rm -rf ~/Applications/DeskDrop.app && cp -R \"$APP_DIR\" ~/Applications/DeskDrop.app"
echo "  open ~/Applications/DeskDrop.app"
