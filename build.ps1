# build.ps1
# ------------------------------------------------------------------
# Assemble the deployable Rime config for the iOS "Hamster" input method.
#
# It stages the upstream rime-ice release, overlays our custom files,
# applies the requested dictionary tier, runs sanity checks, and packs a
# zip that can be imported directly into Hamster.
#
# NOTE: this file is deliberately pure ASCII. PowerShell 5.1 decodes a
# UTF-8 script WITHOUT a BOM using the system ANSI codepage, which turns
# non-ASCII characters into mojibake and can even break parsing. Chinese
# documentation therefore lives in the .md files, not in here.
#
# USAGE:
#   .\build.ps1                     # full tier (default)
#   .\build.ps1 -Tier standard      # drop the 41448 rare-char table
#   .\build.ps1 -Tier light         # drop 41448 + tencent + ext
#   .\build.ps1 -NoZip              # stage only, skip zip
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,

    # Tiers are defined from MEASURED compiled sizes, not from guesswork.
    # Measured with librime 1.17.0 (rime_deployer --build), full tier dict:
    #   full  (6 tables)             table.bin 58.23 MB   all .bin 72.82 MB
    #   lean  (- tencent)            table.bin 28.09 MB   all .bin 42.68 MB
    #   slim  (- tencent - ext)      table.bin 17.20 MB   all .bin 31.79 MB
    # NOTE: dropping only cn_dicts/41448 saves just 0.34 MB - it is a per
    # character table, so it is NOT a useful lever. tencent is the big one.
    [ValidateSet('full', 'lean', 'slim')]
    [string]$Tier = 'full',

    [switch]$NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseDir = Join-Path $Root 'upstream\extracted'
$srcDir = Join-Path $Root 'src'
$distRoot = Join-Path $Root 'dist'
$distDir = Join-Path $distRoot 'Rime'
$zipPath = Join-Path $distRoot ("rime-ios-mspy-{0}.zip" -f $Tier)

$script:ProblemCount = 0

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host ("== " + $Text) -ForegroundColor Cyan
}

function Write-Info([string]$Text) {
    Write-Host ("   " + $Text)
}

function Write-Ok([string]$Text) {
    Write-Host ("   [ok] " + $Text) -ForegroundColor Green
}

function Write-Bad([string]$Text) {
    Write-Host ("   [!!] " + $Text) -ForegroundColor Red
    $script:ProblemCount++
}

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    # Rime reads YAML as UTF-8. A BOM is usually tolerated but we avoid it
    # so the output is byte-identical in shape to upstream files.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

# ==================================================================
Write-Head ("BUILD  tier=" + $Tier + "  root=" + $Root)

if (-not (Test-Path -LiteralPath $baseDir)) {
    Write-Bad ("upstream not found: " + $baseDir)
    Write-Host '   Download rime-ice full.zip first, then extract it to upstream\extracted\ :'
    Write-Host '     https://mirror.nju.edu.cn/github-release/iDvel/rime-ice/LatestRelease/full.zip'
    Write-Host '   (see the "from source" section of README.md)'
    exit 1
}

# ------------------------------------------------------------------
Write-Head '1. stage upstream rime-ice'

