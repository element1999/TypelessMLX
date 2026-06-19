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

_TRANSLATE_MODEL = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
_llm_translator_model = None
_llm_translator_tokenizer = None
_llm_translator_ready = False
_llm_translator_model_path = _TRANSLATE_MODEL  # track which model is currently loaded


def _load_text_model(model_path: str):
    """Load (or reload) the LLM used for translation and lookup."""
    global _llm_translator_model, _llm_translator_tokenizer
    global _llm_translator_ready, _llm_translator_model_path
    if _llm_translator_ready and _llm_translator_model_path == model_path:
        return
    # Preserve current state so we can roll back on failure
    prev_model = _llm_translator_model
    prev_tok = _llm_translator_tokenizer
    prev_ready = _llm_translator_ready
    prev_path = _llm_translator_model_path
    try:
        from mlx_lm import load
        sys.stderr.write(f"[TypelessMLX] Loading text model: {model_path}\n")
        sys.stderr.flush()
        _llm_translator_ready = False
        _llm_translator_model, _llm_translator_tokenizer = load(model_path)
        _llm_translator_model_path = model_path
        _llm_translator_ready = True
        sys.stderr.write("[TypelessMLX] Text model ready\n")
        sys.stderr.flush()
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] Text model load failed: {e}\n")
        sys.stderr.flush()
        # Roll back to previous working model
        _llm_translator_model = prev_model
        _llm_translator_tokenizer = prev_tok
        _llm_translator_ready = prev_ready
        _llm_translator_model_path = prev_path

# Subtitle stream session state (module-level, server is single-threaded)
_subtitle_buffer: list = []          # list of np.ndarray float32 at 16kHz
_subtitle_prev_text: str = ""
_subtitle_stable_count: int = 0
_subtitle_qwen3_model = None
_subtitle_qwen3_model_path: str | None = None
_subtitle_committed_prefix: str = ""  # eagerly-translated prefix of current utterance
_subtitle_utterance_sentences: list = []  # all eager sentences for current utterance
_SUBTITLE_STABLE_THRESHOLD = 2       # consecutive identical results → commit utterance
_SUBTITLE_MAX_SAMPLES = 15 * 16000   # 15s max accumulation before force-commit
_SUBTITLE_MIN_SAMPLES = 8000         # 0.5s minimum before running ASR

# CT-Punc punctuation restoration (sherpa-onnx, lazy loaded)
_punc_model = None
_PUNC_MODEL_NAME = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
_PUNC_CACHE_DIR = os.path.join(os.path.expanduser("~/.cache/sherpa-onnx"), _PUNC_MODEL_NAME)
_PUNC_DOWNLOAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/"
    + _PUNC_MODEL_NAME + ".tar.bz2"
)


def _ensure_punc_model() -> bool:
    """Download CT-Punc model if not already cached. Returns True if ready."""
    onnx_path = os.path.join(_PUNC_CACHE_DIR, "model.int8.onnx")
    if os.path.exists(onnx_path):
        return True
    import urllib.request, tarfile
    sys.stderr.write(f"[TypelessMLX] Downloading CT-Punc model to {_PUNC_CACHE_DIR}...\n")
    sys.stderr.flush()
    try:
        os.makedirs(os.path.dirname(_PUNC_CACHE_DIR), exist_ok=True)
        tmp_tar = _PUNC_CACHE_DIR + ".tar.bz2"
        urllib.request.urlretrieve(_PUNC_DOWNLOAD_URL, tmp_tar)
        with tarfile.open(tmp_tar, "r:bz2") as tf:
            tf.extractall(os.path.dirname(_PUNC_CACHE_DIR))
        os.remove(tmp_tar)
        sys.stderr.write("[TypelessMLX] CT-Punc model ready\n")
        sys.stderr.flush()
        return os.path.exists(onnx_path)
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] CT-Punc download failed: {e}\n")
        sys.stderr.flush()
        return False


# System prompts Qwen3-ASR may echo back verbatim on silence/noise
_ASR_SYSTEM_PROMPTS = {
    "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。",
    "请输出语音识别结果，保持原始语言，不要添加解释。",
}


