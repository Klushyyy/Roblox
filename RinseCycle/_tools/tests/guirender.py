#!/usr/bin/env python3
"""Renders a dumped Roblox GUI tree (guidump.luau JSON) to a PNG.

Supports Frame/TextLabel/TextButton/ImageLabel/ScrollingFrame/CanvasGroup with UICorner, UIStroke
(incl. a UIGradient on the stroke), UIGradient (colour + transparency, rotation, offset), rotation
(inherited), ClipsDescendants, UIPadding, UIListLayout, UIAspectRatioConstraint, UIScale and text.

usage: guirender.py tree.json out.png [W H] [--scale S] [--bg r,g,b] [--root NAME]
"""
import json, math, sys, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
EMOJI_FONTS = ["/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"]

GUI_CLASSES = {"Frame", "TextLabel", "TextButton", "ImageLabel", "ImageButton", "ScrollingFrame",
               "CanvasGroup", "ViewportFrame", "TextBox"}


def P(node, key, default=None):
    v = node["props"].get(key, default)
    return v


def udim2(v):
    if not v:
        return (0, 0, 0, 0)
    return (v["xs"], v["xo"], v["ys"], v["yo"])


def vec2(v, d=(0, 0)):
    if not v:
        return d
    return (v["x"], v["y"])


def col(v, d=(163 / 255, 162 / 255, 165 / 255)):
    if not v:
        return np.array(d, dtype=np.float32)
    return np.array((v["r"], v["g"], v["b"]), dtype=np.float32)


def enum(v, d=None):
    if isinstance(v, dict) and v.get("t") == "Enum":
        return v["v"]
    return d


def kids_of(node, cls):
    return [c for c in node["children"] if c["props"].get("ClassName") == cls]


def first(node, cls):
    k = kids_of(node, cls)
    return k[0] if k else None


def sample_colorseq(cs, t):
    if not cs:
        return np.ones(t.shape + (3,), dtype=np.float32)
    k = cs["k"]
    ts = np.array([p[0] for p in k])
    out = np.empty(t.shape + (3,), dtype=np.float32)
    for i in range(3):
        out[..., i] = np.interp(t, ts, np.array([p[1 + i] for p in k]))
    return out


def sample_numseq(ns, t):
    if not ns:
        return np.zeros(t.shape, dtype=np.float32)
    k = ns["k"]
    return np.interp(t, np.array([p[0] for p in k]), np.array([p[1] for p in k])).astype(np.float32)


