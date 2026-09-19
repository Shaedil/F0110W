#!/usr/bin/env bash
# Builds M0110HUD and assembles it into a signed .app bundle.
#
# CoreBluetooth needs a real bundle: the TCC permission prompt reads
# NSBluetoothAlwaysUsageDescription from Info.plist, and macOS remembers the
# grant by code signature. A bare executable gets denied instead of prompted.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="M0110HUD"
BUNDLE="build/${APP_NAME}.app"
# Every build also replaces the installed copy. The app that gets looked at is
# the one in /Applications, and a build that only wrote build/ left it behind,
# which read as "the change did not land" rather than "you are running an old
# binary".
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
# Any image resources the app ships alongside the icon.
for image in Resources/*.jpg; do
    [[ -e "$image" ]] || continue
    cp "$image" "${BUNDLE}/Contents/Resources/$(basename "$image")"
done

# Copied image resources carry Finder metadata, which codesign rejects with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$BUNDLE"

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough for a local build, but it must be stable or macOS will
# re-prompt for Bluetooth access on every rebuild.
codesign --force --sign - \
         --identifier com.shaedil.m0110hud \
         --timestamp=none \
         "$BUNDLE"

codesign --verify --verbose=1 "$BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> Installing ${INSTALLED}"
# Quit only a copy running out of the install path; the LaunchAgent runs the one
# in build/ and must not be taken down by an unrelated build.
if pgrep -f "^${INSTALLED}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    echo "    quitting the running copy"
    pkill -f "^${INSTALLED}/Contents/MacOS/${APP_NAME}" || true
fi
mkdir -p "$(dirname "$INSTALLED")"
rm -rf "$INSTALLED"
# ditto, not cp -R: it preserves the bundle's extended attributes, and a copy
# that loses them invalidates the signature macOS keyed the Bluetooth grant to.
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
