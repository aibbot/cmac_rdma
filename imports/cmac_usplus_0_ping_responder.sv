`timescale 1ps / 1ps

import cmac_usplus_0_network_types_pkg::*;

// CMAC network endpoint wrapper. The module name and ports remain compatible
// with the vendor example-design top level.
module cmac_usplus_0_ping_responder #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
) (
  input logic        clk,
  input logic        reset,
  input logic [31:0] local_ip,

  input logic         rx_axis_tvalid,
  input logic [511:0] rx_axis_tdata,
  input logic         rx_axis_tlast,
  input logic [ 63:0] rx_axis_tkeep,
  input logic         rx_axis_tuser,

  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic         tx_axis_tlast,
  output logic [ 63:0] tx_axis_tkeep,
  output logic         tx_axis_tuser
);

`ifdef CMAC_RDMA_BUILD

  // The RDMA implementation is isolated behind the dedicated source-set
  // define. The legacy UDP/ARP/ICMP build below remains untouched when the
  // define is absent.
  rdma_board_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(32'hC0A8_110B)
  ) i_rdma_board_endpoint (
    .cmac_clk      (clk),
    .cmac_reset    (reset),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tdata (rx_axis_tdata),
    .rx_axis_tkeep (rx_axis_tkeep),
    .rx_axis_tlast (rx_axis_tlast),
    .rx_axis_tuser (rx_axis_tuser),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tdata (tx_axis_tdata),
    .tx_axis_tkeep (tx_axis_tkeep),
    .tx_axis_tlast (tx_axis_tlast),
    .tx_axis_tuser (tx_axis_tuser)
  );

