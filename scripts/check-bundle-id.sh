#!/usr/bin/env bash
# Finds the bundle ID of a running or installed macOS application.
# Usage: ./scripts/check-bundle-id.sh "Kontur Talk"
#        ./scripts/check-bundle-id.sh Zoom
set -euo pipefail

APP_NAME="${1:-Kontur Talk}"

echo "=== Checking bundle ID for: $APP_NAME ==="

echo ""
echo "--- Method 1: osascript (installed app) ---"
osascript -e "id of app \"$APP_NAME\"" 2>/dev/null && true

echo ""
echo "--- Method 2: NSRunningApplication (must be running) ---"
/usr/bin/swift -e "
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: \"\")
let all = NSWorkspace.shared.runningApplications
for a in all where a.localizedName?.lowercased().contains(\"${APP_NAME,,}\") == true {
    print(\"Bundle ID:\", a.bundleIdentifier ?? \"(none)\",
          \"| PID:\", a.processIdentifier,
          \"| Name:\", a.localizedName ?? \"-\")
}
" 2>/dev/null || echo "(swift inline failed — app may not be running)"

echo ""
echo "--- Method 3: mdls (installed .app bundle) ---"
APP_PATH=$(mdfind "kMDItemCFBundleIdentifier == '*' && kMDItemDisplayName == '${APP_NAME}'" 2>/dev/null | head -1)
if [[ -n "$APP_PATH" ]]; then
    echo "Found: $APP_PATH"
    mdls -name kMDItemCFBundleIdentifier "$APP_PATH" 2>/dev/null
else
    echo "Not found via mdfind; try: mdls -name kMDItemCFBundleIdentifier /Applications/\"${APP_NAME}.app\""
fi

echo ""
echo "--- Method 4: /Applications directory scan ---"
find /Applications -maxdepth 2 -name "*.app" -iname "*$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')*" 2>/dev/null \
    | while read -r app; do
        bid=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "(none)")
        echo "  $app  →  $bid"
    done
