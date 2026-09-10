# RDMA-top timing and placement constraints.
#
# The vendor example-design constraints address the CMAC hierarchy directly.
# cmac_usplus_0_rdma_top adds u_cmac_usplus_0_exdes, so keep a dedicated
# copy here rather than changing the vendor-owned source file.

set_property IOSTANDARD LVCMOS18 [get_ports init_clk]
create_clock -name init_clk -period 40.000 [get_ports init_clk]
create_clock -period 6.400 [get_ports gt_ref_clk_p]

set_false_path -to [get_pins -leaf -of_objects [get_cells -hier *cdc_to* -filter is_sequential] -filter NAME=~*cmac_cdc*/*/D]

# Only the explicitly reviewed single-bit and stable-bus synchronizer inputs
# are false paths. Keep all other paths between the related clocks timed.
set rdma_cdc_first_stage_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/(local_ip_sync1_reg\[[0-9]+\]|i_tx_packet_arbiter/rdma_abort_sync1_reg|i_arp_snapshot_cdc/(src_ack_sync1_reg|src_dst_reset_sync1_reg|dst_request_sync1_reg|dst_mac_sync1_reg\[[0-9]+\]|dst_ip_sync1_reg\[[0-9]+\]))/D}]
set_false_path -to $rdma_cdc_first_stage_pins

# Match the constraints applied by xpm_cdc_gray: every Gray bit must reach the
# first destination stage within one source period and with bounded bus skew.
set rdma_gray_source_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_rx_overflow_counter_cdc/src_gray_reg\[[0-9]+\]}]
set rdma_gray_first_stage_cells [get_cells -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_rx_overflow_counter_cdc/dst_gray_sync1_reg\[[0-9]+\]}]
set rdma_gray_source_clock [get_clocks -quiet -of_objects \
  [get_pins -quiet -of_objects $rdma_gray_source_cells -filter {REF_PIN_NAME == C}]]
set rdma_gray_destination_clock [get_clocks -quiet -of_objects \
  [get_pins -quiet -of_objects $rdma_gray_first_stage_cells -filter {REF_PIN_NAME == C}]]
set rdma_gray_source_period [get_property -quiet -min PERIOD $rdma_gray_source_clock]
set rdma_gray_destination_period [get_property -quiet -min PERIOD $rdma_gray_destination_clock]
set_max_delay -from $rdma_gray_source_cells -to $rdma_gray_first_stage_cells \
  $rdma_gray_source_period -datapath_only
set_bus_skew -from $rdma_gray_source_cells -to $rdma_gray_first_stage_cells \
  [expr min($rdma_gray_source_period, $rdma_gray_destination_period)]

# Each reset source directly asserts its own synchronizer and releases only on
# RDMA clock edges. Cut only the primitive asynchronous control pins.
set rdma_reset_async_pins [get_pins -quiet -hierarchical -regexp \
  {.*i_cmac_usplus_0_rdma_board_endpoint/i_(cmac_reset|lock_reset|lock_reset_cmac)_sync/g_active_(high|low)\.reset_pipeline_reg\[[0-9]+\]/(PRE|CLR)}]
set_false_path -to $rdma_reset_async_pins

set_property LOC GTYE4_CHANNEL_X0Y4 [get_cells {u_cmac_usplus_0_exdes/i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN Y35 [get_ports {gt_txp_out[0]}]

set_property LOC GTYE4_CHANNEL_X0Y5 [get_cells {u_cmac_usplus_0_exdes/i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN V35 [get_ports {gt_txp_out[1]}]

set_property LOC GTYE4_CHANNEL_X0Y6 [get_cells {u_cmac_usplus_0_exdes/i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN T35 [get_ports {gt_txp_out[2]}]

set_property LOC GTYE4_CHANNEL_X0Y7 [get_cells {u_cmac_usplus_0_exdes/i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN R33 [get_ports {gt_txp_out[3]}]

set_property PACKAGE_PIN AA33 [get_ports gt_ref_clk_p]
set_property PACKAGE_PIN AL17 [get_ports init_clk]
