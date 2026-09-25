from __future__ import annotations

import os
import random
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QEvent, QObject, QSize, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QAction, QDesktopServices, QIcon, QImageReader, QKeyEvent, QPixmap
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox,
    QFileDialog, QFormLayout, QFrame, QGridLayout, QGroupBox, QHBoxLayout, QLabel,
    QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit,
    QProgressBar, QPushButton, QScrollArea, QSizePolicy, QSpinBox, QDoubleSpinBox,
    QSplitter, QStackedWidget, QStatusBar, QTabWidget, QTextEdit, QToolBar, QTreeWidget,
    QTreeWidgetItem, QVBoxLayout, QWidget,
)

from . import assistant
from .core import (
    ASPECTS, DIFFUSION_MODELS, QUALITY_PRESETS, SAFETY_NEGATIVE, SAMPLERS, SCHEDULERS, SIZE_TIERS,
    SUPPORT_MODELS, AppPaths, GenerationItem, GenerationParams, HistoryStore, ModelFile,
    Settings, build_sd_args, fit_size, import_reference, physical_memory_gb, recommended_diffusion,
    scan_models,
)
from .downloader import DownloadThread
from .engine import EngineThread


APP_STYLE = """
QWidget { background:#202124; color:#e8eaed; font-family:'Microsoft YaHei UI'; font-size:13px; }
QMainWindow, QDialog { background:#202124; }
QToolBar { background:#292a2d; border:0; border-bottom:1px solid #3c4043; spacing:8px; padding:7px; }
QToolButton, QPushButton { background:#35363a; border:1px solid #4b4d52; border-radius:8px; padding:7px 12px; }
QPushButton:hover { background:#414348; } QPushButton:pressed { background:#4b4d52; }
QPushButton#primary { background:#1a73e8; border-color:#1a73e8; font-weight:600; }
QPushButton#primary:hover { background:#2b7de9; } QPushButton:disabled { color:#73767c; background:#292a2d; }
QLineEdit, QPlainTextEdit, QTextEdit, QComboBox, QSpinBox, QDoubleSpinBox {
  background:#292a2d; border:1px solid #4b4d52; border-radius:8px; padding:7px; selection-background-color:#1a73e8;
}
QComboBox::drop-down { border:0; width:24px; }
QListWidget, QTreeWidget { background:#202124; border:0; outline:0; }
QListWidget::item { background:#292a2d; border:1px solid #3c4043; border-radius:10px; margin:5px; padding:10px; }
QListWidget::item:selected { border:2px solid #1a73e8; background:#303134; }
QTreeWidget::item { padding:6px; } QHeaderView::section { background:#292a2d; padding:7px; border:0; }
QGroupBox { border:1px solid #3c4043; border-radius:10px; margin-top:12px; padding:12px; font-weight:600; }
QGroupBox::title { subcontrol-origin:margin; left:10px; padding:0 5px; }
QProgressBar { border:0; border-radius:4px; background:#3c4043; text-align:center; height:8px; }
QProgressBar::chunk { border-radius:4px; background:#1a73e8; }
QScrollArea { border:0; } QSplitter::handle { background:#3c4043; width:1px; }
QLabel#muted { color:#9aa0a6; } QLabel#warning { color:#f9ab00; background:#3b3423; border-radius:7px; padding:8px; }
QStatusBar { background:#292a2d; border-top:1px solid #3c4043; color:#9aa0a6; }
"""


def open_path(path: Path) -> None:
    if os.name == "nt":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        QDesktopServices.openUrl(path.as_uri())


class PromptEdit(QPlainTextEdit):
    submit = Signal()

    def keyPressEvent(self, event: QKeyEvent) -> None:
        if event.key() in (Qt.Key_Return, Qt.Key_Enter) and not (event.modifiers() & Qt.ShiftModifier):
            self.submit.emit()
            return
        super().keyPressEvent(event)


class RewriteThread(QThread):
    completed = Signal(str, str, str)
    failed = Signal(str)

    def __init__(self, text: str, previous_prompt: str | None, model: str):
        super().__init__()
        self.text, self.previous_prompt, self.model = text, previous_prompt, model

    def run(self) -> None:
        try:
            self.completed.emit(*assistant.rewrite(self.text, self.previous_prompt, self.model))
        except Exception as exc:
            self.failed.emit(str(exc))


