# ConvertTo-Mspy.ps1
# ------------------------------------------------------------------
# Convert standard (full) pinyin into Microsoft Shuangpin (MSPY) codes.
#
# This is a *faithful re-implementation* of the speller/algebra found in
# rime-ice's double_pinyin_mspy.schema.yaml, which in turn comes from the
# authoritative Rime schema rime/rime-double-pinyin.
#
# WHY THIS SCRIPT EXISTS:
#   1. custom_phrase_double.txt needs codes written in *Shuangpin* form
#      (a table_translator matches the input buffer literally, and in a
#      Shuangpin schema the input buffer holds Shuangpin codes).
#      Typing those codes by hand is error-prone, so generate them.
#   2. It doubles as an executable spec of the key mapping: the self-test
#      asserts known-good codes derived from the official schema. If the
#      test passes, the mapping understanding is verified.
#
# NOTE: this file is deliberately pure ASCII so that it survives any
# PowerShell 5.1 encoding quirk. Test data lives in mspy_test_cases.tsv.
#
# USAGE:
#   .\ConvertTo-Mspy.ps1 -Pinyin "ni hao"        -> nihk
#   .\ConvertTo-Mspy.ps1 -Pinyin "zhong'guo"     -> vsgo
#   .\ConvertTo-Mspy.ps1 -SelfTest
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Pinyin,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest

# Bridge characters.
#
# The schema replaces each final with a single *circled letter* (e.g. iu -> Q,
# ua -> W) and only folds those back to lowercase qwerty at the very end.
# That trick matters: it stops an already-converted final from being matched
# again by a later rule (e.g. after "sh" folded to a bridge char, the trailing
# "ui" must not be re-matched by the ui rule).
#
# We need the same trick, but circled letters are non-ASCII and fragile in a
# PowerShell script file, so we use non-letter single characters instead.
# Any character that is not [a-z] works, because every algebra pattern only
# ever matches letters.
#
# The only constraint is that a bridge char must not be '$', which is special
# inside a .NET regex *replacement* string.
$script:Bridge = [ordered]@{
    '1' = 'q'   # iu
    '2' = 'w'   # ia / ua
    '3' = 'r'   # er / uan / u-umlaut-an
    '4' = 't'   # ue / u-umlaut-e
    '5' = 'y'   # u-umlaut / uai
    '6' = 'u'   # sh
    '7' = 'i'   # ch
    '8' = 'v'   # zh
    '9' = 'o'   # uo
    '0' = 'p'   # un / u-umlaut-n
    '+' = 's'   # ong / iong
    '-' = 'd'   # iang / uang
    '*' = 'f'   # en
    '/' = 'g'   # eng
    '=' = 'h'   # ang
    '<' = 'm'   # ian
    '>' = 'j'   # an
    '?' = 'c'   # iao
    '!' = 'k'   # ao
    '@' = 'l'   # ai
    '~' = 'z'   # ei
    '%' = 'x'   # ie
    '^' = 'v'   # ui
    '&' = 'b'   # ou
    '(' = 'n'   # in
    ')' = ';'   # ing
}

