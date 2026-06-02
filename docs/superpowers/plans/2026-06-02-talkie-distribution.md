# Talkie Distribution + Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Talkie to friends as a signed + notarized DMG installed from GitHub Releases, with in-app Sparkle auto-updates driven by a one-command release script.

**Architecture:** Add Sparkle 2.x (SPM) for in-app updates; sign release builds with a Developer ID Application cert under the hardened runtime; notarize + staple the app and a drag-to-Applications DMG; publish each version as a GitHub Release with a committed `appcast.xml` feed that Sparkle polls.

**Tech Stack:** Swift / AppKit, Sparkle 2.x, Xcode `xcodebuild` (archive/exportArchive), `xcrun notarytool`/`stapler`, `create-dmg`, `gh` (GitHub CLI), bash.

> **Note on verification style:** This is a build/signing/distribution pipeline, not unit-testable logic. Each task's "test" is a concrete verification command with expected output (build succeeds, `codesign`/`spctl`/`stapler` pass, the update is detected). Treat those as the test gates.

---

## Spec reference

Implements [docs/superpowers/specs/2026-06-02-talkie-distribution-design.md](../specs/2026-06-02-talkie-distribution-design.md).

## File structure

- `Config/Info.plist` — **Create.** Holds the three Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`); merged with Xcode's generated plist. Kept *outside* the synchronized `Talkie/` folder so folder-based membership doesn't wrongly copy it as a bundle resource.
- `Talkie/AppDelegate.swift` — **Modify.** Add Sparkle import, an `SPUStandardUpdaterController`, and a "Check for Updates…" menu item.
- `Talkie.xcodeproj/project.pbxproj` — **Modify.** Add the Sparkle SPM dependency; set `INFOPLIST_FILE`.
- `ExportOptions.plist` — **Create.** Developer ID export config for `xcodebuild -exportArchive`.
- `appcast.xml` — **Create.** Sparkle update feed (one `<item>` per version).
- `distribute.sh` — **Create.** One-command release pipeline.
- `docs/RELEASING.md` — **Create.** One-time setup + how-to-release notes.

The bundle ID is `com.wenbopan.Talkie`, team `PH43TLJ5WH`, current version `1.3.1` (build `1`). The GitHub repo slug is referenced as `<OWNER>/<REPO>` — resolve it once in Task 1 and use the literal value thereafter.

---

### Task 0: One-time account prerequisites (manual, guided)

These are Apple-account / keychain actions the engineer must perform once. They cannot be scripted. Do them before Task 7's first real release.

**Files:** none.

- [ ] **Step 1: Resolve the GitHub repo slug**

Run: `gh repo view --json nameWithOwner -q .nameWithOwner`
Expected: prints something like `wenbopan/Talkie`. Record this as `<OWNER>/<REPO>` for later tasks. If it errors, run `gh auth login` first.

- [ ] **Step 2: Create a Developer ID Application certificate**

In Xcode: Settings → Accounts → select the team (`PH43TLJ5WH`) → Manage Certificates → "+" → **Developer ID Application**. (Or create at developer.apple.com → Certificates.)

Verify:
Run: `security find-identity -v -p codesigning`
Expected: a line containing `Developer ID Application: ... (PH43TLJ5WH)`.

- [ ] **Step 3: Store notarization credentials**

Create an App Store Connect API key (App Store Connect → Users and Access → Integrations → App Store Connect API → "+", role "Developer"). Download the `.p8`, note the Key ID and Issuer ID. Then:

```bash
xcrun notarytool store-credentials "talkie-notary" \
  --key /path/to/AuthKey_XXXXXXXX.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Verify:
Run: `xcrun notarytool history --keychain-profile "talkie-notary" | head`
Expected: prints a (possibly empty) submission history without an auth error.

---

### Task 1: Add Sparkle SPM dependency

**Files:**
- Modify: `Talkie.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFrameworksBuildPhase, packageProductDependencies, packageReferences, XCRemoteSwiftPackageReference, XCSwiftPackageProductDependency sections)

- [ ] **Step 1: Add the PBXBuildFile entry**

In `Talkie.xcodeproj/project.pbxproj`, find the `/* Begin PBXBuildFile section */` block and add a line after the KeyboardShortcuts build file:

```
		C1D2E3F405162738495A6B7C /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = C2D3E4F506172839405B6C7D /* Sparkle */; };
