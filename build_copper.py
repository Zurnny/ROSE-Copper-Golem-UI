"""Build the 'Copper Golem UI' theme from the Steampunk UI theme by recolouring
every colour and every piece of art:
  brass / gold trims      -> copper
  copper 'selected' parts -> purple (the models' banners)
  dark iron panels        -> cool gunmetal grey
  scrollbars              -> gold (taken from the Ivory Golem scheme)
Text, gauge fills, chat colour choices and element colours stay as they are."""
import os, re, shutil, struct, sys, colorsys
import numpy as np
from PIL import Image
sys.path.insert(0, '/tmp/claude-0/tools'); sys.path.insert(0, '/home/claude/cursors')
from curtool import read_cur
SRC = '/home/claude/steampunk/Steampunk UI'
DST = '/home/claude/copper/Copper Golem UI'

# ---------------------------------------------------------------- colour map
def classify(h, s, v):
    if 28 <= h <= 58 and s > 0.28 and v > 0.38: return 'brass'
    if 12 <= h < 28 and s > 0.38 and v > 0.30: return 'copper'
    if v <= 0.38 and s < 0.75 and (h <= 60 or s < 0.15): return 'dark'
    return None
def map_hsv(h, s, v, mode='normal'):
    k = classify(h, s, v)
    if mode == 'gold':
        if k in ('brass', 'copper'): return 42, min(0.75, max(s, 0.5)), min(1, v * 1.1)
        if k == 'dark': return 268, min(0.7, 0.35 + s * 0.3), min(1, v * 1.4 + 0.02)
        return h, s, v
    if k == 'brass': return 20, min(0.9, s * 1.15), v * 0.95
    if k == 'copper': return 272, min(0.8, s * 0.95), min(1, v * 0.9)
    if k == 'dark': return 255, 0.10, min(1, v * 1.25)
    return h, s, v
def map_rgb(r, g, b, mode='normal'):
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    h2, s2, v2 = map_hsv(h * 360, s, v, mode)
    r2, g2, b2 = colorsys.hsv_to_rgb((h2 % 360) / 360, s2, v2)
    return int(round(r2 * 255)), int(round(g2 * 255)), int(round(b2 * 255))