def _is_silence_hallucination(text: str) -> bool:
    """Return True if the ASR output is a verbatim echo of a system prompt."""
    t = text.strip()
    return any(t == p or t.startswith(p) or p.startswith(t) for p in _ASR_SYSTEM_PROMPTS)


def punc_restore(text: str) -> str:

    """Add punctuation to raw ASR text using sherpa-onnx CT-Transformer."""
    global _punc_model
    if not text.strip():
        return text
    try:
        import sherpa_onnx
        if _punc_model is None:
            if not _ensure_punc_model():
                return text
            cfg = sherpa_onnx.OfflinePunctuationConfig(
                model=sherpa_onnx.OfflinePunctuationModelConfig(
                    ct_transformer=os.path.join(_PUNC_CACHE_DIR, "model.int8.onnx"),
                    num_threads=2,
                    provider="cpu",
                )
            )
            _punc_model = sherpa_onnx.OfflinePunctuation(cfg)
            sys.stderr.write("[TypelessMLX] CT-Punc loaded\n")
            sys.stderr.flush()
        return _punc_model.add_punctuation(text)
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] CT-Punc error: {e}\n")
        sys.stderr.flush()
        return text


def _load_llm_translator_background():
    _load_text_model(_TRANSLATE_MODEL)


_SENT_END = re.compile(r'([。！？!?]+|\.(?=\s|$))')


def _get_completed_sentences(text: str) -> tuple[list[str], str]:
    """Split into (complete sentences with end-mark, remaining incomplete tail)."""
    parts = _SENT_END.split(text)
    sentences = []
    i = 0
    while i + 1 < len(parts):
        combined = (parts[i].strip() + parts[i + 1]).strip()
        if combined:
            sentences.append(combined)
        i += 2
    tail = parts[-1].strip() if parts else ""
    return sentences, tail

def translate_to_chinese_llm(text: str) -> str:
    if not text.strip() or not _llm_translator_ready:
        return ""
    try:
        from mlx_lm import generate
        # Put the instruction inside the user turn for small models that ignore system prompts
        messages = [
            {"role": "user", "content": f"将以下英文翻译成简体中文，只输出中文译文，不要输出英文：\n{text}"},
        ]
        tok = _llm_translator_tokenizer
        if hasattr(tok, "apply_chat_template"):
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        else:
            prompt = f"将以下英文翻译成简体中文，只输出译文：{text}"
        result = generate(_llm_translator_model, tok, prompt=prompt, max_tokens=400, verbose=False)
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


def lookup_word_llm(text: str) -> str:
    """Return a concise dictionary-style entry for a word or phrase using the LLM."""
    if not text.strip() or not _llm_translator_ready:
        return ""
    try:
        from mlx_lm import generate
        messages = [
            {"role": "system", "content": (
                "You are a bilingual dictionary. For the given word or phrase, output a concise entry in this exact format:\n"
                "Line 1: part of speech + English definition (max 15 words)\n"
                "Line 2: Chinese translation or explanation (max 10 Chinese characters)\n"
                "Example for 'ephemeral':\n"
                "adj. lasting for a very short time\n"
                "短暂的；转瞬即逝的\n"
                "Output only the two lines. No extra explanation."
            )},
            {"role": "user", "content": text},
        ]
        tok = _llm_translator_tokenizer
        if hasattr(tok, "apply_chat_template"):
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        else:
            prompt = f"Dictionary entry for: {text}"
        result = generate(_llm_translator_model, tok, prompt=prompt, max_tokens=80, verbose=False)
        result = result.strip()
        sys.stderr.write(f"[TypelessMLX] LLM lookup result: {repr(result[:100])}\n")
        sys.stderr.flush()
        # Post-process: keep at most 3 lines, each capped at 100 chars
        lines = [ln.strip() for ln in result.splitlines() if ln.strip()][:3]
        lines = [ln[:100] for ln in lines]
        # Remove duplicate comma-separated tokens within a line
        def dedup_commas(s: str) -> str:
            parts = [p.strip() for p in s.split("；")]
            seen, out = set(), []
            for p in parts:
                if p.lower() not in seen:
                    seen.add(p.lower()); out.append(p)
            return "；".join(out)
        lines = [dedup_commas(ln) if "；" in ln else ln for ln in lines]
        return "\n".join(lines)
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] LLM lookup failed: {e}\n")
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
    if _is_silence_hallucination(text):
        return ""
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