class Renderer:
    def __init__(self, W, H, scale, bg):
        self.W, self.H, self.S = W, H, scale
        self.img = np.zeros((int(H * scale), int(W * scale), 4), dtype=np.float32)
        self.img[..., :3] = bg
        self.img[..., 3] = 1
        self.fonts = {}

    # ---------- geometry ----------
    def grid(self, cx, cy, hw, hh, rot, pad):
        """Pixel grid around a rotated box; returns (ys, xs slices, local u, v)."""
        c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))
        ex = abs(hw * c) + abs(hh * s) + pad
        ey = abs(hw * s) + abs(hh * c) + pad
        S = self.S
        x0 = max(0, int(math.floor((cx - ex) * S)))
        x1 = min(self.img.shape[1], int(math.ceil((cx + ex) * S)) + 1)
        y0 = max(0, int(math.floor((cy - ey) * S)))
        y1 = min(self.img.shape[0], int(math.ceil((cy + ey) * S)) + 1)
        if x1 <= x0 or y1 <= y0:
            return None
        xs = (np.arange(x0, x1) + 0.5) / S - cx
        ys = (np.arange(y0, y1) + 0.5) / S - cy
        X, Y = np.meshgrid(xs, ys)
        u = X * c + Y * s
        v = -X * s + Y * c
        return (slice(y0, y1), slice(x0, x1), u, v)

    @staticmethod
    def sdf_rrect(u, v, hw, hh, r):
        r = max(0.0, min(r, hw, hh))
        qx = np.abs(u) - (hw - r)
        qy = np.abs(v) - (hh - r)
        outside = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2)
        inside = np.minimum(np.maximum(qx, qy), 0)
        return outside + inside - r

    def cover(self, d):
        return np.clip(0.5 - d * self.S, 0, 1)

    def composite(self, sl, rgb, a, clip):
        ys, xs = sl
        if clip is not None:
            a = a * clip[ys, xs]
        dst = self.img[ys, xs]
        a3 = a[..., None]
        dst[..., :3] = rgb * a3 + dst[..., :3] * (1 - a3)
        dst[..., 3] = a + dst[..., 3] * (1 - a)

    # ---------- text ----------
    def font(self, size, bold=True):
        key = (int(size), bold)
        if key not in self.fonts:
            self.fonts[key] = ImageFont.truetype(FONT_BOLD if bold else FONT_REG, max(1, int(size)))
        return self.fonts[key]

    def draw_text(self, node, cx, cy, w, h, rot, clip, k):
        text = P(node, "Text", "")
        if not text or not isinstance(text, str):
            return
        tt = P(node, "TextTransparency", 0) or 0
        if tt >= 1:
            return
        pad = first(node, "UIPadding")
        l = r = t = b = 0
        if pad:
            def pd(key):
                v = P(pad, key)
                if not v:
                    return 0
                return v["s"] * (w if key in ("PaddingLeft", "PaddingRight") else h) + v["o"] * k
            l, r, t, b = pd("PaddingLeft"), pd("PaddingRight"), pd("PaddingTop"), pd("PaddingBottom")
        bw, bh = max(1, w - l - r), max(1, h - t - b)
        size = (P(node, "TextSize", 14) or 14) * k
        lim = first(node, "UITextSizeConstraint")
        maxs = (P(lim, "MaxTextSize", 100) if lim else 100) * k
        mins = (P(lim, "MinTextSize", 1) if lim else 1) * k
        S = self.S
        wrapped = P(node, "TextWrapped", False)
        scaled = P(node, "TextScaled", False)
        # emoji / unsupported glyphs render as a rounded placeholder square
        def measure(sz):
            f = self.font(sz * S)
            lines = text.split("\n")
            ws = [f.getlength(line) for line in lines]
            return f, lines, max(ws) / S, len(lines) * sz * 1.15
        if scaled:
            lo, hi = 1, maxs
            best = lo
            while hi - lo > 0.5:
                mid = (lo + hi) / 2
                _, _, tw, th = measure(mid)
                if tw <= bw and th <= bh:
                    best, lo = mid, mid
                else:
                    hi = mid
            size = max(mins, min(best, maxs))
        if all(ord(ch) >= 0x2190 and ch != "★" for ch in text if ch not in "️‍ "):
            self.draw_emoji(text, cx, cy, w, h, size, clip, tt)
            return
        f, lines, tw, th = measure(size)
        xa = enum(P(node, "TextXAlignment"), "Center")
        ya = enum(P(node, "TextYAlignment"), "Center")
        tc = col(P(node, "TextColor3"), (0, 0, 0))
        img = Image.new("L", (int(bw * S) + 4, int(bh * S) + 4), 0)
        stroke_node = None
        for c in kids_of(node, "UIStroke"):
            if enum(P(c, "ApplyStrokeMode"), "Contextual") == "Contextual" and P(c, "Enabled", True) is not False:
                stroke_node = c
        st_w = int(round((P(stroke_node, "Thickness", 1) or 1) * k * S)) if stroke_node else 0
        simg = Image.new("L", img.size, 0) if stroke_node else None
        dr = ImageDraw.Draw(img)
        sdr = ImageDraw.Draw(simg) if simg else None
        yy = {"Top": 0, "Center": (bh - th) / 2, "Bottom": bh - th}[ya] * S
        for line in lines:
            lw = f.getlength(line) / S
            xx = {"Left": 0, "Center": (bw - lw) / 2, "Right": bw - lw}[xa] * S
            if sdr:
                sdr.text((xx + 2, yy + 2), line, font=f, fill=255, stroke_width=st_w, stroke_fill=255)
            dr.text((xx + 2, yy + 2), line, font=f, fill=255)
            yy += size * 1.15 * S
        # place into canvas (text rotation ignored)
        x0 = int((cx - w / 2 + l) * S) - 2
        y0 = int((cy - h / 2 + t) * S) - 2
        for im, color, trans in ((simg, col(P(stroke_node, "Color") if stroke_node else None, (0, 0, 0)), (P(stroke_node, "Transparency", 0) or 0) if stroke_node else 1), (img, tc, tt)):
            if im is None or trans >= 1:
                continue
            a = np.asarray(im, dtype=np.float32) / 255 * (1 - trans)
            H, W = a.shape
            ys0, xs0 = max(0, y0), max(0, x0)
            ys1, xs1 = min(self.img.shape[0], y0 + H), min(self.img.shape[1], x0 + W)
            if ys1 <= ys0 or xs1 <= xs0:
                continue
            a = a[ys0 - y0:ys1 - y0, xs0 - x0:xs1 - x0]
            rgb = np.broadcast_to(color, a.shape + (3,)).copy()
            tg = first(node, "UIGradient") if im is img else None
            if tg:
                gx = (np.arange(xs0, xs1) + 0.5) / S - cx
                gy = (np.arange(ys0, ys1) + 0.5) / S - cy
                GX, GY = np.meshgrid(gx, gy)
                rgb, a = self.apply_grad(tg, GX, GY, w / 2, h / 2, rgb, a)
            self.composite((slice(ys0, ys1), slice(xs0, xs1)), rgb, a, clip)

    def draw_emoji(self, text, cx, cy, w, h, size, clip, tt):
        try:
            ef = ImageFont.truetype(EMOJI_FONTS[0], 109)
        except Exception:
            return
        glyph = text.replace("️", "").strip()
        im = Image.new("RGBA", (140 * max(1, len(glyph)), 140), (0, 0, 0, 0))
        ImageDraw.Draw(im).text((4, 4), glyph, font=ef, embedded_color=True)
        bb = im.getbbox()
        if not bb:
            return
        im = im.crop(bb)
        px = max(1, int(size * self.S))
        scale = px / max(im.size[1], 1)
        im = im.resize((max(1, int(im.size[0] * scale)), px), Image.LANCZOS)
        arr = np.asarray(im, dtype=np.float32) / 255
        x0 = int(cx * self.S - arr.shape[1] / 2)
        y0 = int(cy * self.S - arr.shape[0] / 2)
        H, W = arr.shape[:2]
        ys0, xs0 = max(0, y0), max(0, x0)
        ys1, xs1 = min(self.img.shape[0], y0 + H), min(self.img.shape[1], x0 + W)
        if ys1 <= ys0 or xs1 <= xs0:
            return
        sub = arr[ys0 - y0:ys1 - y0, xs0 - x0:xs1 - x0]
        self.composite((slice(ys0, ys1), slice(xs0, xs1)), sub[..., :3], sub[..., 3] * (1 - tt), clip)

    # ---------- nodes ----------
    def render_node(self, node, content, rot_parent, clip, k, group_t=0.0, forced=None):
        """content = (cx, cy, w, h) of parent's content box in canvas units (unrotated frame of parent),
        parent center (pcx, pcy) and rotation handled via rot_parent=(pcx, pcy, rot)."""
        props = node["props"]
        cls = props.get("ClassName")
        if cls not in GUI_CLASSES:
            return
        if props.get("Visible") is False:
            return
        (bx, by, bw_, bh_) = content
        scale = first(node, "UIScale")
        kk = k * (P(scale, "Scale", 1) if scale else 1)
        if forced:
            w, h, tlx, tly = forced
        else:
            xs, xo, ys, yo = udim2(P(node, "Size"))
            w = bw_ * xs + xo * k
            h = bh_ * ys + yo * k
            ar = first(node, "UIAspectRatioConstraint")
            if ar:
                ratio = P(ar, "AspectRatio", 1) or 1
                dom = enum(P(ar, "DominantAxis"), "Width")
                at = enum(P(ar, "AspectType"), "FitWithinMaxSize")
                if at == "FitWithinMaxSize":
                    if w / max(h, 1e-6) > ratio:
                        w = h * ratio
                    else:
                        h = w / ratio
                elif dom == "Width":
                    h = w / ratio
                else:
                    w = h * ratio
            if scale:
                s = P(scale, "Scale", 1)
                w, h = w * s, h * s
            pxs, pxo, pys, pyo = udim2(P(node, "Position"))
            ax, ay = vec2(P(node, "AnchorPoint"))
            px = bx + bw_ * pxs + pxo * k
            py = by + bh_ * pys + pyo * k
            tlx, tly = px - ax * w, py - ay * h
        # local center in parent's unrotated space -> canvas
        lcx, lcy = tlx + w / 2, tly + h / 2
        pcx, pcy, prot = rot_parent
        c, s = math.cos(math.radians(prot)), math.sin(math.radians(prot))
        dx, dy = lcx - pcx, lcy - pcy
        cx = pcx + dx * c - dy * s
        cy = pcy + dx * s + dy * c
        rot = prot + (props.get("Rotation", 0) or 0)
        hw, hh = w / 2, h / 2

        corner = first(node, "UICorner")
        rad = 0
        if corner:
            cr = P(corner, "CornerRadius") or {"s": 0, "o": 8}
            rad = cr["s"] * min(w, h) + cr["o"] * k
        grad = None
        for g in kids_of(node, "UIGradient"):
            if P(g, "Enabled", True) is not False:
                grad = g
        if cls == "CanvasGroup":
            group_t = 1 - (1 - group_t) * (1 - (props.get("GroupTransparency", 0) or 0))

        bgt = props.get("BackgroundTransparency", 0)
        if bgt is None:
            bgt = 0
        g = self.grid(cx, cy, hw, hh, rot, 4 * kk + 50 / self.S)
        if g and bgt < 1 and w > 0 and h > 0:
            ys, xs_, u, v = g
            d = self.sdf_rrect(u, v, hw, hh, rad)
            a = self.cover(d) * (1 - bgt) * (1 - group_t)
            rgb = np.broadcast_to(col(props.get("BackgroundColor3")), a.shape + (3,)).copy()
            if cls in ("ImageLabel", "ImageButton") and props.get("Image"):
                pass
            if grad:
                rgb, a = self.apply_grad(grad, u, v, hw, hh, rgb, a)
            self.composite((ys, xs_), rgb, a, clip)
        if cls in ("ImageLabel", "ImageButton") and props.get("Image") and g:
            # unknown image: faint checker so it is visible in shots
            ys, xs_, u, v = g
            d = self.sdf_rrect(u, v, hw, hh, rad)
            it = props.get("ImageTransparency", 0) or 0
            a = self.cover(d) * 0.35 * (1 - it)
            chk = ((np.floor(u / 4) + np.floor(v / 4)) % 2)[..., None]
            rgb = np.where(chk > 0, np.array([0.8, 0.3, 0.8]), np.array([0.3, 0.8, 0.8])).astype(np.float32)
            self.composite((ys, xs_), rgb, a, clip)
        # border stroke
        for st in kids_of(node, "UIStroke"):
            mode = enum(P(st, "ApplyStrokeMode"), "Contextual")
            is_text = cls in ("TextLabel", "TextButton", "TextBox")
            if P(st, "Enabled", True) is False or (mode == "Contextual" and is_text):
                continue
            th = (P(st, "Thickness", 1) or 1) * kk
            stt = P(st, "Transparency", 0) or 0
            g2 = self.grid(cx, cy, hw, hh, rot, th + 4)
            if not g2:
                continue
            ys, xs_, u, v = g2
            d = self.sdf_rrect(u, v, hw, hh, rad)
            # outside band [0, th]; if the corner radius is 0 Roblox miters, we round slightly
            band = np.clip(0.5 - (d - th) * self.S, 0, 1) - np.clip(0.5 - d * self.S, 0, 1)
            a = np.clip(band, 0, 1) * (1 - stt) * (1 - group_t)
            rgb = np.broadcast_to(col(P(st, "Color"), (0, 0, 0)), a.shape + (3,)).copy()
            sg = first(st, "UIGradient")
            if sg:
                rgb, a = self.apply_grad(sg, u, v, hw + th, hh + th, rgb, a)
            self.composite((ys, xs_), rgb, a, clip)
        if cls in ("TextLabel", "TextButton", "TextBox"):
            self.draw_text(node, cx, cy, w, h, rot, clip, kk)

        # children clip
        child_clip = clip
        if (props.get("ClipsDescendants") or cls in ("CanvasGroup", "ScrollingFrame")) and g:
            ys, xs_, u, v = g
            m = np.zeros(self.img.shape[:2], dtype=np.float32)
            m[ys, xs_] = self.cover(self.sdf_rrect(u, v, hw, hh, rad if cls == "CanvasGroup" else 0))
            child_clip = m if clip is None else m * clip
        # children content box (in this node's unrotated frame, centred on (cx, cy))
        pad = first(node, "UIPadding")
        l = r = t = b = 0
        if pad:
            def pd(key, full):
                v = P(pad, key)
                return (v["s"] * full + v["o"] * kk) if v else 0
            l, r, t, b = pd("PaddingLeft", w), pd("PaddingRight", w), pd("PaddingTop", h), pd("PaddingBottom", h)
        cbox = (cx - hw + l, cy - hh + t, w - l - r, h - t - b)
        kids = [c for c in node["children"] if c["props"].get("ClassName") in GUI_CLASSES]
        order = sorted(range(len(kids)), key=lambda i: ((kids[i]["props"].get("ZIndex", 1) or 1), i))
        layout = first(node, "UIListLayout")
        forced_map = {}
        if layout:
            forced_map = self.list_layout(layout, kids, cbox, k * (P(scale, "Scale", 1) if scale else 1))
        for i in order:
            self.render_node(kids[i], cbox, (cx, cy, rot), child_clip, kk, group_t, forced_map.get(i))

    def list_layout(self, layout, kids, cbox, k):
        bx, by, bw, bh = cbox
        dirn = enum(P(layout, "FillDirection"), "Vertical")
        padv = P(layout, "Padding")
        sizes = []
        vis = [i for i, c in enumerate(kids) if c["props"].get("Visible") is not False]
        if enum(P(layout, "SortOrder"), "LayoutOrder") == "LayoutOrder":
            vis.sort(key=lambda i: ((kids[i]["props"].get("LayoutOrder", 0) or 0), i))
        else:
            vis.sort(key=lambda i: kids[i]["props"].get("Name", ""))
        for i in vis:
            xs, xo, ys, yo = udim2(kids[i]["props"].get("Size"))
            sizes.append((bw * xs + xo * k, bh * ys + yo * k))
        gap = (padv["s"] * (bh if dirn == "Vertical" else bw) + padv["o"] * k) if padv else 0
        total = sum(s[1] if dirn == "Vertical" else s[0] for s in sizes) + gap * max(0, len(sizes) - 1)
        ha = enum(P(layout, "HorizontalAlignment"), "Left")
        va = enum(P(layout, "VerticalAlignment"), "Top")
        out = {}
        if dirn == "Vertical":
            y = by + {"Top": 0, "Center": (bh - total) / 2, "Bottom": bh - total}[va]
            for i, (w, h) in zip(vis, sizes):
                x = bx + {"Left": 0, "Center": (bw - w) / 2, "Right": bw - w}[ha]
                out[i] = (w, h, x, y)
                y += h + gap
        else:
            x = bx + {"Left": 0, "Center": (bw - total) / 2, "Right": bw - total}[ha]
            for i, (w, h) in zip(vis, sizes):
                y = by + {"Top": 0, "Center": (bh - h) / 2, "Bottom": bh - h}[va]
                out[i] = (w, h, x, y)
                x += w + gap
        return out

    def apply_grad(self, g, u, v, hw, hh, rgb, a):
        r = math.radians(P(g, "Rotation", 0) or 0)
        ox, oy = vec2(P(g, "Offset"))
        nx = u / max(2 * hw, 1e-6) - ox
        ny = v / max(2 * hh, 1e-6) - oy
        ext = (abs(math.cos(r)) + abs(math.sin(r))) * 0.5
        t = np.clip((nx * math.cos(r) + ny * math.sin(r)) / ext * 0.5 + 0.5, 0, 1)
        rgb = rgb * sample_colorseq(P(g, "Color"), t)
        tr = sample_numseq(P(g, "Transparency"), t)
        return rgb, a * (1 - tr)

    def save(self, path):
        out = (np.clip(self.img[..., :3], 0, 1) * 255).astype(np.uint8)
        Image.fromarray(out).save(path)


