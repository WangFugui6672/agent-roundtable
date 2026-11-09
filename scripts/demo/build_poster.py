#!/usr/bin/env python3
"""Poster for the v0.2.0 release (1920x1080)."""

import os
from pathlib import Path
from subprocess import run

from PIL import Image, ImageDraw, ImageFilter

import build_assets as B

REPO_ROOT = Path(__file__).resolve().parents[2]
WORK = Path(os.environ.get("DEMO_WORK_DIR", REPO_ROOT.parent / "artifacts" / "dual-demo-edit"))
RAW = Path(os.environ.get("DEMO_RAW_DIR", REPO_ROOT.parent / "artifacts" / "dual-demo-raw" / "take4"))
TMP = WORK / "tmp"
TMP.mkdir(parents=True, exist_ok=True)


def grab(src, t, out):
    run(["ffmpeg", "-y", "-v", "error", "-i", str(src), "-ss", str(t),
         "-frames:v", "1", str(out)], check=True)
    return Image.open(out).convert("RGB")


def phone(img, height, radius=26):
    w = round(img.width * height / img.height)
    img = img.resize((w, height), Image.LANCZOS)
    mask = Image.new("L", (w, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, height - 1], radius=radius, fill=255)
    frame = Image.new("RGBA", (w, height), (0, 0, 0, 0))
    frame.paste(img, (0, 0), mask)
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle([0, 0, w - 1, height - 1], radius=radius, outline=B.BORDER + (255,), width=3)
    return frame


def main():
    ios = grab(RAW / "ios-raw.mp4", 112, TMP / "poster_ios.png")
    andr = grab(RAW / "android-library.mp4", 2.0, TMP / "poster_and.png").crop((130, 0, 590, 1280))

    canvas = B.background()
    d = ImageDraw.Draw(canvas)

    text = B.text
    text(d, (120, 150), "AGENT ROUNDTABLE · v0.2.0", B.body(24), (120, 140, 170), "la")
    text(d, (120, 230), "独立开发者该不该", B.bold(66), B.TEXT, "la")
    text(d, (120, 320), "先做 iOS 再补 Android？", B.bold(66), B.TEXT, "la")
    text(d, (120, 450), "同一议题 · 两个独立圆桌 · 同一协议", B.bold(32), (150, 168, 196), "la")
    text(d, (120, 520), "iOS 与 Android 各自跑完第一轮与第二轮互评，", B.body(25), B.MUTED, "la")
    text(d, (120, 560), "用自己的原生客户端实现同一份协议。", B.body(25), B.MUTED, "la")

    y = 650
    for label, color in [("iOS · SwiftUI · RoundtableCore", B.IOS), ("Android · Compose · :core", B.AND)]:
        B.tag(d, 120, y, label, color)
        y += 60

    text(d, (120, 830), "真实 Provider 流式生成 · BYOK 密钥只在本机", B.body(22), B.DIM, "la")
    text(d, (120, 900), "60 秒双端演示 · 端侧资料库为 Android 独有", B.body(22), B.DIM, "la")

    ios_img = phone(ios, 690)
    and_img = phone(andr, 690)

    def shadow(img, xy):
        sh = Image.new("RGBA", (img.width + 80, img.height + 80), (0, 0, 0, 0))
        mask = Image.new("L", sh.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [40, 40, 40 + img.width, 40 + img.height], radius=30, fill=110)
        mask = mask.filter(ImageFilter.GaussianBlur(22))
        sh.putalpha(mask)
        canvas.paste(sh, (xy[0] - 40, xy[1] - 40), sh)

    shadow(ios_img, (1030, 160))
    shadow(and_img, (1440, 230))
    canvas.paste(ios_img, (1030, 160), ios_img)
    canvas.paste(and_img, (1440, 230), and_img)

    text(d, (1030, 128), "iOS · SwiftUI", B.bold(22), B.IOS, "lm")
    text(d, (1440, 198), "Android · Compose", B.bold(22), B.AND, "lm")

    out = WORK / "demo-v0.2.0-dual-end-poster.png"
    canvas.save(out)
    print(out)


if __name__ == "__main__":
    main()
