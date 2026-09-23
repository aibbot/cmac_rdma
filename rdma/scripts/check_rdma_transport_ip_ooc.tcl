# Out-of-context implementation check for the portable RDMA transport IP.
# Usage: vivado.bat -mode batch -source check_rdma_transport_ip_ooc.tcl

set vivado_version [version -short]
if {![string match "2025.2*" $vivado_version]} {
  error "Vivado 2025.2 is required; found $vivado_version"
}

set build_jobs 8
set clock_period_ns 4.000
set clock_source_site BUFGCE_X0Y168
# Match the board endpoint's deployed transport configuration.  The default
# value is still covered by RTL simulation and the packaged-IP consumer check;
# this implementation gate must retain the production streaming datapath.
set fast_benchmark_mode 1
set script_dir [file dirname [file normalize [info script]]]
set rdma_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $rdma_dir rtl]
set source_manifest [file join $script_dir rdma_transport_ip_sources.tcl]
set build_dir [file join $rdma_dir build transport_ip_ooc]
set project_dir [file join $build_dir project]
set report_dir [file join $build_dir reports]

if {![file exists $source_manifest]} {
  error "RDMA transport IP source manifest is missing: $source_manifest"
}
source $source_manifest

if {[file tail $build_dir] ne "transport_ip_ooc" ||
    [file dirname [file dirname $build_dir]] ne $rdma_dir} {
  error "Refusing to clean unexpected OOC build directory: $build_dir"
}
if {[file exists $build_dir]} {
  file delete -force $build_dir
}
file mkdir $report_dir

# Vivado writes clockInfo.txt and other implementation diagnostics to the
# process working directory. Keep those generated files with the disposable
# OOC build instead of overwriting tracked board-level reports at repository
# root.
cd $build_dir

set_param general.maxThreads $build_jobs
if {[get_param general.maxThreads] != $build_jobs} {
  error "general.maxThreads was not set to $build_jobs"
}

create_project rdma_transport_ip_ooc $project_dir \
  -part xczu47dr-fsvg1517-1-i -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set source_files [rdma_transport_ip_source_files $rtl_dir]

foreach source_file $source_files {
  if {![file exists $source_file]} {
    error "RDMA transport IP source is missing: $source_file"
  }
  read_verilog -sv $source_file
}

synth_design -top cmac_usplus_0_rdma_transport_ip \
  -part xczu47dr-fsvg1517-1-i -mode out_of_context \
  -generic FAST_BENCHMARK_MODE=$fast_benchmark_mode

create_clock -name aclk -period $clock_period_ns [get_ports aclk]
set_property HD.CLK_SRC $clock_source_site [get_ports aclk]
if {[get_property HD.CLK_SRC [get_ports aclk]] ne $clock_source_site} {
  error "Failed to set the OOC clock source to $clock_source_site"
}
set_false_path -from [get_ports aresetn]
set synchronous_inputs [get_ports -quiet -filter \
  {DIRECTION == IN && NAME != "aclk" && NAME != "aresetn"}]
if {[llength $synchronous_inputs]} {
  set_false_path -from $synchronous_inputs
}
set synchronous_outputs [get_ports -quiet -filter {DIRECTION == OUT}]
if {[llength $synchronous_outputs]} {
  set_false_path -to $synchronous_outputs
}
puts "RDMA_TRANSPORT_IP_OOC_INTERFACE clock_source=$clock_source_site \
boundary_paths=integration_signoff fast_benchmark_mode=$fast_benchmark_mode"

opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore -tns_cleanup
write_checkpoint -force [file join $build_dir rdma_transport_ip_ooc_routed.dcp]

report_timing_summary -delay_type min_max -check_timing_verbose \
  -file [file join $report_dir timing_summary.rpt]
set check_timing_text [check_timing -verbose \
  -override_defaults {no_clock unconstrained_internal_endpoints} -return_string]
set check_timing_channel [open [file join $report_dir check_timing.rpt] w]
puts -nonewline $check_timing_channel $check_timing_text
close $check_timing_channel
report_drc -file [file join $report_dir drc.rpt]
set route_status_text [report_route_status -return_string]
set route_status_channel [open [file join $report_dir route_status.rpt] w]
puts -nonewline $route_status_channel $route_status_text
close $route_status_channel
report_utilization -hierarchical -file [file join $report_dir utilization.rpt]
report_high_fanout_nets -timing -load_types -max_nets 100 \
  -file [file join $report_dir high_fanout.rpt]
report_control_sets -verbose -file [file join $report_dir control_sets.rpt]
report_design_analysis -logic_level_distribution \
  -file [file join $report_dir logic_levels.rpt]
report_methodology -file [file join $report_dir methodology.rpt]

set worst_setup_path [get_timing_paths -quiet -delay_type max \
  -max_paths 1 -sort_by slack]
set worst_hold_path [get_timing_paths -quiet -delay_type min \
  -max_paths 1 -sort_by slack]
if {![llength $worst_setup_path] || ![llength $worst_hold_path]} {
  error "OOC timing did not return both setup and hold paths"
}
set wns [get_property SLACK $worst_setup_path]
set whs [get_property SLACK $worst_hold_path]
puts "RDMA_TRANSPORT_IP_OOC_TIMING WNS=$wns WHS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
  error "OOC timing failed: WNS=$wns WHS=$whs"
}

