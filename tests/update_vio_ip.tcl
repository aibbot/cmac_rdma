if {[version -short] ne "2025.2"} {
    error "Vivado 2025.2 is required; running [version -short]"
}

set project_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_dir cmac_usplus_0_ex.xpr]
set vivado_parallel_threads 24
set_param general.maxThreads $vivado_parallel_threads
if {[get_param general.maxThreads] < $vivado_parallel_threads} {
    error "Vivado did not accept $vivado_parallel_threads compile threads"
}
source [file join [file dirname [info script]] configure_udp_benchmark_vio.tcl]

set vio [get_ips vio_0]
set_property -dict [list \
    CONFIG.C_NUM_PROBE_OUT {4} \
    CONFIG.C_PROBE_OUT3_WIDTH {32} \
    CONFIG.C_PROBE_OUT3_INIT_VAL {0xC0A8650B}] $vio

set vio_run [configure_existing_vio]
set udp_vio_run [configure_udp_benchmark_vio $project_dir]

set vio_runs [list $vio_run $udp_vio_run]
foreach run $vio_runs {
    reset_run $run
}
launch_runs $vio_runs -jobs $vivado_parallel_threads
foreach run $vio_runs {
    wait_on_run $run
}
close_project
