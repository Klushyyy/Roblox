"""Tiny z-buffer renderer for the part dumps produced by harness.luau.

usage: python3 render.py parts.json out.png eye_x eye_y eye_z target_x target_y target_z [fov] [W H]
Boxes, wedges, cylinders (axis = local X) and balls are drawn with flat Lambert shading.
Parts with Transparency >= 0.95 are skipped; others are drawn with simple alpha blending
(transparent ones drawn last, no depth write).
"""
import json, sys, math
import numpy as np
from PIL import Image

args = sys.argv[1:]
src, out = args[0], args[1]
eye = np.array([float(v) for v in args[2:5]])
target = np.array([float(v) for v in args[5:8]])
fov = float(args[8]) if len(args) > 8 else 70
W = int(args[9]) if len(args) > 9 else 1280
H = int(args[10]) if len(args) > 10 else 720

parts = json.load(open(src))

def rot(cf):
    m = cf[3:]
    return np.array([[m[0], m[1], m[2]], [m[3], m[4], m[5]], [m[6], m[7], m[8]]])

def box_mesh(hx, hy, hz):
    v = np.array([[x, y, z] for x in (-hx, hx) for y in (-hy, hy) for z in (-hz, hz)])
    # index = xi*4 + yi*2 + zi
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    tris = []
    for a, b, c, d in faces:
        tris += [(a, b, c), (a, c, d)]
    return v, tris

def wedge_mesh(hx, hy, hz):
    # Bottom rectangle, top edge at the back (+Z); the slope faces -Z (the part's front).
    v = np.array([[-hx, -hy, -hz], [hx, -hy, -hz], [hx, -hy, hz], [-hx, -hy, hz], [-hx, hy, hz], [hx, hy, hz]])
    tris = [(0, 2, 1), (0, 3, 2), (3, 4, 5), (3, 5, 2), (0, 1, 5), (0, 5, 4), (0, 4, 3), (1, 2, 5)]
    return v, tris

def cyl_mesh(hx, r, n=28):
    v = []
    for s in (-hx, hx):
        for i in range(n):
            a = 2 * math.pi * i / n
            v.append([s, r * math.cos(a), r * math.sin(a)])
    v.append([-hx, 0, 0]); v.append([hx, 0, 0])
    tris = []
    for i in range(n):
        j = (i + 1) % n
        tris += [(i, j, n + j), (i, n + j, n + i)]
        tris.append((2 * n, j, i))
        tris.append((2 * n + 1, n + i, n + j))
    return np.array(v), tris

def ball_mesh(r, rings=10, segs=18):
    v = []
    for i in range(rings + 1):
        th = math.pi * i / rings
        for j in range(segs):
            ph = 2 * math.pi * j / segs
            v.append([r * math.sin(th) * math.cos(ph), r * math.cos(th), r * math.sin(th) * math.sin(ph)])
    tris = []
    for i in range(rings):
        for j in range(segs):
            a = i * segs + j; b = i * segs + (j + 1) % segs
            c = (i + 1) * segs + j; d = (i + 1) * segs + (j + 1) % segs
            tris += [(a, c, b), (b, c, d)]
    return np.array(v), tris

def ellipsoid_mesh(hx, hy, hz):
    v, t = ball_mesh(1.0)
    return v * np.array([hx, hy, hz]), t

# Camera
fwd = target - eye; fwd /= np.linalg.norm(fwd)
right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
up = np.cross(right, fwd)
f = 1 / math.tan(math.radians(fov) / 2)
light = np.array([0.4, 0.8, 0.3]); light /= np.linalg.norm(light)

zbuf = np.full((H, W), np.inf)
img = np.zeros((H, W, 3))
sky = np.linspace([0.62, 0.78, 0.95], [0.85, 0.9, 0.95], H)
img[:] = sky[:, None, :]

def project(p):
    d = p - eye
    x, y, z = d @ right, d @ up, d @ fwd
    return x, y, z

