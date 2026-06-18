#!/usr/bin/env python3
"""
TypelessMLX - Persistent MLX Whisper transcription server.
Communicates via newline-delimited JSON over stdin/stdout (JSON-RPC style).
"""
import sys
import json
import os
import platform
import re
import traceback

_HESITATION_RE = re.compile(
    r'(?<![^\s，。！？、])(?:呃+|嗯+|啊+|哦+|喔+|哎+)(?=[,，。！？、\s]|$)',
    re.UNICODE
)


def strip_hesitations(text: str) -> str:
    text = _HESITATION_RE.sub('', text)
    text = re.sub(r'[，、]\s*[，、]', '，', text)   # collapse duplicate punctuation
    text = re.sub(r'^\s*[，。、！？]\s*', '', text)   # strip leading punctuation
    return text.strip()

_PUNCTUATION_PROMPT = "以下是普通话语音识别，请输出带有适当标点符号的简体中文文字。例如：今天天气很好，我们去公园走走吧。"


def ensure_trailing_punctuation(text: str) -> str:
    """若文字結尾沒有標點符號，補上句號。"""
    if text and text[-1] not in '。？！…」』':
        return text + '。'
    return text

# Default model: fallback to HF repo
DEFAULT_MODEL = os.path.expanduser("~/.local/share/typelessmlx/models/whisper-large-v3-mlx")
FALLBACK_MODEL = "mlx-community/whisper-large-v3-mlx"


def running_on_apple_silicon() -> bool:
    machine = platform.machine() or ""
    return sys.platform == "darwin" and machine.lower().startswith("arm")


def send(data: dict):
    print(json.dumps(data, ensure_ascii=False), flush=True)


_qwen3_model = None
_qwen3_model_path = None

_argos_initialized = False
_argos_ready = False   # True only when package is installed and translator loaded
_en_zh_translator = None
_argos_lock = None     # threading.Lock, set in main()

_TRANSLATE_MODEL = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
_llm_translator_model = None
_llm_translator_tokenizer = None
_llm_translator_ready = False


def _load_llm_translator_background():
    global _llm_translator_model, _llm_translator_tokenizer, _llm_translator_ready
    try:
        from mlx_lm import load
        sys.stderr.write(f"[TypelessMLX] Loading LLM translator: {_TRANSLATE_MODEL}\n")
        sys.stderr.flush()
        _llm_translator_model, _llm_translator_tokenizer = load(_TRANSLATE_MODEL)
        _llm_translator_ready = True
        sys.stderr.write("[TypelessMLX] LLM translator ready\n")
        sys.stderr.flush()
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] LLM translator load failed: {e}\n")
        sys.stderr.flush()


def translate_to_chinese_llm(text: str) -> str:
    if not text.strip() or not _llm_translator_ready:
        return ""
    try:
        from mlx_lm import generate
        messages = [
            {"role": "system", "content": "你是一名翻译。将用户发送的英文翻译成简体中文。只输出译文，不要解释，不要重复原文。"},
            {"role": "user", "content": text},
        ]
        tok = _llm_translator_tokenizer
        if hasattr(tok, "apply_chat_template"):
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        else:
            prompt = f"将以下英文翻译成简体中文，只输出译文：{text}"
        result = generate(_llm_translator_model, tok, prompt=prompt, max_tokens=300, verbose=False)
        result = result.strip()
        sys.stderr.write(f"[TypelessMLX] LLM translate result: {repr(result[:80])}\n")
        sys.stderr.flush()
        # Reject if result has no CJK characters (model generated English instead)
        if not any('一' <= c <= '鿿' for c in result):
            sys.stderr.write("[TypelessMLX] LLM returned non-Chinese, discarding\n")
            sys.stderr.flush()
            return ""
        return result
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] LLM translation failed: {e}\n")
        sys.stderr.flush()
        return ""


