#!/usr/bin/env bash
# Compila e monta dist/MacPet.app (assinatura ad-hoc).
#   VERSION=0.1.0 ARCHS="arm64 x86_64" ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-$(uname -m)}"

# Uma arquitetura por vez: com várias --arch o SwiftPM usa o build do Xcode, que não resolve o plugin do
# SwiftTerm. Os binários de cada uma são juntados com lipo.
BIN_DIR=".build/universal"
rm -rf "$BIN_DIR" && mkdir -p "$BIN_DIR"
PARTS_MacPet=(); PARTS_hook=()
for arch in $ARCHS; do
    swift build -c release --arch "$arch"
    ARCH_BIN="$(swift build -c release --arch "$arch" --show-bin-path)"
    PARTS_MacPet+=("$ARCH_BIN/MacPet"); PARTS_hook+=("$ARCH_BIN/macpet-hook")
done
lipo -create "${PARTS_MacPet[@]}" -output "$BIN_DIR/MacPet"
lipo -create "${PARTS_hook[@]}" -output "$BIN_DIR/macpet-hook"

APP="dist/MacPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacPet" "$BIN_DIR/macpet-hook" "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

mkdir -p .build
swiftc -O -o .build/make-icon scripts/icon/main.swift Sources/MacPet/Pet/PetArt.swift
.build/make-icon "$APP/Contents/Resources/AppIcon.icns" >/dev/null

# Usa a identidade local fixa se existir (ver scripts/setup-signing.sh); senão, ad-hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "MacPet Local Signing"; then
    IDENTITY="MacPet Local Signing"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier app.macpet-hook "$APP/Contents/MacOS/macpet-hook"
codesign --force --sign "$IDENTITY" --identifier app.macpet "$APP"

echo "OK: $APP ($VERSION, $ARCHS, assinatura: $IDENTITY)"
