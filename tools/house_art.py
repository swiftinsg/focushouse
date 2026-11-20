#!/usr/bin/env python3
"""Build every house sprite from the one reference house, then write PNGs.

    python3 tools/house_art.py && python3 tools/sprites.py

Art/house_reference.txt is the student-supplied house (Art/house_reference.png)
traced 1:1 into an 85x54 grid. It sits on a 96x64 canvas with sky above.

Two independent axes, so every sprite is still the same house:
- level 0-5, from bricks earned all-time (House.levelBricks): 0 is run-down
  (stained walls, boarded windows, holes in a faded roof, dead bushes), each
  level repairs a bit, 4 is the reference house, 5 adds flowers.
- state, from stress (House.State): calm, stressed (a few cracks), overloaded
  (more cracks, a broken window, storm), crumbling (holes, both windows broken),
  resting (night, lit windows). Damage only ever lands on house pixels.
Writes Art/houses.json. Standard library only; deterministic.
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H, OX, OY = 96, 64, 5, 10
LEVELS = 6
STATES = ["calm", "stressed", "overloaded", "crumbling", "resting"]

PALETTE = {
    "o": "#000000", "x": "#1e102b", "n": "#0f3750", "d": "#1e5e81", "g": "#3c7b9e",
    "w": "#e8dfda", "u": "#cbc0bc", "b": "#1a6938",
    # run-down
    "W": "#b8aa98", "U": "#9c8f7f", "s": "#857563", "h": "#140c18", "p": "#8a6a44",
    "P": "#5e4529", "D": "#5d7f93", "N": "#3b5566", "k": "#7d6b3c", "K": "#556b33",
    # nicer, weather, night
    "f": "#e4718f", "y": "#f3c74f", "Y": "#ffd45e", "q": "#f6e6a6",
    "c": "#f4f8ff", "C": "#c9d4e3", "G": "#7a8496", "S": "#535b6b",
}

ref = open(os.path.join(ROOT, "Art", "house_reference.txt")).read().split("\n")
assert len(ref) == 54 and all(len(r) == 85 for r in ref)
BASE = [["."] * W for _ in range(H)]
for y, row in enumerate(ref):
    for x, c in enumerate(row):
        BASE[y + OY][x + OX] = c


def inside(box, x, y):
    x0, y0, x1, y1 = box
    return x0 <= x <= x1 and y0 <= y <= y1


ROUND, SQUARE, DOOR = (41, 22, 51, 32), (52, 41, 60, 48), (31, 41, 43, 61)
CELLS = [(x, y) for y in range(H) for x in range(W)]
WALL = {(x, y) for x, y in CELLS if BASE[y][x] in "wu"}
ROOF = {(x, y) for x, y in CELLS if BASE[y][x] == "n" and y >= 10 and not any(inside(b, x, y) for b in (ROUND, SQUARE, DOOR)) and not (23 <= x <= 33 and y <= 18)}
GLASS = {(x, y) for x, y in CELLS if BASE[y][x] == "g"}
BUSH = {(x, y) for x, y in CELLS if BASE[y][x] == "b"}
HOUSE = {(x, y) for x, y in CELLS if BASE[y][x] != "."}


def rnd(x, y, seed):
    """Stable 0..1 per pixel."""
    v = (x * 73856093) ^ (y * 19349663) ^ (seed * 83492791)
    v = (v ^ (v >> 13)) * 1274126177 & 0xFFFFFFFF
    return (v & 0xFFFF) / 0xFFFF


def holes(g, n, seed):
    """n 2x2 holes in the roof band."""
    if n == 0:
        return
    spots = sorted(ROOF, key=lambda p: rnd(*p, seed))
    made = 0
    for x, y in spots:
        block = [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)]
        if all(p in ROOF for p in block):
            for bx, by in block:
                g[by][bx] = "h"
            made += 1
            if made == n:
                return


def stains(g, n, seed):
    """n grime streaks running down the walls."""
    starts = sorted(WALL, key=lambda p: rnd(*p, seed))[:n]
    for x, y in starts:
        for dy in range(3 + int(rnd(x, y, seed + 1) * 5)):
            if (x, y + dy) in WALL and g[y + dy][x] not in "h":
                g[y + dy][x] = "s"


def board(g, box):
    for x, y in GLASS:
        if inside(box, x, y):
            g[y][x] = "P" if (y - box[1]) % 3 == 0 else "p"


def level(lv):
    g = [r[:] for r in BASE]
    for x, y in WALL:
        if lv <= 2:
            g[y][x] = "W" if BASE[y][x] == "w" else "U"
    stains(g, [14, 10, 7, 3, 0, 0][lv], seed=1)
    for x, y in ROOF:
        if lv <= 1:
            g[y][x] = "N"
    holes(g, [6, 3, 1, 0, 0, 0][lv], seed=2)
    if lv == 0:
        board(g, ROUND)
    if lv <= 1:
        board(g, SQUARE)
    for x, y in CELLS:
        if BASE[y][x] == "d" and lv <= 2:
            g[y][x] = "D"
    for x, y in BUSH:
        if lv <= 2:
            g[y][x] = "kKK"[lv]   # dead, then patchy
        elif lv == 5 and rnd(x, y, 4) < 0.07:
            g[y][x] = "f" if rnd(x, y, 5) < 0.6 else "y"
    return g


# Cracks: start point, steps, horizontal drift. Later states add more.
CRACKS = [(26, 46, 6, 1), (66, 50, 6, -1), (45, 36, 7, 1), (58, 28, 7, -1), (24, 54, 8, 1), (63, 39, 8, 1)]


def crack(g, x, y, steps, dx):
    for i in range(steps):
        if (x, y) in WALL:
            g[y][x] = "h"
        y += 1
        if i % 2 == 1:
            x += dx


def shatter(g, box, seed):
    for x, y in GLASS:
        if inside(box, x, y) and rnd(x, y, seed) < 0.45:
            g[y][x] = "h"


def wall_hole(g, cx, cy):
    for x in range(cx - 2, cx + 2):
        for y in range(cy - 1, cy + 2):
            if (x, y) in WALL and rnd(x, y, 9) < 0.85:
                g[y][x] = "h"


def blob(g, cx, cy, rx, ry, c, edge=None):
    for x in range(cx - rx, cx + rx + 1):
        for y in range(max(0, cy - ry), cy + ry + 1):
            d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
            if d <= 1 and 0 <= x < W and y < H and (x, y) not in HOUSE:
                g[y][x] = edge if edge and d > 0.6 else c


def state(g, st):
    g = [r[:] for r in g]
    n = {"stressed": 2, "overloaded": 4, "crumbling": 6}.get(st, 0)
    for x, y, steps, dx in CRACKS[:n]:
        crack(g, x, y, steps + (2 if st == "crumbling" else 0), dx)
    if st in ("overloaded", "crumbling"):
        shatter(g, SQUARE, 6)
        holes(g, 1, seed=7)
    if st == "crumbling":
        shatter(g, ROUND, 8)
        holes(g, 3, seed=8)
        wall_hole(g, 70, 44)
        wall_hole(g, 27, 36)
    if st in ("calm", "stressed"):
        blob(g, 8, 6, 4, 4, "Y", edge="y")                               # sun
        blob(g, 76, 5, 7, 2, "c" if st == "calm" else "C")               # a cloud
        if st == "stressed":
            blob(g, 86, 8, 5, 2, "C")
    if st in ("overloaded", "crumbling"):
        dark = "S" if st == "crumbling" else "G"
        for cx, cy, rx in [(10, 3, 12), (34, 2, 10), (62, 3, 13), (88, 3, 10)]:
            blob(g, cx, cy, rx, 3 + (st == "crumbling"), dark, edge="G" if dark == "S" else "C")
    if st == "resting":
        blob(g, 84, 6, 4, 4, "q")                                        # moon, with a bite out
        blob(g, 86, 5, 3, 3, ".")
        for x, y in GLASS:
            if g[y][x] == "g":
                g[y][x] = "Y"
    return g


sprites = []
for lv in range(LEVELS):
    base = level(lv)
    for st in STATES:
        g = state(base, st)
        for x, y in CELLS:   # same house in every sprite: nothing of it goes missing,
            assert (g[y][x] != ".") == ((x, y) in HOUSE) or (x, y) not in HOUSE, (st, lv, x, y)
        sprites.append({"name": f"{st}.{lv}", "grid": ["".join(r) for r in g]})

with open(os.path.join(ROOT, "Art", "houses.json"), "w") as f:
    f.write('{"palette": ' + json.dumps(PALETTE) + ',\n "sprites": '
            + json.dumps(sprites, indent=1).replace("\n", "\n ") + "\n}\n")
print(len(sprites), "sprites")
