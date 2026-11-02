set project [file normalize [file join [file dirname [file normalize [info script]]] .. build vivado_rdma rdma.xpr]]
open_project $project
open_run rdma_synth_1
current_instance u_cmac_usplus_0_exdes
set xdc [file normalize [file join [file dirname [file normalize [info script]]] .. .. imports cmac_usplus_0_ila_debug.xdc]]
set f [open $xdc r]
set s [read $f]
close $f
set s [string map [list {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out} {txusrclk2}] $s]
eval $s
set c [get_clocks -quiet init_clk]
puts "CLOCKS=[llength $c]"
set source [get_pins -quiet -hierarchical -regexp {.*GTYE4_COMMON_PRIM_INST/DRPDO\[0\]$}]
set net [get_nets -quiet -of_objects $source]
if {[catch {set_false_path -from $c -through $net} err]} {
  puts "THROUGH_NET_FAIL=$err"
  exit 1
}
puts "THROUGH_NET_OK"
current_instance
close_design
close_project
exit
