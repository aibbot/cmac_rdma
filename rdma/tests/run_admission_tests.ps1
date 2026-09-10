$ErrorActionPreference = 'Stop'

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $testDirectory
$buildDirectory = Join-Path $rdmaDirectory 'build\sim\transport_timer_scale'
$xvlog = 'D:\Xilinx\2025.2\Vivado\bin\xvlog.bat'
$xelab = 'D:\Xilinx\2025.2\Vivado\bin\xelab.bat'
$xsim = 'D:\Xilinx\2025.2\Vivado\bin\xsim.bat'

foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (!(Test-Path -LiteralPath $tool)) {
        throw "Vivado 2025.2 simulator tool is missing: $tool"
    }
}

$versionText = (& $xvlog --version 2>&1 | Out-String)
if ($versionText -notmatch 'v2025\.2') {
    throw "Vivado 2025.2 is required. Found: $versionText"
}

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
