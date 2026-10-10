#!/usr/bin/env bash
# Builds M0110HUD into a signed .app bundle. CoreBluetooth needs a real bundle,
# because the permission prompt reads Info.plist and macOS ties the grant to the signature.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="M0110HUD"
BUNDLE="build/${APP_NAME}.app"
# Every build also replaces the installed copy, since that is the one that runs.
INSTALLED="/Applications/${APP_NAME}.app"

echo "==> Compiling (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
    echo "error: expected binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp "$BIN" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"

mkdir -p "${BUNDLE}/Contents/Resources"
cp Resources/M0110.icns "${BUNDLE}/Contents/Resources/M0110.icns"
for image in Resources/*.jpg Resources/*.usdz; do
    [[ -e "$image" ]] || continue
    cp "$image" "${BUNDLE}/Contents/Resources/$(basename "$image")"
done

# Copied images carry Finder metadata, which codesign rejects.
xattr -cr "$BUNDLE"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing is fine locally, but the identifier must stay the same or macOS
# asks for Bluetooth access again after every rebuild.
codesign --force --sign - \
         --identifier com.shaedil.m0110hud \
         --timestamp=none \
         "$BUNDLE"

codesign --verify --verbose=1 "$BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> Installing ${INSTALLED}"
# Only quit the copy running from the install path.
if pgrep -f "^${INSTALLED}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    echo "    quitting the running copy"
    pkill -f "^${INSTALLED}/Contents/MacOS/${APP_NAME}" || true
fi
mkdir -p "$(dirname "$INSTALLED")"
rm -rf "$INSTALLED"
# Use ditto instead of cp -R to keep extended attributes. Losing them breaks the
# signature that the Bluetooth grant is tied to.
ditto "$BUNDLE" "$INSTALLED"

echo
echo "Built:     $(pwd)/${BUNDLE}"
echo "Installed: ${INSTALLED}"
echo
echo "Try the look without any hardware:"
echo "  \"${BUNDLE}/Contents/MacOS/${APP_NAME}\" --preview"
echo
echo "Run it for real (first launch prompts for Bluetooth access):"
echo "  open \"${BUNDLE}\""
echo
echo "Watch what it's doing:"
echo "  \"${BUNDLE}/Contents/MacOS/${APP_NAME}\" --verbose"