def _download_argos_background():
    """Download and install argostranslate en→zh in a background thread."""
    global _argos_initialized, _argos_ready, _en_zh_translator
    _CERT_FILE = "/Users/donhu/all_certs.pem"
    if os.path.exists(_CERT_FILE):
        os.environ["SSL_CERT_FILE"] = _CERT_FILE
        os.environ["REQUESTS_CA_BUNDLE"] = _CERT_FILE
    try:
        import argostranslate.package
        installed = argostranslate.package.get_installed_packages()
        if not any(p.from_code == "en" and p.to_code == "zh" for p in installed):
            sys.stderr.write("[TypelessMLX] 后台下载 en→zh 翻译语言包 (~100MB)...\n")
            sys.stderr.flush()
            argostranslate.package.update_package_index()
            available = argostranslate.package.get_available_packages()
            pkg = next((p for p in available if p.from_code == "en" and p.to_code == "zh"), None)
            if pkg is None:
                raise RuntimeError("argostranslate en→zh package not found in index")
            argostranslate.package.install_from_path(pkg.download())
            sys.stderr.write("[TypelessMLX] en→zh 语言包安装完成\n")
            sys.stderr.flush()
        # Use MiniSBD (offline sentence splitter) instead of Stanza
        import argostranslate.settings
        argostranslate.settings.chunk_type = argostranslate.settings.ChunkType.MINISBD
        import argostranslate.translate
        _en_zh_translator = argostranslate.translate.get_translation_from_codes("en", "zh")
        _argos_ready = True
        sys.stderr.write("[TypelessMLX] 翻译引擎就绪\n")
        sys.stderr.flush()
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] 翻译引擎初始化失败: {e}\n")
        sys.stderr.flush()
    finally:
        _argos_initialized = True


def translate_to_chinese(text: str) -> str:
    if not text.strip():
        return ""
    if not _argos_ready or _en_zh_translator is None:
        return ""   # Not ready yet — caller shows English fallback
    try:
        import argostranslate.settings
        argostranslate.settings.chunk_type = argostranslate.settings.ChunkType.MINISBD
        return _en_zh_translator.translate(text)
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] 翻译失败: {e}\n")
        sys.stderr.flush()
        return ""


def transcribe_qwen3(audio_path: str, model_path: str, language: str | None,
                     remove_fillers: bool = False) -> str:
    global _qwen3_model, _qwen3_model_path
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.generate import generate_transcription
    if _qwen3_model is None or _qwen3_model_path != model_path:
        sys.stderr.write(f"[TypelessMLX] Loading Qwen3-ASR model: {os.path.basename(model_path)}\n")
        sys.stderr.flush()
        _qwen3_model = load_model(model_path)
        _qwen3_model_path = model_path
    import tempfile
    tmp_path = os.path.join(tempfile.gettempdir(), f"typelessmlx_qwen3_{os.getpid()}")
    system = "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。"
    if remove_fillers:
        system += "移除说话者的语音犹豫音（例如「呃」「嗯」「啊」），但保留所有有意义的词汇。"
    result = generate_transcription(
        model=_qwen3_model,
        audio=audio_path,
        output_path=tmp_path,
        format="txt",
        system_prompt=system,
    )
    try:
        os.remove(tmp_path + ".txt")
    except OSError:
        pass
    text = (result.text if hasattr(result, "text") else str(result)).strip()
    return ensure_trailing_punctuation(text)


def transcribe(audio_path: str, model_path: str, language: str | None,
               initial_prompt: str | None = None, model_type: str = "whisper",
               remove_fillers: bool = False) -> str:
    if model_type == "qwen3":
        return transcribe_qwen3(audio_path, model_path, language, remove_fillers)
    import mlx_whisper
    use_fp16 = model_type == "whisper" and running_on_apple_silicon()
    if use_fp16:
        sys.stderr.write("[TypelessMLX] Apple Silicon detected, enabling fp16\n")
        sys.stderr.flush()
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        language=language or None,
        initial_prompt=initial_prompt or _PUNCTUATION_PROMPT,
        verbose=False,
        fp16=use_fp16,
    )
    text = result.get("text", "").strip()
    if remove_fillers:
        text = strip_hesitations(text)
    return ensure_trailing_punctuation(text)


def transcribe_subtitle(audio_path: str, model_path: str) -> str:
    """Whisper transcription for subtitle mode with multi-layer hallucination filtering."""
    import mlx_whisper
    use_fp16 = running_on_apple_silicon()
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        language="en",
        verbose=False,
        fp16=use_fp16,
    )
    segments = result.get("segments", [])
    if not segments:
        return ""

    # Filter each segment individually — averaged values miss mixed-content chunks
    good = []
    for s in segments:
        no_speech = s.get("no_speech_prob", 0.0)
        comp_ratio = s.get("compression_ratio", 1.0)
        # Whisper uses compression_ratio > 2.4 as its own hallucination signal
        if no_speech > 0.4 or comp_ratio > 2.4:
            sys.stderr.write(
                f"[TypelessMLX] Segment dropped: no_speech={no_speech:.2f} "
                f"compression={comp_ratio:.2f} text={repr(s.get('text','')[:40])}\n"
            )
            sys.stderr.flush()
            continue
        good.append(s)

    if not good:
        return ""
    # Require at least half the segments to survive filtering
    if len(good) < len(segments) / 2:
        sys.stderr.write(f"[TypelessMLX] Subtitle dropped: only {len(good)}/{len(segments)} segments passed\n")
        sys.stderr.flush()
        return ""

    return " ".join(s.get("text", "").strip() for s in good).strip()