function Convert-MspySyllable {
    <#
    .SYNOPSIS
      Convert ONE full-pinyin syllable to its MSPY code.
    .DESCRIPTION
      Rules are applied in exactly the order used by the schema's algebra.
      Order matters a lot, e.g. 'ian' must be folded before 'an', and
      'iang' before 'ang'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PinyinText
    )

    # Normalise: lowercase, and write u-umlaut as v (the schema's convention).
    $s = $PinyinText.ToLowerInvariant()
    $s = $s.Replace([string][char]0x00FC, 'v')

    # --- algebra, in schema order -------------------------------------
    # derive/^([jqxy])u$/$1v/     ju qu xu yu  ->  jv qv xv yv
    $s = $s -replace '^([jqxy])u$', '$1v'

    # xform/^([ae])(.*)$/$1$1$2/  zero-initial a/e get doubled: a -> aa
    # (the schema ALSO derives an 'o'-prefixed variant, but that is an
    #  extra accepted spelling; the doubled form is the canonical one)
    $s = $s -replace '^([ae])(.*)$', '$1$1$2'

    # finals -> bridge chars
    $s = $s -replace 'iu$', '1'
    $s = $s -replace '[iu]a$', '2'
    $s = $s -replace 'er$|[uv]an$', '3'
    $s = $s -replace '[uv]e$', '4'
    $s = $s -replace 'v$|uai$', '5'

    # initials -> bridge chars
    $s = $s -replace '^sh', '6'
    $s = $s -replace '^ch', '7'
    $s = $s -replace '^zh', '8'

    # remaining finals -> bridge chars
    $s = $s -replace 'uo$', '9'
    $s = $s -replace '[uv]n$', '0'
    $s = $s -replace '(.)i?ong$', '$1+'
    $s = $s -replace '[iu]ang$', '-'
    $s = $s -replace '(.)en$', '$1*'
    $s = $s -replace '(.)eng$', '$1/'
    $s = $s -replace '(.)ang$', '$1='
    $s = $s -replace 'ian$', '<'
    $s = $s -replace '(.)an$', '$1>'
    $s = $s -replace 'iao$', '?'
    $s = $s -replace '(.)ao$', '$1!'
    $s = $s -replace '(.)ai$', '$1@'
    $s = $s -replace '(.)ei$', '$1~'
    $s = $s -replace 'ie$', '%'
    $s = $s -replace 'ui$', '^'
    $s = $s -replace '(.)ou$', '$1&'
    $s = $s -replace 'in$', '('
    $s = $s -replace 'ing$', ')'

    # --- fold bridge chars back to the real keys ----------------------
    foreach ($bridgeChar in $script:Bridge.Keys) {
        $s = $s.Replace($bridgeChar, $script:Bridge[$bridgeChar])
    }

    return $s
}

function Convert-MspyPinyin {
    <#
    .SYNOPSIS
      Convert a whole pinyin string (multiple syllables) to MSPY codes.
    .DESCRIPTION
      Syllables may be separated by spaces or apostrophes; the separator is
      dropped so the result is one continuous code, which is what a
      custom_phrase entry wants.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PinyinText
    )

    $parts = $PinyinText.Trim() -split "[ '\u2019]+" | Where-Object { $_ -ne '' }
    $out = foreach ($p in $parts) { Convert-MspySyllable -PinyinText $p }
    return ($out -join '')
}

function Invoke-MspySelfTest {
    <#
    .SYNOPSIS
      Run the key-mapping test suite.
    .DESCRIPTION
      Reads mspy_test_cases.tsv (UTF-8, ASCII-only content, tab separated:
      pinyin<TAB>expected_code). Every expectation was derived by hand from
      the authoritative schema. Returns $true when everything passes.
    #>
    [CmdletBinding()]
    param(
        [string]$CasesPath = (Join-Path $PSScriptRoot 'mspy_test_cases.tsv')
    )

    if (-not (Test-Path -LiteralPath $CasesPath)) {
        throw "Test case file not found: $CasesPath"
    }

    $pass = 0
    $fail = 0
    $failures = @()

    foreach ($line in (Get-Content -LiteralPath $CasesPath -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }

        $cols = $line -split "`t"
        if ($cols.Count -lt 2) { continue }

        $py = $cols[0].Trim()
        $expected = $cols[1].Trim()
        $actual = Convert-MspyPinyin -PinyinText $py

        if ($actual -eq $expected) {
            $pass++
        }
        else {
            $fail++
            $note = ''
            if ($cols.Count -ge 3) { $note = $cols[2].Trim() }
            $failures += ("  {0,-12} expected {1,-8} got {2,-8} {3}" -f $py, $expected, $actual, $note)
        }
    }

    Write-Host ''
    Write-Host 'MSPY key-mapping self-test'
    Write-Host '=========================='
    Write-Host ("  passed: {0}" -f $pass)
    Write-Host ("  failed: {0}" -f $fail)

    if ($fail -gt 0) {
        Write-Host ''
        Write-Host 'Failures:'
        foreach ($f in $failures) { Write-Host $f }
        return $false
    }

    Write-Host ''
    Write-Host 'All cases passed - the MSPY mapping matches the schema.'
    return $true
}

# ------------------------------------------------------------------
# CLI entry point (skipped when the file is dot-sourced)
# ------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {

    if ($SelfTest) {
        $ok = Invoke-MspySelfTest
        if (-not $ok) { exit 1 }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Pinyin)) {
        Write-Host 'Usage:'
        Write-Host '  .\ConvertTo-Mspy.ps1 -Pinyin "ni hao"     # -> nihk'
        Write-Host '  .\ConvertTo-Mspy.ps1 -SelfTest'
        exit 1
    }

    Write-Output (Convert-MspyPinyin -PinyinText $Pinyin)
}
