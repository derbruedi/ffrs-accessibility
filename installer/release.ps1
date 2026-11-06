# Veroeffentlicht die Version aus VERSION auf GitHub: Paket bauen, Tag v<Version> setzen und pushen,
# Release mit Setup und Zip anlegen. Versionen mit Buchstaben (0.1.0b) werden als Vorabversion markiert.
param(
    [string]$Notes = ""
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
$tag = "v$version"

# Beim Spielen gelernte Namen kommen mit ins Release.
& (Join-Path $PSScriptRoot 'collect_names.ps1')
$learned = 'mod/FFRSAccess/Scripts/namen_gelernt.txt'
if (git -C $root status --porcelain -- $learned) {
    git -C $root add -- $learned
    git -C $root commit -q -m "Gelernte Namen übernommen" -- $learned
}

if (git -C $root status --porcelain) { throw "Es gibt nicht eingecheckte Aenderungen. Erst committen." }
if (git -C $root tag --list $tag) { throw "Tag $tag gibt es schon. VERSION erhoehen." }

& (Join-Path $PSScriptRoot 'build_package.ps1')
if ($LASTEXITCODE) { throw "Paketbau fehlgeschlagen" }

git -C $root tag -a $tag -m "Version $version"
git -C $root push origin HEAD $tag

$assets = (Join-Path $root 'dist\FFRSAccess-Setup.exe'), (Join-Path $root 'dist\FFRSAccess.zip')
if (-not $Notes) { $Notes = "Version $version. Setup herunterladen, Spiel beenden, Setup starten." }
$flags = @()
if ($version -match '[A-Za-z]') { $flags += '--prerelease' }
# Notizen ueber eine Datei: PowerShell 5.1 zerlegt Argumente mit Anfuehrungszeichen falsch.
$notesFile = Join-Path $env:TEMP "ffrs_release_notes.txt"
[System.IO.File]::WriteAllText($notesFile, $Notes, (New-Object System.Text.UTF8Encoding $false))
gh release create $tag @assets --repo derbruedi/ffrs-accessibility --title "Version $version" --notes-file $notesFile @flags
$failed = $LASTEXITCODE
Remove-Item $notesFile
if ($failed) { throw "Release fehlgeschlagen" }
Write-Output "Veroeffentlicht: $tag"
