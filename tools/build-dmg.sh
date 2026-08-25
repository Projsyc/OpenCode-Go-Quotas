#!/usr/bin/env bash
# 一键构建 OpenCode-Go-Quotas 安装包(icns + dmg)。
# 用法: bash tools/build-dmg.sh
# 前置: 本仓库 swift 构建(swift build -c release);pip3 install --user ds_store
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/OpenCode-Go-Quotas.app"
BIN="$ROOT/.build/release/OpenCode-Go-Quotas"
OUT="$HOME/Desktop/OpenCode-Go-Quotas-0.1.0.dmg"

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
# 优先用 "OpenCodeGo Dev" 证书身份签名(钥匙串 ACL 需求绑定证书而非 CDHash,
# 历次构建免 Keychain 弹窗);身份未导入则退回 ad-hoc。
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "OpenCodeGo Dev"; then
  SIGN_ID="OpenCodeGo Dev"
fi
codesign --force --deep -s "$SIGN_ID" "$DIST"
swift "$ROOT/tools/render-dmg-background.swift"

echo "==> 4/5 组装 staging + DS_Store 布局"
STAGE="$HOME/Library/Caches/ocg-dmg-new"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$DIST" "$STAGE/"
cp /tmp/dmg-background.png "$STAGE/.background/background.png"
ln -sf /Applications "$STAGE/Applications"
touch "$STAGE/.DS_Store"
python3 "$ROOT/tools/make-dsstore.py" "$STAGE" "OpenCode-Go-Quotas"
SetFile -a V "$STAGE/.background" "$STAGE/.DS_Store"

echo "==> 5/5 hdiutil 打包"
rm -f "$OUT"
hdiutil create -volname "OpenCode-Go-Quotas" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
echo "==> 完成: $OUT"
