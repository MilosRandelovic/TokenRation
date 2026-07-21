#!/bin/bash
# Build TokenRation.app for LOCAL use (ad-hoc signed). Fast, no Apple account needed.
# For a distributable, notarized build, use ./release.sh instead.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

assemble_bundle

echo "==> Code-signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/$MCP_NAME"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
echo "    Launch it:   open \"$APP\""
echo "    Install it:  cp -R \"$APP\" /Applications/"
echo "    (Local only. For distribution to other Macs: ./release.sh)"
