# Usage from the repository root:
#   vivado.bat -mode batch -source rdma/scripts/build_rdma_bitstream.tcl -tclargs setup|synth|impl
# `setup` creates only the isolated sources/run topology and generated IP.

set stage setup
if {[llength $argv] > 0} {
  set stage [lindex $argv 0]
}
if {$stage ni {setup synth impl}} {
  error "stage must be setup, synth, or impl"
}

set rdma_build_jobs 8
set rdma_synth_worker_threads 1
if {[info exists ::env(RDMA_BUILD_JOBS)]} {
  set requested_build_jobs [string trim $::env(RDMA_BUILD_JOBS)]
  if {![string is integer -strict $requested_build_jobs] ||
      $requested_build_jobs != 8} {
    error "RDMA_BUILD_JOBS is fixed at 8; the separate Vivado process guard enforces the limit of 3"
  }
  set rdma_build_jobs $requested_build_jobs
}

# One launched synthesis run can create a run controller and a worker beside
# this batch process. Implementation stays in this process because dynamic
# debug-core synthesis can itself create two helper Vivado processes.
proc rdma_require_exclusive_vivado {phase} {
  if {$::tcl_platform(platform) ne "windows"} {
    puts "RDMA_VIVADO_PROCESS_GUARD phase=$phase platform=$::tcl_platform(platform) skipped=1"
    return
  }

  set count_script {(Get-Process -Name vivado -ErrorAction SilentlyContinue | Measure-Object).Count}
  if {[catch {
    exec powershell.exe -NoProfile -NonInteractive -Command $count_script
  } process_count]} {
    error "Could not count Windows Vivado processes before $phase: $process_count"
  }
  set process_count [string trim $process_count]
  if {![string is integer -strict $process_count] || $process_count < 1} {
    error "Invalid Windows Vivado process count before $phase: {$process_count}"
  }
  puts "RDMA_VIVADO_PROCESS_GUARD phase=$phase count=$process_count limit=3"
  if {$process_count != 1} {
    error "RDMA build requires exclusive Vivado use before $phase; found $process_count vivado.exe processes"
  }
}

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set rdma_build_dir [file join $project_dir rdma build]
set rdma_project_dir [file join $rdma_build_dir vivado_rdma]
set project_file [file join $rdma_project_dir cmac_usplus_0_rdma.xpr]
set rtl_dir [file join $project_dir rdma rtl]
set imports_dir [file join $project_dir imports]
set rdma_timing_report [file join $rdma_build_dir rdma_timing_summary.rpt]
set rdma_check_timing_report [file join $rdma_build_dir rdma_check_timing.rpt]
set rdma_bus_skew_report [file join $rdma_build_dir rdma_bus_skew.rpt]
set rdma_drc_report [file join $rdma_build_dir rdma_drc.rpt]
set rdma_route_status_report [file join $rdma_build_dir rdma_route_status.rpt]
set rdma_utilization_report [file join $rdma_build_dir rdma_utilization.rpt]
set rdma_published_bit [file join $rdma_build_dir cmac_usplus_0_rdma_top.bit]
set rdma_published_ltx [file join $rdma_build_dir cmac_usplus_0_rdma_top.ltx]

rdma_require_exclusive_vivado setup
file mkdir $rdma_build_dir
if {[file tail $rdma_project_dir] ne "vivado_rdma" ||
    [file dirname $rdma_project_dir] ne $rdma_build_dir} {
  error "Refusing to clean unexpected RDMA project directory: $rdma_project_dir"
}
if {[file exists $rdma_project_dir]} {
  file delete -force $rdma_project_dir
}
create_project cmac_usplus_0_rdma $rdma_project_dir -part xczu47dr-fsvg1517-1-i
set_param general.maxThreads $rdma_build_jobs
if {[get_param general.maxThreads] != $rdma_build_jobs} {
  error "general.maxThreads was not set to $rdma_build_jobs"
}
# Vivado 2025.2 uses synth.maxThreads to choose how many task_worker Vivado
# processes synthesis launches. One worker keeps the complete process tree at
# the user-requested limit of three while every process retains eight threads.
set_param synth.maxThreads $rdma_synth_worker_threads
if {[get_param synth.maxThreads] != $rdma_synth_worker_threads} {
  error "synth.maxThreads was not set to $rdma_synth_worker_threads"
}
# Dynamic debug-core synthesis launches one Vivado process per ILA/VIO.  Keep
# those processes serial so their combined virtual-memory demand cannot corrupt
# generated run files on Windows; each individual run still uses maxThreads.
set_param chipscope.maxJobs 1
if {[get_param chipscope.maxJobs] != 1} {
  error "chipscope.maxJobs was not set to 1"
}

