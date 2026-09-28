#!/bin/bash
# Builds "What Made That Sound.app" with SwiftPM and assembles the bundle by hand,
# so it works without Xcode's IDE components (the Xcode project builds the same
# thing). The result is written to build/.
#
# Environment:
#   CONFIGURATION   release (default) or debug
#   SIGN_IDENTITY   codesign identity; "-" (ad-hoc, the default) runs on this Mac only
#   VERSION         marketing version (default 1.0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

APP_NAME="What Made That Sound"
BUNDLE_ID="com.matthewy.WhatMadeThatSound"
AGENT_NAME="WhatMadeThatSoundAgent"
AGENT_PLIST="com.matthewy.WhatMadeThatSound.Agent.plist"
MIN_MACOS="14.2"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling ($CONFIGURATION)"
swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product WhatMadeThatSound
swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product "$AGENT_NAME"
BIN_DIR="$(swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN_DIR/WhatMadeThatSound" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$AGENT_NAME" "$APP/Contents/MacOS/$AGENT_NAME"
cp "$ROOT/LaunchAgents/$AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/$AGENT_PLIST"

# App icon: turn the asset catalog's PNGs into an .icns.
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$ROOT/WhatMadeThatSound/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ICONSET/"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

echo "==> Signing (identity: $SIGN_IDENTITY)"
# Inside out: the agent is nested code, then the bundle that contains it.
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID.Agent" "$APP/Contents/MacOS/$AGENT_NAME"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Built $APP"