```

- [ ] **Step 2: Add Sparkle to the Frameworks build phase**

In `/* Begin PBXFrameworksBuildPhase section */`, inside the `files = ( ... )` list (after the KeyboardShortcuts line), add:

```
				C1D2E3F405162738495A6B7C /* Sparkle in Frameworks */,
```

- [ ] **Step 3: Add Sparkle to the target's packageProductDependencies**

In the `PBXNativeTarget`/group `packageProductDependencies = ( ... )` list (the one already listing LaunchAtLogin and KeyboardShortcuts), add:

```
				C2D3E4F506172839405B6C7D /* Sparkle */,
```

- [ ] **Step 4: Add the package reference to the project**

In `/* Begin PBXProject section */`, inside `packageReferences = ( ... )`, add:

```
				C3D4E5F607182940516C7D8E /* XCRemoteSwiftPackageReference "Sparkle" */,
```

- [ ] **Step 5: Add the XCRemoteSwiftPackageReference**

In `/* Begin XCRemoteSwiftPackageReference section */`, add a new entry alongside the existing ones:

```
		C3D4E5F607182940516C7D8E /* XCRemoteSwiftPackageReference "Sparkle" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/sparkle-project/Sparkle";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 2.6.0;
			};
		};
```

- [ ] **Step 6: Add the XCSwiftPackageProductDependency**

In `/* Begin XCSwiftPackageProductDependency section */`, add:

```
		C2D3E4F506172839405B6C7D /* Sparkle */ = {
			isa = XCSwiftPackageProductDependency;
			package = C3D4E5F607182940516C7D8E /* XCRemoteSwiftPackageReference "Sparkle" */;
			productName = Sparkle;
		};
```

- [ ] **Step 7: Resolve packages**

Run: `xcodebuild -project Talkie.xcodeproj -scheme Talkie -resolvePackageDependencies -derivedDataPath ./build`
Expected: ends with `Resolved source packages:` listing `Sparkle` among the packages, exit code 0.

- [ ] **Step 8: Confirm the Sparkle tools were fetched**

Run: `fd sign_update ./build/SourcePackages/artifacts 2>/dev/null | head -1`
Expected: prints a path to a `sign_update` binary (e.g. `./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update`). This path is used by `distribute.sh`. If empty, the package didn't resolve — re-check Step 5–7.

- [ ] **Step 9: Commit**

```bash
git add Talkie.xcodeproj/project.pbxproj
git commit -m "build: add Sparkle SPM dependency"
```

---

### Task 2: Generate Sparkle EdDSA signing keys

**Files:** none committed (private key goes to the login keychain; public key captured for Task 3).

- [ ] **Step 1: Locate generate_keys**

Run: `fd generate_keys ./build/SourcePackages/artifacts 2>/dev/null | head -1`
Expected: a path like `./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`. Save it as `$GEN`.

- [ ] **Step 2: Generate the key pair**

Run: `"$GEN"` (the generate_keys path from Step 1)
Expected: stores the private key in the login keychain and prints a public key line:
`<string>BASE64_PUBLIC_KEY=</string>` plus instructions. If keys already exist it says so and prints the existing public key with `-p`.

- [ ] **Step 3: Print the public key for Info.plist**

Run: `"$GEN" -p`
Expected: prints the base64 EdDSA public key (single token). Record it as `<SPARKLE_PUBLIC_KEY>` for Task 3, Step 1.

> The private key never leaves the keychain and is never committed. Back it up via `"$GEN" -x sparkle_private_key.txt` stored somewhere safe (1Password etc.), then delete the file — losing it means you can never push verified updates to already-installed copies.

---

### Task 3: Add Sparkle Info.plist keys

**Files:**
- Create: `Talkie/Info.plist`
- Modify: `Talkie.xcodeproj/project.pbxproj` (both build configurations: add `INFOPLIST_FILE`)

- [ ] **Step 1: Create `Talkie/Info.plist`**

Replace `<SPARKLE_PUBLIC_KEY>` with the value from Task 2 Step 3, and `<OWNER>/<REPO>` with the slug from Task 1 Step 1:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/<OWNER>/<REPO>/main/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string><SPARKLE_PUBLIC_KEY></string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 2: Point both build configs at the Info.plist**

In `Talkie.xcodeproj/project.pbxproj`, both build configurations currently have `GENERATE_INFOPLIST_FILE = YES;` (around lines 286 and 331). Immediately after each `GENERATE_INFOPLIST_FILE = YES;` line, add:

```
				INFOPLIST_FILE = Talkie/Info.plist;
