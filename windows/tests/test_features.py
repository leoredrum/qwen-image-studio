import unittest

import numpy as np

from qwen_studio.core import (
    FRESH_RE, GenerationItem, GenerationParams, chain_target, parse_pe_answer, size_for_ratio,
)
from qwen_studio.degrid import degrid_array, nyquist_strength


def item(status: str, outputs: list[str] | None = None) -> GenerationItem:
    params = GenerationParams(prompt="p", negative="", width=1024, height=1024, steps=20, cfg=6.0, seed=1,
                              sampler="euler", scheduler="", batch=1, diffusion_model="m", text_encoder="e")
    return GenerationItem(params=params, status=status, outputs=outputs or [])


class ChainTests(unittest.TestCase):
    def test_defaults_to_latest_done(self):
        a, b = item("done", ["a.png"]), item("failed")
        self.assertIs(chain_target([a, b], b, False), a)

    def test_selected_done_wins(self):
        a, b = item("done", ["a.png"]), item("done", ["b.png"])
        self.assertIs(chain_target([a, b], a, False), a)

    def test_pending_selected_is_target(self):
        a, b = item("done", ["a.png"]), item("running")
        self.assertIs(chain_target([a, b], b, False), b)

    def test_fresh_next_disables(self):
        self.assertIsNone(chain_target([item("done", ["a.png"])], None, True))

    def test_empty_conversation(self):
        self.assertIsNone(chain_target([], None, False))

    def test_fresh_regex(self):
        self.assertTrue(FRESH_RE.search("重新画一张海边的猫"))
        self.assertFalse(FRESH_RE.search("给它戴个墨镜"))


class PETests(unittest.TestCase):
    def test_parse_answer_with_thinking(self):
        text = '<think>分析……{不是 json}</think>\n{"rewritten_prompt": "A cat", "wh_ratio": "3:2"}'
        self.assertEqual(parse_pe_answer(text), {"prompt": "A cat", "wh_ratio": "3:2", "ratio_follow": ""})

    def test_parse_edit_answer(self):
        r = parse_pe_answer('{"rewritten_prompt": "保持<image1>不变", "wh_ratio": "", "ratio_follow": "<image1>"}')
        self.assertEqual(r["ratio_follow"], "<image1>")

    def test_parse_accepts_typo_key_and_rejects_garbage(self):
        self.assertEqual(parse_pe_answer('{"rewrited_prompt": "x"}')["prompt"], "x")
        self.assertIsNone(parse_pe_answer("没有 JSON"))

    def test_size_for_ratio(self):
        self.assertEqual(size_for_ratio("3:2", "标准", (1, 1)), (1248, 832))
        w, h = size_for_ratio("21:9", "标准", (1, 1))
        self.assertEqual((w % 32, h % 32), (0, 0))
        self.assertAlmostEqual(w / h, 21 / 9, delta=0.1)
        self.assertEqual(size_for_ratio("bad", "标准", (7, 7)), (7, 7))


class DeGridTests(unittest.TestCase):
    def test_removes_lattice_and_keeps_alpha(self):
        rng = np.random.default_rng(0)
        h, w = 256, 320
        base = np.clip(128 + rng.normal(0, 3, (h, w, 3)), 0, 255)
        lattice = 3.0 * np.where(np.add.outer(np.arange(h), np.arange(w)) % 2 == 0, 1, -1)[..., None]
        rgba = np.zeros((h, w, 4), np.uint8)
        rgba[..., :3] = np.clip(np.rint(base + lattice), 0, 255)
        rgba[..., 3] = 255
        rgba[:20, :20, 3] = 0
        out = degrid_array(rgba)
        self.assertGreater(nyquist_strength(rgba), 2.5)
        self.assertLess(nyquist_strength(out), 0.5)
        self.assertTrue(np.array_equal(out[..., 3], rgba[..., 3]))
        self.assertLess(abs(out[..., :3].mean() - rgba[..., :3].mean()), 0.5)


if __name__ == "__main__":
    unittest.main()
