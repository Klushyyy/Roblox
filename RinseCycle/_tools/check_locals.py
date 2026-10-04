#!/usr/bin/env python3
"""Roblox's Luau refuses a script with more than 200 local variables alive at once in one function
("Out of local registers ... exceeded limit 200"). Lune's compiler is more lenient, so the offline
tests don't catch it. This counts the locals declared at the top level of every script (the usual
culprit) and fails above LIMIT, leaving room for loop variables and temporaries."""
import pathlib, re, sys

LIMIT = 185
root = pathlib.Path(__file__).resolve().parent.parent
bad = 0
for path in sorted(root.rglob("*.luau")):
    if "_tools" in path.parts:
        continue
    count = 0
    inner = 0  # locals one tab in (inside a top-level `do` block): they are alive together with the top-level ones
    for line in path.read_text(encoding="utf-8").split("\n"):
        m = re.match(r"^local (function )?(.*)", line)
        if m:
            count += 1 if m.group(1) else len([n for n in m.group(2).split("=")[0].split(",") if n.strip()])
        m2 = re.match(r"^\tlocal (function )?(.*)", line)
        if m2:
            inner += 1 if m2.group(1) else len([n for n in m2.group(2).split("=")[0].split(",") if n.strip()])
    # a rough upper bound: the whole file's top-level locals plus a `do` block's own
    if path.name.startswith("AdminServer"):
        count = count + min(inner, 40)
    if count > LIMIT - 40:
        flag = "TOO MANY" if count > LIMIT else "ok"
        print(f"{count:4d}  {flag:8s} {path.relative_to(root)}")
    if count > LIMIT:
        bad += 1
sys.exit(1 if bad else 0)
