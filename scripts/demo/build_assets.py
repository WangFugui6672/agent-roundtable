#!/usr/bin/env python3
"""Generate the static frames for the 60s dual-end demo video (1920x1080)."""

import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
REPO_ROOT = Path(__file__).resolve().parents[2]
WORK = Path(os.environ.get("DEMO_WORK_DIR", REPO_ROOT.parent / "artifacts" / "dual-demo-edit"))
OUT = WORK / "assets"
OUT.mkdir(parents=True, exist_ok=True)

FONT_BOLD = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_BODY = "/System/Library/Fonts/Hiragino Sans GB.ttc"

BG = (10, 13, 19)
PANEL = (17, 23, 37)
BORDER = (43, 50, 68)
TEXT = (232, 237, 246)
MUTED = (148, 163, 184)
DIM = (110, 122, 140)
IOS = (76, 154, 255)
AND = (61, 220, 132)
WARN = (245, 165, 36)


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


def bold(size):
    return font(FONT_BOLD, size)


def body(size):
    return font(FONT_BODY, size)


def background():
    img = Image.new("RGB", (W, H), BG)
    # soft vertical gradient
    top = Image.new("RGB", (W, H), (14, 19, 30))
    mask = Image.new("L", (W, H))
    md = ImageDraw.Draw(mask)
    for y in range(H):
        md.line([(0, y), (W, y)], fill=int(255 * (1 - y / H) ** 1.4))
    img = Image.composite(top, img, mask)
    # faint accent glows
    glow = Image.new("RGB", (W, H), BG)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-500, 500, 700, 1500], fill=(18, 32, 58))
    gd.ellipse([1300, -400, 2400, 500], fill=(26, 20, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(180))
    img = Image.blend(img, glow, 0.35)
    return img


def rounded(draw, box, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def text(draw, xy, s, f, fill=TEXT, anchor="la"):
    draw.text(xy, s, font=f, fill=fill, anchor=anchor)


def tag(draw, x, y, label, fill, fg=(10, 13, 19), f=None):
    f = f or bold(20)
    w = draw.textlength(label, font=f)
    rounded(draw, [x, y, x + w + 28, y + 38], 19, fill=fill)
    text(draw, (x + 14, y + 19), label, f, fg, "lm")
    return w + 28


def header(draw):
    draw.ellipse([64, 46, 84, 66], fill=AND)
    text(draw, (96, 56), "Agent Roundtable", bold(24), TEXT, "lm")
    text(draw, (330, 58), "v0.2.0", body(19), DIM, "lm")
    text(draw, (W - 64, 56), "同一议题 · 两个独立圆桌 · 同一协议", body(23), MUTED, "rm")
    draw.line([(64, 100), (W - 64, 100)], fill=(28, 35, 50), width=1)


# ---------------------------------------------------------------- title card
def title_card():
    img = background()
    d = ImageDraw.Draw(img)
    cx = W // 2
    text(d, (cx, 300), "AGENT ROUNDTABLE · DUAL-NATIVE DEMO", body(24), (120, 140, 170), "mm")
    f = bold(62)
    text(d, (cx, 410), "独立开发者该不该先做 iOS 再补 Android？", f, TEXT, "mm")
    text(d, (cx, 520), "同一议题 · 两个独立圆桌 · 同一协议", bold(36), (150, 168, 196), "mm")
    d.line([(cx - 330, 590), (cx + 330, 590)], fill=(40, 50, 70), width=2)
    text(d, (cx, 640), "iOS · SwiftUI　　Android · Compose　　真实 Provider 流式生成", body(26), MUTED, "mm")
    # accent dots, centred as one row
    label = "两个原生客户端 · 一份协议"
    f = body(22)
    block = 20 + 24 + 18 + 10 + 16 + d.textlength(label, font=f)
    x = cx - block / 2
    d.ellipse([x, 711, x + 20, 731], fill=IOS)
    x += 30
    d.ellipse([x, 711, x + 20, 731], fill=AND)
    x += 38
    text(d, (x, 721), label, f, DIM, "lm")
    img.save(OUT / "card_title.png")


# ---------------------------------------------------------------- side by side
def ios_panel_size():
    return (376, 818)


def and_panel_size():
    # The emulator is 1080x3000; screenrecord pillarboxes it into 720x1280, so the
    # panel keeps the phone's real 0.36 aspect instead of the recording's 0.5625.
    return (294, 818)


def sbs_geometry():
    iw, ih = ios_panel_size()
    aw, ah = and_panel_size()
    gap = 110
    x0 = (W - (iw + aw + gap)) // 2
    top = 142
    return (x0, top, x0 + iw), (x0 + iw + gap, top, x0 + iw + gap + aw)


def phone_frame(size, radius=26):
    w, h = size
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # fill corners with background colour, punch a rounded hole
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=BG + (255,))
    hole = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(hole)
    hd.rounded_rectangle([3, 3, w - 4, h - 4], radius=radius - 2, fill=255)
    img.putalpha(Image.eval(hole, lambda v: 255 - v))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([1, 1, w - 2, h - 2], radius=radius - 1, outline=BORDER + (255,), width=3)
    return img


def sbs_bg():
    img = background()
    d = ImageDraw.Draw(img)
    header(d)
    ios_box, and_box = sbs_geometry()
    text(d, (ios_box[0], 118), "iOS · SwiftUI", bold(22), IOS, "lm")
    text(d, (and_box[0], 118), "Android · Compose", bold(22), AND, "lm")
    img.save(OUT / "sbs_bg.png")
    phone_frame(ios_panel_size()).save(OUT / "mask_ios.png")
    phone_frame(and_panel_size()).save(OUT / "mask_android.png")


def subtitle(slug, line):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    f = body(30)
    w = d.textlength(line, font=f)
    pad = 34
    x0 = (W - (w + pad * 2)) / 2
    y0 = 990
    rounded(d, [x0, y0, x0 + w + pad * 2, y0 + 56], 28, fill=(12, 16, 24, 220))
    text(d, (W / 2, y0 + 28), line, f, (222, 230, 242), "mm")
    img.save(OUT / f"sub_{slug}.png")


# ---------------------------------------------------------------- android only
def android_only_bg():
    img = background()
    d = ImageDraw.Draw(img)
    header(d)
    pw, ph = 294, 818
    px = 380
    py = 142
    text(d, (px, 118), "Android · Compose", bold(22), AND, "lm")
    tx = 800
    tag(d, tx, 150, "Android 独有", AND)
    text(d, (tx, 236), "端侧资料库与检索", bold(46), TEXT, "la")
    text(d, (tx, 302), "文档、向量与检索全部留在设备上", body(24), MUTED, "la")

    rows = [
        ("只存本机", "导入的 PDF / TXT / Markdown 不上传、不跨设备同步"),
        ("端侧嵌入", "模型加载 258 ms · 单条文本推理 89 ms"),
        ("按需检索", "发言前取相似度最高的 3 个片段注入 prompt"),
        ("可追溯", "发言卡片标注「参考了资料库的 2 个片段」"),
    ]
    y = 400
    for title, desc in rows:
        d.ellipse([tx + 2, y + 10, tx + 12, y + 20], fill=AND)
        text(d, (tx + 30, y), title, bold(27), TEXT, "la")
        text(d, (tx + 30, y + 40), desc, body(22), MUTED, "la")
        y += 112

    rounded(d, [tx, y + 8, tx + 1000, y + 96], 18, fill=(16, 22, 34), outline=(32, 41, 58), width=2)
    text(d, (tx + 26, y + 40), "检索阈值 0.45 · 无命中、超时或嵌入不可用时自动降级为无检索",
         body(21), DIM, "lm")
    img.save(OUT / "android_only_bg.png")


# ---------------------------------------------------------------- protocol card
def protocol_card():
    img = background()
    d = ImageDraw.Draw(img)
    cx = W // 2
    text(d, (cx, 150), "同一份协议，两个原生实现", bold(52), TEXT, "mm")
    text(d, (cx, 228), "docs/protocol.md 是唯一契约：客户端只实现协议，不互相依赖", body(26), MUTED, "mm")

    def box(x, y, w, h, head, sub, accent):
        rounded(d, [x, y, x + w, y + h], 22, fill=PANEL, outline=(36, 45, 62), width=2)
        d.ellipse([x + 26, y + 28, x + 38, y + 40], fill=accent)
        text(d, (x + 50, y + 34), head, bold(30), TEXT, "lm")
        text(d, (x + 26, y + 92), sub, body(21), MUTED, "la")

    box(180, 380, 380, 170, "iOS 客户端", "SwiftUI · RoundtableCore", IOS)
    box(1360, 380, 380, 170, "Android 客户端", "Compose · :core", AND)
    box(760, 356, 400, 218, "docs/protocol.md", "快照 + 事件流\nTurn 签发与提交\n结构化互评 · 引用校验", (150, 168, 196))

    # arrows
    def arrow(x1, x2, y):
        d.line([(x1, y), (x2, y)], fill=(70, 84, 110), width=4)
        d.polygon([(x2, y), (x2 - 16, y - 9), (x2 - 16, y + 9)], fill=(70, 84, 110))

    arrow(566, 754, 465)
    arrow(1166, 1354, 465)

    y = 640
    for label in [
        "快照恢复 + 事件流增量更新",
        "Turn 签发、提交、失败可重试",
        "第二轮必须引用对方观点，否则重试一次",
        "BYOK：密钥只在本机，请求直连 Provider",
    ]:
        text(d, (200, y), "·", bold(28), AND, "la")
        text(d, (224, y), label, body(25), (190, 202, 220), "la")
        y += 56

    text(d, (cx, 935), "两端各自跑完整的圆桌，服务端只承担协议与状态", body(22), DIM, "mm")
    img.save(OUT / "card_protocol.png")


# ---------------------------------------------------------------- end card
def end_card():
    img = background()
    d = ImageDraw.Draw(img)
    cx = W // 2
    text(d, (cx, 250), "Agent Roundtable v0.2.0", bold(28), AND, "mm")
    text(d, (cx, 340), "github.com/WangFugui6672/agent-roundtable", bold(52), TEXT, "mm")
    text(d, (cx, 430), "iOS + Android 原生客户端 · 同一协议 · BYOK 直连 Provider", body(28), MUTED, "mm")
    draw_line = [(cx - 360, 510), (cx + 360, 510)]
    d.line(draw_line, fill=(40, 50, 70), width=2)
    text(d, (cx, 570), "加载方式见仓库 README · 发布说明见 docs/releases/v0.2.0.md", body(24), (150, 165, 190), "mm")
    text(d, (cx, 700), "真实设备录屏 · 为时长做剪辑压缩 · 无配音", body(22), DIM, "mm")
    text(d, (cx, 760), "同一议题 · 两个独立圆桌 · 同一协议", body(22), DIM, "mm")
    img.save(OUT / "card_end.png")


if __name__ == "__main__":
    title_card()
    sbs_bg()
    android_only_bg()
    protocol_card()
    end_card()
    subtitle("round1", "两端各自进行第一轮发言：三位 Agent 直连 Provider，逐字流式生成")
    subtitle("round2", "同一套协议：第二轮必须结构化互评，并引用对方的一条观点")
    subtitle("library", "Android 独有：端侧资料库在发言前完成检索与注入")
    subtitle("protocol", "同一份协议文档，两个原生客户端各自实现")
    print("assets written to", OUT)
