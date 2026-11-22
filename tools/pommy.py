import json, sys
W = 18
# shared head + body (rows 0-9); the head sits on the right, tabby cap over it
body = [
"............o...o.",
"...........oPo.oPo",
".oo........oKKocco",
"oKko......oKkKKcco",
"okKo.oooooocKccGco",
".okKocKKkKcccccccP",
"..okcKkKKkcccccCo.",
"...occKkcccccCCo..",
"...occcccccccCco..",
"...occcccCCccco...",
]
def legs(gait):
    """Four legs under the body, rows 10-13: far pair 3 px ahead and shaded (C), near pair over it (c).
    gait = foot offsets (near back, far back, near front, far front)."""
    rows = [list("." * W) for _ in range(4)]
    order = [(7, "C", gait[1]), (13, "C", gait[3]), (4, "c", gait[0]), (10, "c", gait[2])]   # far first, near on top
    for hip, fill, dx in order:
        xs = [hip + round(dx * r / 2) for r in range(3)]
        for r, x in enumerate(xs):
            for c in (x - 1, x + 2):
                if rows[r][c] in ".C": rows[r][c] = "o"
            rows[r][x] = rows[r][x + 1] = fill
        rows[3][xs[2]] = rows[3][xs[2] + 1] = "o"
    return ["".join(r) for r in rows]
contactA, passing, contactB = legs((-2, 1, 2, -1)), legs((0, 0, 0, 0)), legs((1, -2, -1, 2))
def up(rows):   # body 1 px higher on passing frames, tail tip flicks
    rows = rows[1:] + ["...occcccccccco..."]
    rows[1] = "oo.........oKKoKKo"
    return rows
walk = [body + contactA, up(body) + passing, body + contactB, up(body) + passing]
sleepA = [
"..................",
"..................",
"..................",
"............o...o.",
"...........oPo.oPo",
"......ooooooKKocco",
"....ooccKKkKkKccco",
"...occKkKKkKccccco",
"..occKkKkKccckkcco",
"..occcKkccccccccPo",
"..occcccccccccccoo",
".oKkKKkKKkcccCco..",
"oKKooooooooooooo..",
".oo...............",
]
sleepB = sleepA[:3] + [r for r in sleepA[4:10]] + sleepA[9:12] + ["oKKooooooooooooo..", "oo................"]
sleepB = [sleepA[0], sleepA[1]] + sleepA[3:10] + [sleepA[9]] + sleepA[10:12] + ["oKKooooooooooooo..", "oo................"]
sleepB = sleepB[:14]
# held up by the scruff: front view, legs and tail dangling (pivot = top centre)
hang = [
"...oo.....oo...",
"..oPKo...oKPo..",
"..oKKoooooKKo..",
"..oKKKkKkKKKo..",
".occkKkKkKkcco.",
".occcGcccGccco.",
".occcccPccccco.",
"..occcococcco..",
"..ooocccccooo..",
".occccccccccco.",
".occocccccocco.",
".occoccccCocco.",
".occoKkccCocco.",
".occoKKccCocco.",
".oPcoccccCocPo.",
"..occccccCcco..",
"..occccccCcco..",
"...occccccco...",
"...occoKocco...",
"...occoKocco...",
"...oCcoKocCo...",
"....oooKkoo....",
".......oKo.....",
"........o......",
]
frames = {"catWalk": walk, "catSleep": [sleepA, sleepB], "catHang": [hang]}
bad = [(k, i, j, len(r)) for k, fs in frames.items() for i, f in enumerate(fs) for j, r in enumerate(f) if len(r) != len(f[0])] + \
      [(k, i, len(f)) for k in ("catWalk", "catSleep") for i, f in enumerate(frames[k]) if len(f) != 14 or len(f[0]) != W]
assert not bad, bad
# usage: python3 tools/pommy.py [Art/room.json]  (updates the cat keys in place)
path = sys.argv[1] if len(sys.argv) > 1 else "Art/room.json"
room = json.load(open(path))
room.update(frames)
json.dump(room, open(path, "w"))
