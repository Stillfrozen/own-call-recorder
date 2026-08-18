#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${OWN_RECORDER_APP_DIR:-/Applications/OwnRecorder.app}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICON_SRC="$PROJECT_ROOT/Resources/AppIcon.icns"
BIN_ARM="$PROJECT_ROOT/.build/arm64-apple-macosx/release/OwnRecorder"
BIN_X86="$PROJECT_ROOT/.build/x86_64-apple-macosx/release/OwnRecorder"

if [[ -x "$BIN_ARM" ]]; then
  BIN_SRC="$BIN_ARM"
elif [[ -x "$BIN_X86" ]]; then
  BIN_SRC="$BIN_X86"
else
  echo "OwnRecorder binary not found. Build first: swift build -c release" >&2
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Missing $ICON_SRC — generate with scripts/build-app-icon.sh" >&2
  exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_SRC" "$MACOS_DIR/OwnRecorder"
chmod +x "$MACOS_DIR/OwnRecorder"
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
printf '%s\n' "$PROJECT_ROOT/records" > "$RESOURCES_DIR/RecordsRoot.path"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OwnRecorder</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.workspace.own-call-recorder</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OwnRecorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.5</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>LSEnvironment</key>
    <dict>
        <key>OWN_RECORDER_RECORDS_DIR</key>
        <string>${PROJECT_ROOT}/records</string>
    </dict>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Запись микрофона вместе с системным звуком для конспекта встречи.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Захват системного звука встречи (без картинки экрана) для конспекта.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Запись системного звука вместе с микрофоном для конспекта встречи.</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
EOF

# Drop the old icon-less launcher if it is still around.
OLD_LAUNCHER="$HOME/Applications/OwnRecorder Launcher.app"
if [[ -d "$OLD_LAUNCHER" ]]; then
  rm -rf "$OLD_LAUNCHER"
fi

touch "$APP_DIR"
/usr/bin/touch "$APP_DIR/Contents/Info.plist"

# Linker-signed naked binary has Identifier=OwnRecorder and Info.plist=not bound,
# which makes UNUserNotificationCenter fail (UNError 1). Ad-hoc sign the .app.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Installed: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
