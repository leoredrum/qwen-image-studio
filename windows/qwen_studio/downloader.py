from __future__ import annotations

import os
import urllib.request
from pathlib import Path

from PySide6.QtCore import QThread, Signal

from .core import ModelFile


class DownloadThread(QThread):
    progress = Signal(str, int, int)
    completed = Signal(str, str)
    failed = Signal(str, str)

    def __init__(self, model: ModelFile, models_dir: Path):
        super().__init__()
        self.model = model
        self.destination = models_dir / model.local_path
        self._cancelled = False

    def cancel(self) -> None:
        self._cancelled = True

    def run(self) -> None:
        temp = self.destination.with_suffix(self.destination.suffix + ".part")
        self.destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            request = urllib.request.Request(self.model.url, headers={"User-Agent": "Qwen-Image-Studio-Windows/1.0"})
            with urllib.request.urlopen(request, timeout=60) as response, temp.open("wb") as handle:
                total = int(response.headers.get("Content-Length", "0"))
                done = 0
                while not self._cancelled:
                    block = response.read(4 * 1024 * 1024)
                    if not block:
                        break
                    handle.write(block)
                    done += len(block)
                    self.progress.emit(self.model.local_path, done, total)
            if self._cancelled:
                temp.unlink(missing_ok=True)
                self.failed.emit(self.model.local_path, "已取消")
                return
            os.replace(temp, self.destination)
            self.completed.emit(self.model.local_path, str(self.destination))
        except Exception as exc:
            temp.unlink(missing_ok=True)
            self.failed.emit(self.model.local_path, str(exc))