# vectorised version for images
def map_image(im, mode='normal'):
    a = np.asarray(im.convert('RGBA'), float)
    rgb = a[..., :3] / 255
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1); df = mx - mn + 1e-9
    h = np.where(mx == r, ((g - b) / df) % 6, np.where(mx == g, (b - r) / df + 2, (r - g) / df + 4)) * 60
    h = np.where(mx - mn < 1e-6, 0, h); s = np.where(mx > 0, (mx - mn) / (mx + 1e-9), 0); v = mx
    H, S, V = h.copy(), s.copy(), v.copy()
    brass = (h >= 28) & (h <= 58) & (s > 0.28) & (v > 0.38)
    copper = (h >= 12) & (h < 28) & (s > 0.38) & (v > 0.30)
    dark = (v <= 0.38) & (s < 0.75) & ((h <= 60) | (s < 0.15))
    H[brass] = 20; S[brass] = np.minimum(0.9, s[brass] * 1.15); V[brass] = v[brass] * 0.95
    H[copper] = 272; S[copper] = np.minimum(0.8, s[copper] * 0.95); V[copper] = np.minimum(1, v[copper] * 0.9)
    H[dark] = 255; S[dark] = 0.10; V[dark] = np.minimum(1, v[dark] * 1.25)
    c = V * S; x = c * (1 - np.abs((H / 60) % 2 - 1)); m = V - c; z = np.zeros_like(H); hi = (H // 60).astype(int) % 6
    R = np.select([hi == k for k in range(6)], [c, x, z, z, x, c]); G = np.select([hi == k for k in range(6)], [x, c, c, x, z, z]); B = np.select([hi == k for k in range(6)], [z, z, x, c, c, x])
    out = np.stack([R + m, G + m, B + m], -1) * 255
    return Image.fromarray(np.dstack([np.clip(out, 0, 255), a[..., 3]]).astype('uint8'), 'RGBA')

# ---------------------------------------------------------------- text files
KEEP_LINE = re.compile(r'PALETTE|CHANNELS|#game-chat-box\.sp-|elementicon-l-|sp-el-name\.|default=\'rgb')
COL = re.compile(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(,\s*[\d.]+\s*)?\)')
HEX = re.compile(r'#([0-9a-fA-F]{6})\b')
def recolour_text(s):
    out, pos = [], 0
    # CSS blocks: a scrollbar rule gets the gold scrollbar colours
    for m in re.finditer(r'([^{}]*)\{([^{}]*)\}', s):
        out.append(recolour_free(s[pos:m.start()]))
        sel, body = m.group(1), m.group(2)
        mode = 'gold' if re.search(r'scrollbar|sliderbar|slidertrack', sel) and 'input.range' not in sel else 'normal'
        out.append(recolour_free(sel) + '{' + recolour_free(body, mode) + '}')
        pos = m.end()
    out.append(recolour_free(s[pos:]))
    return ''.join(out)
def recolour_free(s, mode='normal'):
    lines = s.split('\n')
    for i, ln in enumerate(lines):
        if KEEP_LINE.search(ln): continue
        ln = COL.sub(lambda m: (('rgba(' if m.group(4) else 'rgb(') + ', '.join(str(c) for c in map_rgb(*(int(m.group(k)) for k in (1, 2, 3)), mode)) + (m.group(4) or '') + ')'), ln)
        ln = HEX.sub(lambda m: '#' + ''.join('%02x' % c for c in map_rgb(*(int(m.group(1)[k:k + 2], 16) for k in (0, 2, 4)), mode)), ln)
        lines[i] = ln
    return '\n'.join(lines)

# ---------------------------------------------------------------- binary art
def write_dds(img, path):
    w, h = img.size
    hdr = bytearray(128); hdr[0:4] = b'DDS '
    struct.pack_into('<7I', hdr, 4, 124, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000, h, w, w * 4, 0, 1)
    struct.pack_into('<2I4sI4I', hdr, 76, 32, 0x41, b'\0\0\0\0', 32, 0xff, 0xff00, 0xff0000, 0xff000000)
    struct.pack_into('<I', hdr, 108, 0x1000)
    open(path, 'wb').write(bytes(hdr) + img.convert('RGBA').tobytes())
def write_cur(path, img, hot=(0, 0)):
    w, h = img.size; px = img.load(); xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]; xor += bytes((b, g, r, a))
    astride = ((w + 31) // 32) * 4; andm = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(astride)
        for x in range(w):
            if px[x, y][3] < 8: row[x // 8] |= 0x80 >> (x % 8)
        andm += row
    bih = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, len(xor) + len(andm), 0, 0, 0, 0)
    data = bih + xor + andm
    head = struct.pack('<HHH', 0, 2, 1) + struct.pack('<BBBBHHII', w, h, 0, 0, hot[0], hot[1], len(data), 22)
    open(path, 'wb').write(head + data)

# ---------------------------------------------------------------- build
if os.path.exists(DST): shutil.rmtree(DST)
shutil.copytree(SRC, DST, ignore=shutil.ignore_patterns('manifest.txt', '.git*'))
counts = {}
for root, _, files in os.walk(DST):
    for f in files:
        p = os.path.join(root, f); ext = f.lower().rsplit('.', 1)[-1]
        if ext in ('html', 'css', 'lua', 'rcss'):
            s = open(p, encoding='utf-8', newline='').read(); s2 = recolour_text(s)
            if s2 != s: open(p, 'w', encoding='utf-8', newline='').write(s2)
        elif ext == 'dds':
            write_dds(map_image(Image.open(p)), p)
        elif ext == 'png':
            im = Image.open(p); mode = im.mode
            out = map_image(im)
            (out if 'A' in mode else out.convert('RGB')).save(p)
        elif ext == 'cur':
            e = read_cur(p)[0]
            write_cur(p, map_image(e['img']), e['hot'])
        elif f == 'skin.ini':
            s = open(p, encoding='utf-8', newline='').read()
            s = re.sub(r'=([0-9A-Fa-f]{6})', lambda m: '=' + ''.join('%02X' % c for c in map_rgb(*(int(m.group(1)[k:k + 2], 16) for k in (0, 2, 4)))), s)
            open(p, 'w', encoding='utf-8', newline='').write(s)
        else:
            continue
        counts[ext] = counts.get(ext, 0) + 1
print(counts)
