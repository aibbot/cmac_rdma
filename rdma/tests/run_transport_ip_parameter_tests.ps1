$ErrorActionPreference = 'Stop'

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $testDirectory
$buildRoot = Join-Path $rdmaDirectory 'build\sim\transport_ip_parameters'
$designFiles = @(
    (Join-Path $rdmaDirectory 'rtl\rdma_reset_sync.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_endpoint_pkg.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_config_manager.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_ack_receiver.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_crc32_parallel.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_external_packet_builder.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_replay_buffer.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_sequence_recovery.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_packet_layout.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_payload_buffer.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_endpoint.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_transport_core.sv'),
    (Join-Path $rdmaDirectory 'rtl\rdma_transport_ip.sv')
)
$testFile = Join-Path $testDirectory 'rdma_transport_ip_parameter_tb.sv'
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

function Invoke-TransportIpParameterTest {
    param(
        [Parameter(Mandatory = $true)] [string] $Top,
        [string] $ExpectedError = ''
    )

    $buildDirectory = Join-Path $buildRoot $Top
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

    Push-Location $buildDirectory
    try {
        & $xvlog --sv @designFiles $testFile
        if ($LASTEXITCODE -ne 0) {
            throw "xvlog failed for $Top with exit code $LASTEXITCODE"
        }

        & $xelab $Top -s "${Top}_sim" --mt 8
        if ($LASTEXITCODE -ne 0) {
            throw "xelab failed for $Top with exit code $LASTEXITCODE"
        }

        & $xsim "${Top}_sim" -runall
        $simulationLog = Get-Content -Raw -LiteralPath (Join-Path $buildDirectory 'xsim.log')

        if ($ExpectedError) {
            if ($simulationLog -notmatch [regex]::Escape("RDMA_IP_PARAMETER_ERROR: $ExpectedError")) {
                throw "$Top did not reject invalid $ExpectedError"
            }
        } else {
            if ($LASTEXITCODE -ne 0 -or $simulationLog -notmatch "${Top} PASS") {
                throw "$Top did not report PASS"
            }
        }
    } finally {
        Pop-Location
    }
}

Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_parameter_tb'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_frequency_tb'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_reset_contract_tb'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_ack_timeout_zero_tb' `
    -ExpectedError 'ACK_TIMEOUT_CYCLES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_retry_overflow_tb' `
    -ExpectedError 'MAX_RETRIES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_retry_negative_tb' `
    -ExpectedError 'MAX_RETRIES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_recovery_negative_tb' `
    -ExpectedError 'MAX_SEQUENCE_RECOVERIES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_recovery_quiet_zero_tb' `
    -ExpectedError 'SEQUENCE_RECOVERY_QUIET_CYCLES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_rnr_timer_zero_tb' `
    -ExpectedError 'RNR_TIMER_10US_CYCLES'
Invoke-TransportIpParameterTest `
    -Top 'cmac_usplus_0_rdma_transport_ip_local_qpn_zero_tb' `
    -ExpectedError 'LOCAL_QPN'

Write-Host 'RDMA transport IP parameter tests passed'
