# Read-only helper for diagnosing Vivado run configuration.
set rdma_inspect_script_dir [file dirname [file normalize [info script]]]
set rdma_inspect_project_dir [file normalize [file join $rdma_inspect_script_dir .. ..]]
set rdma_inspect_xpr [file join $rdma_inspect_project_dir rdma build vivado_rdma rdma.xpr]

open_project $rdma_inspect_xpr
set rdma_inspect_run [get_runs rdma_synth_1]
foreach rdma_inspect_property [lsort [list_property $rdma_inspect_run]] {
  if {[string match *INCREMENTAL* $rdma_inspect_property]} {
    puts "RDMA_RUN_PROPERTY $rdma_inspect_property=[get_property $rdma_inspect_property $rdma_inspect_run]"
  }
}
close_project
