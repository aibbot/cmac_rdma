# Usage from the repository root:
#   vivado.bat -mode batch -source rdma/scripts/build_rdma_bitstream.tcl -tclargs setup|synth|impl
# `setup` creates only the isolated sources/run topology and generated IP.

set rdma_vivado_version [version -short]
if {![regexp {^(2024|2025)\.2(\.[0-9]+)?$} $rdma_vivado_version -> rdma_flow_year]} {
  error "RDMA build supports Vivado 2024.2 or 2025.2; running $rdma_vivado_version"
}
set rdma_legacy_ip_format [expr {$rdma_flow_year eq "2024"}]

set stage setup
if {[llength $argv] > 0} {
  set stage [lindex $argv 0]
}
if {$stage ni {setup synth impl}} {
  error "stage must be setup, synth, or impl"
}

set rdma_build_epoch [clock seconds]
set rdma_build_tag_hex [format %08X [expr {$rdma_build_epoch & 0xFFFFFFFF}]]
if {[info exists ::env(RDMA_BUILD_TAG)]} {
  set requested_build_tag [string toupper [string trim $::env(RDMA_BUILD_TAG)]]
  regsub {^0X} $requested_build_tag {} requested_build_tag
  if {![regexp {^[0-9A-F]{8}$} $requested_build_tag]} {
    error "RDMA_BUILD_TAG must be exactly eight hexadecimal digits"
  }
  set rdma_build_tag_hex $requested_build_tag
}

proc rdma_sha256 {artifact_path} {
  if {![file exists $artifact_path] || [file isdirectory $artifact_path]} {
    error "Cannot hash missing or non-file artifact: $artifact_path"
  }
  if {[catch {exec certutil -hashfile [file nativename $artifact_path] SHA256} hash_output]} {
    error "certutil failed while hashing $artifact_path: $hash_output"
  }
  foreach hash_line [split $hash_output "\n"] {
    set hash_candidate [string tolower [string trim \
      [string map [list " " "" "\r" "" "\t" ""] $hash_line]]]
    if {[regexp {^[0-9a-f]{64}$} $hash_candidate]} {
      return $hash_candidate
    }
  }
  error "certutil did not return a SHA-256 digest for $artifact_path"
}

proc rdma_check_build_tag_probe {} {
  set probe_pins [get_pins -quiet -hierarchical -regexp \
    {.*i_rdma_vio/probe_in29\[[0-9]+\]$}]
  if {[llength $probe_pins] != 32} {
    error "Expected 32 rdma_vio build-tag pins, found [llength $probe_pins]"
  }
  set probe_nets [list]
  foreach probe_pin $probe_pins {
    set pin_nets [get_nets -quiet -of_objects $probe_pin]
    if {[llength $pin_nets] != 1} {
      error "Expected one net on $probe_pin, found [llength $pin_nets]"
    }
    set net_name [get_property NAME $pin_nets]
    if {[string first "/build_tag_probe" $net_name] < 0} {
      error "rdma_vio build-tag pin is not driven by build_tag_probe: $probe_pin -> $net_name"
    }
    lappend probe_nets $net_name
  }
  set probe_nets [lsort -unique $probe_nets]
  if {[llength $probe_nets] != 32} {
    error "Expected 32 distinct build_tag_probe nets, found [llength $probe_nets]"
  }
  return [llength $probe_nets]
}

