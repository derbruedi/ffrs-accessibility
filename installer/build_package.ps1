# Baut das Installationspaket dist\FFRSAccess und dist\FFRSAccess.zip.
# UE4SS kommt aus einem Spielordner, in dem es bereits laeuft; die Mod aus dem Projekt.
param(
    [string]$GameDir = "k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# Version wie 0.1.0b: Zahlen fuer die Exe-Version, voller Text fuer Update-Vergleich und Ansage.
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
$numericVersion = [regex]::Match($version, '^\d+(\.\d+)*').Value
if (-not $numericVersion) { throw "VERSION ungueltig: $version" }
$dist = Join-Path $root 'dist\FFRSAccess'
$zip = Join-Path $root 'dist\FFRSAccess.zip'
$sourceWin64 = Join-Path $GameDir 'FFRS\Binaries\Win64'
$sourceUe4ss = Join-Path $sourceWin64 'ue4ss'

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
$win64 = Join-Path $dist 'dateien\Win64'
$ue4ss = Join-Path $win64 'ue4ss'
$mod = Join-Path $ue4ss 'Mods\FFRSAccess'
New-Item -ItemType Directory -Force (Join-Path $mod 'Scripts'), (Join-Path $mod 'bin'), (Join-Path $dist 'Lizenzen') | Out-Null

# UE4SS ohne Entwickler-Mods (Konsole, Cheats) und ohne Dumps.
Copy-Item (Join-Path $sourceWin64 'dwmapi.dll') $win64
Copy-Item (Join-Path $sourceUe4ss 'UE4SS.dll'), (Join-Path $sourceUe4ss 'LICENSE') $ue4ss
foreach ($standardMod in 'shared', 'Keybinds', 'BPModLoaderMod', 'BPML_GenericFunctions') {
    Copy-Item (Join-Path $sourceUe4ss "Mods\$standardMod") (Join-Path $ue4ss 'Mods') -Recurse
}
Set-Content -Path (Join-Path $ue4ss 'Mods\mods.txt') -Encoding Ascii -Value @(
    'BPML_GenericFunctions : 1',
    'BPModLoaderMod : 1',
    '',
    '; Built-in keybinds, do not move up!',
    'Keybinds : 1'
)
# Neuladen per Taste ist nur zum Entwickeln gedacht und brachte am 05.11. einen Absturz.
$settings = Get-Content (Join-Path $sourceUe4ss 'UE4SS-settings.ini')
$settings = $settings -replace '^EnableHotReloadSystem\s*=.*$', 'EnableHotReloadSystem = 0'
Set-Content -Path (Join-Path $ue4ss 'UE4SS-settings.ini') -Value $settings -Encoding Ascii

# Mod: nur mitgelieferte Daten, keine beim Spielen gelernten oder gescannten Dateien.
$scripts = Join-Path $root 'mod\FFRSAccess\Scripts'
Copy-Item (Join-Path $scripts 'main.lua'), (Join-Path $scripts 'namen_spiel.txt') (Join-Path $mod 'Scripts')
Copy-Item (Join-Path $scripts 'karte_*.txt') (Join-Path $mod 'Scripts')
Copy-Item (Join-Path $root 'build\ffrs_speech.dll'), (Join-Path $root 'build\prism.dll') (Join-Path $mod 'bin')
Set-Content -Path (Join-Path $mod 'version.txt') -Value $version -Encoding Ascii

# Installer; PowerShell 5.1 liest Skripte ohne BOM als ANSI, die Umlaute brauchen UTF-8 mit BOM.
$utf8Bom = New-Object System.Text.UTF8Encoding $true
foreach ($name in 'install.ps1', 'Liesmich.txt') {
    $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $dist $name), $text, $utf8Bom)
}
Copy-Item (Join-Path $PSScriptRoot 'Installieren.bat'), (Join-Path $PSScriptRoot 'Deinstallieren.bat') $dist
Copy-Item (Join-Path $sourceUe4ss 'LICENSE') (Join-Path $dist 'Lizenzen\UE4SS.txt')
Copy-Item (Join-Path $root 'third_party\prism\LICENSES') (Join-Path $dist 'Lizenzen\prism') -Recurse

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $dist -DestinationPath $zip
Write-Output "Paket: $dist"
Write-Output "Zip: $zip"

# Setup-Exe: dieselben Dateien als eingebettete payload.zip (ohne die Skript-Installer).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$staging = Join-Path $root 'dist\payload'
$payloadZip = Join-Path $root 'dist\payload.zip'
foreach ($old in $staging, $payloadZip) { if (Test-Path $old) { Remove-Item $old -Recurse -Force } }
New-Item -ItemType Directory -Force $staging | Out-Null
Copy-Item (Join-Path $dist 'dateien'), (Join-Path $dist 'Lizenzen') $staging -Recurse
Copy-Item (Join-Path $dist 'Liesmich.txt') $staging
[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $payloadZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item $staging -Recurse -Force
$project = Join-Path $PSScriptRoot 'gui\FFRSSetup.csproj'
$out = Join-Path $root 'dist\setup-build'
& dotnet build $project -c Release -o $out "-p:PayloadZip=$payloadZip" "-p:Version=$numericVersion" "-p:InformationalVersion=$version" -nologo -v q
if ($LASTEXITCODE -ne 0) { throw "Setup-Exe: Build fehlgeschlagen" }
$setupExe = Join-Path $root 'dist\FFRSAccess-Setup.exe'
Copy-Item (Join-Path $out 'FFRSAccess-Setup.exe') $setupExe -Force
Remove-Item $out, $payloadZip -Recurse -Force
Write-Output "Setup: $setupExe (Version $version)"
