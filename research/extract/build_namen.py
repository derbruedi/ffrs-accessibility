# Baut die Namensliste der Figuren aus den Spieldaten: Figur -> Gespraech -> Sprecher -> deutscher Name.
# Vorher: ffrs_extract locres de game_de.tsv; dumpall talk <FreeTalk und EV>; dump ST_CharaName, ST_UnitName, DT_MapUnitAsset.
import collections
import glob
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

OUT = r"H:\ff\research\extract\out_full"  # Vollversion; die Demo-Auszuege liegen in out
TARGET = r"H:\ff\mod\FFRSAccess\Scripts\namen_spiel.txt"
PARTY = {"レイン", "ラスウェル", "フィーナ"}
# m_PointName gibt es nur japanisch, die Sprachdatei kennt die Schluessel nicht. Genannt wird nur, was als Wort
# im Spiel vorkommt ("Begib dich zum Thronsaal", ST_MainProgress); eigene Uebersetzungen gibt es nicht.
POINTS = {
    "グランシェルト城内玉座の間": "Thronsaal",
}


def load(name):
    return json.load(open(name, encoding="utf-8"))


german = collections.defaultdict(dict)
for line in open(OUT + r"\game_de.tsv", encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 3:
        german[parts[0]][parts[1]] = parts[2]

source_to_german = {}
for table in ("ST_CharaName", "ST_UnitName"):
    entries = load(os.path.join(OUT, table + ".json"))[0]["StringTable"]["KeysToEntries"]
    for key, source in entries.items():
        text = german[table].get(key)
        if source and text:
            source_to_german.setdefault(source, text)
print("Namen mit Uebersetzung:", len(source_to_german))

# Figur-IDs taugen nicht als Name: Sie bezeichnen das Aussehen (Soldat als "Charlotte"), nur der Sprecher zaehlt.
talk_events = {}
for file in glob.glob(os.path.join(OUT, "talkdata", "*.json")):
    talk_events.update(load(file)[0].get("Rows") or {})
print("Gespraeche im Verzeichnis:", len(talk_events))


def named(rows):
    return [row.get("Speaker") for row in rows if row.get("Speaker") not in ("None", "", "？？？")]


def own_table(event_id):
    event = talk_events.get(event_id) or {}
    table = (event.get("TalkEventDataTable") or {}).get("AssetPathName", "").rsplit(".", 1)[-1]
    return table == "DT_" + event_id


def speakers(event_id):
    event = talk_events.get(event_id)
    if not event:
        return []
    table = event["TalkEventDataTable"]["AssetPathName"].rsplit(".", 1)[-1]
    path = os.path.join(OUT, "talk", table + ".json")
    if not table or not os.path.exists(path):
        return []
    rows = list((load(path)[0].get("Rows") or {}).values())
    # Eigene Tabelle des Ereignisses (DT_SubEv_C01_Lasswell_01 fuer SubEv_C01_Lasswell_01): Szenen nummerieren
    # jede Zeile mit TalkId, die ganze Tabelle ist ein Gespraech.
    if own_table(event_id):
        return named(rows)
    # Sammeltabellen: Die Argumente nennen den Abschnitt, begrenzt von Zeilen mit TalkId.
    args = {entry["Key"]: entry["Value"] for entry in event.get("ArgList", [])}
    ids = [row.get("TalkId") for row in rows]
    if "id1" in args and "id2" in args:
        first, last = int(args["id1"]), int(args["id2"])
        if first in ids and last in ids:
            rows = rows[ids.index(first):ids.index(last)]
    elif "id" in args or "talkId" in args:
        # Nur ein Abschnitt: von seiner TalkId bis zur naechsten Zeile mit TalkId.
        first = int(args.get("id", args.get("talkId")))
        if first not in ids:
            return []
        start = ids.index(first) + 1
        end = next((i for i in range(start, len(ids)) if isinstance(ids[i], int) and ids[i] >= 0), len(ids))
        rows = rows[start:end]
    elif sum(1 for talk_id in ids if isinstance(talk_id, int) and talk_id >= 0) > 1:
        # Sammeltabelle ohne Abschnitt (etwa Gim_EV_ShipMovement): wer dort spricht, ist unbekannt.
        return []
    return named(rows)


def event_ids(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "EventId" and isinstance(value, str):
                yield value
            else:
                yield from event_ids(value)
    elif isinstance(node, list):
        for value in node:
            yield from event_ids(value)


names = {}
counts = collections.Counter()
unknown = collections.Counter()
for level in glob.glob(os.path.join(OUT, "talk", "*_EV.json")):
    for export in load(level):
        if "MapUnit_NPC" not in export.get("Type", "") and "MapUnit_NPC" not in export.get("Class", ""):
            continue
        properties = export.get("Properties") or {}
        package = export["Outer"]["ObjectPath"].rsplit(".", 1)[0]
        path = f"{package}.{package.rsplit('/', 1)[-1]}:PersistentLevel.{export['Name']}"
        found = collections.Counter()
        scenes = collections.Counter()
        for event in event_ids(properties.get("m_EventSettings")):
            (scenes if own_table(event) else found).update(speakers(event))
        # In Szenen reden oft Hauptfiguren mit; sie zaehlen nur, wenn die Figur kein eigenes Gespraech hat.
        if not found:
            found = scenes
        # Die Spielfiguren antworten in fremden Gespraechen; sie zaehlen nur, wenn sonst niemand spricht.
        others = collections.Counter({who: n for who, n in found.items() if who not in PARTY}) or found
        source = others.most_common(1)[0][0] if others else None
        text = source_to_german.get(source)
        if text:
            names[path] = text
            counts["Name"] += 1
        else:
            counts["ohne Gespraech" if not found else "ohne Uebersetzung"] += 1
            if found:
                unknown[source] += 1
print(counts)
print("Ohne Uebersetzung, haeufigste:", unknown.most_common(15))
for path, text in list(names.items())[:12]:
    print(" ", path.rsplit(".", 1)[-1], text, "|", path.split("/")[-1].split(".")[0])
print("Schloss:")
for path, text in names.items():
    if "01Gra_42" in path:
        print(" ", path.rsplit(".", 1)[-1], text)
if "--write" in sys.argv:
    with open(TARGET, "w", encoding="utf-8", newline="\n") as file:
        for path, text in sorted(names.items()):
            file.write(f"{path}\t{text}\n")
        for source, text in POINTS.items():
            file.write(f"Punkt {source}\t{text}\n")
    print("Geschrieben:", TARGET, len(names))