`else

  localparam integer UDP_STREAM_COUNT = 4;

  logic                                                udp_enable;
  logic                                                udp_enable_q;
  logic                                                udp_counter_reset;
  logic                  [                15:0]        udp_payload_length;
  logic                  [                31:0]        udp_gap_cycles;
  logic                  [                 3:0]        udp_stream_mask;
  logic                  [                 3:0]        udp_stream_mask_q;
  logic                  [                47:0]        udp_vio_destination_mac;
  logic                  [                31:0]        udp_vio_destination_ip;
  logic                  [                15:0]        udp_source_port;
  logic                  [                15:0]        udp_destination_port;
  logic                  [                31:0]        udp_packet_count;
  logic                  [                39:0]        udp_tx_rate_bytes_per_second;
  logic                  [                31:0]        udp_tx_local_drop_count;
  logic                  [UDP_STREAM_COUNT-1:0][ 31:0] udp_packet_count_per_stream;
  logic                  [UDP_STREAM_COUNT-1:0][ 39:0] udp_tx_rate_per_stream;
  logic                  [UDP_STREAM_COUNT-1:0][ 31:0] udp_tx_local_drop_per_stream;

  logic                                                arp_sender_update;
  logic                                                arp_sender_update_q;
  logic                                                arp_destination_update_q;
  logic                  [                47:0]        arp_sender_mac;
  logic                  [                31:0]        arp_sender_ip;
  logic                  [                47:0]        arp_sender_mac_q;
  logic                  [                31:0]        arp_sender_ip_q;
  logic                                                arp_destination_valid;
  logic                  [                47:0]        arp_destination_mac;
  logic                  [                31:0]        arp_destination_ip;
  wire                   [                47:0]        udp_effective_destination_mac;
  wire                   [                31:0]        udp_effective_destination_ip;

  logic                                                reply_tx_axis_tready;
  logic                                                reply_tx_axis_tvalid;
  logic                  [               511:0]        reply_tx_axis_tdata;
  logic                                                reply_tx_axis_tlast;
  logic                  [                63:0]        reply_tx_axis_tkeep;
  logic                                                reply_tx_axis_tuser;

  logic                  [UDP_STREAM_COUNT-1:0]        udp_tx_axis_tready;
  logic                  [UDP_STREAM_COUNT-1:0]        udp_tx_axis_tvalid;
  logic                  [UDP_STREAM_COUNT-1:0][511:0] udp_tx_axis_tdata;
  logic                  [UDP_STREAM_COUNT-1:0]        udp_tx_axis_tlast;
  logic                  [UDP_STREAM_COUNT-1:0][ 63:0] udp_tx_axis_tkeep;
  logic                  [UDP_STREAM_COUNT-1:0]        udp_tx_axis_tuser;
  logic                  [UDP_STREAM_COUNT-1:0]        udp_axis_enable;
  logic                                                udp_descriptor_valid;
  udp_frame_descriptor_t                               udp_descriptor;
  integer                                              udp_stream_index;

  udp_benchmark_vio i_udp_benchmark_vio (
    .clk       (clk),
    .probe_in0 (udp_packet_count),
    .probe_in1 (udp_tx_rate_bytes_per_second),
    .probe_in2 (udp_tx_local_drop_count),
    .probe_out0(udp_enable),
    .probe_out1(udp_counter_reset),
    .probe_out2(udp_payload_length),
    .probe_out3(udp_gap_cycles),
    .probe_out4(udp_vio_destination_mac),
    .probe_out5(udp_vio_destination_ip),
    .probe_out6(udp_source_port),
    .probe_out7(udp_destination_port),
    .probe_out8(udp_stream_mask)
  );

  // Keep the VIO settings as the startup fallback. A complete ARP frame
  // directed at this endpoint replaces both UDP destination fields together.
  always_ff @(posedge clk) begin
    if (reset) begin
      arp_sender_update_q      <= 1'b0;
      arp_destination_update_q <= 1'b0;
      arp_sender_mac_q         <= 48'd0;
      arp_sender_ip_q          <= 32'd0;
      arp_destination_valid    <= 1'b0;
      arp_destination_mac      <= 48'd0;
      arp_destination_ip       <= 32'd0;
    end else begin
      // Stage the decoded pair before it fans out to all generators.
      // The trailing pulse blocks the clock boundary where the new
      // destination becomes visible to every UDP generator.
      arp_sender_update_q      <= arp_sender_update;
      arp_destination_update_q <= arp_sender_update_q;
      if (arp_sender_update) begin
        arp_sender_mac_q <= arp_sender_mac;
        arp_sender_ip_q  <= arp_sender_ip;
      end
      if (arp_sender_update_q) begin
        arp_destination_valid <= 1'b1;
        arp_destination_mac   <= arp_sender_mac_q;
        arp_destination_ip    <= arp_sender_ip_q;
      end
    end
  end

  // Keep ARP parsing out of the UDP control timing path. The generator
  // discards an unstarted preloaded frame when this registered value changes.
  assign udp_effective_destination_mac = arp_destination_valid ?
    arp_destination_mac : udp_vio_destination_mac;
  assign udp_effective_destination_ip = arp_destination_valid ?
    arp_destination_ip : udp_vio_destination_ip;
  // Four UDP streams are permanently present. Register the VIO controls so
  // the generators and arbiter observe one common frame-boundary decision.
  always_ff @(posedge clk) begin
    if (reset) begin
      udp_enable_q      <= 1'b0;
      udp_stream_mask_q <= 4'd0;
    end else begin
      udp_enable_q      <= udp_enable;
      udp_stream_mask_q <= udp_stream_mask;
    end
  end

  assign udp_axis_enable = {UDP_STREAM_COUNT{udp_enable_q}} & udp_stream_mask_q;

  always_comb begin
    udp_packet_count             = 32'd0;
    udp_tx_rate_bytes_per_second = 40'd0;
    udp_tx_local_drop_count      = 32'd0;
    for (udp_stream_index = 0; udp_stream_index < UDP_STREAM_COUNT; udp_stream_index = udp_stream_index + 1) begin
      udp_packet_count             = udp_packet_count + udp_packet_count_per_stream[udp_stream_index];
      udp_tx_rate_bytes_per_second = udp_tx_rate_bytes_per_second + udp_tx_rate_per_stream[udp_stream_index];
      udp_tx_local_drop_count      = udp_tx_local_drop_count + udp_tx_local_drop_per_stream[udp_stream_index];
    end
  end

  cmac_usplus_0_ping_reply_engine #(
    .LOCAL_MAC(LOCAL_MAC)
  ) i_ping_reply_engine (
    .clk              (clk),
    .reset            (reset),
    .local_ip         (local_ip),
    .rx_axis_tvalid   (rx_axis_tvalid),
    .rx_axis_tdata    (rx_axis_tdata),
    .rx_axis_tlast    (rx_axis_tlast),
    .rx_axis_tkeep    (rx_axis_tkeep),
    .rx_axis_tuser    (rx_axis_tuser),
    .arp_sender_update(arp_sender_update),
    .arp_sender_mac   (arp_sender_mac),
    .arp_sender_ip    (arp_sender_ip),
    .tx_axis_tready   (reply_tx_axis_tready),
    .tx_axis_tvalid   (reply_tx_axis_tvalid),
    .tx_axis_tdata    (reply_tx_axis_tdata),
    .tx_axis_tlast    (reply_tx_axis_tlast),
    .tx_axis_tkeep    (reply_tx_axis_tkeep),
    .tx_axis_tuser    (reply_tx_axis_tuser)
  );

  // The VIO and learned-ARP fields are identical for every stream. Prepare
  // the checksum and frame descriptor once, then snapshot it per flow only
  // when that flow starts a frame.
  cmac_usplus_0_udp_config_pipeline i_udp_config_pipeline (
    .clk             (clk),
    .reset           (reset),
    .local_ip        (local_ip),
    .destination_mac (udp_effective_destination_mac),
    .destination_ip  (udp_effective_destination_ip),
    .source_port     (udp_source_port),
    .destination_port(udp_destination_port),
    .payload_length  (udp_payload_length),
    .gap_cycles      (udp_gap_cycles),
    .descriptor_valid(udp_descriptor_valid),
    .descriptor      (udp_descriptor)
  );

  genvar udp_benchmark_index;
  generate
    for (udp_benchmark_index = 0;
         udp_benchmark_index < UDP_STREAM_COUNT;
         udp_benchmark_index = udp_benchmark_index + 1) begin : g_udp_benchmark
      localparam logic [15:0] DESTINATION_PORT_OFFSET = udp_benchmark_index;

      cmac_usplus_0_udp_benchmark_core #(
        .LOCAL_MAC(LOCAL_MAC),
        .DESTINATION_PORT_OFFSET(DESTINATION_PORT_OFFSET)
      ) i_udp_benchmark (
        .clk                     (clk),
        .reset                   (reset),
        .enable                  (udp_enable_q && udp_stream_mask_q[udp_benchmark_index]),
        .counter_reset           (udp_counter_reset),
        .frame_start_inhibit     (arp_sender_update_q || arp_destination_update_q),
        .descriptor_valid        (udp_descriptor_valid),
        .descriptor              (udp_descriptor),
        .tx_axis_tready          (udp_tx_axis_tready[udp_benchmark_index]),
        .tx_axis_tvalid          (udp_tx_axis_tvalid[udp_benchmark_index]),
        .tx_axis_tdata           (udp_tx_axis_tdata[udp_benchmark_index]),
        .tx_axis_tlast           (udp_tx_axis_tlast[udp_benchmark_index]),
        .tx_axis_tkeep           (udp_tx_axis_tkeep[udp_benchmark_index]),
        .tx_axis_tuser           (udp_tx_axis_tuser[udp_benchmark_index]),
        .packet_count            (udp_packet_count_per_stream[udp_benchmark_index]),
        .tx_rate_bytes_per_second(udp_tx_rate_per_stream[udp_benchmark_index]),
        .tx_local_drop_count     (udp_tx_local_drop_per_stream[udp_benchmark_index])
      );
    end
  endgenerate

  cmac_usplus_0_tx_packet_arbiter i_tx_packet_arbiter (
    .clk               (clk),
    .reset             (reset),
    .reply_axis_tready (reply_tx_axis_tready),
    .reply_axis_tvalid (reply_tx_axis_tvalid),
    .reply_axis_tdata  (reply_tx_axis_tdata),
    .reply_axis_tlast  (reply_tx_axis_tlast),
    .reply_axis_tkeep  (reply_tx_axis_tkeep),
    .reply_axis_tuser  (reply_tx_axis_tuser),
    .reply_pending     (rx_axis_tvalid || reply_tx_axis_tvalid),
    .udp_config_inhibit(arp_sender_update_q || arp_destination_update_q),
    .udp_axis_enable   (udp_axis_enable),
    .udp_axis_tready   (udp_tx_axis_tready),
    .udp_axis_tvalid   (udp_tx_axis_tvalid),
    .udp_axis_tdata    (udp_tx_axis_tdata),
    .udp_axis_tlast    (udp_tx_axis_tlast),
    .udp_axis_tkeep    (udp_tx_axis_tkeep),
    .udp_axis_tuser    (udp_tx_axis_tuser),
    .tx_axis_tready    (tx_axis_tready),
    .tx_axis_tvalid    (tx_axis_tvalid),
    .tx_axis_tdata     (tx_axis_tdata),
    .tx_axis_tlast     (tx_axis_tlast),
    .tx_axis_tkeep     (tx_axis_tkeep),
    .tx_axis_tuser     (tx_axis_tuser)
  );

`endif

endmodule
