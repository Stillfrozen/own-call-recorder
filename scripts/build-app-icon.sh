#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
SQUARE="$RES/AppIcon-1024-square.png"
MASTER="$RES/AppIcon-1024.png"
ICONSET="$RES/AppIcon.iconset"

if [[ -f "$SQUARE" ]]; then
  python3 "$ROOT/scripts/apply-squircle-mask.py" "$SQUARE" "$MASTER"
elif [[ ! -f "$MASTER" ]]; then
  echo "Missing $MASTER (or $SQUARE)" >&2
  exit 1
fi

# Keep alpha. `sips` often flattens transparent padding to black.
python3 - <<PY
from pathlib import Path
from PIL import Image

master = Path("$MASTER")
iconset = Path("$ICONSET")
iconset.mkdir(parents=True, exist_ok=True)
src = Image.open(master).convert("RGBA")
sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
for name, px in sizes.items():
    src.resize((px, px), Image.Resampling.LANCZOS).save(iconset / name, "PNG")
PY

iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
echo "Wrote $RES/AppIcon.icns"
