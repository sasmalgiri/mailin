#!/usr/bin/env python3
"""Generate App Store screenshots with promotional text overlays."""

from PIL import Image, ImageDraw, ImageFont
import os

# App Store required sizes
IPHONE_SIZE = (1290, 2796)  # iPhone 6.7"
IPAD_SIZE = (2048, 2732)    # iPad Pro 13"
MAC_SIZE = (2880, 1800)     # macOS Retina

# Paths
DESKTOP = os.path.expanduser("~/Desktop")
OUTPUT = os.path.expanduser("~/Downloads/mailin/Screenshots/AppStore_Final")
os.makedirs(OUTPUT, exist_ok=True)

# Colors
GRAD_BLUE = (59, 130, 246)
GRAD_PURPLE = (147, 51, 234)
WHITE = (255, 255, 255)

NBSP = " "  # macOS uses narrow no-break space in screenshot filenames


def find_font(size):
    paths = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except:
                continue
    return ImageFont.load_default()


def find_bold_font(size):
    paths = [
        "/System/Library/Fonts/SFCompact.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                f = ImageFont.truetype(p, size)
                return f
            except:
                continue
    return find_font(size)


def draw_gradient(img, c1, c2):
    draw = ImageDraw.Draw(img)
    w, h = img.size
    for y in range(h):
        r = y / h
        color = tuple(int(c1[i] * (1 - r) + c2[i] * r) for i in range(3))
        draw.line([(0, y), (w, y)], fill=color)


def create_screenshot(src_path, title, subtitle, out_path, canvas_size, corner_r=40):
    cw, ch = canvas_size
    canvas = Image.new("RGBA", (cw, ch))
    draw_gradient(canvas, GRAD_BLUE, GRAD_PURPLE)

    text_h = int(ch * 0.17)
    margin = int(cw * 0.035)

    # Load screenshot
    shot = Image.open(src_path).convert("RGBA")
    sw, sh = shot.size

    # Fit into available space
    avail_w = cw - margin * 2
    avail_h = ch - text_h - int(margin * 1.5)
    scale = min(avail_w / sw, avail_h / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    shot = shot.resize((nw, nh), Image.LANCZOS)

    # Rounded mask
    mask = Image.new("L", (nw, nh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), (nw - 1, nh - 1)], radius=corner_r, fill=255)

    # Shadow
    shadow = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    shadow_block = Image.new("RGBA", (nw, nh), (0, 0, 0, 50))
    sx = (cw - nw) // 2 + 6
    sy = text_h + (avail_h - nh) // 2 + 6
    shadow.paste(shadow_block, (sx, sy), mask)
    canvas = Image.alpha_composite(canvas, shadow)

    # Paste screenshot
    x = (cw - nw) // 2
    y = text_h + (avail_h - nh) // 2
    canvas.paste(shot, (x, y), mask)

    # Text
    draw = ImageDraw.Draw(canvas)
    title_font = find_bold_font(int(cw * 0.052))
    sub_font = find_font(int(cw * 0.028))

    # Center title
    bb = draw.textbbox((0, 0), title, font=title_font)
    tw = bb[2] - bb[0]
    th = bb[3] - bb[1]
    tx = (cw - tw) // 2
    ty = int(text_h * 0.22)
    draw.text((tx, ty), title, fill=WHITE, font=title_font)

    # Center subtitle
    bb2 = draw.textbbox((0, 0), subtitle, font=sub_font)
    sw2 = bb2[2] - bb2[0]
    sx2 = (cw - sw2) // 2
    sy2 = ty + th + int(text_h * 0.1)
    draw.text((sx2, sy2), subtitle, fill=(255, 255, 255, 210), font=sub_font)

    canvas.convert("RGB").save(out_path, "PNG")
    print(f"  OK: {os.path.basename(out_path)} ({cw}x{ch})")


def resolve(filename):
    """Try both regular space and narrow no-break space versions."""
    path = os.path.join(DESKTOP, filename)
    if os.path.exists(path):
        return path
    alt = filename.replace(" AM", f"{NBSP}AM").replace(" PM", f"{NBSP}PM")
    path2 = os.path.join(DESKTOP, alt)
    if os.path.exists(path2):
        return path2
    return None


# ============================================================
print("\n=== iPhone 6.7\" (1290x2796) ===")
for item in [
    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-05-06 at 01.31.51.png",
     "Smart Email Analysis", "Search, filter & organize your email archive",
     "iPhone_01_EmailList.png"),

    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-05-06 at 01.36.03.png",
     "AI-Powered Insights", "On-device Apple Intelligence — 100% private",
     "iPhone_02_AIAssistant.png"),

    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-05-06 at 01.30.53.png",
     "Email Analytics", "Sentiment, priority & communication patterns",
     "iPhone_03_Analytics.png"),

    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-05-06 at 01.32.16.png",
     "Forensic Mode", "Evidence tagging & chain of custody",
     "iPhone_04_Forensic.png"),

    ("Simulator Screenshot - iPhone 17 Pro Max - 2026-05-06 at 01.35.16.png",
     "Reply Tracking", "Visualize communication patterns at a glance",
     "iPhone_05_ReplyFrequency.png"),
]:
    p = resolve(item[0])
    if p:
        create_screenshot(p, item[1], item[2], os.path.join(OUTPUT, item[3]), IPHONE_SIZE, 50)
    else:
        print(f"  MISSING: {item[0]}")

