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
# txusrclk2 legacy ILAs. Enumerate each crossing explicitly so a renamed,
# missing, or extra bit cannot silently broaden the waiver.
set rdma_legacy_async_debug_nets [list]
for {set rdma_legacy_drp_bit 0} {$rdma_legacy_drp_bit < 16} {incr rdma_legacy_drp_bit} {
  # The packet monitor port is an input boundary and has no leaf driver after
  # linking. Resolve the source from the actual GTYE4 primitive output, then
  # derive its canonical net so the waiver remains pin-to-pin and auditable.
  set rdma_legacy_drp_source [get_pins -quiet -hierarchical -regexp \
    [format {.*GTYE4_COMMON_PRIM_INST/DRPDO\[%d\]$} $rdma_legacy_drp_bit]]
  if {[llength $rdma_legacy_drp_source] != 1} {
    error "Expected one GTYE4 DRPDO source pin for bit $rdma_legacy_drp_bit, found [llength $rdma_legacy_drp_source]"
  }
  set rdma_legacy_drp_net [get_nets -quiet -of_objects $rdma_legacy_drp_source]
  if {[llength $rdma_legacy_drp_net] != 1} {
    error "Expected one canonical DRPDO net for bit $rdma_legacy_drp_bit, found [llength $rdma_legacy_drp_net]"
  }
  lappend rdma_legacy_async_debug_nets $rdma_legacy_drp_net
}
set rdma_legacy_drprdy_source [get_pins -quiet -hierarchical -regexp \
  {.*GTYE4_COMMON_PRIM_INST/DRPRDY$}]
if {[llength $rdma_legacy_drprdy_source] != 1} {
  error "Expected one GTYE4 DRPRDY source pin, found [llength $rdma_legacy_drprdy_source]"
}
set rdma_legacy_drprdy_net [get_nets -quiet -of_objects $rdma_legacy_drprdy_source]
if {[llength $rdma_legacy_drprdy_net] != 1} {
  error "Expected one canonical DRPRDY net, found [llength $rdma_legacy_drprdy_net]"
}
lappend rdma_legacy_async_debug_nets $rdma_legacy_drprdy_net
if {[llength $rdma_legacy_async_debug_nets] != 17} {
  error "Expected 17 explicitly enumerated asynchronous legacy DRP debug nets, found [llength $rdma_legacy_async_debug_nets]"
}

set rdma_legacy_async_debug_drivers [list]
set rdma_legacy_async_debug_sinks [list]
foreach rdma_legacy_async_debug_net $rdma_legacy_async_debug_nets {
  set rdma_legacy_net_drivers [get_pins -quiet -leaf \
    -of_objects $rdma_legacy_async_debug_net -filter {DIRECTION == OUT}]
  if {[llength $rdma_legacy_net_drivers] != 1} {
    error "Expected one driver for legacy DRP net $rdma_legacy_async_debug_net, found [llength $rdma_legacy_net_drivers]"
  }
  lappend rdma_legacy_async_debug_drivers [lindex $rdma_legacy_net_drivers 0]

  # Vivado 2025.2 does not populate IS_DEBUG on these physical pins. Depending
  # on whether the debug core is represented before or after opt_design, the
  # leaf sink is either the generated ILA D pin or the connected probe bit
  # (for example, u_ila_0/probe9[3]). Accept only those two exact forms.
  set rdma_legacy_net_sinks [get_pins -quiet -leaf \
    -of_objects $rdma_legacy_async_debug_net -filter {DIRECTION == IN}]
  if {[llength $rdma_legacy_net_sinks] != 1} {
    error "Expected one ILA destination D pin for legacy DRP net $rdma_legacy_async_debug_net, found [llength $rdma_legacy_net_sinks]"
  }
  set rdma_legacy_sink_name [get_property NAME [lindex $rdma_legacy_net_sinks 0]]
  if {![regexp {(^|/)u_ila(_[0-9]+|_status_[0-9]+)?/(.*\/D|probe[0-9]+\[[0-9]+\])$} $rdma_legacy_sink_name]} {
    error "Legacy DRP net does not terminate at an ILA sink: $rdma_legacy_sink_name"
  }
  lappend rdma_legacy_async_debug_sinks [lindex $rdma_legacy_net_sinks 0]
}
if {[llength $rdma_legacy_async_debug_drivers] != 17 ||
    [llength $rdma_legacy_async_debug_sinks] != 17} {
  error "Legacy DRP debug object counts are not 17: nets=[llength $rdma_legacy_async_debug_nets] drivers=[llength $rdma_legacy_async_debug_drivers] sinks=[llength $rdma_legacy_async_debug_sinks]"
}
set rdma_legacy_init_clock [get_clocks -quiet init_clk]
if {[llength $rdma_legacy_init_clock] != 1} {
  error "Legacy DRP source clock is missing: expected init_clk"
}
for {set rdma_legacy_waiver_index 0} {$rdma_legacy_waiver_index < 17} {incr rdma_legacy_waiver_index} {
  set rdma_legacy_async_debug_driver [lindex $rdma_legacy_async_debug_drivers $rdma_legacy_waiver_index]
  set rdma_legacy_async_debug_sink [lindex $rdma_legacy_async_debug_sinks $rdma_legacy_waiver_index]
  # The probe port is a debug-core boundary rather than a legal timing
  # endpoint before opt_design. The canonical DRP net is nevertheless a
  # one-bit, one-driver, one-ILA-sink path, so cut exactly that net from the
  # source clock. This keeps one auditable timing exception per crossing
  # without a wildcard clock-group exception.
  set_false_path -from $rdma_legacy_init_clock \
    -through [lindex $rdma_legacy_async_debug_nets $rdma_legacy_waiver_index]
}
puts "RDMA_LEGACY_DEBUG_ASYNC_CHECK nets=[llength $rdma_legacy_async_debug_nets] drivers=[llength $rdma_legacy_async_debug_drivers] ila_sinks=[llength $rdma_legacy_async_debug_sinks] false_paths=17"
current_instance

