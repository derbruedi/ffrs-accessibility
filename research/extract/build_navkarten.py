# Baut fertige Wegekarten fuer die Mod aus dem gebackenen Navmesh des Spiels (ffrs_extract nav) und den
# Objektdaten der GD-Level (Aufzuege, Sperren). Ausgabe je Karte: mod\FFRSAccess\Scripts\karte_<PL>.txt
# Zeile: ix iy z  Hoehe der Nachbarn +x -x +y -y ("-" = kein Weg)  x y  [g]
# "g" = Punkt an einer beweglichen Stelle (Sperre, Aufzugtuer, Plattform): die Mod prueft ihn im Spiel live.
import collections
import glob
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import navlib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
NAV = os.path.join(HERE, "out_full", "nav_alle.txt")
PL_LIST = os.path.join(HERE, "out_full", "pl_list.txt")
GD_DIR = os.path.join(HERE, "out_full", "gd")
TARGET = os.path.join(HERE, "..", "..", "mod", "FFRSAccess", "Scripts")
CELL = 75
LINK_DZ = 60          # groesster Hoehensprung zwischen Nachbarpunkten
LAYER_DZ = 40         # Punkte einer Zelle mit weniger Abstand sind derselbe Boden
BRIDGE_CELLS = 4      # so viele leere Zellen darf eine Luecke an einer beweglichen Stelle haben
BLOCK_RADIUS = 450    # Umkreis einer Sperre, in dem Luecken ueberbrueckt werden
STOP_RADIUS = 700     # Umkreis eines Aufzughalts
PLATFORM_RADIUS = 300 # Plattform um den Haltepunkt
SKIP = ("Wld_PL",)
# Abdeckungspruefung: Werft 04Dir_41 hat nur den Startbereich gebacken (Rest entsteht im Spiel). Solche Karten
# bekommen keine fertige Karte, die Mod erfasst sie dann selbst.
COVER_TYPES = ("TreasureBox", "SavePoint", "CallSwitch", "FieldItem", "Switch")
COVER_RADIUS = 400
COVER_HEIGHT = 400
COVER_MIN = 0.9    # Weltkarte hat eine eigene, fertige Karte (build_wege.py)

GATE_TYPES = ("BlockingBase", "BlockingBox", "Blocking_", "ElevatorWall", "BlockObject", "Door", "Gate", "Shutter",
              "Bridge", "Ladder", "Switch", "Raft")


def pl_for(nav_path, pls):
    folder = os.path.dirname(os.path.dirname(nav_path))
    cands = [p for p in pls if os.path.dirname(p) == folder]
    return os.path.splitext(os.path.basename(cands[0]))[0] if cands else None


# ---------- Objekte aus den GD-Leveln ----------

def load_gimmicks(pl):
    """Liefert (Sperren, Aufzughalte, alle Objektpunkte) mit Weltkoordinaten."""
    base = pl[:-3]  # ohne _PL
    files = glob.glob(os.path.join(GD_DIR, base + "_*GD.json")) + glob.glob(os.path.join(GD_DIR, base + "_GD.json"))
    blocks, stops, objects = [], [], []
    for path in files:
        data = json.load(open(path, encoding="utf-8"))
        level = os.path.splitext(os.path.basename(path))[0]
        comps = {}
        for o in data:
            outer = o.get("Outer")
            if isinstance(outer, dict):
                owner = outer.get("ObjectName", "").rstrip("'").split(".")[-1]
                comps[(owner, o["Name"])] = o
        for o in data:
            t = o["Type"]
            if not t.startswith("BP_"):
                continue
            props = o.get("Properties", {})
            root = props.get("RootComponent")
            if not root:
                continue
            rname = root["ObjectName"].rstrip("'").split(".")[-1]
            rc = comps.get((o["Name"], rname))
            if not rc:
                continue
            rp = rc.get("Properties", {})
            loc = rp.get("RelativeLocation")
            if not loc or rp.get("AttachParent"):
                continue
            at = (loc["X"], loc["Y"], loc["Z"])
            if any(k in t for k in COVER_TYPES) and "Floor_" not in t:
                objects.append((o["Name"], at))
            yaw = math.radians(rp.get("RelativeRotation", {}).get("Yaw", 0.0))
            if "Floor_" in t or "Elevator_Interact" in t:
                spline = None
                sref = props.get("Spline")
                if sref:
                    spline = comps.get((o["Name"], sref["ObjectName"].rstrip("'").split(".")[-1]))
                pts = []
                if spline:
                    for pt in spline.get("Properties", {}).get("SplineCurves", {}).get("Position", {}).get("Points", []):
                        v = pt.get("OutVal")
                        if v:
                            x = v["X"] * math.cos(yaw) - v["Y"] * math.sin(yaw)
                            y = v["X"] * math.sin(yaw) + v["Y"] * math.cos(yaw)
                            pts.append((at[0] + x, at[1] + y, at[2] + v["Z"]))
                if not pts:
                    pts = [at]
                stops.append((level + ":" + o["Name"], pts))
            elif any(g in t for g in GATE_TYPES):
                blocks.append((o["Name"], at))
    return blocks, stops, objects


