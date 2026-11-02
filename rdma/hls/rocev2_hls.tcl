set source_dir $::env(RDMA_HLS_SOURCE_DIR)
set config_dir $::env(RDMA_HLS_CONFIG_DIR)
set project_dir $::env(RDMA_HLS_PROJECT_DIR)
set export_dir $::env(RDMA_HLS_EXPORT_DIR)
set run_csim $::env(RDMA_HLS_RUN_CSIM)

set cflags "-I${config_dir} -I${source_dir}/hls -std=c++14"

open_project -reset $project_dir
cd $project_dir
set_top rocev2_top

add_files ${source_dir}/hls/axi_utils.cpp -cflags $cflags
add_files ${source_dir}/hls/ipv4/ipv4_utils.cpp -cflags $cflags
add_files ${source_dir}/hls/ipv4/ipv4.cpp -cflags $cflags
add_files ${source_dir}/hls/ipv6/ipv6.cpp -cflags $cflags
add_files ${source_dir}/hls/udp/udp.cpp -cflags $cflags
add_files ${source_dir}/hls/crc/crc.cpp -cflags $cflags
add_files ${source_dir}/hls/ib_transport_protocol/ib_utils.cpp -cflags $cflags
add_files ${source_dir}/hls/ib_transport_protocol/ib_transport_protocol.cpp -cflags $cflags
add_files ${source_dir}/hls/rocev2/rocev2.cpp -cflags $cflags

if {$run_csim eq "1"} {
    add_files -tb ${source_dir}/hls/rocev2/test_rocev2.cpp -cflags $cflags
}

open_solution -reset solution1 -flow_target vivado
set_part xczu47dr-fsvg1517-1-i
create_clock -period 4.0 -name default
set_clock_uncertainty 0.5 default
config_rtl -reset all -reset_level low

if {$run_csim eq "1"} {
    csim_design
}

csynth_design
export_design -format ip_catalog -ipname rocev2 -display_name "RoCEv2 Endpoint" -vendor "ethz.systems.fpga" -version "0.82"

file delete -force ${export_dir}/rocev2
file mkdir $export_dir
file copy -force ${project_dir}/solution1/impl/ip ${export_dir}/rocev2
exit
