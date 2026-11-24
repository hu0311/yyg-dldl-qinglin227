#!/bin/bash
# 在 macOS 上直接生成未签名 IPA（不依赖 Xcode 工程、不依赖 XcodeGen）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="斗罗大陆H5青春麒麟服"
OUT="$ROOT/out"
STAGE="$OUT/stage"
APP="$STAGE/Payload/App.app"

rm -rf "$OUT"
mkdir -p "$APP"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iOS SDK: $SDK"

echo "==> 编译 arm64 可执行文件"
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios14.0 \
  -O -whole-module-optimization \
  App/main.swift App/AppDelegate.swift App/WebViewController.swift \
  -framework UIKit -framework WebKit -framework Foundation \
  -o "$APP/App"

echo "==> 拷贝资源"
cp App/Info.plist "$APP/Info.plist"
for f in App/Assets/*.png; do
  cp "$f" "$APP/$(basename "$f")"
done
if [ -f App/Assets/icon-1024.png ]; then
  cp App/Assets/icon-1024.png "$APP/AppIcon1024.png"
fi

echo "==> 校验 Info.plist"
plutil -lint "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP/Info.plist"

echo "==> ad-hoc 签名（企业签名时会整体覆盖重签）"
codesign --force --sign - --timestamp=none "$APP" || true
codesign --verify --verbose=2 "$APP" || true

echo "==> 打包 ipa"
cd "$STAGE"
zip -qry "$OUT/${APP_NAME}-unsigned.ipa" Payload

echo "==> 产物"
ls -lh "$OUT"/*.ipa
/usr/bin/unzip -l "$OUT/${APP_NAME}-unsigned.ipa" | head -30
