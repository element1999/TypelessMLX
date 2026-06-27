#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/.build/mlx-metallib"
OUT_FILE="$OUT_DIR/mlx.metallib"
CACHE_DIR="$PROJECT_DIR/.build/metal-module-cache"
KERNEL_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels"
ROOT_DIR="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
FORCE=0

if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

if [ "$FORCE" != "1" ] && [ -f "$OUT_FILE" ]; then
    echo "$OUT_FILE"
    exit 0
fi

find_metal() {
    if [ -n "${METAL:-}" ] && [ -x "$METAL" ]; then
        echo "$METAL"
        return 0
    fi

    local mounted="/Volumes/MetalToolchainCryptex/Metal.xctoolchain/usr/bin/metal"
    if [ -x "$mounted" ] && [ -x "$(dirname "$mounted")/air-lld" ]; then
        echo "$mounted"
        return 0
    fi

    if command -v xcrun >/dev/null 2>&1; then
        local xcrun_metal
        xcrun_metal=$(xcrun --find metal 2>/dev/null || true)
        if [ -n "$xcrun_metal" ] && [ -x "$xcrun_metal" ] && [ -x "$(dirname "$xcrun_metal")/air-lld" ]; then
            echo "$xcrun_metal"
            return 0
        fi
    fi

    return 1
}

METAL_BIN=$(find_metal) || {
    echo "error: Metal compiler not found. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}

if [ -n "${AIR_LLD:-}" ] && [ -x "$AIR_LLD" ]; then
    AIR_LLD_BIN="$AIR_LLD"
else
    AIR_LLD_BIN="$(dirname "$METAL_BIN")/air-lld"
fi

if [ ! -x "$AIR_LLD_BIN" ]; then
    echo "error: air-lld not found next to metal compiler: $AIR_LLD_BIN" >&2
    exit 1
fi

if [ ! -d "$KERNEL_DIR" ]; then
    echo "error: MLX Metal kernels not found. Run swift build once to fetch dependencies." >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$CACHE_DIR"

# fence.metal uses system-scope coherent memory features that are unavailable in
# the current App Store Metal toolchain, so omit it from the bundled library.
KERNELS=(
  arg_reduce conv gemv layer_norm random rms_norm rope scaled_dot_product_attention
  arange binary binary_two copy fft reduce quantized fp_quantized scan softmax logsumexp sort ternary unary
  steel/conv/kernels/steel_conv
  steel/conv/kernels/steel_conv_3d
  steel/conv/kernels/steel_conv_general
  steel/gemm/kernels/steel_gemm_fused
  steel/gemm/kernels/steel_gemm_gather
  steel/gemm/kernels/steel_gemm_masked
  steel/gemm/kernels/steel_gemm_splitk
  steel/gemm/kernels/steel_gemm_segmented
  gemv_masked
  steel/attn/kernels/steel_attention
)

AIRS=()
for kernel in "${KERNELS[@]}"; do
    src="$KERNEL_DIR/$kernel.metal"
    name="$(basename "$kernel")"
    air="$OUT_DIR/$name.air"
    echo "  compiling $kernel.metal" >&2
    "$METAL_BIN" -x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
        -fmodules-cache-path="$CACHE_DIR" -mmacosx-version-min=14.0 \
        -c "$src" -I"$ROOT_DIR" -I"$KERNEL_DIR" -o "$air"
    AIRS+=("$air")
done

echo "  linking mlx.metallib" >&2
"$AIR_LLD_BIN" --macos_version_min 14.0 "${AIRS[@]}" -o "$OUT_FILE"

echo "$OUT_FILE"
