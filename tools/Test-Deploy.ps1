# Test-Deploy.ps1
# ------------------------------------------------------------------
# Run a REAL headless Rime deployment against our config and report what
# actually happened. This is not a static check - librime really compiles
# the dictionaries and really writes the merged configs.
#
# It turns three non-obvious findings into something reproducible:
#
#   1. rime_deployer.exe needs rime.dll NEXT TO IT. The official Windows
#      package ships rime.dll under dist\lib while the exe lives in
#      dist\bin, so it dies with 0xC0000135 (STATUS_DLL_NOT_FOUND) unless
#      the DLL is copied across. No third-party deps are needed - the MSVC
#      build links them in.
#
#   2. The directories are POSITIONAL arguments, not named flags:
#         --build <user_data_dir> <shared_data_dir> <staging_dir>
#      Passing --user-data-dir ... just prints "invalid arguments."
#      (extract the real usage by strings-scanning the exe if unsure)
#
#   3. The staging dir receives the PATCH-MERGED configs (default.yaml,
#      <schema>.schema.yaml). That makes them readable evidence of whether
#      our .custom.yaml patches actually took effect - which no static
#      check can prove.
#
# Pure ASCII on purpose (PowerShell 5.1 decodes a BOM-less UTF-8 script
# using the ANSI codepage).
#
# USAGE:
#   .\Test-Deploy.ps1                      # test dist\Rime as-is
#   .\Test-Deploy.ps1 -Tier lean           # rebuild at tier lean, then test
# ------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('full', 'lean', 'slim', 'asis')]
    [string]$Tier = 'asis',
    [string]$DeployerPath,
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$distDir = Join-Path $Root 'dist\Rime'
$work = Join-Path $Root 'deploy-test\verify'

function Write-Head([string]$T) { Write-Host ''; Write-Host ('== ' + $T) -ForegroundColor Cyan }
function Write-Ok([string]$T) { Write-Host ('   [ok] ' + $T) -ForegroundColor Green }
function Write-Bad([string]$T) { Write-Host ('   [!!] ' + $T) -ForegroundColor Red }
function Write-Info([string]$T) { Write-Host ('   ' + $T) }

# ------------------------------------------------------------------
if ($Tier -ne 'asis') {
    Write-Head ('rebuild at tier ' + $Tier)
    & (Join-Path $Root 'build.ps1') -Tier $Tier -NoZip *>&1 | Out-Null
    Write-Ok 'dist rebuilt'
}

# ------------------------------------------------------------------
Write-Head 'locate rime_deployer and rime.dll'
if (-not $DeployerPath) {
    $cand = Get-ChildItem (Join-Path $Root 'deploy-test\bin') -Recurse -Filter 'rime_deployer.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cand) { $DeployerPath = $cand.FullName }
}
if (-not $DeployerPath -or -not (Test-Path -LiteralPath $DeployerPath)) {
    Write-Bad 'rime_deployer.exe not found.'
    Write-Info 'Download the prebuilt Windows package from'
    Write-Info '  https://github.com/rime/librime/releases  (rime-*-Windows-msvc-x64.7z)'
    Write-Info 'and extract it (Windows bsdtar can read 7z):'
    Write-Info '  tar -xf rime-*-Windows-msvc-x64.7z -C deploy-test\bin\rime-main'
    exit 1
}
$binDir = Split-Path -Parent $DeployerPath
Write-Ok ('deployer: ' + $DeployerPath)

# finding 1: rime.dll must sit beside the exe
$dllBeside = Join-Path $binDir 'rime.dll'
if (-not (Test-Path -LiteralPath $dllBeside)) {
    $src = Join-Path (Split-Path -Parent $binDir) 'lib\rime.dll'
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dllBeside -Force
        Write-Ok 'copied rime.dll next to the exe (required)'
    }
    else {
        Write-Bad 'rime.dll not found next to the exe nor in ..\lib'
        exit 1
    }
}
else {
    Write-Ok 'rime.dll already beside the exe'
}

