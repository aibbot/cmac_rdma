# Project timing and placement constraints.
#
# ILA cores are intentionally kept in cmac_usplus_0_ila_debug.xdc and applied
# only during implementation.  Reading debug-core creation commands during
# synthesis retains a large vendor hierarchy and exhausts host memory.

set_property IOSTANDARD LVCMOS18 [get_ports init_clk]
create_clock -period 6.400 [get_ports gt_ref_clk_p]

set_false_path -to [get_pins -leaf -of_objects [get_cells -hier *cdc_to* -filter is_sequential] -filter NAME=~*cmac_cdc*/*/D]

set_property LOC GTYE4_CHANNEL_X0Y4 [get_cells {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN Y35 [get_ports {gt_txp_out[0]}]

set_property LOC GTYE4_CHANNEL_X0Y5 [get_cells {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN V35 [get_ports {gt_txp_out[1]}]

set_property LOC GTYE4_CHANNEL_X0Y6 [get_cells {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN T35 [get_ports {gt_txp_out[2]}]

set_property LOC GTYE4_CHANNEL_X0Y7 [get_cells {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/i_cmac_usplus_0_gt/inst/gen_gtwizard_gtye4_top.cmac_usplus_0_gt_gtwizard_gtye4_inst/gen_gtwizard_gtye4.gen_channel_container[1].gen_enabled_channel.gtye4_channel_wrapper_inst/channel_inst/gtye4_channel_gen.gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
set_property PACKAGE_PIN R33 [get_ports {gt_txp_out[3]}]

set_property PACKAGE_PIN AA33 [get_ports gt_ref_clk_p]
set_property PACKAGE_PIN AL17 [get_ports init_clk]
