# Verify-SyllableCoverage.ps1
# ------------------------------------------------------------------
# Check that EVERY syllable appearing in the mounted dictionaries can
# actually be typed with Microsoft Shuangpin (MSPY).
#
# Why this matters for the "no missing words" requirement:
#   A dictionary entry is only reachable if its pinyin can be expressed as
#   a MSPY code. Rime derives the syllabary from the dictionary plus the
#   schema's speller/algebra. If a syllable has no valid MSPY spelling,
#   every word using it becomes untypeable - a silent coverage hole that
#   no amount of dictionary size can fix.
#
# It also detects COLLISIONS: two different syllables mapping to the same
# code would make the scheme ambiguous.
#
# Pure ASCII on purpose (PowerShell 5.1 decodes a BOM-less UTF-8 script
# using the ANSI codepage).
#
# USAGE:
#   .\Verify-SyllableCoverage.ps1
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$DictRoot,
    [string[]]$Tables = @('8105', '41448', 'base', 'ext', 'others')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# reuse the verified converter
. (Join-Path $PSScriptRoot 'ConvertTo-Mspy.ps1')

if (-not $DictRoot) {
    $DictRoot = Join-Path $Root 'dist\Rime\cn_dicts'
}

# the keys a MSPY code may consist of, per the schema's speller/alphabet
$alphabet = 'zyxwvutsrqponmlkjihgfedcba;'

Write-Host ''
Write-Host 'Syllable coverage check (dictionary pinyin -> MSPY code)'
Write-Host '======================================================='
Write-Host ("dictionaries: " + $DictRoot)

if (-not (Test-Path -LiteralPath $DictRoot)) {
    Write-Host ("  [!!] dictionary directory not found: " + $DictRoot)
    exit 1
}

# ------------------------------------------------------------------
# 1. collect every distinct syllable
# ------------------------------------------------------------------
$syllables = New-Object System.Collections.Generic.HashSet[string]
$nonAlpha = New-Object System.Collections.Generic.HashSet[string]
$tableCount = @{}

foreach ($t in $Tables) {
    $p = Join-Path $DictRoot ($t + '.dict.yaml')
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("  [!!] table missing: " + $t)
        continue
    }
    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($p, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }
        foreach ($piece in ($cols[1].Trim() -split '[, ]+')) {
            if ($piece -eq '') { continue }
            if ($piece -match '^[A-Za-z]+$') {
                [void]$syllables.Add($piece.ToLowerInvariant())
                $n++
            }
            else {
                [void]$nonAlpha.Add($piece)
            }
        }
    }
    $tableCount[$t] = $n
}

foreach ($t in ($tableCount.Keys | Sort-Object)) {
    Write-Host ("  {0,-10} {1,10:N0} syllable occurrences" -f $t, $tableCount[$t])
}
Write-Host ("  distinct syllables : " + $syllables.Count)
if ($nonAlpha.Count -gt 0) {
    Write-Host ("  non-alphabetic pinyin fragments: " + $nonAlpha.Count + " (expected 0)")
}

# ------------------------------------------------------------------
# 2. convert each and classify
# ------------------------------------------------------------------
$ok = 0
$tooLong = @()
$badChar = @()
$empty = @()
$byCode = @{}

foreach ($s in ($syllables | Sort-Object)) {
    $code = Convert-MspyPinyin -PinyinText $s
    if ([string]::IsNullOrEmpty($code)) {
        $empty += $s
        continue
    }
    $illegal = @()
    foreach ($ch in $code.ToCharArray()) {
        if ($alphabet.IndexOf($ch) -lt 0) { $illegal += $ch }
    }
    if ($illegal.Count -gt 0) {
        $badChar += ("{0} -> {1}" -f $s, $code)
        continue
    }
    # a MSPY syllable is 1..2 keys ('o' alone; 'aa'; or initial+final)
    if ($code.Length -gt 2) {
        $tooLong += ("{0} -> {1}" -f $s, $code)
        continue
    }
    $ok++
    if (-not $byCode.ContainsKey($code)) { $byCode[$code] = @() }
    $byCode[$code] += $s
}

Write-Host ''
Write-Host ("  typeable syllables : " + $ok + " / " + $syllables.Count)

$problem = 0
if ($empty.Count -gt 0) {
    Write-Host ("  [!!] empty code      : " + ($empty -join ', '))
    $problem += $empty.Count
}
if ($badChar.Count -gt 0) {
    Write-Host ("  [!!] illegal char    : " + ($badChar -join '; '))
    $problem += $badChar.Count
}
if ($tooLong.Count -gt 0) {
    Write-Host ("  [!!] code longer than 2 keys: " + ($tooLong -join '; '))
    $problem += $tooLong.Count
}

# ------------------------------------------------------------------
# 3. collisions: two syllables sharing one code
#
#    NOTE: a collision is benign here. It means one code reaches two
#    readings, and BOTH stay selectable as candidates - the scheme loses
#    no coverage. This is inherent to MSPY's final mapping, not a defect
#    in our config: "uo" folds onto the same key as a bare "o", so the
#    syllable "luo" (罗) and the syllable "lo" (咯) both spell "lo".
#    The official schema has exactly the same behaviour.
#
#    What WOULD be a real defect is a syllable with no valid code at all,
#    which the check above proves does not happen.
# ------------------------------------------------------------------
$collisions = @()
foreach ($k in $byCode.Keys) {
    if ($byCode[$k].Count -gt 1) {
        $collisions += ("{0} <- {1}" -f $k, ($byCode[$k] -join ', '))
    }
}
if ($collisions.Count -gt 0) {
    Write-Host ''
    Write-Host ("  note: " + $collisions.Count + " code collision(s) - benign, both readings remain reachable:")
    foreach ($c in ($collisions | Sort-Object)) { Write-Host ("       " + $c) }
}
else {
    Write-Host '  no code collisions (one code = one syllable)'
}

# ------------------------------------------------------------------
Write-Host ''
if ($problem -eq 0 -and $nonAlpha.Count -eq 0) {
    if ($collisions.Count -gt 0) {
        Write-Host ("NOTE: " + $collisions.Count + " benign collision(s) reported above.") -ForegroundColor Yellow
    }
    Write-Host 'RESULT: OK - every dictionary syllable is typeable.' -ForegroundColor Green
    exit 0
}
Write-Host ("RESULT: " + ($problem + $nonAlpha.Count) + " problem(s) found.") -ForegroundColor Red
exit 1
