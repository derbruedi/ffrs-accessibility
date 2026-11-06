# Uebernimmt die beim Spielen gelernten Namen (npc_names.txt im Spielordner) in die mitgelieferte Liste
# mod\FFRSAccess\Scripts\namen_gelernt.txt, damit sie mit dem naechsten Setup alle haben.
# Weitere Dateien (etwa von anderen Spielern geschickte npc_names.txt) mit -Extra anhaengen; spaetere gewinnen.
param(
    [string]$GameDir = "k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE",
    [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$target = Join-Path $root 'mod\FFRSAccess\Scripts\namen_gelernt.txt'
$sources = @($target, (Join-Path $GameDir 'FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess\Scripts\npc_names.txt')) + $Extra

$names = [ordered]@{}
foreach ($source in $sources) {
    if (-not (Test-Path $source)) { continue }
    foreach ($line in [System.IO.File]::ReadAllLines($source, [System.Text.Encoding]::UTF8)) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and $parts[0] -and $parts[1].Trim()) {
            $names[$parts[0]] = $parts[1].Trim()
        }
    }
}
$lines = $names.Keys | Sort-Object | ForEach-Object { "$_`t$($names[$_])" }
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($target, (($lines -join "`n") + "`n"), $utf8)
Write-Output "Gelernte Namen: $($names.Count) in $target"