# ============================================================
print("\n=== iPad Pro 13\" (2048x2732) ===")
for item in [
    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.24.10.png",
     "Powerful Email Archive Viewer", "Import, search & analyze thousands of emails",
     "iPad_01_EmailList.png"),

    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.24.55.png",
     "AI Email Assistant", "Ask anything — powered by Apple Intelligence",
     "iPad_02_AIAssistant.png"),

    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.25.06.png",
     "Forensic Investigation", "Evidence tagging, hash verification & audit logs",
     "iPad_03_Forensic.png"),

    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.25.19.png",
     "Predictive Coding", "AI-assisted document review & relevance scoring",
     "iPad_04_PredictiveCoding.png"),

    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.28.22.png",
     "Customizable Roles", "Forensic, legal, IT, journalist & personal modes",
     "iPad_05_Settings.png"),

    ("Simulator Screenshot - iPad Pro 13-inch (M5) - 2026-05-06 at 01.24.40.png",
     "Reply Analytics", "Visualize your communication frequency",
     "iPad_06_ReplyFrequency.png"),
]:
    p = resolve(item[0])
    if p:
        create_screenshot(p, item[1], item[2], os.path.join(OUTPUT, item[3]), IPAD_SIZE, 30)
    else:
        print(f"  MISSING: {item[0]}")

# ============================================================
print("\n=== macOS (2880x1800) ===")
for item in [
    ("Screenshot 2026-05-03 at 10.55.42 AM.png",
     "Welcome to mailin", "Import .mbox, .eml, .msg, .pst & more",
     "Mac_01_Welcome.png"),

    ("Screenshot 2026-05-03 at 10.59.37 AM.png",
     "3-Panel Email Viewer", "Sidebar, email list & full message detail",
     "Mac_02_EmailList.png"),

    ("Screenshot 2026-05-03 at 10.59.58 AM.png",
     "Email Detail View", "Headers, body, attachments & forensic metadata",
     "Mac_03_EmailDetail.png"),

    ("Screenshot 2026-05-03 at 11.05.15 AM.png",
     "Email Analytics", "Sentiment, volume trends & priority breakdown",
     "Mac_04_Analytics.png"),

    ("Screenshot 2026-05-03 at 11.02.54 AM.png",
     "Raw RFC 822 Source", "Full headers for forensic & compliance analysis",
     "Mac_05_RawSource.png"),
]:
    p = resolve(item[0])
    if p:
        create_screenshot(p, item[1], item[2], os.path.join(OUTPUT, item[3]), MAC_SIZE, 20)
    else:
        print(f"  MISSING: {item[0]}")

print(f"\n=== DONE === {len(os.listdir(OUTPUT))} screenshots in {OUTPUT}")
