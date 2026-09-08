if {[version -short] ne "2025.2"} {
    error "Vivado 2025.2 is required; running [version -short]"
}

set project_dir [file normalize [file join [file dirname [info script]] ..]]
set baseline_dcp [file join $project_dir cmac_usplus_0_ex.runs impl_1 \
    cmac_usplus_0_exdes_postroute_physopt.dcp]
if {![file exists $baseline_dcp]} {
    error "Baseline post-route checkpoint is missing: $baseline_dcp"
}

# This opens the known baseline checkpoint without opening or resetting the
# GUI project. Its reports are the comparison source for build_bitstream.tcl.
open_checkpoint $baseline_dcp
report_timing_summary \
    -delay_type min_max \
    -max_paths 10 \
    -report_unconstrained \
    -file [file join $project_dir tests udp_benchmark_baseline_timing_summary.rpt]
report_utilization \
    -hierarchical \
    -hierarchical_depth 4 \
    -file [file join $project_dir tests udp_benchmark_baseline_hierarchical_utilization.rpt]

set endpoint_grant_cells [get_cells -quiet -hierarchical \
    -filter {NAME =~ *i_tx_packet_arbiter/idle_udp_grant_index_q_reg*}]
set endpoint_output_cells [get_cells -quiet -hierarchical \
    -filter {NAME =~ *i_tx_packet_arbiter/output_data_q_reg*}]
if {![llength $endpoint_grant_cells] || ![llength $endpoint_output_cells]} {
    error "Could not find the registered UDP arbiter timing endpoints"
}
report_timing \
    -delay_type max \
    -from $endpoint_grant_cells \
    -to $endpoint_output_cells \
    -max_paths 10 \
    -file [file join $project_dir tests udp_benchmark_baseline_endpoint_timing.rpt]
close_design