if {![llength [get_filesets -quiet sources_rdma]]} {
  create_fileset -srcset sources_rdma
}
set source_set [get_filesets sources_rdma]

# Import the vendor example sources into a separate Vivado project. Xilinx IP
# objects are project-owned, so source-set cloning inside the original project
# would reject the same CMAC .xci names. The original UDP project is therefore
# neither rebuilt nor modified by this flow.
set imported_rtl [list]
foreach source_file [concat \
  [glob -nocomplain [file join $imports_dir *.v]] \
  [glob -nocomplain [file join $imports_dir *.sv]]] {
  if {[file tail $source_file] ne "cmac_usplus_0_exdes_tb.v"} {
    lappend imported_rtl $source_file
  }
}
if {[llength $imported_rtl]} {
  add_files -norecurse -fileset $source_set $imported_rtl
}
foreach source_file [list \
  [file join $project_dir cmac_usplus_0_ex.srcs sources_1 ip cmac_usplus_0 cmac_usplus_0.xci] \
  [file join $project_dir cmac_usplus_0_ex.srcs sources_1 ip cmac_usplus_0_gt cmac_usplus_0_gt.xci] \
  [file join $project_dir cmac_usplus_0_ex.srcs sources_1 ip clk_wiz_0 clk_wiz_0.xci] \
  [file join $project_dir cmac_usplus_0_ex.srcs sources_1 ip vio_0 vio_0.xci]] {
  if {![file exists $source_file]} {
    error "Vendor IP source is missing: $source_file"
  }
  set ip_name [file rootname [file tail $source_file]]
  if {![llength [get_ips -quiet $ip_name]]} {
    import_files -norecurse -fileset $source_set $source_file
  }
}
foreach source_file [list \
  [file join $rtl_dir cmac_usplus_0_rdma_reset_sync.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_gray_counter_cdc.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_crc32_parallel.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_endpoint.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_rx_admission.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_tx_packet_arbiter.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_arp_snapshot_cdc.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_board_endpoint.sv] \
  [file join $rtl_dir cmac_usplus_0_rdma_top.sv]] {
  if {![file exists $source_file]} {
    error "RDMA RTL source is missing: $source_file"
  }
  if {![llength [get_files -quiet $source_file]]} {
    add_files -norecurse -fileset $source_set $source_file
  }
  set_property file_type SystemVerilog [get_files $source_file]
}
set_property top cmac_usplus_0_rdma_top $source_set
set_property verilog_define {CMAC_RDMA_BUILD} $source_set

# create_ip initially places each generated .xci in a BlockSrcs fileset.  The
# RDMA synthesis run instead uses sources_rdma, so use in-context IP synthesis
# and make each generated IP root an explicit member of that source set.
proc rdma_prepare_ip_for_generation {ip_name} {
  set ip [get_ips -quiet $ip_name]
  if {![llength $ip]} {
    return
  }
  if {[llength $ip] != 1} {
    error "Expected exactly one RDMA IP named $ip_name, found [llength $ip]"
  }

  set ip_file [get_property IP_FILE $ip]
  set ip_file_object [get_files -quiet $ip_file]
  if {[llength $ip_file_object] != 1} {
    error "Expected exactly one project file for RDMA IP: ip=$ip_name path=$ip_file count=[llength $ip_file_object]"
  }
  if {[get_property GENERATE_SYNTH_CHECKPOINT $ip_file_object] ne "1"} {
    set_property GENERATE_SYNTH_CHECKPOINT 1 $ip_file_object
  }
}

