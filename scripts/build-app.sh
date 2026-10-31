#!/usr/bin/env bash
# Compila e monta dist/MacPet.app (assinatura ad-hoc).
#   VERSION=0.1.0 ARCHS="arm64 x86_64" ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-$(uname -m)}"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

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
