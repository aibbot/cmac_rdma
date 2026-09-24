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
    case (index)
      0: mac_byte = mac[47:40];
      1: mac_byte = mac[39:32];
      2: mac_byte = mac[31:24];
      3: mac_byte = mac[23:16];
      4: mac_byte = mac[15:8];
      default: mac_byte = mac[7:0];
    endcase
  endfunction

  function automatic logic [7:0] be16_byte(
    input logic [15:0] value,
    input integer index
  );
    be16_byte = index == 0 ? value[15:8] : value[7:0];
  endfunction

  function automatic logic [7:0] be32_byte(
    input logic [31:0] value,
    input integer index
  );
    case (index)
      0: be32_byte = value[31:24];
      1: be32_byte = value[23:16];
      2: be32_byte = value[15:8];
      default: be32_byte = value[7:0];
    endcase
  endfunction

  function automatic logic [7:0] be64_byte(
    input logic [63:0] value,
    input integer index
  );
    case (index)
      0: be64_byte = value[63:56];
      1: be64_byte = value[55:48];
      2: be64_byte = value[47:40];
      3: be64_byte = value[39:32];
      4: be64_byte = value[31:24];
      5: be64_byte = value[23:16];
      6: be64_byte = value[15:8];
      default: be64_byte = value[7:0];
    endcase
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
    begin
      if (offset < 4) begin
        data_payload_byte = be32_byte(BENCHMARK_MAGIC, offset);
      end else if (offset < 8) begin
        data_payload_byte = be32_byte(packet_context.benchmark_sequence, offset - 4);
      end else if (offset < 10) begin
        data_payload_byte = be16_byte(BENCHMARK_VERSION, offset - 8);
      end else if (offset < 12) begin
        data_payload_byte = be16_byte(BENCHMARK_HEADER_LENGTH, offset - 10);
      end else if (offset < 16) begin
        data_payload_byte = be32_byte(packet_context.payload_length, offset - 12);
      end else if (offset < BENCHMARK_HEADER_LENGTH || fast_mode) begin
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
    case (index)
      0: ipv4_byte = 8'h45;
      1: ipv4_byte = 8'h00;
      2: ipv4_byte = packet_context.ip_total_length[15:8];
      3: ipv4_byte = packet_context.ip_total_length[7:0];
      4: ipv4_byte = packet_context.ip_identification[15:8];
      5: ipv4_byte = packet_context.ip_identification[7:0];
      6: ipv4_byte = 8'h40;
      7: ipv4_byte = 8'h00;
      8: ipv4_byte = 8'd64;
      9: ipv4_byte = 8'd17;
      10: ipv4_byte = packet_context.ip_checksum[15:8];
      11: ipv4_byte = packet_context.ip_checksum[7:0];
      12: ipv4_byte = packet_context.local_ip[31:24];
      13: ipv4_byte = packet_context.local_ip[23:16];
      14: ipv4_byte = packet_context.local_ip[15:8];
      15: ipv4_byte = packet_context.local_ip[7:0];
      16: ipv4_byte = packet_context.remote_ip[31:24];
      17: ipv4_byte = packet_context.remote_ip[23:16];
      18: ipv4_byte = packet_context.remote_ip[15:8];
      default: ipv4_byte = packet_context.remote_ip[7:0];
    endcase
  endfunction

  function automatic logic [7:0] udp_byte(input integer index);
    logic [15:0] source_port;
    begin
      source_port = 16'hC000 | {2'b00, packet_context.local_qpn};
      case (index)
        0: udp_byte = source_port[15:8];
        1: udp_byte = source_port[7:0];
        2: udp_byte = RDMA_ROCE_UDP_PORT[15:8];
        3: udp_byte = RDMA_ROCE_UDP_PORT[7:0];
        4: udp_byte = packet_context.udp_length[15:8];
        5: udp_byte = packet_context.udp_length[7:0];
        default: udp_byte = 8'h00;
      endcase
    end
  endfunction

  function automatic logic [7:0] bth_byte(input integer index);
    case (index)
      0: bth_byte = packet_context.opcode;
      1: bth_byte = 8'h00;
      2, 3: bth_byte = 8'hFF;
      4: bth_byte = 8'h00;
      5: bth_byte = packet_context.remote_qpn[23:16];
      6: bth_byte = packet_context.remote_qpn[15:8];
      7: bth_byte = packet_context.remote_qpn[7:0];
      8: bth_byte = (!fast_mode || packet_context.is_commit) ? 8'h80 : 8'h00;
      9: bth_byte = packet_context.psn[23:16];
      10: bth_byte = packet_context.psn[15:8];
      default: bth_byte = packet_context.psn[7:0];
    endcase
  endfunction

  function automatic logic [7:0] reth_byte(input integer index);
    logic [63:0] address64;
    begin
      address64 = {16'd0, packet_context.remote_address};
      if (index < 8)
        reth_byte = be64_byte(address64, index);
      else if (index < 12)
        reth_byte = be32_byte(packet_context.rkey, index - 8);
      else
        reth_byte = be32_byte(packet_context.work_length, index - 12);
    end
  endfunction

  function automatic logic [7:0] immediate_byte(input integer index);
    immediate_byte = be32_byte(packet_context.commit_sequence[31:0], index);
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
        build_byte = build_region_offset == 16'd0 ? 8'h08 : 8'h00;
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
    logic [15:0] source_port;

    source_port = 16'hC000 | {2'b00, packet_context.local_qpn};
    fast_header_word0 = 512'd0;
    fast_header_word1 = 512'd0;

    fast_header_word0[47:0] = {
      packet_context.remote_mac[7:0], packet_context.remote_mac[15:8],
      packet_context.remote_mac[23:16], packet_context.remote_mac[31:24],
      packet_context.remote_mac[39:32], packet_context.remote_mac[47:40]
    };
    fast_header_word0[95:48] = {
      LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16],
      LOCAL_MAC[31:24], LOCAL_MAC[39:32], LOCAL_MAC[47:40]
    };
    fast_header_word0[103:96] = 8'h08;
    fast_header_word0[111:104] = 8'h00;
    fast_header_word0[119:112] = 8'h45;
    fast_header_word0[127:120] = 8'h00;
    fast_header_word0[135:128] = packet_context.ip_total_length[15:8];
    fast_header_word0[143:136] = packet_context.ip_total_length[7:0];
    fast_header_word0[151:144] = packet_context.ip_identification[15:8];
    fast_header_word0[159:152] = packet_context.ip_identification[7:0];
    fast_header_word0[167:160] = 8'h40;
    fast_header_word0[175:168] = 8'h00;
    fast_header_word0[183:176] = 8'd64;
    fast_header_word0[191:184] = 8'd17;
    fast_header_word0[199:192] = packet_context.ip_checksum[15:8];
    fast_header_word0[207:200] = packet_context.ip_checksum[7:0];
    fast_header_word0[239:208] = {
      packet_context.local_ip[7:0], packet_context.local_ip[15:8],
      packet_context.local_ip[23:16], packet_context.local_ip[31:24]
    };
    fast_header_word0[271:240] = {
      packet_context.remote_ip[7:0], packet_context.remote_ip[15:8],
      packet_context.remote_ip[23:16], packet_context.remote_ip[31:24]
    };
    fast_header_word0[279:272] = source_port[15:8];
    fast_header_word0[287:280] = source_port[7:0];
    fast_header_word0[295:288] = RDMA_ROCE_UDP_PORT[15:8];
    fast_header_word0[303:296] = RDMA_ROCE_UDP_PORT[7:0];
    fast_header_word0[311:304] = packet_context.udp_length[15:8];
    fast_header_word0[319:312] = packet_context.udp_length[7:0];
    fast_header_word0[335:320] = 16'd0;
    fast_header_word0[343:336] = packet_context.opcode;
    fast_header_word0[351:344] = 8'h00;
    fast_header_word0[367:352] = 16'hFFFF;
    fast_header_word0[375:368] = 8'h00;
    fast_header_word0[399:376] = {
      packet_context.remote_qpn[7:0], packet_context.remote_qpn[15:8],
      packet_context.remote_qpn[23:16]
    };
    fast_header_word0[407:400] =
      (fast_mode && !packet_context.is_commit) ? 8'h00 : 8'h80;
    fast_header_word0[431:408] = {
      packet_context.psn[7:0], packet_context.psn[15:8], packet_context.psn[23:16]
    };

    if (packet_context.has_reth) begin
      fast_header_word0[447:432] = 16'd0;
      fast_header_word0[495:448] = {
        packet_context.remote_address[7:0], packet_context.remote_address[15:8],
        packet_context.remote_address[23:16], packet_context.remote_address[31:24],
        packet_context.remote_address[39:32], packet_context.remote_address[47:40]
      };
      fast_header_word0[511:496] = {
        packet_context.rkey[23:16], packet_context.rkey[31:24]
      };
      fast_header_word1[15:0] = {
        packet_context.rkey[7:0], packet_context.rkey[15:8]
      };
      fast_header_word1[47:16] = {
        packet_context.work_length[7:0], packet_context.work_length[15:8],
        packet_context.work_length[23:16], packet_context.work_length[31:24]
      };
      fast_header_word1[79:48] = 32'h4F534652;
      fast_header_word1[111:80] = {
        packet_context.benchmark_sequence[7:0],
        packet_context.benchmark_sequence[15:8],
        packet_context.benchmark_sequence[23:16],
        packet_context.benchmark_sequence[31:24]
      };
      fast_header_word1[127:112] = 16'h0100;
      fast_header_word1[143:128] = 16'h1800;
      fast_header_word1[175:144] = {
        packet_context.payload_length[7:0], packet_context.payload_length[15:8],
        packet_context.payload_length[23:16], packet_context.payload_length[31:24]
      };
    end else begin
      fast_header_word0[463:432] = 32'h4F534652;
      fast_header_word0[495:464] = {
        packet_context.benchmark_sequence[7:0],
        packet_context.benchmark_sequence[15:8],
        packet_context.benchmark_sequence[23:16],
        packet_context.benchmark_sequence[31:24]
      };
      fast_header_word0[511:496] = 16'h0100;
      fast_header_word1[15:0] = 16'h1800;
      fast_header_word1[47:16] = {
        packet_context.payload_length[7:0], packet_context.payload_length[15:8],
        packet_context.payload_length[23:16], packet_context.payload_length[31:24]
      };
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
