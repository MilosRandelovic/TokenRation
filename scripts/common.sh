#!/usr/bin/env bash

# Shared bundle assembly, sourced by build-app.sh and release.sh.
# SHORT_VERSION is the release version: bumping it and pushing to main publishes a release.
APP_NAME="TokenRation"
MCP_NAME="tokenration-mcp"
BUNDLE_ID="com.milos.tokenration"
SHORT_VERSION="0.1.0"
BUILD_VERSION="1"
MIN_MACOS="14.0"

# Build the release binary and lay out <APP_NAME>.app (unsigned).
# Sets $APP to the bundle path for the caller.
assemble_bundle() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$root"

  echo "==> Building release"
  swift build -c release
  local binDir="$(swift build -c release --show-bin-path)"
  local bin="$binDir/$APP_NAME"

  APP="$root/$APP_NAME.app"
  local contents="$APP/Contents"
  echo "==> Assembling $APP_NAME.app"
  rm -rf "$APP"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp "$bin" "$contents/MacOS/$APP_NAME"
  # Bundled MCP server; the Homebrew cask symlinks this onto the PATH.
  cp "$binDir/$MCP_NAME" "$contents/MacOS/$MCP_NAME"

  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}