proc rdma_ensure_ip_root_in_source_set {source_set ip_name} {
  set ip [get_ips -quiet $ip_name]
  if {[llength $ip] != 1} {
    error "Expected exactly one RDMA IP named $ip_name, found [llength $ip]"
  }

  set ip_file [get_property IP_FILE $ip]
  if {$ip_file eq "" || ![file exists $ip_file]} {
    error "RDMA IP root file is missing: ip=$ip_name path=$ip_file"
  }

  set ip_file_object [get_files -quiet $ip_file]
  if {[llength $ip_file_object] != 1} {
    error "Expected exactly one project file for RDMA IP: ip=$ip_name path=$ip_file count=[llength $ip_file_object]"
  }
  if {[get_property GENERATE_SYNTH_CHECKPOINT $ip_file_object] ne "0"} {
    set_property GENERATE_SYNTH_CHECKPOINT 0 $ip_file_object
  }

  set ip_in_source_set [get_files -quiet -of_objects $source_set $ip_file]
  if {![llength $ip_in_source_set]} {
    set ip_file_object [get_files -quiet $ip_file]
    if {[llength $ip_file_object] != 1} {
      error "Expected exactly one project file for RDMA IP: ip=$ip_name path=$ip_file count=[llength $ip_file_object]"
    }
    move_files -fileset $source_set $ip_file_object
    set ip_in_source_set [get_files -quiet -of_objects $source_set $ip_file]
  }
  if {[llength $ip_in_source_set] != 1} {
    error "RDMA IP root file membership is invalid: ip=$ip_name path=$ip_file count=[llength $ip_in_source_set]"
  }

  if {[llength $ip_in_source_set] != 1 ||
      [get_property GENERATE_SYNTH_CHECKPOINT $ip_in_source_set] ne "0"} {
    error "RDMA IP root was not configured for in-context synthesis: ip=$ip_name path=$ip_file"
  }

  set ip_run [get_runs -quiet "${ip_name}_synth_1"]
  if {[llength $ip_run]} {
    error "RDMA IP OOC run remains after in-context configuration: ip=$ip_name run=$ip_run"
  }

  puts "RDMA_IP_FILESET ip=$ip_name in_sources_rdma=[llength $ip_in_source_set] generate_synth_checkpoint=0 ooc_runs=0"
}

if {![llength [get_filesets -quiet constrs_rdma]]} {
  create_fileset -constrset constrs_rdma
}
set constraint_set [get_filesets constrs_rdma]
set vendor_project_xdc [file join $project_dir imports cmac_usplus_0_project.xdc]
set obsolete_rdma_debug_xdc [file join $rtl_dir rdma_debug.xdc]
# These files were used by an earlier RDMA flow. The vendor project XDC does
# not include the RDMA wrapper hierarchy, and the debug source uses Tcl that
# XDC parsing deliberately rejects. Remove only their RDMA constraint-set
# membership; the original UDP project retains both vendor files untouched.
foreach obsolete_constraint [list $vendor_project_xdc $obsolete_rdma_debug_xdc] {
  set obsolete_file [get_files -quiet $obsolete_constraint]
  if {[llength $obsolete_file]} {
    remove_files -fileset $constraint_set $obsolete_file
  }
}
set project_xdc [file join $rtl_dir cmac_usplus_0_project_rdma.xdc]
if {![file exists $project_xdc]} {
  error "RDMA project constraint file is missing: $project_xdc"
}
if {![llength [get_files -quiet $project_xdc]]} {
  add_files -norecurse -fileset $constraint_set $project_xdc
}

