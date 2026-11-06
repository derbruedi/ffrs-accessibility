# Baut das Kartennetz fuer die Auftragswege: welche Karte per Ausgang zu welcher fuehrt.
# Vorher: ffrs_extract dumpall mapdata "Datatable/Map/MapData/DT_MapData_.*\.uasset$"
#         ffrs_extract dumpall gd "/Map/.*_GD(_\d+)?\.umap$"
# Ausgabe je Zeile "<von>\t<nach>". Bedingungen der Ausgaenge fehlen hier, die prueft die Mod im Spiel.
import collections
import glob
import json
import os
import sys

OUT = r"H:\ff\research\extract\out_full"
TARGET = r"H:\ff\mod\FFRSAccess\Scripts\karte_netz.txt"

folders = {}
for file in glob.glob(os.path.join(OUT, "mapdata", "*.json")):
    for row in (json.load(open(file, encoding="utf-8"))[0].get("Rows") or {}).values():
        folders[row["Level"]["AssetPathName"].rsplit("/", 1)[0]] = row["ID"]
print("Karten:", len(folders))

links = collections.defaultdict(set)
unknown = collections.Counter()
for file in glob.glob(os.path.join(OUT, "gd", "*.json")):
    for export in json.load(open(file, encoding="utf-8")):
        if export.get("Type") != "BP_MapTransitionTrigger_C":
            continue
        properties = export.get("Properties") or {}
        box = properties.get("m_pRootBoxComponent") or {}
        package = box.get("ObjectPath", "").split(".")[0]
        source = folders.get(package.split("/GD/")[0])
        if source is None:
            unknown[package] += 1
            continue
        if properties.get("m_IsSameMapTrasition"):
            continue
        targets = {properties.get("m_MapId")}
        targets.update(data.get("mapId") for data in properties.get("mTransitionDataList", []))
        for target in targets:
            if isinstance(target, int) and target > 0 and target != source:
                links[source].add(target)
print("Karten mit Ausgaengen:", len(links), "Verbindungen:", sum(len(v) for v in links.values()))
if unknown:
    print("Ohne Karte:", unknown.most_common(5))
if "--write" in sys.argv:
    with open(TARGET, "w", encoding="utf-8", newline="\n") as file:
        for source in sorted(links):
            for target in sorted(links[source]):
                file.write(f"{source}\t{target}\n")
    print("Geschrieben:", TARGET)
