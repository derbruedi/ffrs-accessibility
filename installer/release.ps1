# Veroeffentlicht die Version aus VERSION auf GitHub: Paket bauen, Tag v<Version> setzen und pushen,
# Release mit Setup und Zip anlegen. Versionen mit Buchstaben (0.1.0b) werden als Vorabversion markiert.
param(
    [string]$Notes = ""
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
$tag = "v$version"

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
gh release create $tag @assets --repo derbruedi/ffrs-accessibility --title "Version $version" --notes $Notes @flags
if ($LASTEXITCODE) { throw "Release fehlgeschlagen" }
Write-Output "Veroeffentlicht: $tag"
