#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/Users/ipashintsev/work/cursor-projects/wallet-meeting-summary/meeting-bot/own-call-recorder"
APP_DIR="$HOME/Applications/OwnRecorder Launcher.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
EXEC_PATH="$MACOS_DIR/OwnRecorderLauncher"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OwnRecorderLauncher</string>
    <key>CFBundleIdentifier</key>
    <string>com.workspace.own-recorder.launcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OwnRecorder Launcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

cat > "$EXEC_PATH" <<EOF
#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$PROJECT_ROOT"
BIN_ARM="\$PROJECT_ROOT/.build/arm64-apple-macosx/release/OwnRecorder"
BIN_X86="\$PROJECT_ROOT/.build/x86_64-apple-macosx/release/OwnRecorder"

if pgrep -f '/OwnRecorder$' >/dev/null 2>&1; then
  exit 0
fi

if [[ -x "\$BIN_ARM" ]]; then
  nohup "\$BIN_ARM" >/tmp/own-recorder-launcher.log 2>&1 &
  exit 0
fi

if [[ -x "\$BIN_X86" ]]; then
  nohup "\$BIN_X86" >/tmp/own-recorder-launcher.log 2>&1 &
  exit 0
fi

osascript -e 'display dialog "OwnRecorder binary not found. Build first: swift build -c release" buttons {"OK"} default button "OK" with title "OwnRecorder Launcher"' >/dev/null 2>&1 || true
exit 1
EOF

chmod +x "$EXEC_PATH"
touch "$APP_DIR"

echo "Installed launcher: $APP_DIR"