# Debug-core implementation replaces each probe port with an internal ILA D
# pin during opt_design. Apply CDC waivers only after that transformation so
# each waiver names the actual endpoint reported by report_cdc.
proc rdma_apply_legacy_debug_cdc_waivers {{rdma_waiver_xdc ""}} {
  set rdma_legacy_drp_clock_pin [get_pins -quiet -hierarchical -regexp \
    {.*GTYE4_COMMON_PRIM_INST/DRPCLK$}]
  if {[llength $rdma_legacy_drp_clock_pin] != 1} {
    error "Expected one GTYE4 DRPCLK source pin, found [llength $rdma_legacy_drp_clock_pin]"
  }

  set rdma_legacy_cdc_sources [list]
  for {set rdma_legacy_drp_bit 0} {$rdma_legacy_drp_bit < 16} {incr rdma_legacy_drp_bit} {
    set rdma_legacy_drp_source [get_pins -quiet -hierarchical -regexp \
      [format {.*GTYE4_COMMON_PRIM_INST/DRPDO\[%d\]$} $rdma_legacy_drp_bit]]
    if {[llength $rdma_legacy_drp_source] != 1} {
      error "Expected one post-opt GTYE4 DRPDO source pin for bit $rdma_legacy_drp_bit, found [llength $rdma_legacy_drp_source]"
    }
    lappend rdma_legacy_cdc_sources [lindex $rdma_legacy_drp_source 0]
  }
  set rdma_legacy_drprdy_source [get_pins -quiet -hierarchical -regexp \
    {.*GTYE4_COMMON_PRIM_INST/DRPRDY$}]
  if {[llength $rdma_legacy_drprdy_source] != 1} {
    error "Expected one post-opt GTYE4 DRPRDY source pin, found [llength $rdma_legacy_drprdy_source]"
  }
  lappend rdma_legacy_cdc_sources [lindex $rdma_legacy_drprdy_source 0]

  set rdma_legacy_cdc_sinks [list]
  foreach rdma_legacy_cdc_source $rdma_legacy_cdc_sources {
    set rdma_legacy_cdc_net [get_nets -quiet -of_objects $rdma_legacy_cdc_source]
    if {[llength $rdma_legacy_cdc_net] != 1} {
      error "Expected one post-opt legacy DRP net for $rdma_legacy_cdc_source, found [llength $rdma_legacy_cdc_net]"
    }
    set rdma_legacy_cdc_drivers [get_pins -quiet -leaf \
      -of_objects $rdma_legacy_cdc_net -filter {DIRECTION == OUT}]
    if {[llength $rdma_legacy_cdc_drivers] != 1 ||
        [get_property NAME [lindex $rdma_legacy_cdc_drivers 0]] ne
        [get_property NAME $rdma_legacy_cdc_source]} {
      error "Legacy DRP net does not have its expected single GTYE4 driver: $rdma_legacy_cdc_net"
    }

    set rdma_legacy_cdc_sink [get_pins -quiet -leaf \
      -of_objects $rdma_legacy_cdc_net -filter {DIRECTION == IN}]
    if {[llength $rdma_legacy_cdc_sink] != 1} {
      error "Expected one post-opt ILA D pin for $rdma_legacy_cdc_net, found [llength $rdma_legacy_cdc_sink]"
    }
    set rdma_legacy_cdc_sink_name [get_property NAME $rdma_legacy_cdc_sink]
    if {![regexp {(^|/)u_ila(_[0-9]+|_status_[0-9]+)?/inst/.*/D$} \
        $rdma_legacy_cdc_sink_name]} {
      error "Post-opt legacy DRP net does not terminate at an ILA D pin: $rdma_legacy_cdc_sink_name"
    }
    lappend rdma_legacy_cdc_sinks [lindex $rdma_legacy_cdc_sink 0]
  }

  if {[llength $rdma_legacy_cdc_sources] != 17 ||
      [llength $rdma_legacy_cdc_sinks] != 17} {
    error "Post-opt legacy CDC object counts are not 17: sources=[llength $rdma_legacy_cdc_sources] sinks=[llength $rdma_legacy_cdc_sinks]"
  }
  set rdma_existing_legacy_waivers [get_waivers -quiet -filter \
    {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
  if {[llength $rdma_existing_legacy_waivers] != 0} {
    error "Legacy DRP CDC waivers already exist before creation: [llength $rdma_existing_legacy_waivers]"
  }

  foreach rdma_legacy_cdc_sink $rdma_legacy_cdc_sinks {
    set rdma_legacy_cdc_waiver [create_waiver \
      -type CDC \
      -id {CDC-1} \
      -user {rdma_build} \
      -tags {rdma_legacy_drp_debug} \
      -desc {Legacy GTYE4 DRP status is sampled only by a txusrclk2 diagnostic ILA} \
      -from $rdma_legacy_drp_clock_pin \
      -to $rdma_legacy_cdc_sink]
    if {$rdma_legacy_cdc_waiver eq ""} {
      error "Vivado did not create a CDC-1 waiver for $rdma_legacy_cdc_sink"
    }
  }

  set rdma_created_legacy_waivers [get_waivers -quiet -filter \
    {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
  if {[llength $rdma_created_legacy_waivers] != 17} {
    error "Expected 17 public legacy DRP CDC waivers, found [llength $rdma_created_legacy_waivers]"
  }

  # Vivado 2025.2 write_waivers -objects expects design objects, not waiver
  # objects. Emit a deterministic XDC with explicit pin lookups so reopening
  # the routed checkpoint recreates the same 17 narrow waivers.
  if {$rdma_waiver_xdc ne ""} {
    set rdma_waiver_channel [open $rdma_waiver_xdc w]
    puts $rdma_waiver_channel "# Exact legacy GTYE4 DRP-to-ILA CDC waivers."
    puts $rdma_waiver_channel "# Generated and count-checked by apply_legacy_debug.tcl."
    set rdma_legacy_drp_clock_name [get_property NAME $rdma_legacy_drp_clock_pin]
    set rdma_legacy_drp_clock_lookup \
      [format {[get_pins -quiet %s]} [list $rdma_legacy_drp_clock_name]]
    foreach rdma_legacy_cdc_sink $rdma_legacy_cdc_sinks {
      set rdma_legacy_cdc_sink_name [get_property NAME $rdma_legacy_cdc_sink]
      set rdma_legacy_cdc_sink_lookup \
        [format {[get_pins -quiet %s]} [list $rdma_legacy_cdc_sink_name]]
      puts $rdma_waiver_channel [format \
        {create_waiver -type CDC -id {CDC-1} -user {rdma_build} -tags {rdma_legacy_drp_debug} -desc {Legacy GTYE4 DRP status is sampled only by a txusrclk2 diagnostic ILA} -from %s -to %s} \
        $rdma_legacy_drp_clock_lookup $rdma_legacy_cdc_sink_lookup]
    }
    close $rdma_waiver_channel
  }
  puts "RDMA_LEGACY_DEBUG_CDC_WAIVERS sources=17 ila_d_pins=17 waivers=17"
  return 17
}
