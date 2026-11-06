#!/usr/bin/env python3
"""Generate macOS app icon concepts for AutoMount (1024pt grid, 4x supersampling)."""
import argparse, math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4
CANVAS = 1024

def px(v): return int(round(v * S))

THEMES = {
    'ocean': {'stops': [(0.0, (24, 56, 112)), (0.52, (14, 96, 150)), (1.0, (10, 158, 152))],
              'glow': (0.30, 0.16, 0.62, 64), 'rim': 54},
    'azure': {'stops': [(0.0, (30, 64, 175)), (0.5, (8, 145, 178)), (1.0, (14, 190, 190))],
              'glow': (0.28, 0.14, 0.58, 72), 'rim': 58},
    'night': {'stops': [(0.0, (13, 30, 66)), (0.55, (20, 62, 128)), (1.0, (12, 110, 120))],
              'glow': (0.32, 0.18, 0.55, 56), 'rim': 48},
}

def lin_gradient(size, stops, angle_deg=125.0):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    nx, ny = xx / (size - 1), yy / (size - 1)
    rad = math.radians(angle_deg)
    proj = nx * math.cos(rad) + ny * math.sin(rad)
    t = (proj - proj.min()) / max(proj.max() - proj.min(), 1e-6)
    arr = np.zeros((size, size, 3), dtype=np.float32)
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        c0 = np.array(c0, dtype=np.float32); c1 = np.array(c1, dtype=np.float32)
        seg = (t >= t0) & (t <= t1)
        f = np.clip((t - t0) / max(t1 - t0, 1e-6), 0, 1)
        arr[seg] = c0[None, :] + (c1 - c0)[None, :] * f[seg][:, None]
    return arr

def squircle_mask(size, inset, n=5.0):
    """Apple 图标网格：824/1024 内容区，圆角约 185。用圆角矩形才能避开 Tahoe 的灰底板。"""
    half = size / 2.0 - inset * S
    radius = half * (185.0 / 412.0)
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([size / 2 - half, size / 2 - half, size / 2 + half, size / 2 + half],
                        radius=radius, fill=255)
    return mask

def canvas(): return Image.new('RGBA', (px(CANVAS), px(CANVAS)), (0, 0, 0, 0))

def add_shadow(base, mask, offset=(0, 14), blur=26, alpha=105):
    sh = Image.new('RGBA', base.size, (0, 0, 0, 0))
    sh.paste(Image.new('RGBA', base.size, (0, 0, 0, alpha)), (0, 0), mask)
    sh = sh.filter(ImageFilter.GaussianBlur(px(blur)))
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -px(offset[1])))
    base.alpha_composite(sh)

def fnt(size):
    for p in ('/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/Helvetica.ttc'):
        try: return ImageFont.truetype(p, size)
        except Exception: pass
    return ImageFont.load_default()

def draw_background(theme='ocean'):
    cfg = THEMES[theme]
    img = canvas()
    size = img.size[0]
    mask = squircle_mask(size, 100, n=5.0)
    add_shadow(img, mask, offset=(0, 16), blur=30, alpha=100)

    # gradient computed at 1024 then upscaled (smooth)
    g = lin_gradient(1024, cfg['stops'], angle_deg=125)
    yy, xx = np.mgrid[0:1024, 0:1024].astype(np.float32)
    nx, ny = xx / 1023, yy / 1023
    # radial light
    gx, gy, gr, gs = cfg['glow']
    d = np.sqrt((nx - gx) ** 2 + (ny - gy) ** 2)
    glow = np.clip(1 - d / gr, 0, 1) ** 2 * (gs / 255.0)
    g = g * (1 - glow[:, :, None]) + 255 * glow[:, :, None]
    # smooth vignette
    dx, dy = nx - 0.5, ny - 0.5
    r = np.sqrt(dx ** 2 + dy ** 2) / 0.72
    vig = np.clip((r - 0.28) / 0.72, 0, 1) ** 1.6
    g = g * (1 - 0.20 * vig[:, :, None])
    # subtle noise
    rng = np.random.default_rng(7)
    noise = rng.normal(0, 1.1, (1024, 1024, 1))
    g = np.clip(g + noise, 0, 255)
    bg = Image.fromarray(g.astype(np.uint8), 'RGB').resize((size, size), Image.BICUBIC)
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    layer.paste(bg, (0, 0), mask)
    img.alpha_composite(layer)
    # inner rim light
    rim = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([px(101), px(101), px(923), px(923)], radius=px(179),
                                          outline=(255, 255, 255, cfg['rim']), width=px(2.2))
    img.alpha_composite(rim)
    return img

