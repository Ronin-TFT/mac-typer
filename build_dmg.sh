#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
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

codesign --force --deep --sign - \
  --identifier local.ronin.mactyper \
  --requirements '=designated => identifier "local.ronin.mactyper"' \
  "$APP"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Mac Typer.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Mac Typer" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
