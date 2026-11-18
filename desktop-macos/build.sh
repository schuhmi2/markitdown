#!/usr/bin/env bash
# Builds build/MarkItDown.app (universal: Apple silicon + Intel) and build/MarkItDown-macOS.zip.
# Needs only the Xcode Command Line Tools (xcode-select --install) and python3.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build
APP="$BUILD/MarkItDown.app"
MIN_MACOS=12.0

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
echo "==> Done: $APP and $BUILD/MarkItDown-macOS.zip"
