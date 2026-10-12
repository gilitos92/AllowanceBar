#!/bin/zsh
# Builds "Allowance Bar.app" (menu-bar-only bundle) into the repo root.
#
# Usage:
#   scripts/bundle.sh [--install]
#     --install   also copy the app to /Applications
#
# Optional environment for signing (used by scripts/release.sh and CI):
#   SIGN_IDENTITY   code-signing identity; defaults to ad-hoc "-". Every build
#                   gets the hardened runtime. A Developer ID identity also gets
#                   the timestamp needed for notarization; any other identity
#                   (e.g. the self-signed "GGV" certificate) gets the
#                   library-validation entitlement so Sparkle still loads.
set -euo pipefail

cd "$(dirname "$0")/.."

# Display/bundle name, and the SwiftPM executable product built for it.
APP_NAME="Allowance Bar"
EXECUTABLE="AllowanceBar"
BUNDLE_ID="com.ggv.AllowanceBar"
CLI_NAME="allowancebar"
VERSION="${ALLOWANCEBAR_VERSION:-2.2.3}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Compile Spanish strings from the catalog; en.lproj is checked in separately.
xcrun xcstringstool compile Sources/AgentMeter/Resources/Localizable.xcstrings \
    --output-directory Sources/AgentMeter/Resources

swift build -c release

APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp ".build/release/${EXECUTABLE}" "$APP/Contents/MacOS/${EXECUTABLE}"
# CLI ships in Helpers/ (not MacOS/) because "allowancebar" and "AllowanceBar"
# collide on case-insensitive filesystems.
mkdir -p "$APP/Contents/Helpers"
cp ".build/release/${CLI_NAME}-cli" "$APP/Contents/Helpers/${CLI_NAME}"
RESOURCE_BUNDLE=".build/release/AgentMeter_AgentMeter.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "error: required resource bundle missing: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Embed Sparkle.framework (SwiftPM links it via @rpath but does not bundle it).
SPARKLE_FRAMEWORK=$(find .build/artifacts/sparkle -type d -name "Sparkle.framework" -path "*macos*" | head -1)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found in .build/artifacts (run swift build first)" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>es</string>
	</array>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>${BUNDLE_ID}.oauth</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>${CLI_NAME}</string>
			</array>
		</dict>
	</array>
	<key>SUFeedURL</key>
	<string>https://github.com/gilitos92/AllowanceBar/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>7o1HfBuTkUSilLky6JprZxUSSOY0dZFt23kO68roYrQ=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
</dict>
</plist>
PLIST

# Sign inside-out (--deep is discouraged): Sparkle.framework, including its
# XPC services, before the app. Every build gets the hardened runtime, which
# makes the app ignore DYLD_* environment variables so other processes cannot
# inject code that inherits its Keychain access. Only Developer ID builds get
# a secure timestamp (needed for notarization; Apple's timestamp server
# rejects other certificates). Builds without a Team ID (self-signed or
# ad-hoc) also need the entitlement that turns off library validation, or the
# runtime would refuse to load Sparkle.
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == *"Developer ID"* ]]; then
    SIGN_FLAGS+=(--timestamp)
else
    SIGN_FLAGS+=(--entitlements Resources/AllowanceBar.entitlements)
fi
for xpc in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc; do
    codesign "${SIGN_FLAGS[@]}" "$xpc"
done
codesign "${SIGN_FLAGS[@]}" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/${CLI_NAME}"
codesign "${SIGN_FLAGS[@]}" "$APP"

echo "Built $PWD/$APP (version ${VERSION}, identity: ${SIGN_IDENTITY})"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/$APP"
fi
