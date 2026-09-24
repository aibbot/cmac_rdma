`timescale 1ns / 1ps

module rdma_external_lifecycle_tb;
  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [47:0] REMOTE_MAC = 48'h02_11_22_33_44_55;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_110B;
  localparam logic [31:0] REMOTE_IP = 32'hC0A8_110A;
  localparam logic [23:0] INITIAL_PSN = 24'h00_0100;
  localparam integer DATA_FRAME_BYTES = 4170;
  localparam integer DATA_FRAME_BEATS = 66;
  localparam integer PAYLOAD_OFFSET = 70;
  localparam integer MAX_FRAME_BEATS = 66;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic cfg_valid = 1'b0;
  logic cfg_ready;
  logic cfg_done;
  logic cfg_accepted;
  logic start_request = 1'b0;
  logic stop_request = 1'b0;
  logic abort_request = 1'b0;
  logic [63:0] consumed_bytes = 64'd0;
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
  logic tx_axis_tvalid;
  logic [511:0] tx_axis_tdata;
  logic [63:0] tx_axis_tkeep;
  logic tx_axis_tlast;
  logic tx_axis_tuser;
  logic configured;
  logic active;
  logic stopping;
  logic drained;
  logic fault;
  logic [31:0] fault_reason;
  logic final_commit_acked;
  logic [31:0] retrans_count;
  logic [63:0] issued_bytes;
  logic [63:0] acked_bytes;
  logic [23:0] current_psn;
  logic [31:0] commit_count;
  logic [63:0] published_bytes;
  logic [63:0] producer_sequence;
  logic external_payload_active;
  logic payload_waiting;
  logic [31:0] payload_accepted_count;
  logic [31:0] payload_error_count;

  logic [511:0] captured_data [MAX_FRAME_BEATS];
  logic [63:0] captured_keep [MAX_FRAME_BEATS];
  integer captured_beats;
  integer captured_bytes;

  always #2 clk = ~clk;

  rdma_transport_ip #(
    .ACK_TIMEOUT_CYCLES(2000),
    .MAX_RETRIES(2),
    .FAST_BENCHMARK_MODE(1'b1),
    .BUILD_TAG(32'h2026_0921)
  ) dut (
    .aclk(clk),
    .aresetn(!reset),
    .local_ip(LOCAL_IP),
    .rx_overflow_source_count(32'd0),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_done(cfg_done),
    .cfg_accepted(cfg_accepted),
    .cfg_remote_mac(REMOTE_MAC),
    .cfg_remote_ip(REMOTE_IP),
    .cfg_remote_qpn(24'h12_3456),
    .cfg_local_psn(INITIAL_PSN),
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
    .tx_path_idle(1'b1),
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
    .m_axis_tx_tready(1'b1),
    .m_axis_tx_tvalid(tx_axis_tvalid),
    .m_axis_tx_tdata(tx_axis_tdata),
    .m_axis_tx_tkeep(tx_axis_tkeep),
    .m_axis_tx_tlast(tx_axis_tlast),
    .m_axis_tx_tuser(tx_axis_tuser),
    .build_tag(),
    .configured(configured),
    .active(active),
    .credit_stalled(),
    .stopping(stopping),
    .drained(drained),
    .fault(fault),
    .fault_reason(fault_reason),
    .final_commit_acked(final_commit_acked),
    .config_reject_count(),
    .config_reject_reason(),
    .icrc_drop_count(),
    .invalid_psn_count(),
    .nak_count(),
    .retrans_count(retrans_count),
    .retry_exhausted_count(),
    .rx_overflow_count(),
    .tx_underflow_count(),
    .issued_bytes(issued_bytes),
    .acked_bytes(acked_bytes),
    .ring_offset(),
    .current_psn(current_psn),
    .debug_state(),
    .commit_count(commit_count),
    .immediate_count(),
    .published_bytes(published_bytes),
    .producer_sequence(producer_sequence),
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

  function automatic logic [7:0] get_byte(
    input logic [511:0] data,
    input integer index
  );
    get_byte = data[index * 8 +: 8];
  endfunction

  function automatic logic [7:0] captured_byte(input integer index);
    captured_byte = captured_data[index / 64][(index % 64) * 8 +: 8];
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

  function automatic logic [15:0] ipv4_checksum_ref;
    logic [19:0] sum;
    begin
      sum = 20'd0;
      sum = sum + 16'h4500 + 16'd48 + 16'h0020 + 16'h4000 + 16'h4011;
      sum = sum + REMOTE_IP[31:16] + REMOTE_IP[15:0];
      sum = sum + LOCAL_IP[31:16] + LOCAL_IP[15:0];
      sum = {4'd0, sum[15:0]} + sum[19:16];
      sum = {4'd0, sum[15:0]} + sum[19:16];
      ipv4_checksum_ref = ~sum[15:0];
    end
  endfunction

  task automatic put_byte(
    inout logic [511:0] data,
    input integer index,
    input logic [7:0] value
  );
    data[index * 8 +: 8] = value;
  endtask

  task automatic build_ack(
    input logic [23:0] psn,
    output logic [511:0] data
  );
    logic [31:0] crc;
    logic [31:0] icrc;
    logic [15:0] ip_checksum;
    logic [7:0] crc_byte;
    integer index;
    begin
      data = 512'd0;
      put_byte(data, 0, LOCAL_MAC[47:40]);
      put_byte(data, 1, LOCAL_MAC[39:32]);
      put_byte(data, 2, LOCAL_MAC[31:24]);
      put_byte(data, 3, LOCAL_MAC[23:16]);
      put_byte(data, 4, LOCAL_MAC[15:8]);
      put_byte(data, 5, LOCAL_MAC[7:0]);
      put_byte(data, 6, REMOTE_MAC[47:40]);
      put_byte(data, 7, REMOTE_MAC[39:32]);
      put_byte(data, 8, REMOTE_MAC[31:24]);
      put_byte(data, 9, REMOTE_MAC[23:16]);
      put_byte(data, 10, REMOTE_MAC[15:8]);
      put_byte(data, 11, REMOTE_MAC[7:0]);
      put_byte(data, 12, 8'h08);
      put_byte(data, 13, 8'h00);
      ip_checksum = ipv4_checksum_ref();
      put_byte(data, 14, 8'h45);
      put_byte(data, 15, 8'h00);
      put_byte(data, 16, 8'h00);
      put_byte(data, 17, 8'h30);
      put_byte(data, 18, 8'h00);
      put_byte(data, 19, 8'h20);
      put_byte(data, 20, 8'h40);
      put_byte(data, 21, 8'h00);
      put_byte(data, 22, 8'h40);
      put_byte(data, 23, 8'h11);
      put_byte(data, 24, ip_checksum[15:8]);
      put_byte(data, 25, ip_checksum[7:0]);
      put_byte(data, 26, REMOTE_IP[31:24]);
      put_byte(data, 27, REMOTE_IP[23:16]);
      put_byte(data, 28, REMOTE_IP[15:8]);
      put_byte(data, 29, REMOTE_IP[7:0]);
      put_byte(data, 30, LOCAL_IP[31:24]);
      put_byte(data, 31, LOCAL_IP[23:16]);
      put_byte(data, 32, LOCAL_IP[15:8]);
      put_byte(data, 33, LOCAL_IP[7:0]);
      put_byte(data, 34, 8'hC0);
      put_byte(data, 35, 8'h08);
      put_byte(data, 36, 8'h12);
      put_byte(data, 37, 8'hB7);
      put_byte(data, 38, 8'h00);
      put_byte(data, 39, 8'h1C);
      put_byte(data, 40, 8'h00);
      put_byte(data, 41, 8'h00);
      put_byte(data, 42, 8'h11);
      put_byte(data, 43, 8'h00);
      put_byte(data, 44, 8'hFF);
      put_byte(data, 45, 8'hFF);
      put_byte(data, 46, 8'h00);
      put_byte(data, 47, 8'h00);
      put_byte(data, 48, 8'h00);
      put_byte(data, 49, 8'h01);
      put_byte(data, 50, 8'h00);
      put_byte(data, 51, psn[23:16]);
      put_byte(data, 52, psn[15:8]);
      put_byte(data, 53, psn[7:0]);
      put_byte(data, 54, 8'h1F);
      crc = 32'hDEBB_20E3;
      for (index = 0; index < 44; index = index + 1) begin
        crc_byte = get_byte(data, 14 + index);
        case (index)
          1, 8, 10, 11, 26, 27, 32: crc_byte = 8'hFF;
          default: crc_byte = crc_byte;
        endcase
        crc = crc32_byte_ref(crc, crc_byte);
      end
      icrc = ~crc;
      put_byte(data, 58, icrc[7:0]);
      put_byte(data, 59, icrc[15:8]);
      put_byte(data, 60, icrc[23:16]);
      put_byte(data, 61, icrc[31:24]);
    end
  endtask

  task automatic configure_endpoint;
    integer cycles;
    begin
      cycles = 0;
      while (!cfg_ready && cycles < 100) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!cfg_ready)
        $fatal(1, "configuration did not become ready");
      @(negedge clk);
      cfg_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cfg_valid = 1'b0;
      cycles = 0;
      while (!cfg_done && cycles < 20) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!cfg_done || !cfg_accepted || !configured ||
          !external_payload_active)
        $fatal(1, "external transport configuration was not accepted");
      while (!payload_axis_tready) @(posedge clk);
    end
  endtask

  task automatic send_payload_range(
    input integer first_beat,
    input integer last_beat
  );
    integer beat;
    begin
      for (beat = first_beat; beat <= last_beat; beat = beat + 1) begin
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

  task automatic pulse_start;
    begin
      @(negedge clk);
      start_request = 1'b1;
      @(posedge clk);
      @(negedge clk);
      start_request = 1'b0;
    end
  endtask

  task automatic pulse_stop;
    begin
      @(negedge clk);
      stop_request = 1'b1;
      @(posedge clk);
      @(negedge clk);
      stop_request = 1'b0;
    end
  endtask

  task automatic pulse_start_then_stop;
    begin
      @(negedge clk);
      start_request = 1'b1;
      @(posedge clk);
      @(negedge clk);
      start_request = 1'b0;
      stop_request = 1'b1;
      @(posedge clk);
      @(negedge clk);
      stop_request = 1'b0;
    end
  endtask

  task automatic capture_frame;
    integer lane;
    integer cycles;
    logic done;
    begin
      captured_beats = 0;
      captured_bytes = 0;
      cycles = 0;
      done = 1'b0;
      while (!done && cycles < 100000) begin
        @(negedge clk);
        cycles = cycles + 1;
        if (tx_axis_tvalid) begin
          if (captured_beats >= MAX_FRAME_BEATS)
            $fatal(1, "captured frame exceeded storage");
          captured_data[captured_beats] = tx_axis_tdata;
          captured_keep[captured_beats] = tx_axis_tkeep;
          for (lane = 0; lane < 64; lane = lane + 1) begin
            if (tx_axis_tkeep[lane]) captured_bytes = captured_bytes + 1;
          end
          captured_beats = captured_beats + 1;
          done = tx_axis_tlast;
        end
      end
      if (!done)
        $fatal(1, "timed out waiting for transmit frame");
    end
  endtask

  task automatic send_ack(input logic [23:0] psn);
    logic [511:0] data;
    begin
      build_ack(psn, data);
      while (!rx_axis_tready) @(posedge clk);
      @(negedge clk);
      rx_axis_tdata = data;
      rx_axis_tkeep = 64'h3FFF_FFFF_FFFF_FFFF;
      rx_axis_tlast = 1'b1;
      rx_axis_tvalid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rx_axis_tvalid = 1'b0;
      rx_axis_tlast = 1'b0;
      rx_axis_tkeep = 64'd0;
      rx_axis_tdata = 512'd0;
    end
  endtask

  task automatic assert_data_frame(input logic [23:0] expected_psn);
    integer index;
    begin
      if (captured_beats != DATA_FRAME_BEATS ||
          captured_bytes != DATA_FRAME_BYTES)
        $fatal(1, "data frame shape mismatch: beats=%0d bytes=%0d",
               captured_beats, captured_bytes);
      if (captured_byte(42) != 8'h0A ||
          {captured_byte(51), captured_byte(52), captured_byte(53)} !=
            expected_psn)
        $fatal(1, "captured frame was not the expected data WR");
      for (index = 0; index < 4096; index = index + 1) begin
        if (captured_byte(PAYLOAD_OFFSET + index) !=
            expected_payload_byte(index))
          $fatal(1, "external payload mismatch at byte %0d", index);
      end
    end
  endtask

  task automatic wait_for_acked_bytes(input logic [63:0] expected_bytes);
    integer wait_cycles;
    begin
      wait_cycles = 0;
      while (acked_bytes != expected_bytes && wait_cycles < 200) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end
      if (acked_bytes != expected_bytes)
        $fatal(1, "timed out waiting for acked_bytes=%0d", expected_bytes);
    end
  endtask

  task automatic wait_for_payload_ready;
    integer wait_cycles;
    begin
      wait_cycles = 0;
      while (!payload_axis_tready && wait_cycles < 200) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end
      if (!payload_axis_tready || !payload_waiting)
        $fatal(1, "payload slot did not reopen after ACK");
    end
  endtask

  task automatic assert_final_commit(
    input logic [23:0] expected_psn,
    input logic [63:0] expected_total_bytes,
    input logic expected_final
  );
    integer index;
    begin
      if (captured_beats != 3 || captured_bytes != 138 ||
          captured_byte(42) != 8'h0A ||
          {captured_byte(51), captured_byte(52), captured_byte(53)} !=
            expected_psn)
        $fatal(1, "final commit frame shape/header mismatch");
      for (index = 0; index < 8; index = index + 1) begin
        if (captured_byte(PAYLOAD_OFFSET + index) !=
            expected_total_bytes[index * 8 +: 8])
          $fatal(1, "final commit total byte %0d mismatch", index);
      end
      if (captured_byte(PAYLOAD_OFFSET + 16) !=
            (expected_final ? 8'h01 : 8'h00) ||
          captured_byte(PAYLOAD_OFFSET + 20) != 8'h41 ||
          captured_byte(PAYLOAD_OFFSET + 21) != 8'h4D ||
          captured_byte(PAYLOAD_OFFSET + 22) != 8'h44 ||
          captured_byte(PAYLOAD_OFFSET + 23) != 8'h52)
        $fatal(1, "final commit marker mismatch");
    end
  endtask

  task automatic wait_for_final_ack;
    integer cycles;
    begin
      cycles = 0;
      while (!final_commit_acked && cycles < 200) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!final_commit_acked || configured || active || stopping ||
          !drained || !cfg_ready || fault)
        $fatal(1, "final ACK did not leave a clean drained endpoint");
    end
  endtask

  task automatic complete_stopped_payload;
    begin
      capture_frame();
      assert_data_frame(INITIAL_PSN);
      send_ack(INITIAL_PSN);
      capture_frame();
      assert_final_commit(INITIAL_PSN + 24'd1, 64'd4096, 1'b1);
      send_ack(INITIAL_PSN + 24'd1);
      wait_for_final_ack();
      if (issued_bytes != 64'd4096 || acked_bytes != 64'd4096 ||
          commit_count != 32'd1 || published_bytes != 64'd4096 ||
          producer_sequence != 64'd1 || retrans_count != 32'd0)
        $fatal(1, "stopped payload counters were incorrect");
    end
  endtask

  integer cycles;
  integer error_count_before_abort;
  integer accepted_count_before_race;
  integer accepted_count_before_second_frame;
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // A complete pre-start payload belongs to the session. STOP on the cycle
    // after START must send and ACK it before publishing the final commit.
    configure_endpoint();
    send_payload_range(0, 63);
    if (payload_accepted_count != 32'd1 || payload_error_count != 32'd0 ||
        payload_axis_tready)
      $fatal(1, "pre-start payload was not retained");
    pulse_start_then_stop();
    complete_stopped_payload();
    if (payload_accepted_count != 32'd1 || payload_error_count != 32'd0)
      $fatal(1, "normal STOP discarded the pre-start payload");

    // A partial frame blocks reconfiguration and remains ready through STOP.
    configure_endpoint();
    send_payload_range(0, 15);
    if (cfg_ready)
      $fatal(1, "cfg_ready asserted with a partial payload frame");
    pulse_start();
    pulse_stop();
    if (!payload_axis_tready)
      $fatal(1, "STOP interrupted an in-progress payload frame");
    send_payload_range(16, 63);
    complete_stopped_payload();
    if (payload_accepted_count != 32'd2 || payload_error_count != 32'd0)
      $fatal(1, "partial STOP payload counters were incorrect");

    // ABORT discards an in-progress frame exactly once, but it still accepts
    // the already-started AXIS frame through TLAST.
    configure_endpoint();
    send_payload_range(0, 3);
    error_count_before_abort = payload_error_count;
    @(negedge clk);
    abort_request = 1'b1;
    payload_axis_tvalid = 1'b1;
    payload_axis_tdata = payload_word(4);
    payload_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    payload_axis_tlast = 1'b0;
    #1ps;
    if (!payload_axis_tready)
      $fatal(1, "ABORT blocked a beat of an in-progress payload frame");
    @(posedge clk);
    @(negedge clk);
    abort_request = 1'b0;
    payload_axis_tdata = payload_word(5);
    payload_axis_tlast = 1'b1;
    #1ps;
    if (!payload_axis_tready)
      $fatal(1, "ABORT flush interrupted payload drop drain");
    @(posedge clk);
    @(negedge clk);
    payload_axis_tvalid = 1'b0;
    payload_axis_tlast = 1'b0;
    cycles = 0;
    while ((!drained || !cfg_ready || configured) && cycles < 20) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    if (!drained || !cfg_ready || configured || !fault ||
        payload_error_count != error_count_before_abort + 1)
      $fatal(1, "ABORT did not discard and count one partial payload");

    // A reconfiguration handshake owns an empty-slot cycle over a new first
    // payload beat; no frame may be accepted and flushed behind the host.
    configure_endpoint();
    accepted_count_before_race = payload_accepted_count;
    @(negedge clk);
    cfg_valid = 1'b1;
    payload_axis_tvalid = 1'b1;
    payload_axis_tdata = payload_word(0);
    payload_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    payload_axis_tlast = 1'b0;
    #1ps;
    if (payload_axis_tready)
      $fatal(1, "configuration handshake also accepted a new payload frame");
    @(posedge clk);
    @(negedge clk);
    cfg_valid = 1'b0;
    payload_axis_tvalid = 1'b0;
    cycles = 0;
    while (!cfg_done && cycles < 20) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    if (!cfg_done || !cfg_accepted ||
        payload_accepted_count != accepted_count_before_race ||
        payload_error_count != error_count_before_abort + 1)
      $fatal(1, "reconfiguration race changed payload counters");

    // STOP and ABORT also own an empty-slot cycle over a new first beat.
    while (!payload_axis_tready) @(posedge clk);
    pulse_start();
    @(negedge clk);
    stop_request = 1'b1;
    payload_axis_tvalid = 1'b1;
    payload_axis_tdata = payload_word(0);
    payload_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    payload_axis_tlast = 1'b0;
    #1ps;
    if (payload_axis_tready)
      $fatal(1, "STOP also accepted a new payload frame");
    @(posedge clk);
    @(negedge clk);
    stop_request = 1'b0;
    payload_axis_tvalid = 1'b0;
    capture_frame();
    assert_final_commit(INITIAL_PSN, 64'd0, 1'b1);
    send_ack(INITIAL_PSN);
    wait_for_final_ack();
    if (payload_accepted_count != accepted_count_before_race ||
        payload_error_count != error_count_before_abort + 1)
      $fatal(1, "empty STOP changed payload counters");

    // A data ACK releases the single payload slot. The same running session
    // must accept a second AXIS frame, wait for returned ring credit, and then
    // transmit it with the next PSN before STOP publishes the final commit.
    configure_endpoint();
    pulse_start();
    accepted_count_before_second_frame = payload_accepted_count;
    send_payload_range(0, 63);
    capture_frame();
    assert_data_frame(INITIAL_PSN);
    send_ack(INITIAL_PSN);
    wait_for_acked_bytes(64'd4096);
    wait_for_payload_ready();
    if (payload_accepted_count != accepted_count_before_second_frame + 1)
      $fatal(1, "first running-session payload was not accepted");

    send_payload_range(0, 63);
    if (payload_accepted_count != accepted_count_before_second_frame + 2 ||
        payload_axis_tready)
      $fatal(1, "second running-session payload lifecycle was incorrect");
    capture_frame();
    assert_final_commit(INITIAL_PSN + 24'd1, 64'd4096, 1'b0);
    send_ack(INITIAL_PSN + 24'd1);
    consumed_bytes = 64'd4096;
    capture_frame();
    assert_data_frame(INITIAL_PSN + 24'd2);
    pulse_stop();
    send_ack(INITIAL_PSN + 24'd2);
    wait_for_acked_bytes(64'd8192);
    capture_frame();
    assert_final_commit(INITIAL_PSN + 24'd3, 64'd8192, 1'b1);
    send_ack(INITIAL_PSN + 24'd3);
    wait_for_final_ack();
    consumed_bytes = 64'd0;
    if (issued_bytes != 64'd8192 || acked_bytes != 64'd8192 ||
        commit_count != 32'd2 || published_bytes != 64'd8192 ||
        producer_sequence != 64'd2 || retrans_count != 32'd0 ||
        payload_accepted_count != accepted_count_before_second_frame + 2 ||
        payload_error_count != error_count_before_abort + 1)
      $fatal(1, "two-payload running-session counters were incorrect");

    accepted_count_before_race = payload_accepted_count;
    configure_endpoint();
    pulse_start();
    @(negedge clk);
    abort_request = 1'b1;
    payload_axis_tvalid = 1'b1;
    payload_axis_tdata = payload_word(0);
    payload_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
    payload_axis_tlast = 1'b0;
    #1ps;
    if (payload_axis_tready)
      $fatal(1, "ABORT also accepted a new payload frame");
    @(posedge clk);
    @(negedge clk);
    abort_request = 1'b0;
    payload_axis_tvalid = 1'b0;
    cycles = 0;
    while ((!drained || !cfg_ready || configured) && cycles < 20) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    if (!drained || !cfg_ready || configured ||
        payload_accepted_count != accepted_count_before_race ||
        payload_error_count != error_count_before_abort + 1)
      $fatal(1, "empty ABORT changed payload lifecycle state");

    $display("rdma_external_lifecycle_tb PASS");
    $finish;
  end
endmodule
