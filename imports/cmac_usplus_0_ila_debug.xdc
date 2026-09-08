# CMAC status and AXI-stream observability.
#
# The 50 original CMAC status probes are split across three small ILAs.
# Each probe retains its original observed net and explicit bit order. The
# AXI traffic ILA below remains the original 12-probe definition.
#
# Debug cores are created only during implementation; this XDC is excluded
# from synthesis by tests/build_bitstream.tcl to keep synthesis memory bounded.

# Original status probes 0..17: multi-lane RX counters and common DRP state.
create_debug_core u_ila_0 ila
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out}]]
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe0]
set_property port_width 20 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[13]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[14]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[15]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[16]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[17]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[18]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_err[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe1]
set_property port_width 20 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[13]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[14]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[15]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[16]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[17]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[18]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_len_err[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe2]
set_property port_width 20 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[13]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[14]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[15]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[16]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[17]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[18]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_mf_repeat_err[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe3]
set_property port_width 3 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_packet_small[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_packet_small[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_packet_small[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe4]
set_property port_width 3 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_stomped_fcs[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_stomped_fcs[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_stomped_fcs[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe5]
set_property port_width 20 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[13]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[14]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[15]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[16]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[17]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[18]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe6]
set_property port_width 14 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_bytes[13]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe7]
set_property port_width 16 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[0]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[1]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[2]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[3]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[4]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[5]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[6]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[7]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[8]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[9]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[10]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[11]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[12]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[13]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[14]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpaddr[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe8]
set_property port_width 3 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_packets[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_packets[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_packets[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe9]
set_property port_width 16 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[0]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[1]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[2]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[3]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[4]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[5]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[6]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[7]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[8]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[9]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[10]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[11]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[12]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[13]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[14]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdo[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe10]
set_property port_width 3 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_undersize[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_undersize[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_undersize[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe11]
set_property port_width 3 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_test_pattern_mismatch[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_test_pattern_mismatch[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_test_pattern_mismatch[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe12]
set_property port_width 16 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[0]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[1]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[2]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[3]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[4]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[5]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[6]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[7]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[8]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[9]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[10]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[11]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[12]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[13]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[14]} {i_cmac_usplus_0_pkt_gen_mon/common0_drpdi[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe13]
set_property port_width 7 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_bytes[6]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe14]
set_property port_width 20 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[0]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[1]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[2]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[3]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[4]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[5]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[6]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[7]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[8]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[9]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[10]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[11]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[12]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[13]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[14]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[15]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[16]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[17]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[18]} {i_cmac_usplus_0_pkt_gen_mon/stat_rx_synced_err[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe15]
set_property port_width 20 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list {stat_rx_block_lock[0]} {stat_rx_block_lock[1]} {stat_rx_block_lock[2]} {stat_rx_block_lock[3]} {stat_rx_block_lock[4]} {stat_rx_block_lock[5]} {stat_rx_block_lock[6]} {stat_rx_block_lock[7]} {stat_rx_block_lock[8]} {stat_rx_block_lock[9]} {stat_rx_block_lock[10]} {stat_rx_block_lock[11]} {stat_rx_block_lock[12]} {stat_rx_block_lock[13]} {stat_rx_block_lock[14]} {stat_rx_block_lock[15]} {stat_rx_block_lock[16]} {stat_rx_block_lock[17]} {stat_rx_block_lock[18]} {stat_rx_block_lock[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_0/probe16]
set_property port_width 20 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list {stat_rx_synced[0]} {stat_rx_synced[1]} {stat_rx_synced[2]} {stat_rx_synced[3]} {stat_rx_synced[4]} {stat_rx_synced[5]} {stat_rx_synced[6]} {stat_rx_synced[7]} {stat_rx_synced[8]} {stat_rx_synced[9]} {stat_rx_synced[10]} {stat_rx_synced[11]} {stat_rx_synced[12]} {stat_rx_synced[13]} {stat_rx_synced[14]} {stat_rx_synced[15]} {stat_rx_synced[16]} {stat_rx_synced[17]} {stat_rx_synced[18]} {stat_rx_synced[19]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drpen}]]

# Original status probes 18..34: RX link, fault, and packet-status state.
create_debug_core u_ila_status_1 ila
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_status_1]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_status_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_status_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_status_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_status_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_status_1]
set_property port_width 1 [get_debug_ports u_ila_status_1/clk]
connect_debug_port u_ila_status_1/clk [get_nets [list {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out}]]
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe0]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe0]
connect_debug_port u_ila_status_1/probe0 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drprdy}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe1]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe1]
connect_debug_port u_ila_status_1/probe1 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/common0_drpwe}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe2]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe2]
connect_debug_port u_ila_status_1/probe2 [get_nets [list {ctl_tx_send_idle}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe3]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe3]
connect_debug_port u_ila_status_1/probe3 [get_nets [list {ctl_tx_send_lfi}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_status_1/probe4]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe4]
connect_debug_port u_ila_status_1/probe4 [get_nets [list {stat_rx_aligned_err}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe5]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe5]
connect_debug_port u_ila_status_1/probe5 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_got_signal_os}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe6]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe6]
connect_debug_port u_ila_status_1/probe6 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_hi_ber}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe7]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe7]
connect_debug_port u_ila_status_1/probe7 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_inrangeerr}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe8]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe8]
connect_debug_port u_ila_status_1/probe8 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_internal_local_fault}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_status_1/probe9]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe9]
connect_debug_port u_ila_status_1/probe9 [get_nets [list {stat_rx_internal_local_fault}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe10]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe10]
connect_debug_port u_ila_status_1/probe10 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_jabber}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_status_1/probe11]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe11]
connect_debug_port u_ila_status_1/probe11 [get_nets [list {stat_rx_local_fault}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe12]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe12]
connect_debug_port u_ila_status_1/probe12 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_local_fault}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe13]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe13]
connect_debug_port u_ila_status_1/probe13 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_misaligned}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe14]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe14]
connect_debug_port u_ila_status_1/probe14 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_multicast}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe15]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe15]
connect_debug_port u_ila_status_1/probe15 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_oversize}]]
create_debug_port u_ila_status_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_1/probe16]
set_property port_width 1 [get_debug_ports u_ila_status_1/probe16]
connect_debug_port u_ila_status_1/probe16 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_packet_bad_fcs}]]