def find(node, name):
    if node["props"].get("Name") == name:
        return node
    for c in node["children"]:
        r = find(c, name)
        if r:
            return r
    return None


def main():
    args = sys.argv[1:]
    opts = {"--scale": "1", "--bg": "40,44,60", "--root": None}
    pos = []
    i = 0
    while i < len(args):
        if args[i] in opts:
            opts[args[i]] = args[i + 1]
            i += 2
        else:
            pos.append(args[i])
            i += 1
    tree = json.load(open(pos[0]))
    W = float(pos[2]) if len(pos) > 2 else 1280
    H = float(pos[3]) if len(pos) > 3 else 720
    bg = np.array([float(x) / 255 for x in opts["--bg"].split(",")], dtype=np.float32)
    R = Renderer(W, H, float(opts["--scale"]), bg)
    root = find(tree, opts["--root"]) if opts["--root"] else tree
    kids = root["children"] if root["props"].get("ClassName") not in GUI_CLASSES else [root]
    ordered = sorted(range(len(kids)), key=lambda i: ((kids[i]["props"].get("ZIndex", 1) or 1), i))
    for i in ordered:
        R.render_node(kids[i], (0, 0, W, H), (W / 2, H / 2, 0), None, 1)
    R.save(pos[1])


if __name__ == "__main__":
    main()
