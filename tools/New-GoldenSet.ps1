# New-GoldenSet.ps1
# ------------------------------------------------------------------
# Build the golden-set worksheet for candidate-ordering evaluation.
#
# Resolution order for each curated word (first hit wins):
#   1. Chinese dictionary WITH pinyin (base / 8105 / 41448 / ext / others)
#      -> convert that pinyin with the verified converter
#   2. mixed CN/EN table (en_dicts\cn_en_mspy.txt)
#      -> its 2nd column is ALREADY a Shuangpin code, use as-is
#   3. English tables (en_dicts\en, en_ext)
#      -> 2nd column is the code too
#   4. normalised retry (punctuation/case-insensitive) over 1-3, so that
#      "WiFi密码" still matches the table's "Wi-Fi密码"
#   5. per-character pinyin composition (8105 + 41448 single-char readings)
#      -> needed for words that only exist in cn_dicts\tencent, which is
#         deliberately NOT pinyin-annotated in the table (Rime annotates it
#         at deploy time). 多音字 may be wrong here - those rows are marked
#         "composed" so they can be spot-checked.
# Anything still unresolved is a real dictionary gap and is reported as such.
#
# Pure ASCII on purpose (PowerShell 5.1 decodes a BOM-less UTF-8 script
# using the ANSI codepage).
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$WordsPath,
    [string]$OutPath,
    [string]$DictRoot,
    [string]$EnDictRoot,
    [string]$CnEnPath,
    [string]$OverridePath,
    [string[]]$Tables = @('base', '8105', '41448', 'ext', 'others', 'tencent'),
    [string[]]$EnglishTables = @('en', 'en_ext')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ConvertTo-Mspy.ps1')

if (-not $WordsPath) { $WordsPath = Join-Path $Root 'eval\words.tsv' }
if (-not $OutPath) { $OutPath = Join-Path $Root 'eval\golden_set.tsv' }
if (-not $DictRoot) { $DictRoot = Join-Path $Root 'dist\Rime\cn_dicts' }
if (-not $EnDictRoot) { $EnDictRoot = Join-Path $Root 'dist\Rime\en_dicts' }
if (-not $CnEnPath) { $CnEnPath = Join-Path $EnDictRoot 'cn_en_mspy.txt' }
if (-not $OverridePath) { $OverridePath = Join-Path $Root 'dist\Rime\mspy_overrides.dict.yaml' }

function Get-NormKey([string]$Text) {
    $k = $Text.ToLowerInvariant()
    $k = $k -replace '[^0-9a-z\u4e00-\u9fff]', ''
    return $k
}

function Test-IsSingleChar([string]$Text) {
    return ($Text.Length -eq 1 -and $Text -match '^[\u4e00-\u9fff]$')
}

Write-Host ''
Write-Host 'Building golden set'
Write-Host '==================='

if (-not (Test-Path -LiteralPath $WordsPath)) { throw "word list not found: $WordsPath" }
if (-not (Test-Path -LiteralPath $DictRoot)) { throw "dictionary dir not found: $DictRoot" }

# ------------------------------------------------------------------
# 1. curated word list
# ------------------------------------------------------------------
$wanted = New-Object System.Collections.Generic.List[object]
$wantSet = New-Object System.Collections.Generic.HashSet[string]

foreach ($line in (Get-Content -LiteralPath $WordsPath -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*$') { continue }
    $cols = $line -split "`t"
    if ($cols.Count -lt 2) { continue }
    $cat = $cols[0].Trim()
    $word = $cols[1].Trim()
    if ($word -eq '') { continue }
    $wanted.Add([pscustomobject]@{ Category = $cat; Word = $word })
    [void]$wantSet.Add($word)
}
Write-Host ("  words to resolve: " + $wanted.Count)

# ------------------------------------------------------------------
# 2. Chinese dictionaries: word -> pinyin, plus single-char readings
# ------------------------------------------------------------------
$pinyinOf = @{}
$pySourceOf = @{}
$charPinyin = @{}
$tencentWords = New-Object System.Collections.Generic.HashSet[string]

foreach ($t in $Tables) {
    $p = Join-Path $DictRoot ($t + '.dict.yaml')
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("  [!!] table missing: " + $t)
        continue
    }
    $hits = 0
    $chars = 0
    foreach ($line in [System.IO.File]::ReadLines($p, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.IndexOf("`t") -lt 0) { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }
        $w = $cols[0].Trim()
        $second = $cols[1].Trim()

        if ($t -eq 'tencent') { [void]$tencentWords.Add($w); continue }

        # single-character readings feed the composition fallback
        if (Test-IsSingleChar $w) {
            if (-not $charPinyin.PSBase.ContainsKey($w)) { $charPinyin[$w] = $second }
            $chars++
        }

        if (-not $wantSet.Contains($w)) { continue }
        if ($pinyinOf.PSBase.ContainsKey($w)) { continue }
        $pinyinOf[$w] = $second
        $pySourceOf[$w] = $t
        $hits++
    }
    Write-Host ("  {0,-10} pinyin matched {1,-4} (single-char readings indexed: {2})" -f $t, $hits, $chars)
}
# Also index the self-built override layer. It lives at the Rime ROOT rather
# than under cn_dicts, so the loop above never sees it - without this, every
# word you add to the override layer would keep being reported as "no entry".
if (Test-Path -LiteralPath $OverridePath) {
    $ovHits = 0
    foreach ($line in [System.IO.File]::ReadLines($OverridePath, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.IndexOf("`t") -lt 0) { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }
        $w = $cols[0].Trim()
        if (-not $wantSet.Contains($w)) { continue }
        if ($pinyinOf.PSBase.ContainsKey($w)) { continue }
        $pinyinOf[$w] = $cols[1].Trim()
        $pySourceOf[$w] = 'mspy_overrides'
        $ovHits++
    }
    Write-Host ("  {0,-10} pinyin matched {1}" -f 'overrides', $ovHits)
}
else {
    Write-Host '  [!!] mspy_overrides.dict.yaml not found'
}

