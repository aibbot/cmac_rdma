set dcp [file normalize [file join [file dirname [file normalize [info script]]] .. build vivado_rdma rdma.runs rdma_synth_1 rdma_top.dcp]]
open_checkpoint $dcp
current_instance u_cmac_usplus_0_exdes
set vio_pin [get_pins -quiet -hierarchical -regexp {.*i_rdma_vio/probe_out0$}]
puts "VIO_PIN_COUNT=[llength $vio_pin]"
if {[llength $vio_pin] == 1} {
  set vio_net [get_nets -quiet -of_objects $vio_pin]
  puts "VIO_NET_COUNT=[llength $vio_net] VIO_NET=[get_property NAME $vio_net]"
  foreach p [get_pins -quiet -leaf -of_objects $vio_net -filter {DIRECTION == IN}] {
    puts "VIO_SINK=[get_property NAME $p]"
  }
}
set xdc [file normalize [file join [file dirname [file normalize [info script]]] .. .. imports cmac_usplus_0_ila_debug.xdc]]
set f [open $xdc r]
set s [read $f]
close $f
set s [string map [list {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out} {txusrclk2}] $s]
eval $s
puts "DEBUG_CORES=[llength [get_debug_cores -quiet]]"
for {set bit 0} {$bit < 2} {incr bit} {
  set source [get_pins -quiet -hierarchical -regexp [format {.*GTYE4_COMMON_PRIM_INST/DRPDO\[%d\]$} $bit]]
  set net [get_nets -quiet -of_objects $source]
  puts "BIT=$bit SOURCE=[get_property NAME $source] NET=[get_property NAME $net]"
  set sinks [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == IN}]
  foreach sink $sinks {
    puts "  NET_SINK=[get_property NAME $sink] CELL=[get_property NAME [get_cells -of_objects $sink]] TYPE=[get_property REF_NAME [get_cells -of_objects $sink]]"
  }
  set cells [get_cells -quiet -hierarchical -regexp {.*u_ila_0.*}]
  foreach cell $cells {
    set pins [get_pins -quiet -of_objects $cell -filter {DIRECTION == IN}]
    foreach pin $pins {
      set pin_name [get_property NAME $pin]
      if {[string match *probe9* $pin_name] || [string match *D $pin_name]} {
        puts "  ILA_PIN=$pin_name CELL=[get_property REF_NAME $cell] NETS=[get_property NAME [get_nets -quiet -of_objects $pin]]"
      }
    }
  }
  if {$bit == 0} {
    set c [get_clocks -quiet init_clk]
    if {[catch {set_false_path -through $net} err]} {
      puts "THROUGH_NET_FAIL=$err"
    } else {
      puts "THROUGH_NET_OK"
    }
  }
}
current_instance
close_design
exit
