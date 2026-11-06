# Kopiert die gebaute Mod in den UE4SS-Mod-Ordner des Spiels. Danach muss das Spiel neu starten.
param(
    [string]$GameDir = "k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE"
)
$ErrorActionPreference = 'Stop'

$target = Join-Path $GameDir 'FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess'
New-Item -ItemType Directory -Force "$target\Scripts", "$target\bin" | Out-Null

Copy-Item "$PSScriptRoot\mod\FFRSAccess\Scripts\main.lua", "$PSScriptRoot\mod\FFRSAccess\Scripts\karte_*.txt", "$PSScriptRoot\mod\FFRSAccess\Scripts\namen_spiel.txt" "$target\Scripts\" -Force
Copy-Item "$PSScriptRoot\build\ffrs_speech.dll", "$PSScriptRoot\build\prism.dll" "$target\bin\" -Force
# UE4SS startet Mods mit dieser Markierungsdatei, ohne dass mods.txt geaendert werden muss.
Set-Content -Path "$target\enabled.txt" -Value '' -Encoding Ascii

Write-Output "Mod installiert: $target"
