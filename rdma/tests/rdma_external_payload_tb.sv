`timescale 1ns / 1ps

module rdma_external_payload_tb;
  localparam integer FRAME_BEATS = 66;
  localparam integer ICRC_DATA_BYTES = 4152;
  localparam integer ICRC_FRAME_OFFSET = 4166;
  localparam integer PAYLOAD_OFFSET = 70;
  localparam logic [31:0] GOLDEN_ICRC = 32'h7EE1_11B3;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic [31:0] local_ip = 32'hC0A8_110B;
  logic [31:0] rx_overflow_source_count = 32'd0;
  logic cfg_valid = 1'b0;
  logic cfg_ready;
  logic cfg_done;
  logic cfg_accepted;
  logic start_request = 1'b0;
  logic stop_request = 1'b0;
  logic abort_request = 1'b0;
  logic [63:0] consumed_bytes = 64'd0;
  logic tx_path_idle = 1'b1;
  logic payload_axis_tvalid = 1'b0;
  logic payload_axis_tready;
  logic [511:0] payload_axis_tdata = 512'd0;
  logic [63:0] payload_axis_tkeep = 64'd0;
  logic payload_axis_tlast = 1'b0;
  logic payload_axis_tuser = 1'b0;
  logic rx_axis_tvalid = 1'b0;
  logic rx_axis_tready;
  logic [511:0] rx_axis_tdata = 512'd0;
  logic [63:0] rx_axis_tkeep = 64'd0;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;
  logic tx_axis_tready = 1'b0;
  logic tx_axis_tvalid;
  logic [511:0] tx_axis_tdata;
  logic [63:0] tx_axis_tkeep;
  logic tx_axis_tlast;
  logic tx_axis_tuser;
  logic configured;
  logic active;
  logic [31:0] retrans_count;
  logic external_payload_active;
  logic payload_waiting;
  logic [31:0] payload_accepted_count;
  logic [31:0] payload_error_count;
  logic [31:0] build_tag;
  logic [3:0] transport_state;

  logic [511:0] first_data [0:FRAME_BEATS-1];
  logic [63:0] first_keep [0:FRAME_BEATS-1];
  logic first_last [0:FRAME_BEATS-1];
  logic [511:0] second_data [0:FRAME_BEATS-1];
  logic [63:0] second_keep [0:FRAME_BEATS-1];
  logic second_last [0:FRAME_BEATS-1];

  always #2 clk = ~clk;

  rdma_transport_ip #(
    .ACK_TIMEOUT_CYCLES(16),
    .MAX_RETRIES(2),
    .FAST_BENCHMARK_MODE(1'b1),
    .BUILD_TAG(32'h2026_0921)
  ) dut (
    .aclk(clk),
    .aresetn(!reset),
    .local_ip(local_ip),
    .rx_overflow_source_count(rx_overflow_source_count),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_done(cfg_done),
    .cfg_accepted(cfg_accepted),
    .cfg_remote_mac(48'h02_11_22_33_44_55),
    .cfg_remote_ip(32'hC0A8_110A),
    .cfg_remote_qpn(24'h12_3456),
    .cfg_local_psn(24'h00_0100),
    .cfg_remote_base(48'h0000_0010_0000),
    .cfg_rkey(32'h89AB_CDEF),
    .cfg_ring_size(32'd4096),
    .cfg_wr_size(32'd4096),
    .cfg_local_base(64'd0),
    .cfg_enable_immediate(1'b0),
    .cfg_notify_interval_bytes(32'd4096),
    .cfg_commit_remote_addr(48'h0000_0010_1000),
    .cfg_use_external_payload(1'b1),
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
    .consumed_bytes(consumed_bytes),
    .tx_path_idle(tx_path_idle),
    .s_axis_payload_tvalid(payload_axis_tvalid),
    .s_axis_payload_tready(payload_axis_tready),
    .s_axis_payload_tdata(payload_axis_tdata),
    .s_axis_payload_tkeep(payload_axis_tkeep),
    .s_axis_payload_tlast(payload_axis_tlast),
    .s_axis_payload_tuser(payload_axis_tuser),
    .s_axis_rx_tvalid(rx_axis_tvalid),
    .s_axis_rx_tready(rx_axis_tready),
    .s_axis_rx_tdata(rx_axis_tdata),
    .s_axis_rx_tkeep(rx_axis_tkeep),
    .s_axis_rx_tlast(rx_axis_tlast),
    .s_axis_rx_tuser(rx_axis_tuser),
    .m_axis_tx_tready(tx_axis_tready),
    .m_axis_tx_tvalid(tx_axis_tvalid),
    .m_axis_tx_tdata(tx_axis_tdata),
    .m_axis_tx_tkeep(tx_axis_tkeep),
    .m_axis_tx_tlast(tx_axis_tlast),
    .m_axis_tx_tuser(tx_axis_tuser),
    .build_tag(build_tag),
    .configured(configured),
    .active(active),
    .credit_stalled(),
    .stopping(),
    .drained(),
    .fault(),
    .fault_reason(),
    .final_commit_acked(),
    .config_reject_count(),
    .config_reject_reason(),
    .icrc_drop_count(),
    .invalid_psn_count(),
    .nak_count(),
    .retrans_count(retrans_count),
    .retry_exhausted_count(),
    .rx_overflow_count(),
    .tx_underflow_count(),
    .issued_bytes(),
    .acked_bytes(),
    .ring_offset(),
    .current_psn(),
    .debug_state(transport_state),
    .commit_count(),
    .immediate_count(),
    .published_bytes(),
    .producer_sequence(),
    .last_nak_syndrome(),
    .last_nak_psn(),
    .sequence_recovery_count(),
    .replay_active(),
    .external_payload_active(external_payload_active),
    .payload_waiting(payload_waiting),
    .payload_accepted_count(payload_accepted_count),
    .payload_error_count(payload_error_count)
  );

  function automatic logic [511:0] payload_word(input integer beat_index);
    integer lane;
    begin
      payload_word = 512'd0;
      for (lane = 0; lane < 64; lane = lane + 1)
        payload_word[lane * 8 +: 8] =
          ((beat_index * 64 + lane) * 13 + 7) & 8'hFF;
    end
  endfunction

  function automatic logic [7:0] expected_payload_byte(input integer index);
    expected_payload_byte = (index * 13 + 7) & 8'hFF;
  endfunction

  function automatic logic [7:0] first_frame_byte(input integer index);
    first_frame_byte = first_data[index / 64][(index % 64) * 8 +: 8];
  endfunction

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      crc32_byte_ref = crc;
    end
  endfunction

  task automatic configure_endpoint;
    integer cycles;
    begin
      @(negedge clk);
      cfg_valid = 1'b1;
      do @(posedge clk); while (!cfg_ready);
      @(negedge clk);
      cfg_valid = 1'b0;
      cycles = 0;
      while (!cfg_done && cycles < 20) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!cfg_done || !cfg_accepted || !configured || !external_payload_active)
        $fatal(1, "external transport configuration was not accepted");
    end
  endtask

  task automatic send_payload;
    integer beat;
    begin
      for (beat = 0; beat < 64; beat = beat + 1) begin
        @(negedge clk);
        payload_axis_tvalid = 1'b1;
        payload_axis_tdata = payload_word(beat);
        payload_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
        payload_axis_tlast = beat == 63;
        do @(posedge clk); while (!payload_axis_tready);
      end
      @(negedge clk);
      payload_axis_tvalid = 1'b0;
      payload_axis_tlast = 1'b0;
    end
  endtask

  task automatic capture_first_frame;
    integer beat;
    integer cycles;
    integer stall_cycle;
    logic [511:0] stalled_data;
    logic [63:0] stalled_keep;
    logic stalled_last;
    begin
      cycles = 0;
      while (!tx_axis_tvalid && cycles < 96) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (!tx_axis_tvalid)
        $fatal(1, "external packet construction exceeded 96 cycles");

      stalled_data = tx_axis_tdata;
      stalled_keep = tx_axis_tkeep;
      stalled_last = tx_axis_tlast;
      for (stall_cycle = 0; stall_cycle < 5; stall_cycle = stall_cycle + 1) begin
        @(negedge clk);
        if (!tx_axis_tvalid || tx_axis_tdata !== stalled_data ||
            tx_axis_tkeep !== stalled_keep || tx_axis_tlast !== stalled_last ||
            tx_axis_tuser)
          $fatal(1, "external TX beat changed under backpressure");
      end

      first_data[0] = stalled_data;
      first_keep[0] = stalled_keep;
      first_last[0] = stalled_last;
      tx_axis_tready = 1'b1;
      @(posedge clk);
      beat = 1;
      while (beat < FRAME_BEATS) begin
        @(negedge clk);
        if (tx_axis_tvalid && tx_axis_tready) begin
          first_data[beat] = tx_axis_tdata;
          first_keep[beat] = tx_axis_tkeep;
          first_last[beat] = tx_axis_tlast;
          beat = beat + 1;
        end
      end
    end
  endtask

  task automatic capture_second_frame;
    integer beat;
    begin
      beat = 0;
      while (beat < FRAME_BEATS) begin
        @(negedge clk);
        if (tx_axis_tvalid && tx_axis_tready) begin
          second_data[beat] = tx_axis_tdata;
          second_keep[beat] = tx_axis_tkeep;
          second_last[beat] = tx_axis_tlast;
          beat = beat + 1;
        end
      end
    end
  endtask

  integer index;
  integer frame_byte;
  integer frame_beat;
  integer frame_lane;
  integer ready_cycles;
  logic [31:0] reference_icrc;
  logic [7:0] reference_byte;
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    configure_endpoint();
    ready_cycles = 0;
    while ((!payload_waiting || !payload_axis_tready) && ready_cycles < 10) begin
      @(posedge clk);
      ready_cycles = ready_cycles + 1;
    end
    if (!payload_waiting || !payload_axis_tready ||
        transport_state != 4'd2 ||
        build_tag != 32'h2026_0921)
      $fatal(1, "external transport did not request payload");
    send_payload();
    if (payload_accepted_count != 32'd1 || payload_error_count != 32'd0 ||
        payload_axis_tready)
      $fatal(1, "payload was not retained for transmission");

    @(negedge clk);
    start_request = 1'b1;
    @(posedge clk);
    @(negedge clk);
    start_request = 1'b0;

    capture_first_frame();
    if (!first_last[FRAME_BEATS-1] ||
        first_keep[FRAME_BEATS-1] != 64'h0000_0000_0000_03FF)
      $fatal(1, "external packet length/keep was incorrect");

    for (index = 0; index < 4096; index = index + 1) begin
      frame_byte = PAYLOAD_OFFSET + index;
      frame_beat = frame_byte / 64;
      frame_lane = frame_byte % 64;
      if (first_data[frame_beat][frame_lane * 8 +: 8] !=
          expected_payload_byte(index))
        $fatal(1, "external payload mismatch at byte %0d", index);
    end

    reference_icrc = 32'hDEBB_20E3;
    for (index = 0; index < ICRC_DATA_BYTES; index = index + 1) begin
      reference_byte = first_frame_byte(14 + index);
      case (index)
        1, 8, 10, 11, 26, 27, 32: reference_byte = 8'hFF;
        default: reference_byte = reference_byte;
      endcase
      reference_icrc = crc32_byte_ref(reference_icrc, reference_byte);
    end
    reference_icrc = ~reference_icrc;
    if (reference_icrc != GOLDEN_ICRC ||
        first_frame_byte(ICRC_FRAME_OFFSET) != GOLDEN_ICRC[7:0] ||
        first_frame_byte(ICRC_FRAME_OFFSET + 1) != GOLDEN_ICRC[15:8] ||
        first_frame_byte(ICRC_FRAME_OFFSET + 2) != GOLDEN_ICRC[23:16] ||
        first_frame_byte(ICRC_FRAME_OFFSET + 3) != GOLDEN_ICRC[31:24])
      $fatal(1, "external payload ICRC mismatch expected=%h actual=%h",
             GOLDEN_ICRC, reference_icrc);

    capture_second_frame();
    for (index = 0; index < FRAME_BEATS; index = index + 1) begin
      if (second_data[index] !== first_data[index] ||
          second_keep[index] !== first_keep[index] ||
          second_last[index] !== first_last[index])
        $fatal(1, "retransmission mismatch at beat %0d", index);
    end
    if (retrans_count != 32'd1 || payload_axis_tready)
      $fatal(1, "external payload was released before ACK");

    $display("rdma_external_payload_tb PASS");
    $finish;
  end
endmodule
