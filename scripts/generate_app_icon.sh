#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon-source.png"
OUTPUT_ICON="$ROOT_DIR/Resources/CloseTargetApp.icns"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "Missing source icon: $SOURCE_ICON" >&2
    exit 1
fi

if ! "$PYTHON_BIN" -c "from PIL import Image" >/dev/null 2>&1; then
    RUNTIME_PYTHON="/Users/bytedance/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
    if [[ -x "$RUNTIME_PYTHON" ]]; then
        PYTHON_BIN="$RUNTIME_PYTHON"
    fi
fi

"$PYTHON_BIN" "$ROOT_DIR/scripts/generate_app_icon.py" "$SOURCE_ICON" "$OUTPUT_ICON"

echo "Generated: $OUTPUT_ICON"