class ImageLabel(QLabel):
    def __init__(self):
        super().__init__("生成的图片会显示在这里")
        self.setAlignment(Qt.AlignCenter)
        self.setMinimumSize(420, 420)
        self.setStyleSheet("background:#171717; color:#777; border-radius:12px;")
        self._source: Path | None = None
        self._pixmap: QPixmap | None = None

    def set_image(self, path: Path | None) -> None:
        self._source = path
        self._pixmap = QPixmap(str(path)) if path and path.exists() else None
        self._refresh()

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self._refresh()

    def _refresh(self) -> None:
        if self._pixmap and not self._pixmap.isNull():
            self.setPixmap(self._pixmap.scaled(self.size() - QSize(20, 20), Qt.KeepAspectRatio, Qt.SmoothTransformation))
            self.setText("")
        else:
            self.setPixmap(QPixmap())
            self.setText("生成的图片会显示在这里")


class SettingsDialog(QDialog):
    def __init__(self, settings: Settings, paths: AppPaths, parent=None):
        super().__init__(parent)
        self.settings, self.paths = settings, paths
        self.setWindowTitle("生成设置")
        self.resize(560, 650)
        tabs = QTabWidget()
        tabs.addTab(self._generation_tab(), "生成")
        tabs.addTab(self._advanced_tab(), "高级")
        tabs.addTab(self._storage_tab(), "存储")
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Save).setText("保存")
        buttons.button(QDialogButtonBox.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(tabs)
        layout.addWidget(buttons)

    def _generation_tab(self) -> QWidget:
        page, form = QWidget(), QFormLayout()
        page.setLayout(form)
        self.custom = QCheckBox("使用自定义尺寸")
        self.custom.setChecked(self.settings.custom_size)
        size_row = QHBoxLayout()
        self.width = QSpinBox(); self.width.setRange(256, 4096); self.width.setSingleStep(32); self.width.setValue(self.settings.width)
        self.height = QSpinBox(); self.height.setRange(256, 4096); self.height.setSingleStep(32); self.height.setValue(self.settings.height)
        size_row.addWidget(self.width); size_row.addWidget(QLabel("×")); size_row.addWidget(self.height)
        self.cfg = QDoubleSpinBox(); self.cfg.setRange(0, 20); self.cfg.setSingleStep(.5); self.cfg.setValue(self.settings.cfg)
        self.sampler = QComboBox(); self.sampler.addItems(SAMPLERS); self.sampler.setCurrentText(self.settings.sampler)
        self.scheduler = QComboBox(); self.scheduler.addItems(["自动", *SCHEDULERS[1:]]); self.scheduler.setCurrentText(self.settings.scheduler or "自动")
        self.batch = QSpinBox(); self.batch.setRange(1, 8); self.batch.setValue(self.settings.batch)
        self.random_seed = QCheckBox("每次随机"); self.random_seed.setChecked(self.settings.random_seed)
        self.seed = QSpinBox(); self.seed.setRange(0, 2_147_483_647); self.seed.setValue(self.settings.seed)
        seed_row = QHBoxLayout(); seed_row.addWidget(self.random_seed); seed_row.addWidget(self.seed)
        self.negative = QPlainTextEdit(self.settings.negative); self.negative.setMaximumHeight(90)
        form.addRow(self.custom)
        form.addRow("尺寸", size_row)
        form.addRow("CFG", self.cfg)
        form.addRow("采样器", self.sampler)
        form.addRow("调度器", self.scheduler)
        form.addRow("一次生成", self.batch)
        form.addRow("Seed", seed_row)
        form.addRow("负面提示词", self.negative)
        return page

    def _advanced_tab(self) -> QWidget:
        page, layout = QWidget(), QVBoxLayout()
        page.setLayout(layout)
        self.live_preview = QCheckBox("生成过程中显示实时预览"); self.live_preview.setChecked(self.settings.live_preview)
        self.vae_tiling = QCheckBox("VAE 分块解码（高分辨率推荐）"); self.vae_tiling.setChecked(self.settings.vae_tiling)
        self.chain = QCheckBox("默认以上一张图片继续修改"); self.chain.setChecked(self.settings.chain_edits)
        self.nsfw = QCheckBox("允许成人内容（不附加安全负面提示词）"); self.nsfw.setChecked(self.settings.allow_nsfw)
        self.backend = QComboBox(); self.backend.addItems(["自动", "CUDA", "Vulkan", "CPU"]); self.backend.setCurrentText(self.settings.backend)
        self.assistant_model = QLineEdit(self.settings.assistant_model)
        for widget in (self.live_preview, self.vae_tiling, self.chain, self.nsfw):
            layout.addWidget(widget)
        form = QFormLayout(); form.addRow("推理后端", self.backend); form.addRow("Ollama 模型", self.assistant_model)
        layout.addLayout(form); layout.addStretch()
        return page

    def _storage_tab(self) -> QWidget:
        page, layout = QWidget(), QVBoxLayout()
        page.setLayout(layout)
        self.root_edit = QLineEdit(str(self.paths.root)); self.root_edit.setReadOnly(True)
        choose = QPushButton("更改工作目录…")
        choose.clicked.connect(self._choose_root)
        layout.addWidget(QLabel("模型、输出图片和历史记录都保存在这里："))
        layout.addWidget(self.root_edit)
        layout.addWidget(choose)
        layout.addStretch()
        return page

    def _choose_root(self) -> None:
        path = QFileDialog.getExistingDirectory(self, "选择工作目录", self.root_edit.text())
        if path:
            self.root_edit.setText(path)

    def _save(self) -> None:
        s = self.settings
        s.custom_size, s.width, s.height = self.custom.isChecked(), self.width.value(), self.height.value()
        s.cfg, s.sampler = self.cfg.value(), self.sampler.currentText()
        s.scheduler = "" if self.scheduler.currentText() == "自动" else self.scheduler.currentText()
        s.batch, s.random_seed, s.seed = self.batch.value(), self.random_seed.isChecked(), self.seed.value()
        s.negative = self.negative.toPlainText().strip()
        s.live_preview, s.vae_tiling, s.chain_edits = self.live_preview.isChecked(), self.vae_tiling.isChecked(), self.chain.isChecked()
        s.allow_nsfw, s.backend, s.assistant_model = self.nsfw.isChecked(), self.backend.currentText(), self.assistant_model.text().strip()
        s.root = self.root_edit.text()
        self.accept()


class ModelManagerDialog(QDialog):
    changed = Signal()

    def __init__(self, paths: AppPaths, parent=None):
        super().__init__(parent)
        self.paths = paths
        self.jobs: dict[str, DownloadThread] = {}
        self.models = [*DIFFUSION_MODELS, *SUPPORT_MODELS]
        self.setWindowTitle("模型管理")
        self.resize(820, 520)
        memory = physical_memory_gb()
        recommended = recommended_diffusion(memory)
        intro = QLabel(f"本机内存约 {memory} GB，推荐去噪模型：{recommended.label}。支持断点前的临时文件会以 .part 保存。")
        intro.setWordWrap(True)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["模型", "用途 / 建议", "状态", "进度"])
        self.tree.setColumnWidth(0, 210); self.tree.setColumnWidth(1, 300); self.tree.setColumnWidth(2, 95)
        for model in self.models:
            item = QTreeWidgetItem([model.label, model.description, "", ""])
            item.setData(0, Qt.UserRole, model.local_path)
            self.tree.addTopLevelItem(item)
        self.install = QPushButton("一键安装推荐组合")
        self.install.setObjectName("primary")
        self.install.clicked.connect(self._install_recommended)
        selected = QPushButton("下载选中项")
        selected.clicked.connect(self._install_selected)
        folder = QPushButton("打开模型文件夹")
        folder.clicked.connect(lambda: open_path(self.paths.models))
        close = QPushButton("关闭")
        close.clicked.connect(self._attempt_close)
        row = QHBoxLayout(); row.addWidget(self.install); row.addWidget(selected); row.addStretch(); row.addWidget(folder); row.addWidget(close)
        layout = QVBoxLayout(self); layout.addWidget(intro); layout.addWidget(self.tree); layout.addLayout(row)
        self._refresh()

    def _item(self, local_path: str) -> QTreeWidgetItem | None:
        for index in range(self.tree.topLevelItemCount()):
            item = self.tree.topLevelItem(index)
            if item.data(0, Qt.UserRole) == local_path:
                return item
        return None

    def _refresh(self) -> None:
        for model in self.models:
            item = self._item(model.local_path)
            if item:
                item.setText(2, "已安装" if (self.paths.models / model.local_path).exists() else "未安装")

    def _install_recommended(self) -> None:
        selected = recommended_diffusion()
        for model in [selected, *SUPPORT_MODELS]:
            self._start(model)

    def _install_selected(self) -> None:
        item = self.tree.currentItem()
        if not item:
            return
        local = item.data(0, Qt.UserRole)
        model = next(m for m in self.models if m.local_path == local)
        self._start(model)

    def _start(self, model: ModelFile) -> None:
        if (self.paths.models / model.local_path).exists() or model.local_path in self.jobs:
            return
        thread = DownloadThread(model, self.paths.models)
        self.jobs[model.local_path] = thread
        thread.progress.connect(self._progress)
        thread.completed.connect(self._done)
        thread.failed.connect(self._failed)
        item = self._item(model.local_path)
        if item:
            item.setText(2, "下载中")
        thread.start()

    def _progress(self, name: str, done: int, total: int) -> None:
        item = self._item(name)
        if item:
            if total:
                item.setText(3, f"{done / total:.0%} · {done / 1_073_741_824:.1f}/{total / 1_073_741_824:.1f} GB")
            else:
                item.setText(3, f"{done / 1_048_576:.0f} MB")

    def _done(self, name: str, _path: str) -> None:
        self.jobs.pop(name, None)
        self._refresh(); self.changed.emit()
        item = self._item(name)
        if item: item.setText(3, "完成")

    def _failed(self, name: str, message: str) -> None:
        self.jobs.pop(name, None)
        item = self._item(name)
        if item: item.setText(2, "失败"); item.setText(3, message[:70])

    def _attempt_close(self) -> None:
        if self.jobs:
            QMessageBox.information(self, "正在下载", "请等待当前模型下载完成，或关闭整个应用以取消下载。")
            return
        self.accept()

    def closeEvent(self, event) -> None:
        if self.jobs:
            QMessageBox.information(self, "正在下载", "请等待当前模型下载完成，或关闭整个应用以取消下载。")
            event.ignore(); return
        super().closeEvent(event)