def translate_to_english_llm(text: str) -> str:
    if not text.strip() or not _llm_translator_ready:
        return ""
    try:
        from mlx_lm import generate
        messages = [
            {"role": "system", "content": "You are a translator. Translate the Chinese text to natural, fluent English. Output only the translation, no explanations."},
            {"role": "user", "content": text},
        ]
        tok = _llm_translator_tokenizer
        if hasattr(tok, "apply_chat_template"):
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        else:
            prompt = f"Translate to English: {text}"
        result = generate(_llm_translator_model, tok, prompt=prompt, max_tokens=300, verbose=False)
        result = result.strip()
        sys.stderr.write(f"[TypelessMLX] translate_to_english result: {repr(result[:80])}\n")
        sys.stderr.flush()
        # Reject if result still has too many CJK characters
        if result and sum(1 for c in result if '一' <= c <= '鿿') / max(len(result), 1) > 0.3:
            sys.stderr.write("[TypelessMLX] translate_to_english: result not English, discarding\n")
            sys.stderr.flush()
            return ""
        return result
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] translate_to_english failed: {e}\n")
        sys.stderr.flush()
        return ""



    """Generate a dictionary-style entry using the LLM."""
    if not text.strip() or not _llm_translator_ready:
        return ""
    try:
        from mlx_lm import generate
        messages = [
            {"role": "system", "content": (
                "你是英汉词典，只输出2行，不多不少。格式：\n"
                "第1行: [词性] [中文核心含义，不超过8字]\n"
                "第2行: 例: [英文短句] → [中文]\n\n"
                "示例（单词 calculate）：\n"
                "v. 计算；估算\n"
                "例: Calculate the cost. → 计算成本。"
            )},
            {"role": "user", "content": text},
        ]
        tok = _llm_translator_tokenizer
        if hasattr(tok, "apply_chat_template"):
            prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        else:
            prompt = f"查词：{text}"
        result = generate(_llm_translator_model, tok, prompt=prompt, max_tokens=80, verbose=False)
        result = result.strip()
        # Keep at most 3 non-empty lines; truncate each to 100 chars
        lines = [l[:100] for l in result.splitlines() if l.strip()]
        # Within each line, deduplicate comma/semicolon-separated tokens
        clean = []
        for line in lines[:3]:
            if any(sep in line for sep in ('，', '；', '、')):
                parts = re.split(r'[，；、]', line)
                seen_p, deduped_p = set(), []
                for p in parts:
                    k = p.strip()
                    if k and k not in seen_p:
                        seen_p.add(k)
                        deduped_p.append(p)
                    elif k in seen_p:
                        break
                clean.append('；'.join(deduped_p))
            else:
                clean.append(line)
        result = "\n".join(clean).strip()
        sys.stderr.write(f"[TypelessMLX] lookup result: {repr(result[:120])}\n")
        sys.stderr.flush()
        return result
    except Exception as e:
        sys.stderr.write(f"[TypelessMLX] lookup failed: {e}\n")
        sys.stderr.flush()
        return ""


def _subtitle_read_wav(path: str):
    """Read WAV file as float32 mono normalized to [-1, 1]."""
    import numpy as np
    import wave
    with wave.open(path, 'rb') as f:
        n_channels = f.getnchannels()
        sampwidth = f.getsampwidth()
        n_frames = f.getnframes()
        raw = f.readframes(n_frames)
    if sampwidth == 2:
        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sampwidth == 4:
        data = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        data = np.frombuffer(raw, dtype=np.float32)
    if n_channels > 1:
        data = data.reshape(-1, n_channels).mean(axis=1)
    return data


def _subtitle_write_wav(path: str, data, sample_rate: int = 16000):
    """Write float32 array as 16-bit mono WAV."""
    import numpy as np
    import wave
    pcm = np.clip(data * 32767, -32768, 32767).astype(np.int16)
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sample_rate)
        f.writeframes(pcm.tobytes())


