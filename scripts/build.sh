#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust-core"
SWIFT_DIR="$ROOT_DIR/macos-app"
APP_VERSION="${AGY_HIGHER_VERSION:-0.2.0}"
BUILD_NUMBER="${AGY_HIGHER_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
APP_DIR="${AGY_HIGHER_APP_DIR:-$ROOT_DIR/build/AgyHigher.app}"
BUILD_CONFIG="${AGY_HIGHER_BUILD_CONFIG:-release}"

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -n "${AGY_HIGHER_SDK_PATH:-}" ] && [ -d "${AGY_HIGHER_SDK_PATH}" ]; then
    SDK_PATH="${AGY_HIGHER_SDK_PATH}"
elif [ "$DEV_DIR" = "/Library/Developer/CommandLineTools" ]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
    CLT_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins"
    FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [ ! -f "${CLT_PLUGINS}/libSwiftUIMacros.dylib" ] && \
       grep -q "SwiftUIMacros" "${SDK_PATH}/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/"*.swiftinterface 2>/dev/null && \
       [ -d "$FALLBACK_SDK" ]; then
        echo "==> Note: CLT SDK $(basename "$SDK_PATH") requires SwiftUIMacros; using $(basename "$FALLBACK_SDK")"
        SDK_PATH="$FALLBACK_SDK"
    fi
else
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

if [ ! -d "$SDK_PATH" ]; then
    echo "ERROR: Valid macOS SDK not found: $SDK_PATH" >&2
    exit 1
fi

echo "==> [1/4] Building Rust core static library (release)..."
(cd "$RUST_DIR" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release)

SWIFT_OPT_ARGS=()
if [ "$BUILD_CONFIG" = "release" ] && [ "${AGY_HIGHER_WMO:-0}" != "1" ]; then
    # Multi-core incremental -O avoids slow single-threaded WMO stalls on small edits
    SWIFT_OPT_ARGS=(-Xswiftc -no-whole-module-optimization -Xswiftc -incremental)
fi

echo "==> [2/4] Building SwiftUI macOS application (${BUILD_CONFIG})..."
(cd "$SWIFT_DIR" && swift build --sdk "$SDK_PATH" -c "$BUILD_CONFIG" "${SWIFT_OPT_ARGS[@]}")

BIN_PATH="$(cd "$SWIFT_DIR" && swift build --sdk "$SDK_PATH" -c "$BUILD_CONFIG" --show-bin-path)/AgyHigher"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH="$SWIFT_DIR/.build/${BUILD_CONFIG}/AgyHigher"
fi

echo "==> [3/4] Packaging standalone macOS .app bundle at $APP_DIR (v${APP_VERSION})..."
# Update Contents/ in-place so top-level .app inode is preserved (prevents duplicate Dock tiles)
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
rm -rf "$APP_DIR/Contents/MacOS/AgyHigher" "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/AgyHigher"
chmod +x "$APP_DIR/Contents/MacOS/AgyHigher"
strip -x "$APP_DIR/Contents/MacOS/AgyHigher" 2>/dev/null || true

ICON_SRC="$ROOT_DIR/assets/AppIcon.icns"
if [ ! -f "$ICON_SRC" ]; then
    echo "ERROR: Missing required AppIcon.icns at $ICON_SRC" >&2
    exit 1
fi
cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Bundle standalone STE-STC l10n dictionaries, dist overlay & patch/build tools inside .app
if [ -d "$ROOT_DIR/l10n" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/l10n"
    cp -R "$ROOT_DIR/l10n/dist" "$APP_DIR/Contents/Resources/l10n/"
    cp -R "$ROOT_DIR/l10n/src" "$APP_DIR/Contents/Resources/l10n/"
    cp -R "$ROOT_DIR/l10n/tools" "$APP_DIR/Contents/Resources/l10n/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>AgyHigher</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.don.agy-higher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgyHigher</string>
  <key>CFBundleDisplayName</key>
  <string>AgyHigher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> [4/4] Ad-hoc signing & verifying bundle..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
touch "$APP_DIR"

ABS_APP_DIR="$(cd "$(dirname "$APP_DIR")" && pwd)/$(basename "$APP_DIR")"
if [ -z "${CI:-}" ] && [ "$ABS_APP_DIR" != "/Applications/AgyHigher.app" ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$ABS_APP_DIR" >/dev/null 2>&1 || true
    fi
fi

echo "[Done] Packaged and signed: $ABS_APP_DIR (v${APP_VERSION})"
