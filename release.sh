#!/bin/bash
# Build a Developer-ID-signed, hardened-runtime, NOTARIZED, stapled TokenRation.app that
# runs on other Macs without Gatekeeper warnings.
#
# One-time prerequisites (all require YOUR Apple Developer account):
#   1. Paid Apple Developer Program membership — https://developer.apple.com/programs/ ($99/yr).
#   2. A "Developer ID Application" certificate in your login Keychain:
#        Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸
#        "Developer ID Application".
#      (Your current "Apple Development" cert is NOT valid for distribution.)
#   3. A stored notary credential profile (an app-specific password from
#      https://appleid.apple.com ▸ Sign-In & Security ▸ App-Specific Passwords):
#        xcrun notarytool store-credentials "TokenRation-notary" \
#          --apple-id "you@example.com" --team-id "XXXXXXXXXX" --password "abcd-efgh-ijkl-mnop"
#
# Then just run: ./release.sh
# Overrides: SIGN_IDENTITY="Developer ID Application: ..."  NOTARY_PROFILE="my-profile"
# In CI, pass notary creds via env instead of a stored profile:
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

NOTARY_PROFILE="${NOTARY_PROFILE:-TokenRation-notary}"

# 1. Locate the Developer ID Application signing identity.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "ERROR: No 'Developer ID Application' certificate in your Keychain." >&2
    echo "You currently have:" >&2
    security find-identity -v -p codesigning | sed 's/^/    /' >&2
    echo "Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸" >&2
    echo "'Developer ID Application' (needs a paid Apple Developer Program membership)." >&2
    exit 1
fi
echo "==> Signing identity: $IDENTITY"

assemble_bundle

# 2. Sign with hardened runtime + secure timestamp (both required for notarization).
echo "==> Code-signing (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/$MCP_NAME"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Notarize (zip, submit, wait for Apple's verdict).
ZIP="$APP_NAME.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Submitting to Apple notary service — may take a few minutes"
if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
else
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi

# 4. Staple the ticket onto the app and confirm Gatekeeper accepts it.
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo "==> Gatekeeper assessment:"
spctl -a -vvv -t install "$APP" || true

# 5. Produce the distributable zip and update the Homebrew cask.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo "==> Done. Notarized, stapled: $APP"
echo "    artifact: $(pwd)/$ZIP"
echo "    version:  $SHORT_VERSION"
echo "    sha256:   $SHA"

# Update the cask in the sibling tap (override the path with TAP_CASK=…).
CASK="${TAP_CASK:-../homebrew-tokenration/Casks/tokenration.rb}"
if [ -f "$CASK" ]; then
    /usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$SHORT_VERSION\"/" "$CASK"
    /usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
    echo "==> Updated cask: $CASK"
else
    echo "==> Cask not found at $CASK — paste the version/sha256 above into your cask."
fi

cat <<NEXT

Release flow:
  1. Create a GitHub release tagged v$SHORT_VERSION on MilosRandelovic/TokenRation and
     upload $ZIP to it.
  2. Commit & push the updated cask in the homebrew-tokenration tap.
NEXT