set rdma_build_jobs 8
set rdma_synth_worker_threads 1
if {[info exists ::env(RDMA_BUILD_JOBS)]} {
  set requested_build_jobs [string trim $::env(RDMA_BUILD_JOBS)]
  if {![string is integer -strict $requested_build_jobs] ||
      $requested_build_jobs != 8} {
    error "RDMA_BUILD_JOBS is fixed at 8"
  }
  set rdma_build_jobs $requested_build_jobs
}

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir .. ..]]
set rdma_build_dir [file join $project_dir rdma build]
if {$rdma_legacy_ip_format} {
  set rdma_build_dir [file join $rdma_build_dir 2024.2]
}
set rdma_project_dir [file join $rdma_build_dir vivado_rdma]
set project_file [file join $rdma_project_dir rdma.xpr]
set rtl_dir [file join $project_dir rdma rtl]
set imports_dir [file join $project_dir imports]
set rdma_timing_report [file join $rdma_build_dir rdma_timing_summary.rpt]
set rdma_check_timing_report [file join $rdma_build_dir rdma_check_timing.rpt]
set rdma_bus_skew_report [file join $rdma_build_dir rdma_bus_skew.rpt]
set rdma_drc_report [file join $rdma_build_dir rdma_drc.rpt]
set rdma_route_status_report [file join $rdma_build_dir rdma_route_status.rpt]
set rdma_utilization_report [file join $rdma_build_dir rdma_utilization.rpt]
set rdma_cdc_report [file join $rdma_build_dir rdma_cdc.rpt]
set rdma_cdc_waiver_report [file join $rdma_build_dir rdma_cdc_waivers.rpt]
set rdma_cdc_waiver_xdc [file join $rdma_build_dir rdma_legacy_debug_cdc_waivers.xdc]
set rdma_high_fanout_report [file join $rdma_build_dir rdma_high_fanout.rpt]
set rdma_control_sets_report [file join $rdma_build_dir rdma_control_sets.rpt]
set rdma_logic_levels_report [file join $rdma_build_dir rdma_logic_levels.rpt]
set rdma_methodology_report [file join $rdma_build_dir rdma_methodology.rpt]
set rdma_published_bit [file join $rdma_build_dir rdma_top.bit]
set rdma_published_ltx [file join $rdma_build_dir rdma_top.ltx]
set rdma_published_manifest \
  [file join $rdma_build_dir rdma_top.manifest.txt]

proc rdma_create_2024_vendor_ip {xci_file source_set} {
  package require json
  set input [open $xci_file r]
  try {
    set source_ip [::json::json2dict [read $input]]
  } finally {
    close $input
  }

  set ip_name [file rootname [file tail $xci_file]]
  if {[dict get $source_ip ip_inst xci_name] ne $ip_name} {
    error "XCI instance name does not match its file name: $xci_file"
  }
  set ip_vlnv [split [dict get $source_ip ip_inst component_reference] :]
  if {[llength $ip_vlnv] != 4} {
    error "Invalid IP catalog reference in $xci_file"
  }
  lassign $ip_vlnv vendor library ip_type ip_version
  set ip_dir [file join [get_property DIRECTORY [current_project]] rdma.srcs sources_rdma ip]
  file mkdir $ip_dir
  create_ip -name $ip_type -vendor $vendor -library $library \
    -version $ip_version -module_name $ip_name \
    -dir $ip_dir
  set ip [get_ips $ip_name]

  set explicit_config [list]
  dict for {name attributes} [dict get $source_ip ip_inst parameters component_parameters] {
    set attribute [lindex $attributes 0]
    if {[dict exists $attribute value_src] &&
        [dict get $attribute value_src] eq "user"} {
      lappend explicit_config "CONFIG.$name" [dict get $attribute value]
    }
  }
  set_property -dict $explicit_config $ip
  foreach {property expected} $explicit_config {
    if {[get_property $property $ip] ne $expected} {
      error "2024.2 IP configuration differs: $ip_name $property"
    }
  }

  set ip_file [get_property IP_FILE $ip]
  move_files -fileset $source_set [get_files $ip_file]
  puts "RDMA_2024_IP ip=$ip_name source=$xci_file"
}

