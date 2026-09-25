from __future__ import annotations

import json
import urllib.error
import urllib.request


ENDPOINT = "http://127.0.0.1:11434"
SYSTEM_PROMPT = """你是 Qwen-Image 图像模型的提示词助手。把用户的话转换成图像模型容易理解的提示词，只输出 JSON：{\"mode\": \"generate\" 或 \"edit\", \"prompt\": \"...\", \"reason\": \"一句话说明\"}。
规则：使用肯定句描述最终画面；明确空间关系、视角和主体位置；画面文字原样保留；有上一张图时默认 edit，小改用简洁编辑指令并以“其余保持不变”结尾；全新主题才使用 generate；忠于用户，不凭空增加主体或场景；输出语言与用户一致。"""


def _json_request(path: str, payload: dict | None = None, timeout: int = 10) -> dict:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        ENDPOINT + path, data=body,
        headers={"Content-Type": "application/json", "User-Agent": "Qwen-Image-Studio-Windows/1.0"},
        method="POST" if body else "GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def list_models() -> list[str]:
    try:
        return [item["name"] for item in _json_request("/api/tags").get("models", [])]
    except (OSError, urllib.error.URLError, json.JSONDecodeError, KeyError):
        return []


def rewrite(text: str, previous_prompt: str | None, model: str) -> tuple[str, str, str]:
    schema = {
        "type": "object",
        "properties": {
            "mode": {"type": "string", "enum": ["generate", "edit"]},
            "prompt": {"type": "string"},
            "reason": {"type": "string"},
        },
        "required": ["mode", "prompt", "reason"],
    }
    payload = {
        "model": model, "stream": False, "think": False, "keep_alive": "30m",
        "options": {"temperature": 0.4}, "format": schema,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"上一张图的提示词：{previous_prompt or '（无，这是第一张）'}\n\n用户的话：{text}"},
        ],
    }
    reply = _json_request("/api/chat", payload, timeout=180)
    parsed = json.loads(reply["message"]["content"])
    return parsed["mode"], parsed["prompt"], parsed["reason"]
