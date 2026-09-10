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
      -dir [file join [get_property DIRECTORY [current_project]] cmac_usplus_0_rdma.srcs sources_rdma ip]
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
    CONFIG.HAS_WR_DATA_COUNT {0} \
    CONFIG.HAS_RD_DATA_COUNT {0}] $tx_fifo

  set vio [rdma_get_or_create_ip $project_dir rdma_vio vio]
  set_property -dict [list \
    CONFIG.SIGNAL_CLOCK.FREQ_HZ {250000000} \
    CONFIG.C_NUM_PROBE_IN {22} \
    CONFIG.C_NUM_PROBE_OUT {20} \
    CONFIG.C_PROBE_IN0_WIDTH {1} \
    CONFIG.C_PROBE_IN1_WIDTH {1} \
    CONFIG.C_PROBE_IN2_WIDTH {1} \
    CONFIG.C_PROBE_IN3_WIDTH {1} \
    CONFIG.C_PROBE_IN4_WIDTH {32} \
    CONFIG.C_PROBE_IN5_WIDTH {32} \
    CONFIG.C_PROBE_IN6_WIDTH {32} \
    CONFIG.C_PROBE_IN7_WIDTH {32} \
    CONFIG.C_PROBE_IN8_WIDTH {32} \
    CONFIG.C_PROBE_IN9_WIDTH {32} \
    CONFIG.C_PROBE_IN10_WIDTH {32} \
    CONFIG.C_PROBE_IN11_WIDTH {32} \
    CONFIG.C_PROBE_IN12_WIDTH {64} \
    CONFIG.C_PROBE_IN13_WIDTH {64} \
    CONFIG.C_PROBE_IN14_WIDTH {32} \
    CONFIG.C_PROBE_IN15_WIDTH {24} \
    CONFIG.C_PROBE_IN16_WIDTH {4} \
    CONFIG.C_PROBE_IN17_WIDTH {32} \
    CONFIG.C_PROBE_IN18_WIDTH {32} \
    CONFIG.C_PROBE_IN19_WIDTH {32} \
    CONFIG.C_PROBE_IN20_WIDTH {64} \
    CONFIG.C_PROBE_IN21_WIDTH {64} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT1_WIDTH {1} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT2_WIDTH {1} \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT3_WIDTH {1} \
    CONFIG.C_PROBE_OUT3_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT4_WIDTH {1} \
    CONFIG.C_PROBE_OUT4_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT5_WIDTH {48} \
    CONFIG.C_PROBE_OUT5_INIT_VAL {0x000000000000} \
    CONFIG.C_PROBE_OUT6_WIDTH {32} \
    CONFIG.C_PROBE_OUT6_INIT_VAL {0x00000000} \
    CONFIG.C_PROBE_OUT7_WIDTH {24} \
    CONFIG.C_PROBE_OUT7_INIT_VAL {0x000001} \
    CONFIG.C_PROBE_OUT8_WIDTH {24} \
    CONFIG.C_PROBE_OUT8_INIT_VAL {0x000000} \
    CONFIG.C_PROBE_OUT9_WIDTH {24} \
    CONFIG.C_PROBE_OUT9_INIT_VAL {0x000000} \
    CONFIG.C_PROBE_OUT10_WIDTH {24} \
    CONFIG.C_PROBE_OUT10_INIT_VAL {0x000000} \
    CONFIG.C_PROBE_OUT11_WIDTH {48} \
    CONFIG.C_PROBE_OUT11_INIT_VAL {0x000000000000} \
    CONFIG.C_PROBE_OUT12_WIDTH {32} \
    CONFIG.C_PROBE_OUT12_INIT_VAL {0x00000000} \
    CONFIG.C_PROBE_OUT13_WIDTH {32} \
    CONFIG.C_PROBE_OUT13_INIT_VAL {0x40000000} \
    CONFIG.C_PROBE_OUT14_WIDTH {32} \
    CONFIG.C_PROBE_OUT14_INIT_VAL {0x00100000} \
    CONFIG.C_PROBE_OUT15_WIDTH {64} \
    CONFIG.C_PROBE_OUT15_INIT_VAL {0x0000000000000000} \
    CONFIG.C_PROBE_OUT16_WIDTH {1} \
    CONFIG.C_PROBE_OUT16_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT17_WIDTH {32} \
    CONFIG.C_PROBE_OUT17_INIT_VAL {0x00100000} \
    CONFIG.C_PROBE_OUT18_WIDTH {48} \
    CONFIG.C_PROBE_OUT18_INIT_VAL {0x000000000000} \
    CONFIG.C_PROBE_OUT19_WIDTH {1} \
    CONFIG.C_PROBE_OUT19_INIT_VAL {0x0}] $vio

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

  set runs [list]
  foreach ip [list $clock_wiz $rx_fifo $tx_fifo $vio $ila] {
    lappend runs [rdma_generate_ip $ip]
  }
  return $runs
}
