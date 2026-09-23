#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
STAGING="$(mktemp -d /private/tmp/fullscreen-message.XXXXXX)"
APP="$STAGING/全屏消息.app"
PAYLOAD="$STAGING/payload"
PKG="$BUILD_DIR/全屏消息-Apple芯片-v3.12.0.pkg"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"

xcrun swiftc -swift-version 5 -O \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP/Contents/MacOS/FullscreenMessage" \
  -framework AppKit -framework Network -framework ServiceManagement

cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
ICON_WORK="$STAGING/AppIcon.iconset"
mkdir -p "$ICON_WORK"
xcrun swift "$PROJECT_DIR/scripts/render-icon.swift" "$STAGING/AppIcon-1024.png"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$STAGING/AppIcon-1024.png" --out "$ICON_WORK/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICON_WORK" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$BUILD_DIR/全屏消息.app"
ditto --norsrc "$APP" "$BUILD_DIR/全屏消息.app"

mkdir -p "$PAYLOAD/Applications"
ditto --norsrc "$APP" "$PAYLOAD/Applications/全屏消息.app"
pkgbuild --root "$PAYLOAD" \
  --scripts "$PROJECT_DIR/installer" \
  --identifier "cn.local.fullscreen-message" \
  --version "3.12.0" \
  --install-location / \
  "$PKG"

echo "$BUILD_DIR/全屏消息.app"
echo "$PKG"
