# Releasing Allowance Bar

Allowance Bar ships as a signed `.app` (with the `allowancebar` CLI inside at
`Contents/Helpers/allowancebar`), zipped and attached to a GitHub Release
together with a Sparkle `appcast.xml`. Releases are cut **locally** with
`scripts/release.sh`; there is no GitHub Actions workflow.

Releases are signed with the project's **Developer ID Application**
certificate (team `GC28C3K5G9`) and **notarized** by Apple, so the app opens
without a Gatekeeper warning. Releases up to 2.9.2 were signed with the
self-signed **GGV** certificate and not notarized.

## What a release contains

| Artifact | Produced by | Notes |
|----------|-------------|-------|
| `Allowance Bar.app` | `scripts/bundle.sh` | Compiles the String Catalog, builds the `AllowanceBar` and `allowancebar-cli` products, embeds Sparkle.framework, writes Info.plist (version, `allowancebar://` URL scheme, Sparkle keys), signs inside-out: XPC services → Sparkle → `Helpers/allowancebar` → app. |
| `AllowanceBar.zip` | `scripts/release.sh` | `ditto`-zipped after notarization and stapling; `release.sh` unzips it and checks the team, hardened runtime, staple and "Notarized Developer ID" before writing the appcast. |
| `appcast.xml` | `scripts/release.sh` (`generate_appcast`) | EdDSA-signed Sparkle feed. Must be uploaded with the zip. |

## Credentials

Nothing is stored in GitHub or the repo.

| Credential | Location |
|------------|----------|
| Code-signing identity "Developer ID Application: … (GC28C3K5G9)" | login Keychain |
| Notarization: App Store Connect API key (Developer role) | login Keychain, as notarytool profile `AllowanceBar` |
| Sparkle EdDSA private key | login Keychain, account `AllowanceBar` |
| Old self-signed identity `GGV` (no longer used for releases) | login Keychain |

Backups, all in 1Password vault Personal:

- Developer ID: the `.p12` file and its password are in the Developer ID
  item (file "Developer ID Application - GC28C3K5G9").
- App Store Connect API key: the `.p8` contents are in its own item.
- Sparkle keys and the old `GGV.p12`: item **"Allowance Bar Release Keys"**.

Restore on a new Mac (delete the copied `.p12` and `.p8` afterwards):

```bash
security import DeveloperID.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
# Key ID and issuer ID: App Store Connect → Users and Access → Integrations.
xcrun notarytool store-credentials AllowanceBar --key AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> --issuer <ISSUER_ID>
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account AllowanceBar -f <private-key-file>
```

Why a Developer ID: a Keychain item remembers which apps may read it in a
*partition list*. An app signed by an Apple-issued certificate with a team ID
gets the partition `teamid:GC28C3K5G9`, which stays the same for every build
and survives certificate renewals. A certificate without a team ID (the old
GGV certificate, or ad-hoc signing) gets `cdhash:<fingerprint of this
build>` instead, so every build and every update asked for Keychain access
again. Claude credential reads still go through Apple's trusted `security`
tool, because Claude Code can reset its own item's partition grant during
token renewal.

The signature shows the certificate holder's legal name ("Developer ID
Application: GILBERTO GOMEZ VALADEZ"); Apple issues individual certificates
that way. Never sign public builds with the Apple Development certificate: it
is meant for testing, not distribution.

Never re-create the Sparkle key casually: a new Sparkle key means shipped apps
can never auto-update again. The EdDSA key also carried updates across the
GGV → Developer ID change (see "Sparkle auto-updates").

## Sparkle auto-updates

- `SUFeedURL` is
  `https://github.com/gilitos92/AllowanceBar/releases/latest/download/appcast.xml`;
  GitHub redirects it to the newest (non-prerelease) release's asset.
- `scripts/release.sh` runs `generate_appcast --account AllowanceBar`, which
  signs the zip with the private key; the matching public key is
  `SUPublicEDKey` in `scripts/bundle.sh`.
- Upload **both** `AllowanceBar.zip` and `appcast.xml` as release assets.
- Sparkle accepts an app update when **either** its EdDSA signature matches
  the installed app's `SUPublicEDKey` **or** its code signature matches the
  installed app's designated requirement (`SUUpdateValidator.m`,
  `validateUpdateForHost:`; "allows change of Code Signing identity"). The
  EdDSA key did not change, so the first Developer ID release installs
  automatically over GGV-signed 2.9.2 and earlier. Never change the EdDSA key
  and the signing certificate in the same release.

## Cutting a release

1. Update `CHANGELOG.md`. Run `swift test` and, for user-visible changes,
   install a dev bundle (`ALLOWANCEBAR_VERSION=X.Y.Z-dev scripts/bundle.sh --install`)
   and verify with `open` + `allowancebar status`.
2. Branch `Release-X.Y.Z` from `Development`, commit "Prepare Allowance Bar
   X.Y.Z release", merge `--no-ff` into `main` and `Development`.
3. Build, sign, and write the appcast:
   ```bash
   ALLOWANCEBAR_VERSION=X.Y.Z scripts/release.sh   # Developer ID + notarization
   ```
   It signs with the Developer ID identity, submits the zip to Apple's
   notary service (usually a few minutes), staples the ticket, re-zips,
   verifies the zipped copy, and only then writes the EdDSA-signed appcast.
   (Approve Keychain prompts for the Developer ID key or the Sparkle key with
   "Always Allow" if they appear.)
4. Tag `main` and publish with BOTH assets:
   ```bash
   git tag vX.Y.Z && git push origin main Development vX.Y.Z
   gh release create vX.Y.Z AllowanceBar.zip appcast.xml \
     --title "Allowance Bar X.Y.Z" --notes "..."
   ```
   Release notes say the build is signed with Developer ID and notarized.
5. Install locally to verify (`cp -R "Allowance Bar.app" /Applications/`;
   `allowancebar --version` reports the new version).

Versioning: MINOR for features, PATCH for fixes and small UX follow-ups.

`release.sh` picks the team's Developer ID identity by itself; set
`SIGN_IDENTITY` (SHA-1 or name) to choose one, for example while an old and a
renewed certificate overlap. It refuses to release without a Developer ID.
Set `NOTARY_PROFILE` for another notarytool profile, or
`APPLE_API_KEY_ID`/`APPLE_API_ISSUER`/`APPLE_API_KEY` to skip the profile.

`scripts/bundle.sh` also signs local builds with the Developer ID identity
when it is in the keychain (with a secure timestamp, so it needs the
network), so a dev build installed over the release keeps the Keychain
grant. Without that identity it signs ad-hoc and adds
`Resources/AllowanceBar.entitlements`, so Sparkle still loads. Every build
uses the hardened runtime.

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
