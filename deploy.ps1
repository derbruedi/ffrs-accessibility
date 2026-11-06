# Kopiert die gebaute Mod in den UE4SS-Mod-Ordner des Spiels. Danach muss das Spiel neu starten.
param(
    [string]$GameDir = "k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE"
)
$ErrorActionPreference = 'Stop'

$target = Join-Path $GameDir 'FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess'
New-Item -ItemType Directory -Force "$target\Scripts", "$target\bin" | Out-Null

Copy-Item "$PSScriptRoot\mod\FFRSAccess\Scripts\main.lua", "$PSScriptRoot\mod\FFRSAccess\Scripts\karte_*.txt", "$PSScriptRoot\mod\FFRSAccess\Scripts\namen_spiel.txt", "$PSScriptRoot\mod\FFRSAccess\Scripts\namen_gelernt.txt" "$target\Scripts\" -Force
Copy-Item "$PSScriptRoot\build\ffrs_speech.dll", "$PSScriptRoot\build\prism.dll" "$target\bin\" -Force -ErrorAction Continue
# Die Mod sagt beim Laden die Version an; die Datei schreibt sonst nur der Paketbau.
Set-Content -Path "$target\version.txt" -Value (Get-Content "$PSScriptRoot\VERSION" -TotalCount 1).Trim() -Encoding Ascii
# UE4SS startet Mods mit dieser Markierungsdatei, ohne dass mods.txt geaendert werden muss.
Set-Content -Path "$target\enabled.txt" -Value '' -Encoding Ascii

Write-Output "Mod installiert: $target"
