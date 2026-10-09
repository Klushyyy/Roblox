"""Do props overlap each other on the counters? usage: python3 overlapcheck.py arena2.json [more.json ...]

Reads the part dumps from `lune run harness.luau arenaN out.json`. Whole props (a pizza, a stack of pizza boxes) are worked
out from their parts, and any two that come within GAP studs of each other (or of the counter's edge) are listed.
Exit status 1 if anything overlaps.
"""
import json, sys, math

GAP = 4.0
COUNTER_TOP = 40.0  # (the Backyard's counter; level 2 is the only one with loose pizzas and boxes)


def aabb(p):
    cf = p["cf"]
    m = cf[3:]
    sx, sy, sz = [v / 2 for v in p["sz"]]
    ex = abs(m[0]) * sx + abs(m[1]) * sy + abs(m[2]) * sz
    ey = abs(m[3]) * sx + abs(m[4]) * sy + abs(m[5]) * sz
    ez = abs(m[6]) * sx + abs(m[7]) * sy + abs(m[8]) * sz
    return (cf[0] - ex, cf[0] + ex, cf[1] - ey, cf[1] + ey, cf[2] - ez, cf[2] + ez)


def props(parts):
    """Pizza boards (circles) and box stacks (the box of their bounds): (label, kind, x0, x1, z0, z1)."""
    boards, boxes, logos = [], [], []
    for p in parts:
        if p["n"] == "PizzaBoard":
            boards.append(aabb(p))
        elif p["n"] == "PizzaBox":
            boxes.append(aabb(p))
        elif p["n"] == "PizzaBoxLogo":
            logos.append(p["cf"][0:3])
    out = []
    for i, a in enumerate(boards):
        out.append((f"pizza {i+1} at ({(a[0]+a[1])/2:.0f},{(a[4]+a[5])/2:.0f})", "circle", a[0], a[1], a[4], a[5]))
    stacks = {i: [] for i in range(len(logos))}
    for b in boxes:
        cx, cz = (b[0] + b[1]) / 2, (b[4] + b[5]) / 2
        k = min(range(len(logos)), key=lambda i: (logos[i][0] - cx) ** 2 + (logos[i][2] - cz) ** 2)
        stacks[k].append(b)
    for k, bl in stacks.items():
        if bl:
            x0, x1 = min(b[0] for b in bl), max(b[1] for b in bl)
            z0, z1 = min(b[4] for b in bl), max(b[5] for b in bl)
            out.append((f"box stack at ({(x0+x1)/2:.0f},{(z0+z1)/2:.0f})", "box", x0, x1, z0, z1))
    return out


def counters(parts):
    return [aabb(p) for p in parts if p["n"] == "Countertop"]


def gap(a, b):
    """Studs between two props (negative = they overlap)."""
    if a[1] == "circle" and b[1] == "circle":
        ca = ((a[2] + a[3]) / 2, (a[4] + a[5]) / 2)
        cb = ((b[2] + b[3]) / 2, (b[4] + b[5]) / 2)
        return math.hypot(ca[0] - cb[0], ca[1] - cb[1]) - (a[3] - a[2]) / 2 - (b[3] - b[2]) / 2
    if a[1] == "circle" or b[1] == "circle":
        c, r = (a, b) if a[1] == "circle" else (b, a)
        cx, cz, rad = (c[2] + c[3]) / 2, (c[4] + c[5]) / 2, (c[3] - c[2]) / 2
        dx = max(r[2] - cx, 0, cx - r[3])
        dz = max(r[4] - cz, 0, cz - r[5])
        return math.hypot(dx, dz) - rad
    gx = max(a[2] - b[3], b[2] - a[3])
    gz = max(a[4] - b[5], b[4] - a[5])
    return max(gx, gz) if (gx > 0 and gz > 0) is False else math.hypot(gx, gz)


bad = 0
for path in sys.argv[1:]:
    parts = json.load(open(path))
    items = props(parts)
    tops = counters(parts)
    print(f"{path}: {len(items)} props on the counter")
    for i, a in enumerate(items):
        for b in items[i + 1:]:
            g = gap(a, b)
            if g < GAP:
                bad += 1
                print(f"  OVERLAP/TOO CLOSE: {a[0]} and {b[0]} (gap {g:.1f})")
        if not any(a[2] >= t[0] + 2 and a[3] <= t[1] - 2 and a[4] >= t[4] + 2 and a[5] <= t[5] - 2 for t in tops):
            bad += 1
            print(f"  HANGS OVER THE COUNTER'S EDGE: {a[0]} x {a[2]:.0f}..{a[3]:.0f} z {a[4]:.0f}..{a[5]:.0f}")
print("OK: nothing overlaps" if not bad else f"{bad} problem(s)")
sys.exit(1 if bad else 0)
