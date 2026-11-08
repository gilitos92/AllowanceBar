#!/bin/zsh
# Builds, signs with Developer ID, notarizes, staples, and zips
# "Allowance Bar.app", then writes a signed Sparkle appcast.xml.
# See docs/RELEASING.md.
#
# Environment:
#   ALLOWANCEBAR_VERSION  e.g. 2.9.2 (defaults to 2.9.2)
#   SIGN_IDENTITY         code-signing identity (SHA-1 or certificate name);
#                         defaults to the project's "Developer ID Application"
#                         identity (team GC28C3K5G9) in the keychain. It must
#                         be a Developer ID identity.
#   NOTARY_PROFILE        notarytool keychain profile; defaults to
#                         "AllowanceBar". Alternatively set all of
#                         APPLE_API_KEY_ID / APPLE_API_ISSUER / APPLE_API_KEY
#                         (path to the .p8).
#
# The appcast is signed with the Sparkle EdDSA key stored in the login
# keychain under account "AllowanceBar" (backup in 1Password, vault Personal,
# item "Allowance Bar Release Keys").
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/signing-identity.sh

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(find_developer_id_identity)"
fi
if ! is_developer_id_identity "$SIGN_IDENTITY"; then
    echo "error: no valid Developer ID Application identity for team ${ALLOWANCEBAR_TEAM_ID}" >&2
    echo "       (SIGN_IDENTITY='${SIGN_IDENTITY}'). Releases must be Developer ID signed" >&2
    echo "       and notarized; see docs/RELEASING.md to restore the certificate." >&2
    exit 1
fi
VERSION="${ALLOWANCEBAR_VERSION:-2.9.2}"
SPARKLE_ACCOUNT="AllowanceBar"
REPO="gilitos92/AllowanceBar"

APP="Allowance Bar.app"
ZIP="AllowanceBar.zip"

# 1. Build + sign (hardened runtime, secure timestamp).
SIGN_IDENTITY="$SIGN_IDENTITY" ALLOWANCEBAR_VERSION="$VERSION" scripts/bundle.sh

# 2. Zip for the notary service (ditto preserves the bundle + signature).
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# 3. Notarize, then staple the ticket to the app. `notarytool --wait` can exit
#    0 for a rejected submission, so check the status it reports.
NOTARY_ARGS=()
if [[ -n "${APPLE_API_KEY_ID:-}" ]]; then
    : "${APPLE_API_ISSUER:?Set APPLE_API_ISSUER}"
    : "${APPLE_API_KEY:?Set APPLE_API_KEY (path to .p8)}"
    NOTARY_ARGS=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
    NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-AllowanceBar}")
fi
echo "Submitting $ZIP for notarization (usually a few minutes)..."
NOTARY_JSON=$(xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json)
NOTARY_STATUS=$(plutil -extract status raw -o - - <<<"$NOTARY_JSON" 2>/dev/null || true)
NOTARY_ID=$(plutil -extract id raw -o - - <<<"$NOTARY_JSON" 2>/dev/null || true)
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "error: notarization status '${NOTARY_STATUS:-unknown}' (submission ${NOTARY_ID:-unknown})" >&2
    if [[ -n "$NOTARY_ID" ]]; then
        xcrun notarytool log "$NOTARY_ID" "${NOTARY_ARGS[@]}" >&2 || true
    fi
    exit 1
fi
echo "Notarization accepted (submission $NOTARY_ID)."
xcrun stapler staple "$APP"

# 4. Re-zip the stapled app. This zip is the release asset and the Sparkle
#    update, so the EdDSA signature below covers the stapled app.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# 5. Verify the copy users get: unzip it and check the signature, team,
#    hardened runtime, staple, and Gatekeeper's verdict.
VERIFY_DIR=$(mktemp -d)
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR"
VERIFY_APP="$VERIFY_DIR/$APP"
codesign --verify --deep --strict "$VERIFY_APP"
SIGNATURE_INFO=$(codesign -dv "$VERIFY_APP" 2>&1)
if [[ "$SIGNATURE_INFO" != *"TeamIdentifier=${ALLOWANCEBAR_TEAM_ID}"* ]]; then
    echo "error: the zipped app is not signed by team ${ALLOWANCEBAR_TEAM_ID}" >&2
    exit 1
fi
if [[ "$SIGNATURE_INFO" != *"(runtime)"* ]]; then
    echo "error: the zipped app lacks the hardened runtime" >&2
    exit 1
fi
xcrun stapler validate "$VERIFY_APP"
GATEKEEPER=$(spctl -a -t exec -vv "$VERIFY_APP" 2>&1)
if [[ "$GATEKEEPER" != *"source=Notarized Developer ID"* ]]; then
    echo "error: Gatekeeper does not accept the zipped app as notarized:" >&2
    echo "$GATEKEEPER" >&2
    exit 1
fi
rm -rf "$VERIFY_DIR"
echo "Verified: team ${ALLOWANCEBAR_TEAM_ID}, hardened runtime, stapled, Notarized Developer ID."

# 6. Generate the Sparkle appcast, signed with the EdDSA key in the Keychain.
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
