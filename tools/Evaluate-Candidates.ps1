# Evaluate-Candidates.ps1
# ------------------------------------------------------------------
# Score the golden set and print where our dictionary ranking stands
# against the iOS native Microsoft Shuangpin keyboard.
#
# Reads eval\golden_set.tsv (produced by tools\New-GoldenSet.ps1 and then
# filled in by hand with two candidate positions per word).
#
# METRICS
#   top-1 rate  : share of words whose target IS the first candidate
#   top-3 rate  : share landing within the first 3 candidates
#   mean rank   : average position among words that were found
#   missing     : words that were not on the recorded page at all
#
# The actionable output is the pair list: words where our ranking is worse
# than the reference by >= 2 positions. Those are concrete reweighting
# targets, not guesses.
#
# REGRESSION MODE
#   -Baseline <path>   compare our_rank in this file against our_rank in a
#                      previously filled file, after a dictionary change.
#
# Pure ASCII on purpose (PowerShell 5.1 decodes a BOM-less UTF-8 script
# using the ANSI codepage).
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$SetPath,
    [string]$BaselinePath,
    # a gap this large counts as "meaningfully worse"
    [int]$RegressionWorse = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SetPath) { $SetPath = Join-Path $Root 'eval\golden_set.tsv' }

function Read-GoldenSet([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "golden set not found: $Path" }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        $c = $line -split "`t"
        if ($c.Count -lt 5) { continue }
        if ($c[0] -eq 'category') { continue }   # header

        $refRank = -1; $ourRank = -1
        if ($c[3].Trim() -match '^\d+$') { $refRank = [int]$c[3].Trim() }
        if ($c[4].Trim() -match '^\d+$') { $ourRank = [int]$c[4].Trim() }

        $rows.Add([pscustomobject]@{
                Category = $c[0].Trim()
                Word     = $c[1].Trim()
                Code     = $c[2].Trim()
                RefRank  = $refRank
                OurRank  = $ourRank
            })
    }
    return $rows
}

function Get-Stats([int[]]$Ranks) {
    $found = @($Ranks | Where-Object { $_ -gt 0 })
    $missing = @($Ranks | Where-Object { $_ -eq 0 }).Count
    $n = $found.Count
    if ($n -eq 0) {
        return [pscustomobject]@{ N = 0; Top1 = $null; Top3 = $null; Mean = $null; Missing = $missing }
    }
    $top1 = @($found | Where-Object { $_ -eq 1 }).Count
    $top3 = @($found | Where-Object { $_ -le 3 }).Count
    $mean = ($found | Measure-Object -Average).Average
    return [pscustomobject]@{
        N       = $n
        Top1    = [math]::Round(100.0 * $top1 / $n, 1)
        Top3    = [math]::Round(100.0 * $top3 / $n, 1)
        Mean    = [math]::Round($mean, 2)
        Missing = $missing
    }
}

