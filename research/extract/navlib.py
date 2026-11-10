# Liest die Navmesh-Ausgabe von "ffrs_extract nav" und baut daraus Flaechen mit Nachbarn (Unreal-Koordinaten).
# Recast-Raum (x, y, z) entspricht Unreal (-x, -z, y).
import collections
import math


class Poly:
    __slots__ = ("id", "verts", "center", "area", "links")

    def __init__(self, pid, verts, area):
        self.id = pid
        self.verts = verts
        self.area = area
        self.links = set()
        n = len(verts)
        self.center = tuple(sum(v[i] for v in verts) / n for i in range(3))


def load(path, nav_name="RecastNavMesh-Default"):
    """Liefert {level: [Poly]} fuer das gewuenschte Navmesh."""
    levels = collections.defaultdict(list)
    level = None
    use = False
    verts = []
    tile_polys = []
    tiles = []

    def flush():
        if use and tile_polys:
            tiles.append((level, tile_polys[:]))

    for line in open(path, encoding="utf-8"):
        p = line.split()
        if not p:
            continue
        if p[0] == "L":
            flush()
            tile_polys.clear()
            level, use = p[1], p[2] == nav_name
        elif p[0] == "T":
            flush()
            tile_polys.clear()
            verts = []
        elif p[0] == "V":
            x, y, z = float(p[1]), float(p[2]), float(p[3])
            verts.append((-x, -z, y))
        elif p[0] == "P":
            count = int(p[3])
            ids = [int(v) for v in p[4:4 + count]]
            neis = [int(v) for v in p[10:10 + count]]
            tile_polys.append(([verts[i] for i in ids], int(p[2]) & 0x3F, neis))
    flush()

    for lvl, polys in tiles:
        base = len(levels[lvl])
        objs = []
        for index, (pv, area, neis) in enumerate(polys):
            poly = Poly(base + index, pv, area)
            objs.append((poly, neis))
            levels[lvl].append(poly)
        for poly, neis in objs:
            for nei in neis:
                if nei and not nei & 0x8000:
                    other = levels[lvl][base + nei - 1]
                    poly.links.add(other.id)
                    other.links.add(poly.id)
    for lvl, polys in levels.items():
        connect_edges(polys)
    return levels


def edges(poly):
    v = poly.verts
    for i in range(len(v)):
        yield v[i], v[(i + 1) % len(v)]


def connect_edges(polys, tol=2.0):
    """Verbindet Flaechen ueber Kachelgrenzen: gleiche Kante (kollinear, ueberlappend, gleiche Hoehe)."""
    buckets = collections.defaultdict(list)
    for poly in polys:
        for a, b in edges(poly):
            if abs(a[0] - b[0]) < tol:  # Kante parallel zu Y
                buckets[("x", round(a[0]))].append((poly, a, b))
            elif abs(a[1] - b[1]) < tol:
                buckets[("y", round(a[1]))].append((poly, a, b))
    for (axis, _), items in buckets.items():
        k = 1 if axis == "x" else 0
        for i in range(len(items)):
            p1, a1, b1 = items[i]
            lo1, hi1 = sorted((a1[k], b1[k]))
            for j in range(i + 1, len(items)):
                p2, a2, b2 = items[j]
                if p1 is p2 or p2.id in p1.links:
                    continue
                lo2, hi2 = sorted((a2[k], b2[k]))
                if min(hi1, hi2) - max(lo1, lo2) < 5:
                    continue
                if abs((a1[2] + b1[2]) / 2 - (a2[2] + b2[2]) / 2) > 60:
                    continue
                p1.links.add(p2.id)
                p2.links.add(p1.id)


def contains(poly, x, y):
    v = poly.verts
    inside = False
    j = len(v) - 1
    for i in range(len(v)):
        xi, yi = v[i][0], v[i][1]
        xj, yj = v[j][0], v[j][1]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def find(polys, x, y, z, max_dz=250):
    best = None
    for poly in polys:
        if contains(poly, x, y):
            dz = abs(poly.center[2] - z)
            if dz <= max_dz and (best is None or dz < best[0]):
                best = (dz, poly)
    if best:
        return best[1]
    # Naechste Flaeche in der Naehe
    near = None
    for poly in polys:
        d = math.hypot(poly.center[0] - x, poly.center[1] - y) + abs(poly.center[2] - z)
        if near is None or d < near[0]:
            near = (d, poly)
    return near[1] if near and near[0] < 400 else None


def components(polys):
    comp = {}
    n = 0
    for poly in polys:
        if poly.id in comp:
            continue
        stack = [poly.id]
        comp[poly.id] = n
        while stack:
            cur = stack.pop()
            for nb in polys[cur].links:
                if nb not in comp:
                    comp[nb] = n
                    stack.append(nb)
        n += 1
    return comp
