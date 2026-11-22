#!/usr/bin/env python3
"""ClipShelf 应用图标 · 两版方案

A：叠放的剪贴纸（具象）
B：时间轴列表 + 放大镜（抽象）

统一按 macOS Big Sur 之后的规矩来：
  · 1024 画布，824×824 超椭圆（superellipse n=5），四周留 100pt
  · 竖向渐变底 + 顶部柔光 + 内描边高光 + 底部内阴影
  · 不用文字，图形克制，16pt 下仍可辨认

用法：python3 design/icon.py        # 输出 docs/icon-a.png / docs/icon-b.png
      python3 design/icon.py board  # 额外输出对比板 docs/icon-preview.png
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 3                      # 超采样倍率
FINAL = 1024
S = FINAL * SS
PAD = 100                   # 外留白
BODY = FINAL - PAD * 2      # 824


def sc(v):
    return int(round(v * SS))


def squircle_mask(size, n=5.0, steps=1440, inset=0):
    """超椭圆（Apple 的连续圆角近似），返回 L 通道遮罩"""
    a = (size - inset * 2) / 2.0
    cx = cy = size / 2.0
    pts = []
    for i in range(steps):
        t = 2.0 * 3.141592653589793 * i / steps
        c, s = _cos(t), _sin(t)
        x = cx + a * _sgn(c) * abs(c) ** (2.0 / n)
        y = cy + a * _sgn(s) * abs(s) ** (2.0 / n)
        pts.append((x, y))
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def _cos(t):
    return __import__("math").cos(t)


def _sin(t):
    return __import__("math").sin(t)


def _sgn(v):
    return -1.0 if v < 0 else 1.0


def vgrad(size, top, bottom):
    img = Image.new("RGB", (1, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        k = y / max(1, size - 1)
        d.point((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)))
    return img.resize((size, size), Image.BILINEAR)


def radial_glow(size, center, radius, color, alpha):
    """柔光斑：径向渐变，用于顶部高光"""
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)
    steps = 160
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(alpha * (1 - i / steps) ** 1.6)
        if a <= 0:
            continue
        d.ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=a)
    layer = layer.filter(ImageFilter.GaussianBlur(size * 0.02))
    tint = Image.new("RGBA", (size, size), color + (0,))
    tint.putalpha(layer)
    return tint


def ground(top, bottom, glow=0.55, full_bleed=False):
    """底板：渐变 + 顶光 + 内高光 + 底部内阴影

    full_bleed=True 时铺满整个画布、四角不透明。
    macOS 26 只给「全不透明」的图标自动裁圆角；带透明边角的会被塞进一层灰底板。
    """
    base = vgrad(S, top, bottom).convert("RGBA")
    if glow:
        base.alpha_composite(radial_glow(S, (S * 0.42, S * 0.10), S * 0.62, (255, 255, 255), int(70 * glow)))

    mask = squircle_mask(S, inset=sc(PAD))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask if not full_bleed else Image.new("L", (S, S), 255))

    if full_bleed:
        # 满幅模式：系统会裁掉圆角，这里改成底部整体压暗一点，保留纵深感
        shade = Image.new("L", (S, S), 0)
        d = ImageDraw.Draw(shade)
        d.ellipse([-S * 0.35, S * 0.66, S * 1.35, S * 1.6], fill=110)
        shade = shade.filter(ImageFilter.GaussianBlur(S * 0.07))
        dark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        dark.putalpha(shade.point(lambda v: int(v * 0.5)))
        out.alpha_composite(dark)
        return out

    # 顶部内高光：沿轮廓的一圈白色细边，只保留上半
    ring = squircle_mask(S, inset=sc(PAD))
    inner = squircle_mask(S, inset=sc(PAD) + sc(3))
    edge = Image.composite(ring, Image.new("L", (S, S), 0), inner.point(lambda v: 255 - v))
    edge = edge.filter(ImageFilter.GaussianBlur(sc(0.6)))
    hi = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    hi.putalpha(edge.point(lambda v: int(v * 0.30)))
    out.alpha_composite(hi)

    # 底部内阴影，给一点厚度
    shade = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(shade)
    d.ellipse([-S * 0.3, S * 0.62, S * 1.3, S * 1.45], fill=120)
    shade = shade.filter(ImageFilter.GaussianBlur(S * 0.06))
    shade = Image.composite(shade, Image.new("L", (S, S), 0), mask)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(shade.point(lambda v: int(v * 0.55)))
    out.alpha_composite(shadow)
    return out


def _union_bbox(layers):
    box = None
    for layer in layers:
        b = layer.getbbox()
        if b is None:
            continue
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]),
                                     max(box[2], b[2]), max(box[3], b[3]))
    return box


def _scale_pair(struct, shadow, k):
    """按公共包围盒整体缩放两层，保持相对位置"""
    box = _union_bbox([struct, shadow])
    if box is None:
        return struct, shadow
    w, h = box[2] - box[0], box[3] - box[1]
    nw, nh = max(1, int(w * k)), max(1, int(h * k))
    x, y = (S - nw) // 2, (S - nh) // 2
    a = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    b = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    a.paste(struct.crop(box).resize((nw, nh), Image.LANCZOS), (x, y))
    b.paste(shadow.crop(box).resize((nw, nh), Image.LANCZOS), (x, y))
    return a, b


def _shift(layer, dx, dy):
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.paste(layer, (dx, dy))
    return out


def soft_shadow(size, box, radius, alpha=90, blur=None, dy=0):
    """给卡片类元素加投影"""
    blur = blur or sc(26)
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([box[0], box[1] + dy, box[2], box[3] + dy], radius=radius, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sh.putalpha(layer)
    return sh


# ---------------------------------------------------------------- A 叠放的剪贴纸

def icon_a(full_bleed=False):
    """叠放的剪贴纸：三张纸，前一张居中，后两张在左右下方对称露出一点

    结构（纸/夹子/文字条）与投影分两层；居中按结构层包围盒算，
    软投影不参与，否则包围盒被撑大、纸叠会显得偏高。
    """
    out = ground((92, 132, 255), (106, 66, 226), full_bleed=full_bleed)

    struct = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(struct)

    w, h, r = sc(340), sc(402), sc(44)
    dx, dy = sc(46), sc(52)
    clip_above = sc(16)
    front = (sc(362), sc(300))

    # 后两张：向右下单向错开，读起来才像「一叠」；两层级差用于区分
    for step, tint, edge in [((dx, dy), (203, 213, 246), (172, 186, 234)),
                             ((dx // 2, dy // 2), (231, 238, 255), (203, 214, 247))]:
        box = [front[0] + step[0], front[1] + step[1],
               front[0] + step[0] + w, front[1] + step[1] + h]
        shadow.alpha_composite(soft_shadow(S, box, r, alpha=54, dy=sc(8), blur=sc(18)))
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        ld.rounded_rectangle(box, radius=r, fill=tint + (255,))
        ld.rounded_rectangle(box, radius=r, outline=edge + (255,), width=sc(2))
        struct.alpha_composite(layer)

    box = [front[0], front[1], front[0] + w, front[1] + h]
    shadow.alpha_composite(soft_shadow(S, box, r, alpha=72, dy=sc(12), blur=sc(24)))

    # 纸面：白到淡蓝，避免死白
    card = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paper = vgrad(S, (255, 255, 255), (226, 233, 255)).convert("RGBA")
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=r, fill=255)
    card.paste(paper, (0, 0), mask)
    struct.alpha_composite(card)

    # 纸边：极细的一圈描边，增加实体感
    d.rounded_rectangle(box, radius=r, outline=(120, 138, 214, 70), width=sc(2))

    # 顶部夹子
    clip_w, clip_h = sc(128), sc(38)
    clip_center_x = front[0] + w // 2
    clip = [clip_center_x - clip_w // 2, front[1] - clip_above,
            clip_center_x + clip_w // 2, front[1] - clip_above + clip_h]
    d.rounded_rectangle(clip, radius=sc(17), fill=(74, 92, 240, 255))
    d.rounded_rectangle([clip[0] + sc(28), clip[1] + sc(11),
                         clip[2] - sc(28), clip[1] + sc(18)],
                        radius=sc(4), fill=(255, 255, 255, 150))

    # 正文文字条
    x0 = box[0] + sc(46)
    y = front[1] + sc(96)
    for ww, color in [(sc(214), (175, 190, 240)), (sc(248), (175, 190, 240)),
                      (sc(196), (198, 210, 246)), (sc(248), (198, 210, 246)),
                      (sc(132), (214, 224, 250))]:
        d.rounded_rectangle([x0, y, x0 + ww, y + sc(24)], radius=sc(12), fill=color + (255,))
        y += sc(52)

    # 按结构包围盒居中（横向严格对称；纵向因投影在下方，略上移一点）
    # 满幅模式：画布变大，纸叠按同比例放大，视觉分量才和圆角版一致
    if full_bleed:
        struct, shadow = _scale_pair(struct, shadow, 1.18)

    bbox = struct.getbbox()
    gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    dx = (S - gw) // 2 - bbox[0]
    dy = (S - gh) // 2 - bbox[1] - sc(5) - (sc(8) if full_bleed else 0)
    struct = _shift(struct, dx, dy)
    shadow = _shift(shadow, dx, dy)

    out.alpha_composite(shadow)
    out.alpha_composite(struct)
    return out


def icon_b():
    """时间轴列表：深色玻璃面板 + 薄荷色时间轴 + 琥珀色高亮行 + 放大镜"""
    out = ground((72, 226, 198), (9, 118, 136))
    d = ImageDraw.Draw(out)

    cx = S // 2
    pw, ph, r = sc(438), sc(448), sc(60)
    panel = (cx - pw // 2, sc(288), cx + pw // 2, sc(288) + ph)

    out.alpha_composite(soft_shadow(S, panel, r, alpha=95, dy=sc(16), blur=sc(30)))

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle(panel, radius=r, fill=(7, 38, 44, 214))
    ld.rounded_rectangle(panel, radius=r, outline=(255, 255, 255, 64), width=sc(3))
    out.alpha_composite(layer)

    # 左侧时间轴
    axis_x = panel[0] + sc(78)
    first_y = panel[1] + sc(92)
    gap = sc(102)
    d.line([axis_x, first_y, axis_x, first_y + gap * 2],
           fill=(120, 244, 216, 110), width=sc(5))

    for i, ww in enumerate([sc(214), sc(168), sc(198)]):
        y = first_y + gap * i
        d.ellipse([axis_x - sc(14), y - sc(14), axis_x + sc(14), y + sc(14)],
                  fill=(140, 246, 220, 255))
        bx = axis_x + sc(42)
        if i == 1:
            d.rounded_rectangle([bx - sc(12), y - sc(20), bx + ww + sc(12), y + sc(20)],
                                radius=sc(15), fill=(255, 198, 92, 55))
            d.rounded_rectangle([bx, y - sc(13), bx + ww, y + sc(13)],
                                radius=sc(13), fill=(255, 198, 92, 255))
        else:
            d.rounded_rectangle([bx, y - sc(13), bx + ww, y + sc(13)],
                                radius=sc(13), fill=(236, 255, 250, 225))

    # 右下放大镜
    mg_cx, mg_cy = panel[2] - sc(92), panel[3] - sc(88)
    mg_r = sc(56)
    lens = [mg_cx - mg_r, mg_cy - mg_r, mg_cx + mg_r, mg_cy + mg_r]
    out.alpha_composite(soft_shadow(S, lens, mg_r, alpha=90, dy=sc(8), blur=sc(18)))
    d.ellipse(lens, fill=(255, 255, 255, 245))
    d.ellipse([lens[0] + sc(13), lens[1] + sc(13), lens[2] - sc(13), lens[3] - sc(13)],
              outline=(11, 126, 146, 255), width=sc(10))
    d.line([mg_cx + mg_r * 0.60, mg_cy + mg_r * 0.60,
            mg_cx + mg_r * 1.12, mg_cy + mg_r * 1.12],
           fill=(11, 126, 146, 255), width=sc(13))
    return out


def save(icon, path):
    final = Image.new("RGBA", (FINAL, FINAL), (0, 0, 0, 0))
    final.alpha_composite(icon.resize((FINAL, FINAL), Image.LANCZOS))
    final.save(path)
    return final


# ---------------------------------------------------------------- 对比板

def board(a, b, path):
    W, H = 1560, 1040
    canvas = Image.new("RGB", (W, H), (24, 25, 29))
    d = ImageDraw.Draw(canvas)
    def load(size):
        from PIL import ImageFont
        for path, index in [("/System/Library/Fonts/PingFang.ttc", 2),
                            ("/System/Library/Fonts/PingFang.ttc", 0),
                            ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0)]:
            try:
                return ImageFont.truetype(path, size, index=index)
            except Exception:
                continue
        return ImageFont.load_default(size=size)

    try:
        f_big, f_mid, f_small = load(30), load(20), load(15)
    except Exception:
        f_big = f_mid = f_small = None

    half = W // 2
    d.rectangle([0, 0, half, H], fill=(22, 23, 27))
    d.rectangle([half, 0, W, H], fill=(244, 245, 248))

    def put(img, xy, size, shadow=True):
        im = img.resize((size, size), Image.LANCZOS)
        x, y = xy
        if shadow:
            sh = Image.new("RGBA", (size + 96, size + 96), (0, 0, 0, 0))
            ImageDraw.Draw(sh).rounded_rectangle(
                [48, 60, size + 48, size + 44], radius=int(size * 0.23), fill=(0, 0, 0, 80))
            sh = sh.filter(ImageFilter.GaussianBlur(18))
            canvas.paste(sh, (x - 48, y - 48), sh)
        canvas.paste(im, (x, y), im)

    for idx, (icon, tag, name, note) in enumerate([
        (a, "A", "叠放的剪贴纸", "纸=内容，叠=历史；小尺寸最稳"),
        (b, "B", "时间轴 + 放大镜", "深色玻璃 + 时间轴，呼应面板质感"),
    ]):
        dark = idx == 0
        ox = 70 + (idx % 2) * 0
        col_x = 92 if dark else half + 92
        col_x2 = 92 + half * idx if idx == 0 else half + 92
        base_x = 92 if idx == 0 else half + 92
        fg = (236, 237, 241) if dark else (34, 36, 42)
        dim = (140, 143, 152) if dark else (118, 121, 130)

        put(icon, (base_x, 92), 320)
        if f_big:
            d.text((base_x, 452), f"{tag}  {name}", fill=fg, font=f_big)
            d.text((base_x, 494), note, fill=dim, font=f_mid)
            d.text((base_x, 534), "16 / 24 / 32 / 64 / 128 pt", fill=dim, font=f_small)
        for j, sz in enumerate([128, 64, 32, 24, 16]):
            put(icon, (base_x + j * 136, 580), sz, shadow=False)

        # 应用名标注
        if f_mid:
            d.text((base_x, 760), "ClipShelf.app", fill=dim, font=f_mid)

    # 底部：Dock 条
    dock_y = 840
    d.rounded_rectangle([120, dock_y, W - 120, dock_y + 150], radius=36, fill=(255, 255, 255, 22))
    for i, icon in enumerate([a, b, a, b]):
        put(icon, (300 + i * 260, dock_y + 27), 96)

    canvas.save(path)


def export_icns(src_png, out_icns):
    """导出完整 iconset（16–1024，含 @2x）并打成 .icns"""
    import shutil
    import subprocess

    iconset = "build/AppIcon.iconset"
    shutil.rmtree("build", ignore_errors=True)
    os.makedirs(iconset, exist_ok=True)

    im = Image.open(src_png).convert("RGBA")
    for px, name in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                     (1024, "icon_512x512@2x")]:
        im.resize((px, px), Image.LANCZOS).save(f"{iconset}/{name}.png")

    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)
    shutil.rmtree("build", ignore_errors=True)
    print(f"已写入 {out_icns}")


if __name__ == "__main__":
    os.makedirs("docs", exist_ok=True)
    # 交付用满幅不透明版本：macOS 26 会给它自动裁圆角，带透明边角反而会被加底板
    a = save(icon_a(full_bleed=True), "docs/icon-a.png")
    print("已写入 docs/icon-a.png")

    if "icns" in sys.argv:
        export_icns("docs/icon-a.png", "AppIcon.icns")

    if "board" in sys.argv:
        # 对比板只用于挑方案，属设计阶段产物，不进仓库
        b = save(icon_b(), "docs/icon-b.png")
        board(a, b, "docs/icon-preview.png")
        print("已写入 docs/icon-b.png, docs/icon-preview.png")
