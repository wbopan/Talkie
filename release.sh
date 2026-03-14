#!/bin/bash

set -e

APP_NAME="Seedling"
BUILD_DIR="./build"
DEST="/Applications"

echo "🔨 Building $APP_NAME (Release)..."

BUILD_LOG=$(mktemp)
trap "rm -f $BUILD_LOG" EXIT

xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath "$BUILD_DIR" \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    build 2>&1 | tee "$BUILD_LOG" | grep -E "error:|warning:" || true

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

# If codesign failed due to extended attributes, clear them and re-sign manually
if grep -q "resource fork, Finder information, or similar detritus not allowed" "$BUILD_LOG"; then
    echo "⚠️  Clearing extended attributes and re-signing..."
    xattr -cr "$APP_PATH" 2>/dev/null || true
    SIGN_ID=$(grep -o -- '--sign [^ ]*' "$BUILD_LOG" | head -1 | awk '{print $2}')
    ENTITLEMENTS=$(grep -o -- '--entitlements [^ ]*' "$BUILD_LOG" | head -1 | awk '{print $2}')
    if [ -n "$SIGN_ID" ] && [ -n "$ENTITLEMENTS" ]; then
        codesign --force --sign "$SIGN_ID" -o runtime --entitlements "$ENTITLEMENTS" --timestamp=none --generate-entitlement-der "$APP_PATH"
    else
        codesign --force --deep --sign - "$APP_PATH"
    fi
fi

if [ ! -d "$APP_PATH" ] || ! codesign -v "$APP_PATH" 2>/dev/null; then
    echo "❌ Build failed"
    exit 1
fi

echo "📦 Installing to $DEST..."
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP_PATH" "$DEST/"

echo "✅ Installed: $DEST/$APP_NAME.app"
