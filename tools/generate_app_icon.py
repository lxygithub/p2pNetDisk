#!/usr/bin/env python3
"""生成 p2pNetDisk 的应用图标（纯标准库，无需 Pillow / ImageMagick）。

设计：深蓝 -> 亮蓝的 squircle 渐变底 + 右上青色光晕；主体是一朵白色「云盘」，
云内镂空三个节点两两相连（P2P 网络），云下一条青色托底线代表存储层。

用解析 SDF（signed distance field）逐像素渲染，任意输出尺寸都直接按归一化
坐标计算，因此 48dp 的 mdpi 和 192dp 的 xxxhdpi 一样锐利，不需要缩放插值。

产物：
  - mipmap-*/ic_launcher.png            旧版/兜底图标（带渐变底）
  - mipmap-*/ic_launcher_foreground.png 自适应图标前景（透明底，收进 66dp 安全区）
  - mipmap-*/launch_image.png           启动屏居中的品牌图（96dp）
  - app/assets/images/logo.png          设置页「关于」里展示的品牌图

重新生成：在仓库根目录执行 `python tools/generate_app_icon.py`。
"""

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"
ASSETS = ROOT / "app" / "assets" / "images"

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

# P2P 网络的三个节点（归一化坐标，都在云的实体范围内）
NODES = ((0.415, 0.545), (0.585, 0.545), (0.500, 0.635))
EDGES = ((0, 1), (0, 2), (1, 2))


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else (hi if v > hi else v)


def mix(a, b, t):
    return a + (b - a) * t


def coverage(sdf, pixel):
    """SDF -> 覆盖率，边界约 1 像素的解析抗锯齿。"""
    return clamp(0.5 - sdf / pixel)


def sd_circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def sd_round_box(x, y, cx, cy, hx, hy, r):
    qx = abs(x - cx) - (hx - r)
    qy = abs(y - cy) - (hy - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def sd_segment(x, y, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = x - ax, y - ay
    t = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy))
    return math.hypot(wx - t * vx, wy - t * vy)


def cloud_sdf(x, y):
    """云 = 三个圆 + 一条圆角底边，取并集。"""
    return min(
        sd_circle(x, y, 0.500, 0.545, 0.150),
        sd_circle(x, y, 0.365, 0.570, 0.112),
        sd_circle(x, y, 0.645, 0.555, 0.122),
        sd_round_box(x, y, 0.500, 0.610, 0.200, 0.060, 0.055),
    )


def cut_sdf(x, y):
    """云内镂空：三个节点 + 三条连线，取并集。"""
    d = min(sd_circle(x, y, n[0], n[1], 0.034) for n in NODES)
    for a, b in EDGES:
        p, q = NODES[a], NODES[b]
        d = min(d, sd_segment(x, y, p[0], p[1], q[0], q[1]) - 0.016)
    return d


def background(x, y, size):
    """返回 (r, g, b, alpha)：squircle 渐变底 + 右上光晕。"""
    dx2 = ((x - 0.5) / 0.5) ** 2
    dy2 = ((y - 0.5) / 0.5) ** 2
    s = math.sqrt(math.sqrt(dx2 * dx2 + dy2 * dy2))
    alpha = clamp(0.5 - (s - 1.0) * 0.5 * size)

    t = clamp(0.5 * (x + y))
    r, g, b = mix(88, 14, t), mix(126, 32, t), mix(255, 92, t)
    glow = max(0.0, 1.0 - math.hypot(x - 0.78, y - 0.20) / 0.62) ** 2
    k = 0.32 * glow
    return mix(r, 56, k), mix(g, 189, k), mix(b, 248, k), alpha


def write_png(path, size, pixels):
    """手写 PNG 编码（RGBA8，filter 0），避免第三方依赖。"""
    stride = size * 4
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw.extend(pixels[y * stride : (y + 1) * stride])

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def render(path, size, mode):
    """mode: legacy（渐变底）/ foreground（透明底）/ asset（渐变底，留白略多）。"""
    scale = {"legacy": 0.88, "foreground": 0.60, "asset": 0.88, "launch": 0.88}[mode]
    with_background = mode != "foreground"
    px = 1.0 / size
    shape_px = px / scale
    buf = bytearray(size * size * 4)

    for j in range(size):
        y = (j + 0.5) / size
        gy = (y - 0.5) / scale + 0.5
        row = j * size * 4
        for i in range(size):
            x = (i + 0.5) / size
            gx = (x - 0.5) / scale + 0.5

            if with_background:
                br, bg, bb, ba = background(x, y, size)
            else:
                br = bg = bb = ba = 0.0

            cloud_a = coverage(cloud_sdf(gx, gy), shape_px)
            if cloud_a > 0.0:
                # 镂空只作用在云上，托底线不受影响。
                cloud_a *= 1.0 - coverage(cut_sdf(gx, gy), shape_px)
            line_a = coverage(sd_round_box(gx, gy, 0.500, 0.705, 0.150, 0.012, 0.012), shape_px)

            # 云：白 -> 冷白；托底线：青
            shade = clamp((gy - 0.38) / 0.32)
            cr, cg, cb = mix(255, 214, shade), mix(255, 232, shade), 255.0
            lr, lg, lb = 125.0, 211.0, 252.0

            if with_background:
                r, g, b = br, bg, bb
                r, g, b = mix(r, lr, line_a), mix(g, lg, line_a), mix(b, lb, line_a)
                r, g, b = mix(r, cr, cloud_a), mix(g, cg, cloud_a), mix(b, cb, cloud_a)
                alpha = ba
            else:
                total = clamp(cloud_a + line_a)
                if total > 0.0:
                    r = (cr * cloud_a + lr * line_a) / total
                    g = (cg * cloud_a + lg * line_a) / total
                    b = (cb * cloud_a + lb * line_a) / total
                else:
                    r = g = b = 0.0
                alpha = total

            o = row + i * 4
            buf[o] = int(clamp(r / 255.0) * 255)
            buf[o + 1] = int(clamp(g / 255.0) * 255)
            buf[o + 2] = int(clamp(b / 255.0) * 255)
            buf[o + 3] = int(alpha * 255)

    write_png(path, size, buf)
    print(f"  {path.relative_to(ROOT)}  {size}x{size}")


def main():
    print("p2pNetDisk icon:")
    for name, density in DENSITIES.items():
        folder = RES / f"mipmap-{name}"
        render(folder / "ic_launcher.png", int(48 * density), "legacy")
        render(folder / "ic_launcher_foreground.png", int(108 * density), "foreground")
        render(folder / "launch_image.png", int(96 * density), "launch")
    render(ASSETS / "logo.png", 384, "asset")
    print("done.")


if __name__ == "__main__":
    main()
