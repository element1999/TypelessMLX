#!/usr/bin/env python3
"""
Minimal translation/lookup server for TypelessMLX.
JSON-RPC over stdin/stdout. Only handles translate and lookup actions.
"""
import sys, json, os

_TRANSLATE_MODEL = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
_model = None
_tokenizer = None
_ready = False


def send(data: dict):
    print(json.dumps(data, ensure_ascii=False), flush=True)


def load_model():
    global _model, _tokenizer, _ready
    try:
        from mlx_lm import load
        sys.stderr.write(f"[TranslateServer] Loading {_TRANSLATE_MODEL}...\n")
        sys.stderr.flush()
        _model, _tokenizer = load(_TRANSLATE_MODEL)
        _ready = True
        sys.stderr.write("[TranslateServer] Model ready\n")
        sys.stderr.flush()
    except Exception as e:
        sys.stderr.write(f"[TranslateServer] Load failed: {e}\n")
        sys.stderr.flush()


def generate(prompt: str, max_tokens: int = 400) -> str:
    if not _ready:
        return ""
    try:
        from mlx_lm import generate as mlx_generate
        result = mlx_generate(_model, _tokenizer, prompt=prompt,
                               max_tokens=max_tokens, verbose=False)
        return result.strip()
    except Exception as e:
        sys.stderr.write(f"[TranslateServer] Generate failed: {e}\n")
        sys.stderr.flush()
        return ""


def build_prompt(messages: list) -> str:
    if hasattr(_tokenizer, "apply_chat_template"):
        return _tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True)
    # fallback
    parts = []
    for m in messages:
        parts.append(f"{m['role']}: {m['content']}")
    return "\n".join(parts)


def translate(text: str) -> str:
    cjk = sum(1 for c in text if '一' <= c <= '鿿')
    is_chinese = cjk / max(len(text.strip()), 1) > 0.3
    if is_chinese:
        messages = [
            {"role": "system", "content":
             "You are a translator. Translate the Chinese text to natural, "
             "fluent English. Output only the translation, no explanations."},
            {"role": "user", "content": f"「{text}」"},
        ]
    else:
        messages = [{"role": "user",
                     "content": f"将以下英文翻译成简体中文"
                                 f"，只输出中文译文，不要输出英文："
                                 f"\n「{text}」"}]
    result = generate(build_prompt(messages), max_tokens=400)
    # basic validation
    result_cjk = sum(1 for c in result if '一' <= c <= '鿿')
    result_ratio = result_cjk / max(len(result), 1) if result else 0
    if is_chinese and result_ratio > 0.3:
        return ""
    if not is_chinese and result_ratio < 0.1:
        return ""
    return result


def lookup(word: str) -> str:
    prompt_text = (
        "你是英汉词典，只输出2行，不多不少。"
        "格式：\n"
        "第1行: [词性] [中文核心含义，不超过8字]\n"
        "第2行: 例: [英文短句] → [中文]\n\n"
        f"单词：「{word}」"
    )
    messages = [{"role": "user", "content": prompt_text}]
    return generate(build_prompt(messages), max_tokens=100)


def main():
    import threading
    threading.Thread(target=load_model, daemon=True).start()
    send({"status": "ready"})
    sys.stderr.write("[TranslateServer] Ready (model loading in background)\n")
    sys.stderr.flush()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        req_id = req.get("id", "")
        action = req.get("action", "")

        try:
            if action == "ping":
                send({"id": req_id, "status": "pong"})
            elif action == "translate":
                text = req.get("text", "")
                result = translate(text) if text.strip() else ""
                send({"id": req_id, "text": result, "error": None})
            elif action == "lookup":
                word = req.get("text", "")
                result = lookup(word) if word.strip() else ""
                send({"id": req_id, "text": result, "error": None})
            else:
                send({"id": req_id, "text": "", "error": f"unknown action: {action}"})
        except Exception as e:
            sys.stderr.write(f"[TranslateServer] Error: {e}\n")
            sys.stderr.flush()
            send({"id": req_id, "text": "", "error": str(e)})


if __name__ == "__main__":
    main()