def resolve_model(requested: str | None) -> str:
    if requested and requested.strip():
        return requested.strip()
    # Use local Breeze-ASR-25 if converted, else fallback
    if os.path.isdir(DEFAULT_MODEL):
        return DEFAULT_MODEL
    return FALLBACK_MODEL


def main():
    global _argos_lock
    import threading
    import mlx_whisper  # pre-load before background threads start to avoid import-lock races
    _argos_lock = threading.Lock()
    threading.Thread(target=_download_argos_background, daemon=True).start()
    threading.Thread(target=_load_llm_translator_background, daemon=True).start()

    # Signal Swift that we're ready
    send({"status": "ready"})
    sys.stderr.write("[TypelessMLX] Python backend ready\n")
    sys.stderr.write(f"[TypelessMLX] Inference precision: {'fp16' if running_on_apple_silicon() else 'fp32'} (arch: {platform.machine()})\n")
    sys.stderr.flush()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"[TypelessMLX] JSON parse error: {e}\n")
            sys.stderr.flush()
            continue

        req_id = req.get("id", "")
        action = req.get("action", "")

        try:
            if action == "ping":
                send({"id": req_id, "status": "pong"})

            elif action == "transcribe":
                audio_path = req.get("audio_path", "")
                if not audio_path or not os.path.exists(audio_path):
                    send({"id": req_id, "text": "", "error": f"Audio file not found: {audio_path}"})
                    continue

                model = resolve_model(req.get("model"))
                language = req.get("language")
                initial_prompt = req.get("initial_prompt")
                model_type = req.get("model_type", "whisper")
                remove_fillers = req.get("remove_fillers", False)

                sys.stderr.write(f"[TypelessMLX] Transcribing with model: {os.path.basename(model)}, type: {model_type}, lang: {language or 'auto'}, remove_fillers: {remove_fillers}\n")
                sys.stderr.flush()

                text = transcribe(audio_path, model, language, initial_prompt, model_type, remove_fillers)
                send({"id": req_id, "text": text, "error": None})

            elif action == "subtitle":
                audio_path = req.get("audio_path", "")
                if not audio_path or not os.path.exists(audio_path):
                    send({"id": req_id, "text": "", "translated": "", "error": f"Audio file not found: {audio_path}"})
                    continue
                model = resolve_model(req.get("model"))
                sys.stderr.write(f"[TypelessMLX] Subtitle: transcribing with {os.path.basename(model)}\n")
                sys.stderr.flush()
                text = transcribe_subtitle(audio_path, model)
                # Filter Whisper hallucinations: too short or pure punctuation
                clean = re.sub(r'[\s\.,!?。，！？、…\-]+', '', text)
                if len(clean) < 4:
                    send({"id": req_id, "text": "", "translated": "", "error": None})
                    continue
                # Filter known Whisper silence/noise hallucinations (case-insensitive)
                _HALLUCINATIONS = {
                    "thank you for watching", "thanks for watching",
                    "thank you", "thanks", "you", "please subscribe",
                    "like and subscribe", "subscribe", "bye", "goodbye",
                    "see you next time", "see you later",
                    "this video was sponsored by the us department of education",
                    "this video is sponsored by the us department of education",
                    "this video was made possible by the us department of education",
                }
                if text.strip().lower().rstrip('.!?,。') in _HALLUCINATIONS:
                    send({"id": req_id, "text": "", "translated": "", "error": None})
                    continue
                if text.strip():
                    # Prefer LLM translator; fall back to argostranslate while model loads
                    translated = translate_to_chinese_llm(text)
                    if not translated:
                        translated = translate_to_chinese(text)
                else:
                    translated = ""
                send({"id": req_id, "text": text, "translated": translated, "error": None})

            else:
                send({"id": req_id, "error": f"Unknown action: {action}"})

        except Exception as e:
            error_msg = f"{type(e).__name__}: {e}"
            sys.stderr.write(f"[TypelessMLX] Error handling '{action}': {traceback.format_exc()}\n")
            sys.stderr.flush()
            send({"id": req_id, "text": "", "error": error_msg})


if __name__ == "__main__":
    main()
