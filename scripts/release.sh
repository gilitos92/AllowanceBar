#!/bin/zsh
# Builds, signs, (optionally) notarizes, zips "Allowance Bar.app", and writes
# a signed Sparkle appcast.xml. See docs/RELEASING.md.
#
# Environment:
#   ALLOWANCEBAR_VERSION  e.g. 2.4.0 (defaults to 2.4.0)
#   SIGN_IDENTITY         code-signing identity; defaults to the self-signed
#                         "GGV" certificate in the login keychain. A
#                         "Developer ID Application" identity also enables
#                         notarization and stapling.
#
# Notarization (Developer ID only): set NOTARY_PROFILE (a notarytool keychain
# profile), or all of APPLE_API_KEY_ID / APPLE_API_ISSUER / APPLE_API_KEY
# (path to the .p8).
#
# The appcast is signed with the Sparkle EdDSA key stored in the login
# keychain under account "AllowanceBar" (backup in 1Password, vault Personal,
# item "Allowance Bar Release Keys").
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-GGV}"
VERSION="${ALLOWANCEBAR_VERSION:-2.4.0}"
SPARKLE_ACCOUNT="AllowanceBar"
REPO="gilitos92/AllowanceBar"

APP="Allowance Bar.app"
ZIP="AllowanceBar.zip"

# 1. Build + sign.
SIGN_IDENTITY="$SIGN_IDENTITY" ALLOWANCEBAR_VERSION="$VERSION" scripts/bundle.sh

# 2. Zip (ditto preserves the bundle + signature).
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# 3. Notarize, staple, and re-zip — Developer ID builds only.
if [[ "$SIGN_IDENTITY" == *"Developer ID"* ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        : "${APPLE_API_KEY_ID:?Set NOTARY_PROFILE or APPLE_API_KEY_ID/ISSUER/KEY}"
        : "${APPLE_API_ISSUER:?Set APPLE_API_ISSUER}"
        : "${APPLE_API_KEY:?Set APPLE_API_KEY (path to .p8)}"
        xcrun notarytool submit "$ZIP" \
            --key "$APPLE_API_KEY" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER" \
            --wait
    fi
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun stapler validate "$APP"
else
    echo "Not a Developer ID identity; skipping notarization."
fi

# 4. Generate the Sparkle appcast, signed with the EdDSA key in the Keychain.
#    The enclosure URL must point at the versioned release asset.
GENERATE_APPCAST=$(find .build/artifacts/sparkle -name generate_appcast -type f | head -1)
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "error: generate_appcast not found in .build/artifacts" >&2
    exit 1
fi
APPCAST_DIR=$(mktemp -d)
cp "$ZIP" "$APPCAST_DIR/"
"$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/v${VERSION}/" \
    --maximum-versions 1 \
    "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" appcast.xml
rm -rf "$APPCAST_DIR"
echo "Appcast written to $PWD/appcast.xml"

echo "Release artifacts ready: $PWD/$ZIP and $PWD/appcast.xml (upload BOTH)"
