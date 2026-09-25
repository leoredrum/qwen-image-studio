"""去除 Qwen-Image VAE 解码后残留的 2px 网格（与 macOS 版算法一致）。

网格是周期为 2 的固定图案，只落在三个奈奎斯特分量上：(-1)^x、(-1)^y、(-1)^(x+y)。
按 32px 分块估计每个分量的幅度（自然画面在大块内对这些交替符号求平均≈0，网格则稳定不变），
双线性插值成平滑的幅度图后逐像素减掉。透明通道原样保留。
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

TILE = 32


def _interp_axis(n: int, tiles: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    pos = np.clip((np.arange(n) + 0.5) / TILE - 0.5, 0, tiles - 1)
    i0 = np.floor(pos).astype(np.intp)
    i1 = np.minimum(i0 + 1, tiles - 1)
    return i0, i1, (pos - i0).astype(np.float32)


def degrid_array(rgba: np.ndarray) -> np.ndarray:
    """输入 H×W×4 的 uint8（非预乘 RGBA），返回去网格后的新数组。"""
    h, w = rgba.shape[:2]
    ty, tx = h // TILE, w // TILE
    if ty < 2 or tx < 2:
        return rgba.copy()

    rgb = rgba[..., :3].astype(np.float32)
    alpha = rgba[..., 3]
    sx = np.where(np.arange(w) % 2 == 0, 1.0, -1.0).astype(np.float32)
    sy = np.where(np.arange(h) % 2 == 0, 1.0, -1.0).astype(np.float32)
    patterns = (sx[None, :], sy[:, None], sy[:, None] * sx[None, :])

    ch, cw = ty * TILE, tx * TILE
    crop = rgb[:ch, :cw]
    mask = (alpha[:ch, :cw] >= 250).astype(np.float32)   # 透明边缘不参与估计
    counts = mask.reshape(ty, TILE, tx, TILE).sum(axis=(1, 3))
    valid = counts > TILE * TILE * 0.5

    grid = np.zeros_like(rgb)
    ix0, ix1, dx = _interp_axis(w, tx)
    iy0, iy1, dy = _interp_axis(h, ty)
    for p in patterns:
        pf = np.broadcast_to(p, (h, w))
        weighted = crop * (pf[:ch, :cw] * mask)[..., None]
        sums = weighted.reshape(ty, TILE, tx, TILE, 3).sum(axis=(1, 3))
        amp = np.where(valid[..., None], sums / np.maximum(counts, 1)[..., None], 0).astype(np.float32)
        # 双线性插值：先沿 x，再沿 y
        ax = amp[:, ix0] * (1 - dx)[None, :, None] + amp[:, ix1] * dx[None, :, None]
        full = ax[iy0] * (1 - dy)[:, None, None] + ax[iy1] * dy[:, None, None]
        grid += full * pf[..., None]

    out = rgba.copy()
    cleaned = np.clip(np.rint(rgb - grid), 0, 255).astype(np.uint8)
    keep = alpha > 0
    out[..., :3][keep] = cleaned[keep]
    return out


def nyquist_strength(rgba: np.ndarray) -> float:
    """平坦区域里 (-1)^(x+y) 棋盘分量的平均幅度，用来衡量网格强度。"""
    h, w = rgba.shape[:2]
    ty, tx = h // TILE, w // TILE
    g = rgba[: ty * TILE, : tx * TILE, 1].astype(np.float32)
    s = np.where((np.add.outer(np.arange(ty * TILE), np.arange(tx * TILE)) % 2) == 0, 1.0, -1.0)
    blocks = (g * s).reshape(ty, TILE, tx, TILE).mean(axis=(1, 3))
    return float(np.abs(blocks).mean())


def process_file(path: Path) -> bool:
    """读取 PNG，去网格后原地写回。"""
    from PySide6.QtGui import QImage

    image = QImage(str(path))
    if image.isNull():
        return False
    image = image.convertToFormat(QImage.Format_RGBA8888)
    w, h, bpl = image.width(), image.height(), image.bytesPerLine()
    arr = np.frombuffer(image.constBits(), dtype=np.uint8, count=h * bpl).reshape(h, bpl)[:, : w * 4].reshape(h, w, 4)
    cleaned = np.ascontiguousarray(degrid_array(arr))
    result = QImage(cleaned.data, w, h, w * 4, QImage.Format_RGBA8888).copy()
    return result.save(str(path), "PNG")
