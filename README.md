# TypelessMLX

私有、离线的 macOS 语音输入工具，基于 Apple Silicon 本地运行。按住快捷键说话，识别结果直接粘贴到当前光标位置。

> **macOS 13.0+ · Apple Silicon (M1/M2/M3+) · 仅限本机推理，不联网**

---

## 功能

### 语音输入（核心）
按住 Right Option 说话，松开后识别结果自动粘贴到前台应用。支持切换为 Toggle 模式（按一次开始，再按停止）。

### 实时双语字幕
开启后捕获系统音频（会议、视频均可），实时显示英文字幕并同步翻译成中文：
- **字幕条**：屏幕中下方，显示当前句子（英文 + 中文），新句子覆盖旧句子
- **文字记录**：右上角浮窗，每次停顿后写入完整段落，支持滚动查看

### 查词 / 翻译
选中文字后按快捷键，弹出浮窗显示结果，支持英↔中双向翻译：

| 功能 | 默认快捷键 |
|------|-----------|
| 查词 | ⌃⌥D |
| 句子翻译 | ⌃⌥T |
| OCR 截图识别 | ⌃⌥O |

所有快捷键均可在设置中自定义。

### OCR 截图
按快捷键后屏幕变暗，拖拽框选区域，识别文字后弹出预览，点击「粘贴」插入当前光标。使用 macOS 内置 Vision 框架，支持中英混排，离线运行。

---

## 支持的 ASR 模型

| 模型 | 大小 | 特点 |
|------|------|------|
| macOS 内置 | 无需下载 | 最快 |
| Qwen3-ASR 0.6B | ~1 GB | 中文最佳，**推荐** |
| Qwen3-ASR 1.7B | ~2 GB | 更高精度 |
| WhisperKit Large v3 | 947 MB | 多语言，最高精度 |
| WhisperKit Large v3 Turbo | 632 MB | 多语言，速度/体积平衡 |
| WhisperKit Small | 216 MB | 多语言，最快 |

实时字幕固定使用 Qwen3-ASR 0.6B（速度优先）。

---

## 安装

### 1. 下载主程序
从 Release 页面下载 `TypelessMLX-x.x.x.dmg`，拖入 `/Applications` 即可。

### 2. 安装模型（可选，推荐预装）
每个模型单独打包为 zip，解压后运行 `install.sh`：

```bash
unzip qwen3-asr-0.6b-model.zip
cd qwen3-asr-0.6b-model
bash install.sh
```

**推荐安装组合：**
- `qwen3-asr-0.6b-model.zip` — 语音输入 + 实时字幕
- `qwen2.5-1.5b-translate-model.zip` — 查词 / 句子翻译
- `whisper-large-v3-turbo-632m-model.zip` — WhisperKit 多语言备用模型

如果不预装模型，首次使用时 App 会自动下载模型权重（通过 hf-mirror.com）。WhisperKit tokenizer 已随 App 内置，不会在用户下载 WhisperKit 模型时额外访问 OpenAI tokenizer repo。

### 3. 首次启动
1. 打开 TypelessMLX，菜单栏出现图标
2. 授权麦克风、辅助功能权限
3. 在设置中选择 ASR 模型，如有需要点击下载
4. 按住 Right Option 开始说话

---

## 系统要求

- Mac with Apple Silicon (M1 或更新)
- macOS 13.0+
- 内存：8 GB 以上
- 存储：模型按需，最小配置（macOS 内置模型）几乎不占额外空间

---

## 隐私

所有推理均在本机完成，不上传任何语音或文字数据。模型缓存于 `~/.cache/huggingface/hub/`。

---

## 构建

```bash
# 调试构建
swift build

# 下载并内置 WhisperKit tokenizer（release 前执行一次）
./scripts/download-whisper-tokenizers.sh

# Release 打包（含模型 zip）
./build-app.sh --release --allow-adhoc

# 构建并安装到 /Applications
./build-app.sh --install
```

---

## 许可

MIT License