file mkdir $rdma_build_dir
if {[file tail $rdma_project_dir] ne "vivado_rdma" ||
    [file dirname $rdma_project_dir] ne $rdma_build_dir} {
  error "Refusing to clean unexpected RDMA project directory: $rdma_project_dir"
}
if {[file exists $rdma_project_dir]} {
  file delete -force $rdma_project_dir
}
create_project rdma $rdma_project_dir -part xczu47dr-fsvg1517-1-i
set_param general.maxThreads $rdma_build_jobs
if {[get_param general.maxThreads] != $rdma_build_jobs} {
  error "general.maxThreads was not set to $rdma_build_jobs"
}
# Vivado uses synth.maxThreads to choose how many task_worker Vivado
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
  if {[file tail $source_file] ni {cmac_usplus_0_exdes_tb.v cmac_usplus_0_core_support.v}} {
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
    if {$rdma_legacy_ip_format} {
      rdma_create_2024_vendor_ip $source_file $source_set
    } else {
      import_files -norecurse -fileset $source_set $source_file
    }
  }
}
set rdma_cmac_ip [get_ips -quiet cmac_usplus_0]
if {[llength $rdma_cmac_ip] != 1} {
  error "Expected exactly one imported CMAC IP, found [llength $rdma_cmac_ip]"
}
set_property CONFIG.RX_FLOW_CONTROL {1} $rdma_cmac_ip
set_property CONFIG.TX_FLOW_CONTROL {0} $rdma_cmac_ip
if {[get_property CONFIG.RX_FLOW_CONTROL $rdma_cmac_ip] ne "1" ||
    [get_property CONFIG.TX_FLOW_CONTROL $rdma_cmac_ip] ne "0"} {
  error "RDMA CMAC flow-control configuration was not applied"
}
if {$rdma_legacy_ip_format} {
  # init_clk also drives GT logic. The 2024.2 clock wizard must not insert
  # an IBUF on this shared top-level input.
  set legacy_clock_ip [get_ips clk_wiz_0]
  set_property CONFIG.PRIM_SOURCE No_buffer $legacy_clock_ip
  if {[get_property CONFIG.PRIM_SOURCE $legacy_clock_ip] ne "No_buffer"} {
    error "Vivado 2024.2 clock wizard input buffer was not disabled"
  }
}
reset_target all $rdma_cmac_ip
generate_target all $rdma_cmac_ip
if {$rdma_legacy_ip_format} {
  foreach ip_name {cmac_usplus_0_gt clk_wiz_0 vio_0} {
    generate_target all [get_ips $ip_name]
  }
}
puts "RDMA_CMAC_FLOW_CONTROL rx=[get_property CONFIG.RX_FLOW_CONTROL $rdma_cmac_ip] tx=[get_property CONFIG.TX_FLOW_CONTROL $rdma_cmac_ip]"
foreach source_file [list \
  [file join $rtl_dir rdma_reset_sync.sv] \
  [file join $rtl_dir rdma_gray_counter_cdc.sv] \
  [file join $rtl_dir rdma_endpoint_pkg.sv] \
  [file join $rtl_dir rdma_config_manager.sv] \
  [file join $rtl_dir rdma_ack_receiver.sv] \
  [file join $rtl_dir rdma_crc32_parallel.sv] \
  [file join $rtl_dir rdma_external_packet_builder.sv] \
  [file join $rtl_dir rdma_replay_buffer.sv] \
  [file join $rtl_dir rdma_sequence_recovery.sv] \
  [file join $rtl_dir rdma_packet_layout.sv] \
  [file join $rtl_dir rdma_payload_buffer.sv] \
  [file join $rtl_dir rdma_endpoint.sv] \
  [file join $rtl_dir rdma_transport_core.sv] \
  [file join $rtl_dir rdma_transport_ip.sv] \
  [file join $rtl_dir rdma_rx_admission.sv] \
  [file join $rtl_dir rdma_rx_classifier.sv] \
  [file join $rtl_dir rdcp_pkg.sv] \
  [file join $rtl_dir rdcp_rx_validate.sv] \
  [file join $rtl_dir rdcp_request_parser.sv] \
  [file join $rtl_dir rdcp_session_engine.sv] \
  [file join $rtl_dir rdcp_response_encoder.sv] \
  [file join $rtl_dir rdcp_control.sv] \
  [file join $rtl_dir rdma_tx_frame_arbiter.sv] \
  [file join $rtl_dir rdma_network_core.sv] \
  [file join $rtl_dir rdma_tx_packet_arbiter.sv] \
  [file join $rtl_dir rdma_pause_control.sv] \
  [file join $rtl_dir rdma_pause_diagnostics.sv] \
  [file join $rtl_dir rdma_core_support.sv] \
  [file join $rtl_dir rdma_axis_register.sv] \
  [file join $rtl_dir rdma_tx_drain_tracker.sv] \
  [file join $rtl_dir rdma_board_endpoint.sv] \
  [file join $rtl_dir rdma_top.sv]] {
  if {![file exists $source_file]} {
    error "RDMA RTL source is missing: $source_file"
  }
  if {![llength [get_files -quiet $source_file]]} {
    add_files -norecurse -fileset $source_set $source_file
  }
  set_property file_type SystemVerilog [get_files $source_file]
}
set_property top rdma_top $source_set
set_property verilog_define \
  [list CMAC_RDMA_BUILD "RDMA_BUILD_TAG=32'h${rdma_build_tag_hex}"] $source_set

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
set project_xdc [file join $rtl_dir rdma_project.xdc]
if {![file exists $project_xdc]} {
  error "RDMA project constraint file is missing: $project_xdc"
}
if {![llength [get_files -quiet $project_xdc]]} {
  add_files -norecurse -fileset $constraint_set $project_xdc
}