Write-Host ("  tencent words indexed (no pinyin in table): " + $tencentWords.Count)

# ------------------------------------------------------------------
# 3. tables whose 2nd column is already a Shuangpin code
# ------------------------------------------------------------------
$codeOf = @{}
$codeSourceOf = @{}

# NOTE: this used to live in a helper function that wrote via $script:codeOf.
# That silently populated a different variable from the one the resolution
# loop read, so the normalised alias index came out with a single key.
# Keeping the assignment inline avoids the whole scope question.
# Both call sites below apply the same rule: first hit wins, but an
# all-lowercase code beats an uppercase one (uppercase needs the Shift key).

$cnEnHits = 0
if (Test-Path -LiteralPath $CnEnPath) {
    foreach ($line in [System.IO.File]::ReadLines($CnEnPath, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.IndexOf("`t") -lt 0) { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }
        $w = $cols[0].Trim()
        $c = $cols[1].Trim()
        if ($w -ne '' -and $c -ne '') {
            if (-not $codeOf.PSBase.ContainsKey($w)) {
                $codeOf[$w] = $c
                $codeSourceOf[$w] = 'cn_en'
            }
            elseif ($codeOf[$w] -cne $codeOf[$w].ToLowerInvariant() -and $c -ceq $c.ToLowerInvariant()) {
                $codeOf[$w] = $c
                $codeSourceOf[$w] = 'cn_en'
            }
        }
        if ($wantSet.Contains($w)) { $cnEnHits++ }
    }
    Write-Host ("  {0,-10} code matched {1}" -f 'cn_en', $cnEnHits)
}
else {
    Write-Host '  [!!] cn_en table not found'
}

foreach ($t in $EnglishTables) {
    $p = Join-Path $EnDictRoot ($t + '.dict.yaml')
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("  [!!] english table missing: " + $t)
        continue
    }
    $hits = 0
    foreach ($line in [System.IO.File]::ReadLines($p, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        if ($line.IndexOf("`t") -lt 0) { continue }
        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }
        $w = $cols[0].Trim()
        $c = $cols[1].Trim()
        if ($w -ne '' -and $c -ne '') {
            if (-not $codeOf.PSBase.ContainsKey($w)) {
                $codeOf[$w] = $c
                $codeSourceOf[$w] = $t
            }
            elseif ($codeOf[$w] -cne $codeOf[$w].ToLowerInvariant() -and $c -ceq $c.ToLowerInvariant()) {
                $codeOf[$w] = $c
                $codeSourceOf[$w] = $t
            }
        }
        if ($wantSet.Contains($w)) { $hits++ }
    }
    Write-Host ("  {0,-10} code matched {1}" -f $t, $hits)
}

# ------------------------------------------------------------------
# 4. normalised fallback index
# ------------------------------------------------------------------
$normPinyin = @{}
foreach ($key in $pinyinOf.PSBase.Keys) {
    $nk = Get-NormKey $key
    if (-not $normPinyin.PSBase.ContainsKey($nk)) { $normPinyin[$nk] = $pinyinOf[$key] }
}
$normCode = @{}
foreach ($key in $codeOf.PSBase.Keys) {
    $nk = Get-NormKey $key
    if (-not $normCode.PSBase.ContainsKey($nk)) { $normCode[$nk] = $codeOf[$key] }
}
Write-Host ("  normalised alias index: " + $normPinyin.PSBase.Count + " pinyin, " + $normCode.PSBase.Count + " code")

# FOOTGUN WARNING, worth remembering:
#   These hashtables are keyed by DICTIONARY WORDS, and the English word list
#   literally contains "count" and "keys". PowerShell resolves $ht.Count and
#   $ht.Keys against the hashtable's OWN ENTRIES first, so $ht.Keys returned
#   the string "keys" and $ht.Count returned the string "count" - the loops
#   then iterated a single bogus element. Every Count/Keys/ContainsKey access
#   on these maps therefore goes through .PSBase to reach the real collection.

