#!/bin/bash
# Builds the Release .app and copies it to apps/<timestamp>/JJType.app
# (app keeps its name; the timestamped FOLDER identifies the build)
set -euo pipefail
cd "$(dirname "$0")"

STAMP="$(date +%Y%m%d-%H%M)"
BUILD_DIR="./build"

# Deterministic derived data path (avoids DerivedData wildcard fragility).
# Universal binary for distribution: Intel + Apple Silicon. The ARCHS/ONLY_ACTIVE_ARCH
# overrides live ONLY here — pbxproj stays untouched so Xcode dev builds stay host-arch fast.
xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build -quiet

SRC="$BUILD_DIR/Build/Products/Release/jj-type.app"
if [ ! -d "$SRC" ]; then
  echo "Build succeeded but product not found: $SRC" >&2
  exit 1
fi

mkdir -p "apps/${STAMP}"
rm -rf "apps/${STAMP}/JJType.app"
cp -R "$SRC" "apps/${STAMP}/JJType.app"
echo "Built: apps/${STAMP}/JJType.app"
