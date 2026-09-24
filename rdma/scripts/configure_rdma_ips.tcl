# RDMA-specific debug and clock/CDC IP. The caller must have selected the
# sources_rdma fileset before sourcing this file.

proc rdma_get_or_create_ip {project_dir module_name ip_name} {
  set ip [get_ips -quiet $module_name]
  if {![llength $ip]} {
    create_ip \
      -name $ip_name \
      -vendor xilinx.com \
      -library ip \
      -module_name $module_name \
      -dir [file join [get_property DIRECTORY [current_project]] rdma.srcs sources_rdma ip]
    set ip [get_ips $module_name]
  }
  return $ip
}

proc rdma_generate_ip {ip} {
  reset_target all $ip
  generate_target all $ip
  export_ip_user_files -of_objects $ip -no_script -sync -force
  set ip_run [get_runs -quiet "[get_property NAME $ip]_synth_1"]
  if {![llength $ip_run]} {
    create_ip_run $ip
    set ip_run [get_runs "[get_property NAME $ip]_synth_1"]
  }
  return $ip_run
}

proc configure_rdma_ips {project_dir} {
  set clock_wiz [rdma_get_or_create_ip $project_dir clk_wiz_rdma_250 clk_wiz]
  set_property -dict [list \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {322.265625} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {250.000} \
    CONFIG.CLKOUT1_REQUESTED_PHASE {0.000} \
    CONFIG.CLKOUT1_REQUESTED_DUTY_CYCLE {50.000} \
    CONFIG.NUM_OUT_CLKS {1} \
    CONFIG.CLKOUT1_USED {true} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH}] $clock_wiz

  set rx_fifo [rdma_get_or_create_ip $project_dir axis_data_fifo_rdma_rx axis_data_fifo]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {2048} \
    CONFIG.FIFO_MEMORY_TYPE {block} \
    CONFIG.FIFO_MODE {2} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {2} \
    CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.HAS_TSTRB {0} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.TUSER_WIDTH {1} \
    CONFIG.HAS_WR_DATA_COUNT {1} \
    CONFIG.HAS_RD_DATA_COUNT {0}] $rx_fifo

  set tx_fifo [rdma_get_or_create_ip $project_dir axis_data_fifo_rdma_tx axis_data_fifo]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {2048} \
    CONFIG.FIFO_MEMORY_TYPE {block} \
    CONFIG.FIFO_MODE {2} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.SYNCHRONIZATION_STAGES {2} \
    CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.HAS_TSTRB {0} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.TUSER_WIDTH {1} \
    CONFIG.HAS_WR_DATA_COUNT {1} \
    CONFIG.HAS_RD_DATA_COUNT {0}] $tx_fifo

  set vio [rdma_get_or_create_ip $project_dir rdma_vio vio]
  set_property -dict [list \
    CONFIG.SIGNAL_CLOCK.FREQ_HZ {250000000} \
    CONFIG.C_NUM_PROBE_IN {30} \
    CONFIG.C_NUM_PROBE_OUT {1} \
    CONFIG.C_PROBE_IN0_WIDTH {1} \
    CONFIG.C_PROBE_IN1_WIDTH {1} \
    CONFIG.C_PROBE_IN2_WIDTH {1} \
    CONFIG.C_PROBE_IN3_WIDTH {1} \
    CONFIG.C_PROBE_IN4_WIDTH {1} \
    CONFIG.C_PROBE_IN5_WIDTH {1} \
    CONFIG.C_PROBE_IN6_WIDTH {1} \
    CONFIG.C_PROBE_IN7_WIDTH {4} \
    CONFIG.C_PROBE_IN8_WIDTH {32} \
    CONFIG.C_PROBE_IN9_WIDTH {32} \
    CONFIG.C_PROBE_IN10_WIDTH {32} \
    CONFIG.C_PROBE_IN11_WIDTH {32} \
    CONFIG.C_PROBE_IN12_WIDTH {32} \
    CONFIG.C_PROBE_IN13_WIDTH {32} \
    CONFIG.C_PROBE_IN14_WIDTH {32} \
    CONFIG.C_PROBE_IN15_WIDTH {32} \
    CONFIG.C_PROBE_IN16_WIDTH {32} \
    CONFIG.C_PROBE_IN17_WIDTH {32} \
    CONFIG.C_PROBE_IN18_WIDTH {32} \
    CONFIG.C_PROBE_IN19_WIDTH {64} \
    CONFIG.C_PROBE_IN20_WIDTH {64} \
    CONFIG.C_PROBE_IN21_WIDTH {64} \
    CONFIG.C_PROBE_IN22_WIDTH {64} \
    CONFIG.C_PROBE_IN23_WIDTH {64} \
    CONFIG.C_PROBE_IN24_WIDTH {1} \
    CONFIG.C_PROBE_IN25_WIDTH {8} \
    CONFIG.C_PROBE_IN26_WIDTH {24} \
    CONFIG.C_PROBE_IN27_WIDTH {32} \
    CONFIG.C_PROBE_IN28_WIDTH {1} \
    CONFIG.C_PROBE_IN29_WIDTH {32} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x1}] $vio

  set ila [rdma_get_or_create_ip $project_dir ila_rdma ila]
  set_property -dict [list \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_NUM_OF_PROBES {11} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {0} \
    CONFIG.C_PROBE0_WIDTH {4} \
    CONFIG.C_PROBE1_WIDTH {24} \
    CONFIG.C_PROBE2_WIDTH {32} \
    CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {32} \
    CONFIG.C_PROBE5_WIDTH {32} \
    CONFIG.C_PROBE6_WIDTH {64} \
    CONFIG.C_PROBE7_WIDTH {64} \
    CONFIG.C_PROBE8_WIDTH {32} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1}] $ila

  set flow_vio [rdma_get_or_create_ip $project_dir cmac_flow_control_vio vio]
  set_property -dict [list \
    CONFIG.SIGNAL_CLOCK.FREQ_HZ {322265625} \
    CONFIG.C_NUM_PROBE_IN {20} \
    CONFIG.C_NUM_PROBE_OUT {1} \
    CONFIG.C_PROBE_IN0_WIDTH {9} \
    CONFIG.C_PROBE_IN1_WIDTH {9} \
    CONFIG.C_PROBE_IN2_WIDTH {9} \
    CONFIG.C_PROBE_IN3_WIDTH {9} \
    CONFIG.C_PROBE_IN4_WIDTH {1} \
    CONFIG.C_PROBE_IN5_WIDTH {1} \
    CONFIG.C_PROBE_IN6_WIDTH {32} \
    CONFIG.C_PROBE_IN7_WIDTH {1} \
    CONFIG.C_PROBE_IN8_WIDTH {1} \
    CONFIG.C_PROBE_IN9_WIDTH {16} \
    CONFIG.C_PROBE_IN10_WIDTH {32} \
    CONFIG.C_PROBE_IN11_WIDTH {32} \
    CONFIG.C_PROBE_IN12_WIDTH {32} \
    CONFIG.C_PROBE_IN13_WIDTH {1} \
    CONFIG.C_PROBE_IN14_WIDTH {1} \
    CONFIG.C_PROBE_IN15_WIDTH {16} \
    CONFIG.C_PROBE_IN16_WIDTH {32} \
    CONFIG.C_PROBE_IN17_WIDTH {32} \
    CONFIG.C_PROBE_IN18_WIDTH {32} \
    CONFIG.C_PROBE_IN19_WIDTH {32} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0}] $flow_vio

  set runs [list]
  foreach ip [list $clock_wiz $rx_fifo $tx_fifo $vio $ila $flow_vio] {
    lappend runs [rdma_generate_ip $ip]
  }
  return $runs
}
