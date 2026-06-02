# Releasing Talkie

Talkie is distributed outside the Mac App Store: a signed + notarized DMG published
as a GitHub Release, with in-app auto-updates via [Sparkle](https://sparkle-project.org).

## One-time setup

### 1. Developer ID Application certificate

Xcode → Settings → Accounts → select team `PH43TLJ5WH` → Manage Certificates → "+" →
**Developer ID Application**. Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Create an App Store Connect API key (App Store Connect → Users and Access →
Integrations → App Store Connect API → "+", role **Developer**). Download the `.p8`
and note the Key ID and Issuer ID, then store a notarytool profile named
`talkie-notary`:

```bash
xcrun notarytool store-credentials "talkie-notary" \
  --key /path/to/AuthKey_XXXXXXXX.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Verify: `xcrun notarytool history --keychain-profile "talkie-notary" | head`

### 3. Sparkle signing key (already generated)

The EdDSA private key lives in your **login keychain**; the matching public key is
embedded in `Config/Info.plist` as `SUPublicEDKey`.

**⚠️ Back up the private key — it is irreplaceable.** Without it you can never ship a
verified update to already-installed copies. Export it once, store it somewhere safe
(password manager), then delete the file:

```bash
GEN=$(fd generate_keys ./build/SourcePackages/artifacts | head -1)
"$GEN" -x sparkle_private_key.txt   # move this into 1Password, then rm it
```

### 4. Tools

```bash
brew install create-dmg gh
gh auth login   # if not already authenticated
```

## Cutting a release

```bash
./distribute.sh <version>     # e.g. ./distribute.sh 1.3.2
```

This bumps the version, archives with the Developer ID cert under the hardened
runtime, notarizes + staples the app and DMG, Sparkle-signs the DMG, prepends an
entry to `appcast.xml`, commits + tags + pushes, and creates the GitHub Release with
the DMG attached. Installed copies pick up the update automatically (or via menu bar →
"Check for Updates…").

## First install (for friends)

Send them the GitHub Release page:
`https://github.com/wbopan/Talkie/releases/latest` — download the DMG, drag Talkie to
Applications. After that, updates are automatic.