def coverage(grid, objects):
    """Anteil der Objekte (Truhen, Speicherpunkte, Ausgaenge ...) mit Navmesh in der Naehe."""
    if not objects:
        return 1.0, []
    missing = []
    for name, (x, y, z) in objects:
        found = False
        cx, cy = round(x / CELL), round(y / CELL)
        r = COVER_RADIUS // CELL + 1
        for ix in range(cx - r, cx + r + 1):
            for iy in range(cy - r, cy + r + 1):
                for n in grid.cells.get((ix, iy), ()):
                    if math.hypot(n.x - x, n.y - y) <= COVER_RADIUS and abs(n.z - z) <= COVER_HEIGHT:
                        found = True
                        break
        if not found:
            missing.append(name)
    return 1 - len(missing) / len(objects), missing


# ---------- Raster aus dem Navmesh ----------

def plane_z(poly, x, y):
    v = poly.verts
    a = v[0]
    for i in range(1, len(v) - 1):
        b, c = v[i], v[i + 1]
        det = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(det) < 1e-9:
            continue
        l1 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (y - c[1])) / det
        l2 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (y - c[1])) / det
        l3 = 1 - l1 - l2
        if l1 >= -0.01 and l2 >= -0.01 and l3 >= -0.01:
            return l1 * a[2] + l2 * b[2] + l3 * c[2]
    return poly.center[2]


class Node:
    __slots__ = ("ix", "iy", "z", "x", "y", "polys", "links", "gate")

    def __init__(self, ix, iy, z, x, y, poly, gate=False):
        self.ix, self.iy, self.z, self.x, self.y = ix, iy, z, x, y
        self.polys = {poly} if poly is not None else set()
        self.links = [None, None, None, None]
        self.gate = gate


DIRS = ((1, 0, 1), (-1, 0, 0), (0, 1, 3), (0, -1, 2))


class Grid:
    def __init__(self):
        self.cells = collections.defaultdict(list)

    def at(self, ix, iy, z, dz=LAYER_DZ):
        best = None
        for n in self.cells.get((ix, iy), ()):
            d = abs(n.z - z)
            if d <= dz and (best is None or d < abs(best.z - z)):
                best = n
        return best

    def add(self, ix, iy, z, x, y, poly, gate=False):
        n = self.at(ix, iy, z)
        if n:
            if poly is not None:
                n.polys.add(poly)
            return n, False
        n = Node(ix, iy, z, x, y, poly, gate)
        self.cells[(ix, iy)].append(n)
        return n, True

    def nodes(self):
        for lst in self.cells.values():
            yield from lst


def rasterize(polys):
    grid = Grid()
    for poly in polys:
        xs = [v[0] for v in poly.verts]
        ys = [v[1] for v in poly.verts]
        hit = False
        for ix in range(math.ceil(min(xs) / CELL), math.floor(max(xs) / CELL) + 1):
            for iy in range(math.ceil(min(ys) / CELL), math.floor(max(ys) / CELL) + 1):
                x, y = ix * CELL, iy * CELL
                if navlib.contains(poly, x, y):
                    grid.add(ix, iy, plane_z(poly, x, y), x, y, poly.id)
                    hit = True
        # Schmale Flaechen (Tuerdurchgaenge) treffen oft keine Zellmitte: Mittelpunkt und Kantenmitten nehmen.
        samples = [poly.center[:2]]
        if not hit or (max(xs) - min(xs)) < 2 * CELL or (max(ys) - min(ys)) < 2 * CELL:
            v = poly.verts
            for i in range(len(v)):
                a, b = v[i], v[(i + 1) % len(v)]
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                samples.append((mx * 0.8 + poly.center[0] * 0.2, my * 0.8 + poly.center[1] * 0.2))
        for x, y in samples:
            ix, iy = round(x / CELL), round(y / CELL)
            z = plane_z(poly, x, y)
            if not grid.at(ix, iy, z):
                grid.add(ix, iy, z, x, y, poly.id)
    return grid


def link(grid, polys):
    near = {}
    for p in polys:
        s = set(p.links)
        for q in p.links:
            s |= polys[q].links
        s.add(p.id)
        near[p.id] = s
    for n in grid.nodes():
        for d, (dx, dy, back) in enumerate(DIRS):
            if n.links[d] is not None:
                continue
            m = grid.at(n.ix + dx, n.iy + dy, n.z, LINK_DZ)
            if not m:
                continue
            ok = n.gate or m.gate or any(near[a] & m.polys for a in n.polys)
            if ok:
                n.links[d] = m
                m.links[back] = n


def near_any(x, y, z, points, radius):
    for px, py, pz in points:
        if abs(px - x) <= radius and abs(py - y) <= radius and abs(pz - z) <= 400 \
                and math.hypot(px - x, py - y) <= radius:
            return True
    return False