if {![llength [get_runs -quiet rdma_synth_1]]} {
  create_run rdma_synth_1 -flow {Vivado Synthesis 2025} -strategy Flow_PerfOptimized_high \
    -constrset constrs_rdma
}
set_property SRCSET sources_rdma [get_runs rdma_synth_1]
set_property CONSTRSET constrs_rdma [get_runs rdma_synth_1]
# The RDMA source and constraint sets are intentionally independent of the
# legacy UDP run. Do not reuse a prior incremental DCP after RTL, generated-IP,
# or placement-constraint changes; board bring-up needs a fresh netlist.
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs rdma_synth_1]
set_property INCREMENTAL_CHECKPOINT "" [get_runs rdma_synth_1]
if {[get_property AUTO_INCREMENTAL_CHECKPOINT [get_runs rdma_synth_1]] != 0 ||
    [get_property INCREMENTAL_CHECKPOINT [get_runs rdma_synth_1]] ne ""} {
  error "RDMA synthesis must not use an incremental checkpoint"
}
current_run -synthesis [get_runs rdma_synth_1]
if {[current_fileset -srcset] ne "sources_rdma"} {
  error "RDMA synthesis run did not select sources_rdma"
}

source [file join $script_dir configure_rdma_ips.tcl]
set rdma_ip_names [list clk_wiz_rdma_250 axis_data_fifo_rdma_rx axis_data_fifo_rdma_tx rdma_vio ila_rdma]
foreach ip $rdma_ip_names {
  rdma_prepare_ip_for_generation $ip
}
configure_rdma_ips $project_dir
foreach ip $rdma_ip_names {
  rdma_ensure_ip_root_in_source_set $source_set $ip
}
update_compile_order -fileset sources_rdma

if {![llength [get_runs -quiet rdma_impl_1]]} {
  create_run rdma_impl_1 -parent_run rdma_synth_1 -flow {Vivado Implementation 2025} \
    -strategy Performance_ExploreWithRemap -constrset constrs_rdma
}
set rdma_impl_run [get_runs rdma_impl_1]
set_property CONSTRSET constrs_rdma $rdma_impl_run
# Re-assert the intended base strategy because Vivado persists run property
# changes when a project is closed, including changes made by diagnostics.
set_property strategy Performance_ExploreWithRemap $rdma_impl_run
if {[get_property STRATEGY $rdma_impl_run] ne "Performance_ExploreWithRemap"} {
  error "RDMA implementation strategy was not restored to Performance_ExploreWithRemap"
}
# The default Performance_ExploreWithRemap strategy uses NoTimingRelaxation
# for routing. On this full-CMAC design that directive exhausted host memory
# with tens of thousands of nets still unrouted. Explore stays within the
# available memory while enabling the clock-skew optimization needed to close
# the 322.266 MHz CMAC transmit domain.
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $rdma_impl_run
if {[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $rdma_impl_run] ne "Explore"} {
  error "RDMA implementation route directive was not set to Explore"
}
set legacy_debug_hook [file join $script_dir apply_legacy_debug.tcl]
if {![file exists $legacy_debug_hook]} {
  error "RDMA legacy-debug hook is missing: $legacy_debug_hook"
}
if {![llength [get_files -quiet $legacy_debug_hook]]} {
  add_files -norecurse -fileset utils_1 $legacy_debug_hook
}
set_property STEPS.OPT_DESIGN.TCL.PRE $legacy_debug_hook $rdma_impl_run

puts "RDMA_SETUP project=$project_file part=[get_property PART [current_project]] maxThreads=[get_param general.maxThreads] synthThreads=[get_param synth.maxThreads] runJobs=$rdma_build_jobs debugJobs=[get_param chipscope.maxJobs] impl_strategy=[get_property STRATEGY $rdma_impl_run] route_directive=[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $rdma_impl_run]"
puts "RDMA_SETUP source_files=[llength [get_files -of_objects $source_set]] in_context_ips=$rdma_ip_names"

if {$stage eq "setup"} {
  close_project
  exit
}

# Each generated IP is configured for in-context synthesis from sources_rdma.
reset_run rdma_synth_1
rdma_require_exclusive_vivado synthesis
launch_runs rdma_synth_1 -jobs $rdma_build_jobs
wait_on_run rdma_synth_1
if {[get_property STATUS [get_runs rdma_synth_1]] ne "synth_design Complete!"} {
  error "RDMA synthesis failed: [get_property STATUS [get_runs rdma_synth_1]]"
}

