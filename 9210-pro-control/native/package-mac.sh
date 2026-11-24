#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$NATIVE_DIR/../.." && pwd)"
PACKAGE_MODE="${1:-split}"
if [[ $# -gt 1 ]]; then echo "usage: $0 [split|universal|all]" >&2; exit 2; fi
case "$PACKAGE_MODE" in
  split|universal|all) ;;
  *) echo "usage: $0 [split|universal|all]" >&2; exit 2 ;;
esac
RELEASE_ROOT="$PROJECT_DIR/Mac/releases"
mkdir -p "$RELEASE_ROOT" "$PROJECT_DIR/tools-downloads"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/tools-downloads/mac-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Build clean bundles from the same sources/version. Never copy a potentially
# stale daily app, or touch its process, user workspace or Bluetooth preferences.
for BUILD_ARCH in arm64 x86_64; do
  PIPETTER_BUILD_ARCH="$BUILD_ARCH" \
    PIPETTER_BUILD_OUTPUT="$STAGING_DIR/build/$BUILD_ARCH/9210 Pro Control.app" \
    bash "$NATIVE_DIR/build.sh"
done
ARM_APP="$STAGING_DIR/build/arm64/9210 Pro Control.app"
INTEL_APP="$STAGING_DIR/build/x86_64/9210 Pro Control.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ARM_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARM_APP/Contents/Info.plist")"
[[ "$VERSION" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INTEL_APP/Contents/Info.plist")" ]]
[[ "$BUILD" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INTEL_APP/Contents/Info.plist")" ]]

package_architecture() {
  local PACKAGE_ARCH="$1" PACKAGE_SUFFIX="$2" PACKAGE_LABEL="$3"
  local RELEASE_NAME="9210-Pro-Control-$VERSION-Mac-$PACKAGE_SUFFIX"
  local RELEASE_DIR="$STAGING_DIR/$RELEASE_NAME"
  local APP="$RELEASE_DIR/9210 Pro Control.app"
  mkdir -p "$RELEASE_DIR"
  if [[ "$PACKAGE_ARCH" == x86_64 ]]; then ditto "$INTEL_APP" "$APP"
  else ditto "$ARM_APP" "$APP"; fi
  if [[ "$PACKAGE_ARCH" == universal ]]; then
    lipo -create "$ARM_APP/Contents/MacOS/9210ProControl" "$INTEL_APP/Contents/MacOS/9210ProControl" -output "$APP/Contents/MacOS/9210ProControl"
    codesign --force --sign - "$APP"
  fi
  codesign --verify --deep --strict "$APP"
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" -e "s/@PLATFORM@/$PACKAGE_LABEL/g" \
    "$NATIVE_DIR/DISTRIBUTION_README.txt" > "$RELEASE_DIR/README.txt"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "$RELEASE_DIR" "$RELEASE_ROOT/$RELEASE_NAME.zip"
  (cd "$RELEASE_ROOT" && shasum -a 256 "$RELEASE_NAME.zip" > "$RELEASE_NAME.sha256")
  python3 "$NATIVE_DIR/verify-mac-package.py" "$RELEASE_ROOT/$RELEASE_NAME.zip" \
    --arch "$PACKAGE_ARCH" --output "$RELEASE_ROOT/verification-$VERSION-Mac-$PACKAGE_SUFFIX.json"
  echo "Packaged: $RELEASE_ROOT/$RELEASE_NAME.zip"
}

if [[ "$PACKAGE_MODE" != universal ]]; then
  package_architecture arm64 AppleSilicon 'M 芯片版（Apple Silicon，arm64）'
  package_architecture x86_64 Intel 'Intel 版（x86_64）'
fi
if [[ "$PACKAGE_MODE" != split ]]; then
  package_architecture universal Universal '通用版（Apple Silicon 与 Intel）'
fi