def add_platforms(grid, stops):
    """Kopiert die gebackene Plattform eines Aufzugs an jeden Halt (die Plattform faehrt, das Navmesh nicht)."""
    added = 0
    for name, pts in stops:
        if len(pts) < 2:
            continue
        baked = None
        for sx, sy, sz in pts:
            cells = []
            for ix in range(round((sx - PLATFORM_RADIUS) / CELL), round((sx + PLATFORM_RADIUS) / CELL) + 1):
                for iy in range(round((sy - PLATFORM_RADIUS) / CELL), round((sy + PLATFORM_RADIUS) / CELL) + 1):
                    for n in grid.cells.get((ix, iy), ()):
                        if abs(n.z - sz) < 80 and math.hypot(n.x - sx, n.y - sy) <= PLATFORM_RADIUS:
                            cells.append(n)
            if len(cells) >= 4:
                baked = ((sx, sy, sz), cells)
                break
        if not baked:
            continue
        (bx, by, bz), cells = baked
        for sx, sy, sz in pts:
            dxw, dyw, dzw = sx - bx, sy - by, sz - bz
            if abs(dxw) < 1 and abs(dyw) < 1 and abs(dzw) < 1:
                continue
            for n in cells:
                x, y = n.x + dxw, n.y + dyw
                _, new = grid.add(round(x / CELL), round(y / CELL), n.z + dzw, x, y, None, gate=True)
                added += new
    return added


def bridge(grid, blocks, stops):
    """Fuellt kurze Luecken im Navmesh an beweglichen Stellen mit live zu pruefenden Punkten."""
    points = [b[1] for b in blocks]
    stop_pts = [p for _, pts in stops for p in pts]
    made = 0
    for n in list(grid.nodes()):
        for d, (dx, dy, back) in enumerate(DIRS):
            if n.links[d] is not None:
                continue
            for k in range(2, BRIDGE_CELLS + 2):
                m = grid.at(n.ix + dx * k, n.iy + dy * k, n.z, LINK_DZ)
                if not m:
                    continue
                mid = ((n.x + m.x) / 2, (n.y + m.y) / 2, (n.z + m.z) / 2)
                if not (near_any(*mid, points, BLOCK_RADIUS) or near_any(*mid, stop_pts, STOP_RADIUS)):
                    break
                chain = [n]
                free = True
                for j in range(1, k):
                    z = n.z + (m.z - n.z) * j / k
                    if grid.at(n.ix + dx * j, n.iy + dy * j, z, LINK_DZ):
                        free = False
                        break
                if not free:
                    break
                for j in range(1, k):
                    z = n.z + (m.z - n.z) * j / k
                    g, _ = grid.add(n.ix + dx * j, n.iy + dy * j, z, (n.ix + dx * j) * CELL, (n.iy + dy * j) * CELL,
                                    None, gate=True)
                    chain.append(g)
                    made += 1
                chain.append(m)
                for a, b in zip(chain, chain[1:]):
                    a.links[d] = b
                    b.links[back] = a
                break
    return made


def write(grid, path, stops):
    with open(path, "w", encoding="ascii", newline="\n") as out:
        # Aufzughalte: "A <Level>:<Objekt> <Index> x y z", Index wie m_CallFloorIndex der Rufschalter.
        for name, pts in stops:
            if len(pts) >= 2:
                for i, (x, y, z) in enumerate(pts):
                    out.write("A %s %d %d %d %d\n" % (name, i, round(x), round(y), round(z)))
        for n in grid.nodes():
            z = round(n.z)
            parts = [str(n.ix), str(n.iy), str(z)]
            for m in n.links:
                parts.append(str(round(m.z)) if m is not None else "-")
            parts += [str(round(n.x)), str(round(n.y))]
            if n.gate:
                parts.append("g")
            out.write(" ".join(parts) + "\n")


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    pls = [l.strip() for l in open(PL_LIST) if l.strip()]
    levels = navlib.load(NAV)
    by_pl = collections.defaultdict(list)
    for nav_path, polys in levels.items():
        pl = pl_for(nav_path, pls)
        if pl and pl not in SKIP:
            by_pl[pl].append(polys)
    for pl, groups in sorted(by_pl.items()):
        if only and only not in pl:
            continue
        polys = [p for g in groups for p in g]
        if len(groups) > 1:  # Ids neu vergeben
            for i, p in enumerate(polys):
                p.id = i
        grid = rasterize(polys)
        blocks, stops, objects = load_gimmicks(pl)
        plat = add_platforms(grid, stops)
        link(grid, polys)
        made = bridge(grid, blocks, stops)
        link(grid, polys)
        count = sum(1 for _ in grid.nodes())
        share, missing = coverage(grid, objects)
        target = os.path.join(TARGET, "karte_" + pl + ".txt")
        if share < COVER_MIN:
            if os.path.exists(target):
                os.remove(target)
            print(f"{pl}: AUSGELASSEN, nur {share:.0%} von {len(objects)} Objekten auf dem Navmesh, fehlt z. B. "
                  f"{', '.join(missing[:4])}")
            continue
        write(grid, target, stops)
        print(f"{pl}: {len(polys)} Flaechen, {count} Punkte, {len(blocks)} Sperren, {len(stops)} Aufzuege, "
              f"{plat} Plattformpunkte, {made} Brueckenpunkte, Abdeckung {share:.0%} von {len(objects)}")


if __name__ == "__main__":
    main()
