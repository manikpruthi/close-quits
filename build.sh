#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CloseQuits"
BUNDLE_NAME="CloseQuits"
BUILD_DIR="${CLOSE_QUITS_BUILD_DIR:-$HOME/Library/Caches/CloseQuitsBuild}"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
MODE="${1:-debug}"

SDK="$(xcrun --show-sdk-path)"
MIN_MACOS="13.0"

if [ "$MODE" = "release" ] || [ "$MODE" = "--release" ]; then
    OPTIMIZATION=(-O -whole-module-optimization)
else
    OPTIMIZATION=(-Onone -g)
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINARIES=()
for ARCH in arm64 x86_64; do
    OUT="$BUILD_DIR/$APP_NAME-$ARCH"
    echo "Compiling ${#SOURCES[@]} Swift files for $ARCH-apple-macos$MIN_MACOS ($MODE)…"
    if swiftc -swift-version 6 -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" "${OPTIMIZATION[@]}" \
        "${SOURCES[@]}" -o "$OUT" -framework AppKit -framework ApplicationServices; then
        BINARIES+=("$OUT")
    else
        echo "warning: skipping $ARCH (toolchain cannot target it)" >&2
    fi
done

if [ "${#BINARIES[@]}" -eq 0 ]; then
    echo "error: no architectures built" >&2
    exit 1
fi

lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "${BINARIES[@]}"

find "$APP" -name '*.dSYM' -type d -prune -exec rm -rf {} + 2>/dev/null || true

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

touch "$BUILD_DIR/.metadata_never_index"
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"