# ---------------- folder ----------------
def _arc(cx, cy, r, a0, a1, steps=10):
    pts = []
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def _bezier(p0, p1, p2, p3, steps=26):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt**3*p0[0] + 3*mt**2*t*p1[0] + 3*mt*t**2*p2[0] + t**3*p3[0]
        y = mt**3*p0[1] + 3*mt**2*t*p1[1] + 3*mt*t**2*p2[1] + t**3*p3[1]
        pts.append((x, y))
    return pts

def _folder_silhouette(left, right, top, bottom, tab_flat_end, curve_end, body_top,
                       r_tab=34, r_top=46, r_bottom=52):
    pts = []
    pts += _arc(left + r_tab, top + r_tab, r_tab, 180, 270)          # top-left tab corner
    pts.append((tab_flat_end, top))                                 # tab top edge
    pts += _bezier((tab_flat_end, top), (tab_flat_end + 34, top),
                   (curve_end - 34, body_top - 6), (curve_end, body_top))  # smooth hump
    pts.append((right - r_top, body_top))
    pts += _arc(right - r_top, body_top + r_top, r_top, 270, 360)   # right top corner
    pts.append((right, bottom - r_bottom))
    pts += _arc(right - r_bottom, bottom - r_bottom, r_bottom, 0, 90)  # bottom-right
    pts.append((left + r_bottom, bottom))
    pts += _arc(left + r_bottom, bottom - r_bottom, r_bottom, 90, 180)  # bottom-left
    pts.append((left, top + r_tab))
    return pts