# XDC accepts only constraint commands, so validate its deliberately narrow
# CDC selections against the completed synthesized netlist here.
open_run rdma_synth_1
set rdma_cdc_first_stage_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/(local_ip_sync1_reg\[[0-9]+\]|i_tx_packet_arbiter/rdma_abort_sync1_reg|i_arp_snapshot_cdc/(src_ack_sync1_reg|src_dst_reset_sync1_reg|dst_request_sync1_reg|dst_mac_sync1_reg\[[0-9]+\]|dst_ip_sync1_reg\[[0-9]+\]))/D}]
if {[llength $rdma_cdc_first_stage_pins] != 116} {
  error "Expected 116 false-path RDMA CDC first-stage data pins, found [llength $rdma_cdc_first_stage_pins]"
}
set rdma_gray_source_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_rx_overflow_counter_cdc/src_gray_reg\[[0-9]+\]}]
if {[llength $rdma_gray_source_cells] != 32} {
  error "Expected 32 RDMA Gray-counter source cells, found [llength $rdma_gray_source_cells]"
}
set rdma_gray_first_stage_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_rx_overflow_counter_cdc/dst_gray_sync1_reg\[[0-9]+\]/D}]
if {[llength $rdma_gray_first_stage_pins] != 32} {
  error "Expected 32 RDMA Gray-counter first-stage pins, found [llength $rdma_gray_first_stage_pins]"
}
set rdma_reset_async_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_(cmac_reset|lock_reset|lock_reset_cmac)_sync/g_active_(high|low)\.reset_pipeline_reg\[[0-9]+\]/(PRE|CLR)}]
if {[llength $rdma_reset_async_pins] != 12} {
  error "Expected 12 RDMA reset-synchronizer asynchronous pins, found [llength $rdma_reset_async_pins]"
}
set rdma_cdc_sync_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/(local_ip_(sync1|rdma)_reg\[[0-9]+\]|i_tx_packet_arbiter/rdma_abort_sync[12]_reg|i_rx_overflow_counter_cdc/dst_gray_sync[12]_reg\[[0-9]+\]|i_arp_snapshot_cdc/(src_ack_sync[12]_reg|src_dst_reset_sync[12]_reg|dst_request_sync[12]_reg|dst_mac_sync[12]_reg\[[0-9]+\]|dst_ip_sync[12]_reg\[[0-9]+\])|i_(cmac_reset|lock_reset|lock_reset_cmac)_sync/g_active_(high|low)\.reset_pipeline_reg\[[0-9]+\])}]
if {[llength $rdma_cdc_sync_cells] != 308} {
  error "Expected 308 RDMA synchronizer cells, found [llength $rdma_cdc_sync_cells]"
}
foreach rdma_cdc_sync_cell $rdma_cdc_sync_cells {
  set rdma_async_reg [get_property ASYNC_REG $rdma_cdc_sync_cell]
  if {$rdma_async_reg ni {1 TRUE true}} {
    error "RDMA synchronizer cell is missing ASYNC_REG: $rdma_cdc_sync_cell"
  }
}
puts "RDMA_CDC_CHECK false_path_first_stage_pins=[llength $rdma_cdc_first_stage_pins] gray_source_cells=[llength $rdma_gray_source_cells] gray_first_stage_pins=[llength $rdma_gray_first_stage_pins] reset_async_pins=[llength $rdma_reset_async_pins] async_reg_cells=[llength $rdma_cdc_sync_cells]"
if {$stage eq "synth"} {
  close_design
  close_project
  exit
}

foreach stale_output [list \
  $rdma_timing_report $rdma_check_timing_report $rdma_bus_skew_report \
  $rdma_drc_report $rdma_route_status_report $rdma_utilization_report \
  $rdma_published_bit $rdma_published_ltx] {
  if {[file exists $stale_output]} {
    file delete -force $stale_output
  }
}

set rdma_impl_directory [get_property DIRECTORY $rdma_impl_run]
file mkdir $rdma_impl_directory
set rdma_routed_checkpoint [file join $rdma_impl_directory cmac_usplus_0_rdma_top_routed.dcp]
if {[file exists $rdma_routed_checkpoint]} {
  file delete -force $rdma_routed_checkpoint
}

