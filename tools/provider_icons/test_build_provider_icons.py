#!/usr/bin/env python3
"""The checked-in Grok and Cursor marks match the generator."""

import importlib.util
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("build_provider_icons.py")


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[12:16] != b"IHDR":
        raise AssertionError(f"{path.name} has no IHDR")
    return struct.unpack(">II", data[16:24])


class ProviderIconTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("provider_icons", SCRIPT)
        self.build = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(self.build)

    def test_official_sources_are_at_least_the_codex_mark(self):
        assets = ROOT / "components/app_tokens/assets"
        for name in ("grok-mark.png", "cursor-mark.png"):
            width, height = png_size(assets / name)
            self.assertGreaterEqual(width, 112, name)
            self.assertGreaterEqual(height, 112, name)

    def test_firmware_images_match_the_generator(self):
        header, source = self.build.render_sources()
        self.assertEqual(
            (ROOT / "components/app_tokens/provider_icons.h").read_text(
                encoding="utf-8"),
            header)
        self.assertEqual(
            (ROOT / "components/app_tokens/provider_icons.c").read_text(
                encoding="utf-8"),
            source)
        assets = self.build.build_assets()
        grok = assets["tk_img_grok_32"][2]
        self.assertEqual(grok[3], 0)  # top-left alpha, BGRA
        opaque = [grok[index + 3] for index in range(0, len(grok), 4)]
        self.assertTrue(any(alpha > 200 for alpha in opaque))
        cursor = assets["tk_img_cursor_16"][2]
        self.assertEqual(len(cursor), 16 * 16 * 4)
        self.assertEqual(len(grok), 32 * 32 * 4)


if __name__ == "__main__":
    unittest.main()