# Original status probes 35..49: remaining RX and TX packet-status state.
create_debug_core u_ila_status_2 ila
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_status_2]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_status_2]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_status_2]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_status_2]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_status_2]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_status_2]
set_property port_width 1 [get_debug_ports u_ila_status_2/clk]
connect_debug_port u_ila_status_2/clk [get_nets [list {i_cmac_usplus_0_core_support/i_cmac_usplus_0_gt_wrapper/cmac_gtwiz_userclk_rx_inst/gtwiz_userclk_rx_usrclk_out}]]
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe0]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe0]
connect_debug_port u_ila_status_2/probe0 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_packet_large}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe1]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe1]
connect_debug_port u_ila_status_2/probe1 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_received_local_fault}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe2]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe2]
connect_debug_port u_ila_status_2/probe2 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_remote_fault}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe3]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe3]
connect_debug_port u_ila_status_2/probe3 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_rsfec_uncorrected_cw_inc}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_status_2/probe4]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe4]
connect_debug_port u_ila_status_2/probe4 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_status}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe5]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe5]
connect_debug_port u_ila_status_2/probe5 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_toolong}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe6]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe6]
connect_debug_port u_ila_status_2/probe6 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_total_good_packets}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe7]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe7]
connect_debug_port u_ila_status_2/probe7 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_truncated}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe8]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe8]
connect_debug_port u_ila_status_2/probe8 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_unicast}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe9]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe9]
connect_debug_port u_ila_status_2/probe9 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_rx_vlan}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe10]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe10]
connect_debug_port u_ila_status_2/probe10 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_tx_bad_fcs}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe11]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe11]
connect_debug_port u_ila_status_2/probe11 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_tx_broadcast}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe12]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe12]
connect_debug_port u_ila_status_2/probe12 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_tx_frame_error}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_status_2/probe13]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe13]
connect_debug_port u_ila_status_2/probe13 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_tx_local_fault}]]
create_debug_port u_ila_status_2 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_status_2/probe14]
set_property port_width 1 [get_debug_ports u_ila_status_2/probe14]
connect_debug_port u_ila_status_2/probe14 [get_nets [list {i_cmac_usplus_0_pkt_gen_mon/stat_tx_multicast}]]

