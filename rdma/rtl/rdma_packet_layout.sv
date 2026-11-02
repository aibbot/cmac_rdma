`timescale 1ps / 1ps

// Combinational byte layout for Ethernet/RoCEv2 packets. The endpoint keeps
// scheduling and pipeline state; this module owns protocol byte ordering.
module rdma_packet_layout #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
) (
  input  rdma_endpoint_pkg::rdma_packet_context_t packet_context,
  input  logic fast_mode,
  input  rdma_endpoint_pkg::rdma_packet_region_t build_region,
  input  logic [15:0] build_region_offset,
  input  logic [15:0] crc_offset,
  input  logic [31:0] packet_icrc,
  output logic [7:0] build_byte,
  output logic [7:0] crc_byte,
  output logic [511:0] fast_header_word0,
  output logic [511:0] fast_header_word1,
  output logic [399:0] fast_header_word0_masked
);
  import rdma_endpoint_pkg::*;

  localparam logic [31:0] BENCHMARK_MAGIC = 32'h5246_534F;
  localparam logic [15:0] BENCHMARK_VERSION = 16'd1;
  localparam logic [15:0] BENCHMARK_HEADER_LENGTH = 16'd24;
  localparam logic [31:0] COMMIT_MAGIC = 32'h5244_4D41;
  localparam integer COMMIT_PUBLISH_SEQUENCE_OFFSET = 40;

  function automatic logic [7:0] mac_byte(
    input logic [47:0] mac,
    input integer index
  );
    logic [47:0] encoded;
    begin
      encoded = rdma_store_axis_be48(mac);
      mac_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] ethertype_byte(input integer index);
    logic [15:0] encoded;
    begin
      encoded = rdma_store_axis_be16(16'h0800);
      ethertype_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] le32_byte(
    input logic [31:0] value,
    input integer index
  );
    case (index)
      0: le32_byte = value[7:0];
      1: le32_byte = value[15:8];
      2: le32_byte = value[23:16];
      default: le32_byte = value[31:24];
    endcase
  endfunction

  function automatic logic [7:0] le64_byte(
    input logic [63:0] value,
    input integer index
  );
    case (index)
      0: le64_byte = value[7:0];
      1: le64_byte = value[15:8];
      2: le64_byte = value[23:16];
      3: le64_byte = value[31:24];
      4: le64_byte = value[39:32];
      5: le64_byte = value[47:40];
      6: le64_byte = value[55:48];
      default: le64_byte = value[63:56];
    endcase
  endfunction

  function automatic logic [7:0] data_payload_byte(input integer offset);
    logic [63:0] byte_address;
    logic [63:0] word_value;
    rdma_rfso_header_t header;
    logic [191:0] encoded_header;
    begin
      header = '0;
      header.magic = BENCHMARK_MAGIC;
      header.sequence_number = packet_context.benchmark_sequence;
      header.version = BENCHMARK_VERSION;
      header.header_length = BENCHMARK_HEADER_LENGTH;
      header.payload_length = packet_context.payload_length;
      encoded_header = rdma_encode_rfso(header);
      if (offset < BENCHMARK_HEADER_LENGTH) begin
        data_payload_byte = encoded_header[offset * 8 +: 8];
      end else if (fast_mode) begin
        data_payload_byte = 8'd0;
      end else begin
        byte_address = packet_context.local_address + {32'd0, offset};
        word_value = byte_address >> 3;
        case (byte_address[2:0])
          3'd0: data_payload_byte = word_value[7:0];
          3'd1: data_payload_byte = word_value[15:8];
          3'd2: data_payload_byte = word_value[23:16];
          3'd3: data_payload_byte = word_value[31:24];
          3'd4: data_payload_byte = word_value[39:32];
          3'd5: data_payload_byte = word_value[47:40];
          3'd6: data_payload_byte = word_value[55:48];
          default: data_payload_byte = word_value[63:56];
        endcase
      end
    end
  endfunction

  function automatic logic [7:0] commit_payload_byte(input integer offset);
    if (offset < 8) begin
      commit_payload_byte = le64_byte(packet_context.commit_total_bytes, offset);
    end else if (offset < 12) begin
      commit_payload_byte = le32_byte(packet_context.commit_end_offset, offset - 8);
    end else if (offset < 16) begin
      commit_payload_byte = le32_byte(packet_context.commit_interval_bytes, offset - 12);
    end else if (offset < 20) begin
      commit_payload_byte = le32_byte(
        {31'd0, packet_context.commit_final}, offset - 16);
    end else if (offset < 24) begin
      commit_payload_byte = le32_byte(COMMIT_MAGIC, offset - 20);
    end else if (offset >= COMMIT_PUBLISH_SEQUENCE_OFFSET &&
                 offset < COMMIT_PUBLISH_SEQUENCE_OFFSET + 8) begin
      commit_payload_byte = le64_byte(
        packet_context.commit_sequence, offset - COMMIT_PUBLISH_SEQUENCE_OFFSET);
    end else begin
      commit_payload_byte = 8'd0;
    end
  endfunction

  function automatic logic [7:0] payload_byte(input integer offset);
    payload_byte = packet_context.is_commit ? commit_payload_byte(offset) :
                                             data_payload_byte(offset);
  endfunction

  function automatic logic [7:0] ipv4_byte(input integer index);
    rdma_ipv4_header_t header;
    logic [159:0] encoded;
    begin
      header = '0;
      header.version_ihl = 8'h45;
      header.total_length = packet_context.ip_total_length;
      header.identification = packet_context.ip_identification;
      header.flags_fragment = 16'h4000;
      header.ttl = 8'd64;
      header.protocol = 8'd17;
      header.checksum = packet_context.ip_checksum;
      header.source = packet_context.local_ip;
      header.destination = packet_context.remote_ip;
      encoded = rdma_encode_ipv4(header);
      ipv4_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] udp_byte(input integer index);
    logic [15:0] source_port;
    rdma_udp_header_t header;
    logic [63:0] encoded;
    begin
      source_port = 16'hC000 | {2'b00, packet_context.local_qpn};
      header = '0;
      header.source_port = source_port;
      header.destination_port = RDMA_ROCE_UDP_PORT;
      header.length = packet_context.udp_length;
      encoded = rdma_encode_udp(header);
      udp_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] bth_byte(input integer index);
    rdma_bth_t header;
    logic [95:0] encoded;
    begin
      header = '0;
      header.opcode = packet_context.opcode;
      header.pkey = 16'hFFFF;
      header.destination_qpn = packet_context.remote_qpn;
      header.ack_request = (!fast_mode || packet_context.is_commit) ?
                           8'h80 : 8'h00;
      header.psn = packet_context.psn;
      encoded = rdma_encode_bth(header);
      bth_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] reth_byte(input integer index);
    rdma_reth_t header;
    logic [127:0] encoded;
    begin
      header = '0;
      header.virtual_address = {16'd0, packet_context.remote_address};
      header.rkey = packet_context.rkey;
      header.length = packet_context.work_length;
      encoded = rdma_encode_reth(header);
      reth_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] immediate_byte(input integer index);
    logic [31:0] encoded;
    begin
      encoded = rdma_store_axis_be32(packet_context.commit_sequence[31:0]);
      immediate_byte = encoded[index * 8 +: 8];
    end
  endfunction

  function automatic logic [7:0] icrc_actual_byte(input integer index);
    integer payload_start;
    integer immediate_start;
    begin
      immediate_start = 20 + 8 + 12 + (packet_context.has_reth ? 16 : 0);
      payload_start = immediate_start + (packet_context.has_immediate ? 4 : 0);
      if (index < 20)
        icrc_actual_byte = ipv4_byte(index);
      else if (index < 28)
        icrc_actual_byte = udp_byte(index - 20);
      else if (index < 40)
        icrc_actual_byte = bth_byte(index - 28);
      else if (packet_context.has_reth && index < 56)
        icrc_actual_byte = reth_byte(index - 40);
      else if (packet_context.has_immediate && index < immediate_start + 4)
        icrc_actual_byte = immediate_byte(index - immediate_start);
      else
        icrc_actual_byte = payload_byte(index - payload_start);
    end
  endfunction

  function automatic logic [7:0] icrc_masked_byte(input integer index);
    case (index)
      1, 8, 10, 11, 26, 27, 32: icrc_masked_byte = 8'hFF;
      default: icrc_masked_byte = icrc_actual_byte(index);
    endcase
  endfunction

  always_comb begin
    case (build_region)
      RDMA_PACKET_DEST_MAC:
        build_byte = mac_byte(packet_context.remote_mac, build_region_offset);
      RDMA_PACKET_SOURCE_MAC:
        build_byte = mac_byte(LOCAL_MAC, build_region_offset);
      RDMA_PACKET_ETHERTYPE:
        build_byte = ethertype_byte(build_region_offset);
      RDMA_PACKET_IPV4: build_byte = ipv4_byte(build_region_offset);
      RDMA_PACKET_UDP: build_byte = udp_byte(build_region_offset);
      RDMA_PACKET_BTH: build_byte = bth_byte(build_region_offset);
      RDMA_PACKET_RETH: build_byte = reth_byte(build_region_offset);
      RDMA_PACKET_IMMEDIATE: build_byte = immediate_byte(build_region_offset);
      RDMA_PACKET_PAYLOAD: build_byte = payload_byte(build_region_offset);
      default: begin
        case (build_region_offset)
          16'd0: build_byte = packet_icrc[7:0];
          16'd1: build_byte = packet_icrc[15:8];
          16'd2: build_byte = packet_icrc[23:16];
          default: build_byte = packet_icrc[31:24];
        endcase
      end
    endcase
  end

  assign crc_byte = icrc_masked_byte(crc_offset);

  always_comb begin : build_fast_headers
    rdma_ethernet_header_t ethernet_header;
    rdma_ipv4_header_t ipv4_header;
    rdma_udp_header_t udp_header;
    rdma_bth_t bth_header;
    rdma_reth_t reth_header;
    rdma_rfso_header_t rfso_header;
    logic [111:0] encoded_ethernet;
    logic [159:0] encoded_ipv4;
    logic [63:0] encoded_udp;
    logic [95:0] encoded_bth;
    logic [127:0] encoded_reth;
    logic [191:0] encoded_rfso;

    ethernet_header = '0;
    ethernet_header.destination = packet_context.remote_mac;
    ethernet_header.source = LOCAL_MAC;
    ethernet_header.ethertype = 16'h0800;
    encoded_ethernet = rdma_encode_ethernet(ethernet_header);

    ipv4_header = '0;
    ipv4_header.version_ihl = 8'h45;
    ipv4_header.total_length = packet_context.ip_total_length;
    ipv4_header.identification = packet_context.ip_identification;
    ipv4_header.flags_fragment = 16'h4000;
    ipv4_header.ttl = 8'd64;
    ipv4_header.protocol = 8'd17;
    ipv4_header.checksum = packet_context.ip_checksum;
    ipv4_header.source = packet_context.local_ip;
    ipv4_header.destination = packet_context.remote_ip;
    encoded_ipv4 = rdma_encode_ipv4(ipv4_header);

    udp_header = '0;
    udp_header.source_port = 16'hC000 | {2'b00, packet_context.local_qpn};
    udp_header.destination_port = RDMA_ROCE_UDP_PORT;
    udp_header.length = packet_context.udp_length;
    encoded_udp = rdma_encode_udp(udp_header);

    bth_header = '0;
    bth_header.opcode = packet_context.opcode;
    bth_header.pkey = 16'hFFFF;
    bth_header.destination_qpn = packet_context.remote_qpn;
    bth_header.ack_request =
      (fast_mode && !packet_context.is_commit) ? 8'h00 : 8'h80;
    bth_header.psn = packet_context.psn;
    encoded_bth = rdma_encode_bth(bth_header);

    reth_header = '0;
    reth_header.virtual_address = {16'd0, packet_context.remote_address};
    reth_header.rkey = packet_context.rkey;
    reth_header.length = packet_context.work_length;
    encoded_reth = rdma_encode_reth(reth_header);

    rfso_header = '0;
    rfso_header.magic = BENCHMARK_MAGIC;
    rfso_header.sequence_number = packet_context.benchmark_sequence;
    rfso_header.version = BENCHMARK_VERSION;
    rfso_header.header_length = BENCHMARK_HEADER_LENGTH;
    rfso_header.payload_length = packet_context.payload_length;
    encoded_rfso = rdma_encode_rfso(rfso_header);

    fast_header_word0 = 512'd0;
    fast_header_word1 = 512'd0;

    fast_header_word0[0 +: 112] = encoded_ethernet;
    fast_header_word0[112 +: 160] = encoded_ipv4;
    fast_header_word0[272 +: 64] = encoded_udp;
    fast_header_word0[336 +: 96] = encoded_bth;

    if (packet_context.has_reth) begin
      fast_header_word0[432 +: 80] = encoded_reth[0 +: 80];
      fast_header_word1[0 +: 48] = encoded_reth[80 +: 48];
      fast_header_word1[48 +: 192] = encoded_rfso;
    end else begin
      fast_header_word0[432 +: 80] = encoded_rfso[0 +: 80];
      fast_header_word1[0 +: 112] = encoded_rfso[80 +: 112];
    end

    fast_header_word0_masked = fast_header_word0[511:112];
    fast_header_word0_masked[15:8] = 8'hFF;
    fast_header_word0_masked[71:64] = 8'hFF;
    fast_header_word0_masked[87:80] = 8'hFF;
    fast_header_word0_masked[95:88] = 8'hFF;
    fast_header_word0_masked[215:208] = 8'hFF;
    fast_header_word0_masked[223:216] = 8'hFF;
    fast_header_word0_masked[263:256] = 8'hFF;
  end
endmodule
