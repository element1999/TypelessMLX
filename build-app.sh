#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TypelessMLX"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/TypelessMLX/TypelessMLX.entitlements"
INSTALL_DIR="/Applications/$APP_NAME.app"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/TypelessMLX/Info.plist" 2>/dev/null || echo "0.0.0")
VENV_BUNDLED=0   # set to 1 after venv is successfully copied
DMG_PATH="$BUILD_DIR/${APP_NAME}-${APP_VERSION}.dmg"  # recalculated after venv step

INSTALL_APP=0
MODE="dev"        # dev | release
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

usage() {
    cat <<EOF
Usage: $0 [--dev|--release] [--install|-i] [--allow-adhoc]

Modes:
  (default)   Dev mode — debug binary, no venv bundle, no DMG. Fast iteration.
  --release   Release mode — release binary, bundle venv, create DMG + model zips.

Options:
  --install, -i   Copy app to /Applications and launch after build.
  --allow-adhoc   Allow ad-hoc signing (dev mode uses ad-hoc automatically).

Environment:
  SIGN_IDENTITY           Code signing identity, e.g. "Apple Development: You (TEAMID)"
  ALLOW_ADHOC_SIGNING=1   Same as --allow-adhoc flag.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dev)          MODE="dev" ;;
        --release)      MODE="release" ;;
        --install|-i)   INSTALL_APP=1 ;;
        --allow-adhoc)  ALLOW_ADHOC_SIGNING=1 ;;
        --help|-h)      usage; exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Dev mode always allows ad-hoc signing
if [ "$MODE" = "dev" ]; then
    ALLOW_ADHOC_SIGNING=1
fi

find_default_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null |
        awk -F '"' '
            /"Apple Development: / { print $2; found = 1; exit }
            /"Developer ID Application: / && fallback == "" { fallback = $2 }
            END { if (!found && fallback != "") print fallback }
        '
}

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(find_default_signing_identity || true)"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    if [ "$ALLOW_ADHOC_SIGNING" = "1" ]; then
        SIGN_IDENTITY="-"
    else
        echo "❌ No Apple code signing identity found."
        echo "   Run with --allow-adhoc, or set SIGN_IDENTITY."
        exit 1
    fi
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════╗"
if [ "$MODE" = "dev" ]; then
    echo "║   TypelessMLX Dev Build v${APP_VERSION}     ║"
else
    echo "║   TypelessMLX Release v${APP_VERSION}       ║"
fi
echo "╚══════════════════════════════════════╝"
echo ""
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "⚠️  Ad-hoc signing (permissions may need re-approval after rebuilds)"
else
    echo "🔐 Signing identity: $SIGN_IDENTITY"
fi
echo ""

# ── Step 1: Build ─────────────────────────────────────────────────────────────
cd "$PROJECT_DIR"
if [ "$MODE" = "dev" ]; then
    echo "🔨 Building debug binary..."
    swift build 2>&1
    BINARY_SRC=".build/debug/TypelessMLX"
else
    echo "🔨 Building release binary..."
    swift build -c release 2>&1
    BINARY_SRC=".build/release/TypelessMLX"
fi

# ── Step 2: App bundle ────────────────────────────────────────────────────────
echo ""
echo "📦 Creating app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_SRC" "$APP_BUNDLE/Contents/MacOS/TypelessMLX"
cp "TypelessMLX/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

mkdir -p "$APP_BUNDLE/Contents/Resources/backend"
cp backend/transcribe_server.py "$APP_BUNDLE/Contents/Resources/backend/"
cp backend/convert.py "$APP_BUNDLE/Contents/Resources/backend/"
cp backend/requirements.txt "$APP_BUNDLE/Contents/Resources/backend/"
echo "  ✅ Python backend copied"

if [ "$MODE" = "release" ]; then
    VENV_SRC="$HOME/.local/share/typelessmlx/venv"
    if [ -d "$VENV_SRC" ]; then
        echo "  📦 Bundling Python venv (resolving symlinks — this takes a while)..."
        cp -RL "$VENV_SRC" "$APP_BUNDLE/Contents/Resources/venv"
        VENV_BUNDLED=1
        echo "  ✅ Venv bundled ($(du -sh "$APP_BUNDLE/Contents/Resources/venv" | awk '{print $1}'))"
    else
        echo "  ⚠️  No venv at $VENV_SRC — skipping venv bundle"
    fi
else
    echo "  ℹ️  Dev mode: using system venv at ~/.local/share/typelessmlx/venv"
fi

