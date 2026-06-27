#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/TypelessMLX/Resources/silero-vad/Silero-VAD-v5-MLX"
BASE_URL="${HF_ENDPOINT:-https://huggingface.co}"

mkdir -p "$OUT_DIR"

download_model_file() {
    local file="$1"
    local dest="$2"
    local url="$BASE_URL/aufklarer/Silero-VAD-v5-MLX/resolve/main/$file"
    echo "Downloading Silero VAD $file..."
    curl -L --fail --retry 3 --retry-delay 1 -o "$dest" "$url"
    test -s "$dest"
}

download_model_file "config.json" "$OUT_DIR/config.json"
download_model_file "model.safetensors" "$OUT_DIR/model.safetensors"

wc -c \
    "$OUT_DIR/config.json" \
    "$OUT_DIR/model.safetensors"
