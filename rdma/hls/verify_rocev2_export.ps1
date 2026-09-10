param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
$componentPath = Join-Path $BuildDirectory 'iprepo\rocev2\component.xml'
$reportPath = Join-Path $BuildDirectory 'rocev2_prj\solution1\syn\report\rocev2_top_csynth.rpt'

if (!(Test-Path -LiteralPath $componentPath)) {
    throw "Exported component.xml is missing: $componentPath"
}
if (!(Test-Path -LiteralPath $reportPath)) {
    throw "HLS synthesis report is missing: $reportPath"
}

[xml]$component = Get-Content -Raw -LiteralPath $componentPath
$namespace = New-Object System.Xml.XmlNamespaceManager($component.NameTable)
$namespace.AddNamespace('spirit', 'http://www.spiritconsortium.org/XMLSchema/SPIRIT/1685-2009')

$requiredPortWidths = [ordered]@{
    's_axis_rx_data_TDATA'          = 512
    's_axis_rx_data_TKEEP'          = 64
    's_axis_rx_data_TLAST'          = 1
    'm_axis_tx_data_TDATA'          = 512
    'm_axis_tx_data_TKEEP'          = 64
    'm_axis_tx_data_TLAST'          = 1
    's_axis_sq_meta_TDATA'           = 248
    'm_axis_rx_ack_meta_TDATA'       = 56
    'm_axis_mem_write_cmd_TDATA'     = 144
    'm_axis_mem_read_cmd_TDATA'      = 144
    'm_axis_mem_write_data_TDATA'    = 512
    'm_axis_mem_write_data_TKEEP'    = 64
    'm_axis_mem_write_data_TLAST'    = 1
    's_axis_mem_read_data_TDATA'     = 512
    's_axis_mem_read_data_TKEEP'     = 64
    's_axis_mem_read_data_TLAST'     = 1
    's_axis_qp_interface_TDATA'      = 184
    's_axis_qp_conn_interface_TDATA' = 184
    'local_ip_address'               = 128
}

foreach ($entry in $requiredPortWidths.GetEnumerator()) {
    $portName = $entry.Key
    $port = $component.SelectSingleNode("//spirit:model/spirit:ports/spirit:port[spirit:name='$portName']", $namespace)
    if (!$port) { throw "Exported IP port is missing: $portName" }

    $left = $port.SelectSingleNode('spirit:wire/spirit:vector/spirit:left', $namespace)
    $right = $port.SelectSingleNode('spirit:wire/spirit:vector/spirit:right', $namespace)
    $actualWidth = if ($left -and $right) {
        [int]$left.InnerText - [int]$right.InnerText + 1
    } else {
        1
    }
    if ($actualWidth -ne $entry.Value) {
        throw "Exported IP port width mismatch for ${portName}: expected $($entry.Value), found $actualWidth"
    }
}

$report = Get-Content -Raw -LiteralPath $reportPath
$timingMatch = [regex]::Match(
    $report,
    '(?m)^\s*\|ap_clk\s*\|\s*(?<target>[0-9.]+)\s*ns\|\s*(?<estimated>[0-9.]+)\s*ns\|\s*(?<uncertainty>[0-9.]+)\s*ns\|'
)
if (!$timingMatch.Success) {
    throw 'HLS synthesis report has no ap_clk timing summary'
}

$targetPeriod = [double]::Parse($timingMatch.Groups['target'].Value, [Globalization.CultureInfo]::InvariantCulture)
$estimatedPeriod = [double]::Parse($timingMatch.Groups['estimated'].Value, [Globalization.CultureInfo]::InvariantCulture)
$uncertainty = [double]::Parse($timingMatch.Groups['uncertainty'].Value, [Globalization.CultureInfo]::InvariantCulture)
if ([Math]::Abs($targetPeriod - 4.0) -gt 0.001) {
    throw 'HLS synthesis report does not target a 4.00 ns clock period'
}
if ($estimatedPeriod -gt $targetPeriod) {
    Write-Warning ("HLS estimate misses the 4.00 ns target: estimated {0:N3} ns (uncertainty {1:N2} ns)" -f $estimatedPeriod, $uncertainty)
}

Write-Host ("RoCEv2 HLS export verified: 4.00 ns target, {0:N3} ns estimate, interfaces and widths match" -f $estimatedPeriod)
Write-Host "Component: $componentPath"