class LogDialog(QDialog):
    def __init__(self, text: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("推理日志")
        self.resize(900, 560)
        editor = QPlainTextEdit(text); editor.setReadOnly(True); editor.setStyleSheet("font-family:Consolas; font-size:12px")
        copy = QPushButton("复制全部"); copy.clicked.connect(lambda: QApplication.clipboard().setText(editor.toPlainText()))
        close = QPushButton("关闭"); close.clicked.connect(self.accept)
        row = QHBoxLayout(); row.addWidget(copy); row.addStretch(); row.addWidget(close)
        layout = QVBoxLayout(self); layout.addWidget(editor); layout.addLayout(row)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        bootstrap = AppPaths.default()
        bootstrap.ensure()
        probe = Settings.load(bootstrap.settings)
        self.paths = AppPaths(Path(probe.root)) if probe.root else bootstrap
        self.paths.ensure()
        self._install_bundled_engine()
        self.settings_data = Settings.load(self.paths.settings)
        if not self.settings_data.root:
            self.settings_data.root = str(self.paths.root)
        self.history = HistoryStore(self.paths.history)
        self.items = self.history.load()
        self.model_state = scan_models(self.paths)
        self.references: list[str] = []
        self.selected_item: GenerationItem | None = None
        self.engine_thread: EngineThread | None = None
        self.rewrite_thread: RewriteThread | None = None
        self.running_item: GenerationItem | None = None
        self.log_lines: list[str] = []
        self._last_preview = 0.0
        self.setWindowTitle("Qwen Image Studio · Windows")
        self.setMinimumSize(1120, 720)
        self.resize(1380, 880)
        self.setStyleSheet(APP_STYLE)
        icon = Path(__file__).resolve().parent.parent / "assets" / "icon.png"
        if icon.exists(): self.setWindowIcon(QIcon(str(icon)))
        self._build_toolbar()
        self._build_ui()
        self.setStatusBar(QStatusBar())
        self._refresh_models()
        self._refresh_history()
        self._select_latest()

    def _install_bundled_engine(self) -> None:
        """Copy a packaged engine into the writable workspace on first launch."""
        bundle_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
        candidates = [bundle_root / "bin", Path(sys.executable).resolve().parent / "bin"]
        bundled = next((folder for folder in candidates if (folder / "sd-cli.exe").exists()), None)
        if self.paths.engine.exists() or bundled is None:
            return
        shutil.copytree(bundled, self.paths.bin, dirs_exist_ok=True)

    def _build_toolbar(self) -> None:
        bar = QToolBar(); bar.setMovable(False); self.addToolBar(bar)
        title = QLabel("<b style='font-size:16px'>Qwen Image Studio</b><br><span style='color:#9aa0a6'>Qwen-Image-2.1 · Windows 本地版</span>")
        bar.addWidget(title)
        spacer = QWidget(); spacer.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred); bar.addWidget(spacer)
        for text, callback in (("模型", self.show_models), ("输出文件夹", lambda: open_path(self.paths.outputs)), ("设置", self.show_settings)):
            action = QAction(text, self); action.triggered.connect(callback); bar.addAction(action)

    def _build_ui(self) -> None:
        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(self._left_panel())
        splitter.addWidget(self._right_panel())
        splitter.setSizes([600, 780])
        splitter.setCollapsible(0, False); splitter.setCollapsible(1, False)
        self.setCentralWidget(splitter)

    def _left_panel(self) -> QWidget:
        panel, layout = QWidget(), QVBoxLayout()
        panel.setLayout(layout); panel.setMinimumWidth(530)
        self.problem = QLabel(); self.problem.setObjectName("warning"); self.problem.setWordWrap(True); self.problem.hide()
        self.history_list = QListWidget(); self.history_list.setSpacing(2); self.history_list.setIconSize(QSize(110, 110)); self.history_list.currentItemChanged.connect(self._history_selected)
        layout.addWidget(self.problem); layout.addWidget(self.history_list, 1)
        box = QFrame(); box.setStyleSheet("QFrame{background:#292a2d;border:1px solid #3c4043;border-radius:14px;}")
        composer = QVBoxLayout(box)
        self.chain_label = QLabel("基于右侧图片接着修改"); self.chain_label.setObjectName("muted")
        self.prompt = PromptEdit(); self.prompt.setPlaceholderText("描述你想生成的画面…（Enter 生成，Shift+Enter 换行）"); self.prompt.setMaximumHeight(120); self.prompt.submit.connect(self.send)
        composer.addWidget(self.chain_label); composer.addWidget(self.prompt)
        self.refs_list = QListWidget(); self.refs_list.setViewMode(QListWidget.IconMode); self.refs_list.setFlow(QListWidget.LeftToRight); self.refs_list.setMaximumHeight(76); self.refs_list.setIconSize(QSize(54, 54)); self.refs_list.hide(); composer.addWidget(self.refs_list)
        controls = QHBoxLayout()
        add_ref = QPushButton("＋ 参考图"); add_ref.clicked.connect(self.add_references)
        self.model_combo = QComboBox(); self.model_combo.setMinimumWidth(105)
        self.aspect_combo = QComboBox(); self.aspect_combo.addItems(ASPECTS); self.aspect_combo.setCurrentText(self.settings_data.aspect)
        self.tier_combo = QComboBox(); self.tier_combo.addItems(["草稿", "标准", "2K 高清"]); self.tier_combo.setCurrentText(self.settings_data.size_tier)
        self.quality_combo = QComboBox(); self.quality_combo.addItems(QUALITY_PRESETS); self.quality_combo.setCurrentText(next((k for k, v in QUALITY_PRESETS.items() if v == self.settings_data.steps), "标准"))
        self.assistant_check = QCheckBox("助手"); self.assistant_check.setChecked(self.settings_data.assistant)
        self.transparent_check = QCheckBox("透明"); self.transparent_check.setChecked(self.settings_data.transparent)
        self.send_button = QPushButton("生成 ↑"); self.send_button.setObjectName("primary"); self.send_button.clicked.connect(self.send)
        for widget in (add_ref, self.model_combo, self.aspect_combo, self.tier_combo, self.quality_combo, self.assistant_check, self.transparent_check): controls.addWidget(widget)
        controls.addStretch(); controls.addWidget(self.send_button)
        composer.addLayout(controls)
        self.progress = QProgressBar(); self.progress.setRange(0, 100); self.progress.hide(); composer.addWidget(self.progress)
        self.stage = QLabel(); self.stage.setObjectName("muted"); self.stage.hide(); composer.addWidget(self.stage)
        layout.addWidget(box)
        return panel

    def _right_panel(self) -> QWidget:
        panel, layout = QWidget(), QVBoxLayout()
        panel.setLayout(layout)
        self.image = ImageLabel(); layout.addWidget(self.image, 1)
        self.meta = QLabel("选择一条历史记录查看详情"); self.meta.setWordWrap(True)
        self.meta.setStyleSheet("font-size:14px; padding:8px")
        self.note = QLabel(); self.note.setObjectName("muted"); self.note.setWordWrap(True)
        actions = QHBoxLayout()
        for text, callback in (("复制图片", self.copy_image), ("另存为…", self.save_image), ("用作参考图", self.use_selected_as_reference), ("打开位置", self.reveal_image), ("查看日志", self.show_log)):
            button = QPushButton(text); button.clicked.connect(callback); actions.addWidget(button)
        actions.addStretch()
        layout.addWidget(self.meta); layout.addWidget(self.note); layout.addLayout(actions)
        return panel

    def _refresh_models(self) -> None:
        self.model_state = scan_models(self.paths)
        models = list(self.model_state["diffusion"] or [])
        selected = self.settings_data.diffusion_model
        self.model_combo.blockSignals(True); self.model_combo.clear(); self.model_combo.addItems(models or ["未安装模型"])
        if selected in models: self.model_combo.setCurrentText(selected)
        self.model_combo.blockSignals(False)
        problems = []
        if not self.paths.engine.exists(): problems.append("缺少推理引擎 sd-cli.exe")
        if not models: problems.append("缺少去噪模型")
        if not self.model_state["encoder"]: problems.append("缺少文本编码器")
        if not self.model_state["vae"]: problems.append("缺少 VAE")
        if problems:
            self.problem.setText("尚未就绪：" + "、".join(problems) + "。点击右上角“模型”，并按 README 构建或放入推理引擎。")
            self.problem.show()
        else:
            self.problem.hide()

    def _refresh_history(self) -> None:
        selected_id = self.selected_item.id if self.selected_item else None
        self.history_list.clear()
        status_text = {"queued":"排队中", "thinking":"助手改写中", "running":"生成中", "done":"完成", "failed":"失败", "cancelled":"已取消"}
        for item in reversed(self.items):
            prompt = item.params.user_text or item.params.prompt
            info = f"{status_text.get(item.status,item.status)} · {item.params.width}×{item.params.height} · {item.params.steps}步 · seed {item.params.seed}"
            row = QListWidgetItem(f"{prompt}\n{info}")
            row.setData(Qt.UserRole, item.id)
            if item.outputs:
                path = self.paths.outputs / item.outputs[0]
                if path.exists(): row.setIcon(QIcon(str(path)))
            self.history_list.addItem(row)
            if item.id == selected_id: self.history_list.setCurrentItem(row)

    def _select_latest(self) -> None:
        if self.items:
            self.selected_item = next((i for i in reversed(self.items) if i.outputs), self.items[-1])
            for index in range(self.history_list.count()):
                row = self.history_list.item(index)
                if row.data(Qt.UserRole) == self.selected_item.id: self.history_list.setCurrentItem(row); break
        else:
            self._show_item(None)

    def _history_selected(self, current: QListWidgetItem | None, _previous: QListWidgetItem | None) -> None:
        if not current: return
        item_id = current.data(Qt.UserRole)
        self.selected_item = next((item for item in self.items if item.id == item_id), None)
        self._show_item(self.selected_item)

    def _show_item(self, item: GenerationItem | None) -> None:
        path = self.paths.outputs / item.outputs[0] if item and item.outputs else None
        self.image.set_image(path)
        if not item:
            self.meta.setText("选择一条历史记录查看详情"); self.note.clear(); return
        p = item.params
        prompt = p.user_text or p.prompt
        duration = f" · 用时 {int(item.duration)} 秒" if item.duration else ""
        self.meta.setText(f"{prompt}\n{p.width}×{p.height} · {p.steps}步 · CFG {p.cfg:g} · {p.sampler} · seed {p.seed}{duration}")
        self.note.setText(item.assistant_note or item.error or "")
        self.chain_label.setText("基于右侧图片接着修改" if item.outputs and self.settings_data.chain_edits else "生成一张新图片")

    def add_references(self) -> None:
        files, _ = QFileDialog.getOpenFileNames(self, "选择参考图（最多 10 张）", "", "图片 (*.png *.jpg *.jpeg *.webp *.bmp)")
        for filename in files[: max(0, 10 - len(self.references))]:
            try: self.references.append(import_reference(Path(filename), self.paths))
            except OSError as exc: QMessageBox.warning(self, "无法添加", str(exc))
        self._refresh_refs()

    def _refresh_refs(self) -> None:
        self.refs_list.clear()
        for rel in self.references:
            item = QListWidgetItem(QIcon(str(self.paths.outputs / rel)), Path(rel).name); item.setData(Qt.UserRole, rel); self.refs_list.addItem(item)
        self.refs_list.setVisible(bool(self.references))

    def _make_params(self, text: str) -> GenerationParams:
        self.settings_data.aspect, self.settings_data.size_tier = self.aspect_combo.currentText(), self.tier_combo.currentText()
        self.settings_data.steps = QUALITY_PRESETS[self.quality_combo.currentText()]
        self.settings_data.transparent = self.transparent_check.isChecked()
        model = self.model_combo.currentText()
        if model != "未安装模型": self.settings_data.diffusion_model = model
        width, height = self.settings_data.target_size()
        refs = list(self.references)
        if self.settings_data.chain_edits and self.selected_item and self.selected_item.outputs:
            current = self.selected_item.outputs[0]
            if current not in refs: refs.insert(0, current)
        if self.settings_data.follow_reference_size and refs and not self.settings_data.custom_size:
            size = QImageReader(str(self.paths.outputs / refs[0])).size()
            if size.isValid() and size.height() > 0:
                width, height = fit_size(size.width() / size.height(), SIZE_TIERS[self.settings_data.size_tier])
        negative = self.settings_data.negative
        if not self.settings_data.allow_nsfw:
            negative = f"{negative}, {SAFETY_NEGATIVE}" if negative else SAFETY_NEGATIVE
        encoders = list(self.model_state["encoder"] or [])
        encoder = self.settings_data.text_encoder if self.settings_data.text_encoder in encoders else (encoders[0] if encoders else self.settings_data.text_encoder)
        return GenerationParams(
            prompt=text, user_text=text if self.assistant_check.isChecked() else None,
            negative=negative, width=width, height=height, steps=self.settings_data.steps,
            cfg=self.settings_data.cfg, seed=random.randint(0, 2_147_483_647) if self.settings_data.random_seed else self.settings_data.seed,
            sampler=self.settings_data.sampler, scheduler=self.settings_data.scheduler,
            batch=self.settings_data.batch, diffusion_model=self.settings_data.diffusion_model,
            text_encoder=encoder, refs=refs[:10], easy_cache=self.settings_data.easy_cache,
            transparent=self.settings_data.transparent,
        )

    def send(self) -> None:
        text = self.prompt.toPlainText().strip()
        if not text: return
        self._refresh_models()
        if self.problem.isVisible():
            QMessageBox.warning(self, "尚未就绪", self.problem.text()); return
        self.settings_data.assistant = self.assistant_check.isChecked()
        item = GenerationItem(params=self._make_params(text))
        self.items.append(item); self.selected_item = item
        self.prompt.clear(); self.references.clear(); self._refresh_refs(); self._save_and_refresh(); self.start_next()

    def start_next(self) -> None:
        if self.engine_thread or self.rewrite_thread: return
        item = next((i for i in self.items if i.status == "queued"), None)
        if not item: self._set_running_ui(False); return
        self.running_item = item
        if item.params.user_text and self.assistant_check.isChecked():
            item.status = "thinking"; self._save_and_refresh(); self._set_running_ui(True, "助手正在理解提示词…")
            previous = None
            if item.params.refs:
                previous_item = next((i for i in self.items if item.params.refs[0] in i.outputs), None)
                previous = previous_item.params.prompt if previous_item else None
            self.rewrite_thread = RewriteThread(item.params.user_text, previous, self.settings_data.assistant_model)
            self.rewrite_thread.completed.connect(self._rewrite_done)
            self.rewrite_thread.failed.connect(self._rewrite_failed)
            self.rewrite_thread.finished.connect(self._rewrite_finished)
            self.rewrite_thread.start(); return
        self._run_item(item)

    def _rewrite_done(self, mode: str, prompt: str, reason: str) -> None:
        if not self.running_item: return
        self.running_item.params.prompt = prompt; self.running_item.assistant_note = f"助手：{reason}"
        if mode == "generate" and self.running_item.params.refs:
            previous_outputs = {output for item in self.items if item.id != self.running_item.id for output in item.outputs}
            if self.running_item.params.refs[0] in previous_outputs:
                self.running_item.params.refs.pop(0)
        self.running_item.status = "queued"

    def _rewrite_failed(self, message: str) -> None:
        if self.running_item:
            self.running_item.assistant_note = f"助手不可用，已按原话生成：{message}"
            self.running_item.status = "queued"

    def _rewrite_finished(self) -> None:
        item = self.running_item; self.rewrite_thread = None
        if item: self._run_item(item)

    def _run_item(self, item: GenerationItem) -> None:
        item.status = "running"; self.log_lines.clear(); self._save_and_refresh(); self._set_running_ui(True, "准备中")
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S") + "_" + item.id[:4]
        output = self.paths.outputs / (f"{stamp}_%d.png" if item.params.batch > 1 else f"{stamp}.png")
        preview = self.paths.previews / f"{item.id}.png" if self.settings_data.live_preview else None
        if preview: preview.unlink(missing_ok=True)
        args = build_sd_args(item.params, self.paths, self.model_state, output, preview, self.settings_data)
        self.engine_thread = EngineThread(self.paths.engine, args, self.paths.root, preview)
        self.engine_thread.line.connect(self._log)
        self.engine_thread.progress.connect(self._engine_progress)
        self.engine_thread.preview_changed.connect(lambda p: self.image.set_image(Path(p)))
        self.engine_thread.completed.connect(lambda code, duration, cancelled: self._engine_done(item, stamp, preview, code, duration, cancelled))
        self.engine_thread.start()

    def _log(self, line: str) -> None:
        self.log_lines.append(line)
        self.log_lines = self.log_lines[-500:]

    def _engine_progress(self, stage: str, step: int, total: int, seconds: float, image_index: int, image_count: int) -> None:
        if total:
            fraction = ((image_index - 1) + step / total) / max(1, image_count)
            self.progress.setValue(round(fraction * 100))
            eta = int(((total - step) + (image_count - image_index) * total) * seconds) if seconds else 0
            self.stage.setText(f"{stage} · {step}/{total}" + (f" · 约剩 {eta // 60}分{eta % 60}秒" if eta else ""))
        else:
            self.stage.setText(stage)

    def _engine_done(self, item: GenerationItem, prefix: str, preview: Path | None, code: int, duration: float, cancelled: bool) -> None:
        outputs = sorted(self.paths.outputs.glob(prefix + "*.png"))
        item.outputs = [path.relative_to(self.paths.outputs).as_posix() for path in outputs]
        item.duration = duration
        if cancelled: item.status = "cancelled"
        elif code == 0 and outputs: item.status = "done"
        else:
            item.status = "failed"
            errors = [line for line in self.log_lines if any(word in line.lower() for word in ("error", "failed", "exception"))]
            item.error = (errors[-1] if errors else (self.log_lines[-1] if self.log_lines else f"sd-cli.exe 退出码 {code}"))[:500]
        if preview: preview.unlink(missing_ok=True)
        self.engine_thread = None; self.running_item = None
        self.selected_item = item; self._save_and_refresh(); self._show_item(item); self._set_running_ui(False)
        if item.status == "done" and QApplication.applicationState() != Qt.ApplicationActive:
            QApplication.alert(self, 5000)
        QTimer.singleShot(0, self.start_next)

    def cancel(self) -> None:
        if self.engine_thread: self.engine_thread.cancel()

    def _set_running_ui(self, running: bool, text: str = "") -> None:
        self.progress.setVisible(running); self.stage.setVisible(running)
        if running: self.stage.setText(text); self.send_button.setText("停止"); self.send_button.clicked.disconnect(); self.send_button.clicked.connect(self.cancel)
        else:
            self.progress.setValue(0); self.send_button.setText("生成 ↑")
            try: self.send_button.clicked.disconnect()
            except RuntimeError: pass
            self.send_button.clicked.connect(self.send)

    def _save_and_refresh(self) -> None:
        self.history.save(self.items); self.settings_data.save(self.paths.settings); self._refresh_history()

    def show_models(self) -> None:
        dialog = ModelManagerDialog(self.paths, self); dialog.changed.connect(self._refresh_models); dialog.exec(); self._refresh_models()

    def show_settings(self) -> None:
        old_root = self.paths.root
        dialog = SettingsDialog(self.settings_data, self.paths, self)
        if dialog.exec() != QDialog.Accepted: return
        new_root = Path(self.settings_data.root)
        if new_root != old_root:
            self.paths = AppPaths(new_root); self.paths.ensure(); self.paths.remember(); self._install_bundled_engine(); self.history = HistoryStore(self.paths.history); self.items = self.history.load(); self.selected_item = None
        self.settings_data.save(self.paths.settings); self._refresh_models(); self._refresh_history(); self._select_latest()

    def selected_output(self) -> Path | None:
        if self.selected_item and self.selected_item.outputs:
            path = self.paths.outputs / self.selected_item.outputs[0]
            return path if path.exists() else None
        return None

    def copy_image(self) -> None:
        path = self.selected_output()
        if path: QApplication.clipboard().setPixmap(QPixmap(str(path)))

    def save_image(self) -> None:
        path = self.selected_output()
        if not path: return
        target, _ = QFileDialog.getSaveFileName(self, "另存为", path.name, "PNG 图片 (*.png)")
        if target:
            try: shutil.copy2(path, target)
            except OSError as exc: QMessageBox.warning(self, "保存失败", str(exc))

    def use_selected_as_reference(self) -> None:
        path = self.selected_output()
        if path and self.selected_item:
            rel = self.selected_item.outputs[0]
            if rel not in self.references and len(self.references) < 10: self.references.append(rel); self._refresh_refs()

    def reveal_image(self) -> None:
        path = self.selected_output()
        if path: subprocess.Popen(["explorer", "/select,", str(path)])

    def show_log(self) -> None:
        LogDialog("\n".join(self.log_lines) or "暂无本次运行日志。", self).exec()

    def closeEvent(self, event) -> None:
        if self.engine_thread:
            answer = QMessageBox.question(self, "正在生成", "退出会停止当前生成，确定退出吗？")
            if answer != QMessageBox.Yes: event.ignore(); return
            self.engine_thread.cancel(); self.engine_thread.wait(4000)
        self._save_and_refresh(); event.accept()