```

With `GENERATE_INFOPLIST_FILE = YES` still set, Xcode merges its generated keys (bundle id, versions, etc.) on top of this file, so the Sparkle keys are added without losing anything.

- [ ] **Step 3: Build and confirm the keys land in the bundle**

Run: `./build.sh`
Expected: `✅ Build successful!`

Then verify the merged plist:
Run: `/usr/libexec/PlistBuddy -c "Print :SUFeedURL" ./build/Build/Products/Debug/Talkie.app/Contents/Info.plist`
Expected: prints the feed URL. Repeat for `:SUPublicEDKey` (prints the base64 key) and `:CFBundleIdentifier` (prints `com.wenbopan.Talkie`, proving the generated keys still merged in).

- [ ] **Step 4: Commit**

```bash
git add Talkie/Info.plist Talkie.xcodeproj/project.pbxproj
git commit -m "feat: add Sparkle Info.plist feed + public key"
```

---

### Task 4: Wire the Sparkle updater + "Check for Updates…" menu item

**Files:**
- Modify: `Talkie/AppDelegate.swift` (imports near line 12; properties near line 16; `setupStatusItem()` menu near line 99)

- [ ] **Step 1: Import Sparkle**

In `Talkie/AppDelegate.swift`, after `import KeyboardShortcuts` (line 12), add:

```swift
import Sparkle
```

- [ ] **Step 2: Add the updater controller property**

In the `// MARK: - Properties` block, after `private let settings = AppSettings.shared` add:

```swift
    /// Sparkle updater. `startingUpdater: true` begins automatic background checks per Info.plist.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

- [ ] **Step 3: Add the menu item**

In `setupStatusItem()`, between the `Settings...` item and the `Quit` item, add a "Check for Updates…" item. Replace this existing block:

```swift
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
```

with:

```swift
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
```

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: `✅ Build successful!`

- [ ] **Step 5: Manually verify the menu item**

Run: `open ./build/Build/Products/Debug/Talkie.app`
Then click the menu bar icon. Expected: a "Check for Updates..." item appears between "Settings..." and "Quit". Clicking it shows Sparkle's "checking for updates" UI (it will say it's up to date / can't reach the feed until the appcast is live — that's fine; the goal here is the wiring works without crashing). Quit the app afterward.

- [ ] **Step 6: Commit**

```bash
git add Talkie/AppDelegate.swift
git commit -m "feat: wire Sparkle updater and Check for Updates menu item"
```

---

### Task 5: Create the Developer ID export options

**Files:**
- Create: `ExportOptions.plist`

- [ ] **Step 1: Create `ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>PH43TLJ5WH</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
git add ExportOptions.plist
git commit -m "build: add Developer ID export options"
```

---

### Task 6: Create the initial appcast feed

**Files:**
- Create: `appcast.xml`

- [ ] **Step 1: Create an empty-but-valid `appcast.xml`**

`distribute.sh` will prepend `<item>` entries inside `<channel>`. Create the skeleton:

```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
	<channel>
		<title>Talkie</title>
		<!-- BEGIN ITEMS -->
		<!-- END ITEMS -->
	</channel>
</rss>
```

- [ ] **Step 2: Commit**

```bash
git add appcast.xml
git commit -m "feat: add initial Sparkle appcast feed"
```

---

### Task 7: Write the release pipeline `distribute.sh`

**Files:**
- Create: `distribute.sh` (chmod +x)

Install the DMG builder first:
Run: `brew list create-dmg >/dev/null 2>&1 || brew install create-dmg`
Expected: `create-dmg` is installed (`which create-dmg` prints a path).

- [ ] **Step 1: Write `distribute.sh`**

Replace `<OWNER>/<REPO>` with the actual slug from Task 1 Step 1.

```bash
#!/bin/bash
set -euo pipefail

# Usage: ./distribute.sh <version>   e.g. ./distribute.sh 1.3.2
# One-command Developer ID release: archive -> notarize -> DMG -> sign -> appcast -> GitHub Release.

