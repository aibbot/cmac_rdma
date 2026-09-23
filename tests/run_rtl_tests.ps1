$ErrorActionPreference = 'Stop'

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = Split-Path -Parent $testDirectory
$importsDirectory = Join-Path $projectDirectory 'imports'

Push-Location $testDirectory
try {
    $simulatorVersion = (& xvlog --version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $simulatorVersion -notmatch 'v2025\.2') {
        throw "Vivado Simulator 2025.2 is required. Found: $simulatorVersion"
    }

    & xvlog --sv `
        (Join-Path $importsDirectory 'cmac_usplus_0_network_types.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_udp_config_pipeline.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_udp_benchmark_core.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_udp_benchmark.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_tx_packet_arbiter.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_ping_reply_engine.sv') `
        (Join-Path $importsDirectory 'cmac_usplus_0_ping_responder.sv') `
        (Join-Path $testDirectory 'cmac_usplus_0_ping_responder_tb.sv') `
        (Join-Path $testDirectory 'cmac_usplus_0_udp_benchmark_tb.sv') `
        (Join-Path $testDirectory 'cmac_usplus_0_network_endpoint_tb.sv') `
        (Join-Path $testDirectory 'cmac_usplus_0_tx_packet_arbiter_tb.sv')
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed with exit code $LASTEXITCODE" }

    $tests = @(
        @{ Top = 'cmac_usplus_0_ping_responder_tb'; Snapshot = 'ping_responder_tb_sim' },
        @{ Top = 'cmac_usplus_0_udp_benchmark_tb'; Snapshot = 'udp_benchmark_tb_sim' },
        @{ Top = 'cmac_usplus_0_network_endpoint_tb'; Snapshot = 'network_endpoint_tb_sim' },
        @{ Top = 'cmac_usplus_0_tx_packet_arbiter_tb'; Snapshot = 'tx_packet_arbiter_tb_sim' }
    )

    foreach ($test in $tests) {
        & xelab $test.Top -s $test.Snapshot
        if ($LASTEXITCODE -ne 0) {
            throw "xelab failed for $($test.Top) with exit code $LASTEXITCODE"
        }
        & xsim $test.Snapshot -runall
        if ($LASTEXITCODE -ne 0) {
            throw "xsim failed for $($test.Top) with exit code $LASTEXITCODE"
        }

        $simulationLog = Get-Content -Raw (Join-Path $testDirectory 'xsim.log')
        if ($simulationLog -match '(?m)^(Fatal:|Error:)') {
            throw "xsim reported a simulation failure for $($test.Top)"
        }
        if ($simulationLog -notmatch [regex]::Escape("$($test.Top) PASS")) {
            throw "xsim did not report PASS for $($test.Top)"
        }
    }
} finally {
    Pop-Location
}
