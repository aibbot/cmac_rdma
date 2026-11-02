param(
    [string]$BuildDirectory = '',
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'

$hlsDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $hlsDirectory
if (!$BuildDirectory) {
    $BuildDirectory = Join-Path $rdmaDirectory 'build\hls'
}
$BuildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path

$vivado = 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat'
$rtlDirectory = Join-Path $BuildDirectory 'iprepo\rocev2\hdl\verilog'
$xdcFile = Join-Path $BuildDirectory 'iprepo\rocev2\constraints\rocev2_top_ooc.xdc'
$oocDirectory = Join-Path $BuildDirectory 'ooc'
$projectDirectory = Join-Path $oocDirectory 'project'
$reportDirectory = Join-Path $oocDirectory 'reports'

if (!(Test-Path -LiteralPath $vivado)) {
    throw "Vivado 2025.2 is required at $vivado"
}
$versionText = (& $vivado -version 2>&1 | Out-String)
if ($versionText -notmatch 'v2025\.2') {
    throw "Vivado 2025.2 is required. Found: $versionText"
}
if (!(Test-Path -LiteralPath $rtlDirectory)) {
    throw "Exported HLS Verilog directory is missing: $rtlDirectory"
}
if (!(Test-Path -LiteralPath $xdcFile)) {
    throw "Exported HLS OOC constraint is missing: $xdcFile"
}

if (!$Resume) {
    Remove-Item -LiteralPath $oocDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $projectDirectory, $reportDirectory | Out-Null

$env:RDMA_OOC_RTL_DIR = $rtlDirectory
$env:RDMA_OOC_XDC_FILE = $xdcFile
$env:RDMA_OOC_PROJECT_DIR = $projectDirectory
$env:RDMA_OOC_REPORT_DIR = $reportDirectory
$env:RDMA_OOC_RESUME = if ($Resume) { '1' } else { '0' }
try {
    & $vivado -mode batch -nojournal -nolog -source (Join-Path $hlsDirectory 'rocev2_ooc.tcl')
    if ($LASTEXITCODE -ne 0) {
        throw "RoCEv2 OOC timing gate failed with Vivado exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item Env:RDMA_OOC_RTL_DIR, Env:RDMA_OOC_XDC_FILE, Env:RDMA_OOC_PROJECT_DIR, Env:RDMA_OOC_REPORT_DIR, Env:RDMA_OOC_RESUME -ErrorAction SilentlyContinue
}

Write-Host "RoCEv2 OOC timing/DRC/routing gate passed: $(Join-Path $reportDirectory 'result.txt')"
