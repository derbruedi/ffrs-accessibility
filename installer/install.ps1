# Installiert den FFRS-Zugang (UE4SS und die Mod FFRSAccess) in einen Spielordner von FINAL FANTASY RESONANCE.
# Aufruf ueber Installieren.bat; der Spielordner wird abgefragt oder mit -GameDir uebergeben.
param(
    [string]$GameDir,
    [switch]$Uninstall,
    [string]$Language = ''
)
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'dateien'
. (Join-Path $PSScriptRoot 'locale.ps1')
$exeRelative = 'FFRS\Binaries\Win64\FFRS-Win64-Shipping.exe'
$localesDir = Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\Scripts\locales'
Use-Language $localesDir $Language

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

$titleShown = $false
if (-not $GameDir) {
    $suggestions = @(Find-GameDirs)
    $suggestion = $suggestions | Select-Object -First 1
    if ($suggestion) {
        Write-Step (T 'installer.found' @{ path = $suggestion })
        if ($suggestions.Count -gt 1) {
            Write-Step (T 'installer.also_found' @{ path = (($suggestions | Select-Object -Skip 1) -join '; ') })
        }
        $answer = (Ask (T 'script.choose_found'))
        $GameDir = if ($answer) { $answer } else { $suggestion }
    } else {
        Write-Step (T 'script.title')
        $titleShown = $true
        $GameDir = (Ask (T 'script.enter_game'))
    }
}
$game = Resolve-GameDir $GameDir
if (-not $game) {
    Write-Step (T 'installer.game.invalid' @{ file = $exeRelative })
    Write-Step (T 'script.invalid_path' @{ path = $GameDir })
    exit 1
}
$win64 = Join-Path $game 'FFRS\Binaries\Win64'
$ue4ss = Join-Path $win64 'ue4ss'
$modDir = Join-Path $ue4ss 'Mods\FFRSAccess'
if (-not $Language -and (Test-Path (Join-Path $modDir 'language.txt'))) {
    Use-Language $localesDir ([IO.File]::ReadAllText((Join-Path $modDir 'language.txt'), [Text.Encoding]::UTF8).Trim())
}
if (-not $titleShown) { Write-Step (T 'script.title') }
Write-Step (T 'installer.game_path.status' @{ path = $game })

$running = Get-Process -Name 'FFRS-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($win64, [System.StringComparison]::OrdinalIgnoreCase)
}
if ($running) {
    Write-Step (T 'installer.game.running')
    exit 1
}

if ($Uninstall) {
    if (Test-Path $modDir) {
        Remove-Item $modDir -Recurse -Force
        Write-Step (T 'installer.mod_removed')
    } else {
        Write-Step (T 'installer.mod_not_installed')
    }
    $answer = (Ask (T 'script.remove_ue4ss_prompt'))
    if (@('j', 'y') -contains $answer.ToLower()) {
        if (Test-Path (Join-Path $ue4ss 'UE4SS.dll')) {
            Remove-Item (Join-Path $win64 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
            Remove-Item $ue4ss -Recurse -Force
            Write-Step (T 'installer.ue4ss_removed')
        }
    }
    Write-Step (T 'installer.uninstall.done')
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
Write-Step (T $(if ($hadUe4ss) { 'installer.ue4ss_updated' } else { 'installer.ue4ss_installed' }))

# Mod: Dateien ersetzen, gelernte Namen (npc_names.txt) und gescannte Wegekarten (wege*.txt) bleiben.
New-Item -ItemType Directory -Force (Join-Path $modDir 'Scripts'), (Join-Path $modDir 'bin') | Out-Null
Copy-Item (Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\Scripts\*') (Join-Path $modDir 'Scripts') -Recurse -Force
Copy-Item (Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\bin\*') (Join-Path $modDir 'bin') -Force
$sounds = Join-Path $payload 'Win64\ue4ss\Mods\FFRSAccess\Sounds'
if (Test-Path $sounds) {
    New-Item -ItemType Directory -Force (Join-Path $modDir 'Sounds') | Out-Null
    Copy-Item (Join-Path $sounds '*') (Join-Path $modDir 'Sounds') -Recurse -Force
}
Set-Content -Path (Join-Path $modDir 'enabled.txt') -Value '' -Encoding Ascii
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $modDir 'language.txt'), $script:LanguageCode + [Environment]::NewLine, $utf8NoBom)
Write-Step (T 'script.mod_installed')
Write-Step (T 'installer.install.done')
