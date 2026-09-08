#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CloseTargetApp"
BUNDLE_IDENTIFIER="com.local.CloseTargetApp"
# 固定使用本机已有的长期代码签名证书指纹，使不同构建版本拥有相同的 Designated Requirement。
# 如需在另一台机器构建，可以显式设置 CLOSE_TARGET_APP_SIGNING_IDENTITY 覆盖该身份。
DEFAULT_SIGNING_IDENTITY="659A2CD838DF7ADCB88F313BDE6572A223C4923C"
SIGNING_IDENTITY="${CLOSE_TARGET_APP_SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="CloseTargetApp.icns"

cd "$ROOT_DIR"

if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Missing code signing identity: $SIGNING_IDENTITY" >&2
    echo "Set CLOSE_TARGET_APP_SIGNING_IDENTITY to a stable local code signing identity." >&2
    exit 1
fi

swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

if [[ -e "$APP_DIR" ]]; then
    /usr/bin/trash "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ ! -f "$ROOT_DIR/Resources/$ICON_FILE" ]]; then
    "$ROOT_DIR/scripts/generate_app_icon.sh"
fi
cp "$ROOT_DIR/Resources/$ICON_FILE" "$RESOURCES_DIR/$ICON_FILE"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_FILE</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "Built and signed with identity $SIGNING_IDENTITY: $APP_DIR"