def _transcribe_qwen3_subtitle(audio_path: str, model_path: str) -> str:
    """Run Qwen3-ASR on audio; returns transcript in original language (VAD built-in)."""
    global _subtitle_qwen3_model, _subtitle_qwen3_model_path
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.generate import generate_transcription
    if _subtitle_qwen3_model is None or _subtitle_qwen3_model_path != model_path:
        sys.stderr.write(f"[TypelessMLX] Loading subtitle ASR: {model_path}\n")
        sys.stderr.flush()
        _subtitle_qwen3_model = load_model(model_path)
        _subtitle_qwen3_model_path = model_path
    import tempfile
    tmp_out = os.path.join(tempfile.gettempdir(), f"typelessmlx_subout_{os.getpid()}")
    result = generate_transcription(
        model=_subtitle_qwen3_model,
        audio=audio_path,
        output_path=tmp_out,
        format="txt",
        system_prompt="请输出语音识别结果，保持原始语言，不要添加解释。",
    )
    try:
        os.remove(tmp_out + ".txt")
    except OSError:
        pass
    text = (result.text if hasattr(result, "text") else str(result)).strip()
    if _is_silence_hallucination(text):
        return ""
    return text


def handle_subtitle_stream(req_id: str, req: dict):
    """Accumulate audio chunks; eagerly translate completed sentences in partials,
    commit remaining tail on VAD-detected silence."""
    global _subtitle_prev_text, _subtitle_stable_count, _subtitle_committed_prefix
    global _subtitle_utterance_sentences
    import numpy as np
    import tempfile

    reset = req.get("reset", False)
    if reset:
        _subtitle_buffer.clear()
        _subtitle_prev_text = ""
        _subtitle_stable_count = 0
        _subtitle_committed_prefix = ""
        _subtitle_utterance_sentences = []
        send({"id": req_id, "text": "", "committed": False})
        return

    audio_path = req.get("audio_path", "")
    model_path = req.get("model_path", "mlx-community/Qwen3-ASR-0.6B-8bit")

    if not audio_path or not os.path.exists(audio_path):
        send({"id": req_id, "text": "", "committed": False,
              "error": f"Audio not found: {audio_path}"})
        return

    chunk = _subtitle_read_wav(audio_path)
    _subtitle_buffer.append(chunk)

    # Trim to max 15s
    total_samples = sum(len(a) for a in _subtitle_buffer)
    while total_samples > _SUBTITLE_MAX_SAMPLES and len(_subtitle_buffer) > 1:
        total_samples -= len(_subtitle_buffer[0])
        _subtitle_buffer.pop(0)

    if total_samples < _SUBTITLE_MIN_SAMPLES:
        send({"id": req_id, "text": "", "committed": False})
        return

    # Run Qwen3-ASR on full accumulated buffer
    combined = np.concatenate(_subtitle_buffer)
    tmp_wav = os.path.join(tempfile.gettempdir(), f"typelessmlx_sub_{os.getpid()}.wav")
    _subtitle_write_wav(tmp_wav, combined)
    text = _transcribe_qwen3_subtitle(tmp_wav, model_path)
    try:
        os.remove(tmp_wav)
    except OSError:
        pass

    sys.stderr.write(f"[TypelessMLX] Subtitle ASR ({total_samples/16000:.1f}s buf): {repr(text[:60])}\n")
    sys.stderr.flush()

    # Find new completed sentences not yet eagerly translated
    if text.startswith(_subtitle_committed_prefix):
        suffix = text[len(_subtitle_committed_prefix):]
    else:
        # ASR corrected earlier text — reset prefix, re-scan from scratch
        _subtitle_committed_prefix = ""
        suffix = text

    new_sentences, tail = _get_completed_sentences(punc_restore(suffix) if suffix.strip() else suffix)

    eager_pairs: list[dict] = []
    for s in new_sentences:
        zh = translate_to_chinese_llm(s) if _llm_translator_ready else ""
        eager_pairs.append({"en": s, "zh": zh})
        _subtitle_committed_prefix += s
        _subtitle_utterance_sentences.append({"en": s, "zh": zh})
        sys.stderr.write(f"[TypelessMLX] Eager sentence: {repr(s[:50])}\n")
        sys.stderr.flush()

    # VAD stability check
    force_commit = total_samples >= _SUBTITLE_MAX_SAMPLES
    if text == _subtitle_prev_text:
        _subtitle_stable_count += 1
        commit = (_subtitle_stable_count >= _SUBTITLE_STABLE_THRESHOLD and bool(text)) or force_commit
    else:
        _subtitle_stable_count = 0
        _subtitle_prev_text = text
        commit = force_commit

    if commit:
        # For transcript: use the FULL stable ASR text — punc_restore + split + translate fresh.
        # This gives clean, context-aware output with no duplicates from prefix tracking.
        full_punct = punc_restore(text) if text.strip() else ""
        transcript_sents, transcript_tail = _get_completed_sentences(full_punct)
        if transcript_tail.strip():
            transcript_sents.append(transcript_tail.strip())
        utterance_pairs = []
        for s in transcript_sents:
            zh = translate_to_chinese_llm(s) if _llm_translator_ready else ""
            utterance_pairs.append({"en": s, "zh": zh})

        _subtitle_buffer.clear()
        _subtitle_prev_text = ""
        _subtitle_stable_count = 0
        _subtitle_committed_prefix = ""
        _subtitle_utterance_sentences = []
        sys.stderr.write(f"[TypelessMLX] Subtitle commit: {len(utterance_pairs)} transcript sents, {len(eager_pairs)} new eager\n")
        sys.stderr.flush()
        send({"id": req_id, "text": "", "committed": True, "chinese": "",
              "eager_sentences": eager_pairs,
              "utterance_sentences": utterance_pairs})
    else:
        send({"id": req_id, "text": tail, "committed": False, "eager_sentences": eager_pairs})


