from __future__ import annotations

import ctypes
import json
import os
import shutil
import uuid
from dataclasses import asdict, dataclass, field, fields
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ASPECTS: dict[str, tuple[int, int]] = {
    "1:1": (1, 1),
    "4:3": (4, 3),
    "3:4": (3, 4),
    "3:2": (3, 2),
    "2:3": (2, 3),
    "16:9": (16, 9),
    "9:16": (9, 16),
}

SIZE_TIERS = {
    "草稿": 0.59,
    "标准": 1.05,
    "2K 高清": 4.2,
}

PRESET_SIZES: dict[str, dict[str, tuple[int, int]]] = {
    "草稿": {
        "1:1": (768, 768), "4:3": (896, 672), "3:4": (672, 896),
        "3:2": (960, 640), "2:3": (640, 960), "16:9": (1024, 576), "9:16": (576, 1024),
    },
    "标准": {
        "1:1": (1024, 1024), "4:3": (1152, 864), "3:4": (864, 1152),
        "3:2": (1248, 832), "2:3": (832, 1248), "16:9": (1536, 864), "9:16": (864, 1536),
    },
    "2K 高清": {
        "1:1": (2048, 2048), "4:3": (2400, 1792), "3:4": (1792, 2400),
        "3:2": (2528, 1696), "2:3": (1696, 2528), "16:9": (2752, 1536), "9:16": (1536, 2752),
    },
}

QUALITY_PRESETS = {"草稿": 12, "标准": 20, "精细": 30, "极致": 40}
SAMPLERS = ["euler", "euler_a", "heun", "dpm2", "dpm++2m", "dpm++2mv2", "dpm++2s_a", "ipndm", "res_multistep", "er_sde", "lcm"]
SCHEDULERS = ["", "simple", "discrete", "karras", "exponential", "sgm_uniform", "beta", "smoothstep", "kl_optimal"]
SAFETY_NEGATIVE = "nsfw, nude, naked, nudity, nipples, genitals, explicit, sexual, porn, erotic, lingerie, gore, blood"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def fit_size(aspect: float, megapixels: float) -> tuple[int, int]:
    height = ((megapixels * 1_000_000) / aspect) ** 0.5
    width = height * aspect
    round32 = lambda value: max(256, round(value / 32) * 32)
    return round32(width), round32(height)


def preset_size(aspect: str, tier: str) -> tuple[int, int]:
    return PRESET_SIZES.get(tier, PRESET_SIZES["标准"]).get(aspect, (1024, 1024))


def physical_memory_gb() -> int:
    class MemoryStatus(ctypes.Structure):
        _fields_ = [
            ("length", ctypes.c_ulong), ("memory_load", ctypes.c_ulong),
            ("total_phys", ctypes.c_ulonglong), ("avail_phys", ctypes.c_ulonglong),
            ("total_page_file", ctypes.c_ulonglong), ("avail_page_file", ctypes.c_ulonglong),
            ("total_virtual", ctypes.c_ulonglong), ("avail_virtual", ctypes.c_ulonglong),
            ("avail_extended_virtual", ctypes.c_ulonglong),
        ]

    status = MemoryStatus()
    status.length = ctypes.sizeof(status)
    if os.name == "nt" and ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        return max(1, round(status.total_phys / 1_073_741_824))
    return 16


@dataclass(slots=True)
class AppPaths:
    root: Path

    @property
    def models(self) -> Path:
        return self.root / "models"

    @property
    def outputs(self) -> Path:
        return self.root / "outputs"

    @property
    def refs(self) -> Path:
        return self.outputs / "refs"

    @property
    def previews(self) -> Path:
        return self.outputs / ".preview"

    @property
    def bin(self) -> Path:
        return self.root / "bin"

    @property
    def engine(self) -> Path:
        return self.bin / "sd-cli.exe"

    @property
    def history(self) -> Path:
        return self.outputs / "history.json"

    @property
    def settings(self) -> Path:
        return self.root / "settings.json"

    def ensure(self) -> None:
        for path in (self.root, self.models, self.outputs, self.refs, self.previews, self.bin):
            path.mkdir(parents=True, exist_ok=True)

    @classmethod
    def default(cls) -> "AppPaths":
        pointer = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "Qwen Image Studio" / "workspace.json"
        try:
            remembered = Path(json.loads(pointer.read_text(encoding="utf-8"))["root"])
            if remembered.is_absolute():
                return cls(remembered)
        except (OSError, json.JSONDecodeError, KeyError, TypeError):
            pass
        docs = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Documents"
        legacy = docs / "Qwen image"
        return cls(legacy if (legacy / "models").exists() else docs / "Qwen Image Studio")

    def remember(self) -> None:
        pointer = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "Qwen Image Studio" / "workspace.json"
        pointer.parent.mkdir(parents=True, exist_ok=True)
        pointer.write_text(json.dumps({"root": str(self.root)}, ensure_ascii=False, indent=2), encoding="utf-8")