if {![regexp {checking no_clock \(([0-9]+)\)} \
      $check_timing_text -> no_clock_count] ||
    ![regexp {checking unconstrained_internal_endpoints \(([0-9]+)\)} \
      $check_timing_text -> unconstrained_endpoint_count]} {
  error "OOC check_timing report did not contain the required checks"
}
puts "RDMA_TRANSPORT_IP_OOC_CONSTRAINTS no_clock=$no_clock_count \
unconstrained_internal_endpoints=$unconstrained_endpoint_count"
if {$no_clock_count != 0 || $unconstrained_endpoint_count != 0} {
  error "OOC constraints failed: no_clock=$no_clock_count \
unconstrained_internal_endpoints=$unconstrained_endpoint_count"
}

# An OOC reusable IP deliberately has no package-pin I/O assignments. These
# are the only implementation DRCs waived here; every internal blocker fails.
set ooc_drc_waivers {NSTD-1 UCIO-1 RTSTAT-1}
set drc_blockers [list]
foreach violation [get_drc_violations -quiet] {
  set severity [get_property SEVERITY $violation]
  set check_name [get_property ID $violation]
  if {($severity eq "Error" || $severity eq "Critical Warning") &&
      $check_name ni $ooc_drc_waivers} {
    lappend drc_blockers $violation
  }
}
puts "RDMA_TRANSPORT_IP_OOC_DRC blockers=[llength $drc_blockers] waivers=$ooc_drc_waivers"
if {[llength $drc_blockers]} {
  error "OOC DRC found blocking violations: $drc_blockers"
}

if {![regexp {# of routable nets[^:]*:[ ]*([0-9]+)[ ]*:} \
      $route_status_text -> routable_net_count] ||
    ![regexp {# of nets with explicit gaps[^:]*:[ ]*([0-9]+)[ ]*:} \
      $route_status_text -> explicit_gap_count] ||
    ![regexp {# of fully routed nets[^:]*:[ ]*([0-9]+)[ ]*:} \
      $route_status_text -> routed_net_count] ||
    ![regexp {# of nets with routing errors[^:]*:[ ]*([0-9]+)[ ]*:} \
      $route_status_text -> route_error_count]} {
  error "OOC route report did not contain the required counters"
}
puts "RDMA_TRANSPORT_IP_OOC_ROUTE routable=$routable_net_count \
routed=$routed_net_count explicit_gaps=$explicit_gap_count \
errors=$route_error_count"
# HD.CLK_SRC deliberately terminates the pinless OOC clock at the modeled
# BUFG site, so Vivado reports one boundary gap even though every routable net
# is fully routed. Prove that every partial route object is an aclk hierarchy
# alias connected to the top-level aclk port; a count-only waiver could hide an
# unrelated single routing gap.
set allowed_ooc_boundary_gaps 1
set aclk_port [get_ports -quiet aclk]
set aclk_net [get_nets -quiet aclk]
set partial_route_nets [lsort [get_nets -hier -filter \
  {ROUTE_STATUS == PARTIAL}]]
set unexpected_partial_nets [list]
foreach partial_net $partial_route_nets {
  set partial_name [get_property NAME $partial_net]
  set partial_type [get_property TYPE $partial_net]
  set partial_ports [get_ports -quiet -of_objects $partial_net]
  if {$partial_type ne "LOCAL_CLOCK" ||
      ($partial_name ne "aclk" && ![string match "*/aclk" $partial_name]) ||
      [llength $partial_ports] != 1 ||
      [get_property NAME $partial_ports] ne "aclk"} {
    lappend unexpected_partial_nets $partial_name
  }
}
set actual_clock_source_site [get_property HD.CLK_SRC $aclk_port]
puts "RDMA_TRANSPORT_IP_OOC_GAP_OWNER port=aclk \
clock_source=$actual_clock_source_site partial_nets=$partial_route_nets"
if {$routable_net_count != $routed_net_count ||
    $explicit_gap_count != $allowed_ooc_boundary_gaps ||
    [llength $aclk_port] != 1 ||
    [llength $aclk_net] != 1 ||
    [llength $partial_route_nets] == 0 ||
    [llength $unexpected_partial_nets] != 0 ||
    $actual_clock_source_site ne $clock_source_site ||
    $route_error_count != 0} {
  error "OOC design is not fully routed: routable=$routable_net_count \
routed=$routed_net_count explicit_gaps=$explicit_gap_count \
errors=$route_error_count clock_source=$actual_clock_source_site \
partial_nets=$partial_route_nets unexpected_partial_nets=$unexpected_partial_nets"
}

set pass_file [file join $report_dir ooc_pass.txt]
set pass_channel [open $pass_file w]
puts $pass_channel "status=PASS"
puts $pass_channel "vivado_version=$vivado_version"
puts $pass_channel "clock_period_ns=$clock_period_ns"
puts $pass_channel "fast_benchmark_mode=$fast_benchmark_mode"
puts $pass_channel "wns_ns=$wns"
puts $pass_channel "whs_ns=$whs"
puts $pass_channel "no_clock=$no_clock_count"
puts $pass_channel \
  "unconstrained_internal_endpoints=$unconstrained_endpoint_count"
puts $pass_channel "routable_nets=$routable_net_count"
puts $pass_channel "fully_routed_nets=$routed_net_count"
puts $pass_channel "explicit_gaps=$explicit_gap_count"
puts $pass_channel "allowed_ooc_boundary_gaps=$allowed_ooc_boundary_gaps"
puts $pass_channel "gap_owner=aclk"
puts $pass_channel "clock_source_site=$actual_clock_source_site"
puts $pass_channel "partial_route_nets=[join $partial_route_nets ,]"
puts $pass_channel "routing_errors=$route_error_count"
puts $pass_channel "drc_blockers=[llength $drc_blockers]"
close $pass_channel
puts "RDMA_TRANSPORT_IP_OOC_PASS reports=$report_dir proof=$pass_file"
close_project