# launch_runs would keep this controller alive beside an implementation
# process. Dynamic debug synthesis then adds two more Vivado processes. Run the
# generated strategy commands directly so the Windows process total stays <= 3.
rdma_require_exclusive_vivado implementation
puts "RDMA_DIRECT_IMPL opt=ExploreWithRemap place=Explore phys_opt=Explore route=Explore"
source $legacy_debug_hook
opt_design -directive ExploreWithRemap
set rdma_optimized_checkpoint [file join $rdma_impl_directory cmac_usplus_0_rdma_top_opt.dcp]
write_checkpoint -force $rdma_optimized_checkpoint
set rdma_debug_core_count [llength [get_debug_cores -quiet]]
set rdma_blackbox_count [llength [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]]
puts "RDMA_OPT_CHECK debug_cores=$rdma_debug_core_count blackboxes=$rdma_blackbox_count"
if {$rdma_debug_core_count != 8 || $rdma_blackbox_count != 0} {
  error "RDMA opt_design did not fully implement the expected debug cores: debug_cores=$rdma_debug_core_count blackboxes=$rdma_blackbox_count"
}
set_param project.isImplRun true
place_design -directive Explore
set_param project.isImplRun false
set rdma_placed_checkpoint [file join $rdma_impl_directory cmac_usplus_0_rdma_top_placed.dcp]
write_checkpoint -force $rdma_placed_checkpoint
phys_opt_design -directive Explore
set rdma_physopt_checkpoint [file join $rdma_impl_directory cmac_usplus_0_rdma_top_physopt.dcp]
write_checkpoint -force $rdma_physopt_checkpoint
set_msg_config -source 4 -id {Route 35-39} -severity "critical warning" -new_severity warning
route_design -directive Explore -tns_cleanup
write_checkpoint -force $rdma_routed_checkpoint

set rdma_routed_checkpoint_ready 0
if {[file exists $rdma_routed_checkpoint] &&
    [file size $rdma_routed_checkpoint] > 0} {
  set rdma_routed_checkpoint_ready 1
}
puts "RDMA_ROUTE_STAGE mode=direct debug_cores=$rdma_debug_core_count blackboxes=$rdma_blackbox_count routed_checkpoint=$rdma_routed_checkpoint_ready"
if {!$rdma_routed_checkpoint_ready} {
  error "RDMA direct route_design did not produce a routed checkpoint: $rdma_routed_checkpoint"
}

close_design
open_checkpoint $rdma_routed_checkpoint
report_timing_summary -delay_type min_max -check_timing_verbose \
  -file $rdma_timing_report
set rdma_check_timing_text [check_timing -verbose \
  -override_defaults {no_clock unconstrained_internal_endpoints} -return_string]
set rdma_check_timing_channel [open $rdma_check_timing_report w]
puts -nonewline $rdma_check_timing_channel $rdma_check_timing_text
close $rdma_check_timing_channel
report_bus_skew -warn_on_violation -file $rdma_bus_skew_report
report_drc -file $rdma_drc_report
report_route_status -file $rdma_route_status_report
report_utilization -hierarchical -file $rdma_utilization_report

set rdma_worst_setup_path [get_timing_paths -quiet -delay_type max -max_paths 1 -sort_by slack]
set rdma_worst_hold_path [get_timing_paths -quiet -delay_type min -max_paths 1 -sort_by slack]
if {![llength $rdma_worst_setup_path] || ![llength $rdma_worst_hold_path]} {
  error "RDMA timing signoff did not return both setup and hold paths"
}
set rdma_wns [get_property SLACK $rdma_worst_setup_path]
set rdma_whs [get_property SLACK $rdma_worst_hold_path]
puts "RDMA_TIMING_CHECK WNS=$rdma_wns WHS=$rdma_whs"
if {$rdma_wns < 0.0 || $rdma_whs < 0.0} {
  error "RDMA timing signoff failed: WNS=$rdma_wns WHS=$rdma_whs"
}

