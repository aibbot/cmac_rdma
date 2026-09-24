$ErrorActionPreference = 'Stop'

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$rdmaDirectory = Split-Path -Parent $testDirectory
$buildRoot = Join-Path $rdmaDirectory 'build\sim\endpoint'
$endpointPackage = Join-Path $rdmaDirectory 'rtl\rdma_endpoint_pkg.sv'
$configManager = Join-Path $rdmaDirectory 'rtl\rdma_config_manager.sv'
$ackReceiver = Join-Path $rdmaDirectory 'rtl\rdma_ack_receiver.sv'
$crcParallel = Join-Path $rdmaDirectory 'rtl\rdma_crc32_parallel.sv'
$externalPacketBuilder = Join-Path $rdmaDirectory 'rtl\rdma_external_packet_builder.sv'
$replayBuffer = Join-Path $rdmaDirectory 'rtl\rdma_replay_buffer.sv'
$sequenceRecovery = Join-Path $rdmaDirectory 'rtl\rdma_sequence_recovery.sv'
$packetLayout = Join-Path $rdmaDirectory 'rtl\rdma_packet_layout.sv'
$endpoint = Join-Path $rdmaDirectory 'rtl\rdma_endpoint.sv'
$endpointDesignFiles = @($endpointPackage, $configManager, $ackReceiver,
    $crcParallel, $externalPacketBuilder, $replayBuffer, $sequenceRecovery,
    $packetLayout, $endpoint)
$payloadBuffer = Join-Path $rdmaDirectory 'rtl\rdma_payload_buffer.sv'
$transportCore = Join-Path $rdmaDirectory 'rtl\rdma_transport_core.sv'
$transportIp = Join-Path $rdmaDirectory 'rtl\rdma_transport_ip.sv'
$networkCore = Join-Path $rdmaDirectory 'rtl\rdma_network_core.sv'
$resetSynchronizer = Join-Path $rdmaDirectory 'rtl\rdma_reset_sync.sv'
$grayCounterCdc = Join-Path $rdmaDirectory 'rtl\rdma_gray_counter_cdc.sv'
$rxAdmission = Join-Path $rdmaDirectory 'rtl\rdma_rx_admission.sv'
$txPacketArbiter = Join-Path $rdmaDirectory 'rtl\rdma_tx_packet_arbiter.sv'
$pauseControl = Join-Path $rdmaDirectory 'rtl\rdma_pause_control.sv'
$pauseDiagnostics = Join-Path $rdmaDirectory 'rtl\rdma_pause_diagnostics.sv'
$rxClassifier = Join-Path $rdmaDirectory 'rtl\rdma_rx_classifier.sv'
$txFrameArbiter = Join-Path $rdmaDirectory 'rtl\rdma_tx_frame_arbiter.sv'
$rdcpPackage = Join-Path $rdmaDirectory 'rtl\rdcp_pkg.sv'
$rdcpRxValidate = Join-Path $rdmaDirectory 'rtl\rdcp_rx_validate.sv'
$rdcpRequestParser = Join-Path $rdmaDirectory 'rtl\rdcp_request_parser.sv'
$rdcpSessionEngine = Join-Path $rdmaDirectory 'rtl\rdcp_session_engine.sv'
$rdcpResponseEncoder = Join-Path $rdmaDirectory 'rtl\rdcp_response_encoder.sv'
$rdcpControl = Join-Path $rdmaDirectory 'rtl\rdcp_control.sv'
$axisRegister = Join-Path $rdmaDirectory 'rtl\rdma_axis_register.sv'
$txDrainTracker = Join-Path $rdmaDirectory 'rtl\rdma_tx_drain_tracker.sv'
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