NEAR = 0.3
def draw_tri(P, color, alpha):
    # clip against the near plane, then fan-triangulate what's left
    q = [np.array(project(p)) for p in P]
    if all(v[2] >= NEAR for v in q):
        return raster(q, color, alpha)
    out = []
    for i in range(3):
        a, b = q[i], q[(i + 1) % 3]
        if a[2] >= NEAR:
            out.append(a)
        if (a[2] >= NEAR) != (b[2] >= NEAR):
            k = (NEAR - a[2]) / (b[2] - a[2])
            out.append(a + (b - a) * k)
    for i in range(1, len(out) - 1):
        raster([out[0], out[i], out[i + 1]], color, alpha)

def raster(Q, color, alpha):
    xs, ys, zs = [], [], []
    for x, y, z in Q:
        xs.append((x / z * f * H / 2) + W / 2)
        ys.append(H / 2 - (y / z * f * H / 2))
        zs.append(z)
    x0, x1 = int(max(0, math.floor(min(xs)))), int(min(W - 1, math.ceil(max(xs))))
    y0, y1 = int(max(0, math.floor(min(ys)))), int(min(H - 1, math.ceil(max(ys))))
    if x0 > x1 or y0 > y1:
        return
    (ax, bx, cx), (ay, by, cy) = xs, ys
    den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if abs(den) < 1e-9:
        return
    gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
    w1 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
    w2 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
    w3 = 1 - w1 - w2
    inside = (w1 >= -1e-4) & (w2 >= -1e-4) & (w3 >= -1e-4)
    if not inside.any():
        return
    z = 1 / (w1 / zs[0] + w2 / zs[1] + w3 / zs[2])
    region = zbuf[y0:y1 + 1, x0:x1 + 1]
    mask = inside & (z < region - 1e-3)
    if alpha >= 0.999:
        region[mask] = z[mask]
        img[y0:y1 + 1, x0:x1 + 1][mask] = color
    else:
        sub = img[y0:y1 + 1, x0:x1 + 1]
        sub[mask] = sub[mask] * (1 - alpha) + np.array(color) * alpha

opaque, clear = [], []
for p in parts:
    if p["t"] >= 0.95:
        continue
    (clear if p["t"] > 0.05 else opaque).append(p)
# Transparent parts back to front.
clear.sort(key=lambda p: -np.linalg.norm(np.array(p["cf"][:3]) - eye))

for p in opaque + clear:
    sx, sy, sz = p["sz"]
    s = p["s"]
    if s == "Cylinder":
        v, tris = cyl_mesh(sx / 2, min(sy, sz) / 2)
    elif s == "Ball":
        v, tris = ball_mesh(min(sx, sy, sz) / 2)
    elif s == "WedgePart":
        v, tris = wedge_mesh(sx / 2, sy / 2, sz / 2)
    elif p.get("mt") == "Head":
        # Roblox's head mesh: a rounded block about 1.25 x 1.25 x 1.25 of the part's height.
        d = sy * 1.25
        v, tris = cyl_mesh(d * 0.5, d / 2)
        v = v[:, [1, 0, 2]]
        v[:, 0] *= 1.0
        v = np.clip(v, -1e9, 1e9)
    elif p.get("mesh"):
        v, tris = ellipsoid_mesh(sx / 2, sy / 2, sz / 2)
    else:
        v, tris = box_mesh(sx / 2, sy / 2, sz / 2)
    R = rot(p["cf"]); T = np.array(p["cf"][:3])
    wv = v @ R.T + T
    base = np.array(p["c"])
    if p["m"] == "Neon":
        base = np.minimum(1, base * 1.25)
    alpha = 1 - p["t"]
    for a, b, c in tris:
        P = wv[[a, b, c]]
        n = np.cross(P[1] - P[0], P[2] - P[0])
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            continue
        n /= ln
        view = eye - P[0]
        if n @ view < 0:
            n = -n  # two-sided shading (winding isn't guaranteed consistent)
        shade = 0.45 + 0.55 * max(0, n @ light)
        if p["m"] == "Neon":
            shade = 1
        draw_tri(P, np.clip(base * shade, 0, 1), alpha)

Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(out)
print("saved", out)
