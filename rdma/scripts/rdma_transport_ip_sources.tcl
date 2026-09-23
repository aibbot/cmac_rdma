# Authoritative ordered source list for packaging and OOC verification.
proc rdma_transport_ip_source_names {} {
  return [list \
    rdma_reset_sync.sv \
    rdma_endpoint_pkg.sv \
    rdma_config_manager.sv \
    rdma_ack_receiver.sv \
    rdma_crc32_parallel.sv \
    rdma_external_packet_builder.sv \
    rdma_replay_buffer.sv \
    rdma_payload_buffer.sv \
    rdma_endpoint.sv \
    rdma_transport_core.sv \
    rdma_transport_ip.sv]
}

proc rdma_transport_ip_source_files {rtl_dir} {
  set source_files [list]
  foreach source_name [rdma_transport_ip_source_names] {
    lappend source_files [file join $rtl_dir $source_name]
  }
  return $source_files
}
