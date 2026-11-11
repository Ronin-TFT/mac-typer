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

rm -rf "$APP" "$DMG" "$STAGING" "$ROOT/build/AppIcon.iconset" "$ROOT/build/icon.png"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build"

GOCACHE="$GOCACHE" "$GO" build -o "$APP/Contents/Resources/mac-typer" "$ROOT"
GOCACHE="$GOCACHE" "$GO" run "$ROOT/app/make_icon.go"

clang "$ROOT/app/MacTyperGUI/main.m" \
  -o "$APP/Contents/MacOS/MacTyper" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework Carbon \
  -fobjc-arc

cp "$ROOT/app/MacTyperGUI/Info.plist" "$APP/Contents/Info.plist"

mkdir -p "$ROOT/build/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/icon.png" --out "$ROOT/build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ROOT/build/icon.png" --out "$ROOT/build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 签名：设置 SIGN_IDENTITY 时使用该证书（推荐自签名“代码签名”证书，见 README）。
# 不再使用仅检查 identifier 的签名要求，否则任何同 identifier 的临时签名程序
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

codesign --force --sign "$SIGN_IDENTITY" \
  --identifier local.ronin.mactyper.helper \
  "$APP/Contents/Resources/mac-typer"
codesign --force --sign "$SIGN_IDENTITY" \
  --identifier local.ronin.mactyper \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated >&2
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Mac Typer.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Mac Typer" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
