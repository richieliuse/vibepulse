#!/usr/bin/env python3
"""Bake official Grok and Cursor marks at the sizes the quota pages draw.

Sources are the publishers' own PNGs and are larger than the 112 px Codex
mark checked into agent_assets. The firmware images are the final on-screen
sizes: 32 px on the Grok page (the Codex header mark) and 16 px in each
Cursor quadrant (half of that mark). LVGL must not scale or recolor them.
Pixels are straight-alpha B,G,R,A, matching lv_color32_t.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "components/app_tokens/assets"
OUT_H = ROOT / "components/app_tokens/provider_icons.h"
OUT_C = ROOT / "components/app_tokens/provider_icons.c"

# Near-black tile pixels become transparent so the mark sits on the AMOLED
# black instead of painting a second black square.
_BLACK_CUTOFF = 24


def _paeth(left: int, up: int, up_left: int) -> int:
    estimate = left + up - up_left
    distance_left = abs(estimate - left)
    distance_up = abs(estimate - up)
    distance_up_left = abs(estimate - up_left)
    if distance_left <= distance_up and distance_left <= distance_up_left:
        return left
    if distance_up <= distance_up_left:
        return up
    return up_left


def read_png_rgba(path: Path) -> tuple[int, int, bytes]:
    """8-bit non-interlaced RGBA PNG. Stdlib only, so CI can rebuild it."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path.name} is not a PNG")
    position = 8
    width = height = None
    compressed = bytearray()
    while position + 8 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        chunk = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, comp, filt, inter = struct.unpack(
                ">IIBBBBB", chunk)
            if (depth, color, comp, filt, inter) != (8, 6, 0, 0, 0):
                raise ValueError(f"{path.name} must be 8-bit RGBA")
        elif kind == b"IDAT":
            compressed += chunk
        elif kind == b"IEND":
            break
    if not width or not height:
        raise ValueError(f"{path.name} has no image header")
    raw = zlib.decompress(bytes(compressed))
    stride = width * 4
    rows = []
    cursor = 0
    previous = bytearray(stride)
    for _y in range(height):
        filter_type = raw[cursor]
        cursor += 1
        row = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        if filter_type == 1:
            for index in range(stride):
                left = row[index - 4] if index >= 4 else 0
                row[index] = (row[index] + left) & 255
        elif filter_type == 2:
            for index in range(stride):
                row[index] = (row[index] + previous[index]) & 255
        elif filter_type == 3:
            for index in range(stride):
                left = row[index - 4] if index >= 4 else 0
                row[index] = (row[index] + ((left + previous[index]) // 2)) & 255
        elif filter_type == 4:
            for index in range(stride):
                left = row[index - 4] if index >= 4 else 0
                up = previous[index]
                up_left = previous[index - 4] if index >= 4 else 0
                row[index] = (row[index] + _paeth(left, up, up_left)) & 255
        elif filter_type != 0:
            raise ValueError(f"unsupported PNG filter {filter_type}")
        rows.append(row)
        previous = row
    return width, height, b"".join(rows)


def resize_rgba(src: bytes, src_w: int, src_h: int,
                dst_w: int, dst_h: int) -> bytes:
    """Area-average downsample. Coverage weights keep the result stable."""
    out = bytearray(dst_w * dst_h * 4)
    for dst_y in range(dst_h):
        y0 = dst_y * src_h / dst_h
        y1 = (dst_y + 1) * src_h / dst_h
        y_start = int(y0)
        y_end = min(src_h, int(y1 + 0.999999))
        for dst_x in range(dst_w):
            x0 = dst_x * src_w / dst_w
            x1 = (dst_x + 1) * src_w / dst_w
            x_start = int(x0)
            x_end = min(src_w, int(x1 + 0.999999))
            red = green = blue = alpha = covered = 0.0
            for src_y in range(y_start, y_end):
                weight_y = min(src_y + 1, y1) - max(src_y, y0)
                if weight_y <= 0:
                    continue
                for src_x in range(x_start, x_end):
                    weight_x = min(src_x + 1, x1) - max(src_x, x0)
                    if weight_x <= 0:
                        continue
                    weight = weight_x * weight_y
                    index = (src_y * src_w + src_x) * 4
                    sample_alpha = src[index + 3] / 255.0
                    covered += weight
                    alpha += weight * src[index + 3]
                    red += weight * src[index] * sample_alpha
                    green += weight * src[index + 1] * sample_alpha
                    blue += weight * src[index + 2] * sample_alpha
            offset = (dst_y * dst_w + dst_x) * 4
            if covered <= 0 or alpha <= 0:
                continue
            premul = alpha / 255.0
            if premul <= 0:
                continue
            red_i = int(round(red / premul))
            green_i = int(round(green / premul))
            blue_i = int(round(blue / premul))
            alpha_i = int(round(alpha / covered))
            if max(red_i, green_i, blue_i) < _BLACK_CUTOFF:
                alpha_i = 0
            out[offset] = max(0, min(255, red_i))
            out[offset + 1] = max(0, min(255, green_i))
            out[offset + 2] = max(0, min(255, blue_i))
            out[offset + 3] = max(0, min(255, alpha_i))
    return bytes(out)


def to_bgra(rgba: bytes) -> bytes:
    out = bytearray(len(rgba))
    for index in range(0, len(rgba), 4):
        red, green, blue, alpha = rgba[index:index + 4]
        out[index:index + 4] = bytes((blue, green, red, alpha))
    return bytes(out)


def build_assets() -> dict[str, tuple[int, int, bytes]]:
    grok_w, grok_h, grok = read_png_rgba(ASSETS / "grok-mark.png")
    cursor_w, cursor_h, cursor = read_png_rgba(ASSETS / "cursor-mark.png")
    if min(grok_w, grok_h, cursor_w, cursor_h) < 112:
        raise ValueError("source marks must be at least the 112 px Codex mark")
    return {
        "tk_img_grok_32": (32, 32, to_bgra(
            resize_rgba(grok, grok_w, grok_h, 32, 32))),
        "tk_img_cursor_16": (16, 16, to_bgra(
            resize_rgba(cursor, cursor_w, cursor_h, 16, 16))),
    }


def _c_array(name: str, data: bytes) -> str:
    rows = []
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        rows.append("  " + ", ".join(f"0x{byte:02x}" for byte in chunk) + ",")
    return f"static const uint8_t {name}[] = {{\n" + "\n".join(rows) + "\n};\n"


def _descriptor(name: str, width: int, height: int, size: int) -> str:
    return f"""const lv_image_dsc_t {name} = {{
  .header = {{
    .magic = LV_IMAGE_HEADER_MAGIC,
    .cf = LV_COLOR_FORMAT_ARGB8888,
    .flags = 0,
    .w = {width},
    .h = {height},
    .stride = {width * 4},
  }},
  .data_size = {size},
  .data = {name}_data,
}};
"""


def render_sources() -> tuple[str, str]:
    assets = build_assets()
    header = """#ifndef PROVIDER_ICONS_H
#define PROVIDER_ICONS_H

#include "lvgl.h"

/* Final on-screen sizes. Source PNGs in assets/ are the official marks
 * and are larger than the 112 px Codex asset. */
extern const lv_image_dsc_t tk_img_grok_32;
extern const lv_image_dsc_t tk_img_cursor_16;

#endif
"""
    source = '#include "provider_icons.h"\n\n'
    for name, (_width, _height, data) in assets.items():
        source += _c_array(name + "_data", data)
        source += "\n"
    for name, (width, height, data) in assets.items():
        source += _descriptor(name, width, height, len(data))
        source += "\n"
    return header, source


def main() -> None:
    header, source = render_sources()
    OUT_H.write_text(header, encoding="utf-8")
    OUT_C.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    main()
