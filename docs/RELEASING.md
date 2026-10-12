# Releasing Allowance Bar

Allowance Bar ships as a signed `.app` (with the `allowancebar` CLI inside at
`Contents/Helpers/allowancebar`), zipped and attached to a GitHub Release
together with a Sparkle `appcast.xml`. Releases are cut **locally** with
`scripts/release.sh`; there is no GitHub Actions release workflow (CI only
builds and tests).

Builds are signed with the self-signed **GGV** certificate and are **not
notarized** (no paid Apple Developer Program membership). Users approve the
app once in System Settings → Privacy & Security → Open Anyway; Sparkle
updates install afterwards without that step.

## What a release contains

| Artifact | Produced by | Notes |
|----------|-------------|-------|
| `Allowance Bar.app` | `scripts/bundle.sh` | Compiles the String Catalog, builds the `AllowanceBar` and `allowancebar-cli` products, embeds Sparkle.framework, writes Info.plist (version, `allowancebar://` URL scheme, Sparkle keys), signs inside-out: XPC services → Sparkle → `Helpers/allowancebar` → app. |
| `AllowanceBar.zip` | `scripts/release.sh` | `ditto`-zipped. Notarized and stapled only with a Developer ID identity. |
| `appcast.xml` | `scripts/release.sh` (`generate_appcast`) | EdDSA-signed Sparkle feed. Must be uploaded with the zip. |

## Credentials

Nothing is stored in GitHub or the repo.

| Credential | Location |
|------------|----------|
| Code-signing identity `GGV` (self-signed, CN=GGV, no Team ID) | login Keychain |
| Sparkle EdDSA private key | login Keychain, account `AllowanceBar` |

Both are backed up in one 1Password item, **"Allowance Bar Release Keys"**
(vault Personal): the Sparkle private and public keys, the attached
`GGV.p12`, and its password.

Restore on a new Mac:

```bash
security import GGV.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account AllowanceBar -f <private-key-file>
```

Why self-signed instead of ad-hoc: macOS ties Keychain "Always Allow"
grants to the code signature's designated requirement. Ad-hoc signatures
change with every build, so users would be re-prompted after each update; a
stable certificate keeps the trusted-app identity. This does not prevent
Claude Code from resetting the item's separate partition grant during token
renewal, so Claude credential reads use Apple's trusted `security` tool.
The certificate shows only "GGV".

Never re-create the GGV certificate or the Sparkle key casually: a new
certificate re-triggers Keychain prompts for every user, and a new Sparkle
key means shipped apps can never auto-update again.

## Sparkle auto-updates

- `SUFeedURL` is
  `https://github.com/gilitos92/AllowanceBar/releases/latest/download/appcast.xml`;
  GitHub redirects it to the newest (non-prerelease) release's asset.
- `scripts/release.sh` runs `generate_appcast --account AllowanceBar`, which
  signs the zip with the private key; the matching public key is
  `SUPublicEDKey` in `scripts/bundle.sh`.
- Upload **both** `AllowanceBar.zip` and `appcast.xml` as release assets.

## Cutting a release

1. Update `CHANGELOG.md`. Run `swift test` and, for user-visible changes,
   install a dev bundle (`ALLOWANCEBAR_VERSION=X.Y.Z-dev scripts/bundle.sh --install`)
   and verify with `open` + `allowancebar status`.
2. Branch `Release-X.Y.Z` from `Development`, commit "Prepare Allowance Bar
   X.Y.Z release", merge `--no-ff` into `main` and `Development`.
3. Build, sign, and write the appcast:
   ```bash
   ALLOWANCEBAR_VERSION=X.Y.Z scripts/release.sh   # SIGN_IDENTITY defaults to GGV
   ```
   (Approve Keychain prompts for the GGV key or the Sparkle key with
   "Always Allow" if they appear.)
4. Tag `main` and publish with BOTH assets:
   ```bash
   git tag vX.Y.Z && git push origin main Development vX.Y.Z
   gh release create vX.Y.Z AllowanceBar.zip appcast.xml \
     --title "Allowance Bar X.Y.Z" --notes "..."
   ```
   Release notes say the build is signed with a self-signed certificate and
   not notarized, with the "Open Anyway" first-launch step.
5. Install locally to verify (`cp -R "Allowance Bar.app" /Applications/`;
   `allowancebar --version` reports the new version).

Versioning: MINOR for features, PATCH for fixes and small UX follow-ups.

With a Developer ID later: pass `SIGN_IDENTITY="Developer ID Application: …"`
plus `NOTARY_PROFILE` (or `APPLE_API_KEY_ID`/`APPLE_API_ISSUER`/`APPLE_API_KEY`);
`release.sh` then adds a secure timestamp, notarizes, and staples. Every
build already uses the hardened runtime; builds without a Team ID add
`Resources/AllowanceBar.entitlements` so the self-signed Sparkle framework loads. Switching
identity changes the designated requirement, so users see Keychain prompts once.

### Local packaging checks

- Use the complete `scripts/bundle.sh` flow. It adds
  `@executable_path/../Frameworks` to the executable's runtime search paths;
  replacing the executable afterward loses that step and can prevent Sparkle
  from loading. Verify the packaged executable with `otool -l` before signing.
- Build and sign outside iCloud Documents if File Provider adds Finder metadata
  that causes code signing to reject the bundle. A clean `/private/tmp` source
  checkout is suitable for release staging.
- Verify the final bundle's signature (`codesign --verify --deep --strict`), then launch the installed
  app and check `allowancebar doctor` plus a fresh `allowancebar refresh --wait 15`
  snapshot. A valid signature alone does not prove the app can launch.
- Before the launch check, temporarily rename the staging checkout's `.build`
  directory so SwiftPM's generated absolute resource fallback cannot resolve.
  The installed app must launch and refresh using only its embedded resources.
  Restore the directory afterward. `L()` resolves the packaged resource bundle
  under `Contents/Resources`; SwiftPM's generated `Bundle.module` alone looks
  in a different location and can mask a broken package while build files exist.
