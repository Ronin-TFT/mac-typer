#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Mac Typer.app"
DMG="$ROOT/dist/MacTyper.dmg"
STAGING="$ROOT/build/dmg"
GOCACHE="${GOCACHE:-$ROOT/.cache/go-build}"
GO="${GO:-$(command -v go || true)}"
if [[ -z "$GO" && -x "$ROOT/.tools/go/bin/go" ]]; then
  GO="$ROOT/.tools/go/bin/go"
fi

if [[ -z "$GO" || ! -x "$GO" ]]; then
  echo "Go is required to build Mac Typer" >&2
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET=13.0
rm -rf "$APP" "$DMG" "$STAGING" "$ROOT/build/AppIcon.iconset" "$ROOT/build/icon.png" "$ROOT/build/lib"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/lib"

# 打字引擎：分别为 Apple Silicon 和 Intel 编译静态库，再合并为通用库。
for goarch clangarch in arm64 arm64 amd64 x86_64; do
  CGO_ENABLED=1 GOOS=darwin GOARCH=$goarch GOCACHE="$GOCACHE" \
    CC="clang -arch $clangarch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    "$GO" build -buildmode=c-archive -trimpath -o "$ROOT/build/lib/$goarch/libmactyper.a" "$ROOT"
done
lipo -create "$ROOT/build/lib/arm64/libmactyper.a" "$ROOT/build/lib/amd64/libmactyper.a" \
  -output "$ROOT/build/lib/libmactyper.a"
cp "$ROOT/build/lib/arm64/libmactyper.h" "$ROOT/build/lib/libmactyper.h"

clang -arch arm64 -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -fobjc-arc -O2 \
  -I "$ROOT/build/lib" -I "$ROOT" \
  "$ROOT"/app/MacTyperGUI/*.m "$ROOT/build/lib/libmactyper.a" \
  -o "$APP/Contents/MacOS/MacTyper" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework Carbon \
  -framework CoreFoundation \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo
lipo -info "$APP/Contents/MacOS/MacTyper"

cp "$ROOT/app/MacTyperGUI/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/typos/common.txt" "$APP/Contents/Resources/typos_common.txt"

GOCACHE="$GOCACHE" "$GO" run "$ROOT/app/make_icon.go"
mkdir -p "$ROOT/build/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/icon.png" --out "$ROOT/build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ROOT/build/icon.png" --out "$ROOT/build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 签名：设置 SIGN_IDENTITY 时使用该证书（推荐自签名“代码签名”证书，见 README）。
# 不使用仅检查 identifier 的签名要求，否则任何同 identifier 的临时签名程序
# 都能冒用 Mac Typer 的辅助功能权限。
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  if ! security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    echo "找不到签名证书：$SIGN_IDENTITY（用 security find-identity -p codesigning 查看）" >&2
    exit 1
  fi
else
  SIGN_IDENTITY="-"
  echo "警告：未设置 SIGN_IDENTITY，使用临时签名。每次更新后需要重新授予辅助功能权限。" >&2
fi

codesign --force --sign "$SIGN_IDENTITY" --identifier local.ronin.mactyper "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated >&2

mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Mac Typer.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Mac Typer" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
