param(
    [switch]$AllowPartial
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$localeDir = Join-Path $root 'mod\FFRSAccess\Scripts\locales'
$errors = New-Object System.Collections.Generic.List[string]

function Read-Locale([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $errors.Add("${path}: UTF-8 mit BOM ist nicht erlaubt")
    }
    $sections = @{}
    $section = ''
    $lineNumber = 0
    $textFile = [Text.Encoding]::UTF8.GetString($bytes)
    $textFile = $textFile.Replace([string][char]13 + [string][char]10, [string][char]10).Replace([string][char]13, [string][char]10)
    foreach ($line in $textFile.Split([char]10)) {
        $lineNumber++
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -match '^\[([a-z0-9_.-]+)\]$') {
            $section = $Matches[1]
            if (-not $sections.ContainsKey($section)) { $sections[$section] = @{} }
            continue
        }
        if (-not $section) {
            $errors.Add("$path $lineNumber : Schluessel ausserhalb eines Abschnitts")
            continue
        }
        $i = $text.IndexOf('=')
        if ($i -le 0) {
            $errors.Add("$path $lineNumber : erwartet key = value")
            continue
        }
        $key = $text.Substring(0, $i).Trim()
        $value = $text.Substring($i + 1).Trim()
        if ($key -notmatch '^[a-z0-9_.-]+$') { $errors.Add("$path $lineNumber : ungueltiger Schluessel '$key'") }
        if ($sections[$section].ContainsKey($key)) { $errors.Add("$path $lineNumber : doppelter Schluessel $section.$key") }
        if (-not $value) { $errors.Add("$path $lineNumber : leerer Wert fuer $section.$key") }
        $sections[$section][$key] = $value
    }
    return $sections
}

function Placeholders([string]$value) {
    $names = @([regex]::Matches($value, '\{([a-z0-9_.-]+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    return ($names -join ',')
}

$files = @(Get-ChildItem $localeDir -Filter '*.lang' -File | Sort-Object Name)
if (-not $files) { throw "Keine Sprachdateien in $localeDir" }
$locales = @{}
foreach ($file in $files) {
    $code = $file.BaseName
    $sections = Read-Locale $file.FullName
    foreach ($required in 'meta', 'installer', 'mod') {
        if (-not $sections.ContainsKey($required)) { $errors.Add("$($file.Name): Abschnitt [$required] fehlt") }
    }
    if ($sections.ContainsKey('meta')) {
        $meta = $sections['meta']
        foreach ($required in 'code', 'native_name', 'fallback') {
            if (-not $meta.ContainsKey($required)) { $errors.Add("$($file.Name): [meta] $required fehlt") }
        }
        if ($meta['code'] -and $meta['code'] -ne $code) { $errors.Add("$($file.Name): code ist $($meta['code']), Dateiname ist $code") }
    }
    $locales[$code] = $sections
}

$reference = $locales['de-DE']
if (-not $reference) { throw 'de-DE.lang fehlt' }
foreach ($entry in $locales.GetEnumerator()) {
    if ($entry.Key -eq 'de-DE') { continue }
    foreach ($section in 'installer', 'mod') {
        if (-not $entry.Value.ContainsKey($section)) { continue }
        $expected = $reference[$section]
        $actual = $entry.Value[$section]
        foreach ($key in $expected.Keys) {
            if (-not $actual.ContainsKey($key)) {
                if (-not $AllowPartial) { $errors.Add("$($entry.Key): $section.$key fehlt") }
                continue
            }
            $left = Placeholders $expected[$key]
            $right = Placeholders $actual[$key]
            if ($left -ne $right) { $errors.Add("$($entry.Key): $section.$key Platzhalter '$right', erwartet '$left'") }
        }
        foreach ($key in $actual.Keys) {
            if (-not $expected.ContainsKey($key)) { $errors.Add("$($entry.Key): unbekannter Schluessel $section.$key") }
        }
    }
}

# Literal keys used by the Lua mod and the two installers must exist in de-DE.lang.
$used = New-Object System.Collections.Generic.HashSet[string]
$lua = Get-Content (Join-Path $root 'mod\FFRSAccess\Scripts\main.lua') -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($lua, '\bT\(\s*"([^"]+)"')) { [void]$used.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($lua, '\bT\.plural\(\s*"([^"]+)"')) { [void]$used.Add($m.Groups[1].Value + '.one'); [void]$used.Add($m.Groups[1].Value + '.other') }
$gui = Get-Content (Join-Path $root 'installer\gui\Program.cs') -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($gui, 'LocaleCatalog\.T\(\s*"([^"]+)"')) { [void]$used.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($gui, 'LocaleCatalog\.N\(\s*"([^"]+)"')) { [void]$used.Add($m.Groups[1].Value + '.one'); [void]$used.Add($m.Groups[1].Value + '.other') }
$scriptInstaller = Get-Content (Join-Path $root 'installer\install.ps1') -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($scriptInstaller, '\bT\s+''([^'']+)''')) { [void]$used.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($scriptInstaller, '\bN\s+''([^'']+)''')) { [void]$used.Add($m.Groups[1].Value + '.one'); [void]$used.Add($m.Groups[1].Value + '.other') }
foreach ($key in $used) {
    if ($key.EndsWith('.')) { continue }
    if (-not $reference['installer'].ContainsKey($key) -and -not $reference['mod'].ContainsKey($key)) {
        $errors.Add("Code verwendet fehlenden Schluessel: $key")
    }
}

if ($errors.Count -gt 0) {
    throw ("Sprachdateien ungueltig:" + [Environment]::NewLine + "- " + ($errors -join ([Environment]::NewLine + '- ')))
}
Write-Output "Sprachdateien OK: $($files.Count) Sprachen"
