#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building DeskDrop (release)..."
swift build -c release --disable-sandbox

APP_DIR="$SCRIPT_DIR/build/DeskDrop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/DeskDrop" "$MACOS_DIR/DeskDrop"
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
if [ ! -f "Resources/AppIcon.icns" ]; then
    swift "scripts/generate_icon.swift" "Resources/AppIcon.icns"
fi
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Ad-hoc sign so macOS local network & notification permissions behave consistently
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "To install into ~/Applications:"
echo "  mkdir -p ~/Applications && rm -rf ~/Applications/DeskDrop.app && cp -R \"$APP_DIR\" ~/Applications/DeskDrop.app"
echo "  open ~/Applications/DeskDrop.app"
