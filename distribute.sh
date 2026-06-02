#!/bin/bash
set -euo pipefail

# Usage: ./distribute.sh <version>   e.g. ./distribute.sh 1.3.2
# One-command Developer ID release: archive -> notarize -> DMG -> sign -> appcast -> GitHub Release.

APP_NAME="Talkie"
SCHEME="Talkie"
BUNDLE_ID="com.wenbopan.Talkie"
TEAM_ID="HJDT6NYKJC"
REPO="wbopan/Talkie"
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
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
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
import sys
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
