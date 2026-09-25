import json
import tempfile
import unittest
from pathlib import Path

from qwen_studio.core import (
    AppPaths, GenerationParams, HistoryStore, Settings, build_sd_args, fit_size,
    preset_size, recommended_diffusion,
)


class CoreTests(unittest.TestCase):
    def test_presets_are_divisible_by_32(self):
        for tier in ("草稿", "标准", "2K 高清"):
            for aspect in ("1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16"):
                width, height = preset_size(aspect, tier)
                self.assertEqual(width % 32, 0)
                self.assertEqual(height % 32, 0)

    def test_fit_size(self):
        width, height = fit_size(16 / 9, 1.05)
        self.assertEqual(width % 32, 0)
        self.assertEqual(height % 32, 0)
        self.assertAlmostEqual(width / height, 16 / 9, delta=.06)

    def test_recommendation(self):
        self.assertEqual(recommended_diffusion(16).label, "Q4_K_M")
        self.assertEqual(recommended_diffusion(64).label, "Q8_0")

    def test_settings_ignore_unknown_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            path.write_text(json.dumps({"steps": 30, "future": True}), encoding="utf-8")
            settings = Settings.load(path)
            self.assertEqual(settings.steps, 30)

    def test_build_sd_args(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = AppPaths(Path(folder)); paths.ensure()
            params = GenerationParams("猫", "bad", 1024, 1024, 20, 6, 7, "euler", "", 1, "model.gguf", "text.gguf", refs=["refs/a.png"], transparent=True)
            args = build_sd_args(params, paths, {"vae": paths.models / "vae/v.safetensors", "vision": "mmproj.gguf"}, paths.outputs / "out.png", paths.previews / "p.png", Settings())
            self.assertIn("--llm_vision", args)
            self.assertIn("--preview-path", args)
            prompt = args[args.index("-p") + 1]
            self.assertTrue(prompt.startswith("This is an RGBA image"))


if __name__ == "__main__":
    unittest.main()
