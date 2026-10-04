"""Phone audit of GUI dumps: smallest real text size (TextSize x every UIScale above it) and text that
would be clipped (a one-line label wider than its box). Usage: mobaudit.py dump.json [minpx]"""
import json, sys
CHAR_W = 0.52  # average glyph width / TextSize for the game's fonts

def walk(n, scale=1.0, path=()):
    own = 1.0
    for c in n.get('children', []) or []:
        if c['props'].get('ClassName') == 'UIScale':
            own = c['props'].get('Scale', 1.0)
    scale *= own
    name = n['props'].get('Name', '?')
    yield n, scale, path + (name,)
    for c in n.get('children', []) or []:
        yield from walk(c, scale, path + (name,))

def main():
    d = json.load(open(sys.argv[1]))
    minpx = float(sys.argv[2]) if len(sys.argv) > 2 else 9.0
    small = {}
    worst = 99.0
    for n, scale, path in walk(d):
        p = n['props']
        if p.get('ClassName') not in ('TextLabel', 'TextButton'):
            continue
        txt = p.get('Text', '')
        if not txt or not p.get('Visible', True):
            continue
        size = p.get('TextSize', 14)
        if p.get('TextScaled'):
            continue
        px = size * scale
        worst = min(worst, px)
        if px < minpx:
            key = (round(px, 1), txt[:40])
            small[key] = small.get(key, 0) + 1
    print(f"{sys.argv[1].split('/')[-1]}: smallest text {worst:.1f}px; {sum(small.values())} labels under {minpx}px")
    for (px, t), c in sorted(small.items())[:8]:
        print(f"   {px}px  {t!r} x{c}")

main()