def draw_folder(base):
    size = base.size[0]
    left, right = 270, 754
    top, bottom = 300, 712
    w = right - left
    body_top = top + 84
    tab_flat_end = left + w * 0.30
    curve_end = left + w * 0.48
    pts = _folder_silhouette(left, right, top, bottom, tab_flat_end, curve_end, body_top)
    poly = [(px(x), px(y)) for x, y in pts]

    # silhouette mask
    smask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(smask).polygon(poly, fill=255)
    add_shadow(base, smask, offset=(0, 20), blur=26, alpha=92)

    # back / outline gradient
    back_grad = lin_gradient(1024, [(0.0, (222, 239, 251)), (0.55, (200, 227, 245)), (1.0, (166, 202, 229))], angle_deg=90)
    back_grad = Image.fromarray(back_grad.astype(np.uint8), 'RGB').resize((size, size), Image.BICUBIC)
    bl = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    bl.paste(back_grad, (0, 0), smask)
    base.alpha_composite(bl)

    # front panel (inset rounded rect)
    inset = 18
    front = (left + inset, body_top + 34, right - inset, bottom - inset)
    fradius = 36
    fmask = Image.new('L', (size, size), 0)
    fd = ImageDraw.Draw(fmask)
    fd.rounded_rectangle([px(front[0]), px(front[1]), px(front[2]), px(front[3])], radius=px(fradius), fill=255)
    fg = lin_gradient(1024, [(0.0, (255, 255, 255)), (0.55, (249, 252, 255)), (1.0, (224, 240, 252))], angle_deg=90)
    fg = Image.fromarray(fg.astype(np.uint8), 'RGB').resize((size, size), Image.BICUBIC)
    fl = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    fl.paste(fg, (0, 0), fmask)
    base.alpha_composite(fl)

    # shadow cast by the folder lip onto the front panel top
    yy = np.mgrid[0:1024, 0:1024][0].astype(np.float32)
    band = np.clip(1 - (yy - front[1]) / 30.0, 0, 1) ** 1.5 * 34
    top_img = Image.fromarray(np.dstack([np.full((1024, 1024), 34, np.float32),
                                         np.full((1024, 1024), 76, np.float32),
                                         np.full((1024, 1024), 116, np.float32),
                                         band]).astype(np.uint8), 'RGBA')
    top_img = top_img.resize((size, size), Image.BICUBIC)
    top_img.putalpha(Image.composite(top_img.getchannel('A'), Image.new('L', (size, size), 0), fmask))
    base.alpha_composite(top_img)

    # subtle bottom shading inside front panel
    yy2 = np.mgrid[0:1024, 0:1024][0].astype(np.float32) / 1023.0
    shade = np.clip((yy2 - 0.60) / 0.40, 0, 1) ** 1.6 * 24
    sh_img = Image.fromarray(np.dstack([np.full((1024, 1024), 26, np.float32),
                                        np.full((1024, 1024), 62, np.float32),
                                        np.full((1024, 1024), 104, np.float32),
                                        shade]).astype(np.uint8), 'RGBA')
    sh_img = sh_img.resize((size, size), Image.BICUBIC)
    sh_img.putalpha(Image.composite(sh_img.getchannel('A'), Image.new('L', (size, size), 0), fmask))
    base.alpha_composite(sh_img)

    # front panel border
    border = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        [px(front[0]), px(front[1]), px(front[2]), px(front[3])], radius=px(fradius),
        outline=(40, 84, 124, 38), width=px(2))
    base.alpha_composite(border)

    # front panel top rim
    hi = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(hi).rounded_rectangle(
        [px(front[0] + 7), px(front[1] + 3), px(front[2] - 7), px(front[1] + 17)],
        radius=px(8), fill=(255, 255, 255, 115))
    hi.putalpha(Image.composite(hi.getchannel('A'), Image.new('L', (size, size), 0), fmask))
    base.alpha_composite(hi)

    # outline highlight along the outer top edge
    rim = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(rim).polygon(poly, outline=(255, 255, 255, 0))
    base.alpha_composite(rim)

    return dict(left=left, right=right, top=top, bottom=bottom, front_top=front[1],
                tab_right=curve_end, tab_bottom=body_top, front_panel=front)

def draw_arrow(base, p):
    size = base.size[0]
    cx = (p['left'] + p['right']) / 2
    top = p['front_top'] + 48
    shaft_w, shaft_h = 56, 96
    head_w, head_h = 150, 68
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([px(cx - shaft_w / 2), px(top), px(cx + shaft_w / 2), px(top + shaft_h)],
                        radius=px(18), fill=255)
    d.polygon([(px(cx - head_w / 2), px(top + shaft_h - 10)),
               (px(cx + head_w / 2), px(top + shaft_h - 10)),
               (px(cx), px(top + shaft_h + head_h))], fill=255)
    sh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    sh.paste(Image.new('RGBA', (size, size), (0, 40, 64, 80)), (0, 0), mask)
    sh = sh.filter(ImageFilter.GaussianBlur(px(8)))
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -px(6)))
    base.alpha_composite(sh)
    g = lin_gradient(1024, [(0.0, (26, 170, 176)), (1.0, (4, 86, 118))], angle_deg=90)
    g = Image.fromarray(g.astype(np.uint8), 'RGB').resize((size, size), Image.BICUBIC)
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    layer.paste(g, (0, 0), mask)
    base.alpha_composite(layer)

