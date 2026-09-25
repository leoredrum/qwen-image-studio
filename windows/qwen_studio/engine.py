from __future__ import annotations

import os
import re
import signal
import subprocess
import time
from pathlib import Path

from PySide6.QtCore import QThread, Signal


STEP_RE = re.compile(r"\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s)")
IMAGE_RE = re.compile(r"generating image:\s*(\d+)/(\d+)", re.IGNORECASE)


class EngineThread(QThread):
    line = Signal(str)
    progress = Signal(str, int, int, float, int, int)
    preview_changed = Signal(str)
    completed = Signal(int, float, bool)

    def __init__(self, executable: Path, args: list[str], cwd: Path, preview: Path | None = None):
        super().__init__()
        self.executable = executable
        self.args = args
        self.cwd = cwd
        self.preview = preview
        self._process: subprocess.Popen[bytes] | None = None
        self._cancelled = False
        self._preview_stamp = 0.0

    def cancel(self) -> None:
        self._cancelled = True
        process = self._process
        if process is None or process.poll() is not None:
            return
        try:
            if os.name == "nt":
                process.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                process.terminate()
            process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()

    def _parse(self, text: str) -> None:
        text = text.replace("\x1b[K", "").strip()
        if not text:
            return
        self.line.emit(text)
        stage, step, total, seconds, image_index, image_count = "准备中", 0, 0, 0.0, 1, 1
        match = STEP_RE.search(text)
        if match:
            step, total = int(match.group(1)), int(match.group(2))
            value = float(match.group(3))
            seconds = value if match.group(4) == "s/it" else (1 / value if value else 0)
            stage = "绘制中"
        else:
            image = IMAGE_RE.search(text)
            if image:
                image_index, image_count = int(image.group(1)), int(image.group(2))
                stage = "绘制中"
            elif "get_learned_condition" in text or "qwen3vl build" in text:
                stage = "理解提示词"
            elif "decoding" in text.lower():
                stage = "解码图像"
            elif "loading tensors" in text.lower():
                stage = "加载模型"
            else:
                return
        self.progress.emit(stage, step, total, seconds, image_index, image_count)
        if self.preview and self.preview.exists():
            try:
                stamp = self.preview.stat().st_mtime
                if stamp != self._preview_stamp:
                    self._preview_stamp = stamp
                    self.preview_changed.emit(str(self.preview))
            except OSError:
                pass

    def run(self) -> None:
        started = time.monotonic()
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # 非 Windows 上为 0，便于在其他系统上测试
        if os.name == "nt":
            flags |= subprocess.CREATE_NEW_PROCESS_GROUP
        try:
            self._process = subprocess.Popen(
                [str(self.executable), *self.args],
                cwd=str(self.cwd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, creationflags=flags,
            )
            pending = bytearray()
            assert self._process.stdout is not None
            while True:
                chunk = self._process.stdout.read(1)
                if not chunk:
                    break
                if chunk in (b"\r", b"\n"):
                    if pending:
                        self._parse(pending.decode("utf-8", errors="replace"))
                        pending.clear()
                else:
                    pending.extend(chunk)
            if pending:
                self._parse(pending.decode("utf-8", errors="replace"))
            code = self._process.wait()
        except OSError as exc:
            self.line.emit(f"[ERROR] 无法启动 sd-cli.exe：{exc}")
            code = -1
        self.completed.emit(code, time.monotonic() - started, self._cancelled)

