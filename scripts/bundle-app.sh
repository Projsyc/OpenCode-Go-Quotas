#!/bin/bash
# ============================================================
# 把 SPM 构建产物打包成可直接双击运行的 .app
# 用法: bash scripts/bundle-app.sh [release|debug]  (默认 release)
# ============================================================
set -euo pipefail

# ---- 变量置顶(按需修改) ----
APP_NAME="OpenCodeGo"
BUNDLE_ID="${BUNDLE_ID:-com.acccan.opencode-go}"
VERSION="1.0.0"
MIN_OS="14.0"
CONFIGURATION="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
# ----------------------------

cd "$PROJECT_DIR"

echo "▶ 构建 ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "✗ 未找到构建产物: $BIN_PATH"
  exit 1
fi

echo "▶ 组装 $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>  <string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" 2>/dev/null || true

echo "✅ 完成: $APP_DIR"
echo "   运行: open \"$APP_DIR\""
