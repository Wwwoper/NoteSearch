#!/usr/bin/env python3
"""Рисует иконку NoteSearch (1024x1024, прозрачный фон, стиль macOS Big Sur и новее).

Зависимости: Pillow, numpy.  Запуск:  python3 scripts/draw_icon.py [путь/к/icon-1024.png]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 3                       # коэффициент суперсэмплинга
CANVAS = 1024 * S
BODY = 824                  # размер «плитки» иконки на холсте 1024 (поля под тень)
OFFSET = (1024 - BODY) // 2

TOP_LEFT = np.array([64, 156, 255], dtype=np.float32)     # голубой
BOTTOM_RIGHT = np.array([124, 58, 237], dtype=np.float32)  # фиолетовый
HIGHLIGHT = (255, 209, 51, 255)                            # жёлтый «маркер»


def px(value):
    return int(round(value * S))


def squircle_alpha(size, n=5.0):
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    x = (xs - c) / c
    y = (ys - c) / c
    d = np.abs(x) ** n + np.abs(y) ** n
    signed = (1.0 - d ** (1.0 / n)) * c
    return np.clip(signed + 0.5, 0.0, 1.0)


def body_layer():
    size = px(BODY)
    alpha = squircle_alpha(size)

    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    t = ((xs + ys) / (2.0 * (size - 1)))[..., None]
    rgb = TOP_LEFT * (1 - t) + BOTTOM_RIGHT * t

    # мягкий блик сверху
    cx, cy = size * 0.40, -size * 0.12
    dist = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2)
    sheen = np.clip(1.0 - dist / (size * 0.95), 0.0, 1.0) ** 2 * 0.28
    rgb = rgb * (1 - sheen[..., None]) + 255.0 * sheen[..., None]

    # лёгкое затемнение к низу
    shade = 1.0 - 0.14 * (ys / size) ** 2
    rgb = rgb * shade[..., None]

    out = np.dstack([np.clip(rgb, 0, 255), alpha * 255.0]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def tinted_shadow(alpha_img, color, opacity, blur, dy):
    shadow = Image.new("RGBA", alpha_img.size, color + (0,))
    a = alpha_img.point(lambda v: int(v * opacity))
    shadow.putalpha(a)
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(blur)))
    shifted = Image.new("RGBA", alpha_img.size, (0, 0, 0, 0))
    shifted.paste(shadow, (0, px(dy)))
    return shifted


def bbox(cx, cy, r):
    return [px(cx - r), px(cy - r), px(cx + r), px(cy + r)]


def glyph_layer():
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    cx, cy = 448, 452
    r_out, r_in = 215, 169

    # стекло лупы
    draw.ellipse(bbox(cx, cy, r_in), fill=(255, 255, 255, 46))

    # строки «текста» внутри линзы
    def bar(dx0, dx1, dy, height, color):
        draw.rounded_rectangle(
            [px(cx + dx0), px(cy + dy - height / 2), px(cx + dx1), px(cy + dy + height / 2)],
            radius=px(height / 2),
            fill=color,
        )

    white = (255, 255, 255, 238)
    bar(-105, 85, -58, 24, white)
    bar(-125, 30, 0, 48, HIGHLIGHT)      # найденное слово
    bar(46, 108, 0, 24, white)
    bar(-105, 52, 58, 24, white)

    # оправа и ручка
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse(bbox(cx, cy, r_out), fill=255)
    md.ellipse(bbox(cx, cy, r_in), fill=0)

    import math
    a = math.radians(45)
    p1 = (cx + (r_out - 10) * math.cos(a), cy + (r_out - 10) * math.sin(a))
    p2 = (772, 764)
    width = 68
    md.line([px(p1[0]), px(p1[1]), px(p2[0]), px(p2[1])], fill=255, width=px(width))
    md.ellipse(bbox(p2[0], p2[1], width / 2), fill=255)
    md.ellipse(bbox(p1[0], p1[1], width / 2), fill=255)

    layer.paste((255, 255, 255, 255), mask=mask)
    return layer


def render():
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    body = body_layer()
    body_full = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    body_full.paste(body, (px(OFFSET), px(OFFSET)))

    canvas = Image.alpha_composite(
        canvas, tinted_shadow(body_full.getchannel("A"), (20, 10, 70), 0.50, 24, 16)
    )
    canvas = Image.alpha_composite(canvas, body_full)

    glyph = glyph_layer()
    canvas = Image.alpha_composite(
        canvas, tinted_shadow(glyph.getchannel("A"), (40, 20, 120), 0.45, 12, 12)
    )
    canvas = Image.alpha_composite(canvas, glyph)

    return canvas.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "assets/icon-1024.png")
    target.parent.mkdir(parents=True, exist_ok=True)
    render().save(target)
    print("Сохранено:", target)