# Original 12-probe AXI traffic ILA. Data and keep retain their exact bit order.
create_debug_core u_ila_1 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_1]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_1]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_1]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_1]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_1]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_1]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_1]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_1]
set_property port_width 1 [get_debug_ports u_ila_1/clk]
connect_debug_port u_ila_1/clk [get_nets [list {txusrclk2}]]
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe0]
set_property port_width 512 [get_debug_ports u_ila_1/probe0]
connect_debug_port u_ila_1/probe0 [get_nets [list {rx_axis_tdata[0]} {rx_axis_tdata[1]} {rx_axis_tdata[2]} {rx_axis_tdata[3]} {rx_axis_tdata[4]} {rx_axis_tdata[5]} {rx_axis_tdata[6]} {rx_axis_tdata[7]} {rx_axis_tdata[8]} {rx_axis_tdata[9]} {rx_axis_tdata[10]} {rx_axis_tdata[11]} {rx_axis_tdata[12]} {rx_axis_tdata[13]} {rx_axis_tdata[14]} {rx_axis_tdata[15]} {rx_axis_tdata[16]} {rx_axis_tdata[17]} {rx_axis_tdata[18]} {rx_axis_tdata[19]} {rx_axis_tdata[20]} {rx_axis_tdata[21]} {rx_axis_tdata[22]} {rx_axis_tdata[23]} {rx_axis_tdata[24]} {rx_axis_tdata[25]} {rx_axis_tdata[26]} {rx_axis_tdata[27]} {rx_axis_tdata[28]} {rx_axis_tdata[29]} {rx_axis_tdata[30]} {rx_axis_tdata[31]} {rx_axis_tdata[32]} {rx_axis_tdata[33]} {rx_axis_tdata[34]} {rx_axis_tdata[35]} {rx_axis_tdata[36]} {rx_axis_tdata[37]} {rx_axis_tdata[38]} {rx_axis_tdata[39]} {rx_axis_tdata[40]} {rx_axis_tdata[41]} {rx_axis_tdata[42]} {rx_axis_tdata[43]} {rx_axis_tdata[44]} {rx_axis_tdata[45]} {rx_axis_tdata[46]} {rx_axis_tdata[47]} {rx_axis_tdata[48]} {rx_axis_tdata[49]} {rx_axis_tdata[50]} {rx_axis_tdata[51]} {rx_axis_tdata[52]} {rx_axis_tdata[53]} {rx_axis_tdata[54]} {rx_axis_tdata[55]} {rx_axis_tdata[56]} {rx_axis_tdata[57]} {rx_axis_tdata[58]} {rx_axis_tdata[59]} {rx_axis_tdata[60]} {rx_axis_tdata[61]} {rx_axis_tdata[62]} {rx_axis_tdata[63]} {rx_axis_tdata[64]} {rx_axis_tdata[65]} {rx_axis_tdata[66]} {rx_axis_tdata[67]} {rx_axis_tdata[68]} {rx_axis_tdata[69]} {rx_axis_tdata[70]} {rx_axis_tdata[71]} {rx_axis_tdata[72]} {rx_axis_tdata[73]} {rx_axis_tdata[74]} {rx_axis_tdata[75]} {rx_axis_tdata[76]} {rx_axis_tdata[77]} {rx_axis_tdata[78]} {rx_axis_tdata[79]} {rx_axis_tdata[80]} {rx_axis_tdata[81]} {rx_axis_tdata[82]} {rx_axis_tdata[83]} {rx_axis_tdata[84]} {rx_axis_tdata[85]} {rx_axis_tdata[86]} {rx_axis_tdata[87]} {rx_axis_tdata[88]} {rx_axis_tdata[89]} {rx_axis_tdata[90]} {rx_axis_tdata[91]} {rx_axis_tdata[92]} {rx_axis_tdata[93]} {rx_axis_tdata[94]} {rx_axis_tdata[95]} {rx_axis_tdata[96]} {rx_axis_tdata[97]} {rx_axis_tdata[98]} {rx_axis_tdata[99]} {rx_axis_tdata[100]} {rx_axis_tdata[101]} {rx_axis_tdata[102]} {rx_axis_tdata[103]} {rx_axis_tdata[104]} {rx_axis_tdata[105]} {rx_axis_tdata[106]} {rx_axis_tdata[107]} {rx_axis_tdata[108]} {rx_axis_tdata[109]} {rx_axis_tdata[110]} {rx_axis_tdata[111]} {rx_axis_tdata[112]} {rx_axis_tdata[113]} {rx_axis_tdata[114]} {rx_axis_tdata[115]} {rx_axis_tdata[116]} {rx_axis_tdata[117]} {rx_axis_tdata[118]} {rx_axis_tdata[119]} {rx_axis_tdata[120]} {rx_axis_tdata[121]} {rx_axis_tdata[122]} {rx_axis_tdata[123]} {rx_axis_tdata[124]} {rx_axis_tdata[125]} {rx_axis_tdata[126]} {rx_axis_tdata[127]} {rx_axis_tdata[128]} {rx_axis_tdata[129]} {rx_axis_tdata[130]} {rx_axis_tdata[131]} {rx_axis_tdata[132]} {rx_axis_tdata[133]} {rx_axis_tdata[134]} {rx_axis_tdata[135]} {rx_axis_tdata[136]} {rx_axis_tdata[137]} {rx_axis_tdata[138]} {rx_axis_tdata[139]} {rx_axis_tdata[140]} {rx_axis_tdata[141]} {rx_axis_tdata[142]} {rx_axis_tdata[143]} {rx_axis_tdata[144]} {rx_axis_tdata[145]} {rx_axis_tdata[146]} {rx_axis_tdata[147]} {rx_axis_tdata[148]} {rx_axis_tdata[149]} {rx_axis_tdata[150]} {rx_axis_tdata[151]} {rx_axis_tdata[152]} {rx_axis_tdata[153]} {rx_axis_tdata[154]} {rx_axis_tdata[155]} {rx_axis_tdata[156]} {rx_axis_tdata[157]} {rx_axis_tdata[158]} {rx_axis_tdata[159]} {rx_axis_tdata[160]} {rx_axis_tdata[161]} {rx_axis_tdata[162]} {rx_axis_tdata[163]} {rx_axis_tdata[164]} {rx_axis_tdata[165]} {rx_axis_tdata[166]} {rx_axis_tdata[167]} {rx_axis_tdata[168]} {rx_axis_tdata[169]} {rx_axis_tdata[170]} {rx_axis_tdata[171]} {rx_axis_tdata[172]} {rx_axis_tdata[173]} {rx_axis_tdata[174]} {rx_axis_tdata[175]} {rx_axis_tdata[176]} {rx_axis_tdata[177]} {rx_axis_tdata[178]} {rx_axis_tdata[179]} {rx_axis_tdata[180]} {rx_axis_tdata[181]} {rx_axis_tdata[182]} {rx_axis_tdata[183]} {rx_axis_tdata[184]} {rx_axis_tdata[185]} {rx_axis_tdata[186]} {rx_axis_tdata[187]} {rx_axis_tdata[188]} {rx_axis_tdata[189]} {rx_axis_tdata[190]} {rx_axis_tdata[191]} {rx_axis_tdata[192]} {rx_axis_tdata[193]} {rx_axis_tdata[194]} {rx_axis_tdata[195]} {rx_axis_tdata[196]} {rx_axis_tdata[197]} {rx_axis_tdata[198]} {rx_axis_tdata[199]} {rx_axis_tdata[200]} {rx_axis_tdata[201]} {rx_axis_tdata[202]} {rx_axis_tdata[203]} {rx_axis_tdata[204]} {rx_axis_tdata[205]} {rx_axis_tdata[206]} {rx_axis_tdata[207]} {rx_axis_tdata[208]} {rx_axis_tdata[209]} {rx_axis_tdata[210]} {rx_axis_tdata[211]} {rx_axis_tdata[212]} {rx_axis_tdata[213]} {rx_axis_tdata[214]} {rx_axis_tdata[215]} {rx_axis_tdata[216]} {rx_axis_tdata[217]} {rx_axis_tdata[218]} {rx_axis_tdata[219]} {rx_axis_tdata[220]} {rx_axis_tdata[221]} {rx_axis_tdata[222]} {rx_axis_tdata[223]} {rx_axis_tdata[224]} {rx_axis_tdata[225]} {rx_axis_tdata[226]} {rx_axis_tdata[227]} {rx_axis_tdata[228]} {rx_axis_tdata[229]} {rx_axis_tdata[230]} {rx_axis_tdata[231]} {rx_axis_tdata[232]} {rx_axis_tdata[233]} {rx_axis_tdata[234]} {rx_axis_tdata[235]} {rx_axis_tdata[236]} {rx_axis_tdata[237]} {rx_axis_tdata[238]} {rx_axis_tdata[239]} {rx_axis_tdata[240]} {rx_axis_tdata[241]} {rx_axis_tdata[242]} {rx_axis_tdata[243]} {rx_axis_tdata[244]} {rx_axis_tdata[245]} {rx_axis_tdata[246]} {rx_axis_tdata[247]} {rx_axis_tdata[248]} {rx_axis_tdata[249]} {rx_axis_tdata[250]} {rx_axis_tdata[251]} {rx_axis_tdata[252]} {rx_axis_tdata[253]} {rx_axis_tdata[254]} {rx_axis_tdata[255]} {rx_axis_tdata[256]} {rx_axis_tdata[257]} {rx_axis_tdata[258]} {rx_axis_tdata[259]} {rx_axis_tdata[260]} {rx_axis_tdata[261]} {rx_axis_tdata[262]} {rx_axis_tdata[263]} {rx_axis_tdata[264]} {rx_axis_tdata[265]} {rx_axis_tdata[266]} {rx_axis_tdata[267]} {rx_axis_tdata[268]} {rx_axis_tdata[269]} {rx_axis_tdata[270]} {rx_axis_tdata[271]} {rx_axis_tdata[272]} {rx_axis_tdata[273]} {rx_axis_tdata[274]} {rx_axis_tdata[275]} {rx_axis_tdata[276]} {rx_axis_tdata[277]} {rx_axis_tdata[278]} {rx_axis_tdata[279]} {rx_axis_tdata[280]} {rx_axis_tdata[281]} {rx_axis_tdata[282]} {rx_axis_tdata[283]} {rx_axis_tdata[284]} {rx_axis_tdata[285]} {rx_axis_tdata[286]} {rx_axis_tdata[287]} {rx_axis_tdata[288]} {rx_axis_tdata[289]} {rx_axis_tdata[290]} {rx_axis_tdata[291]} {rx_axis_tdata[292]} {rx_axis_tdata[293]} {rx_axis_tdata[294]} {rx_axis_tdata[295]} {rx_axis_tdata[296]} {rx_axis_tdata[297]} {rx_axis_tdata[298]} {rx_axis_tdata[299]} {rx_axis_tdata[300]} {rx_axis_tdata[301]} {rx_axis_tdata[302]} {rx_axis_tdata[303]} {rx_axis_tdata[304]} {rx_axis_tdata[305]} {rx_axis_tdata[306]} {rx_axis_tdata[307]} {rx_axis_tdata[308]} {rx_axis_tdata[309]} {rx_axis_tdata[310]} {rx_axis_tdata[311]} {rx_axis_tdata[312]} {rx_axis_tdata[313]} {rx_axis_tdata[314]} {rx_axis_tdata[315]} {rx_axis_tdata[316]} {rx_axis_tdata[317]} {rx_axis_tdata[318]} {rx_axis_tdata[319]} {rx_axis_tdata[320]} {rx_axis_tdata[321]} {rx_axis_tdata[322]} {rx_axis_tdata[323]} {rx_axis_tdata[324]} {rx_axis_tdata[325]} {rx_axis_tdata[326]} {rx_axis_tdata[327]} {rx_axis_tdata[328]} {rx_axis_tdata[329]} {rx_axis_tdata[330]} {rx_axis_tdata[331]} {rx_axis_tdata[332]} {rx_axis_tdata[333]} {rx_axis_tdata[334]} {rx_axis_tdata[335]} {rx_axis_tdata[336]} {rx_axis_tdata[337]} {rx_axis_tdata[338]} {rx_axis_tdata[339]} {rx_axis_tdata[340]} {rx_axis_tdata[341]} {rx_axis_tdata[342]} {rx_axis_tdata[343]} {rx_axis_tdata[344]} {rx_axis_tdata[345]} {rx_axis_tdata[346]} {rx_axis_tdata[347]} {rx_axis_tdata[348]} {rx_axis_tdata[349]} {rx_axis_tdata[350]} {rx_axis_tdata[351]} {rx_axis_tdata[352]} {rx_axis_tdata[353]} {rx_axis_tdata[354]} {rx_axis_tdata[355]} {rx_axis_tdata[356]} {rx_axis_tdata[357]} {rx_axis_tdata[358]} {rx_axis_tdata[359]} {rx_axis_tdata[360]} {rx_axis_tdata[361]} {rx_axis_tdata[362]} {rx_axis_tdata[363]} {rx_axis_tdata[364]} {rx_axis_tdata[365]} {rx_axis_tdata[366]} {rx_axis_tdata[367]} {rx_axis_tdata[368]} {rx_axis_tdata[369]} {rx_axis_tdata[370]} {rx_axis_tdata[371]} {rx_axis_tdata[372]} {rx_axis_tdata[373]} {rx_axis_tdata[374]} {rx_axis_tdata[375]} {rx_axis_tdata[376]} {rx_axis_tdata[377]} {rx_axis_tdata[378]} {rx_axis_tdata[379]} {rx_axis_tdata[380]} {rx_axis_tdata[381]} {rx_axis_tdata[382]} {rx_axis_tdata[383]} {rx_axis_tdata[384]} {rx_axis_tdata[385]} {rx_axis_tdata[386]} {rx_axis_tdata[387]} {rx_axis_tdata[388]} {rx_axis_tdata[389]} {rx_axis_tdata[390]} {rx_axis_tdata[391]} {rx_axis_tdata[392]} {rx_axis_tdata[393]} {rx_axis_tdata[394]} {rx_axis_tdata[395]} {rx_axis_tdata[396]} {rx_axis_tdata[397]} {rx_axis_tdata[398]} {rx_axis_tdata[399]} {rx_axis_tdata[400]} {rx_axis_tdata[401]} {rx_axis_tdata[402]} {rx_axis_tdata[403]} {rx_axis_tdata[404]} {rx_axis_tdata[405]} {rx_axis_tdata[406]} {rx_axis_tdata[407]} {rx_axis_tdata[408]} {rx_axis_tdata[409]} {rx_axis_tdata[410]} {rx_axis_tdata[411]} {rx_axis_tdata[412]} {rx_axis_tdata[413]} {rx_axis_tdata[414]} {rx_axis_tdata[415]} {rx_axis_tdata[416]} {rx_axis_tdata[417]} {rx_axis_tdata[418]} {rx_axis_tdata[419]} {rx_axis_tdata[420]} {rx_axis_tdata[421]} {rx_axis_tdata[422]} {rx_axis_tdata[423]} {rx_axis_tdata[424]} {rx_axis_tdata[425]} {rx_axis_tdata[426]} {rx_axis_tdata[427]} {rx_axis_tdata[428]} {rx_axis_tdata[429]} {rx_axis_tdata[430]} {rx_axis_tdata[431]} {rx_axis_tdata[432]} {rx_axis_tdata[433]} {rx_axis_tdata[434]} {rx_axis_tdata[435]} {rx_axis_tdata[436]} {rx_axis_tdata[437]} {rx_axis_tdata[438]} {rx_axis_tdata[439]} {rx_axis_tdata[440]} {rx_axis_tdata[441]} {rx_axis_tdata[442]} {rx_axis_tdata[443]} {rx_axis_tdata[444]} {rx_axis_tdata[445]} {rx_axis_tdata[446]} {rx_axis_tdata[447]} {rx_axis_tdata[448]} {rx_axis_tdata[449]} {rx_axis_tdata[450]} {rx_axis_tdata[451]} {rx_axis_tdata[452]} {rx_axis_tdata[453]} {rx_axis_tdata[454]} {rx_axis_tdata[455]} {rx_axis_tdata[456]} {rx_axis_tdata[457]} {rx_axis_tdata[458]} {rx_axis_tdata[459]} {rx_axis_tdata[460]} {rx_axis_tdata[461]} {rx_axis_tdata[462]} {rx_axis_tdata[463]} {rx_axis_tdata[464]} {rx_axis_tdata[465]} {rx_axis_tdata[466]} {rx_axis_tdata[467]} {rx_axis_tdata[468]} {rx_axis_tdata[469]} {rx_axis_tdata[470]} {rx_axis_tdata[471]} {rx_axis_tdata[472]} {rx_axis_tdata[473]} {rx_axis_tdata[474]} {rx_axis_tdata[475]} {rx_axis_tdata[476]} {rx_axis_tdata[477]} {rx_axis_tdata[478]} {rx_axis_tdata[479]} {rx_axis_tdata[480]} {rx_axis_tdata[481]} {rx_axis_tdata[482]} {rx_axis_tdata[483]} {rx_axis_tdata[484]} {rx_axis_tdata[485]} {rx_axis_tdata[486]} {rx_axis_tdata[487]} {rx_axis_tdata[488]} {rx_axis_tdata[489]} {rx_axis_tdata[490]} {rx_axis_tdata[491]} {rx_axis_tdata[492]} {rx_axis_tdata[493]} {rx_axis_tdata[494]} {rx_axis_tdata[495]} {rx_axis_tdata[496]} {rx_axis_tdata[497]} {rx_axis_tdata[498]} {rx_axis_tdata[499]} {rx_axis_tdata[500]} {rx_axis_tdata[501]} {rx_axis_tdata[502]} {rx_axis_tdata[503]} {rx_axis_tdata[504]} {rx_axis_tdata[505]} {rx_axis_tdata[506]} {rx_axis_tdata[507]} {rx_axis_tdata[508]} {rx_axis_tdata[509]} {rx_axis_tdata[510]} {rx_axis_tdata[511]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe1]
set_property port_width 64 [get_debug_ports u_ila_1/probe1]
connect_debug_port u_ila_1/probe1 [get_nets [list {rx_axis_tkeep[0]} {rx_axis_tkeep[1]} {rx_axis_tkeep[2]} {rx_axis_tkeep[3]} {rx_axis_tkeep[4]} {rx_axis_tkeep[5]} {rx_axis_tkeep[6]} {rx_axis_tkeep[7]} {rx_axis_tkeep[8]} {rx_axis_tkeep[9]} {rx_axis_tkeep[10]} {rx_axis_tkeep[11]} {rx_axis_tkeep[12]} {rx_axis_tkeep[13]} {rx_axis_tkeep[14]} {rx_axis_tkeep[15]} {rx_axis_tkeep[16]} {rx_axis_tkeep[17]} {rx_axis_tkeep[18]} {rx_axis_tkeep[19]} {rx_axis_tkeep[20]} {rx_axis_tkeep[21]} {rx_axis_tkeep[22]} {rx_axis_tkeep[23]} {rx_axis_tkeep[24]} {rx_axis_tkeep[25]} {rx_axis_tkeep[26]} {rx_axis_tkeep[27]} {rx_axis_tkeep[28]} {rx_axis_tkeep[29]} {rx_axis_tkeep[30]} {rx_axis_tkeep[31]} {rx_axis_tkeep[32]} {rx_axis_tkeep[33]} {rx_axis_tkeep[34]} {rx_axis_tkeep[35]} {rx_axis_tkeep[36]} {rx_axis_tkeep[37]} {rx_axis_tkeep[38]} {rx_axis_tkeep[39]} {rx_axis_tkeep[40]} {rx_axis_tkeep[41]} {rx_axis_tkeep[42]} {rx_axis_tkeep[43]} {rx_axis_tkeep[44]} {rx_axis_tkeep[45]} {rx_axis_tkeep[46]} {rx_axis_tkeep[47]} {rx_axis_tkeep[48]} {rx_axis_tkeep[49]} {rx_axis_tkeep[50]} {rx_axis_tkeep[51]} {rx_axis_tkeep[52]} {rx_axis_tkeep[53]} {rx_axis_tkeep[54]} {rx_axis_tkeep[55]} {rx_axis_tkeep[56]} {rx_axis_tkeep[57]} {rx_axis_tkeep[58]} {rx_axis_tkeep[59]} {rx_axis_tkeep[60]} {rx_axis_tkeep[61]} {rx_axis_tkeep[62]} {rx_axis_tkeep[63]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe2]
set_property port_width 1 [get_debug_ports u_ila_1/probe2]
connect_debug_port u_ila_1/probe2 [get_nets [list {rx_axis_tlast}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe3]
set_property port_width 1 [get_debug_ports u_ila_1/probe3]
connect_debug_port u_ila_1/probe3 [get_nets [list {rx_axis_tuser}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe4]
set_property port_width 1 [get_debug_ports u_ila_1/probe4]
connect_debug_port u_ila_1/probe4 [get_nets [list {rx_axis_tvalid}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe5]
set_property port_width 512 [get_debug_ports u_ila_1/probe5]
connect_debug_port u_ila_1/probe5 [get_nets [list {tx_axis_tdata[0]} {tx_axis_tdata[1]} {tx_axis_tdata[2]} {tx_axis_tdata[3]} {tx_axis_tdata[4]} {tx_axis_tdata[5]} {tx_axis_tdata[6]} {tx_axis_tdata[7]} {tx_axis_tdata[8]} {tx_axis_tdata[9]} {tx_axis_tdata[10]} {tx_axis_tdata[11]} {tx_axis_tdata[12]} {tx_axis_tdata[13]} {tx_axis_tdata[14]} {tx_axis_tdata[15]} {tx_axis_tdata[16]} {tx_axis_tdata[17]} {tx_axis_tdata[18]} {tx_axis_tdata[19]} {tx_axis_tdata[20]} {tx_axis_tdata[21]} {tx_axis_tdata[22]} {tx_axis_tdata[23]} {tx_axis_tdata[24]} {tx_axis_tdata[25]} {tx_axis_tdata[26]} {tx_axis_tdata[27]} {tx_axis_tdata[28]} {tx_axis_tdata[29]} {tx_axis_tdata[30]} {tx_axis_tdata[31]} {tx_axis_tdata[32]} {tx_axis_tdata[33]} {tx_axis_tdata[34]} {tx_axis_tdata[35]} {tx_axis_tdata[36]} {tx_axis_tdata[37]} {tx_axis_tdata[38]} {tx_axis_tdata[39]} {tx_axis_tdata[40]} {tx_axis_tdata[41]} {tx_axis_tdata[42]} {tx_axis_tdata[43]} {tx_axis_tdata[44]} {tx_axis_tdata[45]} {tx_axis_tdata[46]} {tx_axis_tdata[47]} {tx_axis_tdata[48]} {tx_axis_tdata[49]} {tx_axis_tdata[50]} {tx_axis_tdata[51]} {tx_axis_tdata[52]} {tx_axis_tdata[53]} {tx_axis_tdata[54]} {tx_axis_tdata[55]} {tx_axis_tdata[56]} {tx_axis_tdata[57]} {tx_axis_tdata[58]} {tx_axis_tdata[59]} {tx_axis_tdata[60]} {tx_axis_tdata[61]} {tx_axis_tdata[62]} {tx_axis_tdata[63]} {tx_axis_tdata[64]} {tx_axis_tdata[65]} {tx_axis_tdata[66]} {tx_axis_tdata[67]} {tx_axis_tdata[68]} {tx_axis_tdata[69]} {tx_axis_tdata[70]} {tx_axis_tdata[71]} {tx_axis_tdata[72]} {tx_axis_tdata[73]} {tx_axis_tdata[74]} {tx_axis_tdata[75]} {tx_axis_tdata[76]} {tx_axis_tdata[77]} {tx_axis_tdata[78]} {tx_axis_tdata[79]} {tx_axis_tdata[80]} {tx_axis_tdata[81]} {tx_axis_tdata[82]} {tx_axis_tdata[83]} {tx_axis_tdata[84]} {tx_axis_tdata[85]} {tx_axis_tdata[86]} {tx_axis_tdata[87]} {tx_axis_tdata[88]} {tx_axis_tdata[89]} {tx_axis_tdata[90]} {tx_axis_tdata[91]} {tx_axis_tdata[92]} {tx_axis_tdata[93]} {tx_axis_tdata[94]} {tx_axis_tdata[95]} {tx_axis_tdata[96]} {tx_axis_tdata[97]} {tx_axis_tdata[98]} {tx_axis_tdata[99]} {tx_axis_tdata[100]} {tx_axis_tdata[101]} {tx_axis_tdata[102]} {tx_axis_tdata[103]} {tx_axis_tdata[104]} {tx_axis_tdata[105]} {tx_axis_tdata[106]} {tx_axis_tdata[107]} {tx_axis_tdata[108]} {tx_axis_tdata[109]} {tx_axis_tdata[110]} {tx_axis_tdata[111]} {tx_axis_tdata[112]} {tx_axis_tdata[113]} {tx_axis_tdata[114]} {tx_axis_tdata[115]} {tx_axis_tdata[116]} {tx_axis_tdata[117]} {tx_axis_tdata[118]} {tx_axis_tdata[119]} {tx_axis_tdata[120]} {tx_axis_tdata[121]} {tx_axis_tdata[122]} {tx_axis_tdata[123]} {tx_axis_tdata[124]} {tx_axis_tdata[125]} {tx_axis_tdata[126]} {tx_axis_tdata[127]} {tx_axis_tdata[128]} {tx_axis_tdata[129]} {tx_axis_tdata[130]} {tx_axis_tdata[131]} {tx_axis_tdata[132]} {tx_axis_tdata[133]} {tx_axis_tdata[134]} {tx_axis_tdata[135]} {tx_axis_tdata[136]} {tx_axis_tdata[137]} {tx_axis_tdata[138]} {tx_axis_tdata[139]} {tx_axis_tdata[140]} {tx_axis_tdata[141]} {tx_axis_tdata[142]} {tx_axis_tdata[143]} {tx_axis_tdata[144]} {tx_axis_tdata[145]} {tx_axis_tdata[146]} {tx_axis_tdata[147]} {tx_axis_tdata[148]} {tx_axis_tdata[149]} {tx_axis_tdata[150]} {tx_axis_tdata[151]} {tx_axis_tdata[152]} {tx_axis_tdata[153]} {tx_axis_tdata[154]} {tx_axis_tdata[155]} {tx_axis_tdata[156]} {tx_axis_tdata[157]} {tx_axis_tdata[158]} {tx_axis_tdata[159]} {tx_axis_tdata[160]} {tx_axis_tdata[161]} {tx_axis_tdata[162]} {tx_axis_tdata[163]} {tx_axis_tdata[164]} {tx_axis_tdata[165]} {tx_axis_tdata[166]} {tx_axis_tdata[167]} {tx_axis_tdata[168]} {tx_axis_tdata[169]} {tx_axis_tdata[170]} {tx_axis_tdata[171]} {tx_axis_tdata[172]} {tx_axis_tdata[173]} {tx_axis_tdata[174]} {tx_axis_tdata[175]} {tx_axis_tdata[176]} {tx_axis_tdata[177]} {tx_axis_tdata[178]} {tx_axis_tdata[179]} {tx_axis_tdata[180]} {tx_axis_tdata[181]} {tx_axis_tdata[182]} {tx_axis_tdata[183]} {tx_axis_tdata[184]} {tx_axis_tdata[185]} {tx_axis_tdata[186]} {tx_axis_tdata[187]} {tx_axis_tdata[188]} {tx_axis_tdata[189]} {tx_axis_tdata[190]} {tx_axis_tdata[191]} {tx_axis_tdata[192]} {tx_axis_tdata[193]} {tx_axis_tdata[194]} {tx_axis_tdata[195]} {tx_axis_tdata[196]} {tx_axis_tdata[197]} {tx_axis_tdata[198]} {tx_axis_tdata[199]} {tx_axis_tdata[200]} {tx_axis_tdata[201]} {tx_axis_tdata[202]} {tx_axis_tdata[203]} {tx_axis_tdata[204]} {tx_axis_tdata[205]} {tx_axis_tdata[206]} {tx_axis_tdata[207]} {tx_axis_tdata[208]} {tx_axis_tdata[209]} {tx_axis_tdata[210]} {tx_axis_tdata[211]} {tx_axis_tdata[212]} {tx_axis_tdata[213]} {tx_axis_tdata[214]} {tx_axis_tdata[215]} {tx_axis_tdata[216]} {tx_axis_tdata[217]} {tx_axis_tdata[218]} {tx_axis_tdata[219]} {tx_axis_tdata[220]} {tx_axis_tdata[221]} {tx_axis_tdata[222]} {tx_axis_tdata[223]} {tx_axis_tdata[224]} {tx_axis_tdata[225]} {tx_axis_tdata[226]} {tx_axis_tdata[227]} {tx_axis_tdata[228]} {tx_axis_tdata[229]} {tx_axis_tdata[230]} {tx_axis_tdata[231]} {tx_axis_tdata[232]} {tx_axis_tdata[233]} {tx_axis_tdata[234]} {tx_axis_tdata[235]} {tx_axis_tdata[236]} {tx_axis_tdata[237]} {tx_axis_tdata[238]} {tx_axis_tdata[239]} {tx_axis_tdata[240]} {tx_axis_tdata[241]} {tx_axis_tdata[242]} {tx_axis_tdata[243]} {tx_axis_tdata[244]} {tx_axis_tdata[245]} {tx_axis_tdata[246]} {tx_axis_tdata[247]} {tx_axis_tdata[248]} {tx_axis_tdata[249]} {tx_axis_tdata[250]} {tx_axis_tdata[251]} {tx_axis_tdata[252]} {tx_axis_tdata[253]} {tx_axis_tdata[254]} {tx_axis_tdata[255]} {tx_axis_tdata[256]} {tx_axis_tdata[257]} {tx_axis_tdata[258]} {tx_axis_tdata[259]} {tx_axis_tdata[260]} {tx_axis_tdata[261]} {tx_axis_tdata[262]} {tx_axis_tdata[263]} {tx_axis_tdata[264]} {tx_axis_tdata[265]} {tx_axis_tdata[266]} {tx_axis_tdata[267]} {tx_axis_tdata[268]} {tx_axis_tdata[269]} {tx_axis_tdata[270]} {tx_axis_tdata[271]} {tx_axis_tdata[272]} {tx_axis_tdata[273]} {tx_axis_tdata[274]} {tx_axis_tdata[275]} {tx_axis_tdata[276]} {tx_axis_tdata[277]} {tx_axis_tdata[278]} {tx_axis_tdata[279]} {tx_axis_tdata[280]} {tx_axis_tdata[281]} {tx_axis_tdata[282]} {tx_axis_tdata[283]} {tx_axis_tdata[284]} {tx_axis_tdata[285]} {tx_axis_tdata[286]} {tx_axis_tdata[287]} {tx_axis_tdata[288]} {tx_axis_tdata[289]} {tx_axis_tdata[290]} {tx_axis_tdata[291]} {tx_axis_tdata[292]} {tx_axis_tdata[293]} {tx_axis_tdata[294]} {tx_axis_tdata[295]} {tx_axis_tdata[296]} {tx_axis_tdata[297]} {tx_axis_tdata[298]} {tx_axis_tdata[299]} {tx_axis_tdata[300]} {tx_axis_tdata[301]} {tx_axis_tdata[302]} {tx_axis_tdata[303]} {tx_axis_tdata[304]} {tx_axis_tdata[305]} {tx_axis_tdata[306]} {tx_axis_tdata[307]} {tx_axis_tdata[308]} {tx_axis_tdata[309]} {tx_axis_tdata[310]} {tx_axis_tdata[311]} {tx_axis_tdata[312]} {tx_axis_tdata[313]} {tx_axis_tdata[314]} {tx_axis_tdata[315]} {tx_axis_tdata[316]} {tx_axis_tdata[317]} {tx_axis_tdata[318]} {tx_axis_tdata[319]} {tx_axis_tdata[320]} {tx_axis_tdata[321]} {tx_axis_tdata[322]} {tx_axis_tdata[323]} {tx_axis_tdata[324]} {tx_axis_tdata[325]} {tx_axis_tdata[326]} {tx_axis_tdata[327]} {tx_axis_tdata[328]} {tx_axis_tdata[329]} {tx_axis_tdata[330]} {tx_axis_tdata[331]} {tx_axis_tdata[332]} {tx_axis_tdata[333]} {tx_axis_tdata[334]} {tx_axis_tdata[335]} {tx_axis_tdata[336]} {tx_axis_tdata[337]} {tx_axis_tdata[338]} {tx_axis_tdata[339]} {tx_axis_tdata[340]} {tx_axis_tdata[341]} {tx_axis_tdata[342]} {tx_axis_tdata[343]} {tx_axis_tdata[344]} {tx_axis_tdata[345]} {tx_axis_tdata[346]} {tx_axis_tdata[347]} {tx_axis_tdata[348]} {tx_axis_tdata[349]} {tx_axis_tdata[350]} {tx_axis_tdata[351]} {tx_axis_tdata[352]} {tx_axis_tdata[353]} {tx_axis_tdata[354]} {tx_axis_tdata[355]} {tx_axis_tdata[356]} {tx_axis_tdata[357]} {tx_axis_tdata[358]} {tx_axis_tdata[359]} {tx_axis_tdata[360]} {tx_axis_tdata[361]} {tx_axis_tdata[362]} {tx_axis_tdata[363]} {tx_axis_tdata[364]} {tx_axis_tdata[365]} {tx_axis_tdata[366]} {tx_axis_tdata[367]} {tx_axis_tdata[368]} {tx_axis_tdata[369]} {tx_axis_tdata[370]} {tx_axis_tdata[371]} {tx_axis_tdata[372]} {tx_axis_tdata[373]} {tx_axis_tdata[374]} {tx_axis_tdata[375]} {tx_axis_tdata[376]} {tx_axis_tdata[377]} {tx_axis_tdata[378]} {tx_axis_tdata[379]} {tx_axis_tdata[380]} {tx_axis_tdata[381]} {tx_axis_tdata[382]} {tx_axis_tdata[383]} {tx_axis_tdata[384]} {tx_axis_tdata[385]} {tx_axis_tdata[386]} {tx_axis_tdata[387]} {tx_axis_tdata[388]} {tx_axis_tdata[389]} {tx_axis_tdata[390]} {tx_axis_tdata[391]} {tx_axis_tdata[392]} {tx_axis_tdata[393]} {tx_axis_tdata[394]} {tx_axis_tdata[395]} {tx_axis_tdata[396]} {tx_axis_tdata[397]} {tx_axis_tdata[398]} {tx_axis_tdata[399]} {tx_axis_tdata[400]} {tx_axis_tdata[401]} {tx_axis_tdata[402]} {tx_axis_tdata[403]} {tx_axis_tdata[404]} {tx_axis_tdata[405]} {tx_axis_tdata[406]} {tx_axis_tdata[407]} {tx_axis_tdata[408]} {tx_axis_tdata[409]} {tx_axis_tdata[410]} {tx_axis_tdata[411]} {tx_axis_tdata[412]} {tx_axis_tdata[413]} {tx_axis_tdata[414]} {tx_axis_tdata[415]} {tx_axis_tdata[416]} {tx_axis_tdata[417]} {tx_axis_tdata[418]} {tx_axis_tdata[419]} {tx_axis_tdata[420]} {tx_axis_tdata[421]} {tx_axis_tdata[422]} {tx_axis_tdata[423]} {tx_axis_tdata[424]} {tx_axis_tdata[425]} {tx_axis_tdata[426]} {tx_axis_tdata[427]} {tx_axis_tdata[428]} {tx_axis_tdata[429]} {tx_axis_tdata[430]} {tx_axis_tdata[431]} {tx_axis_tdata[432]} {tx_axis_tdata[433]} {tx_axis_tdata[434]} {tx_axis_tdata[435]} {tx_axis_tdata[436]} {tx_axis_tdata[437]} {tx_axis_tdata[438]} {tx_axis_tdata[439]} {tx_axis_tdata[440]} {tx_axis_tdata[441]} {tx_axis_tdata[442]} {tx_axis_tdata[443]} {tx_axis_tdata[444]} {tx_axis_tdata[445]} {tx_axis_tdata[446]} {tx_axis_tdata[447]} {tx_axis_tdata[448]} {tx_axis_tdata[449]} {tx_axis_tdata[450]} {tx_axis_tdata[451]} {tx_axis_tdata[452]} {tx_axis_tdata[453]} {tx_axis_tdata[454]} {tx_axis_tdata[455]} {tx_axis_tdata[456]} {tx_axis_tdata[457]} {tx_axis_tdata[458]} {tx_axis_tdata[459]} {tx_axis_tdata[460]} {tx_axis_tdata[461]} {tx_axis_tdata[462]} {tx_axis_tdata[463]} {tx_axis_tdata[464]} {tx_axis_tdata[465]} {tx_axis_tdata[466]} {tx_axis_tdata[467]} {tx_axis_tdata[468]} {tx_axis_tdata[469]} {tx_axis_tdata[470]} {tx_axis_tdata[471]} {tx_axis_tdata[472]} {tx_axis_tdata[473]} {tx_axis_tdata[474]} {tx_axis_tdata[475]} {tx_axis_tdata[476]} {tx_axis_tdata[477]} {tx_axis_tdata[478]} {tx_axis_tdata[479]} {tx_axis_tdata[480]} {tx_axis_tdata[481]} {tx_axis_tdata[482]} {tx_axis_tdata[483]} {tx_axis_tdata[484]} {tx_axis_tdata[485]} {tx_axis_tdata[486]} {tx_axis_tdata[487]} {tx_axis_tdata[488]} {tx_axis_tdata[489]} {tx_axis_tdata[490]} {tx_axis_tdata[491]} {tx_axis_tdata[492]} {tx_axis_tdata[493]} {tx_axis_tdata[494]} {tx_axis_tdata[495]} {tx_axis_tdata[496]} {tx_axis_tdata[497]} {tx_axis_tdata[498]} {tx_axis_tdata[499]} {tx_axis_tdata[500]} {tx_axis_tdata[501]} {tx_axis_tdata[502]} {tx_axis_tdata[503]} {tx_axis_tdata[504]} {tx_axis_tdata[505]} {tx_axis_tdata[506]} {tx_axis_tdata[507]} {tx_axis_tdata[508]} {tx_axis_tdata[509]} {tx_axis_tdata[510]} {tx_axis_tdata[511]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe6]
set_property port_width 64 [get_debug_ports u_ila_1/probe6]
connect_debug_port u_ila_1/probe6 [get_nets [list {tx_axis_tkeep[0]} {tx_axis_tkeep[1]} {tx_axis_tkeep[2]} {tx_axis_tkeep[3]} {tx_axis_tkeep[4]} {tx_axis_tkeep[5]} {tx_axis_tkeep[6]} {tx_axis_tkeep[7]} {tx_axis_tkeep[8]} {tx_axis_tkeep[9]} {tx_axis_tkeep[10]} {tx_axis_tkeep[11]} {tx_axis_tkeep[12]} {tx_axis_tkeep[13]} {tx_axis_tkeep[14]} {tx_axis_tkeep[15]} {tx_axis_tkeep[16]} {tx_axis_tkeep[17]} {tx_axis_tkeep[18]} {tx_axis_tkeep[19]} {tx_axis_tkeep[20]} {tx_axis_tkeep[21]} {tx_axis_tkeep[22]} {tx_axis_tkeep[23]} {tx_axis_tkeep[24]} {tx_axis_tkeep[25]} {tx_axis_tkeep[26]} {tx_axis_tkeep[27]} {tx_axis_tkeep[28]} {tx_axis_tkeep[29]} {tx_axis_tkeep[30]} {tx_axis_tkeep[31]} {tx_axis_tkeep[32]} {tx_axis_tkeep[33]} {tx_axis_tkeep[34]} {tx_axis_tkeep[35]} {tx_axis_tkeep[36]} {tx_axis_tkeep[37]} {tx_axis_tkeep[38]} {tx_axis_tkeep[39]} {tx_axis_tkeep[40]} {tx_axis_tkeep[41]} {tx_axis_tkeep[42]} {tx_axis_tkeep[43]} {tx_axis_tkeep[44]} {tx_axis_tkeep[45]} {tx_axis_tkeep[46]} {tx_axis_tkeep[47]} {tx_axis_tkeep[48]} {tx_axis_tkeep[49]} {tx_axis_tkeep[50]} {tx_axis_tkeep[51]} {tx_axis_tkeep[52]} {tx_axis_tkeep[53]} {tx_axis_tkeep[54]} {tx_axis_tkeep[55]} {tx_axis_tkeep[56]} {tx_axis_tkeep[57]} {tx_axis_tkeep[58]} {tx_axis_tkeep[59]} {tx_axis_tkeep[60]} {tx_axis_tkeep[61]} {tx_axis_tkeep[62]} {tx_axis_tkeep[63]}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe7]
set_property port_width 1 [get_debug_ports u_ila_1/probe7]
connect_debug_port u_ila_1/probe7 [get_nets [list {tx_axis_tlast}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA [get_debug_ports u_ila_1/probe8]
set_property port_width 1 [get_debug_ports u_ila_1/probe8]
connect_debug_port u_ila_1/probe8 [get_nets [list {tx_axis_tready}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe9]
set_property port_width 1 [get_debug_ports u_ila_1/probe9]
connect_debug_port u_ila_1/probe9 [get_nets [list {tx_axis_tvalid}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe10]
set_property port_width 1 [get_debug_ports u_ila_1/probe10]
connect_debug_port u_ila_1/probe10 [get_nets [list {tx_ovfout}]]
create_debug_port u_ila_1 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_1/probe11]
set_property port_width 1 [get_debug_ports u_ila_1/probe11]
connect_debug_port u_ila_1/probe11 [get_nets [list {tx_unfout}]]

set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets txusrclk2]
