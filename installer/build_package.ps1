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
& (Join-Path $root 'tools\check_locales.ps1')
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
Copy-Item (Join-Path $scripts 'main.lua'), (Join-Path $scripts 'i18n.lua'), (Join-Path $scripts 'narration.lua'), (Join-Path $scripts 'sounds.lua'),(Join-Path $scripts 'namen_spiel.txt'), (Join-Path $scripts 'namen_gelernt.txt') (Join-Path $mod 'Scripts')
Copy-Item (Join-Path $scripts 'locales') (Join-Path $mod 'Scripts') -Recurse
Copy-Item (Join-Path $scripts 'karte_*.txt') (Join-Path $mod 'Scripts')
Copy-Item (Join-Path $root 'build\ffrs_speech.dll'), (Join-Path $root 'build\prism.dll') (Join-Path $mod 'bin')
New-Item -ItemType Directory -Force (Join-Path $mod 'Sounds') | Out-Null
Copy-Item (Join-Path $root 'mod\FFRSAccess\Sounds\*.wav') (Join-Path $mod 'Sounds')
Set-Content -Path (Join-Path $mod 'version.txt') -Value $version -Encoding Ascii

# Installer; PowerShell 5.1 liest Skripte ohne BOM als ANSI, die Umlaute brauchen UTF-8 mit BOM.
$utf8Bom = New-Object System.Text.UTF8Encoding $true
foreach ($name in @('install.ps1', 'locale.ps1') + @(Get-ChildItem $PSScriptRoot -Filter 'Liesmich*.txt' -File | Select-Object -ExpandProperty Name)) {
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
Copy-Item (Get-ChildItem $dist -Filter 'Liesmich*.txt' -File).FullName $staging -Force
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

# Audiodeskription (etwa 400 MB) als eigene Datei: Das Setup laedt sie nur, wenn sie sich geaendert hat. Der Name
# traegt einen Pruefwert ueber Pfade und Inhalt aller Dateien, das Setup vergleicht ihn mit Descriptions\stand.txt.
Get-ChildItem (Join-Path $root 'dist') -Filter 'FFRSAccess-Audiodeskription-*.zip' | Remove-Item -Force
$descriptions = Join-Path $root 'mod\FFRSAccess\Descriptions'
if (-not (Test-Path (Join-Path $descriptions 'cues.tsv'))) {
    Write-Warning "Audiodeskription fehlt ($descriptions), Release bekommt keine."
    return
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$lines = Get-ChildItem $descriptions -Recurse -File | Where-Object { $_.Name -ne 'stand.txt' } |
    ForEach-Object {
        $relative = $_.FullName.Substring($descriptions.Length + 1).Replace('\', '/')
        "$relative $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object -CaseSensitive
$stamp = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($lines -join "`n")) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
$audioZip = Join-Path $root "dist\FFRSAccess-Audiodeskription-$stamp.zip"
$audioStaging = Join-Path $root 'dist\audio'
if (Test-Path $audioStaging) { Remove-Item $audioStaging -Recurse -Force }
New-Item -ItemType Directory -Force $audioStaging | Out-Null
Copy-Item $descriptions $audioStaging -Recurse
Remove-Item (Join-Path $audioStaging 'Descriptions\stand.txt') -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::CreateFromDirectory($audioStaging, $audioZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item $audioStaging -Recurse -Force
Write-Output "Audiodeskription: $audioZip"