# Only clear the staging dir and THIS tier's zip. Wiping all of dist would
# delete the other tiers' packages - and you WANT to keep them, because the
# natural workflow is "ship full, but keep lean ready in case the keyboard
# extension dies from memory pressure".
if (Test-Path -LiteralPath $distDir) {
    Remove-Item -LiteralPath $distDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Copy-Item -Path (Join-Path $baseDir '*') -Destination $distDir -Recurse -Force
$baseCount = (Get-ChildItem -LiteralPath $distDir -Recurse -File).Count
Write-Ok ("staged " + $baseCount + " upstream files")

# ------------------------------------------------------------------
Write-Head '2. overlay custom files'

$overlaid = @()
Get-ChildItem -LiteralPath $srcDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($srcDir.Length).TrimStart('\')
    $dst = Join-Path $distDir $rel
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    $overlaid += $rel
    Write-Info $rel
}
if ($overlaid.Count -eq 0) { Write-Bad 'nothing overlaid - src/ is empty' }

# ------------------------------------------------------------------
Write-Head ("3. apply dictionary tier: " + $Tier)

# Measured compiled sizes (librime 1.17.0, rime_deployer --build). Printed on
# every build so the tier trade-off is visible instead of guessed.
Write-Info 'measured compiled size (table.bin / all .bin):'
Write-Info '   full  = 58.23 MB / 72.82 MB   (all 6 tables)'
Write-Info '   lean  = 28.09 MB / 42.68 MB   (- cn_dicts/tencent)'
Write-Info '   slim  = 17.20 MB / 31.79 MB   (- cn_dicts/tencent - cn_dicts/ext)'
Write-Info 'note: dropping only cn_dicts/41448 saves ~0.34 MB - not a useful lever'

$dictFile = Join-Path $distDir 'rime_ice_full.dict.yaml'
if (-not (Test-Path -LiteralPath $dictFile)) {
    Write-Bad 'rime_ice_full.dict.yaml missing'
    exit 1
}

$dropTables = @()
switch ($Tier) {
    'full' { $dropTables = @() }
    'lean' { $dropTables = @('cn_dicts/tencent') }
    'slim' { $dropTables = @('cn_dicts/tencent', 'cn_dicts/ext') }
}

if ($dropTables.Count -gt 0) {
    $srcLines = Get-Content -LiteralPath $dictFile -Encoding UTF8
    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $srcLines) {
        $disabled = $false
        foreach ($t in $dropTables) {
            if ($line -match ('^\s*-\s+' + [regex]::Escape($t) + '\s*$|^\s*-\s+' + [regex]::Escape($t) + '\s+#')) {
                $disabled = $true
            }
        }
        if ($disabled) {
            $newLines.Add(('  # [tier ' + $Tier + '] disabled: ' + $line.Trim()))
            Write-Info ('disabled ' + $line.Trim())
        }
        else {
            $newLines.Add($line)
        }
    }
    Write-Utf8NoBom -Path $dictFile -Lines $newLines.ToArray()
    Write-Ok ('tier applied, dropped: ' + ($dropTables -join ', '))
}
else {
    Write-Ok 'full tier - no table dropped'
}

# ------------------------------------------------------------------
Write-Head '4. sanity checks'

# 4.1 required files
$required = @(
    'default.yaml',
    'double_pinyin_mspy.schema.yaml',
    'double_pinyin_mspy.custom.yaml',
    'default.custom.yaml',
    'rime_ice_full.dict.yaml',
    'custom_phrase_double.txt',
    'melt_eng.schema.yaml',
    'melt_eng.dict.yaml',
    'radical_pinyin.schema.yaml',
    'radical_pinyin.dict.yaml',
    'lua\corrector.lua',
    'lua\pin_cand_filter.lua',
    'opencc\emoji.json'
)
foreach ($f in $required) {
    if (Test-Path -LiteralPath (Join-Path $distDir $f)) { Write-Ok ('present: ' + $f) }
    else { Write-Bad ('MISSING: ' + $f) }
}