# ------------------------------------------------------------------
# 5. resolve and write
# ------------------------------------------------------------------
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('# golden set - fill in the two observation columns')
$rows.Add('#')
$rows.Add('# ref_rank : on the iOS NATIVE Microsoft Shuangpin keyboard, type `code`')
$rows.Add('#            and write the position of the target word in the candidate')
$rows.Add('#            list. 1 = first candidate, 2 = second, 0 = not on the page.')
$rows.Add('# our_rank : the same on OUR Rime scheme. Leave blank if untested.')
$rows.Add('#')
$rows.Add('# Actionable output = words where our_rank - ref_rank >= 2.')
$rows.Add('#')
$rows.Add("category`tword`tcode`tref_rank`tour_rank`pinyin`tlookup")

$gaps = @()
$noEntry = @()
$nPinyin = 0; $nCode = 0; $nNorm = 0; $nComposed = 0

foreach ($item in $wanted) {
    $w = $item.Word
    $target = $w
    $how = ''

    $py = $null
    $code = $null

    if ($pinyinOf.PSBase.ContainsKey($target)) {
        $py = $pinyinOf[$target]
        $how = 'pinyin/' + $pySourceOf[$target]
    }
    elseif ($codeOf.PSBase.ContainsKey($target)) {
        $code = $codeOf[$target]
        $how = 'code/' + $codeSourceOf[$target]
    }
    else {
        $nk = Get-NormKey $w
        if ($normPinyin.PSBase.ContainsKey($nk)) {
            $py = $normPinyin[$nk]
            $how = 'norm-pinyin'
            $nNorm++
        }
        elseif ($normCode.PSBase.ContainsKey($nk)) {
            $code = $normCode[$nk]
            $how = 'norm-code'
            $nNorm++
        }
    }

    if ($null -ne $py) {
        $conv = Convert-MspyPinyin -PinyinText $py
        $rows.Add(($item.Category + "`t" + $w + "`t" + $conv + "`t`t`t" + $py + "`t" + $how))
        $nPinyin++
        continue
    }
    if ($null -ne $code) {
        $rows.Add(($item.Category + "`t" + $w + "`t" + $code + "`t`t`t`t" + $how))
        $nCode++
        continue
    }

    # ---- fallback: compose the pinyin from per-character readings ----
    $parts = New-Object System.Collections.Generic.List[string]
    $composable = $true
    foreach ($ch in $w.ToCharArray()) {
        $s = [string]$ch
        if (Test-IsSingleChar $s -and $charPinyin.PSBase.ContainsKey($s)) {
            $parts.Add($charPinyin[$s])
        }
        else {
            $composable = $false
            break
        }
    }

    if ($composable -and $parts.Count -gt 0) {
        $py = ($parts -join ' ')
        $code = Convert-MspyPinyin -PinyinText $py
        # Composition proves the code is TYPEABLE. It does NOT prove the word
        # exists as a dictionary ENTRY - and that difference matters, because a
        # word with no entry can never become a first-class candidate.
        # A word living only in cn_dicts\tencent DOES have an entry (Rime
        # annotates its pinyin at deploy time), so only the rest are real gaps.
        $tag = 'composed/NO-WORD-ENTRY'
        if ($tencentWords.Contains($w)) {
            $tag = 'composed/tencent-entry'
        }
        else {
            $noEntry += $w
        }
        $rows.Add(($item.Category + "`t" + $w + "`t" + $code + "`t`t`t" + $py + "`t" + $tag + " (polyphone readings may differ)"))
        $nComposed++
        continue
    }

    $gaps += $w
    $rows.Add(($item.Category + "`t" + $w + "`t`t`t`t`tGAP-not-in-dictionary"))
}

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutPath, $rows.ToArray(), $enc)

Write-Host ''
Write-Host ("  via dictionary pinyin : " + $nPinyin)
Write-Host ("  via table code        : " + $nCode)
Write-Host ("  needed normalising    : " + $nNorm)
Write-Host ("  via char composition  : " + $nComposed)
Write-Host ("  NO WORD ENTRY         : " + $noEntry.Count)
if ($noEntry.Count -gt 0) {
    Write-Host '    Typeable by composing per-character readings, but NOT present as'
    Write-Host '    a dictionary entry, so they will never rank as a first-class'
    Write-Host '    candidate. These are dictionary-addition candidates:'
    foreach ($g in $noEntry) { Write-Host ("      - " + $g) }
}
Write-Host ("  TRUE COVERAGE GAPS    : " + $gaps.Count)
if ($gaps.Count -gt 0) {
    Write-Host '    Present in NO table at all - genuinely untypeable as one unit:'
    foreach ($g in $gaps) { Write-Host ("      - " + $g) }
    Write-Host '    These are dictionary-addition candidates, not script failures.'
}
Write-Host ''
Write-Host ("  wrote: " + $OutPath)
Write-Host ''
Write-Host 'Next: fill ref_rank / our_rank on the phone, then run'
Write-Host '      tools\Evaluate-Candidates.ps1'
