#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/TypelessMLX/Resources/whisper-tokenizers/models/openai"
BASE_URL="${HF_ENDPOINT:-https://huggingface.co}"

mkdir -p "$OUT_DIR/whisper-small" "$OUT_DIR/whisper-large-v3"

download_tokenizer_file() {
    local repo="$1"
    local file="$2"
    local dest="$3"
    local url="$BASE_URL/openai/$repo/resolve/main/$file"
    echo "Downloading $repo $file..."
    curl -L --fail --retry 3 --retry-delay 1 -o "$dest" "$url"
    test -s "$dest"
}

download_tokenizer_file "whisper-small" "tokenizer.json" "$OUT_DIR/whisper-small/tokenizer.json"
download_tokenizer_file "whisper-small" "tokenizer_config.json" "$OUT_DIR/whisper-small/tokenizer_config.json"
download_tokenizer_file "whisper-large-v3" "tokenizer.json" "$OUT_DIR/whisper-large-v3/tokenizer.json"
download_tokenizer_file "whisper-large-v3" "tokenizer_config.json" "$OUT_DIR/whisper-large-v3/tokenizer_config.json"

wc -c \
    "$OUT_DIR/whisper-small/tokenizer.json" \
    "$OUT_DIR/whisper-small/tokenizer_config.json" \
    "$OUT_DIR/whisper-large-v3/tokenizer.json" \
    "$OUT_DIR/whisper-large-v3/tokenizer_config.json"
