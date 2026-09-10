set rtl_dir $::env(RDMA_OOC_RTL_DIR)
set xdc_file $::env(RDMA_OOC_XDC_FILE)
set project_dir $::env(RDMA_OOC_PROJECT_DIR)
set report_dir $::env(RDMA_OOC_REPORT_DIR)
set resume_run $::env(RDMA_OOC_RESUME)

set part_name xczu47dr-fsvg1517-1-i
set parallel_jobs 24
# Vivado 2025.2 task_worker crashes while parallelizing this generated HLS
# netlist. Keep the requested run-level fanout, but serialize synthesis inside
# the run until AMD fixes the worker access violation.
set synth_worker_threads 1

set_param general.maxThreads $parallel_jobs
set configured_parallel_jobs [get_param general.maxThreads]
if {$configured_parallel_jobs < $parallel_jobs} {
    error "Vivado did not accept $parallel_jobs compile threads"
}
set_param synth.maxThreads $synth_worker_threads
set configured_synth_worker_threads [get_param synth.maxThreads]
if {$configured_synth_worker_threads != $synth_worker_threads} {
    error "Vivado did not accept $synth_worker_threads synthesis worker thread"
}
file mkdir $report_dir

if {$resume_run eq "1"} {
    set project_file [file join $project_dir rocev2_ooc.xpr]
    if {![file exists $project_file]} {
        error "Cannot resume; OOC project is missing: $project_file"
    }
    open_project $project_file
    set impl_run [get_runs impl_1]
} else {
    create_project -force rocev2_ooc $project_dir -part $part_name
    set_property target_language Verilog [current_project]

    set rtl_files [glob -nocomplain -directory $rtl_dir *.v]
    if {[llength $rtl_files] == 0} {
        error "No exported HLS Verilog files found in $rtl_dir"
    }
    add_files -norecurse $rtl_files
    add_files -fileset constrs_1 -norecurse $xdc_file
    set_property top rocev2_top [get_filesets sources_1]

    set synth_run [get_runs synth_1]
    set_property strategy Flow_PerfOptimized_high $synth_run
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects $synth_run

    launch_runs $synth_run -jobs $parallel_jobs
    wait_on_run $synth_run
    set synth_checkpoint [file join [get_property DIRECTORY $synth_run] rocev2_top.dcp]
    if {![file exists $synth_checkpoint]} {
        error "OOC synthesis did not complete: [get_property STATUS $synth_run]"
    }

    set impl_run [get_runs impl_1]
    set_property strategy Performance_ExplorePostRoutePhysOpt $impl_run
    launch_runs $impl_run -to_step route_design -jobs $parallel_jobs
    wait_on_run $impl_run
}

set routed_checkpoint [file join [get_property DIRECTORY $impl_run] rocev2_top_routed.dcp]
if {![file exists $routed_checkpoint]} {
    error "OOC route_design did not complete: [get_property STATUS $impl_run]"
}

open_checkpoint $routed_checkpoint
report_timing_summary -delay_type min_max -check_timing_verbose -max_paths 20 -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization_hierarchical.rpt]
report_drc -file [file join $report_dir drc.rpt]
set route_status [report_route_status -return_string]
set route_report [open [file join $report_dir route_status.rpt] w]
puts $route_report $route_status
close $route_report
write_checkpoint -force [file join $report_dir rocev2_ooc_routed.dcp]

set drc_error_count [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
if {![regexp -nocase {# of routable nets\.*\s*:\s*([0-9]+)} $route_status -> routable_net_count]} {
    error "Could not read the routable-net count from report_route_status"
}
if {![regexp -nocase {# of fully routed nets\.*\s*:\s*([0-9]+)} $route_status -> fully_routed_net_count]} {
    error "Could not read the fully-routed-net count from report_route_status"
}
if {![regexp -nocase {# of nets with routing errors\.*\s*:\s*([0-9]+)} $route_status -> routing_error_count]} {
    error "Could not read the routing-error count from report_route_status"
}

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    error "OOC implementation produced no setup or hold timing paths"
}

set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set result_file [open [file join $report_dir result.txt] w]
puts $result_file "part=$part_name"
puts $result_file "clock_period_ns=4.000"
puts $result_file "general_max_threads=$configured_parallel_jobs"
puts $result_file "run_jobs=$parallel_jobs"
puts $result_file "synth_worker_threads=$configured_synth_worker_threads"
puts $result_file "wns_ns=$wns"
puts $result_file "whs_ns=$whs"
puts $result_file "drc_errors=$drc_error_count"
puts $result_file "routable_nets=$routable_net_count"
puts $result_file "fully_routed_nets=$fully_routed_net_count"
puts $result_file "routing_errors=$routing_error_count"
puts $result_file "clock_source_location=unspecified"
close $result_file

puts "RoCEv2 OOC result: WNS=$wns ns, WHS=$whs ns, DRC errors=$drc_error_count, routing errors=$routing_error_count"
if {$wns < 0.0 || $whs < 0.0 || $drc_error_count != 0 ||
    $routing_error_count != 0 || $fully_routed_net_count != $routable_net_count} {
    puts stderr "ERROR: RoCEv2 HLS IP does not meet the OOC timing/DRC/routing gate"
    exit 2
}

exit 0
