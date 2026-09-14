# Read-only timing/DRC report for an RDMA checkpoint.
set_param general.maxThreads 8
if {[get_param general.maxThreads] != 8} {
  error "RDMA checkpoint reports must use 8 threads"
}
set rdma_report_script_dir [file dirname [file normalize [info script]]]
set rdma_report_project_dir [file normalize [file join $rdma_report_script_dir .. ..]]
if {[llength $argv] < 1} {
  error "checkpoint path is required"
}
set rdma_report_checkpoint [file normalize [lindex $argv 0]]
if {![file exists $rdma_report_checkpoint]} {
  error "checkpoint is missing: $rdma_report_checkpoint"
}
set rdma_report_prefix [file rootname $rdma_report_checkpoint]
open_checkpoint $rdma_report_checkpoint
report_timing_summary -delay_type min_max -check_timing_verbose \
  -file "${rdma_report_prefix}_timing_summary.rpt"
report_timing -delay_type max -max_paths 20 -sort_by slack -path_type full \
  -file "${rdma_report_prefix}_timing_paths.rpt"
report_timing -delay_type min -max_paths 20 -sort_by slack -path_type full \
  -file "${rdma_report_prefix}_hold_paths.rpt"
report_cdc -details -file "${rdma_report_prefix}_cdc.rpt"
report_drc -file "${rdma_report_prefix}_drc.rpt"
report_route_status -file "${rdma_report_prefix}_route_status.rpt"
report_utilization -hierarchical -file "${rdma_report_prefix}_utilization.rpt"
close_design
exit
