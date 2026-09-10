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
  cmac_usplus_0_rdma_board_endpoint #(
    .LOCAL_MAC(LOCAL_MAC)
  ) i_cmac_usplus_0_rdma_board_endpoint (
    .cmac_clk      (clk),
    .cmac_reset    (reset),
    .local_ip      (local_ip),
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
  assign udp_effective_destination_mac = arp_destination_valid ? arp_destination_mac : udp_vio_destination_mac;
  assign udp_effective_destination_ip  = arp_destination_valid ? arp_destination_ip : udp_vio_destination_ip;
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
    for (udp_benchmark_index = 0; udp_benchmark_index < UDP_STREAM_COUNT; udp_benchmark_index = udp_benchmark_index + 1) begin : g_udp_benchmark
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

// Reply-priority AXI-Stream arbiter for four independently generated UDP
// streams. Each ingress owns a one-beat elastic buffer before arbitration.
// Its tready comes only from registered local capacity, not from the CMAC
// output-ready path, while a queued beat can be consumed and replaced every
// clock.
// A VIO enable update may discard buffered beats, which intentionally permits
// an in-flight frame to be interrupted.
module cmac_usplus_0_tx_packet_arbiter (
  input logic clk,
  input logic reset,

  output logic         reply_axis_tready,
  input  logic         reply_axis_tvalid,
  input  logic [511:0] reply_axis_tdata,
  input  logic         reply_axis_tlast,
  input  logic [ 63:0] reply_axis_tkeep,
  input  logic         reply_axis_tuser,
  input  logic         reply_pending,
  input  logic         udp_config_inhibit,

  input  logic [3:0]        udp_axis_enable,
  output logic [3:0]        udp_axis_tready,
  input  logic [3:0]        udp_axis_tvalid,
  input  logic [3:0][511:0] udp_axis_tdata,
  input  logic [3:0]        udp_axis_tlast,
  input  logic [3:0][ 63:0] udp_axis_tkeep,
  input  logic [3:0]        udp_axis_tuser,

  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic         tx_axis_tlast,
  output logic [ 63:0] tx_axis_tkeep,
  output logic         tx_axis_tuser
);

  localparam logic [2:0] SEL_IDLE = 3'd0;
  localparam logic [2:0] SEL_REPLY = 3'd1;
  localparam logic [2:0] SEL_UDP0 = 3'd2;
  localparam logic [2:0] SEL_UDP3 = 3'd5;

  logic   [  2:0]        frame_selection_q;
  logic   [  1:0]        udp_next_q;
  logic   [  3:0]        udp_axis_enable_q;
  logic                  idle_udp_grant_valid_q;
  (* max_fanout = 64 *)logic   [  1:0]        idle_udp_grant_index_q;
  logic                  reply_buffer_valid_q;
  logic   [511:0]        reply_buffer_data_q;
  logic                  reply_buffer_last_q;
  logic   [ 63:0]        reply_buffer_keep_q;
  logic                  reply_buffer_user_q;
  // One elastic beat per source is sufficient because a selected source can
  // dequeue and refill in one clock. Holding unselected sources at their
  // AXI boundary removes four redundant 512-bit FIFO entries.
  logic   [  3:0]        udp_buffer_valid_q;
  logic   [  3:0][511:0] udp_buffer_data_q;
  logic   [  3:0]        udp_buffer_last_q;
  logic   [  3:0][ 63:0] udp_buffer_keep_q;
  logic   [  3:0]        udp_buffer_user_q;

  logic                  output_valid_q;
  logic   [511:0]        output_data_q;
  logic                  output_last_q;
  logic   [ 63:0]        output_keep_q;
  logic                  output_user_q;

  logic   [  2:0]        selected_selection;
  logic   [  1:0]        selected_udp_index;
  logic                  selected_valid;
  logic   [511:0]        selected_data;
  logic                  selected_last;
  logic   [ 63:0]        selected_keep;
  logic                  selected_user;
  logic                  output_pop;
  logic                  output_has_space;
  logic                  output_load;
  logic                  reply_buffer_pop;
  logic   [  3:0]        udp_buffer_pop;
  logic   [  3:0]        udp_buffer_push;
  logic                  idle_udp_pick_valid;
  logic   [  1:0]        idle_udp_pick_index;
  integer                grant_scan_offset;
  integer                grant_scan_index;
  integer                scan_index;
  integer                udp_buffer_index;

  function automatic logic [1:0] next_udp_index(input logic [1:0] stream_index);
    begin
      if (stream_index == 2'd3) next_udp_index = 2'd0;
      else next_udp_index = stream_index + 1'b1;
    end
  endfunction

  function automatic logic selection_enabled(input logic [2:0] selection);
    begin
      case (selection)
        SEL_UDP0: selection_enabled = udp_axis_enable_q[0];
        3'd3:     selection_enabled = udp_axis_enable_q[1];
        3'd4:     selection_enabled = udp_axis_enable_q[2];
        SEL_UDP3: selection_enabled = udp_axis_enable_q[3];
        default:  selection_enabled = 1'b1;
      endcase
    end
  endfunction

  // Compute the next frame grant independently of the wide data mux.  The
  // registered result keeps round-robin control routing off the first-beat
  // data path into output_data_q.
  always_comb begin
    idle_udp_pick_valid = 1'b0;
    idle_udp_pick_index = 2'd0;
    if ((frame_selection_q == SEL_IDLE) && !reply_buffer_valid_q && !reply_pending && !idle_udp_grant_valid_q) begin
      for (grant_scan_offset = 0; grant_scan_offset < 4; grant_scan_offset = grant_scan_offset + 1) begin
        grant_scan_index = udp_next_q + grant_scan_offset;
        if (grant_scan_index >= 4) grant_scan_index = grant_scan_index - 4;
        if (!idle_udp_pick_valid && udp_axis_enable_q[grant_scan_index] && udp_buffer_valid_q[grant_scan_index]) begin
          idle_udp_pick_valid = 1'b1;
          idle_udp_pick_index = grant_scan_index;
        end
      end
    end
  end

  always_comb begin
    selected_selection = SEL_IDLE;
    selected_udp_index = 2'd0;
    selected_valid     = 1'b0;
    selected_data      = 512'd0;
    selected_last      = 1'b0;
    selected_keep      = 64'd0;
    selected_user      = 1'b0;

    // Continue a stored frame before selecting another source. If VIO
    // disabled that stream, omit its remaining buffered data instead.
    if (frame_selection_q == SEL_REPLY) begin
      if (reply_buffer_valid_q) begin
        selected_selection = SEL_REPLY;
        selected_valid     = 1'b1;
        selected_data      = reply_buffer_data_q;
        selected_last      = reply_buffer_last_q;
        selected_keep      = reply_buffer_keep_q;
        selected_user      = reply_buffer_user_q;
      end
    end else if ((frame_selection_q >= SEL_UDP0) && (frame_selection_q <= SEL_UDP3)) begin
      selected_udp_index = frame_selection_q - SEL_UDP0;
      if (udp_axis_enable_q[selected_udp_index] && udp_buffer_valid_q[selected_udp_index]) begin
        selected_selection = frame_selection_q;
        selected_valid     = 1'b1;
        selected_data      = udp_buffer_data_q[selected_udp_index];
        selected_last      = udp_buffer_last_q[selected_udp_index];
        selected_keep      = udp_buffer_keep_q[selected_udp_index];
        selected_user      = udp_buffer_user_q[selected_udp_index];
      end
    end else begin
      if (reply_buffer_valid_q) begin
        selected_selection = SEL_REPLY;
        selected_valid     = 1'b1;
        selected_data      = reply_buffer_data_q;
        selected_last      = reply_buffer_last_q;
        selected_keep      = reply_buffer_keep_q;
        selected_user      = reply_buffer_user_q;
      end else if (!reply_pending && idle_udp_grant_valid_q && udp_axis_enable_q[idle_udp_grant_index_q] && udp_buffer_valid_q[idle_udp_grant_index_q]) begin
        selected_selection = SEL_UDP0 + idle_udp_grant_index_q;
        selected_udp_index = idle_udp_grant_index_q;
        selected_valid     = 1'b1;
        selected_data      = udp_buffer_data_q[idle_udp_grant_index_q];
        selected_last      = udp_buffer_last_q[idle_udp_grant_index_q];
        selected_keep      = udp_buffer_keep_q[idle_udp_grant_index_q];
        selected_user      = udp_buffer_user_q[idle_udp_grant_index_q];
      end
    end

    output_pop       = output_valid_q && tx_axis_tready;
    output_has_space = !output_valid_q || output_pop;
    output_load      = output_has_space && selected_valid;
    reply_buffer_pop = output_load && (selected_selection == SEL_REPLY);
    udp_buffer_pop   = 4'd0;
    if (output_load && (selected_selection >= SEL_UDP0) && (selected_selection <= SEL_UDP3)) udp_buffer_pop[selected_udp_index] = 1'b1;

    // No input-ready expression references input tvalid or CMAC tready.
    // A full elastic buffer can accept a replacement when its stored beat
    // is selected for this output-register load.
    udp_axis_tready   = 4'd0;
    // Keep the reply ingress independent from CMAC tx_axis_tready.  The
    // response engine honors backpressure, and a one-entry reply buffer
    // is sufficient for its infrequent ARP/ICMP traffic.
    reply_axis_tready = !reply_buffer_valid_q;
    for (scan_index = 0; scan_index < 4; scan_index = scan_index + 1) begin
      if (udp_axis_enable_q[scan_index] && !udp_config_inhibit) udp_axis_tready[scan_index] = !udp_buffer_valid_q[scan_index] || udp_buffer_pop[scan_index];
    end
    udp_buffer_push = udp_axis_tvalid & udp_axis_tready;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      frame_selection_q <= SEL_IDLE;
      udp_next_q        <= 2'd0;
      udp_axis_enable_q <= 4'd0;
    end else begin
      udp_axis_enable_q <= udp_axis_enable;
      if ((frame_selection_q != SEL_IDLE) && !selection_enabled(frame_selection_q)) begin
        frame_selection_q <= SEL_IDLE;
      end else if (output_load) begin
        if (selected_last) begin
          frame_selection_q <= SEL_IDLE;
          if ((selected_selection >= SEL_UDP0) && (selected_selection <= SEL_UDP3)) udp_next_q <= next_udp_index(selected_udp_index);
        end else begin
          frame_selection_q <= selected_selection;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      idle_udp_grant_valid_q <= 1'b0;
      idle_udp_grant_index_q <= 2'd0;
    end else if ((frame_selection_q != SEL_IDLE) || reply_buffer_valid_q || reply_pending) begin
      idle_udp_grant_valid_q <= 1'b0;
    end else if (idle_udp_grant_valid_q) begin
      if (!udp_axis_enable_q[idle_udp_grant_index_q] || !udp_buffer_valid_q[idle_udp_grant_index_q] || (output_load && (selected_selection >= SEL_UDP0) && (selected_selection <= SEL_UDP3))) begin
        idle_udp_grant_valid_q <= 1'b0;
      end
    end else if (idle_udp_pick_valid) begin
      idle_udp_grant_valid_q <= 1'b1;
      idle_udp_grant_index_q <= idle_udp_pick_index;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      reply_buffer_valid_q <= 1'b0;
      reply_buffer_data_q  <= 512'd0;
      reply_buffer_last_q  <= 1'b0;
      reply_buffer_keep_q  <= 64'd0;
      reply_buffer_user_q  <= 1'b0;
      udp_buffer_valid_q   <= 4'd0;
      udp_buffer_data_q    <= '0;
      udp_buffer_last_q    <= 4'd0;
      udp_buffer_keep_q    <= '0;
      udp_buffer_user_q    <= 4'd0;
    end else begin
      if (reply_buffer_pop) reply_buffer_valid_q <= 1'b0;
      if (reply_axis_tvalid && reply_axis_tready) begin
        reply_buffer_valid_q <= 1'b1;
        reply_buffer_data_q  <= reply_axis_tdata;
        reply_buffer_last_q  <= reply_axis_tlast;
        reply_buffer_keep_q  <= reply_axis_tkeep;
        reply_buffer_user_q  <= reply_axis_tuser;
      end

      for (udp_buffer_index = 0; udp_buffer_index < 4; udp_buffer_index = udp_buffer_index + 1) begin
        if (!udp_axis_enable_q[udp_buffer_index]) begin
          udp_buffer_valid_q[udp_buffer_index] <= 1'b0;
        end else if (udp_buffer_push[udp_buffer_index]) begin
          // A push wins over a concurrent pop: the new beat is the
          // next contents of this one-entry elastic buffer.
          udp_buffer_valid_q[udp_buffer_index] <= 1'b1;
          udp_buffer_data_q[udp_buffer_index]  <= udp_axis_tdata[udp_buffer_index];
          udp_buffer_last_q[udp_buffer_index]  <= udp_axis_tlast[udp_buffer_index];
          udp_buffer_keep_q[udp_buffer_index]  <= udp_axis_tkeep[udp_buffer_index];
          udp_buffer_user_q[udp_buffer_index]  <= udp_axis_tuser[udp_buffer_index];
        end else if (udp_buffer_pop[udp_buffer_index]) begin
          udp_buffer_valid_q[udp_buffer_index] <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      output_valid_q <= 1'b0;
      output_data_q  <= 512'd0;
      output_last_q  <= 1'b0;
      output_keep_q  <= 64'd0;
      output_user_q  <= 1'b0;
    end else if (output_load) begin
      output_valid_q <= 1'b1;
      output_data_q  <= selected_data;
      output_last_q  <= selected_last;
      output_keep_q  <= selected_keep;
      output_user_q  <= selected_user;
    end else if (output_pop) begin
      output_valid_q <= 1'b0;
    end
  end

  always_comb begin
    tx_axis_tvalid = output_valid_q;
    tx_axis_tdata  = output_data_q;
    tx_axis_tlast  = output_last_q;
    tx_axis_tkeep  = output_keep_q;
    tx_axis_tuser  = output_user_q;
  end

endmodule

// Minimal untagged Ethernet ARP and IPv4 ICMP echo reply engine.
module cmac_usplus_0_ping_reply_engine #(
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

  output wire        arp_sender_update,
  output wire [47:0] arp_sender_mac,
  output wire [31:0] arp_sender_ip,

  input  logic         tx_axis_tready,
  output wire          tx_axis_tvalid,
  output wire  [511:0] tx_axis_tdata,
  output wire          tx_axis_tlast,
  output wire  [ 63:0] tx_axis_tkeep,
  output wire          tx_axis_tuser
);

  localparam integer MAX_FRAME_WORDS = 24;  // 1536 bytes, enough for a 1500-byte MTU frame
  localparam [63:0] KEEP_60 = 64'h0FFF_FFFF_FFFF_FFFF;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_RX   = 2'd1,
    ST_TX   = 2'd2,
    ST_DROP = 2'd3
  } state_t;

  logic   [511:0] frame_data          [0:MAX_FRAME_WORDS-1];
  logic   [ 63:0] frame_keep          [0:MAX_FRAME_WORDS-1];
  state_t         state;
  logic   [  5:0] rx_word_index;
  logic   [  5:0] frame_word_count;
  logic   [  5:0] tx_word_index;
  logic           frame_is_arp;
  logic           frame_is_icmp;
  logic           frame_bad;
  logic           response_is_arp;
  logic           rx_drop_in_progress;
  logic   [ 31:0] frame_local_ip;
  logic   [ 31:0] response_local_ip;

  function automatic logic [7:0] get_byte(input logic [511:0] data, input int unsigned byte_index);
    get_byte = data[byte_index*8+:8];
  endfunction

  function automatic logic [15:0] get_be16(input logic [511:0] data, input int unsigned byte_index);
    get_be16 = {get_byte(data, byte_index), get_byte(data, byte_index + 1)};
  endfunction

  function automatic logic [31:0] get_be32(input logic [511:0] data, input int unsigned byte_index);
    get_be32 = {get_byte(data, byte_index), get_byte(data, byte_index + 1), get_byte(data, byte_index + 2), get_byte(data, byte_index + 3)};
  endfunction

  function automatic logic [47:0] get_mac(input logic [511:0] data, input int unsigned byte_index);
    get_mac = {get_byte(data, byte_index), get_byte(data, byte_index + 1), get_byte(data, byte_index + 2), get_byte(data, byte_index + 3), get_byte(data, byte_index + 4), get_byte(data, byte_index + 5)};
  endfunction

  function automatic logic [511:0] set_byte(input logic [511:0] data, input int unsigned byte_index, input logic [7:0] value);
    logic [511:0] updated;
    begin
      updated                  = data;
      updated[byte_index*8+:8] = value;
      set_byte                 = updated;
    end
  endfunction

  function automatic logic [511:0] set_be16(input logic [511:0] data, input int unsigned byte_index, input logic [15:0] value);
    logic [511:0] updated;
    begin
      updated  = set_byte(data, byte_index, value[15:8]);
      updated  = set_byte(updated, byte_index + 1, value[7:0]);
      set_be16 = updated;
    end
  endfunction

  function automatic logic [511:0] set_be32(input logic [511:0] data, input int unsigned byte_index, input logic [31:0] value);
    logic [511:0] updated;
    begin
      updated  = set_byte(data, byte_index, value[31:24]);
      updated  = set_byte(updated, byte_index + 1, value[23:16]);
      updated  = set_byte(updated, byte_index + 2, value[15:8]);
      updated  = set_byte(updated, byte_index + 3, value[7:0]);
      set_be32 = updated;
    end
  endfunction

  function automatic logic [511:0] set_mac(input logic [511:0] data, input int unsigned byte_index, input logic [47:0] value);
    logic [511:0] updated;
    begin
      updated = set_byte(data, byte_index, value[47:40]);
      updated = set_byte(updated, byte_index + 1, value[39:32]);
      updated = set_byte(updated, byte_index + 2, value[31:24]);
      updated = set_byte(updated, byte_index + 3, value[23:16]);
      updated = set_byte(updated, byte_index + 4, value[15:8]);
      updated = set_byte(updated, byte_index + 5, value[7:0]);
      set_mac = updated;
    end
  endfunction

  function automatic logic is_arp_request(input logic [511:0] data, input logic [63:0] keep);
    begin
      is_arp_request = keep[41] && ((get_mac(data, 0) == 48'hFF_FF_FF_FF_FF_FF) || (get_mac(data, 0) == LOCAL_MAC)) && (get_be16(data, 12) == 16'h0806) && (get_be16(data, 14) == 16'h0001) && (get_be16(data, 16) == 16'h0800) && (get_byte(data, 18) == 8'h06) && (get_byte(data, 19) == 8'h04) &&
        (get_be16(data, 20) == 16'h0001) && (get_be32(data, 38) == local_ip);
    end
  endfunction

  // ARP sender fields are usable as a UDP destination only when this is a
  // complete, untagged ARP request or reply addressed to the local IP.
  function automatic logic is_arp_sender_for_local(input logic [511:0] data, input logic [63:0] keep);
    begin
      is_arp_sender_for_local = (&keep[41:0]) && ((get_mac(data, 0) == 48'hFF_FF_FF_FF_FF_FF) || (get_mac(data, 0) == LOCAL_MAC)) && (get_mac(data, 6) == get_mac(data, 22)) && (get_be16(data, 12) == 16'h0806) && (get_be16(data, 14) == 16'h0001) && (get_be16(data, 16) == 16'h0800) &&
        (get_byte(data, 18) == 8'h06) && (get_byte(data, 19) == 8'h04) && ((get_be16(data, 20) == 16'h0001) || (get_be16(data, 20) == 16'h0002)) && (get_be32(data, 28) != 32'd0) && (get_be32(data, 38) == local_ip);
    end
  endfunction

  function automatic logic is_icmp_echo_request(input logic [511:0] data, input logic [63:0] keep);
    begin
      is_icmp_echo_request = keep[41] && (get_mac(data, 0) == LOCAL_MAC) && (get_be16(data, 12) == 16'h0800) && (get_byte(data, 14) == 8'h45) && (get_be16(data, 16) >= 16'd28) && ((get_be16(data, 20) & 16'h3FFF) == 16'd0) && (get_byte(data, 23) == 8'h01) && (get_be32(data, 30) == local_ip) &&
        (get_be16(data, 34) == 16'h0800);
    end
  endfunction

  function automatic logic [15:0] icmp_reply_checksum(input logic [15:0] request_checksum);
    logic [16:0] sum;
    begin
      // RFC 1624 incremental update for ICMP type 8 -> 0.
      sum                 = {1'b0, ~request_checksum} + 17'h0F7FF;
      sum                 = {1'b0, sum[15:0]} + sum[16];
      icmp_reply_checksum = ~sum[15:0];
    end
  endfunction

  function automatic logic [511:0] make_arp_reply(input logic [511:0] request);
    logic [511:0] reply;
    begin
      reply          = 512'd0;
      reply          = set_mac(reply, 0, get_mac(request, 6));
      reply          = set_mac(reply, 6, LOCAL_MAC);
      reply          = set_be16(reply, 12, 16'h0806);
      reply          = set_be16(reply, 14, 16'h0001);
      reply          = set_be16(reply, 16, 16'h0800);
      reply          = set_byte(reply, 18, 8'h06);
      reply          = set_byte(reply, 19, 8'h04);
      reply          = set_be16(reply, 20, 16'h0002);
      reply          = set_mac(reply, 22, LOCAL_MAC);
      reply          = set_be32(reply, 28, response_local_ip);
      reply          = set_mac(reply, 32, get_mac(request, 6));
      reply          = set_be32(reply, 38, get_be32(request, 28));
      make_arp_reply = reply;
    end
  endfunction

  function automatic logic [511:0] make_icmp_reply(input logic [511:0] request);
    logic [511:0] reply;
    begin
      reply           = request;
      reply           = set_mac(reply, 0, get_mac(request, 6));
      reply           = set_mac(reply, 6, LOCAL_MAC);
      // Swapping IPv4 source/destination leaves the IPv4 checksum unchanged.
      reply           = set_be32(reply, 26, get_be32(request, 30));
      reply           = set_be32(reply, 30, get_be32(request, 26));
      reply           = set_byte(reply, 34, 8'h00);
      reply           = set_be16(reply, 36, icmp_reply_checksum(get_be16(request, 36)));
      make_icmp_reply = reply;
    end
  endfunction

  // An Ethernet ARP frame is no longer than one 64-byte CMAC beat. Waiting
  // for TLAST ensures a malformed multi-beat frame cannot change UDP state.
  assign arp_sender_update = rx_axis_tvalid && rx_axis_tlast && !rx_axis_tuser && is_arp_sender_for_local(rx_axis_tdata, rx_axis_tkeep);
  assign arp_sender_mac    = get_mac(rx_axis_tdata, 22);
  assign arp_sender_ip     = get_be32(rx_axis_tdata, 28);

  assign tx_axis_tvalid    = (state == ST_TX);
  assign tx_axis_tuser     = 1'b0;
  assign tx_axis_tdata     = (state != ST_TX) ? 512'd0 : response_is_arp ? make_arp_reply(frame_data[0]) : (tx_word_index == 6'd0) ? make_icmp_reply(frame_data[0]) : frame_data[tx_word_index];
  assign tx_axis_tkeep     = (state != ST_TX) ? 64'd0 : response_is_arp ? KEEP_60 : frame_keep[tx_word_index];
  assign tx_axis_tlast     = (state != ST_TX) ? 1'b0 : response_is_arp ? 1'b1 : (tx_word_index == (frame_word_count - 1'b1));

  always_ff @(posedge clk) begin
    if (reset) begin
      state               <= ST_IDLE;
      rx_word_index       <= 6'd0;
      frame_word_count    <= 6'd0;
      tx_word_index       <= 6'd0;
      frame_is_arp        <= 1'b0;
      frame_is_icmp       <= 1'b0;
      frame_bad           <= 1'b0;
      response_is_arp     <= 1'b0;
      rx_drop_in_progress <= 1'b0;
      frame_local_ip      <= 32'd0;
      response_local_ip   <= 32'd0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (rx_axis_tvalid) begin
            frame_data[0]  <= rx_axis_tdata;
            frame_keep[0]  <= rx_axis_tkeep;
            frame_is_arp   <= is_arp_request(rx_axis_tdata, rx_axis_tkeep);
            frame_is_icmp  <= is_icmp_echo_request(rx_axis_tdata, rx_axis_tkeep);
            frame_bad      <= rx_axis_tuser;
            frame_local_ip <= local_ip;
            if (rx_axis_tlast) begin
              frame_word_count <= 6'd1;
              tx_word_index    <= 6'd0;
              if (!rx_axis_tuser && is_arp_request(rx_axis_tdata, rx_axis_tkeep)) begin
                response_is_arp   <= 1'b1;
                response_local_ip <= local_ip;
                state             <= ST_TX;
              end else if (!rx_axis_tuser && is_icmp_echo_request(rx_axis_tdata, rx_axis_tkeep)) begin
                response_is_arp   <= 1'b0;
                response_local_ip <= local_ip;
                state             <= ST_TX;
              end
            end else begin
              rx_word_index <= 6'd1;
              state         <= ST_RX;
            end
          end
        end

        ST_RX: begin
          if (rx_axis_tvalid) begin
            frame_data[rx_word_index] <= rx_axis_tdata;
            frame_keep[rx_word_index] <= rx_axis_tkeep;
            frame_bad                 <= frame_bad | rx_axis_tuser;
            if (rx_axis_tlast) begin
              frame_word_count <= rx_word_index + 1'b1;
              tx_word_index    <= 6'd0;
              if (!(frame_bad | rx_axis_tuser) && (frame_is_arp || frame_is_icmp)) begin
                response_is_arp   <= frame_is_arp;
                response_local_ip <= frame_local_ip;
                state             <= ST_TX;
              end else begin
                state <= ST_IDLE;
              end
            end else if (rx_word_index == MAX_FRAME_WORDS - 1) begin
              state <= ST_DROP;
            end else begin
              rx_word_index <= rx_word_index + 1'b1;
            end
          end
        end

        ST_TX: begin
          // CMAC RX has no ready signal. Keep the receive frame
          // boundary while a response is being sent.
          if (rx_axis_tvalid) rx_drop_in_progress <= !rx_axis_tlast;
          if (tx_axis_tready) begin
            if (response_is_arp || (tx_word_index == (frame_word_count - 1'b1))) begin
              if (rx_axis_tvalid ? !rx_axis_tlast : rx_drop_in_progress) state <= ST_DROP;
              else state <= ST_IDLE;
            end else begin
              tx_word_index <= tx_word_index + 1'b1;
            end
          end
        end

        ST_DROP: begin
          if (rx_axis_tvalid && rx_axis_tlast) begin
            rx_drop_in_progress <= 1'b0;
            state               <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