def main():
    import threading
    import mlx_whisper  # pre-load before background threads start to avoid import-lock races
    # Pre-import mlx_lm on the main thread so the background loader and request handler
    # don't race on Python's importlib lock, which causes the deadlock seen in practice.
    try:
        from mlx_lm import load as _mlx_lm_load, generate as _mlx_lm_generate  # noqa: F401
    except ImportError:
        pass
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
                    translated = translate_to_chinese_llm(text)
                else:
                    translated = ""
                send({"id": req_id, "text": text, "translated": translated, "error": None})

            elif action == "translate":
                text = req.get("text", "")
                if not text.strip():
                    send({"id": req_id, "text": "", "error": None})
                    continue
                text_model = req.get("text_model")
                if text_model:
                    _load_text_model(text_model)
                # Auto-detect direction: >30% CJK → Chinese→English, else English→Chinese
                cjk = sum(1 for c in text if '一' <= c <= '鿿')
                is_chinese = cjk / max(len(text.strip()), 1) > 0.3
                if is_chinese:
                    sys.stderr.write(f"[TypelessMLX] translate: ZH→EN\n")
                    sys.stderr.flush()
                    translated = translate_to_english_llm(text)
                else:
                    sys.stderr.write(f"[TypelessMLX] translate: EN→ZH\n")
                    sys.stderr.flush()
                    translated = translate_to_chinese_llm(text)
                send({"id": req_id, "text": translated, "error": None})

            elif action == "lookup":
                text = req.get("text", "")
                if not text.strip():
                    send({"id": req_id, "text": "", "error": None})
                    continue
                text_model = req.get("text_model")
                if text_model:
                    _load_text_model(text_model)
                entry = lookup_word_llm(text)
                send({"id": req_id, "text": entry, "error": None})

            elif action == "subtitle_stream":
                handle_subtitle_stream(req_id, req)

            else:
                send({"id": req_id, "error": f"Unknown action: {action}"})

        except Exception as e:
            error_msg = f"{type(e).__name__}: {e}"
            sys.stderr.write(f"[TypelessMLX] Error handling '{action}': {traceback.format_exc()}\n")
            sys.stderr.flush()
            send({"id": req_id, "text": "", "error": error_msg})


if __name__ == "__main__":
    main()
