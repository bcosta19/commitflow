#!/usr/bin/env python3
"""Renders docs/demo.gif from the real `commitflow --demo` output.

The binary runs in a pty; its ANSI stream is split into frames (every frame ends with the
cursor-up that redraws it in place), parsed, and drawn with Pillow. Block glyphs are drawn as
rectangles so the result does not depend on the font's coverage of U+2580..U+25A0.

    zig build -Doptimize=ReleaseSafe
    python3 scripts/make-demo-gif.py            # needs Pillow and `script` (util-linux)
"""
import os, re, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out", "bin", "commitflow")
OUT = os.path.join(ROOT, "docs", "demo.gif")
FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
FONT_BOLD = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf"

COLS, LINES = 120, 22          # terminal width; frame height (render.line_count)
FPS_IN, KEEP_EVERY = 30, 2     # keep every 2nd frame -> 15 fps
HOLD_MS = 3000                 # pause on the final frame before looping
END_DATE = "2026-11-07"        # fixed so the picture is reproducible
BG, FG = (13, 17, 23), (230, 237, 243)
FONT_PX, PAD = 15, 14

def capture():
    cmd = (f"stty cols {COLS} rows {LINES + 2}; env -u NO_COLOR {BIN} --demo "
           f"--end {END_DATE} --duration 6 --fps {FPS_IN}")
    with tempfile.NamedTemporaryFile() as tmp:
        subprocess.run(["script", "-qec", cmd, tmp.name], stdout=subprocess.DEVNULL, check=True)
        return open(tmp.name, "rb").read().decode("utf-8", "replace")

SGR = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")

def parse_frame(chunk):
    """-> list of lines, each a list of (char, fg, bold)."""
    lines, fg, bold = [], FG, False
    for raw in chunk.replace("\r", "").split("\n"):
        row, pos = [], 0
        for m in SGR.finditer(raw):
            row += [(c, fg, bold) for c in raw[pos:m.start()]]
            pos = m.end()
            params, final = m.group(1), m.group(2)
            if final != "m":
                continue
            p = params.split(";") if params else ["0"]
            if p[0] == "0":
                fg, bold = FG, False
            elif p[0] == "1":
                bold = True
            elif p[:2] == ["38", "2"]:
                fg = tuple(int(x) for x in p[2:5])
        row += [(c, fg, bold) for c in raw[pos:]]
        lines.append(row)
    return lines

def split_frames(stream):
    stream = re.sub(r"Script (started|done) on [^\n]*\n?", "", stream)  # util-linux banner
    parts = stream.split(f"\x1b[{LINES}A")
    frames = [parse_frame(p) for p in parts]
    frames = [f[:LINES] for f in frames]
    return [f for f in frames if len(f) == LINES]

def main():
    frames = split_frames(capture())
    if len(frames) < 10:
        sys.exit(f"only {len(frames)} frames captured; is {BIN} built?")
    font, bold = ImageFont.truetype(FONT, FONT_PX), ImageFont.truetype(FONT_BOLD, FONT_PX)
    cw = round(font.getlength("M"))
    ch = round(FONT_PX * 1.35)
    width = max(len(r) for f in frames for r in f)
    W, H = width * cw + 2 * PAD, LINES * ch + 2 * PAD

    def draw(frame):
        img = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(img)
        for y, row in enumerate(frame):
            for x, (c, fg, b) in enumerate(row):
                if c == " ":
                    continue
                x0, y0 = PAD + x * cw, PAD + y * ch
                if c == "█":
                    d.rectangle([x0, y0, x0 + cw - 1, y0 + ch - 1], fill=fg)
                elif "\u2581" <= c <= "\u2587":                 # lower eighth blocks
                    h = round(ch * (ord(c) - 0x2580) / 8)
                    d.rectangle([x0, y0 + ch - h, x0 + cw - 1, y0 + ch - 1], fill=fg)
                elif c == "■":
                    s = round(cw * 1.0)
                    cx, cy = x0 + cw // 2, y0 + ch // 2
                    d.rectangle([cx - s // 2, cy - s // 2, cx + s // 2 - 1, cy + s // 2 - 1], fill=fg)
                else:
                    d.text((x0, y0), c, font=bold if b else font, fill=fg)
        return img

    keep = frames[::KEEP_EVERY]
    if keep[-1] is not frames[-1]:
        keep.append(frames[-1])
    imgs = [draw(f) for f in keep]

    # One shared palette for every frame so colours never flicker between frames. Text
    # anti-aliasing produces several hundred distinct colours, so build it from a montage of
    # sampled frames with median cut.
    sample = imgs[:: max(1, len(imgs) // 12)] + [imgs[-1]]
    montage = Image.new("RGB", (W, H * len(sample)))
    for i, im in enumerate(sample):
        montage.paste(im, (0, i * H))
    pal = montage.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    frames_p = [im.quantize(palette=pal, dither=Image.Dither.NONE) for im in imgs]

    delay = int(1000 / FPS_IN * KEEP_EVERY)
    durations = [delay] * (len(frames_p) - 1) + [HOLD_MS]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    frames_p[0].save(OUT, save_all=True, append_images=frames_p[1:], duration=durations,
                     loop=0, optimize=True, disposal=1)
    print(f"{OUT}: {len(frames_p)} frames, {W}x{H}px, {os.path.getsize(OUT) / 1024:.0f} KiB, "
          "256-colour shared palette")

if __name__ == "__main__":
    main()
