#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$NATIVE_DIR/../.." && pwd)"
OUTPUT="${PIPETTER_BUILD_OUTPUT:-$PROJECT_DIR/Mac/9210 Pro Control.app}"
BUILD_ARCH="${PIPETTER_BUILD_ARCH:-arm64}"
case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported Mac architecture: $BUILD_ARCH (use arm64 or x86_64)" >&2; exit 2 ;;
esac
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources" "$PROJECT_DIR/tools-downloads/swift-cache"
swiftc -swift-version 5 -O -target "$BUILD_ARCH-apple-macosx14.0" -module-cache-path "$PROJECT_DIR/tools-downloads/swift-cache" \
  "$NATIVE_DIR"/Sources/*.swift -o "$OUTPUT/Contents/MacOS/9210ProControl"
cp -R "$NATIVE_DIR/Resources/." "$OUTPUT/Contents/Resources/"
cat > "$OUTPUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.lab.pipetter9210.maccontrol</string>
<key>CFBundleName</key><string>9210 Pro Control</string>
<key>CFBundleDisplayName</key><string>9210 Pro Control</string>
<key>CFBundleExecutable</key><string>9210ProControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>37</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>连接您的 9210 Pro 移液工作站，读取设备状态并执行您启动的移液方案。</string>
</dict></plist>
PLIST
codesign --force --sign - "$OUTPUT"
echo "Built: $OUTPUT"
