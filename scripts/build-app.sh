#!/usr/bin/env bash

# Build TokenRation.app for local use, ad-hoc signed. No Apple Developer account required.
# For a distributable build, see release.sh.

set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/common.sh

assemble_bundle

echo "==> Code-signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/$MCP_NAME"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
echo "    Launch it:   open \"$APP\""
echo "    Install it:  cp -R \"$APP\" /Applications/"
echo "    (Local only. For a distributable build: make release)"
