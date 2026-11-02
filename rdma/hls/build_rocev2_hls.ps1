param(
    [string]$SourceDirectory = '',
    [switch]$SkipCsim
)

$ErrorActionPreference = 'Stop'

$hlsDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $hlsDirectory
$projectDirectory = Split-Path -Parent $rdmaDirectory
$lock = Get-Content -Raw -LiteralPath (Join-Path $rdmaDirectory 'fpga_network_stack.lock.json') | ConvertFrom-Json
$dependencyDirectory = Join-Path $rdmaDirectory 'third_party\fpga-network-stack'
$buildDirectory = Join-Path $rdmaDirectory 'build\hls'
$sourceCopy = Join-Path $buildDirectory 'fpga-network-stack'
$configDirectory = Join-Path $buildDirectory 'config'
$hlsProjectDirectory = Join-Path $buildDirectory 'rocev2_prj'
$exportDirectory = Join-Path $buildDirectory 'iprepo'
$vitisRun = 'D:\Xilinx\2025.2\Vitis\bin\vitis-run.bat'

if (!(Test-Path -LiteralPath $vitisRun)) {
    throw "Vitis 2025.2 is required at $vitisRun"
}
$versionText = (& $vitisRun --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'v2025\.2') {
    throw "Vitis 2025.2 is required. Found: $versionText"
}

if (!$SourceDirectory) {
    $SourceDirectory = $dependencyDirectory
    if (!(Test-Path -LiteralPath (Join-Path $SourceDirectory '.git'))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SourceDirectory) | Out-Null
        & git clone --filter=blob:none --no-checkout $lock.repository $SourceDirectory
        if ($LASTEXITCODE -ne 0) { throw 'Failed to clone fpga-network-stack' }
        & git -C $SourceDirectory fetch --depth 1 origin $lock.branch
        if ($LASTEXITCODE -ne 0) { throw 'Failed to fetch the locked fpga-network-stack branch' }
        & git -C $SourceDirectory checkout --detach $lock.commit
        if ($LASTEXITCODE -ne 0) { throw 'Failed to check out the locked fpga-network-stack commit' }
    }
}

$SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).Path
$actualCommit = (& git -C $SourceDirectory rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $lock.commit) {
    throw "fpga-network-stack commit mismatch. Expected $($lock.commit), found $actualCommit"
}
if (& git -C $SourceDirectory status --porcelain) {
    throw 'The fpga-network-stack source checkout must be clean'
}

$sourceManifest = Join-Path $hlsDirectory 'fpga_network_stack_sources.txt'
$requiredSources = Get-Content -LiteralPath $sourceManifest | Where-Object { $_ -and !$_.StartsWith('#') }
foreach ($relativeSource in $requiredSources) {
    $sourcePath = Join-Path $SourceDirectory $relativeSource
    if (!(Test-Path -LiteralPath $sourcePath)) {
        throw "Required source is missing: $relativeSource"
    }
    $header = (Get-Content -LiteralPath $sourcePath -TotalCount 45) -join "`n"
    if ($header -notmatch 'Redistribution and use in source and binary forms') {
        throw "Required source has no BSD-3-Clause license header: $relativeSource"
    }
}

Remove-Item -LiteralPath $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $sourceCopy, $configDirectory, $exportDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDirectory 'hls') -Destination $sourceCopy -Recurse

$sourceCopyRelative = [IO.Path]::GetRelativePath($projectDirectory, $sourceCopy).Replace('\', '/')
Push-Location $projectDirectory
try {
    $patches = Get-ChildItem -LiteralPath (Join-Path $hlsDirectory 'patches') -Filter '*.patch' | Sort-Object Name
    foreach ($patch in $patches) {
        & git apply --no-index --check "--directory=$sourceCopyRelative" $patch.FullName
        if ($LASTEXITCODE -ne 0) { throw "Patch does not apply to the locked source: $($patch.Name)" }
        & git apply --no-index "--directory=$sourceCopyRelative" $patch.FullName
        if ($LASTEXITCODE -ne 0) { throw "Failed to apply patch: $($patch.Name)" }
    }
} finally {
    Pop-Location
}

$timerHeader = Get-Content -Raw -LiteralPath (Join-Path $sourceCopy 'hls\ib_transport_protocol\transport_timer.hpp')
if ($timerHeader -notmatch 'CLOCK_PERIOD_US' -or $timerHeader -match '0\.0064') {
    throw 'Clock-period patch verification failed'
}
$csimSource = Get-Content -Raw -LiteralPath (Join-Path $sourceCopy 'hls\rocev2\test_rocev2.cpp')
if ($csimSource -match '#include\s+<(sys/socket|sys/types|netdb|fcntl)\.h>') {
    throw 'Windows C-sim compatibility patch verification failed'
}
if ($csimSource -notmatch '(?m)^void rocev2_top\(' -or
    $csimSource -notmatch '\[PASSED\] rocev2_top') {
    throw 'Top-level RoCEv2 C-sim compatibility patch verification failed'
}

$configHeader = @"
#pragma once
#include <stdint.h>

#define RETRANS_EN

const unsigned DATA_WIDTH = $($lock.data_width_bits);
const uint16_t MAX_QPS = $($lock.max_qps);
const uint16_t PMTU = $($lock.pmtu_bytes);
const uint16_t PMTU_WORDS = PMTU / (DATA_WIDTH / 8);
static constexpr double CLOCK_PERIOD_US = $($lock.clock_period_ns) / 1000.0;
static const uint32_t PCIE_BATCH_PKG = 12;
static const uint32_t PCIE_BATCH_SIZE = PMTU * PCIE_BATCH_PKG;
"@
[System.IO.File]::WriteAllText((Join-Path $configDirectory 'rocev2_config.hpp'), $configHeader)
$widthHeader = "#pragma once`n`nconst unsigned DATA_WIDTH = $($lock.data_width_bits);`n"
[System.IO.File]::WriteAllText((Join-Path $configDirectory 'ipv4_config.hpp'), $widthHeader)
[System.IO.File]::WriteAllText((Join-Path $configDirectory 'ipv6_config.hpp'), $widthHeader)
[System.IO.File]::WriteAllText((Join-Path $configDirectory 'udp_config.hpp'), $widthHeader)

$env:RDMA_HLS_SOURCE_DIR = $sourceCopy
$env:RDMA_HLS_CONFIG_DIR = $configDirectory
$env:RDMA_HLS_PROJECT_DIR = $hlsProjectDirectory
$env:RDMA_HLS_EXPORT_DIR = $exportDirectory
$env:RDMA_HLS_RUN_CSIM = if ($SkipCsim) { '0' } else { '1' }
try {
    & $vitisRun --mode hls --tcl (Join-Path $hlsDirectory 'rocev2_hls.tcl') --work_dir $buildDirectory
    if ($LASTEXITCODE -ne 0) { throw "RoCEv2 HLS build failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item Env:RDMA_HLS_SOURCE_DIR, Env:RDMA_HLS_CONFIG_DIR, Env:RDMA_HLS_PROJECT_DIR, Env:RDMA_HLS_EXPORT_DIR, Env:RDMA_HLS_RUN_CSIM -ErrorAction SilentlyContinue
}

& (Join-Path $hlsDirectory 'verify_rocev2_export.ps1') -BuildDirectory $buildDirectory
if ($LASTEXITCODE -ne 0) { throw 'Exported RoCEv2 IP verification failed' }