def draw_pin_badge(base, cx=736, cy=698, r=112):
    size = base.size[0]
    # shadow
    sm = Image.new('L', (size, size), 0)
    ImageDraw.Draw(sm).ellipse([px(cx - r - 6), px(cy - r - 2), px(cx + r + 6), px(cy + r + 10)], fill=255)
    add_shadow(base, sm, offset=(0, 10), blur=12, alpha=90)
    # white ring
    ring = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse([px(cx - r - 13), px(cy - r - 13), px(cx + r + 13), px(cy + r + 13)],
                                 fill=(255, 255, 255, 240))
    base.alpha_composite(ring)
    # badge gradient
    cm = Image.new('L', (size, size), 0)
    ImageDraw.Draw(cm).ellipse([px(cx - r), px(cy - r), px(cx + r), px(cy + r)], fill=255)
    g = lin_gradient(1024, [(0.0, (24, 186, 188)), (1.0, (4, 92, 120))], angle_deg=120)
    g = Image.fromarray(g.astype(np.uint8), 'RGB').resize((size, size), Image.BICUBIC)
    gl = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gl.paste(g, (0, 0), cm)
    base.alpha_composite(gl)
    # pin glyph
    pin_w = r * 1.04
    pin_h = r * 1.36
    pcx = cx
    ptop = cy - pin_h * 0.44
    cr = pin_w * 0.46
    ccy = ptop + cr
    gm = Image.new('L', (size, size), 0)
    gd = ImageDraw.Draw(gm)
    gd.ellipse([px(pcx - cr), px(ccy - cr), px(pcx + cr), px(ccy + cr)], fill=255)
    gd.polygon([(px(pcx - cr * 0.78), px(ccy + cr * 0.42)),
                (px(pcx + cr * 0.78), px(ccy + cr * 0.42)),
                (px(pcx), px(ptop + pin_h))], fill=255)
    gd.ellipse([px(pcx - cr * 0.37), px(ccy - cr * 0.37), px(pcx + cr * 0.37), px(ccy + cr * 0.37)], fill=0)
    white = Image.new('RGBA', (size, size), (255, 255, 255, 255))
    base.paste(white, (0, 0), gm)

def draw_wifi(base, cx=818, cy=306, scale=0.82, alpha=60):
    size = base.size[0]
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for r in (44, 88, 132):
        rr = r * scale
        d.arc([px(cx - rr), px(cy - rr), px(cx + rr), px(cy + rr)], 225, 315,
              fill=(255, 255, 255, alpha), width=px(14 * scale))
    d.ellipse([px(cx - 9 * scale), px(cy - 9 * scale), px(cx + 9 * scale), px(cy + 9 * scale)],
              fill=(255, 255, 255, alpha + 20))
    base.alpha_composite(layer)

def render(theme='ocean', variant='A'):
    img = draw_background(theme)
    p = draw_folder(img)
    if variant in ('A', 'B', 'C'):
        draw_arrow(img, p)
    if variant in ('A', 'B', 'D'):
        draw_pin_badge(img)
    if variant in ('A', 'D'):
        draw_wifi(img)
    return img.resize((CANVAS, CANVAS), Image.LANCZOS)

