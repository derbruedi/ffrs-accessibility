# Installiert den FFRS-Zugang (UE4SS und die Mod FFRSAccess) in einen Spielordner von FINAL FANTASY RESONANCE.
# Aufruf ueber Installieren.bat; der Spielordner wird abgefragt oder mit -GameDir uebergeben.
param(
    [string]$GameDir,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'dateien'
$exeRelative = 'FFRS\Binaries\Win64\FFRS-Win64-Shipping.exe'

function Write-Step([string]$text) {
    Write-Host $text
}

# Read-Host liefert ohne Eingabe (umgeleitete Konsole) nichts; dann gilt die Antwort als leer.
function Ask([string]$prompt) {
    $answer = Read-Host $prompt
    if ($null -eq $answer) { return '' }
    return "$answer".Trim()
}

# Steam-Bibliotheken aus libraryfolders.vdf, darin jeder Ordner, der mit FINAL FANTASY RESONANCE beginnt.
function Find-GameDirs {
    $found = @()
    $steam = $null
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($item.SteamPath) { $steam = $item.SteamPath } elseif ($item.InstallPath) { $steam = $item.InstallPath }
        } catch {}
        if ($steam) { break }
    }
    $libraries = @()
    if ($steam) {
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($match in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += $match.Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $common = Join-Path $library 'steamapps\common'
        if (Test-Path $common) {
            foreach ($dir in Get-ChildItem $common -Directory -Filter 'FINAL FANTASY RESONANCE*' -ErrorAction SilentlyContinue) {
                if (Test-Path (Join-Path $dir.FullName $exeRelative)) { $found += $dir.FullName }
            }
        }
    }
    # Vollversion vor der Demo vorschlagen.
    return @($found | Sort-Object { if ($_ -match 'DEMO') { 1 } else { 0 } })
}

# Akzeptiert den Spielordner selbst, aber auch FFRS oder Win64 darin.
function Resolve-GameDir([string]$path) {
    $path = $path.Trim().Trim('"')
    if (-not $path) { return $null }
    $candidate = $path
    for ($i = 0; $i -lt 4; $i++) {
        if (Test-Path (Join-Path $candidate $exeRelative)) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path $candidate -Parent
        if (-not $parent) { break }
        $candidate = $parent
    }
    return $null
}

Write-Step 'FINAL FANTASY RESONANCE Zugang, Installation.'
if (-not $GameDir) {
    $suggestions = @(Find-GameDirs)
    $suggestion = $suggestions | Select-Object -First 1
    if ($suggestion) {
        Write-Step "Gefundener Spielordner: $suggestion"
        if ($suggestions.Count -gt 1) {
            Write-Step ('Weitere gefundene Ordner: ' + (($suggestions | Select-Object -Skip 1) -join '; '))
        }
        $answer = (Ask 'Enter drücken, um diesen Ordner zu nehmen, oder einen anderen Spielordner eingeben')
        $GameDir = if ($answer) { $answer } else { $suggestion }
    } else {
        $GameDir = (Ask 'Kein Spielordner gefunden. Bitte den Spielordner eingeben, zum Beispiel C:\Program Files (x86)\Steam\steamapps\common\FINAL FANTASY RESONANCE')
    }
}
$game = Resolve-GameDir $GameDir
if (-not $game) {
    Write-Step "In diesem Ordner liegt kein FINAL FANTASY RESONANCE: $GameDir"
    Write-Step "Erwartet wird die Datei $exeRelative darin."
    exit 1
}
$win64 = Join-Path $game 'FFRS\Binaries\Win64'
$ue4ss = Join-Path $win64 'ue4ss'
$modDir = Join-Path $ue4ss 'Mods\FFRSAccess'
Write-Step "Spielordner: $game"

$running = Get-Process -Name 'FFRS-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($win64, [System.StringComparison]::OrdinalIgnoreCase)
}
if ($running) {
    Write-Step 'Das Spiel läuft gerade. Bitte das Spiel beenden und den Installer noch einmal starten.'
    exit 1
}

if ($Uninstall) {
    if (Test-Path $modDir) {
        Remove-Item $modDir -Recurse -Force
        Write-Step 'Mod FFRSAccess entfernt.'
    } else {
        Write-Step 'Mod FFRSAccess war nicht installiert.'
    }
    $answer = (Ask 'Auch UE4SS entfernen? Dann laufen andere UE4SS-Mods ebenfalls nicht mehr. j für ja, Enter für nein')
    if ($answer.ToLower() -eq 'j') {
        if (Test-Path (Join-Path $ue4ss 'UE4SS.dll')) {
            Remove-Item (Join-Path $win64 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
            Remove-Item $ue4ss -Recurse -Force
            Write-Step 'UE4SS entfernt.'
        }
    }
    Write-Step 'Deinstallation fertig.'
    exit 0
}

# UE4SS: Einstellungen und Mod-Liste eines vorhandenen UE4SS bleiben erhalten, nur Programmdateien werden ersetzt.
$hadUe4ss = Test-Path (Join-Path $ue4ss 'UE4SS.dll')
New-Item -ItemType Directory -Force (Join-Path $ue4ss 'Mods') | Out-Null
Copy-Item (Join-Path $payload 'Win64\dwmapi.dll') $win64 -Force
Copy-Item (Join-Path $payload 'Win64\ue4ss\UE4SS.dll'), (Join-Path $payload 'Win64\ue4ss\LICENSE') $ue4ss -Force
foreach ($name in 'UE4SS-settings.ini', 'Mods\mods.txt') {
    $target = Join-Path $ue4ss $name
    if (-not (Test-Path $target)) {
        Copy-Item (Join-Path $payload "Win64\ue4ss\$name") $target
    }
}
foreach ($standardMod in Get-ChildItem (Join-Path $payload 'Win64\ue4ss\Mods') -Directory | Where-Object { $_.Name -ne 'FFRSAccess' }) {
    Copy-Item $standardMod.FullName (Join-Path $ue4ss 'Mods') -Recurse -Force
}
Write-Step ($(if ($hadUe4ss) { 'UE4SS aktualisiert, Einstellungen behalten.' } else { 'UE4SS installiert.' }))

# Mod: Dateien ersetzen, gelernte Namen (npc_names.txt) und gescannte Wegekarten (wege*.txt) bleiben.
New-Item -ItemType Directory -Force (Join-Path $modDir 'Scripts'), (Join-Path $modDir 'bin') | Out-Null
Copy-Item (Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\Scripts\*') (Join-Path $modDir 'Scripts') -Force
Copy-Item (Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\bin\*') (Join-Path $modDir 'bin') -Force
Set-Content -Path (Join-Path $modDir 'enabled.txt') -Value '' -Encoding Ascii
Write-Step 'Mod FFRSAccess installiert.'
Write-Step 'Fertig. Beim nächsten Spielstart sagt die Mod: Final Fantasy Resonance Zugang geladen.'
