# usage: eyecheck.py parts.json ex ey ez  -> names of parts the eye is inside of (6 stud margin)
import json, sys
import numpy as np
L = json.load(open(sys.argv[1]))
e = np.array([float(v) for v in sys.argv[2:5]])
hits = []
for p in L:
    if p.get("t", 0) >= 0.95:
        continue
    cf = p["cf"]
    T = np.array(cf[:3]); R = np.array(cf[3:12]).reshape(3, 3)
    local = R.T @ (e - T)
    half = np.array(p["sz"]) / 2 + 6
    if np.all(np.abs(local) <= half):
        hits.append(p["n"])
if hits:
    print("INSIDE", sorted(set(hits)))
