#!/usr/bin/env bash
# Builds build/MarkItDown.app (universal: Apple silicon + Intel), the drag-and-drop installer
# build/MarkItDown.dmg and build/MarkItDown-macOS.zip.
# Needs only the Xcode Command Line Tools (xcode-select --install) and python3.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP="$BUILD/MarkItDown.app"
MIN_MACOS=12.0
# Single source of truth for versions: browser-poc/index.html.
# The app version is the page's <span id="app-version">; the converter version is the
# MarkItDown release the page installs ("markitdown==0.1.9" -> 0.1.9).
APP_VERSION="$(sed -nE 's/.*<span id="app-version">([^<]+)<.*/\1/p' ../browser-poc/index.html)"
UPSTREAM_VERSION="$(sed -nE 's/.*"markitdown==([^"]+)".*/\1/p' ../browser-poc/index.html)"
if [ -z "$APP_VERSION" ] || [ -z "$UPSTREAM_VERSION" ]; then
  echo "Could not read the versions from browser-poc/index.html" >&2
  exit 1
fi

echo "==> Bundling Pyodide and wheels for offline use"
python3 tools/prepare_web.py --out "$BUILD/web" --cache "$BUILD/cache"

echo "==> Compiling"
rm -rf "$APP" "$BUILD/bin"
mkdir -p "$BUILD/bin" "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o "$BUILD/bin/MarkItDown-$arch"
done
lipo -create "$BUILD"/bin/MarkItDown-* -output "$APP/Contents/MacOS/MarkItDown"

echo "==> Assembling the app bundle"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
plutil -insert MarkItDownUpstreamVersion -string "$UPSTREAM_VERSION" "$APP/Contents/Info.plist"
cp -R "$BUILD/web" "$APP/Contents/Resources/web"
rm -rf "$BUILD/AppIcon.iconset"
swift tools/make_icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Self-test: converting sample files with the built app"
# Signed without the sandbox for this step only, so the app can read the repository's test files.
codesign --force --sign - --timestamp=none "$APP"
FIXTURES="$(cd ../packages/markitdown/tests/test_files && pwd)"
"$APP/Contents/MacOS/MarkItDown" --self-test \
  "$FIXTURES/test.docx" "$FIXTURES/test.pdf" "$FIXTURES/test.xlsx" "$FIXTURES/test.pptx" \
  "$FIXTURES/test_blog.html" > "$BUILD/self-test.md"
grep '^=== ' "$BUILD/self-test.md"

echo "==> Ad-hoc signing with the App Sandbox (no Apple Developer account needed)"
codesign --force --deep --sign - --entitlements MarkItDown.entitlements --timestamp=none "$APP"
codesign --verify --strict "$APP"

rm -f "$BUILD/MarkItDown-macOS.zip"
ditto -c -k --keepParent "$APP" "$BUILD/MarkItDown-macOS.zip"

echo "==> Building the drag-and-drop installer (MarkItDown.dmg)"
VENV="$BUILD/cache/dmgbuild-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    dmgbuild==1.6.5 ds-store==1.3.1 mac-alias==2.2.2
fi
swift tools/make_dmg_background.swift "$BUILD/dmg-background.tiff"
rm -f "$BUILD/MarkItDown.dmg"
"$VENV/bin/dmgbuild" -s tools/dmg_settings.py \
  -D app="$APP" -D background="$BUILD/dmg-background.tiff" \
  -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "MarkItDown" "$BUILD/MarkItDown.dmg"
hdiutil verify -quiet "$BUILD/MarkItDown.dmg"
echo "==> Done: $APP, $BUILD/MarkItDown.dmg and $BUILD/MarkItDown-macOS.zip"