def sheet(path, items, cell=420, cols=3):
    pad, label_h = 26, 32
    rows = (len(items) + cols - 1) // cols
    W = cell * cols + pad * (cols + 1)
    H = (cell + label_h) * rows + pad * (rows + 1)
    out = Image.new('RGB', (W, H), (243, 246, 249))
    d = ImageDraw.Draw(out)
    font = fnt(20)
    for i, (title, im) in enumerate(items):
        col, row = i % cols, i // cols
        x = pad + col * (cell + pad)
        y = pad + row * (cell + label_h + pad)
        check = Image.new('RGB', (cell, cell), (255, 255, 255))
        cd = ImageDraw.Draw(check)
        step = 24
        for yy in range(0, cell, step):
            for xx in range(0, cell, step):
                if (xx // step + yy // step) % 2 == 0:
                    cd.rectangle([xx, yy, xx + step - 1, yy + step - 1], fill=(232, 238, 244))
        check.paste(im.resize((cell, cell), Image.LANCZOS), (0, 0), im.resize((cell, cell), Image.LANCZOS))
        out.paste(check, (x, y))
        d.text((x + 2, y + cell + 5), title, fill=(40, 50, 60), font=font)
    out.save(path)

def small_sheet(path, im, sizes=(16, 32, 48, 64, 128, 256)):
    pad = 26
    W = sum(sizes) + pad * (len(sizes) + 1)
    H = 276 + pad * 2
    out = Image.new('RGB', (W, H), (243, 246, 249))
    d = ImageDraw.Draw(out)
    font = fnt(15)
    x = pad
    for s in sizes:
        sm = im.resize((s, s), Image.LANCZOS)
        check = Image.new('RGB', (s, s), (255, 255, 255))
        cd = ImageDraw.Draw(check)
        step = max(4, s // 8)
        for yy in range(0, s, step):
            for xx in range(0, s, step):
                if (xx // step + yy // step) % 2 == 0:
                    cd.rectangle([xx, yy, xx + step - 1, yy + step - 1], fill=(232, 238, 244))
        check.paste(sm, (0, 0), sm)
        out.paste(check, (x, pad))
        d.text((x, pad + 256 + 4), f'{s}px', fill=(90, 100, 110), font=font)
        x += s + pad
    out.save(path)

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='preview')
    ap.add_argument('--final', default='', help='theme name to build AppIcon.icns')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # previews
    azure = render('azure', 'A')
    ocean = render('ocean', 'A')
    night = render('night', 'A')
    azure.save(os.path.join(args.out, 'appicon-1024.png'))
    ocean.save(os.path.join(args.out, 'alternative-ocean-1024.png'))
    night.save(os.path.join(args.out, 'alternative-night-1024.png'))
    small_sheet(os.path.join(args.out, 'small-sizes.png'), azure)

    # variants sheet (english labels for reliable fonts)
    items = [('A  all elements', azure),
             ('B  no wifi', render('azure', 'B')),
             ('C  no badge', render('azure', 'C')),
             ('D  no arrow', render('azure', 'D'))]
    sheet(os.path.join(args.out, 'variants.png'), items, cols=2)

    # dock mock
    W, H = 760, 220
    dock = Image.new('RGB', (W, H), (28, 32, 38))
    d = ImageDraw.Draw(dock)
    bar = Image.new('L', (W - 40, 150), 0)
    ImageDraw.Draw(bar).rounded_rectangle([0, 0, W - 41, 149], radius=28, fill=255)
    dock.paste(Image.new('RGB', (W - 40, 150), (52, 58, 66)), (20, 35), bar)
    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 14)
    x = 30
    for name, im in (('azure', azure), ('ocean', ocean), ('azure alt', render('night', 'A'))):
        sm = im.resize((112, 112), Image.LANCZOS)
        dock.paste(sm, (x, 54), sm)
        d.text((x, 176), name, fill=(200, 205, 210), font=font)
        x += 240
    dock.save(os.path.join(args.out, 'dock-mock.png'))

    if args.final:
        master = render(args.final, 'A')
        master.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), f'AppIcon-{args.final}-1024.png'))
        iconset = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'AppIcon.iconset')
        os.makedirs(iconset, exist_ok=True)
        mapping = {
            'icon_16x16.png': 16, 'icon_16x16@2x.png': 32,
            'icon_32x32.png': 32, 'icon_32x32@2x.png': 64,
            'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
            'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
            'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
        }
        for name, siz in mapping.items():
            master.resize((siz, siz), Image.LANCZOS).save(os.path.join(iconset, name))
        import subprocess
        out_icns = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'AppIcon.icns')
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', out_icns], check=True)
        print('wrote', out_icns)
