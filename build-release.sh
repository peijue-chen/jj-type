#!/bin/bash
# Builds the Release .app and copies it to apps/<timestamp>/JJType.app
# (app keeps its name; the timestamped FOLDER identifies the build)
#
# Output: progress + warnings/errors by default; `VERBOSE=1 ./build-release.sh`
# streams the raw xcodebuild log (every CompileSwift / CodeSign line).
set -euo pipefail
cd "$(dirname "$0")"

STAMP="$(date +%Y%m%d-%H%M)"
BUILD_DIR="./build"
START=$SECONDS

VERSION="$(grep -m1 'MARKETING_VERSION' jj-type.xcodeproj/project.pbxproj \
  | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d '\r')"
[ -n "$VERSION" ] || VERSION="?"
echo "==> JJType ${VERSION} · Release · universal (x86_64 + arm64)"
echo "==> 编译中…（完整日志：VERBOSE=1 ./build-release.sh）"

# Deterministic derived data path (avoids DerivedData wildcard fragility).
# Universal binary for distribution: Intel + Apple Silicon. The ARCHS/ONLY_ACTIVE_ARCH
# overrides live ONLY here — pbxproj stays untouched so Xcode dev builds stay host-arch fast.
set +e
if [ "${VERBOSE:-0}" = "1" ]; then
  xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build 2>&1
  STATUS=$?
else
  # Progress + diagnostics only. `-quiet` prints nothing at all on success, but
  # the raw log is thousands of lines (SwiftCompile lists every file AND its
  # absolute path), so it is filtered: one short line per compile pass, plus
  # link / sign / plist → truncated, and every warning / error verbatim.
  # `VERBOSE=1` for the untouched stream.
  xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build 2>&1 \
    | awk '
        /^(CompileSwift|SwiftCompile|SwiftDriver) / {
          work++
          if ($1 == "SwiftCompile") print "   · 编译 " $3
          next
        }
        /^Ld / { print "   · 链接 " $4; next }
        /^CodeSign / {
          n = split($2, p, "/"); print "   · 签名 " p[n]; next
        }
        /^(ProcessInfoPlistFile|CpResource|CompileAssetCatalog|Touch) / { next }
        /^\*\* BUILD/ { result = $0; next }
        /error:|warning:|^=== / { print }
        END {
          if (work == 0) print "   （增量构建：没有需要重新编译的文件）"
          if (result != "") print result
        }'
  STATUS=${PIPESTATUS[0]}
fi
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "" >&2
  echo "!! 编译失败（exit ${STATUS}）— 用 VERBOSE=1 ./build-release.sh 看完整日志" >&2
  exit "$STATUS"
fi
echo "==> 编译完成（$((SECONDS - START))s · $(ls jj-type/*.swift | wc -l | tr -d ' ') 个 Swift 文件 × 2 架构）"

SRC="$BUILD_DIR/Build/Products/Release/jj-type.app"
if [ ! -d "$SRC" ]; then
  echo "Build succeeded but product not found: $SRC" >&2
  exit 1
fi

echo "==> 复制产物…"
mkdir -p "apps/${STAMP}"
rm -rf "apps/${STAMP}/JJType.app"
cp -R "$SRC" "apps/${STAMP}/JJType.app"
echo "Built: apps/${STAMP}/JJType.app ($((SECONDS - START))s)"

# open
open "./apps/${STAMP}/"
