"""Draws the Multiemu icon (three stacked phones = several emulators) -> icon.png, AppIcon.icns."""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 2048  # drawn at 2x, scaled down for smooth edges

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# background: dark green tile with a soft top glow
tile = Image.new("RGBA", (S, S))
td = ImageDraw.Draw(tile)
for y in range(S):
    td.line([(0, y), (S, y)], fill=lerp((22, 58, 46, 255), (9, 22, 18, 255), y / S))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((80, 80, S - 80, S - 80), radius=440, fill=255)
im.paste(tile, (0, 0), mask)

def phone(cx, cy, w, h, body, screen, shadow=True):
    global im
    x0, y0, x1, y1 = cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2
    if shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((x0 + 20, y0 + 50, x1 + 20, y1 + 50), radius=130, fill=(0, 0, 0, 120))
        im = Image.alpha_composite(im, sh.filter(ImageFilter.GaussianBlur(40)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((x0, y0, x1, y1), radius=130, fill=body)
    d.rounded_rectangle((x0 + 46, y0 + 110, x1 - 46, y1 - 110), radius=60, fill=screen)
    d.rounded_rectangle((cx - 70, y0 + 48, cx + 70, y0 + 72), radius=12, fill=screen)

phone(700, 1080, 640, 1180, (40, 92, 74, 255), (24, 60, 48, 255))
phone(1024, 1000, 640, 1180, (70, 150, 118, 255), (30, 84, 66, 255))
phone(1348, 1080, 640, 1180, (236, 244, 240, 255), (18, 36, 30, 255))
d = ImageDraw.Draw(im)
# play triangle on the front screen
cx, cy = 1348, 1080
d.polygon([(cx - 110, cy - 150), (cx - 110, cy + 150), (cx + 150, cy)], fill=(43, 211, 140, 255))

out = im.resize((1024, 1024), Image.LANCZOS)
out.save(os.path.join(HERE, "icon.png"))
with tempfile.TemporaryDirectory() as t:
    iset = os.path.join(t, "AppIcon.iconset"); os.mkdir(iset)
    for s in (16, 32, 128, 256, 512):
        out.resize((s, s), Image.LANCZOS).save(f"{iset}/icon_{s}x{s}.png")
        out.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iset}/icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iset, "-o", os.path.join(HERE, "AppIcon.icns")], check=True)
print("icon.png, AppIcon.icns")