if {![llength [get_runs -quiet rdma_synth_1]]} {
  create_run rdma_synth_1 -flow "Vivado Synthesis $rdma_flow_year" -strategy Flow_PerfOptimized_high \
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
set rdma_ip_names [list clk_wiz_rdma_250 axis_data_fifo_rdma_rx axis_data_fifo_rdma_tx rdma_vio ila_rdma cmac_flow_control_vio]
foreach ip $rdma_ip_names {
  rdma_prepare_ip_for_generation $ip
}
configure_rdma_ips $project_dir
foreach ip $rdma_ip_names {
  rdma_ensure_ip_root_in_source_set $source_set $ip
}
if {$rdma_legacy_ip_format} {
  foreach ip {cmac_usplus_0 cmac_usplus_0_gt clk_wiz_0 vio_0} {
    rdma_ensure_ip_root_in_source_set $source_set $ip
  }
}
update_compile_order -fileset sources_rdma

if {![llength [get_runs -quiet rdma_impl_1]]} {
  create_run rdma_impl_1 -parent_run rdma_synth_1 -flow "Vivado Implementation $rdma_flow_year" \
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

puts "RDMA_SETUP project=$project_file part=[get_property PART [current_project]] build_tag=0x$rdma_build_tag_hex maxThreads=[get_param general.maxThreads] synthThreads=[get_param synth.maxThreads] runJobs=$rdma_build_jobs debugJobs=[get_param chipscope.maxJobs] impl_strategy=[get_property STRATEGY $rdma_impl_run] route_directive=[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $rdma_impl_run]"
puts "RDMA_SETUP source_files=[llength [get_files -of_objects $source_set]] in_context_ips=$rdma_ip_names"

if {$stage eq "setup"} {
  close_project
  exit
}

# Each generated IP is configured for in-context synthesis from sources_rdma.
reset_run rdma_synth_1
launch_runs rdma_synth_1 -jobs $rdma_build_jobs
wait_on_run rdma_synth_1
if {[get_property STATUS [get_runs rdma_synth_1]] ne "synth_design Complete!"} {
  error "RDMA synthesis failed: [get_property STATUS [get_runs rdma_synth_1]]"
}

# XDC accepts only constraint commands, so validate its deliberately narrow
# CDC selections against the completed synthesized netlist here.
open_run rdma_synth_1
set rdma_cdc_first_stage_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_rdma_board_endpoint/(i_tx_drain_tracker/pipeline_busy_sync1_reg|i_tx_packet_arbiter/rdma_abort_sync1_reg)/D}]
if {[llength $rdma_cdc_first_stage_pins] != 2} {
  error "Expected 2 false-path RDMA CDC first-stage data pins, found [llength $rdma_cdc_first_stage_pins]"
}
set rdma_gray_source_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_rdma_board_endpoint/i_rx_overflow_counter_cdc/src_gray_reg\[[0-9]+\]}]
if {[llength $rdma_gray_source_cells] != 32} {
  error "Expected 32 RDMA Gray-counter source cells, found [llength $rdma_gray_source_cells]"
}
set rdma_gray_first_stage_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_rdma_board_endpoint/i_rx_overflow_counter_cdc/dst_gray_sync1_reg\[[0-9]+\]/D}]
if {[llength $rdma_gray_first_stage_pins] != 32} {
  error "Expected 32 RDMA Gray-counter first-stage pins, found [llength $rdma_gray_first_stage_pins]"
}
set rdma_reset_async_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_rdma_board_endpoint/i_(cmac_reset|lock_reset|lock_reset_cmac)_sync/g_active_(high|low)\.reset_pipeline_reg\[[0-9]+\]/(PRE|CLR)}]
if {[llength $rdma_reset_async_pins] != 12} {
  error "Expected 12 RDMA reset-synchronizer asynchronous pins, found [llength $rdma_reset_async_pins]"
}
set rdma_cdc_sync_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_rdma_board_endpoint/(i_tx_drain_tracker/pipeline_busy_sync[12]_reg|i_tx_packet_arbiter/rdma_abort_sync[12]_reg|i_rx_overflow_counter_cdc/dst_gray_sync[12]_reg\[[0-9]+\]|i_(cmac_reset|lock_reset|lock_reset_cmac)_sync/g_active_(high|low)\.reset_pipeline_reg\[[0-9]+\])}]
if {[llength $rdma_cdc_sync_cells] != 80} {
  error "Expected 80 RDMA synchronizer cells, found [llength $rdma_cdc_sync_cells]"
}
foreach rdma_cdc_sync_cell $rdma_cdc_sync_cells {
  set rdma_async_reg [get_property ASYNC_REG $rdma_cdc_sync_cell]
  if {$rdma_async_reg ni {1 TRUE true}} {
    error "RDMA synchronizer cell is missing ASYNC_REG: $rdma_cdc_sync_cell"
  }
}
puts "RDMA_CDC_CHECK false_path_first_stage_pins=[llength $rdma_cdc_first_stage_pins] gray_source_cells=[llength $rdma_gray_source_cells] gray_first_stage_pins=[llength $rdma_gray_first_stage_pins] reset_async_pins=[llength $rdma_reset_async_pins] async_reg_cells=[llength $rdma_cdc_sync_cells]"
puts "RDMA_BUILD_TAG_PROBE stage=synth named_nets=[rdma_check_build_tag_probe]"
if {$stage eq "synth"} {
  close_design
  close_project
  exit
}

