# Shared locale loader for the script installer. UTF-8 without BOM.
$script:LocaleDir = ''
$script:LanguageCode = 'de-DE'
$script:Locale = @{}
$script:FallbackLocale = @{}

function Read-Locale([string]$code) {
    $path = Join-Path $script:LocaleDir "$code.lang"
    if (-not (Test-Path $path)) { return @{} }
    $values = @{}
    $section = ''
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -match '^\[([^]]+)\]$') { $section = $Matches[1]; continue }
        if ($section -ne 'installer') { continue }
        $i = $text.IndexOf('=')
        if ($i -le 0) { continue }
        $key = $text.Substring(0, $i).Trim()
        $value = $text.Substring($i + 1).Trim()
        $value = $value.Replace('\n', [string][char]10).Replace('\r', [string][char]13).Replace('\t', [string][char]9).Replace('\\', '\')
        $values[$key] = $value
    }
    return $values
}

function Resolve-Language([string]$requested) {
    $requested = "$requested".Trim().Replace('_', '-')
    if (-not $requested -or $requested -ieq 'auto') {
        $requested = [Globalization.CultureInfo]::CurrentUICulture.Name
    }
    $files = @(Get-ChildItem $script:LocaleDir -Filter '*.lang' -File -ErrorAction SilentlyContinue)
    if (-not $files) { return 'de-DE' }
    foreach ($file in $files) {
        if ($file.BaseName -ieq $requested) { return $file.BaseName }
    }
    $lower = $requested.ToLowerInvariant()
    if ($lower.StartsWith('zh')) {
        $match = $files | Where-Object { $_.BaseName.StartsWith('zh-', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($match) { return $match.BaseName }
    }
    if ($lower.StartsWith('de')) {
        $match = $files | Where-Object { $_.BaseName.StartsWith('de-', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($match) { return $match.BaseName }
    }
    return 'de-DE'
}

function Use-Language([string]$dir, [string]$requested) {
    $script:LocaleDir = $dir
    $script:LanguageCode = Resolve-Language $requested
    $script:FallbackLocale = Read-Locale 'de-DE'
    $script:Locale = Read-Locale $script:LanguageCode
}

function T([string]$key, [hashtable]$vars = @{}) {
    $text = $script:Locale[$key]
    if ($null -eq $text) { $text = $script:FallbackLocale[$key] }
    if ($null -eq $text) { return $key }
    foreach ($name in $vars.Keys) { $text = $text.Replace('{' + $name + '}', [string]$vars[$name]) }
    return $text
}

function N([string]$key, [long]$count, [hashtable]$vars = @{}) {
    $copy = @{}
    foreach ($name in $vars.Keys) { $copy[$name] = $vars[$name] }
    $copy['count'] = $count
    $suffix = if ($count -eq 1) { '.one' } else { '.other' }
    return T ($key + $suffix) $copy
}