& (Join-Path $testDirectory 'run_transport_ip_parameter_tests.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "RDMA transport IP parameter tests failed with exit code $LASTEXITCODE"
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
    -TestFile (Join-Path $testDirectory 'rdma_crc32_parallel_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_config_manager_tb' `
    -DesignFiles @($endpointPackage, $configManager) `
    -TestFile (Join-Path $testDirectory 'rdma_config_manager_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_ack_receiver_tb' `
    -DesignFiles @($endpointPackage, $ackReceiver) `
    -TestFile (Join-Path $testDirectory 'rdma_ack_receiver_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_external_packet_builder_tb' `
    -DesignFiles @($crcParallel, $externalPacketBuilder) `
    -TestFile (Join-Path $testDirectory 'rdma_external_packet_builder_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_replay_buffer_tb' `
    -DesignFiles @($replayBuffer) `
    -TestFile (Join-Path $testDirectory 'rdma_replay_buffer_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_sequence_recovery_tb' `
    -DesignFiles @($endpointPackage, $sequenceRecovery) `
    -TestFile (Join-Path $testDirectory 'rdma_sequence_recovery_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_packet_layout_tb' `
    -DesignFiles @($endpointPackage, $packetLayout) `
    -TestFile (Join-Path $testDirectory 'rdma_packet_layout_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_icrc_vector_tb' `
    -TestFile (Join-Path $testDirectory 'rdma_icrc_vector_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_reset_sync_tb' `
    -DesignFiles @($resetSynchronizer) `
    -TestFile (Join-Path $testDirectory 'rdma_reset_sync_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_gray_counter_cdc_tb' `
    -DesignFiles @($grayCounterCdc) `
    -TestFile (Join-Path $testDirectory 'rdma_gray_counter_cdc_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_rx_admission_tb' `
    -DesignFiles @($rxAdmission) `
    -TestFile (Join-Path $testDirectory 'rdma_rx_admission_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_rx_classifier_tb' `
    -DesignFiles @($rxClassifier) `
    -TestFile (Join-Path $testDirectory 'rdma_rx_classifier_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_frame_arbiter_tb' `
    -DesignFiles @($txFrameArbiter) `
    -TestFile (Join-Path $testDirectory 'rdma_tx_frame_arbiter_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_payload_buffer_tb' `
    -DesignFiles @($payloadBuffer) `
    -TestFile (Join-Path $testDirectory 'rdma_payload_buffer_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_rx_validate_tb' `
    -DesignFiles @($rdcpPackage, $rdcpRxValidate) `
    -TestFile (Join-Path $testDirectory 'rdcp_rx_validate_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_request_parser_tb' `
    -DesignFiles @($rdcpPackage, $rdcpRequestParser) `
    -TestFile (Join-Path $testDirectory 'rdcp_request_parser_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_session_engine_tb' `
    -DesignFiles @($rdcpPackage, $rdcpSessionEngine) `
    -TestFile (Join-Path $testDirectory 'rdcp_session_engine_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_fault_arbiter_tb' `
    -DesignFiles @($rdcpPackage, $rdcpSessionEngine) `
    -TestFile (Join-Path $testDirectory 'rdcp_fault_arbiter_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_config_recovery_tb' `
    -DesignFiles @($rdcpPackage, $endpointPackage, $configManager, $ackReceiver, $crcParallel, $externalPacketBuilder, $replayBuffer, $sequenceRecovery, $packetLayout, $rdcpSessionEngine, $endpoint) `
    -TestFile (Join-Path $testDirectory 'rdcp_config_recovery_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_response_encoder_tb' `
    -DesignFiles @($rdcpPackage, $rdcpResponseEncoder) `
    -TestFile (Join-Path $testDirectory 'rdcp_response_encoder_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdcp_control_tb' `
    -DesignFiles @($rdcpPackage, $rdcpRxValidate, $rdcpRequestParser, $rdcpSessionEngine, $rdcpResponseEncoder, $rdcpControl) `
    -TestFile (Join-Path $testDirectory 'rdcp_control_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_external_payload_tb' `
    -DesignFiles @($resetSynchronizer, $endpointPackage, $configManager, $ackReceiver, $crcParallel, $externalPacketBuilder, $replayBuffer, $sequenceRecovery, $packetLayout, $payloadBuffer, $endpoint, $transportCore, $transportIp) `
    -TestFile (Join-Path $testDirectory 'rdma_external_payload_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_external_lifecycle_tb' `
    -DesignFiles @($resetSynchronizer, $endpointPackage, $configManager, $ackReceiver, $crcParallel, $externalPacketBuilder, $replayBuffer, $sequenceRecovery, $packetLayout, $payloadBuffer, $endpoint, $transportCore, $transportIp) `
    -TestFile (Join-Path $testDirectory 'rdma_external_lifecycle_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_network_core_tb' `
    -DesignFiles @($rdcpPackage, $rdcpRxValidate, $rdcpRequestParser, $rdcpSessionEngine, $rdcpResponseEncoder, $rdcpControl, $endpointPackage, $configManager, $ackReceiver, $crcParallel, $externalPacketBuilder, $replayBuffer, $sequenceRecovery, $packetLayout, $payloadBuffer, $endpoint, $transportCore, $rxClassifier, $txFrameArbiter, $networkCore) `
    -TestFile (Join-Path $testDirectory 'rdma_network_core_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_packet_arbiter_tb' `
    -DesignFiles @($txPacketArbiter) `
    -TestFile (Join-Path $testDirectory 'rdma_tx_packet_arbiter_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_pause_control_tb' `
    -DesignFiles @($pauseControl) `
    -TestFile (Join-Path $testDirectory 'rdma_pause_control_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_pause_diagnostics_tb' `
    -DesignFiles @($pauseDiagnostics) `
    -TestFile (Join-Path $testDirectory 'rdma_pause_diagnostics_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_axis_register_tb' `
    -DesignFiles @($axisRegister) `
    -TestFile (Join-Path $testDirectory 'rdma_axis_register_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_abort_guard_tb' `
    -DesignFiles @($txPacketArbiter, $axisRegister) `
    -TestFile (Join-Path $testDirectory 'rdma_tx_abort_guard_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_tx_drain_tracker_tb' `
    -DesignFiles @($txDrainTracker) `
    -TestFile (Join-Path $testDirectory 'rdma_tx_drain_tracker_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_endpoint_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_endpoint_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_ring_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_ring_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_1m_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_10m_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_stop_boundary_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_data_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_retransmission_disabled_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_credit_nak_race_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_abort_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_commit_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_commit_nak_disabled_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_out_of_window_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_oow_disabled_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_second_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_repeated_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_repeated_nak_psn_wrap_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_cross_message_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_default_recovery_limit_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_limit0_disabled_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_fatal_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_fatal_nak_retransmission_disabled_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')
Invoke-RdmaEndpointTest -Top 'cmac_usplus_0_rdma_notification_fast_ring_boundary_nak_tb' `
    -DesignFiles $endpointDesignFiles `
    -TestFile (Join-Path $testDirectory 'rdma_notification_interval_tb.sv')

Write-Host 'RDMA endpoint SystemVerilog tests passed'