# 4.2 dictionary imports must resolve on disk
$importNames = @()
foreach ($line in (Get-Content -LiteralPath $dictFile -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    $m = [regex]::Match($line, '^\s*-\s+([A-Za-z0-9_/]+)\s*(#.*)?$')
    if ($m.Success) { $importNames += $m.Groups[1].Value }
}
if ($importNames.Count -eq 0) { Write-Bad 'no import_tables parsed from rime_ice_full.dict.yaml' }
foreach ($n in $importNames) {
    $p = Join-Path $distDir ($n + '.dict.yaml')
    if (Test-Path -LiteralPath $p) { Write-Ok ('dict table: ' + $n) }
    else { Write-Bad ('dict table NOT FOUND: ' + $n) }
}

# 4.3 the dict file's declared name must match what the schema patch mounts
$dictName = ''
foreach ($line in (Get-Content -LiteralPath $dictFile -Encoding UTF8)) {
    $m = [regex]::Match($line, '^name:\s*(\S+)\s*$')
    if ($m.Success) { $dictName = $m.Groups[1].Value; break }
}
$patchText = Get-Content -LiteralPath (Join-Path $distDir 'double_pinyin_mspy.custom.yaml') -Raw -Encoding UTF8
if ($patchText -match ('translator/dictionary:\s*' + [regex]::Escape($dictName))) {
    Write-Ok ('schema mounts dict name: ' + $dictName)
}
else {
    Write-Bad ("schema does not mount '" + $dictName + "' - mismatch between dict name and patch")
}

# 4.4 both dictionary references must be retargeted, otherwise librime
#     compiles BOTH rime_ice and rime_ice_full (double memory)
if ($patchText -match 'radical_reverse_lookup/dictionary:') {
    Write-Ok 'radical_reverse_lookup dictionary also retargeted (avoids double compile)'
}
else {
    Write-Bad 'radical_reverse_lookup/dictionary NOT retargeted - rime_ice would still be compiled'
}

# 4.5 patch top-level keys must exist in the upstream schema, so upstream
#     drift is caught at build time instead of silently doing nothing
$schemaText = Get-Content -LiteralPath (Join-Path $distDir 'double_pinyin_mspy.schema.yaml') -Raw -Encoding UTF8
$patchKeys = @()
foreach ($line in (Get-Content -LiteralPath (Join-Path $distDir 'double_pinyin_mspy.custom.yaml') -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    $m = [regex]::Match($line, '^\s{2}([A-Za-z_][A-Za-z0-9_]*)/')
    if ($m.Success) { $patchKeys += $m.Groups[1].Value }
}
$patchKeys = $patchKeys | Select-Object -Unique
foreach ($k in $patchKeys) {
    if ($schemaText -match ('(?m)^' + [regex]::Escape($k) + ':')) {
        Write-Ok ('patch key resolves in upstream schema: ' + $k)
    }
    else {
        Write-Bad ('patch key NOT found in upstream schema: ' + $k + ' (upstream may have renamed it)')
    }
}

# 4.6 schema_list must contain exactly our one schema
# NOTE: must skip comment lines. An earlier version scanned the raw text and
# happily matched the '`- schema: rime_ice`' example inside a comment.
$schemaRefs = @()
foreach ($line in (Get-Content -LiteralPath (Join-Path $distDir 'default.custom.yaml') -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    $m = [regex]::Match($line, '-\s*schema:\s*([A-Za-z0-9_]+)')
    if ($m.Success) { $schemaRefs += $m.Groups[1].Value }
}
if ($schemaRefs.Count -eq 1 -and $schemaRefs[0] -eq 'double_pinyin_mspy') {
    Write-Ok 'schema_list pruned to exactly: double_pinyin_mspy (biggest memory lever)'
}
else {
    Write-Bad ('schema_list unexpected: ' + ($schemaRefs -join ', '))
}

# 4.7 our own YAML must not contain TABs (YAML forbids tabs for indentation)
# NOTE: only *config* YAML is checked here. .dict.yaml files legitimately use
# TAB as the word/code separator, so they must be excluded. (An earlier
# version used -Include with -LiteralPath, which is silently ignored and made
# every file look like a YAML config.)
Get-ChildItem -LiteralPath $srcDir -Recurse -File |
    Where-Object { $_.Name -like '*.yaml' -and $_.Name -notlike '*.dict.yaml' } |
    ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        if ($raw -match "`t") { Write-Bad ('TAB found in config YAML (illegal for indentation): ' + $_.Name) }
        else { Write-Ok ('no tabs: ' + $_.Name) }
    }

# 4.8 the custom phrase file must have no comment lines after the header,
#     otherwise the table parser treats them as entries
$cpPath = Join-Path $distDir 'custom_phrase_double.txt'
if (Test-Path -LiteralPath $cpPath) {
    # The table parser treats every line after the header as an entry, so all
    # comments must sit ABOVE the first data line. An earlier version keyed off
    # the 'db_type' marker, which wrongly flagged the whole documented header.
    $cpLines = Get-Content -LiteralPath $cpPath -Encoding UTF8
    $firstData = -1
    for ($i = 0; $i -lt $cpLines.Count; $i++) {
        $l = $cpLines[$i]
        if ($l -match '^\s*$') { continue }
        if ($l -match '^\s*#') { continue }
        $firstData = $i
        break
    }
    if ($firstData -lt 0) {
        Write-Bad 'custom_phrase_double.txt has no data lines'
    }
    else {
        $badComments = 0
        for ($i = $firstData; $i -lt $cpLines.Count; $i++) {
            if ($cpLines[$i] -match '^\s*#') { $badComments++ }
        }
        if ($badComments -gt 0) { Write-Bad ($badComments.ToString() + ' comment line(s) appear AFTER the first data line') }
        else { Write-Ok 'custom_phrase_double.txt: all comments are above the first data line' }
    }
}

# 4.9 hamster.custom.yaml patch keys must exist in the reference template.
#     Hamster silently ignores unknown keys, so a typo would quietly do
#     nothing - which is exactly the failure mode worth automating away.
$hamPath = Join-Path $distDir 'hamster.custom.yaml'
$refPath = Join-Path $Root 'reference\hamster.default.yaml'
if ((Test-Path -LiteralPath $hamPath) -and (Test-Path -LiteralPath $refPath)) {

    # index the reference template as section -> set of second-level keys
    $refSections = @{}
    $curRef = ''
    foreach ($line in (Get-Content -LiteralPath $refPath -Encoding UTF8)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):') {
            $curRef = $Matches[1]
            if (-not $refSections.ContainsKey($curRef)) {
                $refSections[$curRef] = New-Object System.Collections.Generic.HashSet[string]
            }
            continue
        }
        if ($curRef -ne '' -and $line -match '^\s{2}([A-Za-z_][A-Za-z0-9_]*):') {
            [void]$refSections[$curRef].Add($Matches[1])
        }
    }

    # Collect section/key pairs. Two patch syntaxes exist in the wild and
    # both are accepted here:
    #   slash :   keyboard/enableX: true        (and keyboard/listKey/+:)
    #   nested:   keyboard:\n    enableX: true
    $paths = New-Object System.Collections.Generic.List[string]
    $curSection = ''
    foreach ($line in (Get-Content -LiteralPath $hamPath -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }

        # slash-path form
        if ($line -match '^  ([A-Za-z_][A-Za-z0-9_]*)/([A-Za-z_][A-Za-z0-9_]*)(/+)?\s*:') {
            $paths.Add($Matches[1] + '/' + $Matches[2])
            continue
        }
        # nested form: section header
        if ($line -match '^  ([A-Za-z_][A-Za-z0-9_]*):\s*$') {
            $curSection = $Matches[1]
            continue
        }
        # nested form: key inside the current section
        if ($line -match '^    ([A-Za-z_][A-Za-z0-9_]*):') {
            $paths.Add($curSection + '/' + $Matches[1])
            continue
        }
    }

    $checked = 0
    foreach ($p in $paths) {
        $checked++
        $parts = $p -split '/'
        $sec = $parts[0]
        $key = $parts[1]
        $found = $false
        if ($refSections.ContainsKey($sec)) { $found = $refSections[$sec].Contains($key) }
        if ($found) { Write-Ok ('hamster key resolves: ' + $p) }
        else { Write-Bad ('hamster key NOT in template: ' + $p) }
    }
    Write-Info ('checked ' + $checked + ' hamster config keys against the reference template')

    # ---- colour-schema inner keys ----
    # These are NOT hamster.yaml keys, so the loop above never sees them.
    # They still deserve a check: the template we have (2.1.0) and the current
    # docs (2.19.x) DISAGREE on the key-text colour names
    # (button_front_color vs button_foreground_color), so a wrong name here
    # would silently produce the wrong colours. The allowlist is the union of
    # both sources.
    $colourKeys = @(
        'schemaName', 'name', 'author',
        # keyboard backgrounds / key faces - keyboard_color.mdx (current docs)
        'back_color', 'button_back_color', 'button_pressed_back_color',
        'button_foreground_color', 'button_pressed_foreground_color',
        'button_swipe_foreground_color', 'corner_radius', 'border_color',
        'shadow_color', 'shadow_size',
        # the 2.1.0 template spelling of the same three
        'button_front_color', 'button_pressed_front_color', 'button_swipe_front_color',
        # candidate bar
        'text_color', 'hilited_candidate_text_color', 'hilited_comment_text_color',
        'hilited_candidate_back_color', 'hilited_candidate_label_color',
        'candidate_text_color', 'comment_text_color', 'label_color',
        # long-press callout + key bubble
        'hilited_callout_back_color', 'hilited_callout_foreground_color',
        'button_bubble_back_color'
    )
    $unknownColour = @()
    foreach ($line in (Get-Content -LiteralPath $hamPath -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        $k = ''
        if ($line -match '^\s*- ([A-Za-z_][A-Za-z0-9_]*):') { $k = $Matches[1] }
        elseif ($line -match '^      ([a-z_][a-z0-9_]*):') { $k = $Matches[1] }
        if ($k -ne '' -and $colourKeys -notcontains $k) { $unknownColour += $k }
    }
    if ($unknownColour.Count -gt 0) {
        Write-Bad ('colour-schema key(s) not in the documented set: ' + (($unknownColour | Select-Object -Unique) -join ', '))
    }
    else {
        Write-Ok 'all colour-schema keys are in the documented set'
    }
}
else {
    Write-Bad 'hamster.custom.yaml or reference/hamster.default.yaml missing - hamster keys unchecked'
}

# 4.10 the self-built override dictionary. Entries must be well formed AND
#      their pinyin must be typeable with MSPY - a typo in the pinyin would
#      silently add a word nobody can reach.
$ovPath = Join-Path $distDir 'mspy_overrides.dict.yaml'
if (Test-Path -LiteralPath $ovPath) {
    . (Join-Path $PSScriptRoot 'tools\ConvertTo-Mspy.ps1')

    $mspyAlphabet = 'zyxwvutsrqponmlkjihgfedcba;'
    $ovCount = 0
    $ovBad = 0
    $ovSeen = $false

    foreach ($line in (Get-Content -LiteralPath $ovPath -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\.\.\.\s*$') { $ovSeen = $true; continue }
        if ($line -match '^---\s*$') { continue }
        if (-not $ovSeen) { continue }              # still in the YAML front matter
        if ($line.IndexOf("`t") -lt 0) { continue }  # section prose, not an entry

        $c = $line -split "`t"
        if ($c.Count -lt 3) {
            Write-Bad ('override entry needs 3 tab-separated columns: ' + $line.Trim())
            $ovBad++
            continue
        }
        $word = $c[0].Trim()
        $py = $c[1].Trim()
        $weight = $c[2].Trim()

        if ($weight -notmatch '^\d+$') {
            Write-Bad ('override weight is not an integer: ' + $line.Trim())
            $ovBad++
            continue
        }

        $code = Convert-MspyPinyin -PinyinText $py
        $typeable = $true
        $syllables = @($py -split '\s+' | Where-Object { $_ -ne '' })
        if ($code.Length -lt 1 -or $code.Length -gt (2 * $syllables.Count)) { $typeable = $false }
        foreach ($ch in $code.ToCharArray()) {
            if ($mspyAlphabet.IndexOf($ch) -lt 0) { $typeable = $false }
        }
        if (-not $typeable) {
            Write-Bad ('override pinyin not typeable: ' + $word + ' / ' + $py + ' -> [' + $code + ']')
            $ovBad++
            continue
        }

        $ovCount++
        Write-Ok ('override: ' + $word + '  ' + $py + '  w=' + $weight + '  -> ' + $code)
    }

    if ($ovCount -eq 0) { Write-Bad 'override dictionary has no entries' }
    if ($ovBad -gt 0) { Write-Bad ($ovBad.ToString() + ' malformed override entry(ies)') }
    else { Write-Ok ('override dictionary OK (' + $ovCount + ' entries)') }
}
else {
    Write-Bad 'mspy_overrides.dict.yaml missing'
}

# ------------------------------------------------------------------
Write-Head '5. inventory'

# entry counts, so the coverage claim is backed by numbers
$tables = @{}
foreach ($n in $importNames) {
    $p = Join-Path $distDir ($n + '.dict.yaml')
    if (Test-Path -LiteralPath $p) {
        $cnt = 0
        foreach ($l in (Get-Content -LiteralPath $p -Encoding UTF8)) {
            if ($l -match "`t" -and $l -notmatch '^\s*#') { $cnt++ }
        }
        $tables[$n] = $cnt
    }
}
$cnTotal = 0
foreach ($k in ($tables.Keys | Sort-Object)) {
    Write-Info ("{0,-22} {1,10:N0}" -f $k, $tables[$k])
    $cnTotal += $tables[$k]
}
Write-Info ("{0,-22} {1,10:N0}" -f 'TOTAL (mounted tables)', $cnTotal)

# english tables are mounted separately via melt_eng.dict.yaml
$enTotal = 0
foreach ($n in @('en_dicts/en', 'en_dicts/en_ext')) {
    $p = Join-Path $distDir ($n + '.dict.yaml')
    if (Test-Path -LiteralPath $p) {
        $cnt = 0
        foreach ($l in (Get-Content -LiteralPath $p -Encoding UTF8)) {
            if ($l -match "`t" -and $l -notmatch '^\s*#') { $cnt++ }
        }
        $enTotal += $cnt
        Write-Info ("{0,-22} {1,10:N0}" -f $n, $cnt)
    }
}
Write-Info ("{0,-22} {1,10:N0}" -f 'TOTAL english', $enTotal)

$allFiles = Get-ChildItem -LiteralPath $distDir -Recurse -File
$totalMb = [math]::Round((($allFiles | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
Write-Info ''
Write-Info ("output files : " + $allFiles.Count)
Write-Info ("output size  : " + $totalMb + " MB")

# ------------------------------------------------------------------
if (-not $NoZip) {
    Write-Head '6. pack zip for Hamster import'

    # Hamster requires the zip to have NO root folder: files at archive root.
    #
    # NOTE: we deliberately do NOT use Compress-Archive. On PowerShell 5.1
    # (Windows PowerShell) it writes entry names with BACKSLASH separators,
    # which violates the ZIP spec. iOS's unzip then treats a name like
    # "cn_dicts\41448.dict.yaml" as ONE flat filename containing a backslash
    # rather than a directory path - so cn_dicts/, lua/, opencc/ would all
    # collapse and the deployment would fail. Building the archive by hand
    # lets us force forward slashes.
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    # Two assemblies are needed: ZipFile lives in ...FileSystem, while
    # ZipArchiveMode lives in the base System.IO.Compression assembly.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipRoot = $distDir.TrimEnd('\')

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $added = 0
        Get-ChildItem -LiteralPath $distDir -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($zipRoot.Length).TrimStart('\')
            $entryName = $rel.Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
            $added++
        }
        Write-Ok ('added ' + $added + ' entries')
    }
    finally {
        $zip.Dispose()
    }

    $zipMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
    Write-Ok ($zipPath + '  (' + $zipMb + ' MB)')

    # ---- verify the archive is actually iOS-safe ----
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $backslash = 0
        $wrapper = 0
        $dirs = @{}
        foreach ($e in $zip.Entries) {
            if ($e.FullName -like '*\*') { $backslash++ }
            if ($e.FullName -match '^(Rime|rime-ios-mspy)/') { $wrapper++ }
            $top = ($e.FullName -split '/')[0]
            if ($top -notmatch '\.') { $dirs[$top] = $true }
        }

        if ($backslash -gt 0) {
            Write-Bad ($backslash.ToString() + ' zip entry name(s) contain a BACKSLASH - iOS would not create the directories')
        }
        else {
            Write-Ok 'all zip entry names use forward slashes (iOS-safe)'
        }

        if ($wrapper -gt 0) {
            Write-Bad 'zip contains a wrapper folder; Hamster requires no root folder'
        }
        else {
            Write-Ok 'no wrapper folder in zip'
        }

        if ($dirs.Keys.Count -gt 0) {
            Write-Ok ('top-level content dirs: ' + (($dirs.Keys | Sort-Object) -join ', '))
        }
    }
    finally {
        $zip.Dispose()
    }
}

# ------------------------------------------------------------------
Write-Head 'RESULT'
if ($script:ProblemCount -eq 0) {
    Write-Host '   BUILD OK - no problems found.' -ForegroundColor Green
    Write-Host ''
    Write-Host '   next: import the zip into Hamster, then run RIME -> redeploy.'
    exit 0
}
else {
    Write-Host ("   BUILD FINISHED WITH " + $script:ProblemCount + " PROBLEM(S).") -ForegroundColor Red
    exit 1
}