foreach stale_output [list \
  $rdma_timing_report $rdma_check_timing_report $rdma_bus_skew_report \
  $rdma_drc_report $rdma_route_status_report $rdma_utilization_report \
  $rdma_cdc_report $rdma_cdc_waiver_report $rdma_cdc_waiver_xdc \
  $rdma_high_fanout_report \
  $rdma_control_sets_report $rdma_logic_levels_report $rdma_methodology_report \
  $rdma_published_bit $rdma_published_ltx $rdma_published_manifest] {
  if {[file exists $stale_output]} {
    file delete -force $stale_output
  }
}

set rdma_impl_directory [get_property DIRECTORY $rdma_impl_run]
file mkdir $rdma_impl_directory
set rdma_routed_checkpoint [file join $rdma_impl_directory rdma_top_routed.dcp]
if {[file exists $rdma_routed_checkpoint]} {
  file delete -force $rdma_routed_checkpoint
}

# Run the generated implementation strategy directly to keep this build's
# helper-process fan-out and memory demand bounded.
puts "RDMA_DIRECT_IMPL opt=ExploreWithRemap place=Explore phys_opt=Explore route=Explore"
source $legacy_debug_hook
opt_design -directive ExploreWithRemap
if {[llength [info commands rdma_apply_legacy_debug_cdc_waivers]] != 1} {
  error "Legacy debug hook did not define rdma_apply_legacy_debug_cdc_waivers"
}
set rdma_legacy_cdc_waiver_count \
  [rdma_apply_legacy_debug_cdc_waivers $rdma_cdc_waiver_xdc]
