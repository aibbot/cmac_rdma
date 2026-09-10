# This runs as the opt_design pre-hook, after the RDMA wrapper has been
# linked. The vendor file creates debug cores and is valid Tcl, but those
# commands are intentionally not parsed as an XDC constraint file.
set rdma_debug_script_dir [file dirname [file normalize [info script]]]
set rdma_debug_project_dir [file normalize [file join $rdma_debug_script_dir .. ..]]
set rdma_legacy_debug_xdc [file join $rdma_debug_project_dir imports cmac_usplus_0_ila_debug.xdc]

current_instance u_cmac_usplus_0_exdes
set rdma_legacy_debug_clock [get_nets -quiet {txusrclk2}]
if {[llength $rdma_legacy_debug_clock] != 1} {
  error "Legacy ILA debug clock is missing: expected u_cmac_usplus_0_exdes/txusrclk2"
}

# The vendor debug definition names an internal CMAC-IP RX clock. That net is
# optimized away when the CMAC is synthesized out of context. The example
# packet monitor and the RDMA CMAC AXI boundary both use txusrclk2, which stays
# in the linked netlist and is the stable debug clock for these probes.
set rdma_legacy_debug_file [open $rdma_legacy_debug_xdc r]
set rdma_legacy_debug_script [read $rdma_legacy_debug_file]
close $rdma_legacy_debug_file
set rdma_legacy_debug_script [string map [list \
  {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out} \
  {txusrclk2}] $rdma_legacy_debug_script]
eval $rdma_legacy_debug_script

# DRPDO and DRPRDY are produced on init_clk and are sampled only by the
# txusrclk2 legacy ILAs. Cut those 17 debug-only crossings without relaxing any
# functional path between the two clock domains.
set rdma_legacy_async_debug_nets [concat \
  [get_nets -quiet {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[*]}] \
  [get_nets -quiet {i_cmac_usplus_0_pkt_gen_mon/common0_drprdy}]]
if {[llength $rdma_legacy_async_debug_nets] != 17} {
  error "Expected 17 asynchronous legacy DRP debug nets, found [llength $rdma_legacy_async_debug_nets]"
}
set rdma_legacy_async_debug_drivers [get_pins -quiet -leaf \
  -of_objects $rdma_legacy_async_debug_nets -filter {DIRECTION == OUT}]
if {[llength $rdma_legacy_async_debug_drivers] != 17} {
  error "Expected 17 asynchronous legacy DRP debug drivers, found [llength $rdma_legacy_async_debug_drivers]"
}
set rdma_legacy_init_clock [get_clocks -quiet init_clk]
if {[llength $rdma_legacy_init_clock] != 1} {
  error "Legacy DRP source clock is missing: expected init_clk"
}
foreach rdma_legacy_async_debug_driver $rdma_legacy_async_debug_drivers {
  set_false_path -from $rdma_legacy_init_clock \
    -through $rdma_legacy_async_debug_driver
}
puts "RDMA_LEGACY_DEBUG_ASYNC_CHECK nets=[llength $rdma_legacy_async_debug_nets] drivers=[llength $rdma_legacy_async_debug_drivers]"
current_instance