@dataclass(slots=True)
class Settings:
    root: str = ""
    diffusion_model: str = "qwen-image-2.1-Q4_K_M.gguf"
    text_encoder: str = "Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf"
    aspect: str = "1:1"
    size_tier: str = "标准"
    custom_size: bool = False
    width: int = 1024
    height: int = 1024
    follow_reference_size: bool = True
    steps: int = 20
    cfg: float = 6.0
    sampler: str = "euler"
    scheduler: str = ""
    random_seed: bool = True
    seed: int = 42
    batch: int = 1
    negative: str = ""
    allow_nsfw: bool = False
    easy_cache: bool = False
    live_preview: bool = True
    vae_tiling: bool = False
    chain_edits: bool = True
    assistant: bool = True
    assistant_model: str = "qwen3.5:9b"
    transparent: bool = False
    backend: str = "自动"

    @classmethod
    def load(cls, path: Path) -> "Settings":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            valid = {f.name for f in fields(cls)}
            return cls(**{k: v for k, v in raw.items() if k in valid})
        except (OSError, json.JSONDecodeError, TypeError):
            return cls()

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), ensure_ascii=False, indent=2), encoding="utf-8")

    def target_size(self) -> tuple[int, int]:
        if self.custom_size:
            return max(256, self.width // 32 * 32), max(256, self.height // 32 * 32)
        return preset_size(self.aspect, self.size_tier)


@dataclass(slots=True)
class GenerationParams:
    prompt: str
    negative: str
    width: int
    height: int
    steps: int
    cfg: float
    seed: int
    sampler: str
    scheduler: str
    batch: int
    diffusion_model: str
    text_encoder: str
    refs: list[str] = field(default_factory=list)
    easy_cache: bool = False
    transparent: bool = False
    user_text: str | None = None


@dataclass(slots=True)
class GenerationItem:
    params: GenerationParams
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    created_at: str = field(default_factory=utc_now)
    outputs: list[str] = field(default_factory=list)
    status: str = "queued"
    error: str | None = None
    duration: float | None = None
    assistant_note: str | None = None

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        return value

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "GenerationItem":
        params = GenerationParams(**raw.pop("params"))
        valid = {f.name for f in fields(cls)}
        item = cls(params=params, **{k: v for k, v in raw.items() if k in valid and k != "params"})
        if item.status in {"queued", "running", "thinking"}:
            item.status = "cancelled"
        return item


class HistoryStore:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> list[GenerationItem]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            return [GenerationItem.from_dict(dict(item)) for item in raw]
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            return []

    def save(self, items: list[GenerationItem]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps([i.to_dict() for i in items], ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(self.path)


@dataclass(frozen=True, slots=True)
class ModelFile:
    label: str
    repo: str
    remote_path: str
    local_path: str
    description: str
    kind: str

    @property
    def url(self) -> str:
        from urllib.parse import quote
        return f"https://huggingface.co/{self.repo}/resolve/main/{quote(self.remote_path)}?download=true"


DIFFUSION_MODELS = [
    ModelFile("Q3_K_M", "unsloth/Qwen-Image-2.1-GGUF", "qwen-image-2.1-Q3_K_M.gguf", "qwen-image-2.1-Q3_K_M.gguf", "内存占用最低，画质有所下降", "diffusion"),
    ModelFile("Q4_K_M", "unsloth/Qwen-Image-2.1-GGUF", "qwen-image-2.1-Q4_K_M.gguf", "qwen-image-2.1-Q4_K_M.gguf", "推荐，画质与内存平衡", "diffusion"),
    ModelFile("Q5_K_M", "unsloth/Qwen-Image-2.1-GGUF", "qwen-image-2.1-Q5_K_M.gguf", "qwen-image-2.1-Q5_K_M.gguf", "更高画质，适合 24GB+ 内存", "diffusion"),
    ModelFile("Q6_K", "unsloth/Qwen-Image-2.1-GGUF", "qwen-image-2.1-Q6_K.gguf", "qwen-image-2.1-Q6_K.gguf", "高画质，适合 32GB+ 内存", "diffusion"),
    ModelFile("Q8_0", "unsloth/Qwen-Image-2.1-GGUF", "qwen-image-2.1-Q8_0.gguf", "qwen-image-2.1-Q8_0.gguf", "接近原始画质，适合 48GB+ 内存", "diffusion"),
]

SUPPORT_MODELS = [
    ModelFile("Qwen3-VL 编码器", "unsloth/Qwen3-VL-8B-Instruct-GGUF", "Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf", "Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf", "文生图与改图必需", "encoder"),
    ModelFile("视觉模块", "unsloth/Qwen3-VL-8B-Instruct-GGUF", "mmproj-BF16.gguf", "mmproj-BF16.gguf", "参考图改图必需", "vision"),
    ModelFile("Qwen Image 2.1 VAE", "unsloth/Qwen-Image-2.1-FP8", "vae/qwen_image_2.1_vae_bf16.safetensors", "vae/qwen_image_2.1_vae_bf16.safetensors", "图像编码/解码必需", "vae"),
]


def recommended_diffusion(memory_gb: int | None = None) -> ModelFile:
    memory = memory_gb or physical_memory_gb()
    label = "Q8_0" if memory >= 48 else "Q6_K" if memory >= 32 else "Q5_K_M" if memory >= 20 else "Q4_K_M" if memory >= 14 else "Q3_K_M"
    return next(model for model in DIFFUSION_MODELS if model.label == label)


def scan_models(paths: AppPaths) -> dict[str, list[str] | str | None]:
    ggufs = sorted(p.name for p in paths.models.glob("*.gguf"))
    vaes = sorted((paths.models / "vae").glob("*.safetensors"))
    return {
        "diffusion": [name for name in ggufs if name.lower().startswith(("qwen-image", "qwen_image"))],
        "encoder": [name for name in ggufs if name.startswith(("Qwen3-VL", "Qwen3VL", "Qwen2.5-VL"))],
        "vision": next((name for name in ggufs if name.lower().startswith("mmproj")), None),
        "vae": str(vaes[0]) if vaes else None,
    }


def import_reference(source: Path, paths: AppPaths) -> str:
    suffix = source.suffix.lower() if source.suffix else ".png"
    destination = paths.refs / f"{uuid.uuid4().hex[:10]}{suffix}"
    shutil.copy2(source, destination)
    return destination.relative_to(paths.outputs).as_posix()


def build_sd_args(params: GenerationParams, paths: AppPaths, model_state: dict[str, Any], output_pattern: Path, preview: Path | None, settings: Settings) -> list[str]:
    prompt = params.prompt
    if params.transparent and not prompt.startswith("This is an RGBA image"):
        prompt = f"This is an RGBA image with transparency. {prompt} The image has alpha channel and the background is transparent."
    args = [
        "--diffusion-model", str(paths.models / params.diffusion_model),
        "--vae", str(model_state["vae"] or ""),
        "--llm", str(paths.models / params.text_encoder),
        "-p", prompt,
        "--steps", str(params.steps),
        "--cfg-scale", str(params.cfg),
        "--sampling-method", params.sampler,
        "-W", str(params.width), "-H", str(params.height),
        "-s", str(params.seed), "--diffusion-fa", "-o", str(output_pattern),
    ]
    if params.negative:
        args += ["-n", params.negative]
    if params.scheduler:
        args += ["--scheduler", params.scheduler]
    if params.batch > 1:
        args += ["-b", str(params.batch)]
    for rel in params.refs[:10]:
        args += ["-r", str(paths.outputs / rel)]
    if params.refs and model_state.get("vision"):
        args += ["--llm_vision", str(paths.models / str(model_state["vision"]))]
    if params.easy_cache:
        args += ["--cache-mode", "easycache"]
    if preview is not None:
        args += ["--preview", "proj", "--preview-path", str(preview)]
    if settings.vae_tiling or params.width * params.height > 3_000_000:
        args += ["--vae-tiling"]
    backend = settings.backend.lower()
    if backend == "cuda":
        args += ["--backend", "cuda0"]
    elif backend == "vulkan":
        args += ["--backend", "vulkan0"]
    return args
