#!/usr/bin/env bash
# Builds Koda Player.app, a self-contained bundle with libmpv and its codecs inside,
# so it runs on Macs that have never seen Homebrew.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Koda Player"
BUNDLE_ID="com.koda.player"
VERSION="1.0"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

BREW_PREFIX="$(brew --prefix)"
if [ ! -f "${BREW_PREFIX}/lib/libmpv.dylib" ]; then
  echo "error: libmpv not found. Run: brew install mpv" >&2
  exit 1
fi

echo "==> Pointing the build at ${BREW_PREFIX}"
cat > Sources/CMPV/module.modulemap <<EOF
module CMPV [system] {
    header "${BREW_PREFIX}/include/mpv/client.h"
    header "${BREW_PREFIX}/include/mpv/render.h"
    header "${BREW_PREFIX}/include/mpv/render_gl.h"
    link "mpv"
    export *
}
EOF
sed -i '' "s|^let brewPrefix = .*|let brewPrefix = \"${BREW_PREFIX}\"|" Package.swift

echo "==> Compiling (release)"
swift build -c release 2>&1 | grep -vE "DeprecatedDeclaration|warning:|^ *[0-9]+ \||^ *\||^ *\`-|^$" || true
test -x "${BUILD_DIR}/KodaPlayer"

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources" "${CONTENTS}/Frameworks"
cp "${BUILD_DIR}/KodaPlayer" "${CONTENTS}/MacOS/${APP_NAME}"

# Document types: every container we advertise, so Finder's "Open With" lists the player.
VIDEO_EXTENSIONS='mp4 m4v mov mkv webm avi wmv flv f4v mpg mpeg m2v mts m2ts ts vob ogv ogm rm rmvb asf divx 3gp 3g2 mxf y4m nut amv dav swf hevc h264 av1 ivf mp3 flac wav m4a aac ogg opus wma aiff ape dsf mka tta wv'
EXTENSION_XML=""
for ext in ${VIDEO_EXTENSIONS}; do
  EXTENSION_XML="${EXTENSION_XML}				<string>${ext}</string>
"
done

cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Playback engine: mpv / FFmpeg (LGPL)</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Media File</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>CFBundleTypeExtensions</key>
			<array>
${EXTENSION_XML}			</array>
		</dict>
	</array>
</dict>
</plist>
EOF

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Tools/make-icon.swift "${ICONSET}"
iconutil -c icns "${ICONSET}" -o "${CONTENTS}/Resources/AppIcon.icns"

echo "==> Bundling libmpv and its codec libraries"
if command -v dylibbundler >/dev/null 2>&1; then
  dylibbundler \
    -od -b -cd \
    -x "${CONTENTS}/MacOS/${APP_NAME}" \
    -d "${CONTENTS}/Frameworks" \
    -p "@executable_path/../Frameworks" \
    >/dev/null 2>&1

  # dylibbundler adds its rpath once per bundled library, and dyld refuses to load anything
  # carrying the same LC_RPATH twice. Collapse them back down to one everywhere.
  dedupe_rpath() {
    local binary="$1"
    while install_name_tool -delete_rpath "@executable_path/../Frameworks/" "${binary}" 2>/dev/null; do :; done
    while install_name_tool -delete_rpath "@executable_path/../Frameworks" "${binary}" 2>/dev/null; do :; done
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${binary}" 2>/dev/null || true
  }

  dedupe_rpath "${CONTENTS}/MacOS/${APP_NAME}"
  for dylib in "${CONTENTS}/Frameworks"/*.dylib; do
    [ -f "${dylib}" ] && dedupe_rpath "${dylib}"
  done
else
  echo "    dylibbundler missing: the app will need Homebrew's mpv installed to run."
  echo "    Install it with: brew install dylibbundler"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
  echo "    ad-hoc signing failed; the app still runs locally."

SIZE="$(du -sh "${APP_DIR}" | cut -f1)"
echo
echo "Built ${APP_DIR} (${SIZE})"
echo "Run it:      open '${APP_DIR}'"
echo "Install it:  cp -R '${APP_DIR}' /Applications/"
