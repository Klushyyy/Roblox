"""Clip checker for LevelNPCs scans (harness npcscan<level>).

Reports, per actor, time ranges where a body part sinks into room geometry or into another actor,
deeper than a tolerance. Everything is treated as an oriented box (cylinders/balls conservatively).
"""
import json, sys
import numpy as np

data = json.load(open(sys.argv[1]))
TOL = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
actors = sorted(data["actors"], key=len, reverse=True)

def obb(p):
    c = np.array(p["cf"][:3]); R = np.array(p["cf"][3:]).reshape(3, 3)
    sz = np.array(p["sz"], dtype=float)
    if p.get("mt") == "Head":
        sz = np.array([sz[1] * 1.25] * 3)
    elif p.get("mt") == "Sphere":
        sz = sz * 0.8
    return c, R, sz / 2

def owner(name):
    for a in actors:
        if name.startswith(a):
            return a
    return None

# Room parts that matter: visible, and not tiny decoration.
IGNORE = {"KitchenFloor", "FloorTile", "Ceiling", "Carpet", "CarpetTrim", "Cloth", "Runner", "SafetyWall", "SafetyLid", "TablePlate"}
# Expected contact while sitting: thighs on the seat, calves by the seat edge / chair legs.
ALLOW = [
    (("Thigh",), ("ChairSeat", "StoolSeat", "ThroneSeat", "Chair"), 14),
    (("Shin",), ("ChairSeat", "ChairLeg", "StoolSeat", "StoolPost", "ThroneSeat", "Chair"), 30),
]
def allowed(part, other, depth):
    for pp, oo, d in ALLOW:
        if part.startswith(pp) and other in oo and depth <= d:
            return True
    return False
static = []
for p in data["static"]:
    if p["t"] >= 0.95 or p["n"] in IGNORE or p.get("hidden"):
        continue
    c, R, h = obb(p)
    if max(h) < 0.6:
        continue
    static.append((p["n"], c, R, h))

def overlap(a, b):
    """Penetration depth of two OBBs via SAT (0 if separated)."""
    ca, Ra, ha = a; cb, Rb, hb = b
    axes = [Ra[:, i] for i in range(3)] + [Rb[:, i] for i in range(3)]
    for i in range(3):
        for j in range(3):
            v = np.cross(Ra[:, i], Rb[:, j])
            n = np.linalg.norm(v)
            if n > 1e-6:
                axes.append(v / n)
    d = cb - ca
    best = 1e9
    for ax in axes:
        ra = np.sum(ha * np.abs(Ra.T @ ax))
        rb = np.sum(hb * np.abs(Rb.T @ ax))
        o = ra + rb - abs(d @ ax)
        if o <= 0:
            return 0.0
        best = min(best, o)
    return best

# Pre-bin static parts by rough bounds.
sb = []
for n, c, R, h in static:
    r = np.linalg.norm(h)
    sb.append((n, c, R, h, r))

hits = {}
for fr in data["frames"]:
    t = fr["t"]
    parts = []
    for p in fr["p"]:
        o = owner(p["n"])
        c, R, h = obb(p)
        parts.append((p["n"], o, c, R, h, np.linalg.norm(h)))
    furn = [("Chair", c, R, h, r) for (pn, o, c, R, h, r) in parts if o is None and pn.startswith("Furn")]
    for (pn, o, c, R, h, r) in parts:
        if o is None:
            continue  # props are checked by eye
        for (sn, sc, sR, sh, sr) in sb + furn:
            if np.linalg.norm(sc - c) > r + sr:
                continue
            d = overlap((c, R, h), (sc, sR, sh))
            if d > TOL and not allowed(pn[len(o):], sn, d):
                key = (o, pn[len(o):], sn)
                hits.setdefault(key, []).append((t, d))
    # actor vs actor
    for i in range(len(parts)):
        pn, o, c, R, h, r = parts[i]
        if o is None:
            continue
        for j in range(i + 1, len(parts)):
            qn, o2, c2, R2, h2, r2 = parts[j]
            if o2 is None or o2 == o:
                continue
            if np.linalg.norm(c2 - c) > r + r2:
                continue
            d = overlap((c, R, h), (c2, R2, h2))
            if d > TOL:
                key = (o, pn[len(o):], "actor " + o2 + qn[len(o2):])
                hits.setdefault(key, []).append((t, d))

def ranges(ts):
    out = []
    for t, d in ts:
        if out and t - out[-1][1] <= 0.26:
            out[-1][1] = t; out[-1][2] = max(out[-1][2], d)
        else:
            out.append([t, t, d])
    return out

if not hits:
    print("no clipping deeper than", TOL)
for key in sorted(hits):
    rs = ranges(hits[key])
    print(f"{key[0]:8s} {key[1]:8s} x {key[2]:24s} " + ", ".join(f"{a:.2f}-{b:.2f}s ({d:.0f})" for a, b, d in rs[:6]) + (" ..." if len(rs) > 6 else ""))
