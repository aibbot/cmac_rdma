param([string] $VivadoBin)

$ErrorActionPreference = 'Stop'

if (!$VivadoBin) {
    $VivadoBin = Split-Path -Parent (Get-Command vivado.bat -ErrorAction Stop).Source
}
$VivadoBin = (Resolve-Path -LiteralPath $VivadoBin -ErrorAction Stop).Path

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $testDirectory
$xvlog = Join-Path $VivadoBin 'xvlog.bat'
$xelab = Join-Path $VivadoBin 'xelab.bat'
$xsim = Join-Path $VivadoBin 'xsim.bat'

foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (!(Test-Path -LiteralPath $tool)) {
        throw "Vivado simulator tool is missing: $tool"
    }
}

$versionText = (& $xvlog --version 2>&1 | Out-String)
$versionMatch = [regex]::Match($versionText, 'v(2024|2025)\.2(\.[0-9]+)?\b')
if ($LASTEXITCODE -ne 0 -or !$versionMatch.Success) {
    throw "Vivado 2024.2 or 2025.2 is required. Found: $versionText"
}
$buildDirectory = Join-Path $rdmaDirectory "build\sim\$($versionMatch.Groups[1].Value).2\transport_timer_scale"

Remove-Item -LiteralPath $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

Push-Location $buildDirectory
try {
    & $xvlog --sv (Join-Path $testDirectory 'transport_timer_scale_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }

    & $xelab transport_timer_scale_tb -s transport_timer_scale_tb_sim
    if ($LASTEXITCODE -ne 0) { throw "xelab failed with exit code $LASTEXITCODE" }

    & $xsim transport_timer_scale_tb_sim -runall
    if ($LASTEXITCODE -ne 0) { throw "xsim failed with exit code $LASTEXITCODE" }

    $simulationLog = Get-Content -Raw -LiteralPath (Join-Path $buildDirectory 'xsim.log')
    if ($simulationLog -notmatch 'PASS: transport_timer_scale_tb') {
        throw 'Timer scale simulation did not report PASS'
    }
} finally {
    Pop-Location
}

Write-Host 'RDMA admission SystemVerilog tests passed'
