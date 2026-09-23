set dcp [file normalize [file join [file dirname [file normalize [info script]]] .. build vivado_rdma cmac_usplus_0_rdma.runs rdma_impl_1 cmac_usplus_0_rdma_top_routed.dcp]]
open_checkpoint $dcp
current_instance u_cmac_usplus_0_exdes
set nets [list]
set drivers [list]
set sinks [list]
for {set bit 0} {$bit < 16} {incr bit} {
  set source [get_pins -quiet -hierarchical -regexp [format {.*GTYE4_COMMON_PRIM_INST/DRPDO\[%d\]$} $bit]]
  if {[llength $source] != 1} { error "source bit=$bit count=[llength $source]" }
  set net [get_nets -quiet -of_objects $source]
  if {[llength $net] != 1} { error "net bit=$bit count=[llength $net]" }
  set driver [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
  set sink [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == IN}]
  if {[llength $driver] != 1 || [llength $sink] != 1} { error "pins bit=$bit drivers=[llength $driver] sinks=[llength $sink]" }
  if {![regexp {(^|/)u_ila(_[0-9]+|_status_[0-9]+)?/(.*\/D|probe[0-9]+\[[0-9]+\])$} [get_property NAME [lindex $sink 0]]]} { error "sink bit=$bit name=[get_property NAME [lindex $sink 0]]" }
  lappend nets $net
  lappend drivers [lindex $driver 0]
  lappend sinks [lindex $sink 0]
}
set source [get_pins -quiet -hierarchical -regexp {.*GTYE4_COMMON_PRIM_INST/DRPRDY$}]
if {[llength $source] != 1} { error "rdy source count=[llength $source]" }
set net [get_nets -quiet -of_objects $source]
if {[llength $net] != 1} { error "rdy net count=[llength $net]" }
set driver [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
set sink [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == IN}]
if {[llength $driver] != 1 || [llength $sink] != 1} { error "rdy pins drivers=[llength $driver] sinks=[llength $sink]" }
if {![regexp {(^|/)u_ila(_[0-9]+|_status_[0-9]+)?/(.*\/D|probe[0-9]+\[[0-9]+\])$} [get_property NAME [lindex $sink 0]]]} { error "rdy sink name=[get_property NAME [lindex $sink 0]]" }
lappend nets $net
lappend drivers [lindex $driver 0]
lappend sinks [lindex $sink 0]
if {[llength $nets] != 17 || [llength $drivers] != 17 || [llength $sinks] != 17} { error "counts nets=[llength $nets] drivers=[llength $drivers] sinks=[llength $sinks]" }
puts "RDMA_LEGACY_DEBUG_SELECTION_CHECK nets=[llength $nets] drivers=[llength $drivers] ila_sinks=[llength $sinks]"
current_instance
close_design
exit
