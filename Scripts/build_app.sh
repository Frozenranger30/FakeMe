#!/bin/bash
# Builds FakeMe binary and assembles a proper .app bundle.
# Output: $PROJECT_DIR/FakeMe.app
set -euo pipefail

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
BUILD_DIR="${PROJECT_DIR}/.build/release"
APP_DIR="${PROJECT_DIR}/FakeMe.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "Building FakeMe (release)..."
cd "${PROJECT_DIR}"
swift build -c release -Xswiftc -suppress-warnings

BINARY="${BUILD_DIR}/FakeMe"
if [ ! -f "${BINARY}" ]; then
    echo "Error: binary not found at ${BINARY}"
    exit 1
fi

echo "Assembling FakeMe.app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy binary (use install to handle permission restrictions)
/usr/bin/install -m 755 "${BINARY}" "${MACOS_DIR}/FakeMe"

# Copy Info.plist
/usr/bin/install -m 644 "${PROJECT_DIR}/Sources/FakeMeApp/Info.plist" "${CONTENTS}/Info.plist"

# PkgInfo marker
printf "APPL????" > "${CONTENTS}/PkgInfo"

# Ad-hoc code signature (required for camera/accessibility permissions)
codesign --force --sign - --entitlements "${PROJECT_DIR}/Scripts/FakeMe.entitlements" "${APP_DIR}" 2>/dev/null || \
codesign --force --sign - "${APP_DIR}"

echo "Done: ${APP_DIR}"
