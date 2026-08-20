#!/usr/bin/env bash
# Packs dist/Koda Player.app into a DMG that can be handed to someone else.
# Run ./build-app.sh first; pass a version to name the file (default 1.0).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Koda Player"
VERSION="${1:-1.0}"
APP_DIR="dist/${APP_NAME}.app"
DMG="dist/KodaPlayer-${VERSION}.dmg"

if [ ! -d "${APP_DIR}" ]; then
  echo "error: ${APP_DIR} not found. Build it first with ./build-app.sh" >&2
  exit 1
fi

ARCH="$(lipo -archs "${APP_DIR}/Contents/MacOS/${APP_NAME}" | tr ' ' '/')"
echo "==> Staging ${APP_NAME} (${ARCH})"
STAGE="$(mktemp -d)/${APP_NAME}"
mkdir -p "${STAGE}"
cp -R "${APP_DIR}" "${STAGE}/"
# The usual drag-to-install target.
ln -s /Applications "${STAGE}/Applications"

# The app is ad-hoc signed unless it was built with a Developer ID, so the first launch
# needs the right-click dance. Saying so in the disk image saves everyone a support round.
if ! codesign -dv "${APP_DIR}" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]"; then
  cat > "${STAGE}/Read me first.txt" <<'NOTE'
Koda Player is not signed with an Apple Developer ID, so macOS will refuse
to open it on the first try.

To install:

  1. Drag Koda Player onto the Applications folder.
  2. Open Applications, right-click Koda Player, and choose Open.
  3. Click Open in the dialog that appears. macOS remembers the choice.

If macOS still refuses, clear the download flag in Terminal:

  xattr -dr com.apple.quarantine "/Applications/Koda Player.app"

The same flag is why a video downloaded from the web can be refused when you
double-click it. Opening it with File > Open, or dragging it onto the window,
sidesteps that.
NOTE
fi

echo "==> Building ${DMG}"
rm -f "${DMG}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${DMG}" >/dev/null

SIZE="$(du -h "${DMG}" | cut -f1)"
echo
echo "Built ${DMG} (${SIZE}, ${ARCH}, macOS $(plutil -extract LSMinimumSystemVersion raw "${APP_DIR}/Contents/Info.plist")+)"
