# FINAL FANTASY RESONANCE Zugang

Eine Barrierefreiheits-Mod, die FINAL FANTASY RESONANCE für blinde Spieler über einen Screenreader spielbar macht (NVDA, JAWS und andere über die Bibliothek Prism). Sie liest Menüs, Dialoge, Gespräche, Kämpfe und Ergebnisse vor und hat einen Pathfinder, der die Figur zu Personen, Schätzen, Ausgängen und Questzielen läuft.

Die Mod läuft mit [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) im Spiel mit. Sie verändert keine Spieldateien und umgeht keinen Kopierschutz.

**Stand: Beta.** Versionen mit `b` sind Betaversionen.

## Installation

1. Unter [Releases](https://github.com/derbruedi/ffrs-accessibility/releases) die neueste `FFRSAccess-Setup.exe` herunterladen.
2. Das Spiel beenden und das Setup starten. Es findet das Spiel in den Steam-Bibliotheken, Enter installiert.
3. Beim Start prüft das Setup, ob es auf GitHub eine neuere Version gibt, und bietet an, sie herunterzuladen und gleich zu installieren.

Tasten und Hinweise stehen in [installer/Liesmich.txt](installer/Liesmich.txt).

## Aufbau

- `mod/FFRSAccess/Scripts/main.lua` – die Mod (UE4SS-Lua)
- `native/ffrs_speech.cpp` – Sprach-DLL über eine Named Pipe zu Prism
- `installer/` – Setup (`gui/`, WinForms, .NET Framework 4.8), Skript-Installer, Paketbau `build_package.ps1`, Veröffentlichung `release.ps1`
- `research/extract/` – Werkzeuge, die Namen und Wegekarten aus den Spieldaten erzeugen (die Spieldaten selbst liegen nicht im Repo)

## Neue Version veröffentlichen

1. Nummer in `VERSION` erhöhen (z. B. `0.1.1b`).
2. `installer\release.ps1` ausführen: baut das Setup, legt den Tag `v<Version>` an und lädt Setup und Zip als Release hoch. Versionen mit Buchstaben werden als Vorabversion markiert.

## Lizenzen

UE4SS: MIT-Lizenz. Prism: MPL-2.0, die Lizenzen der Bestandteile liegen in `third_party/prism/LICENSES`.
