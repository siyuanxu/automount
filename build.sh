#!/bin/bash
# 构建并签名 AutoMount.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AutoMount"
BUNDLE_ID="io.github.siyuanxu.automount"
BUILD_DIR="$DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
SIGN_ID="${SIGN_ID:-}"

if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
fi

ARCH="$(uname -m)"
echo "==> 清理 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 编译 Swift 源码（${ARCH}）"
swiftc -O -swift-version 5 \
    -target "${ARCH}-apple-macosx13.0" \
    "$DIR/Sources/"*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

if [ "$SIGN_ID" = "-" ]; then
    echo "==> 使用 ad-hoc 签名（适合发布构建）"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
elif [ -n "$SIGN_ID" ]; then
    echo "==> 使用开发证书签名：$SIGN_ID"
    codesign --force --timestamp=none --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
    echo "==> 未找到开发证书，使用 ad-hoc 签名"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "==> 构建完成：$APP"