function Show-Stats([string]$Label, $S) {
    if ($S.N -eq 0) {
        Write-Host ("  {0,-8} no observations yet" -f $Label)
        return
    }
    Write-Host ("  {0,-8} n={1,-4} top-1={2,5}%  top-3={3,5}%  mean-rank={4,5}  missing={5}" -f `
            $Label, $S.N, $S.Top1, $S.Top3, $S.Mean, $S.Missing)
}

# ==================================================================
Write-Host ''
Write-Host 'Candidate-ranking evaluation'
Write-Host '============================'
Write-Host ("  set: " + $SetPath)

$rows = Read-GoldenSet -Path $SetPath
Write-Host ("  words in set: " + $rows.Count)

$refRanks = @($rows | Where-Object { $_.RefRank -ge 0 } | ForEach-Object { $_.RefRank })
$ourRanks = @($rows | Where-Object { $_.OurRank -ge 0 } | ForEach-Object { $_.OurRank })

# ------------------------------------------------------------------
Write-Host ''
Write-Host 'Overall'
$refStats = Get-Stats -Ranks $refRanks
$ourStats = Get-Stats -Ranks $ourRanks
Show-Stats 'native' $refStats
Show-Stats 'ours' $ourStats

if ($refStats.N -eq 0 -and $ourStats.N -eq 0) {
    Write-Host ''
    Write-Host '  Nothing observed yet - fill ref_rank / our_rank in the TSV first.'
    Write-Host '  See eval\README.md for the procedure.'
    exit 0
}

# ------------------------------------------------------------------
Write-Host ''
Write-Host 'By category'
$cats = $rows | Select-Object -ExpandProperty Category | Select-Object -Unique
foreach ($cat in $cats) {
    $sub = @($rows | Where-Object { $_.Category -eq $cat })
    $r = Get-Stats -Ranks @($sub | Where-Object { $_.RefRank -ge 0 } | ForEach-Object { $_.RefRank })
    $o = Get-Stats -Ranks @($sub | Where-Object { $_.OurRank -ge 0 } | ForEach-Object { $_.OurRank })
    if ($r.N -eq 0 -and $o.N -eq 0) { continue }
    Write-Host ("  [" + $cat + "]")
    Show-Stats 'native' $r
    Show-Stats 'ours' $o
}

# ------------------------------------------------------------------
# the actionable part: where are we worse than the reference?
# ------------------------------------------------------------------
$both = @($rows | Where-Object { $_.RefRank -gt 0 -and $_.OurRank -gt 0 })
if ($both.Count -gt 0) {
    Write-Host ''
    Write-Host ("Pairs with both observations: " + $both.Count)

    $gaps = @($both | ForEach-Object {
            [pscustomobject]@{
                Word = $_.Word; Code = $_.Code; Cat = $_.Category
                Ref = $_.RefRank; Our = $_.OurRank; Delta = ($_.OurRank - $_.RefRank)
            }
        })

    $worse = @($gaps | Where-Object { $_.Delta -ge $RegressionWorse } | Sort-Object -Property Delta -Descending)
    $better = @($gaps | Where-Object { $_.Delta -le (-1 * $RegressionWorse) } | Sort-Object -Property Delta)

    Write-Host ''
    if ($worse.Count -gt 0) {
        Write-Host ("  >>> REWEIGHTING TARGETS (" + $worse.Count + "): we rank these >=" + $RegressionWorse + " positions worse") -ForegroundColor Yellow
        foreach ($g in $worse) {
            Write-Host ("      {0,-8} {1,-8} [{2}] native #{3}  ours #{4}  (+{5})" -f $g.Word, $g.Code, $g.Cat, $g.Ref, $g.Our, $g.Delta)
        }
        Write-Host '      ^ raise these words weights in the dictionary override layer'
    }
    else {
        Write-Host '  No word is meaningfully worse than the native keyboard.' -ForegroundColor Green
    }

    Write-Host ''
    if ($better.Count -gt 0) {
        Write-Host ("  We beat the native keyboard on " + $better.Count + " word(s):") -ForegroundColor Green
        foreach ($g in $better) {
            Write-Host ("      {0,-8} {1,-8} [{2}] native #{3}  ours #{4}  ({5})" -f $g.Word, $g.Code, $g.Cat, $g.Ref, $g.Our, $g.Delta)
        }
    }

    $agree = @($gaps | Where-Object { $_.Delta -eq 0 }).Count
    Write-Host ''
    Write-Host ("  exact rank agreement: " + $agree + " / " + $both.Count)
}
else {
    Write-Host ''
    Write-Host '  Need at least one word with BOTH ref_rank and our_rank filled'
    Write-Host '  to compute the native-vs-ours gap.'
}

# ------------------------------------------------------------------
# regression mode
# ------------------------------------------------------------------
if ($BaselinePath) {
    Write-Host ''
    Write-Host 'Regression vs baseline'
    Write-Host ("  baseline: " + $BaselinePath)
    $base = Read-GoldenSet -Path $BaselinePath
    $baseMap = @{}
    foreach ($b in $base) { if ($b.OurRank -gt 0) { $baseMap[$b.Word] = $b.OurRank } }

    $improved = @()
    $regressed = @()
    $unchanged = 0
    foreach ($r in $rows) {
        if ($r.OurRank -le 0) { continue }
        if (-not $baseMap.ContainsKey($r.Word)) { continue }
        $d = $r.OurRank - $baseMap[$r.Word]
        if ($d -lt 0) { $improved += ("{0} ({1} -> {2})" -f $r.Word, $baseMap[$r.Word], $r.OurRank) }
        elseif ($d -gt 0) { $regressed += ("{0} ({1} -> {2})" -f $r.Word, $baseMap[$r.Word], $r.OurRank) }
        else { $unchanged++ }
    }

    Write-Host ("  improved  : " + $improved.Count)
    foreach ($i in $improved) { Write-Host ("      " + $i) }
    Write-Host ("  regressed : " + $regressed.Count)
    foreach ($i in $regressed) { Write-Host ("      " + $i) }
    Write-Host ("  unchanged : " + $unchanged)

    Write-Host ''
    if ($regressed.Count -gt 0) {
        Write-Host '  RESULT: REGRESSION - do not ship this dictionary change.' -ForegroundColor Red
        exit 1
    }
    Write-Host '  RESULT: no regressions.' -ForegroundColor Green
}
