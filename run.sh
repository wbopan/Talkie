#!/bin/bash

set -e

echo "🚀 Running Talkie with logs..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_PATH="./build/Build/Products/Debug/Talkie.app"

# 运行应用并显示日志
"$APP_PATH/Contents/MacOS/Talkie" 2>&1
