#!/usr/bin/env bash
# 一键构建 OpenCode-Go-Quotas 安装包(icns + dmg)。
# 用法: bash tools/build-dmg.sh
# 前置: 本仓库 swift 构建(swift build -c release);pip3 install --user ds_store mac-alias
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

echo "==> 4/5 组装 staging(背景图放卷根 .background.png)"
STAGE="$HOME/Library/Caches/ocg-dmg-new"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$DIST" "$STAGE/"
cp /tmp/dmg-background.png "$STAGE/.background.png"
ln -sf /Applications "$STAGE/Applications"
SetFile -a V "$STAGE/.background.png"

echo "==> 5/5 UDRW 可写镜像 → 挂载写入 DS_Store(现代格式)→ 转 UDZO"
TMPD="/tmp/ocg-build"
mkdir -p "$TMPD"
RW="$TMPD/OpenCode-Go-Quotas.rw.dmg"
VOL="OpenCode-Go-Quotas"
MOUNT="/Volumes/$VOL"
rm -f "$RW" "$OUT"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW" >/dev/null
hdiutil attach "$RW" -nobrowse -mountpoint "$MOUNT" -quiet
python3 "$ROOT/tools/make-dsstore.py" "$MOUNT" "$VOL"
SetFile -a V "$MOUNT/.DS_Store" "$MOUNT/.background.png"
sync
hdiutil detach "$MOUNT" -force -quiet

hdiutil convert "$RW" -format UDZO -o "$OUT"
echo "==> 完成: $OUT"
