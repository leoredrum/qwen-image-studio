from __future__ import annotations

import base64
import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

from .core import parse_pe_answer


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


# --------------------------------------------------------------------------- #
# 官方提示词改写模型（Qwen-Image-2.1-PE，社区 GGUF 版，经 Ollama 运行）
# --------------------------------------------------------------------------- #

PE_MODELS = {
    "t2i": "hf.co/prithivMLmods/Qwen-Image-2.1-PE-T2I-GGUF:Q4_K_M",
    "edit": "hf.co/prithivMLmods/Qwen-Image-2.1-PE-I2I-GGUF:Q4_K_M",
}
PE_PROMPT_URL = "https://raw.githubusercontent.com/QwenLM/Qwen-Image-2.1/main/prompt_rewrite/prompts/{}"


def pe_installed(models: list[str] | None = None) -> bool:
    models = list_models() if models is None else models
    return all(name in models for name in PE_MODELS.values())


def pe_system_prompt(task: str, cache_dir: Path) -> str:
    """官方 system prompt（Qwen Research License），首次使用时从官方仓库下载并缓存。"""
    name = "system_prompt_t2i.txt" if task == "t2i" else "system_prompt_edit.txt"
    local = cache_dir / name
    try:
        text = local.read_text(encoding="utf-8")
        if text.strip():
            return text
    except OSError:
        pass
    request = urllib.request.Request(PE_PROMPT_URL.format(name), headers={"User-Agent": "Qwen-Image-Studio-Windows"})
    with urllib.request.urlopen(request, timeout=30) as response:
        text = response.read().decode("utf-8")
    cache_dir.mkdir(parents=True, exist_ok=True)
    local.write_text(text, encoding="utf-8")
    return text


def encode_image(path: Path) -> str | None:
    """按训练时的上限缩到 1MP 以内，转 JPEG 后 base64。"""
    from PySide6.QtCore import QBuffer, QByteArray, QIODevice, Qt
    from PySide6.QtGui import QImage

    image = QImage(str(path))
    if image.isNull():
        return None
    pixels = image.width() * image.height()
    if pixels > 1_048_576:
        scale = (1_048_576 / pixels) ** 0.5
        image = image.scaled(int(image.width() * scale), int(image.height() * scale), Qt.KeepAspectRatio, Qt.SmoothTransformation)
    data = QByteArray()
    buffer = QBuffer(data)
    buffer.open(QIODevice.WriteOnly)
    image.convertToFormat(QImage.Format_RGB888).save(buffer, "JPEG", 92)
    return base64.b64encode(bytes(data)).decode("ascii")


def rewrite_official(task: str, text: str, images: list[Path], cache_dir: Path) -> dict:
    """按官方参数调用：开启思考，temperature 1.0，top_p 0.95；图片放在文字前面。"""
    system = pe_system_prompt(task, cache_dir)
    user: dict = {"role": "user", "content": text}
    if task == "edit":
        user["images"] = [b for b in (encode_image(p) for p in images) if b]
    options = {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "num_ctx": 16384, "num_predict": 8192}
    if task == "t2i":
        options["presence_penalty"] = 1.5
    payload = {
        "model": PE_MODELS[task], "stream": False, "think": True, "keep_alive": "30m",
        "options": options, "messages": [{"role": "system", "content": system}, user],
    }
    started = time.monotonic()
    reply = _json_request("/api/chat", payload, timeout=600)
    parsed = parse_pe_answer(reply.get("message", {}).get("content", ""))
    if not parsed:
        raise ValueError("官方改写模型没有返回有效结果")
    parsed["seconds"] = time.monotonic() - started
    return parsed


def pull(name: str, progress: Callable[[float, str], None]) -> None:
    """通过 Ollama 下载模型，流式回报进度。"""
    request = urllib.request.Request(
        ENDPOINT + "/api/pull", data=json.dumps({"model": name, "stream": True}).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=3600) as response:
        for raw in response:
            try:
                obj = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                continue
            if obj.get("error"):
                raise RuntimeError(obj["error"])
            total, done = obj.get("total") or 0, obj.get("completed") or 0
            progress(done / total if total else 0.0, obj.get("status", ""))
