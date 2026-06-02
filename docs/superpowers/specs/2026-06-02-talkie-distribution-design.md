# Talkie Distribution + Auto-Update — Design

**Date:** 2026-06-02
**Status:** Approved (design)

## Goal

Distribute Talkie to a small group (the author + friends) outside the Mac App Store
with (1) a natural install experience and (2) automatic update push, using the
author's existing Apple Developer account.

## Decisions

| Topic            | Decision                                                            |
|------------------|---------------------------------------------------------------------|
| Update mechanism | **Sparkle 2.x** via Swift Package Manager                           |
| Hosting          | **GitHub Releases** (DMG as release asset; `appcast.xml` in repo)   |
| Repo visibility  | **Public** (Sparkle fetches feed + DMG with no auth)               |
| Install artifact | **DMG** with drag-to-Applications layout                           |
| First install    | Share the GitHub Release link (no landing page — easy to add later)|
| Signing          | **Developer ID Application** + hardened runtime + **notarization** |

## Context (current state)

- App is **non-sandboxed** (required for Accessibility / global-hotkey APIs) → non-MAS distribution.
- Signing: `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = PH43TLJ5WH`.
- Bundle ID: `com.wenbopan.Talkie`. Current version: `MARKETING_VERSION = 1.3.1`, `CURRENT_PROJECT_VERSION = 1`.
- Entitlements (`Talkie/Talkie.entitlements`): app-sandbox **false**, audio-input, user-selected files read-only, network client.
- No Developer ID Application certificate currently in the keychain (only Xcode-managed dev certs).
- Existing `build.sh` (Debug → logs) and `release.sh` (Release → `/Applications`) are kept as the local dev flow; the distribution pipeline is **additive**.
- Xcode project uses folder-based file membership; SwiftPM already in use (KeyboardShortcuts).

## Architecture

Five pieces:

1. **Code signing & notarization** — release builds use a **Developer ID Application**
   certificate with **hardened runtime** (`-o runtime`), then are notarized via
   `xcrun notarytool` and stapled with `xcrun stapler`. This removes the
   "unidentified developer" / "damaged app" Gatekeeper warnings on friends' Macs.

2. **Sparkle integration** — add the Sparkle 2.x SPM package. Add Info.plist keys:
   - `SUFeedURL` → raw GitHub URL of `appcast.xml`
   - `SUPublicEDKey` → the EdDSA public key
   - `SUEnableAutomaticChecks` → `true`
   Wire an `SPUStandardUpdaterController` into the app and add a
   **"Check for Updates…"** menu item. Generate a one-time **EdDSA key pair**
   (private key in the login keychain, public key embedded in the app).

3. **Release artifact** — a signed + notarized + stapled **DMG** with a
   drag-to-Applications layout.

4. **Appcast feed** — `appcast.xml` with one `<item>` per version
   (download URL, version, EdDSA signature, file length, release notes).
   Committed to the public repo; `SUFeedURL` points at the stable raw URL.

5. **Distribution** — one **GitHub Release** per version (via `gh`), DMG attached
   as an asset.

## Release pipeline (one command)

A new distribution script (separate from the local `release.sh`, e.g.
`distribute.sh <version>`) performs end to end:

1. Bump `MARKETING_VERSION` (+ `CURRENT_PROJECT_VERSION`) to the given version.
2. `xcodebuild archive` → `xcodebuild -exportArchive` with Developer ID export
   options (hardened runtime).
3. Notarize the app with `notarytool`, staple.
4. Build the DMG (drag-to-Applications), notarize + staple the DMG.
5. Sparkle `sign_update` → EdDSA signature + file size.
6. Prepend a new `<item>` to `appcast.xml` (version, URL, signature, length, notes).
7. `git commit` appcast + version bump, `git tag`, push.
8. `gh release create <tag>` with the DMG attached.

After this, every installed copy detects the update and friends click "Install Update".

## Data flow (updates)

Installed app → polls `SUFeedURL` (appcast.xml on GitHub) on schedule → sees newer
`<item>` → downloads DMG from the release asset → verifies EdDSA signature against
embedded public key → verifies Developer ID + notarization → installs in place →
relaunches.

## One-time prerequisites (guided)

- Create a **Developer ID Application** certificate (Xcode → Settings → Accounts →
  Manage Certificates, or developer.apple.com). Lands in the keychain.
- Create notarization credentials — an **App Store Connect API key** (preferred) or
  app-specific password — stored once via `notarytool store-credentials`.
- Generate the Sparkle **EdDSA keys** via Sparkle's `generate_keys` tool.

## Error handling

- Build script uses `set -euo pipefail`; fails loudly if archive/export/notarize fails.
- Notarization: poll with `notarytool submit --wait`; on rejection, fetch and print
  the notarization log.
- Verify before publishing: `codesign --verify --deep --strict`, `spctl -a -vvv`,
  `xcrun stapler validate` on both app and DMG. Abort the release if any fail.
- Re-sign-after-xattr-clear fallback from the existing scripts is preserved where relevant.

## Testing

- **Signing/notarization:** `codesign --verify --deep --strict`, `spctl -a -vvv`,
  `xcrun stapler validate` pass on the app and DMG.
- **Gatekeeper sim:** quarantine-attribute a copy and confirm it opens without warning.
- **Update loop end-to-end:** install vN, release vN+1, confirm the in-app updater
  detects, downloads, verifies (EdDSA), installs, and relaunches into vN+1.

## Scope (YAGNI)

- No landing page (share GitHub link; trivial to add later).
- No delta updates, no beta channels, no self-hosted appcast.
- Local dev flow (`build.sh`, `release.sh` → `/Applications`) unchanged.

## Open items / risks

- The author must create the Developer ID cert + notarization credentials before the
  first real distribution build — these are account actions Claude cannot perform.
- Sparkle framework + XPC services must be correctly embedded and signed under the
  hardened runtime during `archive`/`exportArchive` (Xcode handles this when added via
  SPM; verified in the testing step).
