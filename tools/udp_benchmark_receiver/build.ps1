param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$sourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDirectory = Join-Path $sourceDirectory 'build'

cmake -S $sourceDirectory -B $buildDirectory "-DUDP_BENCHMARK_CONFIGURATION=$Configuration"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cmake --build $buildDirectory --config $Configuration
exit $LASTEXITCODE