# ------------------------------------------------------------------
Write-Head 'stage a fresh user dir from dist\Rime'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$user = Join-Path $work 'user'
$shared = Join-Path $work 'shared'
$staging = Join-Path $user 'build'
$logDir = Join-Path $work 'log'
foreach ($d in @($user, $shared, $staging, $logDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
if (-not (Test-Path -LiteralPath $distDir)) { Write-Bad ('dist not found: ' + $distDir); exit 1 }
Copy-Item -Path (Join-Path $distDir '*') -Destination $user -Recurse -Force
Write-Ok ('staged ' + (Get-ChildItem $user -Recurse -File).Count + ' files')

# ------------------------------------------------------------------
Write-Head 'run the deployment'
$env:GLOG_log_dir = $logDir
$t0 = Get-Date
# finding 2: positional args
& $DeployerPath --build $user $shared $staging *>&1 | Out-Null
$exit = $LASTEXITCODE
$secs = [int]((Get-Date) - $t0).TotalSeconds
if ($exit -eq 0) { Write-Ok ("exit=0 in " + $secs + "s") } else { Write-Bad ("exit=" + $exit + " (deployment failed)") }

# ------------------------------------------------------------------
Write-Head 'log severity'
$infoLog = Get-ChildItem $logDir -Filter '*INFO*' -ErrorAction SilentlyContinue | Select-Object -First 1
$errors = 0
$warnTotal = 0
$warnDup = 0
$warnOther = @()
if ($infoLog) {
    $lines = Select-String -Path $infoLog.FullName -Pattern '^[EW]\d{4}' -Encoding UTF8
    $errors = @($lines | Where-Object { $_.Line -match '^E\d{4}' }).Count
    $warns = @($lines | Where-Object { $_.Line -match '^W\d{4}' })
    $warnTotal = $warns.Count
    $warnDup = @($warns | Where-Object { $_.Line -match 'entry_collector\.cc:\d+\] duplicate word definition' }).Count
    # rime-ice documents these two as ignorable (melt_eng self-reference)
    $warnOther = @($warns |
            Where-Object { $_.Line -notmatch 'duplicate word definition' } |
            Where-Object { $_.Line -notmatch 'circular dependencies detected' } |
            Where-Object { $_.Line -notmatch 'accessing blocking node' } |
            Where-Object { $_.Line -notmatch 'nonexistent config file' })
}
$errFile = Get-ChildItem $logDir -Filter '*ERROR*' -ErrorAction SilentlyContinue

Write-Info ('ERROR-level lines      : ' + $errors)
Write-Info ('glog .ERROR. file      : ' + $(if ($errFile) { 'PRESENT (bad)' } else { 'absent' }))
Write-Info ('WARNING total          : ' + $warnTotal)
Write-Info ('  duplicate word (known): ' + $warnDup)
Write-Info ('  melt_eng self-ref     : documented as ignorable')
Write-Info ('  UNEXPECTED warnings   : ' + $warnOther.Count)
foreach ($w in ($warnOther | Select-Object -First 10)) { Write-Host ('      ' + $w.Line) }

# ------------------------------------------------------------------
Write-Head 'verify the patches actually merged (finding 3)'
# the staging dir holds the patched configs, so read them back
$defFile = Join-Path $staging 'default.yaml'
if (Test-Path -LiteralPath $defFile) {
    $refs = @()
    foreach ($l in (Get-Content -LiteralPath $defFile -Encoding UTF8)) {
        if ($l -match '^\s*#') { continue }
        $m = [regex]::Match($l, '-\s*schema:\s*([A-Za-z0-9_]+)')
        if ($m.Success) { $refs += $m.Groups[1].Value }
    }
    if ($refs.Count -eq 1 -and $refs[0] -eq 'double_pinyin_mspy') {
        Write-Ok 'schema_list pruned to exactly double_pinyin_mspy'
    }
    else { Write-Bad ('schema_list is: ' + ($refs -join ', ')) }
}
else { Write-Bad 'merged default.yaml not found in staging' }

$schemaFile = Join-Path $staging 'double_pinyin_mspy.schema.yaml'
if (Test-Path -LiteralPath $schemaFile) {
    $s = Get-Content -LiteralPath $schemaFile -Raw -Encoding UTF8
    $checks = @(
        @{ n = 'schema/name'; p = '(?m)^\s{2}name:\s*(.+?)\s*$' },
        @{ n = 'translator/dictionary'; p = '(?ms)^translator:.*?^\s{2}dictionary:\s*(\S+)' },
        @{ n = 'radical dictionary'; p = '(?ms)^radical_reverse_lookup:.*?^\s{2}dictionary:\s*(\S+)' },
        @{ n = 'preedit_format'; p = '(?ms)^translator:.*?^\s{2}preedit_format:\s*(\[\]|\S+)' }
    )
    foreach ($c in $checks) {
        $m = [regex]::Match($s, $c.p)
        if ($m.Success) { Write-Ok ($c.n + ' = ' + $m.Groups[1].Value) }
        else { Write-Info ($c.n + ' = (not found)') }
    }
}
else { Write-Bad 'merged schema not found in staging' }

# ------------------------------------------------------------------
Write-Head 'compiled size'
$bins = Get-ChildItem $staging -File -Filter *.bin -ErrorAction SilentlyContinue
if ($bins) {
    foreach ($b in ($bins | Sort-Object Length -Descending)) {
        Write-Info ('{0,-32} {1,9:N2} MB' -f $b.Name, ($b.Length / 1MB))
    }
    $all = ($bins | Measure-Object Length -Sum).Sum
    Write-Host ''
    Write-Host ('   TOTAL .bin = ' + [math]::Round($all / 1MB, 2) + ' MB') -ForegroundColor Yellow
    Write-Info 'reference: full 72.82 | lean 42.68 | slim 31.79 MB (all .bin)'
}
else { Write-Bad 'no .bin produced' }

if (-not $KeepWork) {
    Write-Host ''
    Write-Info ('work dir kept for inspection: ' + $work)
}

Write-Host ''
if ($exit -eq 0 -and $errors -eq 0 -and $warnOther.Count -eq 0 -and -not $errFile) {
    Write-Host 'RESULT: DEPLOY OK - no errors, no unexpected warnings.' -ForegroundColor Green
    exit 0
}
Write-Host 'RESULT: review the problems above.' -ForegroundColor Red
exit 1
