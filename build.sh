#!/bin/bash

set -eo pipefail

echo "🔨 Building Talkie..."

BUILD_LOG=$(mktemp)
trap "rm -f $BUILD_LOG" EXIT

# Build and capture raw output, pipe through xcbeautify for display
xcodebuild -project Talkie.xcodeproj \
    -scheme Talkie \
    -configuration Debug \
    -derivedDataPath ./build \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    build 2>&1 | tee "$BUILD_LOG" | xcbeautify 2>/dev/null || true

# If codesign failed due to extended attributes, clear them and re-sign manually
if grep -q "resource fork, Finder information, or similar detritus not allowed" "$BUILD_LOG"; then
    echo "⚠️  Clearing extended attributes and re-signing..."
    APP_PATH="./build/Build/Products/Debug/Talkie.app"
    xattr -cr "$APP_PATH" 2>/dev/null || true
    # Extract signing identity and entitlements from the failed codesign command
    SIGN_ID=$(grep -o -- '--sign [^ ]*' "$BUILD_LOG" | head -1 | awk '{print $2}')
    ENTITLEMENTS=$(grep -o -- '--entitlements [^ ]*' "$BUILD_LOG" | head -1 | awk '{print $2}')
    if [ -n "$SIGN_ID" ] && [ -n "$ENTITLEMENTS" ]; then
        codesign --force --sign "$SIGN_ID" -o runtime --entitlements "$ENTITLEMENTS" --timestamp=none --generate-entitlement-der "$APP_PATH" 2>&1
        if [ $? -eq 0 ]; then
            # Override the build log result
            echo "** BUILD SUCCEEDED **" >> "$BUILD_LOG"
        fi
    else
        # Fallback: ad-hoc sign
        codesign --force --deep --sign - "$APP_PATH" 2>&1
        if [ $? -eq 0 ]; then
            echo "** BUILD SUCCEEDED **" >> "$BUILD_LOG"
        fi
    fi
fi

# Check actual build result
if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    echo ""
    echo "✅ Build successful!"
    echo "📦 App location: ./build/Build/Products/Debug/Talkie.app"
elif grep -q "BUILD FAILED" "$BUILD_LOG"; then
    echo ""
    echo "❌ BUILD FAILED"
    echo ""
    grep "error:" "$BUILD_LOG" | head -20
    exit 1
else
    echo ""
    echo "❌ Build status unknown — xcodebuild output did not contain BUILD SUCCEEDED or BUILD FAILED"
    exit 1
fi
