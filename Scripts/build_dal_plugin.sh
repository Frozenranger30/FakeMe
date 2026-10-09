#!/bin/bash
# Compiles FakeMeDAL.plugin — the CoreMediaIO DAL virtual camera plugin.
# No Developer Account or code signing required.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${SCRIPT_DIR}/.."
DAL_SRC="${PROJECT_DIR}/DALPlugin"
OUT_DIR="${PROJECT_DIR}/FakeMeDAL.plugin/Contents/MacOS"
BUNDLE_DIR="${PROJECT_DIR}/FakeMeDAL.plugin"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"

echo "Building FakeMeDAL.plugin..."

rm -rf "${BUNDLE_DIR}"
mkdir -p "${OUT_DIR}"

# Compile the Objective-C plugin as a bundle (not dylib)
clang \
  -bundle \
  -arch arm64 \
  -mmacosx-version-min=14.0 \
  -fobjc-arc \
  -I "${DAL_SRC}" \
  -framework CoreFoundation \
  -framework CoreMedia \
  -framework CoreMediaIO \
  -framework CoreVideo \
  -framework AudioToolbox \
  -o "${OUT_DIR}/FakeMeDAL" \
  "${DAL_SRC}/FakeMeDAL.m"

# Copy Info.plist
cp "${DAL_SRC}/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Ad-hoc sign (DAL plugins don't need a real certificate)
codesign --force --sign - "${BUNDLE_DIR}"

echo "Built: ${BUNDLE_DIR}"
echo "Binary: $(ls -lh "${OUT_DIR}/FakeMeDAL" | awk '{print $5}')"