APP_NAME="Talkie"
SCHEME="Talkie"
BUNDLE_ID="com.wenbopan.Talkie"
TEAM_ID="PH43TLJ5WH"
REPO="<OWNER>/<REPO>"
NOTARY_PROFILE="talkie-notary"
DERIVED="./build"
DIST="./dist"

VERSION="${1:?Usage: ./distribute.sh <version>  (e.g. 1.3.2)}"
TAG="v${VERSION}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "==> Releasing ${APP_NAME} ${VERSION}"

# --- 0. Preconditions ---
command -v create-dmg >/dev/null || { echo "Missing create-dmg (brew install create-dmg)"; exit 1; }
command -v gh >/dev/null || { echo "Missing gh (brew install gh)"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application certificate in keychain (see docs/RELEASING.md)"; exit 1; }

# Pick the EdDSA sign_update (exclude the legacy old_dsa_scripts copy).
SIGN_UPDATE="$(fd sign_update "${DERIVED}/SourcePackages/artifacts" 2>/dev/null | rg -v old_dsa | head -1 || true)"

# --- 1. Bump versions in pbxproj ---
PBX="Talkie.xcodeproj/project.pbxproj"
CUR_BUILD="$(rg -No 'CURRENT_PROJECT_VERSION = ([0-9]+)' -r '$1' "$PBX" | head -1)"
NEW_BUILD=$(( CUR_BUILD + 1 ))
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${VERSION};/g" "$PBX"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBX"
echo "==> Version ${VERSION} (build ${NEW_BUILD})"

# --- 2. Archive ---
rm -rf "${DIST}"; mkdir -p "${DIST}"
xcodebuild -project Talkie.xcodeproj -scheme "${SCHEME}" -configuration Release \
  -derivedDataPath "${DERIVED}" \
  -archivePath "${DIST}/${APP_NAME}.xcarchive" \
  ENABLE_HARDENED_RUNTIME=YES \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  archive

# --- 3. Export with Developer ID ---
xcodebuild -exportArchive \
  -archivePath "${DIST}/${APP_NAME}.xcarchive" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "${DIST}/export"

APP_PATH="${DIST}/export/${APP_NAME}.app"
[ -d "${APP_PATH}" ] || { echo "Export failed: ${APP_PATH} missing"; exit 1; }

# --- 4. Notarize + staple the app ---
echo "==> Notarizing app..."
ditto -c -k --keepParent "${APP_PATH}" "${DIST}/${APP_NAME}.zip"
xcrun notarytool submit "${DIST}/${APP_NAME}.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"

# --- 5. Build the DMG (drag-to-Applications) ---
echo "==> Building DMG..."
rm -f "${DIST}/${DMG_NAME}"
create-dmg \
  --volname "${APP_NAME}" \
  --window-size 540 380 \
  --icon "${APP_NAME}.app" 140 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  "${DIST}/${DMG_NAME}" "${APP_PATH}"

# --- 6. Sign the DMG, notarize + staple it ---
codesign --force --sign "Developer ID Application" --timestamp "${DIST}/${DMG_NAME}"
echo "==> Notarizing DMG..."
xcrun notarytool submit "${DIST}/${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DIST}/${DMG_NAME}"

# --- 7. Verify Gatekeeper acceptance ---
spctl -a -t open --context context:primary-signature -vvv "${DIST}/${DMG_NAME}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
xcrun stapler validate "${DIST}/${DMG_NAME}"

# --- 8. Sparkle-sign the DMG ---
[ -n "${SIGN_UPDATE}" ] || { echo "sign_update tool not found under ${DERIVED}/SourcePackages/artifacts"; exit 1; }
ED_SIG_LINE="$("${SIGN_UPDATE}" "${DIST}/${DMG_NAME}")"   # prints: sparkle:edSignature="..." length="..."
echo "==> Sparkle signature: ${ED_SIG_LINE}"

# --- 9. Prepend the new <item> into appcast.xml ---
DL_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
PUBDATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM="		<item>
			<title>${VERSION}</title>
			<pubDate>${PUBDATE}</pubDate>
			<sparkle:version>${NEW_BUILD}</sparkle:version>
			<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>26.1</sparkle:minimumSystemVersion>
			<enclosure url=\"${DL_URL}\" type=\"application/octet-stream\" ${ED_SIG_LINE} />
		</item>"
# Insert right after the BEGIN ITEMS marker.
python3 - "$ITEM" <<'PY'
import sys, io
item = sys.argv[1]
with open("appcast.xml", "r", encoding="utf-8") as f:
    content = f.read()
marker = "<!-- BEGIN ITEMS -->"
content = content.replace(marker, marker + "\n" + item, 1)
with open("appcast.xml", "w", encoding="utf-8") as f:
    f.write(content)
PY

# --- 10. Commit, tag, push ---
git add "$PBX" appcast.xml
git commit -m "release: ${APP_NAME} ${VERSION}"
git tag "${TAG}"
git push && git push --tags

# --- 11. Create the GitHub Release with the DMG ---
gh release create "${TAG}" "${DIST}/${DMG_NAME}" \
  --title "${APP_NAME} ${VERSION}" \
  --notes "Talkie ${VERSION}"

echo "==> Done. Installed copies will auto-update from ${DL_URL}"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x distribute.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n distribute.sh`
Expected: no output, exit 0 (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add distribute.sh
git commit -m "build: add one-command distribute.sh release pipeline"
```

---

### Task 8: First real release + end-to-end update verification

**Files:** none (this exercises the pipeline).

- [ ] **Step 1: Cut the first distributed release (1.3.2)**

Run: `./distribute.sh 1.3.2`
Expected: completes through every stage, ending with `==> Done.`. Notarization steps print `status: Accepted`. A GitHub Release `v1.3.2` now exists with `Talkie-1.3.2.dmg` attached.

- [ ] **Step 2: Verify the published artifacts**

Run: `gh release view v1.3.2 --json assets -q '.assets[].name'`
Expected: includes `Talkie-1.3.2.dmg`.

Run: `curl -s https://raw.githubusercontent.com/<OWNER>/<REPO>/main/appcast.xml | rg "1.3.2|edSignature"`
Expected: shows the new `<item>` with `sparkle:shortVersionString` 1.3.2 and an `edSignature`.

- [ ] **Step 3: Verify the DMG opens cleanly (Gatekeeper)**

Run: `open ./dist/Talkie-1.3.2.dmg`
Expected: DMG mounts showing the Talkie icon + Applications drop link, no "unidentified developer" warning. Drag to Applications, launch from /Applications — it opens without a Gatekeeper block. (Optionally test the quarantine path: `xattr -w com.apple.quarantine "0001;0;Safari;" /Applications/Talkie.app` then relaunch — still opens.)

- [ ] **Step 4: Verify the auto-update loop**

Install the 1.3.2 build (from Step 3). Then cut a newer version:
Run: `./distribute.sh 1.3.3`
Expected: succeeds as in Step 1.

Now in the running 1.3.2 app, click menu bar → "Check for Updates...".
Expected: Sparkle reports version 1.3.3 is available, downloads it, verifies the signature, installs, and relaunches. Confirm the relaunched app is 1.3.3:
Run: `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Talkie.app/Contents/Info.plist`
Expected: `1.3.3`.

- [ ] **Step 5: Write the release runbook**

Create `docs/RELEASING.md` capturing: the Task 0 one-time setup (Developer ID cert, `notarytool store-credentials "talkie-notary"`, Sparkle key backup), and the day-to-day command `./distribute.sh <version>`. Note that the Sparkle private key in the login keychain is irreplaceable and must be backed up.

- [ ] **Step 6: Commit the runbook**

```bash
git add docs/RELEASING.md
git commit -m "docs: add release runbook"
```

---

## Self-review notes

- **Spec coverage:** Sparkle integration (Tasks 1–4, 6), Developer ID + notarization (Tasks 0, 5, 7), DMG (Task 7), GitHub Releases distribution (Task 7), one-command pipeline (Task 7), end-to-end update test (Task 8), one-time prereqs (Task 0). All spec sections mapped.
- **Type/name consistency:** `talkie-notary` notary profile, `Developer ID Application` identity, `appcast.xml` `<!-- BEGIN ITEMS -->` marker, and `sign_update` artifact path are referenced identically across Task 0/2/3/7.
- **Known substitutions the engineer must make literal:** `<OWNER>/<REPO>` (Task 1 Step 1), `<SPARKLE_PUBLIC_KEY>` (Task 2 Step 3 → Task 3 Step 1). These are genuine runtime values, not placeholders for logic.
- **Sparkle minimum macOS:** appcast uses `minimumSystemVersion 26.1` to match the project's `MACOSX_DEPLOYMENT_TARGET`.
