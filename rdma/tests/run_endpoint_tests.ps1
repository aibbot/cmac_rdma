$ErrorActionPreference = 'Stop'

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $testDirectory
$buildRoot = Join-Path $rdmaDirectory 'build\sim\endpoint'
$crcParallel = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_crc32_parallel.sv'
$endpoint = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_endpoint.sv'
$endpointDesignFiles = @($crcParallel, $endpoint)
$resetSynchronizer = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_reset_sync.sv'
$grayCounterCdc = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_gray_counter_cdc.sv'
$rxAdmission = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_rx_admission.sv'
$txPacketArbiter = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_tx_packet_arbiter.sv'
$pauseControl = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_pause_control.sv'
$pauseDiagnostics = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_pause_diagnostics.sv'
$rxClassifier = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_rx_classifier.sv'
$txFrameArbiter = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_tx_frame_arbiter.sv'
$rdcpControl = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdcp_control.sv'
$boardEndpoint = Join-Path $rdmaDirectory 'rtl\cmac_usplus_0_rdma_board_endpoint.sv'
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

function Invoke-RdmaEndpointTest {
    param(
        [Parameter(Mandatory = $true)] [string] $Top,
        [string[]] $DesignFiles = @(),
        [Parameter(Mandatory = $true)] [string] $TestFile
    )

    $buildDirectory = Join-Path $buildRoot $Top
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

    Push-Location $buildDirectory
    try {
        & $xvlog --sv @DesignFiles $TestFile
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed for $Top with exit code $LASTEXITCODE" }

        & $xelab $Top -s "${Top}_sim" --mt 8
        if ($LASTEXITCODE -ne 0) { throw "xelab failed for $Top with exit code $LASTEXITCODE" }

        & $xsim "${Top}_sim" -runall
        if ($LASTEXITCODE -ne 0) { throw "xsim failed for $Top with exit code $LASTEXITCODE" }

        $simulationLog = Get-Content -Raw -LiteralPath (Join-Path $buildDirectory 'xsim.log')
        if ($simulationLog -notmatch 'cmac_usplus_0_rdma_notification_interval_tb PASS' -and
            $simulationLog -notmatch "${Top} PASS") {
            throw "$Top did not report PASS"
        }
    } finally {
        Pop-Location
    }
}

Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_crc32_parallel_tb' `
    -DesignFiles @($crcParallel) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_crc32_parallel_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_icrc_vector_tb' `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_icrc_vector_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_reset_sync_tb' `
    -DesignFiles @($resetSynchronizer) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_reset_sync_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_gray_counter_cdc_tb' `
    -DesignFiles @($grayCounterCdc) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_gray_counter_cdc_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_rx_admission_tb' `
    -DesignFiles @($rxAdmission) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_rx_admission_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_rx_classifier_tb' `
    -DesignFiles @($rxClassifier) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_rx_classifier_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_frame_arbiter_tb' `
    -DesignFiles @($txFrameArbiter) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_tx_frame_arbiter_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_control_tb' `
    -DesignFiles @($rdcpControl) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdcp_control_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_packet_arbiter_tb' `
    -DesignFiles @($txPacketArbiter) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_tx_packet_arbiter_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_pause_control_tb' `
    -DesignFiles @($pauseControl) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_pause_control_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_pause_diagnostics_tb' `
    -DesignFiles @($pauseDiagnostics) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_pause_diagnostics_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_axis_register_tb' `
    -DesignFiles @($boardEndpoint) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_axis_register_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_abort_guard_tb' `
    -DesignFiles @($txPacketArbiter, $boardEndpoint) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_tx_abort_guard_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_drain_tracker_tb' `
    -DesignFiles @($boardEndpoint) `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_tx_drain_tracker_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_endpoint_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_endpoint_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_ring_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_ring_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_1m_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_10m_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_stop_boundary_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_data_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_credit_nak_race_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_abort_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_commit_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_out_of_window_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_second_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_repeated_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_repeated_nak_psn_wrap_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_cross_message_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_default_recovery_limit_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_fatal_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_ring_boundary_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'cmac_usplus_0_rdma_notification_interval_tb.sv')

Write-Host 'RDMA endpoint SystemVerilog tests passed'