if {![regexp {checking no_clock \(([0-9]+)\)} \
      $rdma_check_timing_text -> rdma_no_clock_count] ||
    ![regexp {checking unconstrained_internal_endpoints \(([0-9]+)\)} \
      $rdma_check_timing_text -> rdma_unconstrained_endpoint_count]} {
  error "RDMA check_timing report did not contain the required checks"
}
puts "RDMA_CHECK_TIMING no_clock=$rdma_no_clock_count unconstrained_internal_endpoints=$rdma_unconstrained_endpoint_count"
if {$rdma_no_clock_count != 0 || $rdma_unconstrained_endpoint_count != 0} {
  error "RDMA check_timing signoff failed: no_clock=$rdma_no_clock_count unconstrained_internal_endpoints=$rdma_unconstrained_endpoint_count"
}

set rdma_bus_skew_channel [open $rdma_bus_skew_report r]
set rdma_bus_skew_text [read $rdma_bus_skew_channel]
close $rdma_bus_skew_channel
if {![regexp {Slack \(MET\)} $rdma_bus_skew_text]} {
  error "RDMA bus-skew signoff did not report any checked paths"
}
if {[regexp {Slack \(VIOLATED\)} $rdma_bus_skew_text]} {
  error "RDMA bus-skew signoff failed; see $rdma_bus_skew_report"
}

set rdma_drc_blockers [list]
foreach rdma_drc_violation [get_drc_violations -quiet] {
  set rdma_drc_severity [get_property SEVERITY $rdma_drc_violation]
  if {$rdma_drc_severity eq "Error" || $rdma_drc_severity eq "Critical Warning"} {
    lappend rdma_drc_blockers $rdma_drc_violation
  }
}
puts "RDMA_DRC_CHECK blockers=[llength $rdma_drc_blockers]"
if {[llength $rdma_drc_blockers]} {
  error "RDMA DRC signoff found blocking violations: $rdma_drc_blockers"
}

set rdma_route_status_channel [open $rdma_route_status_report r]
set rdma_route_status_text [read $rdma_route_status_channel]
close $rdma_route_status_channel
if {![regexp {# of routable nets[^:]*:\s*([0-9]+)\s*:} \
      $rdma_route_status_text -> rdma_routable_nets] ||
    ![regexp {# of fully routed nets[^:]*:\s*([0-9]+)\s*:} \
      $rdma_route_status_text -> rdma_fully_routed_nets] ||
    ![regexp {# of nets with routing errors[^:]*:\s*([0-9]+)\s*:} \
      $rdma_route_status_text -> rdma_route_errors]} {
  error "RDMA route-status report did not contain the required counters"
}
puts "RDMA_ROUTE_CHECK routable=$rdma_routable_nets fully_routed=$rdma_fully_routed_nets errors=$rdma_route_errors"
if {$rdma_route_errors != 0 || $rdma_fully_routed_nets != $rdma_routable_nets} {
  error "RDMA route signoff failed: routable=$rdma_routable_nets fully_routed=$rdma_fully_routed_nets errors=$rdma_route_errors"
}

# Generate into the disposable project first. Only publish a complete pair
# after every route-level acceptance gate has passed.
set rdma_staging_dir [file join $rdma_project_dir artifacts_staging]
file mkdir $rdma_staging_dir
set rdma_staged_bit [file join $rdma_staging_dir cmac_usplus_0_rdma_top.bit]
set rdma_staged_ltx [file join $rdma_staging_dir cmac_usplus_0_rdma_top.ltx]
write_bitstream -force $rdma_staged_bit
write_debug_probes -force $rdma_staged_ltx
foreach staged_output [list $rdma_staged_bit $rdma_staged_ltx] {
  if {![file exists $staged_output] || [file size $staged_output] == 0} {
    error "RDMA staged artifact is missing or empty: $staged_output"
  }
}
file copy -force $rdma_staged_bit $rdma_published_bit
file copy -force $rdma_staged_ltx $rdma_published_ltx
puts "RDMA_ARTIFACTS bit=$rdma_published_bit bit_bytes=[file size $rdma_published_bit] ltx=$rdma_published_ltx ltx_bytes=[file size $rdma_published_ltx]"
close_project
