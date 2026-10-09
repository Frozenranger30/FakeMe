#!/bin/bash
# Builds a universal (Apple Silicon + Intel) FakeMe.app and packages it as FakeMe.dmg.
# Usage: Scripts/package_dmg.sh [version]     e.g. Scripts/package_dmg.sh 1.0.0
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
VERSION="${1:-}"
OUT="${PROJECT_DIR}/FakeMe.dmg"
STAGE="$(mktemp -d)/dmg"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

cd "${PROJECT_DIR}"
echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -suppress-warnings
BIN="${PROJECT_DIR}/.build/out/Products/Release/FakeMe"
[ -f "$BIN" ] || BIN="${PROJECT_DIR}/.build/apple/Products/Release/FakeMe"
[ -f "$BIN" ] || { echo "Universal binary not found"; exit 1; }

echo "==> Assembling FakeMe.app"
APP="${STAGE}/FakeMe.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/FakeMe"
cp Sources/FakeMeApp/Info.plist "${APP}/Contents/Info.plist"
cp Sources/FakeMeApp/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf "APPL????" > "${APP}/Contents/PkgInfo"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
fi

# Ad-hoc signature (no paid Apple Developer account needed)
codesign --sign - --force --deep "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "${STAGE}/Programme"

echo "==> Creating DMG"
hdiutil detach /Volumes/FakeMe -force >/dev/null 2>&1 || true
hdiutil create -volname "FakeMe" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
