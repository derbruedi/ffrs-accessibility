# Baut die fertige Wegekarte der Weltkarte aus dem Kollisionsmodell SM_Wld_PL (Waende) und einem Scan der Mod (Bodenhoehen).
# Zeile je Punkt: ix iy z  Hoehe der Nachbarn +x -x +y -y ("-" = kein Weg)  x y (genaue Lage in der Zelle)
import collections
import struct
import sys

import numpy as np

OUT = r"H:\ff\research\extract\out"
MOD = r"k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE\FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess\Scripts"
SCAN = MOD + r"\wege75_Wld_PL.txt"
TARGET = r"H:\ff\mod\FFRSAccess\Scripts\karte_Wld_PL.txt"
GRID = 75
CELL = 20
STEP_HEIGHT = 20
FIGURE_HEIGHT = 66
MAX_RISE = 85
X0, Y0 = -23000, -20600
W, H = 46200 // CELL, 43900 // CELL

data = open(OUT + r"\SM_Wld_PL.bin", "rb").read()
nv, ni = struct.unpack_from("<ii", data, 0)
verts = np.frombuffer(data, "<f4", nv * 3, 8).reshape(-1, 3).astype(np.float64)
idx = np.frombuffer(data, "<u4", ni, 8 + nv * 12).reshape(-1, 3)
tri = verts[idx]

ground = {}
for line in open(SCAN):
    p = line.split()
    key = (int(p[0]), int(p[1]))
    ground[key] = max(ground.get(key, -9999), int(p[2]))
print("Bodenpunkte aus dem Scan:", len(ground))


def floor_at(x, y):
    i, j = round(x / GRID), round(y / GRID)
    for r in range(3):
        best = None
        for di in range(-r, r + 1):
            for dj in range(-r, r + 1):
                z = ground.get((i + di, j + dj))
                if z is not None and (best is None or z > best):
                    best = z
        if best is not None:
            return best
    return None


wall = np.zeros((H, W), dtype=bool)
kept = dropped = 0
for t in tri:
    floor = floor_at(t[:, 0].mean(), t[:, 1].mean())
    # Waende, die ganz unter dem Boden oder ueber dem Kopf liegen, stoeren die Figur nicht.
    if floor is not None and (t[:, 2].max() < floor + STEP_HEIGHT or t[:, 2].min() > floor + FIGURE_HEIGHT):
        dropped += 1
        continue
    kept += 1
    for a, b in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
        steps = max(int(np.hypot(b[0] - a[0], b[1] - a[1]) / (CELL / 2)), 1)
        s = np.linspace(0, 1, steps + 1)
        i = ((a[0] + (b[0] - a[0]) * s - X0) / CELL).astype(int)
        j = ((a[1] + (b[1] - a[1]) * s - Y0) / CELL).astype(int)
        ok = (i >= 0) & (i < W) & (j >= 0) & (j < H)
        wall[j[ok], i[ok]] = True
print("Dreiecke wirksam", kept, "nicht in Koerperhoehe", dropped)

# Die Figur hat Radius 19: Waende um eine Zelle verdicken.
fat = wall.copy()
fat[1:, :] |= wall[:-1, :]
fat[:-1, :] |= wall[1:, :]
fat[:, 1:] |= wall[:, :-1]
fat[:, :-1] |= wall[:, 1:]


def blocked(x, y):
    i, j = int((x - X0) / CELL), int((y - Y0) / CELL)
    return not (0 <= i < W and 0 <= j < H) or fat[j, i]


def line_free(a, b):
    steps = max(int(np.hypot(b[0] - a[0], b[1] - a[1]) / (CELL / 2)), 1)
    return not any(blocked(a[0] + (b[0] - a[0]) * s / steps, a[1] + (b[1] - a[1]) * s / steps) for s in range(steps + 1))


# Je Rasterzelle der freie Punkt, der am naechsten an ihrer Mitte liegt: Enge Durchgaenge bleiben so erhalten.
OFFSETS = sorted(((dx, dy) for dx in range(-30, 31, 10) for dy in range(-30, 31, 10)), key=lambda o: o[0] ** 2 + o[1] ** 2)
points = {}
for (ix, iy) in ground:
    for dx, dy in OFFSETS:
        x, y = ix * GRID + dx, iy * GRID + dy
        if not blocked(x, y):
            points[(ix, iy)] = (x, y)
            break
print("Punkte frei:", len(points), "in Wand:", len(ground) - len(points))

links = collections.defaultdict(dict)
DIRECTIONS = ((1, 0), (-1, 0), (0, 1), (0, -1))
for key, here in points.items():
    for index, (dx, dy) in enumerate(DIRECTIONS):
        other = (key[0] + dx, key[1] + dy)
        there = points.get(other)
        if there and abs(ground[key] - ground[other]) <= MAX_RISE and line_free(here, there):
            links[key][index] = other


def component(start):
    seen, queue = {start}, collections.deque([start])
    while queue:
        node = queue.popleft()
        for other in links[node].values():
            if other not in seen:
                seen.add(other)
                queue.append(other)
    return seen


def nearest(x, y):
    return min(points, key=lambda k: (points[k][0] - x) ** 2 + (points[k][1] - y) ** 2)


def route_length(a, b):
    previous, queue = {a: None}, collections.deque([a])
    while queue:
        node = queue.popleft()
        if node == b:
            break
        for other in links[node].values():
            if other not in previous:
                previous[other] = node
                queue.append(other)
    if b not in previous:
        return None, None
    path, node = [], b
    while node is not None:
        path.append(points[node])
        node = previous[node]
    path.reverse()
    return sum(np.hypot(p[0] - q[0], p[1] - q[1]) for p, q in zip(path, path[1:])) / 100, path


mitra = nearest(16617, 21717)
area = component(mitra)
print("Gebiet ab Mitra:", len(area), "Punkte")
for name, x, y in (("Erdschrein", 17961, 20921), ("Residenzstadt", 12719, 20702), ("Haenger A", 14041, 21426), ("Haenger B", 13963, 21653)):
    node = nearest(x, y)
    length, path = route_length(mitra, node)
    print(f"  {name}: naechster Punkt {points[node]}, im Gebiet {node in area}, Weg {length and round(length)} m")
    if name == "Residenzstadt" and path:
        print("  Weg:", path[::6])

if "--write" in sys.argv:
    with open(TARGET, "w") as file:
        for key in area:
            cells = []
            for index in range(4):
                other = links[key].get(index)
                cells.append(str(ground[other]) if other else "-")
            x, y = points[key]
            file.write(f"{key[0]} {key[1]} {ground[key]} {' '.join(cells)} {x} {y}\n")
    print("Geschrieben:", TARGET, len(area), "Punkte")
