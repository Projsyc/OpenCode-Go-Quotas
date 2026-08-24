#!/usr/bin/env bash
# 一键构建 OpenCodeGo 安装包(icns + dmg)。
# 用法: bash tools/build-dmg.sh
# 前置: 本仓库 swift 构建(swift build -c release);pip3 install --user ds_store
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/OpenCodeGo.app"
BIN="$ROOT/.build/release/OpenCodeGo"
OUT="$HOME/Desktop/OpenCodeGo-1.0.dmg"

echo "==> 1/5 渲染图标"
swift "$ROOT/tools/render-icon.swift"

echo "==> 2/5 生成 icns 并装入 bundle"
iconutil -c icns /tmp/icon/AppIcon.iconset -o /tmp/icon/AppIcon.icns
mkdir -p "$DIST/Contents/Resources"
cp /tmp/icon/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"
PLIST="$DIST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"

echo "==> 3/5 符号 + 渲染背景"
codesign --force --deep -s - "$DIST"
swift "$ROOT/tools/render-dmg-background.swift"

echo "==> 4/5 组装 staging + DS_Store 布局"
STAGE="$HOME/Library/Caches/ocg-dmg-new"
mkdir -p "$STAGE/.background"
cp -R "$DIST" "$STAGE/"
cp /tmp/dmg-background.png "$STAGE/.background/background.png"
ln -sf /Applications "$STAGE/Applications"
touch "$STAGE/.DS_Store"
python3 "$ROOT/tools/make-dsstore.py" "$STAGE" "OpenCodeGo"
SetFile -a V "$STAGE/.background" "$STAGE/.DS_Store"

echo "==> 5/5 hdiutil 打包"
rm -f "$OUT"
hdiutil create -volname "OpenCodeGo" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
echo "==> 完成: $OUT"
