`timescale 1ps / 1ps

package rdma_endpoint_pkg;
  localparam logic [7:0] RDMA_RC_ACK = 8'h11;
  localparam logic [15:0] RDMA_ROCE_UDP_PORT = 16'd4791;
  localparam logic [31:0] RDMA_ICRC_INIT = 32'hDEBB_20E3;

  // Numeric views of the fixed RoCEv2 fields.  Packet builders and receivers
  // convert these structures to/from AXI byte lanes only at the boundary.
  typedef struct packed {
    logic [47:0] destination;
    logic [47:0] source;
    logic [15:0] ethertype;
  } rdma_ethernet_header_t;

  typedef struct packed {
    logic [7:0] version_ihl;
    logic [7:0] dscp_ecn;
    logic [15:0] total_length;
    logic [15:0] identification;
    logic [15:0] flags_fragment;
    logic [7:0] ttl;
    logic [7:0] protocol;
    logic [15:0] checksum;
    logic [31:0] source;
    logic [31:0] destination;
  } rdma_ipv4_header_t;

  typedef struct packed {
    logic [15:0] source_port;
    logic [15:0] destination_port;
    logic [15:0] length;
    logic [15:0] checksum;
  } rdma_udp_header_t;

  typedef struct packed {
    logic [7:0] opcode;
    logic [7:0] flags;
    logic [15:0] pkey;
    logic [7:0] reserved;
    logic [23:0] destination_qpn;
    logic [7:0] ack_request;
    logic [23:0] psn;
  } rdma_bth_t;

  typedef struct packed {
    logic [63:0] virtual_address;
    logic [31:0] rkey;
    logic [31:0] length;
  } rdma_reth_t;

  typedef struct packed {
    logic [23:0] psn;
    logic [7:0] syndrome;
  } rdma_ack_payload_t;

  typedef struct packed {
    logic [31:0] magic;
    logic [31:0] sequence_number;
    logic [15:0] version;
    logic [15:0] header_length;
    logic [31:0] payload_length;
    logic [63:0] reserved;
  } rdma_rfso_header_t;

  typedef struct packed {
    logic [47:0] remote_mac;
    logic [31:0] local_ip;
    logic [31:0] remote_ip;
    logic [23:0] remote_qpn;
    logic [23:0] initial_psn;
    logic [47:0] remote_base;
    logic [31:0] rkey;
    logic [31:0] ring_size;
    logic [31:0] wr_size;
    logic [63:0] local_base;
    logic enable_immediate;
    logic [31:0] notify_interval_bytes;
    logic [47:0] commit_remote_addr;
    logic use_external_payload;
  } rdma_endpoint_config_t;

  // AXI byte zero is carried in the low byte of a vector.  Keep all network
  // byte-order handling in these boundary helpers so packet users assign
  // numeric fields directly on the protocol structs.
  function automatic logic [15:0] rdma_store_axis_be16(
    input logic [15:0] value
  );
    rdma_store_axis_be16 = {value[7:0], value[15:8]};
  endfunction

  function automatic logic [23:0] rdma_store_axis_be24(
    input logic [23:0] value
  );
    rdma_store_axis_be24 = {
      value[7:0], value[15:8], value[23:16]};
  endfunction

  function automatic logic [31:0] rdma_store_axis_be32(
    input logic [31:0] value
  );
    rdma_store_axis_be32 = {
      value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  function automatic logic [47:0] rdma_store_axis_be48(
    input logic [47:0] value
  );
    rdma_store_axis_be48 = {
      value[7:0], value[15:8], value[23:16],
      value[31:24], value[39:32], value[47:40]};
  endfunction

  function automatic logic [63:0] rdma_store_axis_be64(
    input logic [63:0] value
  );
    rdma_store_axis_be64 = {
      value[7:0], value[15:8], value[23:16], value[31:24],
      value[39:32], value[47:40], value[55:48], value[63:56]};
  endfunction

  function automatic logic [7:0] rdma_load_axis_byte(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_byte = frame[index * 8 +: 8];
  endfunction

  function automatic logic [15:0] rdma_load_axis_be16(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_be16 = {
      rdma_load_axis_byte(frame, index),
      rdma_load_axis_byte(frame, index + 1)};
  endfunction

  function automatic logic [23:0] rdma_load_axis_be24(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_be24 = {
      rdma_load_axis_byte(frame, index),
      rdma_load_axis_byte(frame, index + 1),
      rdma_load_axis_byte(frame, index + 2)};
  endfunction

  function automatic logic [31:0] rdma_load_axis_be32(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_be32 = {
      rdma_load_axis_byte(frame, index),
      rdma_load_axis_byte(frame, index + 1),
      rdma_load_axis_byte(frame, index + 2),
      rdma_load_axis_byte(frame, index + 3)};
  endfunction

  function automatic logic [47:0] rdma_load_axis_be48(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_be48 = {
      rdma_load_axis_byte(frame, index),
      rdma_load_axis_byte(frame, index + 1),
      rdma_load_axis_byte(frame, index + 2),
      rdma_load_axis_byte(frame, index + 3),
      rdma_load_axis_byte(frame, index + 4),
      rdma_load_axis_byte(frame, index + 5)};
  endfunction

  function automatic logic [63:0] rdma_load_axis_be64(
    input logic [511:0] frame,
    input integer index
  );
    rdma_load_axis_be64 = {
      rdma_load_axis_byte(frame, index),
      rdma_load_axis_byte(frame, index + 1),
      rdma_load_axis_byte(frame, index + 2),
      rdma_load_axis_byte(frame, index + 3),
      rdma_load_axis_byte(frame, index + 4),
      rdma_load_axis_byte(frame, index + 5),
      rdma_load_axis_byte(frame, index + 6),
      rdma_load_axis_byte(frame, index + 7)};
  endfunction

  function automatic logic [111:0] rdma_encode_ethernet(
    input rdma_ethernet_header_t header
  );
    logic [111:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 48] = rdma_store_axis_be48(header.destination);
      encoded[48 +: 48] = rdma_store_axis_be48(header.source);
      encoded[96 +: 16] = rdma_store_axis_be16(header.ethertype);
      rdma_encode_ethernet = encoded;
    end
  endfunction

  function automatic logic [159:0] rdma_encode_ipv4(
    input rdma_ipv4_header_t header
  );
    logic [159:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 8] = header.version_ihl;
      encoded[8 +: 8] = header.dscp_ecn;
      encoded[16 +: 16] = rdma_store_axis_be16(header.total_length);
      encoded[32 +: 16] = rdma_store_axis_be16(header.identification);
      encoded[48 +: 16] = rdma_store_axis_be16(header.flags_fragment);
      encoded[64 +: 8] = header.ttl;
      encoded[72 +: 8] = header.protocol;
      encoded[80 +: 16] = rdma_store_axis_be16(header.checksum);
      encoded[96 +: 32] = rdma_store_axis_be32(header.source);
      encoded[128 +: 32] = rdma_store_axis_be32(header.destination);
      rdma_encode_ipv4 = encoded;
    end
  endfunction

  function automatic logic [63:0] rdma_encode_udp(
    input rdma_udp_header_t header
  );
    logic [63:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 16] = rdma_store_axis_be16(header.source_port);
      encoded[16 +: 16] = rdma_store_axis_be16(header.destination_port);
      encoded[32 +: 16] = rdma_store_axis_be16(header.length);
      encoded[48 +: 16] = rdma_store_axis_be16(header.checksum);
      rdma_encode_udp = encoded;
    end
  endfunction

  function automatic logic [95:0] rdma_encode_bth(
    input rdma_bth_t header
  );
    logic [95:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 8] = header.opcode;
      encoded[8 +: 8] = header.flags;
      encoded[16 +: 16] = rdma_store_axis_be16(header.pkey);
      encoded[32 +: 8] = header.reserved;
      encoded[40 +: 24] = rdma_store_axis_be24(header.destination_qpn);
      encoded[64 +: 8] = header.ack_request;
      encoded[72 +: 24] = rdma_store_axis_be24(header.psn);
      rdma_encode_bth = encoded;
    end
  endfunction

  function automatic logic [127:0] rdma_encode_reth(
    input rdma_reth_t header
  );
    logic [127:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 64] = rdma_store_axis_be64(header.virtual_address);
      encoded[64 +: 32] = rdma_store_axis_be32(header.rkey);
      encoded[96 +: 32] = rdma_store_axis_be32(header.length);
      rdma_encode_reth = encoded;
    end
  endfunction

  function automatic logic [191:0] rdma_encode_rfso(
    input rdma_rfso_header_t header
  );
    logic [191:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 32] = rdma_store_axis_be32(header.magic);
      encoded[32 +: 32] = rdma_store_axis_be32(header.sequence_number);
      encoded[64 +: 16] = rdma_store_axis_be16(header.version);
      encoded[80 +: 16] = rdma_store_axis_be16(header.header_length);
      encoded[96 +: 32] = rdma_store_axis_be32(header.payload_length);
      encoded[128 +: 64] = rdma_store_axis_be64(header.reserved);
      rdma_encode_rfso = encoded;
    end
  endfunction

  function automatic rdma_ethernet_header_t rdma_decode_ethernet(
    input logic [511:0] frame,
    input integer offset
  );
    rdma_ethernet_header_t decoded;
    begin
      decoded.destination = rdma_load_axis_be48(frame, offset);
      decoded.source = rdma_load_axis_be48(frame, offset + 6);
      decoded.ethertype = rdma_load_axis_be16(frame, offset + 12);
      rdma_decode_ethernet = decoded;
    end
  endfunction

  function automatic rdma_ipv4_header_t rdma_decode_ipv4(
    input logic [511:0] frame,
    input integer offset
  );
    rdma_ipv4_header_t decoded;
    begin
      decoded.version_ihl = rdma_load_axis_byte(frame, offset);
      decoded.dscp_ecn = rdma_load_axis_byte(frame, offset + 1);
      decoded.total_length = rdma_load_axis_be16(frame, offset + 2);
      decoded.identification = rdma_load_axis_be16(frame, offset + 4);
      decoded.flags_fragment = rdma_load_axis_be16(frame, offset + 6);
      decoded.ttl = rdma_load_axis_byte(frame, offset + 8);
      decoded.protocol = rdma_load_axis_byte(frame, offset + 9);
      decoded.checksum = rdma_load_axis_be16(frame, offset + 10);
      decoded.source = rdma_load_axis_be32(frame, offset + 12);
      decoded.destination = rdma_load_axis_be32(frame, offset + 16);
      rdma_decode_ipv4 = decoded;
    end
  endfunction

  function automatic rdma_udp_header_t rdma_decode_udp(
    input logic [511:0] frame,
    input integer offset
  );
    rdma_udp_header_t decoded;
    begin
      decoded.source_port = rdma_load_axis_be16(frame, offset);
      decoded.destination_port = rdma_load_axis_be16(frame, offset + 2);
      decoded.length = rdma_load_axis_be16(frame, offset + 4);
      decoded.checksum = rdma_load_axis_be16(frame, offset + 6);
      rdma_decode_udp = decoded;
    end
  endfunction

  function automatic rdma_bth_t rdma_decode_bth(
    input logic [511:0] frame,
    input integer offset
  );
    rdma_bth_t decoded;
    begin
      decoded.opcode = rdma_load_axis_byte(frame, offset);
      decoded.flags = rdma_load_axis_byte(frame, offset + 1);
      decoded.pkey = rdma_load_axis_be16(frame, offset + 2);
      decoded.reserved = rdma_load_axis_byte(frame, offset + 4);
      decoded.destination_qpn = rdma_load_axis_be24(frame, offset + 5);
      decoded.ack_request = rdma_load_axis_byte(frame, offset + 8);
      decoded.psn = rdma_load_axis_be24(frame, offset + 9);
      rdma_decode_bth = decoded;
    end
  endfunction

  function automatic rdma_ack_payload_t rdma_decode_ack(
    input logic [511:0] frame,
    input integer bth_offset
  );
    rdma_ack_payload_t decoded;
    begin
      decoded.psn = rdma_load_axis_be24(frame, bth_offset + 9);
      decoded.syndrome = rdma_load_axis_byte(frame, bth_offset + 12);
      rdma_decode_ack = decoded;
    end
  endfunction

  typedef enum logic [3:0] {
    RDMA_PACKET_DEST_MAC,
    RDMA_PACKET_SOURCE_MAC,
    RDMA_PACKET_ETHERTYPE,
    RDMA_PACKET_IPV4,
    RDMA_PACKET_UDP,
    RDMA_PACKET_BTH,
    RDMA_PACKET_RETH,
    RDMA_PACKET_IMMEDIATE,
    RDMA_PACKET_PAYLOAD,
    RDMA_PACKET_ICRC
  } rdma_packet_region_t;

  typedef struct packed {
    logic [47:0] remote_mac;
    logic [31:0] local_ip;
    logic [31:0] remote_ip;
    logic [13:0] local_qpn;
    logic [23:0] remote_qpn;
    logic [31:0] rkey;
    logic        is_commit;
    logic [7:0]  opcode;
    logic        has_reth;
    logic        has_immediate;
    logic [31:0] payload_length;
    logic [31:0] work_length;
    logic [63:0] local_address;
    logic [47:0] remote_address;
    logic [23:0] psn;
    logic [31:0] benchmark_sequence;
    logic [63:0] commit_total_bytes;
    logic [31:0] commit_end_offset;
    logic [31:0] commit_interval_bytes;
    logic [63:0] commit_sequence;
    logic        commit_final;
    logic [15:0] ip_identification;
    logic [15:0] ip_checksum;
    logic [15:0] udp_length;
    logic [15:0] ip_total_length;
  } rdma_packet_context_t;

  typedef struct packed {
    logic        valid;
    logic [23:0] psn;
    logic [31:0] ring_offset;
    logic [63:0] local_address;
    logic [31:0] data_sequence;
    logic [31:0] interval_bytes;
    logic [31:0] logical_remaining;
    logic [31:0] work_length;
  } rdma_recovery_checkpoint_t;

  typedef struct packed {
    logic [23:0] psn;
    logic [23:0] packet_index;
    logic [31:0] byte_offset;
    logic [31:0] replay_bytes;
  } rdma_recovery_action_t;
endpackage