if [ -f "$PROJECT_DIR/icon/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/icon/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  ✅ App icon copied"
fi

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# ── Step 3: Code signing ──────────────────────────────────────────────────────
echo ""
echo "🔐 Code signing..."
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --identifier "com.typelessmlx.app" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE" 2>&1

codesign --verify --deep --strict "$APP_BUNDLE"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature" || true

# ── Step 4: DMG + model archives (release only) ───────────────────────────────
if [ "$MODE" = "release" ]; then
    # Recalculate DMG name now that we know whether venv was bundled
    if [ "$VENV_BUNDLED" = "1" ]; then
        DMG_PATH="$BUILD_DIR/${APP_NAME}-${APP_VERSION}-full.dmg"
    else
        DMG_PATH="$BUILD_DIR/${APP_NAME}-${APP_VERSION}.dmg"
    fi
    echo ""
    echo "💿 Creating DMG..."
    DMG_STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -volname "$APP_NAME $APP_VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" 2>&1
    rm -rf "$DMG_STAGING" || true
    DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
    echo "  ✅ DMG: $DMG_PATH ($DMG_SIZE)"

    echo ""
    echo "📦 Packaging model archives..."
    HF_CACHE="$HOME/.cache/huggingface/hub"

    package_model_archive() {
        local model_id="$1" repo="$2"
        local escaped_repo
        escaped_repo=$(echo "$repo" | sed 's|/|--|g')
        local cache_dir="$HF_CACHE/models--$escaped_repo"
        local snapshot_dir
        snapshot_dir=$(ls -td "$cache_dir/snapshots"/*/ 2>/dev/null | head -1)
        if [ -z "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ]; then
            echo "  ⚠️  跳过 $model_id（本地未缓存）"
            return 0
        fi

        local snapshot_hash
        snapshot_hash=$(basename "${snapshot_dir%/}")
        local staging="$BUILD_DIR/${model_id}-staging"
        local archive="$BUILD_DIR/${model_id}-model.zip"

        rm -rf "$staging"
        mkdir -p "$staging/model"

        echo "  复制 $model_id 模型文件..."
        (cd "${snapshot_dir%/}" && cp -RL . "$staging/model/")

        local escaped_repo_val="$escaped_repo"
        local snapshot_hash_val="$snapshot_hash"
        local model_id_val="$model_id"

        cat > "$staging/install.sh" << INSTALL_EOF
#!/bin/bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
SNAPSHOT_HASH="${snapshot_hash_val}"
CACHE_DIR="\$HOME/.cache/huggingface/hub/models--${escaped_repo_val}"
SNAPSHOT_DIR="\$CACHE_DIR/snapshots/\$SNAPSHOT_HASH"

echo "📦 正在安装模型: ${model_id_val}..."
mkdir -p "\$SNAPSHOT_DIR"
mkdir -p "\$CACHE_DIR/refs"
echo "  复制模型文件..."
cp -r "\$SCRIPT_DIR/model/." "\$SNAPSHOT_DIR/"
printf '%s' "\$SNAPSHOT_HASH" > "\$CACHE_DIR/refs/main"
echo "✅ 安装完成: \$SNAPSHOT_DIR"
echo "   重启 TypelessMLX 后，在设置中选择对应模型即可使用。"
INSTALL_EOF

        chmod +x "$staging/install.sh"
        echo "  压缩打包中..."
        (cd "$staging" && zip -r "$archive" . -x "*.DS_Store" > /dev/null)
        rm -rf "$staging"

        local size
        size=$(du -sh "$archive" | awk '{print $1}')
        echo "  ✅ $(basename "$archive") ($size)"
    }

    package_model_archive "qwen3-asr-0.6b"  "mlx-community/Qwen3-ASR-0.6B-8bit"
    package_model_archive "qwen3-asr-1.7b"  "mlx-community/Qwen3-ASR-1.7B-8bit"
    package_model_archive "qwen2.5-1.5b-translate" "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    package_model_archive "whisper-large-v3" "mlx-community/whisper-large-v3-mlx"
fi

# ── Step 5: Report ────────────────────────────────────────────────────────────
echo ""
APP_SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
BINARY_SIZE=$(du -sh "$APP_BUNDLE/Contents/MacOS/TypelessMLX" | awk '{print $1}')
echo "═══════════════════════════════════════"
echo "  ✅ Build complete! v${APP_VERSION} [${MODE}]"
echo "  📍 $APP_BUNDLE"
echo "  📏 App size: $APP_SIZE  Binary: $BINARY_SIZE"
if [ "$MODE" = "release" ]; then
    echo "  💿 $DMG_PATH ($DMG_SIZE)"
fi
echo "═══════════════════════════════════════"

# ── Step 6: Install ───────────────────────────────────────────────────────────
if [ "$INSTALL_APP" = "1" ]; then
    echo ""
    echo "📲 Installing to /Applications..."
    killall TypelessMLX 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_DIR"
    cp -R "$APP_BUNDLE" "$INSTALL_DIR"
    echo "✅ Installed to $INSTALL_DIR"
    echo ""
    echo "🚀 Launching TypelessMLX..."
    open "$INSTALL_DIR"
else
    echo ""
    echo "To install:  $0 --install"
    echo "To run:      open \"$APP_BUNDLE\""
fi

if [ "$MODE" = "release" ]; then
    echo ""
    echo "⚠️  首次使用注意事项："
    echo "  1. 授权麦克风访问（系统设置 → 隐私与安全 → 麦克风）"
    echo "  2. 授权辅助功能（系统设置 → 隐私与安全 → 辅助功能）"
    echo "  3. 授权输入监控（系统设置 → 隐私与安全 → 输入监控）"
    echo "  4. App 启动后会自动显示设置窗口，点击"开始安装"复制 Python 环境"
    echo "  5. 完成后按 Right Option 即可开始录音"
fi
