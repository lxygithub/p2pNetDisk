#!/usr/bin/env python3
"""为管理后台生成 favicon（复用 Android 图标的 SDF 渲染）。

产物：
  - netdisk-admin/src/favicon.ico  16/32/48/64 多尺寸（PNG-in-ICO）
  - netdisk-admin/src/favicon.png  128px，供 apple-touch-icon / 高 DPI 标签页

重新生成：在仓库根目录执行 `python tools/generate_admin_favicon.py`。
依赖同目录的 generate_app_icon.py（纯标准库，无需 Pillow）。
"""

import shutil
import struct
from pathlib import Path

import generate_app_icon as icon

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "netdisk-admin" / "src"
TMP = ROOT / ".workbuddy" / "favicon-tmp"

SIZES = (16, 32, 48, 64)


def write_ico(path, entries):
    """entries: [(size, png_bytes)] → ICO（PNG-in-ICO，Vista+ 浏览器都支持）。"""
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    dir_entries = b""
    blobs = b""
    for size, png in entries:
        # ICO 目录里 256 用 0 表示；这里最大 64，直接写实际值。
        dim = 0 if size >= 256 else size
        dir_entries += struct.pack(
            "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset
        )
        offset += len(png)
        blobs += png
    path.write_bytes(header + dir_entries + blobs)


def main():
    TMP.mkdir(parents=True, exist_ok=True)
    entries = []
    for size in SIZES:
        p = TMP / f"{size}.png"
        icon.render(p, size, "legacy")
        entries.append((size, p.read_bytes()))

    write_ico(OUT / "favicon.ico", entries)
    icon.render(OUT / "favicon.png", 128, "legacy")

    shutil.rmtree(TMP, ignore_errors=True)
    print("done.")


if __name__ == "__main__":
    main()
