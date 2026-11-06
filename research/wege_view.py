# Zeigt eine gespeicherte Wegekarte als Textraster: Aufruf mit dem Dateipfad.
import sys

CELL = 75
rows = []
for line in open(sys.argv[1], encoding="ascii"):
    parts = line.split()
    rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3:]))

print("Punkte", len(rows))
print("X", min(r[0] for r in rows) * CELL, max(r[0] for r in rows) * CELL)
print("Y", min(r[1] for r in rows) * CELL, max(r[1] for r in rows) * CELL)
print("Hoehen", sorted({r[2] for r in rows}))

cells = {}
for ix, iy, z, links in rows:
    cells.setdefault((ix, iy), []).append(z)
xs = sorted({r[0] for r in rows})
for iy in range(max(r[1] for r in rows), min(r[1] for r in rows) - 1, -1):
    text = "".join(
        ("#" if len(cells[(ix, iy)]) > 1 else ("." if cells[(ix, iy)][0] <= -250 else "o")) if (ix, iy) in cells else " "
        for ix in range(xs[0], xs[-1] + 1)
    )
    print(f"{iy * CELL:>6} {text}")
print("Spalte links = X", xs[0] * CELL, "; o = Boden ueber -250, . = darunter")
