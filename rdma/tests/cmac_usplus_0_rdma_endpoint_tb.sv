`timescale 1ns / 1ps

module cmac_usplus_0_rdma_endpoint_tb;

  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [47:0] REMOTE_MAC_A = 48'h02_00_00_00_00_A0;
  localparam logic [47:0] REMOTE_MAC_B = 48'h02_00_00_00_00_B0;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_010B;
  localparam logic [31:0] REMOTE_IP = 32'hC0A8_010A;
  localparam logic [7:0] AETH_ACK = 8'h1F;
  localparam logic [7:0] AETH_RNR_TIMER_1 = 8'h21;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic [31:0] rx_overflow_source_count = 32'd0;

  logic cfg_apply = 1'b0;
  logic cfg_start = 1'b0;
  logic cfg_stop = 1'b0;
  logic [47:0] cfg_remote_mac = REMOTE_MAC_A;
  logic [31:0] cfg_remote_ip = REMOTE_IP;
  logic [23:0] cfg_remote_qpn = 24'h12_34_56;
  logic [23:0] cfg_local_psn = 24'hFF_FFFE;
  logic [47:0] cfg_remote_base = 48'h0000_0100_0000;
  logic [31:0] cfg_rkey = 32'hA5A5_5A5A;
  logic [31:0] cfg_ring_size = 32'd16384;
  logic [31:0] cfg_wr_size = 32'd4096;
  logic [63:0] cfg_local_base = 64'd0;
  logic cfg_enable_immediate = 1'b0;
  logic [31:0] cfg_notify_interval_bytes = 32'd8192;
  logic [47:0] cfg_commit_remote_addr = cfg_remote_base + 48'd16384;

  logic rx_axis_tvalid = 1'b0;
  logic rx_axis_tready;
  logic [511:0] rx_axis_tdata = 512'd0;
  logic [63:0] rx_axis_tkeep = 64'd0;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;

  logic tx_axis_tready = 1'b1;
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
  logic [31:0] config_reject_count;
  logic [31:0] config_reject_reason;
  logic [31:0] icrc_drop_count;
  logic [31:0] invalid_psn_count;
  logic [31:0] nak_count;
  logic [31:0] retrans_count;
  logic [31:0] retry_exhausted_count;
  logic [31:0] rx_overflow_count;
  logic [31:0] tx_underflow_count;
  logic [63:0] issued_bytes;
  logic [63:0] acked_bytes;
  logic [31:0] ring_offset;
  logic [23:0] current_psn;
  logic [3:0] debug_state;
  logic [31:0] commit_count;
  logic [31:0] immediate_count;
  logic [63:0] published_bytes;
  logic [63:0] producer_sequence;

  logic [7:0] captured [0:8191];
  logic [7:0] original_captured [0:8191];
  integer captured_byte_count;
  logic [23:0] forced_ack_psn;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .ACK_TIMEOUT_CYCLES(200),
    .MAX_RETRIES(2),
    .RNR_TIMER_10US_CYCLES(8)
  ) dut (
    .clk(clk),
    .reset(reset),
    .local_ip(LOCAL_IP),
    .rx_overflow_source_count(rx_overflow_source_count),
    .cfg_valid(cfg_apply),
    .cfg_ready(),
    .cfg_done(),
    .cfg_accepted(),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_local_base(cfg_local_base),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .start_request(cfg_start),
    .stop_request(cfg_stop),
    .abort_request(1'b0),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(tx_axis_tkeep),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),
    .configured(configured),
    .active(active),
    .stopping(stopping),
    .drained(drained),
    .fault(fault),
    .fault_reason(fault_reason),
    .final_commit_acked(final_commit_acked),
    .config_reject_count(config_reject_count),
    .config_reject_reason(config_reject_reason),
    .icrc_drop_count(icrc_drop_count),
    .invalid_psn_count(invalid_psn_count),
    .nak_count(nak_count),
    .retrans_count(retrans_count),
    .retry_exhausted_count(retry_exhausted_count),
    .rx_overflow_count(rx_overflow_count),
    .tx_underflow_count(tx_underflow_count),
    .issued_bytes(issued_bytes),
    .acked_bytes(acked_bytes),
    .ring_offset(ring_offset),
    .current_psn(current_psn),
    .debug_state(debug_state),
    .commit_count(commit_count),
    .immediate_count(immediate_count),
    .published_bytes(published_bytes),
    .producer_sequence(producer_sequence)
  );

  function automatic logic [7:0] get_byte(input logic [511:0] data, input integer index);
    begin
      get_byte = data[index * 8 +: 8];
    end
  endfunction

  function automatic logic [23:0] get_be24(input logic [511:0] data, input integer index);
    begin
      get_be24 = {get_byte(data, index), get_byte(data, index + 1),
                  get_byte(data, index + 2)};
    end
  endfunction

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (index = 0; index < 8; index = index + 1) begin
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      end
      crc32_byte_ref = crc;
    end
  endfunction

  function automatic logic [15:0] ipv4_checksum_ref(
    input logic [15:0] total_length,
    input logic [15:0] identification,
    input logic [31:0] source_ip,
    input logic [31:0] destination_ip
  );
    logic [19:0] sum;
    begin
      sum = 20'd0;
      sum = sum + 16'h4500 + total_length + identification + 16'h4000 + 16'h4011;
      sum = sum + source_ip[31:16] + source_ip[15:0];
      sum = sum + destination_ip[31:16] + destination_ip[15:0];
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
    begin
      data[index * 8 +: 8] = value;
    end
  endtask

  task automatic build_ack(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input logic corrupt_icrc,
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
      put_byte(data, 6, REMOTE_MAC_A[47:40]);
      put_byte(data, 7, REMOTE_MAC_A[39:32]);
      put_byte(data, 8, REMOTE_MAC_A[31:24]);
      put_byte(data, 9, REMOTE_MAC_A[23:16]);
      put_byte(data, 10, REMOTE_MAC_A[15:8]);
      put_byte(data, 11, REMOTE_MAC_A[7:0]);
      put_byte(data, 12, 8'h08);
      put_byte(data, 13, 8'h00);
      ip_checksum = ipv4_checksum_ref(16'd48, 16'h0020, REMOTE_IP, LOCAL_IP);
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
      put_byte(data, 54, syndrome);
      put_byte(data, 55, 8'h00);
      put_byte(data, 56, 8'h00);
      put_byte(data, 57, 8'h00);
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
      if (corrupt_icrc) icrc = icrc ^ 32'h0000_0001;
      put_byte(data, 58, icrc[7:0]);
      put_byte(data, 59, icrc[15:8]);
      put_byte(data, 60, icrc[23:16]);
      put_byte(data, 61, icrc[31:24]);
    end
  endtask

  task automatic pulse_apply;
    begin
      @(negedge clk);
      cfg_apply = 1'b1;
      @(negedge clk);
      cfg_apply = 1'b0;
    end
  endtask

  task automatic pulse_start;
    begin
      @(negedge clk);
      cfg_start = 1'b1;
      @(negedge clk);
      cfg_start = 1'b0;
    end
  endtask

  task automatic pulse_stop;
    begin
      @(negedge clk);
      cfg_stop = 1'b1;
      @(negedge clk);
      cfg_stop = 1'b0;
    end
  endtask

  task automatic pulse_start_then_stop_idle;
    begin
      @(negedge clk);
      cfg_start = 1'b1;
      @(negedge clk);
      cfg_start = 1'b0;
      cfg_stop = 1'b1;
      @(negedge clk);
      cfg_stop = 1'b0;
    end
  endtask

  task automatic send_ack(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input logic corrupt_icrc
  );
    logic [511:0] data;
    begin
      build_ack(psn, syndrome, corrupt_icrc, data);
      while (!rx_axis_tready) @(posedge clk);
      @(negedge clk);
      rx_axis_tdata = data;
      rx_axis_tkeep = 64'h3FFF_FFFF_FFFF_FFFF;
      rx_axis_tlast = 1'b1;
      rx_axis_tuser = 1'b0;
      rx_axis_tvalid = 1'b1;
      @(negedge clk);
      rx_axis_tvalid = 1'b0;
      rx_axis_tlast = 1'b0;
      rx_axis_tkeep = 64'd0;
      rx_axis_tdata = 512'd0;
    end
  endtask

  task automatic send_ack_after_tx_beats(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input integer beat_count
  );
    integer observed_beats;
    begin
      observed_beats = 0;
      while (observed_beats < beat_count) begin
        @(posedge clk);
        if (tx_axis_tvalid && tx_axis_tready) observed_beats = observed_beats + 1;
      end
      send_ack(psn, syndrome, 1'b0);
    end
  endtask

  // Directly align an already-validated ACK indication to the final beat of a
  // retry. This exercises the scheduler race independently of RX parsing.
  task automatic acknowledge_on_final_tx_beat(input logic [23:0] psn);
    begin
      while (retrans_count == 32'd0) @(posedge clk);
      while (!(tx_axis_tvalid && tx_axis_tready && tx_axis_tlast)) @(negedge clk);
      forced_ack_psn = psn;
      force dut.rx_ack_pulse = 1'b1;
      force dut.rx_ack_psn = forced_ack_psn;
      force dut.rx_ack_psn_matches = (forced_ack_psn == dut.inflight_psn);
      force dut.rx_ack_is_nak = 1'b0;
      force dut.rx_ack_syndrome = AETH_ACK;
      @(posedge clk);
      @(negedge clk);
      release dut.rx_ack_pulse;
      release dut.rx_ack_psn;
      release dut.rx_ack_psn_matches;
      release dut.rx_ack_is_nak;
      release dut.rx_ack_syndrome;
    end
  endtask

  task automatic reset_and_apply(input logic [23:0] initial_psn);
    begin
      @(negedge clk);
      reset = 1'b1;
      cfg_apply = 1'b0;
      cfg_start = 1'b0;
      cfg_stop = 1'b0;
      rx_axis_tvalid = 1'b0;
      rx_axis_tlast = 1'b0;
      rx_axis_tkeep = 64'd0;
      rx_axis_tdata = 512'd0;
      tx_axis_tready = 1'b1;
      cfg_remote_mac = REMOTE_MAC_A;
      cfg_local_psn = initial_psn;
      repeat (5) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      pulse_apply();
      repeat (4) @(posedge clk);
      if (!configured || !drained || fault) begin
        $fatal(1, "configuration was not accepted after reset");
      end
    end
  endtask

  task automatic verify_board_apply_configuration;
    begin
      cfg_remote_mac = 48'h6CB3_1121_E4DC;
      cfg_remote_ip = 32'hC0A8_110A;
      cfg_remote_qpn = 24'd9;
      cfg_local_psn = 24'd11618228;
      cfg_remote_base = 48'h7FCD_EFBF_F000;
      cfg_rkey = 32'hB0FC_6F39;
      cfg_ring_size = 32'd1073741824;
      cfg_wr_size = 32'd10485760;
      cfg_local_base = 64'd0;
      cfg_enable_immediate = 1'b0;
      cfg_notify_interval_bytes = 32'd10485760;
      cfg_commit_remote_addr = 48'h7FCE_2FBF_F000;

      repeat (5) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      pulse_apply();
      repeat (4) @(posedge clk);
      if (!configured || config_reject_count != 32'd0 ||
          config_reject_reason != 32'd0) begin
        $fatal(1,
               "control-plane configuration rejected: identity=%0b sizes=%0b commit=%0b remote_end=%h commit_end=%h reason=%h",
               dut.cfg_identity_valid, dut.cfg_sizes_valid, dut.cfg_commit_valid,
               dut.cfg_snapshot_remote_end, dut.cfg_snapshot_commit_end,
               config_reject_reason);
      end

      @(negedge clk);
      cfg_notify_interval_bytes = 32'd10485761;
      pulse_apply();
      repeat (4) @(posedge clk);
      if (config_reject_count != 32'd1 || config_reject_reason != 32'h0000_2000) begin
        $fatal(1, "notify alignment reject reason mismatch: count=%0d reason=%h",
               config_reject_count, config_reject_reason);
      end
      if (dut.session_local_qpn != 24'd1 ||
          dut.session_remote_base != 48'h7FCD_EFBF_F000) begin
        $fatal(1, "rejected configuration overwrote the accepted session");
      end

      @(negedge clk);
      reset = 1'b1;
      cfg_remote_mac = REMOTE_MAC_A;
      cfg_remote_ip = REMOTE_IP;
      cfg_remote_qpn = 24'h12_34_56;
      cfg_local_psn = 24'hFF_FFFE;
      cfg_remote_base = 48'h0000_0100_0000;
      cfg_rkey = 32'hA5A5_5A5A;
      cfg_ring_size = 32'd16384;
      cfg_wr_size = 32'd4096;
      cfg_local_base = 64'd0;
      cfg_enable_immediate = 1'b0;
      cfg_notify_interval_bytes = 32'd8192;
      cfg_commit_remote_addr = 48'h0000_0100_4000;
    end
  endtask

  task automatic receive_packet(
    output logic [511:0] first_word,
    output logic [511:0] final_word,
    output logic [63:0] final_keep,
    output integer byte_count
  );
    integer beat_byte;
    integer word_count;
    logic seen_first;
    logic seen_last;
    begin
      byte_count = 0;
      word_count = 0;
      seen_first = 1'b0;
      seen_last = 1'b0;
      first_word = 512'd0;
      final_word = 512'd0;
      final_keep = 64'd0;
      while (!seen_last) begin
        @(posedge clk);
        if (tx_axis_tvalid && tx_axis_tready) begin
          if (!seen_first) begin
            first_word = tx_axis_tdata;
            seen_first = 1'b1;
          end
          for (beat_byte = 0; beat_byte < 64; beat_byte = beat_byte + 1) begin
            if (tx_axis_tkeep[beat_byte]) begin
              captured[byte_count] = tx_axis_tdata[beat_byte * 8 +: 8];
              byte_count = byte_count + 1;
            end
          end
          word_count = word_count + 1;
          if (tx_axis_tlast) begin
            final_word = tx_axis_tdata;
            final_keep = tx_axis_tkeep;
            seen_last = 1'b1;
          end
        end
      end
      captured_byte_count = byte_count;
    end
  endtask

  task automatic assert_packet_header(
    input logic [511:0] first_word,
    input logic [23:0] expected_psn,
    input logic [47:0] expected_remote_mac,
    input logic [47:0] expected_remote_address
  );
    begin
      if ({get_byte(first_word, 0), get_byte(first_word, 1), get_byte(first_word, 2),
           get_byte(first_word, 3), get_byte(first_word, 4), get_byte(first_word, 5)} != expected_remote_mac) begin
        $fatal(1, "wrong destination MAC");
      end
      if (get_byte(first_word, 12) != 8'h08 || get_byte(first_word, 13) != 8'h00) begin
        $fatal(1, "wrong Ethernet type");
      end
      if (get_byte(first_word, 42) != 8'h0A || get_be24(first_word, 47) != cfg_remote_qpn ||
          get_byte(first_word, 50) != 8'h80 || get_be24(first_word, 51) != expected_psn) begin
        $fatal(1, "wrong BTH fields");
      end
      if (get_byte(first_word, 54) != 8'd0 || get_byte(first_word, 55) != 8'd0 ||
          {get_byte(first_word, 56), get_byte(first_word, 57), get_byte(first_word, 58),
           get_byte(first_word, 59), get_byte(first_word, 60), get_byte(first_word, 61)} != expected_remote_address) begin
        $fatal(1, "wrong RETH remote address");
      end
    end
  endtask

  task automatic assert_benchmark_payload(input logic [31:0] expected_sequence);
    integer index;
    begin
      if ({captured[70], captured[71], captured[72], captured[73]} != 32'h5246_534F ||
          {captured[74], captured[75], captured[76], captured[77]} != expected_sequence ||
          {captured[78], captured[79]} != 16'd1 ||
          {captured[80], captured[81]} != 16'd24 ||
          {captured[82], captured[83], captured[84], captured[85]} != 32'd4096) begin
        $fatal(1,
               "wrong RFSO header: magic=%h sequence=%h version=%h header=%h length=%h",
               {captured[70], captured[71], captured[72], captured[73]},
               {captured[74], captured[75], captured[76], captured[77]},
               {captured[78], captured[79]}, {captured[80], captured[81]},
               {captured[82], captured[83], captured[84], captured[85]});
      end
      for (index = 86; index < 94; index = index + 1) begin
        if (captured[index] != 8'd0) begin
          $fatal(1, "nonzero RFSO reserved byte at packet offset %0d", index - 70);
        end
      end
    end
  endtask

  task automatic assert_captured_icrc;
    logic [31:0] crc;
    logic [31:0] actual_icrc;
    logic [7:0] crc_byte;
    integer index;
    begin
      if (captured_byte_count != 4170) $fatal(1, "wrong packet byte count %0d", captured_byte_count);
      if ({captured[66], captured[67], captured[68], captured[69]} != 32'd4096) begin
        $fatal(1, "wrong RETH length");
      end
      if (captured[94] != 8'h03 || captured[95] != 8'h00 ||
          captured[4158] != 8'hFF || captured[4159] != 8'h01) begin
        $fatal(1, "payload after the RFSO header is not local_address >> 3");
      end
      crc = 32'hDEBB_20E3;
      for (index = 0; index < 4152; index = index + 1) begin
        crc_byte = captured[14 + index];
        case (index)
          1, 8, 10, 11, 26, 27, 32: crc_byte = 8'hFF;
          default: crc_byte = crc_byte;
        endcase
        crc = crc32_byte_ref(crc, crc_byte);
      end
      actual_icrc = {captured[4169], captured[4168], captured[4167], captured[4166]};
      if (actual_icrc != ~crc) $fatal(1, "packet ICRC mismatch");
    end
  endtask

  task automatic assert_plain_commit(
    input logic [511:0] first_word,
    input logic [23:0] expected_psn,
    input logic [63:0] expected_sequence,
    input logic [63:0] expected_total_bytes,
    input logic [31:0] expected_end_offset,
    input logic [31:0] expected_interval_bytes,
    input logic expected_final
  );
    logic [47:0] remote_address;
    begin
      remote_address = {get_byte(first_word, 56), get_byte(first_word, 57),
                        get_byte(first_word, 58), get_byte(first_word, 59),
                        get_byte(first_word, 60), get_byte(first_word, 61)};
      if (captured_byte_count != 138 || get_byte(first_word, 42) != 8'h0A ||
          get_be24(first_word, 51) != expected_psn ||
          remote_address != cfg_commit_remote_addr ||
          {captured[66], captured[67], captured[68], captured[69]} != 32'd64 ||
          {captured[77], captured[76], captured[75], captured[74],
           captured[73], captured[72], captured[71], captured[70]} != expected_total_bytes ||
          {captured[81], captured[80], captured[79], captured[78]} != expected_end_offset ||
          {captured[85], captured[84], captured[83], captured[82]} != expected_interval_bytes ||
          {captured[89], captured[88], captured[87], captured[86]} !=
            {31'd0, expected_final} ||
          {captured[117], captured[116], captured[115], captured[114],
           captured[113], captured[112], captured[111], captured[110]} != expected_sequence) begin
        $fatal(1, "wrong polling commit: bytes=%0d opcode=%h psn=%h addr=%h len=%h total=%h end=%h interval=%h final=%h seq=%h",
               captured_byte_count, get_byte(first_word, 42), get_be24(first_word, 51),
               remote_address, {captured[66], captured[67], captured[68], captured[69]},
               {captured[77], captured[76], captured[75], captured[74],
                captured[73], captured[72], captured[71], captured[70]},
               {captured[81], captured[80], captured[79], captured[78]},
               {captured[85], captured[84], captured[83], captured[82]},
               {captured[89], captured[88], captured[87], captured[86]},
               {captured[117], captured[116], captured[115], captured[114],
                captured[113], captured[112], captured[111], captured[110]});
      end
    end
  endtask

  initial begin
    logic [511:0] first_packet;
    logic [511:0] retry_packet;
    logic [511:0] second_packet;
    logic [511:0] third_packet;
    logic [511:0] final_packet;
    logic [63:0] final_keep;
    integer byte_count;
    integer index;
    integer syndrome_value;

    verify_board_apply_configuration();
    repeat (5) @(posedge clk);
    reset = 1'b0;
    pulse_apply();
    // Validation is pipelined, so mutate the live VIO input immediately after
    // the apply edge to prove that the accepted session uses the edge snapshot.
    cfg_remote_mac = REMOTE_MAC_B;
    repeat (3) @(posedge clk);
    if (!configured || !drained || fault) $fatal(1, "configuration was not accepted");

    // A Gray-synchronized source count may advance by several events between
    // endpoint clocks. Account for the complete delta.
    @(negedge clk);
    rx_overflow_source_count = 32'd7;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (rx_overflow_count != 32'd7) $fatal(1, "overflow counter lost a multi-event delta");
    rx_overflow_source_count = 32'd12;
    repeat (2) @(posedge clk);
    @(negedge clk);
    if (rx_overflow_count != 32'd12) $fatal(1, "overflow counter lost a later delta");

    pulse_start();
    while (!tx_axis_tvalid) @(negedge clk);
    first_packet = tx_axis_tdata;
    tx_axis_tready = 1'b0;
    repeat (3) @(posedge clk);
    if (!tx_axis_tvalid || tx_axis_tdata !== first_packet) $fatal(1, "AXIS backpressure changed packet data");
    @(negedge clk);
    tx_axis_tready = 1'b1;
    receive_packet(first_packet, final_packet, final_keep, byte_count);
    assert_packet_header(first_packet, 24'hFF_FFFE, REMOTE_MAC_A, cfg_remote_base);
    assert_benchmark_payload(32'd0);
    assert_captured_icrc();

    // Let the first packet time out once. The retry must reproduce the frame,
    // and an ACK coincident with its final beat must retire it exactly once.
    fork
      receive_packet(retry_packet, final_packet, final_keep, byte_count);
      acknowledge_on_final_tx_beat(24'hFF_FFFE);
    join
    if (retry_packet !== first_packet) $fatal(1, "retransmission header changed");
    if (retrans_count != 32'd1) $fatal(1, "timeout retransmission was not counted");
    repeat (4) @(posedge clk);
    if (fault || acked_bytes != 64'd4096 || issued_bytes != 64'd4096 ||
        current_psn != 24'hFF_FFFF || debug_state == 4'd4) begin
      $fatal(1, "delayed ACK on retry final beat did not retire the WR");
    end

    receive_packet(second_packet, final_packet, final_keep, byte_count);
    assert_packet_header(second_packet, 24'hFF_FFFF, REMOTE_MAC_A, cfg_remote_base + 48'd4096);
    assert_benchmark_payload(32'd1);

    // ICRC-invalid and wrong-PSN ACKs are observable and do not complete the WR.
    send_ack(24'hFF_FFFF, AETH_ACK, 1'b1);
    repeat (55) @(posedge clk);
    if (icrc_drop_count != 32'd1 || acked_bytes != 64'd4096) $fatal(1, "bad ICRC ACK was accepted");
    send_ack(24'hFF_FFFE, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    if (invalid_psn_count == 32'd0 || acked_bytes != 64'd4096) $fatal(1, "wrong PSN ACK was accepted");
    send_ack(24'hFF_FFFF, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    if (acked_bytes != 64'd8192 || issued_bytes != 64'd8192) $fatal(1, "second ACK did not retire data");
    if (ring_offset != 32'd8192) $fatal(1, "ring offset advanced incorrectly");

    // A plain commit lets Linux poll producer_sequence without posted RQEs.
    receive_packet(third_packet, final_packet, final_keep, byte_count);
    assert_plain_commit(third_packet, 24'd0, 64'd1, 64'd8192, 32'd8192,
                        32'd8192, 1'b0);
    send_ack(24'd0, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    if (current_psn != 24'd1 || commit_count != 32'd1 || immediate_count != 32'd0 ||
        published_bytes != 64'd8192 || producer_sequence != 64'd1) begin
      $fatal(1, "polling commit state is wrong");
    end

    receive_packet(third_packet, final_packet, final_keep, byte_count);
    assert_packet_header(third_packet, 24'd1, REMOTE_MAC_A,
                         cfg_remote_base + 48'd8192);
    assert_benchmark_payload(32'd2);
    pulse_stop();
    send_ack(24'd1, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    receive_packet(final_packet, retry_packet, final_keep, byte_count);
    assert_plain_commit(final_packet, 24'd2, 64'd2, 64'd12288, 32'd12288,
                        32'd4096, 1'b1);
    send_ack(24'd2, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    if (!drained || active || fault || acked_bytes != 64'd12288 ||
        published_bytes != 64'd12288 || producer_sequence != 64'd2) begin
      $fatal(1, "stop did not drain and publish the active packet");
    end

    // A wrong-PSN ACK that completes while the frame is on the wire must be
    // deferred until TLAST and must not retire or duplicate the outstanding WR.
    reset_and_apply(24'h01_0203);
    pulse_start();
    fork
      receive_packet(first_packet, final_packet, final_keep, byte_count);
      send_ack_after_tx_beats(24'h01_0204, AETH_ACK, 4);
    join
    assert_benchmark_payload(32'd0);
    repeat (8) @(posedge clk);
    if (captured_byte_count != 4170 || invalid_psn_count != 32'd1 ||
        acked_bytes != 64'd0 || current_psn != 24'h01_0203 || fault) begin
      $fatal(1, "mid-frame wrong-PSN ACK changed the outstanding WR");
    end
    for (index = 0; index < captured_byte_count; index = index + 1) begin
      original_captured[index] = captured[index];
    end

    // RNR timer code 1 maps to one scaled 10 us unit. No replay may begin
    // before that delay, and the complete BRAM-backed frame must be identical.
    send_ack(24'h01_0203, AETH_RNR_TIMER_1, 1'b0);
    index = 0;
    while ((debug_state != 4'd7) && (index < 100)) begin
      @(posedge clk);
      index = index + 1;
    end
    if (debug_state != 4'd7 || nak_count != 32'd1) begin
      $fatal(1, "RNR response did not enter the retry-delay state");
    end
    repeat (7) begin
      @(posedge clk);
      if (tx_axis_tvalid) $fatal(1, "RNR replay began before the encoded delay elapsed");
    end
    fork
      receive_packet(retry_packet, final_packet, final_keep, byte_count);
      send_ack_after_tx_beats(24'h01_0203, AETH_ACK, 4);
    join
    for (index = 0; index < captured_byte_count; index = index + 1) begin
      if (captured[index] !== original_captured[index]) begin
        $fatal(1, "RNR replay changed byte %0d", index);
      end
    end
    repeat (8) @(posedge clk);
    if (acked_bytes != 64'd4096 || issued_bytes != 64'd4096 ||
        current_psn != 24'h01_0204 || retrans_count != 32'd1 ||
        nak_count != 32'd1 || fault) begin
      $fatal(1, "mid-frame matching ACK did not retire exactly one complete replay");
    end

    // Stopping in the scheduler's idle gap publishes a zero-byte final record
    // before the first data WR can be selected.
    reset_and_apply(24'h02_0000);
    pulse_start_then_stop_idle();
    receive_packet(final_packet, retry_packet, final_keep, byte_count);
    assert_plain_commit(final_packet, 24'h02_0000, 64'd1, 64'd0, 32'd0,
                        32'd0, 1'b1);
    send_ack(24'h02_0000, AETH_ACK, 1'b0);
    repeat (55) @(posedge clk);
    if (!drained || active || fault || issued_bytes != 64'd0 || acked_bytes != 64'd0 ||
        commit_count != 32'd1 || published_bytes != 64'd0 || producer_sequence != 64'd1) begin
      $fatal(1, "idle stop did not publish and ACK a zero-byte final commit");
    end

    // AETH sequence error (0x60) and fatal NAKs (0x61..0x64) are not safely
    // recoverable by this single-outstanding bring-up endpoint.
    for (syndrome_value = 8'h60; syndrome_value <= 8'h64;
         syndrome_value = syndrome_value + 1) begin
      reset_and_apply(24'h03_0000 + syndrome_value);
      pulse_start();
      receive_packet(first_packet, final_packet, final_keep, byte_count);
      send_ack(24'h03_0000 + syndrome_value, syndrome_value[7:0], 1'b0);
      repeat (60) @(posedge clk);
      if (!fault || active || nak_count != 32'd1 || retrans_count != 32'd0 ||
          acked_bytes != 64'd0) begin
        $fatal(1, "AETH syndrome %h did not stop the QP immediately", syndrome_value[7:0]);
      end
    end

    $display("cmac_usplus_0_rdma_endpoint_tb PASS");
    $finish;
  end

endmodule