if {$rdma_legacy_cdc_waiver_count != 17} {
  error "Expected 17 post-opt legacy CDC waivers, found $rdma_legacy_cdc_waiver_count"
}
if {![file exists $rdma_cdc_waiver_xdc] ||
    [file size $rdma_cdc_waiver_xdc] == 0} {
  error "Vivado did not persist the legacy CDC waivers: $rdma_cdc_waiver_xdc"
}
set rdma_optimized_checkpoint [file join $rdma_impl_directory rdma_top_opt.dcp]
write_checkpoint -force $rdma_optimized_checkpoint
set rdma_debug_core_count [llength [get_debug_cores -quiet]]
set rdma_blackbox_count [llength [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]]
puts "RDMA_OPT_CHECK debug_cores=$rdma_debug_core_count blackboxes=$rdma_blackbox_count"
if {$rdma_debug_core_count != 9 || $rdma_blackbox_count != 0} {
  error "RDMA opt_design did not fully implement the expected debug cores: debug_cores=$rdma_debug_core_count blackboxes=$rdma_blackbox_count"
}
set_param project.isImplRun true
place_design -directive Explore
set_param project.isImplRun false
set rdma_placed_checkpoint [file join $rdma_impl_directory rdma_top_placed.dcp]
write_checkpoint -force $rdma_placed_checkpoint
phys_opt_design -directive Explore
set rdma_physopt_checkpoint [file join $rdma_impl_directory rdma_top_physopt.dcp]
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
set rdma_embedded_legacy_cdc_waivers [get_waivers -quiet -filter \
  {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
puts "RDMA_CDC_WAIVER_CHECKPOINT waivers=[llength $rdma_embedded_legacy_cdc_waivers]"
if {[llength $rdma_embedded_legacy_cdc_waivers] != 17} {
  error "RDMA routed checkpoint did not retain exactly 17 legacy CDC waivers"
}
delete_waivers $rdma_embedded_legacy_cdc_waivers
set rdma_remaining_legacy_cdc_waivers [get_waivers -quiet -filter \
  {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
if {[llength $rdma_remaining_legacy_cdc_waivers] != 0} {
  error "RDMA routed checkpoint retained legacy CDC waivers after deletion"
}
read_xdc $rdma_cdc_waiver_xdc
set rdma_reloaded_legacy_cdc_waivers [get_waivers -quiet -filter \
  {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
puts "RDMA_CDC_WAIVER_RELOAD waivers=[llength $rdma_reloaded_legacy_cdc_waivers]"
if {[llength $rdma_reloaded_legacy_cdc_waivers] != 17} {
  error "RDMA routed checkpoint did not reload exactly 17 legacy CDC waivers"
}
puts "RDMA_BUILD_TAG_PROBE stage=route named_nets=[rdma_check_build_tag_probe]"
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
report_cdc -details -show_waiver -file $rdma_cdc_report
report_waivers -type CDC -file $rdma_cdc_waiver_report
report_high_fanout_nets -timing -load_types -max_nets 100 \
  -file $rdma_high_fanout_report
report_control_sets -hierarchical -file $rdma_control_sets_report
report_design_analysis -logic_level_distribution -logic_level_dist_paths 1000 \
  -file $rdma_logic_levels_report
report_methodology -file $rdma_methodology_report
puts "RDMA_RESOURCE_REPORT path=$rdma_utilization_report"

set rdma_legacy_cdc_waivers [get_waivers -quiet -filter \
  {TYPE == CDC && ID == CDC-1 && TAGS =~ *rdma_legacy_drp_debug*}]
report_cdc -severity Critical -no_header -return_string
set rdma_unwaived_critical_cdc [get_cdc_violations -quiet -filter \
  {SEVERITY == Critical}]
puts "RDMA_CDC_SIGNOFF critical_unwaived=[llength $rdma_unwaived_critical_cdc] legacy_waivers=[llength $rdma_legacy_cdc_waivers]"
if {[llength $rdma_legacy_cdc_waivers] != 17} {
  error "RDMA CDC signoff did not retain exactly 17 legacy waivers"
}
if {[llength $rdma_unwaived_critical_cdc] != 0} {
  error "RDMA CDC signoff found unwaived Critical paths; see $rdma_cdc_report"
}

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
set rdma_staged_bit [file join $rdma_staging_dir rdma_top.bit]
set rdma_staged_ltx [file join $rdma_staging_dir rdma_top.ltx]
write_bitstream -force $rdma_staged_bit
write_debug_probes -force $rdma_staged_ltx
foreach staged_output [list $rdma_staged_bit $rdma_staged_ltx] {
  if {![file exists $staged_output] || [file size $staged_output] == 0} {
    error "RDMA staged artifact is missing or empty: $staged_output"
  }
}
set rdma_ltx_channel [open $rdma_staged_ltx r]
set rdma_ltx_text [read $rdma_ltx_channel]
close $rdma_ltx_channel
if {[string first {/<const} $rdma_ltx_text] >= 0 ||
    [string first {/build_tag_probe} $rdma_ltx_text] < 0} {
  error "RDMA LTX contains anonymous constants or lacks the named build_tag_probe bus"
}
puts "RDMA_BUILD_TAG_PROBE stage=ltx anonymous_constants=0 named_bus=1"
file copy -force $rdma_staged_bit $rdma_published_bit
file copy -force $rdma_staged_ltx $rdma_published_ltx
puts "RDMA_ARTIFACTS bit=$rdma_published_bit bit_bytes=[file size $rdma_published_bit] ltx=$rdma_published_ltx ltx_bytes=[file size $rdma_published_ltx]"

set rdma_manifest_sources [list \
  [file normalize [info script]] \
  [file join $script_dir configure_rdma_ips.tcl] \
  [file join $script_dir apply_legacy_debug.tcl] \
  $project_xdc]
foreach rdma_source_object [get_files -quiet -of_objects $source_set] {
  set rdma_source_path [file normalize $rdma_source_object]
  if {[file exists $rdma_source_path] && ![file isdirectory $rdma_source_path]} {
    lappend rdma_manifest_sources $rdma_source_path
  }
}
set rdma_manifest_sources [lsort -unique $rdma_manifest_sources]

set rdma_git_head unavailable
set rdma_git_dirty unavailable
if {![catch {exec git -C $project_dir rev-parse HEAD} rdma_git_head_result]} {
  set rdma_git_head [string trim $rdma_git_head_result]
  if {![catch {exec git -C $project_dir status --porcelain} rdma_git_status]} {
    set rdma_git_dirty [expr {[string trim $rdma_git_status] eq "" ? 0 : 1}]
  }
}

set rdma_manifest_channel [open $rdma_published_manifest w]
puts $rdma_manifest_channel "format=cmac-usplus-rdma-build-manifest-v1"
puts $rdma_manifest_channel "build_utc=[clock format $rdma_build_epoch -gmt true -format {%Y-%m-%dT%H:%M:%SZ}]"
puts $rdma_manifest_channel "build_tag=0x$rdma_build_tag_hex"
puts $rdma_manifest_channel "vivado_version=[version -short]"
puts $rdma_manifest_channel "git_head=$rdma_git_head"
puts $rdma_manifest_channel "git_dirty=$rdma_git_dirty"
puts $rdma_manifest_channel "bit.bytes=[file size $rdma_published_bit]"
puts $rdma_manifest_channel "bit.sha256=[rdma_sha256 $rdma_published_bit]"
puts $rdma_manifest_channel "ltx.bytes=[file size $rdma_published_ltx]"
puts $rdma_manifest_channel "ltx.sha256=[rdma_sha256 $rdma_published_ltx]"
foreach {rdma_report_name rdma_report_path} [list \
  timing $rdma_timing_report \
  check_timing $rdma_check_timing_report \
  bus_skew $rdma_bus_skew_report \
  drc $rdma_drc_report \
  route_status $rdma_route_status_report \
  utilization $rdma_utilization_report \
  cdc $rdma_cdc_report \
  cdc_waivers $rdma_cdc_waiver_report \
  high_fanout $rdma_high_fanout_report \
  control_sets $rdma_control_sets_report \
  logic_levels $rdma_logic_levels_report \
  methodology $rdma_methodology_report] {
  puts $rdma_manifest_channel \
    "report.$rdma_report_name.sha256=[rdma_sha256 $rdma_report_path]"
}
puts $rdma_manifest_channel \
  "waiver.cdc_xdc.sha256=[rdma_sha256 $rdma_cdc_waiver_xdc]"
puts $rdma_manifest_channel "source.count=[llength $rdma_manifest_sources]"
foreach rdma_source_path $rdma_manifest_sources {
  puts $rdma_manifest_channel \
    "source.sha256=[rdma_sha256 $rdma_source_path] path=$rdma_source_path"
}
close $rdma_manifest_channel
puts "RDMA_MANIFEST path=$rdma_published_manifest sources=[llength $rdma_manifest_sources] build_tag=0x$rdma_build_tag_hex"
close_project
