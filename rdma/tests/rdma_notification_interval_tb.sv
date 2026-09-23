`timescale 1ns / 1ps

// Exercises the real 4 KiB packet scheduler over production notification
// sizes. It runs once per NOTIFY_INTERVAL_BYTES test plusarg.
module cmac_usplus_0_rdma_notification_interval_tb #(
  parameter integer NOTIFY_INTERVAL_BYTES = 1024 * 1024,
  parameter bit FAST_BENCHMARK_MODE = 1'b0,
  parameter integer WR_SIZE_BYTES = 1024 * 1024,
  parameter integer RING_SIZE_BYTES = 16 * 1024 * 1024,
  parameter logic [23:0] INITIAL_PSN = 24'h00_4000,
  parameter integer MAX_SEQUENCE_RECOVERIES = 12,
  parameter bit RETRANSMISSION_ENABLE = 1'b1,
  parameter bit STOP_AT_FIRST_WR_BOUNDARY = 1'b0,
  parameter bit INJECT_CREDIT_RESERVATION_NAK_RACE = 1'b0,
  parameter bit INJECT_DATA_SEQUENCE_NAK = 1'b0,
  parameter bit INJECT_COMMIT_SEQUENCE_NAK = 1'b0,
  parameter bit INJECT_OUT_OF_WINDOW_SEQUENCE_NAK = 1'b0,
  parameter bit INJECT_SECOND_SEQUENCE_NAK = 1'b0,
  parameter bit EXPECT_SECOND_SEQUENCE_RECOVERY = 1'b0,
  parameter bit INJECT_CROSS_MESSAGE_SEQUENCE_NAK = 1'b0,
  parameter bit INJECT_SEQUENCE_RECOVERY_LIMIT = 1'b0,
  parameter bit INJECT_FATAL_DATA_NAK = 1'b0,
  parameter bit INJECT_RING_BOUNDARY_SEQUENCE_NAK = 1'b0,
  parameter bit HOLD_RECOVERY_PATH_BUSY = 1'b0,
  parameter bit INJECT_ABORT = 1'b0
);

  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [47:0] REMOTE_MAC = 48'h02_00_00_00_00_A0;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_010B;
  localparam logic [31:0] REMOTE_IP = 32'hC0A8_010A;
  localparam logic [47:0] REMOTE_BASE = 48'h0000_0100_0000;
  logic clk = 1'b0;
  logic reset = 1'b1;
  logic cfg_apply = 1'b0;
  logic cfg_start = 1'b0;
  logic cfg_stop = 1'b0;
  logic cfg_abort = 1'b0;
  logic [63:0] consumed_bytes = 64'd0;
  logic [47:0] cfg_remote_mac = REMOTE_MAC;
  logic [31:0] cfg_remote_ip = REMOTE_IP;
  logic [23:0] cfg_remote_qpn = 24'h12_34_56;
  logic [23:0] cfg_local_psn = INITIAL_PSN;
  logic [47:0] cfg_remote_base = REMOTE_BASE;
  logic [31:0] cfg_rkey = 32'hA5A5_5A5A;
  logic [31:0] cfg_ring_size = RING_SIZE_BYTES;
  logic [31:0] cfg_wr_size = WR_SIZE_BYTES;
  logic [63:0] cfg_local_base = 64'd0;
  logic cfg_enable_immediate = 1'b1;
  logic [31:0] cfg_notify_interval_bytes = 32'd1 * 1024 * 1024;
  logic [47:0] cfg_commit_remote_addr = REMOTE_BASE + RING_SIZE_BYTES;

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
  logic credit_stalled;
  logic [7:0] last_nak_syndrome;
  logic [23:0] last_nak_psn;
  logic [31:0] sequence_recovery_count;
  logic replay_active;
  logic tx_path_idle = 1'b1;
  longint unsigned cycle_count = 0;
  longint unsigned tx_transfer_count = 0;

  always #2 clk = ~clk;
  always @(posedge clk) cycle_count <= cycle_count + 1;
  always @(posedge clk) begin
    if (tx_axis_tvalid && tx_axis_tready) begin
      tx_transfer_count <= tx_transfer_count + 1;
    end
  end

  cmac_usplus_0_rdma_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .ACK_TIMEOUT_CYCLES(2000),
    .MAX_RETRIES(2),
    .MAX_SEQUENCE_RECOVERIES(MAX_SEQUENCE_RECOVERIES),
    .SEQUENCE_RECOVERY_QUIET_CYCLES(8),
    .FAST_BENCHMARK_MODE(FAST_BENCHMARK_MODE)
  ) dut (
    .clk(clk),
    .reset(reset),
    .local_ip(LOCAL_IP),
    .rx_overflow_source_count(32'd0),
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
    .cfg_use_external_payload(1'b0),
    .start_request(cfg_start),
    .stop_request(cfg_stop),
    .abort_request(cfg_abort),
    .consumed_bytes(consumed_bytes),
    .tx_path_idle(tx_path_idle),
    .retransmission_enable(RETRANSMISSION_ENABLE),
    .payload_packet_valid(1'b0),
    .payload_packet_length(16'd0),
    .payload_packet_release(),
    .payload_buffer_empty(1'b1),
    .payload_ingress_enable(),
    .payload_flush(),
    .payload_read_enable(),
    .payload_read_address(),
    .payload_read_data(512'd0),
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
    .credit_stalled(credit_stalled),
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
    .producer_sequence(producer_sequence),
    .last_nak_syndrome(last_nak_syndrome),
    .last_nak_psn(last_nak_psn),
    .sequence_recovery_count(sequence_recovery_count),
    .replay_active(replay_active),
    .external_payload_active()
  );

  function automatic logic [7:0] get_byte(input logic [511:0] data, input integer index);
    begin
      get_byte = data[index * 8 +: 8];
    end
  endfunction

  function automatic logic [15:0] get_be16(input logic [511:0] data, input integer index);
    begin
      get_be16 = {get_byte(data, index), get_byte(data, index + 1)};
    end
  endfunction

  function automatic logic [23:0] get_be24(input logic [511:0] data, input integer index);
    begin
      get_be24 = {get_byte(data, index), get_byte(data, index + 1),
                  get_byte(data, index + 2)};
    end
  endfunction

  function automatic logic [31:0] get_be32(input logic [511:0] data, input integer index);
    begin
      get_be32 = {get_byte(data, index), get_byte(data, index + 1),
                  get_byte(data, index + 2), get_byte(data, index + 3)};
    end
  endfunction

  function automatic logic [31:0] get_le32(input logic [511:0] data, input integer index);
    begin
      get_le32 = {get_byte(data, index + 3), get_byte(data, index + 2),
                  get_byte(data, index + 1), get_byte(data, index)};
    end
  endfunction

  function automatic logic [63:0] get_le64(input logic [511:0] data, input integer index);
    begin
      get_le64 = {get_byte(data, index + 7), get_byte(data, index + 6),
                  get_byte(data, index + 5), get_byte(data, index + 4),
                  get_byte(data, index + 3), get_byte(data, index + 2),
                  get_byte(data, index + 1), get_byte(data, index)};
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

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
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

  task automatic build_response(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
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
      ip_checksum = ipv4_checksum_ref(16'd48, 16'h0020, REMOTE_IP, LOCAL_IP);
      put_byte(data, 14, 8'h45);
      put_byte(data, 16, 8'h00);
      put_byte(data, 17, 8'h30);
      put_byte(data, 18, 8'h00);
      put_byte(data, 19, 8'h20);
      put_byte(data, 20, 8'h40);
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
      put_byte(data, 42, 8'h11);
      put_byte(data, 43, 8'h00);
      put_byte(data, 44, 8'hFF);
      put_byte(data, 45, 8'hFF);
      put_byte(data, 47, 8'h00);
      put_byte(data, 48, 8'h00);
      put_byte(data, 49, 8'h01);
      put_byte(data, 50, 8'h80);
      put_byte(data, 51, psn[23:16]);
      put_byte(data, 52, psn[15:8]);
      put_byte(data, 53, psn[7:0]);
      put_byte(data, 54, syndrome);
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

  task automatic pulse_abort;
    begin
      @(negedge clk);
      cfg_abort = 1'b1;
      @(negedge clk);
      cfg_abort = 1'b0;
    end
  endtask

  task automatic drive_response(input logic [23:0] psn, input logic [7:0] syndrome);
    logic [511:0] data;
    begin
      build_response(psn, syndrome, data);
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

  task automatic send_response(input logic [23:0] psn, input logic [7:0] syndrome);
    begin
      drive_response(psn, syndrome);
      repeat (55) @(posedge clk);
    end
  endtask

  task automatic send_ack(input logic [23:0] psn);
    begin
      send_response(psn, 8'h1F);
    end
  endtask

  task automatic send_sequence_nak(input logic [23:0] psn);
    begin
      send_response(psn, 8'h60);
    end
  endtask

  task automatic capture_packet(
    output logic [511:0] first_word,
    output logic [511:0] second_word
  );
    logic seen_first;
    logic seen_second;
    logic seen_last;
    logic [31:0] crc;
    logic [31:0] actual_icrc;
    logic [7:0] checked_byte;
    integer beat_index;
    integer byte_index;
    integer absolute_offset;
    integer icrc_start;
    begin
      first_word = 512'd0;
      second_word = 512'd0;
      seen_first = 1'b0;
      seen_second = 1'b0;
      seen_last = 1'b0;
      crc = 32'hDEBB_20E3;
      actual_icrc = 32'd0;
      beat_index = 0;
      icrc_start = -1;
      while (!seen_last) begin
        @(posedge clk);
        if (FAST_BENCHMARK_MODE && seen_first && tx_axis_tready &&
            !tx_axis_tvalid) begin
          $fatal(1, "fast packet inserted an AXIS bubble before TLAST at beat %0d",
                 beat_index);
        end
        if (tx_axis_tvalid && tx_axis_tready) begin
          if (!seen_first) begin
            first_word = tx_axis_tdata;
            seen_first = 1'b1;
            icrc_start = 14 + get_be16(tx_axis_tdata, 16) - 4;
          end else if (!seen_second) begin
            second_word = tx_axis_tdata;
            seen_second = 1'b1;
          end
          for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
            if (tx_axis_tkeep[byte_index]) begin
              absolute_offset = beat_index * 64 + byte_index;
              checked_byte = get_byte(tx_axis_tdata, byte_index);
              if ((absolute_offset >= 14) && (absolute_offset < icrc_start)) begin
                case (absolute_offset - 14)
                  1, 8, 10, 11, 26, 27, 32: checked_byte = 8'hFF;
                  default: checked_byte = checked_byte;
                endcase
                crc = crc32_byte_ref(crc, checked_byte);
              end else if ((absolute_offset >= icrc_start) &&
                           (absolute_offset < (icrc_start + 4))) begin
                case (absolute_offset - icrc_start)
                  0: actual_icrc[7:0] = checked_byte;
                  1: actual_icrc[15:8] = checked_byte;
                  2: actual_icrc[23:16] = checked_byte;
                  default: actual_icrc[31:24] = checked_byte;
                endcase
              end
            end
          end
          beat_index = beat_index + 1;
          if (tx_axis_tlast) begin
            seen_last = 1'b1;
            if (actual_icrc != ~crc) begin
              $fatal(1, "data packet ICRC mismatch: actual=%h expected=%h",
                     actual_icrc, ~crc);
            end
          end
        end
      end
    end
  endtask

  task automatic capture_immediate_commit(
    output logic [511:0] first_word,
    output logic [511:0] second_word,
    output logic [511:0] third_word,
    output logic [63:0] third_keep
  );
    integer beat_count;
    begin
      first_word = 512'd0;
      second_word = 512'd0;
      third_word = 512'd0;
      third_keep = 64'd0;
      beat_count = 0;
      while (beat_count < 3) begin
        @(posedge clk);
        if (tx_axis_tvalid && tx_axis_tready) begin
          case (beat_count)
            0: first_word = tx_axis_tdata;
            1: second_word = tx_axis_tdata;
            default: begin
              third_word = tx_axis_tdata;
              third_keep = tx_axis_tkeep;
              if (!tx_axis_tlast) begin
                $fatal(1, "Immediate commit did not end on beat three: opcode=%h psn=%h physical_remaining=%0d logical_remaining=%0d replay=%b replay_remaining=%0d issued=%0d",
                       get_byte(first_word, 42), get_be24(first_word, 51),
                       dut.physical_message_remaining,
                       dut.logical_wr_remaining, dut.replay_active,
                       dut.replay_remaining_bytes, issued_bytes);
              end
            end
          endcase
          beat_count = beat_count + 1;
        end
      end
    end
  endtask

  function automatic logic [7:0] commit_packet_byte(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic [511:0] third_word,
    input integer index
  );
    begin
      if (index < 64) begin
        commit_packet_byte = get_byte(first_word, index);
      end else if (index < 128) begin
        commit_packet_byte = get_byte(second_word, index - 64);
      end else begin
        commit_packet_byte = get_byte(third_word, index - 128);
      end
    end
  endfunction

  task automatic assert_data_packet(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic [23:0] expected_psn,
    input logic [7:0] expected_opcode,
    input logic expected_reth,
    input logic [47:0] expected_remote_address,
    input logic [31:0] expected_reth_length
  );
    logic [47:0] remote_address;
    begin
      remote_address = {get_byte(first_word, 56), get_byte(first_word, 57),
                        get_byte(first_word, 58), get_byte(first_word, 59),
                        get_byte(first_word, 60), get_byte(first_word, 61)};
      if (get_byte(first_word, 42) != expected_opcode ||
          get_byte(first_word, 50) !=
            (FAST_BENCHMARK_MODE ? 8'h00 : 8'h80) ||
          get_be24(first_word, 51) != expected_psn ||
          (expected_reth && (remote_address != expected_remote_address ||
                             get_be32(second_word, 2) != expected_reth_length))) begin
        $fatal(1, "bad data packet: opcode=%h psn=%h addr=%h length=%h expected_opcode=%h",
               get_byte(first_word, 42), get_be24(first_word, 51), remote_address,
               get_be32(second_word, 2), expected_opcode);
      end
    end
  endtask

  function automatic logic [7:0] data_packet_byte(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input integer index
  );
    begin
      if (index < 64) begin
        data_packet_byte = get_byte(first_word, index);
      end else begin
        data_packet_byte = get_byte(second_word, index - 64);
      end
    end
  endfunction

  task automatic assert_rfso_header(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic expected_reth,
    input logic [31:0] expected_sequence
  );
    integer payload_start;
    integer index;
    begin
      payload_start = expected_reth ? 70 : 54;
      if (data_packet_byte(first_word, second_word, payload_start) != 8'h52 ||
          data_packet_byte(first_word, second_word, payload_start + 1) != 8'h46 ||
          data_packet_byte(first_word, second_word, payload_start + 2) != 8'h53 ||
          data_packet_byte(first_word, second_word, payload_start + 3) != 8'h4F ||
          {data_packet_byte(first_word, second_word, payload_start + 4),
           data_packet_byte(first_word, second_word, payload_start + 5),
           data_packet_byte(first_word, second_word, payload_start + 6),
           data_packet_byte(first_word, second_word, payload_start + 7)} !=
             expected_sequence ||
          {data_packet_byte(first_word, second_word, payload_start + 8),
           data_packet_byte(first_word, second_word, payload_start + 9)} != 16'd1 ||
          {data_packet_byte(first_word, second_word, payload_start + 10),
           data_packet_byte(first_word, second_word, payload_start + 11)} != 16'd24 ||
          data_packet_byte(first_word, second_word, payload_start + 12) != 8'd0 ||
          data_packet_byte(first_word, second_word, payload_start + 13) != 8'd0 ||
          {data_packet_byte(first_word, second_word, payload_start + 14),
           data_packet_byte(first_word, second_word, payload_start + 15)} != 16'd4096) begin
        $fatal(1, "wrong RFSO header: reth=%0b sequence=%0d", expected_reth,
               expected_sequence);
      end
      for (index = 16; index < 24; index = index + 1) begin
        if (data_packet_byte(first_word, second_word, payload_start + index) != 8'd0) begin
          $fatal(1, "nonzero RFSO reserved byte at packet offset %0d", index);
        end
      end
    end
  endtask

  task automatic assert_immediate_commit(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic [23:0] expected_psn,
    input logic [63:0] expected_sequence,
    input logic [63:0] expected_total_bytes,
    input logic [31:0] expected_end_offset,
    input logic [31:0] expected_interval,
    input logic expected_final
  );
    logic [47:0] remote_address;
    begin
      remote_address = {get_byte(first_word, 56), get_byte(first_word, 57),
                        get_byte(first_word, 58), get_byte(first_word, 59),
                        get_byte(first_word, 60), get_byte(first_word, 61)};
      if (get_byte(first_word, 42) != 8'h0B ||
          get_be24(first_word, 51) != expected_psn ||
          remote_address != cfg_commit_remote_addr ||
          get_be32(second_word, 2) != 32'd64 ||
          get_be32(second_word, 6) != expected_sequence[31:0] ||
          get_le64(second_word, 10) != expected_total_bytes ||
          get_le32(second_word, 18) != expected_end_offset ||
          get_le32(second_word, 22) != expected_interval ||
          get_le32(second_word, 26) != {31'd0, expected_final} ||
          get_le32(second_word, 30) != 32'h5244_4D41 ||
          get_le64(second_word, 50) != expected_sequence) begin
        $fatal(1, "bad interval commit: opcode=%h psn=%h addr=%h len=%h imm=%h total=%h end=%h interval=%h magic=%h seq=%h",
               get_byte(first_word, 42), get_be24(first_word, 51), remote_address,
               get_be32(second_word, 2), get_be32(second_word, 6),
               get_le64(second_word, 10), get_le32(second_word, 18),
               get_le32(second_word, 22), get_le32(second_word, 30),
               get_le64(second_word, 50));
      end
    end
  endtask

  task automatic assert_immediate_commit_icrc(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic [511:0] third_word,
    input logic [63:0] third_keep
  );
    logic [31:0] crc;
    logic [31:0] actual_icrc;
    logic [7:0] crc_byte;
    integer index;
    begin
      if (third_keep != 64'h0000_0000_0000_3FFF) begin
        $fatal(1, "Immediate commit tail tkeep is wrong: %h", third_keep);
      end
      crc = 32'hDEBB_20E3;
      for (index = 0; index < 124; index = index + 1) begin
        crc_byte = commit_packet_byte(first_word, second_word, third_word, 14 + index);
        case (index)
          1, 8, 10, 11, 26, 27, 32: crc_byte = 8'hFF;
          default: crc_byte = crc_byte;
        endcase
        crc = crc32_byte_ref(crc, crc_byte);
      end
      actual_icrc = {commit_packet_byte(first_word, second_word, third_word, 141),
                     commit_packet_byte(first_word, second_word, third_word, 140),
                     commit_packet_byte(first_word, second_word, third_word, 139),
                     commit_packet_byte(first_word, second_word, third_word, 138)};
      if (actual_icrc != ~crc) begin
        $fatal(1, "Immediate commit ICRC mismatch: actual=%h expected=%h", actual_icrc, ~crc);
      end
    end
  endtask

  initial begin
    logic [511:0] first_word;
    logic [511:0] second_word;
    logic [511:0] commit_first_word;
    logic [511:0] commit_second_word;
    logic [511:0] commit_third_word;
    logic [511:0] retry_first_word;
    logic [511:0] retry_second_word;
    logic [511:0] retry_third_word;
    logic [63:0] commit_third_keep;
    logic [63:0] retry_third_keep;
    logic [23:0] expected_psn;
    logic [7:0] expected_opcode;
    logic expected_reth;
    integer interval_bytes;
    integer packet_count;
    integer packet_index;
    integer recovery_target;
    longint unsigned data_start_cycle;
    longint unsigned data_elapsed_cycles;
    longint unsigned recovery_release_cycle;
    logic [511:0] stalled_word;
    logic [31:0] credit_before_nak;

    interval_bytes = NOTIFY_INTERVAL_BYTES;
    if ((interval_bytes <= 0) || ((interval_bytes % 4096) != 0)) begin
      $fatal(1, "interval regression requires a nonzero 4 KiB multiple, got %0d",
             interval_bytes);
    end
    cfg_notify_interval_bytes = interval_bytes;
    packet_count = STOP_AT_FIRST_WR_BOUNDARY ?
                   (WR_SIZE_BYTES / 4096) : (interval_bytes / 4096);

    repeat (5) @(posedge clk);
    reset = 1'b0;
    pulse_apply();
    repeat (3) @(posedge clk);
    if (!configured || fault || !drained) $fatal(1, "interval configuration was not accepted");
    if (INJECT_ABORT) tx_axis_tready = 1'b0;
    pulse_start();
    data_start_cycle = cycle_count;

    if (INJECT_CREDIT_RESERVATION_NAK_RACE) begin
      wait (issued_bytes >= 64'd4096);
      @(negedge clk iff (debug_state == 4'd2));
      credit_before_nak = dut.available_credit_bytes;
      force dut.rx_ack_pulse = 1'b1;
      force dut.rx_ack_psn = INITIAL_PSN;
      force dut.rx_ack_is_nak = 1'b1;
      force dut.rx_ack_syndrome = 8'h60;
      @(posedge clk);
      @(negedge clk);
      release dut.rx_ack_pulse;
      release dut.rx_ack_psn;
      release dut.rx_ack_is_nak;
      release dut.rx_ack_syndrome;
      if (dut.available_credit_bytes != credit_before_nak) begin
        $fatal(1,
               "sequence NAK at credit reservation leaked credit: before=%0d after=%0d",
               credit_before_nak, dut.available_credit_bytes);
      end
      wait (replay_active || fault);
      if (fault) begin
        $fatal(1, "credit reservation race faulted instead of replaying: reason=%h",
               fault_reason);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-credit-reservation-nak-race");
      $finish;
    end

    if (INJECT_RING_BOUNDARY_SEQUENCE_NAK) begin
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                         1'b1, REMOTE_BASE, 32'd8192);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd0);
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd1, 8'h08,
                         1'b0, 48'd0, 32'd0);
      assert_rfso_header(first_word, second_word, 1'b0, 32'd1);
      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd2, 64'd1, 64'd8192,
                              32'd8192, 32'd8192, 1'b0);
      drive_response(INITIAL_PSN + 24'd2, 8'h1F);
      wait (published_bytes == 64'd8192);
      consumed_bytes = 64'd8192;

      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd3, 8'h0A,
                         1'b1, REMOTE_BASE + 48'd8192, 32'd4096);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd2);

      // Model loss of the ring-tail packet: the responder can report the
      // missing PSN only after the following commit reaches it. The commit
      // barrier must retain the tail message checkpoint until that response.
      fork
        capture_immediate_commit(commit_first_word, commit_second_word,
                                 commit_third_word, commit_third_keep);
        begin
          @(negedge clk iff (dut.inflight_is_commit &&
                             (debug_state == 4'd5) && tx_axis_tvalid));
          drive_response(INITIAL_PSN + 24'd3, 8'h60);
        end
      join
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd4, 64'd2, 64'd12288,
                              32'd0, 32'd4096, 1'b0);
      wait (replay_active);
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd3, 8'h0A,
                         1'b1, REMOTE_BASE + 48'd8192, 32'd4096);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd2);

      capture_immediate_commit(retry_first_word, retry_second_word,
                               retry_third_word, retry_third_keep);
      assert_immediate_commit(retry_first_word, retry_second_word,
                              INITIAL_PSN + 24'd4, 64'd2, 64'd12288,
                              32'd0, 32'd4096, 1'b0);
      assert_immediate_commit_icrc(retry_first_word, retry_second_word,
                                   retry_third_word, retry_third_keep);
      send_ack(INITIAL_PSN + 24'd4);

      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd5, 8'h0A,
                         1'b1, REMOTE_BASE, 32'd4096);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd3);
      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd6, 64'd3, 64'd16384,
                              32'd4096, 32'd4096, 1'b0);
      pulse_stop();
      send_ack(INITIAL_PSN + 24'd6);
      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd7, 64'd4, 64'd16384,
                              32'd4096, 32'd0, 1'b1);
      send_ack(INITIAL_PSN + 24'd7);
      repeat (20) @(posedge clk);
      if (!drained || active || fault || nak_count != 32'd1 ||
          retrans_count != 32'd1 || sequence_recovery_count != 32'd1 ||
          commit_count != 32'd4 || producer_sequence != 64'd4 ||
          published_bytes != 64'd16384 || issued_bytes != 64'd16384 ||
          acked_bytes != 64'd16384 || ring_offset != 32'd4096) begin
        $fatal(1, "ring-boundary recovery state is wrong: drained=%b active=%b fault=%b nak=%0d retrans=%0d recovery=%0d commits=%0d seq=%0d published=%0d issued=%0d acked=%0d ring=%0d",
               drained, active, fault, nak_count, retrans_count,
               sequence_recovery_count, commit_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes, ring_offset);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-ring-boundary-sequence-recovery");
      $finish;
    end

    if (INJECT_OUT_OF_WINDOW_SEQUENCE_NAK || INJECT_FATAL_DATA_NAK) begin
      fork
        capture_packet(first_word, second_word);
        begin
          @(negedge clk iff (tx_axis_tvalid && (debug_state == 4'd5)));
          drive_response(INJECT_FATAL_DATA_NAK ? INITIAL_PSN :
                         (INITIAL_PSN - 24'd1),
                         INJECT_FATAL_DATA_NAK ? 8'h61 : 8'h60);
        end
      join
      repeat (100) @(posedge clk);
      if (!fault || active || configured || nak_count != 32'd1 ||
          retrans_count != 32'd0 || sequence_recovery_count != 32'd0 ||
          last_nak_syndrome != (INJECT_FATAL_DATA_NAK ? 8'h61 : 8'h60) ||
          last_nak_psn != (INJECT_FATAL_DATA_NAK ? INITIAL_PSN :
                           (INITIAL_PSN - 24'd1)) ||
          fault_reason != (INJECT_FATAL_DATA_NAK ?
                           32'h0000_0103 : 32'h0000_0101) ||
          tx_axis_tvalid) begin
        $fatal(1, "invalid/fatal NAK did not quiesce safely: active=%b configured=%b fault=%b reason=%h syndrome=%h psn=%h nak=%0d retrans=%0d recovery=%0d tx_valid=%b",
               active, configured, fault, fault_reason, last_nak_syndrome,
               last_nak_psn, nak_count, retrans_count,
               sequence_recovery_count, tx_axis_tvalid);
      end
      if (INJECT_FATAL_DATA_NAK)
        $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-fatal-nak");
      else
        $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-out-of-window-nak");
      $finish;
    end

    if (INJECT_SEQUENCE_RECOVERY_LIMIT) begin
      for (packet_index = 0; packet_index < MAX_SEQUENCE_RECOVERIES;
           packet_index = packet_index + 1) begin
        fork
          begin
            capture_packet(first_word, second_word);
            assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                               1'b1, REMOTE_BASE, WR_SIZE_BYTES);
            assert_rfso_header(first_word, second_word, 1'b1, 32'd0);
          end
          begin
            @(negedge clk iff (tx_axis_tvalid && (debug_state == 4'd5)));
            drive_response(INITIAL_PSN, 8'h60);
          end
        join

        recovery_target = 0;
        while ((sequence_recovery_count != (packet_index + 1)) &&
               (recovery_target < 300)) begin
          @(posedge clk);
          recovery_target = recovery_target + 1;
          if (fault) begin
            $fatal(1, "sequence recovery %0d faulted before the configured limit: reason=%h",
                   packet_index + 1, fault_reason);
          end
        end
        if (sequence_recovery_count != (packet_index + 1) ||
            retrans_count != (packet_index + 1) ||
            nak_count != (packet_index + 1)) begin
          $fatal(1, "sequence recovery %0d did not complete: nak=%0d retrans=%0d recovery=%0d",
                 packet_index + 1, nak_count, retrans_count,
                 sequence_recovery_count);
        end
      end

      fork
        begin
          capture_packet(first_word, second_word);
          assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                             1'b1, REMOTE_BASE, WR_SIZE_BYTES);
          assert_rfso_header(first_word, second_word, 1'b1, 32'd0);
        end
        begin
          @(negedge clk iff (tx_axis_tvalid && (debug_state == 4'd5)));
          drive_response(INITIAL_PSN, 8'h60);
        end
      join

      repeat (100) @(posedge clk);
      if (!fault || active || configured || fault_reason != 32'h0000_0102 ||
          nak_count != (MAX_SEQUENCE_RECOVERIES + 1) ||
          retrans_count != MAX_SEQUENCE_RECOVERIES ||
          sequence_recovery_count != MAX_SEQUENCE_RECOVERIES ||
          last_nak_syndrome != 8'h60 || last_nak_psn != INITIAL_PSN ||
          tx_axis_tvalid) begin
        $fatal(1, "default sequence recovery limit did not quiesce on NAK %0d: active=%b configured=%b fault=%b reason=%h nak=%0d retrans=%0d recovery=%0d tx_valid=%b",
               MAX_SEQUENCE_RECOVERIES + 1, active, configured, fault,
               fault_reason, nak_count, retrans_count,
               sequence_recovery_count, tx_axis_tvalid);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-default-sequence-recovery-limit recoveries=%0d",
               MAX_SEQUENCE_RECOVERIES);
      $finish;
    end

    if (INJECT_SECOND_SEQUENCE_NAK) begin
      recovery_target = 1;
      for (packet_index = 0; packet_index < 4; packet_index = packet_index + 1) begin
        capture_packet(first_word, second_word);
        expected_psn = INITIAL_PSN + packet_index;
        expected_reth = packet_index == 0;
        expected_opcode = expected_reth ? 8'h06 :
                          ((packet_index == (packet_count - 1)) ? 8'h08 : 8'h07);
        assert_data_packet(first_word, second_word, expected_psn, expected_opcode,
                           expected_reth, REMOTE_BASE + (packet_index * 4096),
                           WR_SIZE_BYTES);
        assert_rfso_header(first_word, second_word, expected_reth, packet_index);
      end
      drive_response(INITIAL_PSN + recovery_target, 8'h60);
      wait (replay_active);
      fork
        begin
          capture_packet(first_word, second_word);
          assert_data_packet(first_word, second_word,
                             INITIAL_PSN + recovery_target, 8'h07, 1'b0,
                             REMOTE_BASE + (recovery_target * 4096),
                             WR_SIZE_BYTES);
          assert_rfso_header(first_word, second_word, 1'b0, recovery_target);
        end
        begin
          @(negedge clk iff (replay_active && tx_axis_tvalid &&
                             (debug_state == 4'd5)));
          drive_response(INITIAL_PSN + recovery_target, 8'h60);
        end
      join

      if (!EXPECT_SECOND_SEQUENCE_RECOVERY) begin
        repeat (100) @(posedge clk);
        if (!fault || active || configured || fault_reason != 32'h0000_0102 ||
            nak_count != 32'd2 || retrans_count != 32'd1 ||
            sequence_recovery_count != 32'd1 || last_nak_syndrome != 8'h60 ||
            last_nak_psn != (INITIAL_PSN + recovery_target) || tx_axis_tvalid) begin
          $fatal(1, "sequence recovery limit did not quiesce safely: active=%b configured=%b fault=%b reason=%h syndrome=%h psn=%h nak=%0d retrans=%0d recovery=%0d tx_valid=%b",
                 active, configured, fault, fault_reason, last_nak_syndrome,
                 last_nak_psn, nak_count, retrans_count,
                 sequence_recovery_count, tx_axis_tvalid);
        end
        $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-sequence-recovery-limit");
        $finish;
      end

      @(negedge clk);
      fork : wait_for_second_sequence_recovery
        begin
          wait (replay_active);
        end
        begin
          repeat (300) begin
            @(posedge clk);
            if (fault) begin
              $fatal(1, "second sequence NAK faulted instead of rewinding: reason=%h",
                     fault_reason);
            end
          end
          $fatal(1, "second sequence NAK did not rewind to requested PSN");
        end
      join_any
      disable wait_for_second_sequence_recovery;
      for (packet_index = recovery_target; packet_index < packet_count;
           packet_index = packet_index + 1) begin
        capture_packet(first_word, second_word);
        expected_psn = INITIAL_PSN + packet_index;
        expected_reth = packet_index == 0;
        if (expected_reth) begin
          expected_opcode = (packet_count == 1) ? 8'h0A : 8'h06;
        end else if (packet_index == (packet_count - 1)) begin
          expected_opcode = 8'h08;
        end else begin
          expected_opcode = 8'h07;
        end
        assert_data_packet(first_word, second_word, expected_psn, expected_opcode,
                           expected_reth, REMOTE_BASE + (packet_index * 4096),
                           WR_SIZE_BYTES);
        assert_rfso_header(first_word, second_word, expected_reth, packet_index);
      end

      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      expected_psn = INITIAL_PSN + packet_count;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd1, interval_bytes, interval_bytes,
                              interval_bytes, 1'b0);
      pulse_stop();
      send_ack(expected_psn);

      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      expected_psn = expected_psn + 24'd1;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd2, interval_bytes, interval_bytes, 32'd0, 1'b1);
      send_ack(expected_psn);
      repeat (20) @(posedge clk);
      if (!drained || active || fault || nak_count != 32'd2 ||
          retrans_count != 32'd2 || sequence_recovery_count != 32'd2 ||
          commit_count != 32'd2 || producer_sequence != 64'd2 ||
          published_bytes != interval_bytes || issued_bytes != interval_bytes ||
          acked_bytes != interval_bytes || ring_offset != interval_bytes) begin
        $fatal(1, "repeated sequence recovery state is wrong: drained=%b active=%b fault=%b nak=%0d retrans=%0d recovery=%0d commits=%0d seq=%0d published=%0d issued=%0d acked=%0d ring=%0d",
               drained, active, fault, nak_count, retrans_count,
               sequence_recovery_count, commit_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes, ring_offset);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-repeated-sequence-recovery");
      $finish;
    end

    if (INJECT_CROSS_MESSAGE_SEQUENCE_NAK) begin
      fork
        begin
          capture_packet(first_word, second_word);
          assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                             1'b1, REMOTE_BASE, WR_SIZE_BYTES);
          assert_rfso_header(first_word, second_word, 1'b1, 32'd0);
        end
        begin
          @(negedge clk iff (tx_axis_tvalid && (debug_state == 4'd5)));
          drive_response(INITIAL_PSN, 8'h60);
        end
      join
      fork : wait_for_first_cross_message_recovery
        begin
          wait (replay_active);
        end
        begin
          repeat (300) begin
            @(posedge clk);
            if (fault) begin
              $fatal(1, "first message sequence NAK faulted: reason=%h",
                     fault_reason);
            end
          end
          $fatal(1, "first message sequence NAK did not start replay");
        end
      join_any
      disable wait_for_first_cross_message_recovery;
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                         1'b1, REMOTE_BASE, WR_SIZE_BYTES);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd0);
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd1, 8'h08,
                         1'b0, 48'd0, 32'd0);
      assert_rfso_header(first_word, second_word, 1'b0, 32'd1);

      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd2, 64'd1, 64'd8192,
                              32'd8192, 32'd8192, 1'b0);
      send_ack(INITIAL_PSN + 24'd2);

      fork
        begin
          capture_packet(first_word, second_word);
          assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd3,
                             8'h06, 1'b1, REMOTE_BASE + 48'd8192,
                             WR_SIZE_BYTES);
          assert_rfso_header(first_word, second_word, 1'b1, 32'd2);
        end
        begin
          @(negedge clk iff (tx_axis_tvalid && (debug_state == 4'd5)));
          drive_response(INITIAL_PSN + 24'd3, 8'h60);
        end
      join
      fork : wait_for_second_cross_message_recovery
        begin
          wait (replay_active);
        end
        begin
          repeat (300) begin
            @(posedge clk);
            if (fault) begin
              $fatal(1, "second message sequence NAK faulted: reason=%h",
                     fault_reason);
            end
          end
          $fatal(1, "second message sequence NAK did not start replay");
        end
      join_any
      disable wait_for_second_cross_message_recovery;
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd3,
                         8'h06, 1'b1, REMOTE_BASE + 48'd8192,
                         WR_SIZE_BYTES);
      assert_rfso_header(first_word, second_word, 1'b1, 32'd2);
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN + 24'd4, 8'h08,
                         1'b0, 48'd0, 32'd0);
      assert_rfso_header(first_word, second_word, 1'b0, 32'd3);

      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd5, 64'd2, 64'd16384,
                              32'd16384, 32'd8192, 1'b0);
      pulse_stop();
      send_ack(INITIAL_PSN + 24'd5);
      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      assert_immediate_commit(commit_first_word, commit_second_word,
                              INITIAL_PSN + 24'd6, 64'd3, 64'd16384,
                              32'd16384, 32'd0, 1'b1);
      send_ack(INITIAL_PSN + 24'd6);
      repeat (20) @(posedge clk);
      if (!drained || active || fault || nak_count != 32'd2 ||
          retrans_count != 32'd2 || sequence_recovery_count != 32'd2 ||
          commit_count != 32'd3 || producer_sequence != 64'd3 ||
          published_bytes != 64'd16384 || issued_bytes != 64'd16384 ||
          acked_bytes != 64'd16384 || ring_offset != 32'd16384) begin
        $fatal(1, "cross-message recovery state is wrong: drained=%b active=%b fault=%b nak=%0d retrans=%0d recovery=%0d commits=%0d seq=%0d published=%0d issued=%0d acked=%0d ring=%0d",
               drained, active, fault, nak_count, retrans_count,
               sequence_recovery_count, commit_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes, ring_offset);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-cross-message-sequence-recovery");
      $finish;
    end

    if (INJECT_ABORT) begin
      @(negedge clk iff tx_axis_tvalid);
      stalled_word = tx_axis_tdata;
      pulse_abort();
      repeat (6) begin
        @(negedge clk);
        if (!tx_axis_tvalid || tx_axis_tdata !== stalled_word ||
            fault || drained || active) begin
          $fatal(1, "ABORT altered stalled frame: valid=%b fault=%b drained=%b active=%b",
                 tx_axis_tvalid, fault, drained, active);
        end
      end
      tx_axis_tready = 1'b1;
      capture_packet(first_word, second_word);
      assert_data_packet(first_word, second_word, INITIAL_PSN, 8'h06,
                         1'b1, REMOTE_BASE, WR_SIZE_BYTES);
      repeat (10) @(posedge clk);
      if (!fault || !drained || configured || active || tx_axis_tvalid ||
          fault_reason != 32'h8000_0001) begin
        $fatal(1, "ABORT drain failed: configured=%b active=%b drained=%b fault=%b reason=%h valid=%b",
               configured, active, drained, fault, fault_reason, tx_axis_tvalid);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-ABORT-frame-boundary");
      $finish;
    end

    if (INJECT_DATA_SEQUENCE_NAK) begin
      recovery_target = (packet_count == 2560) ? 1946 : (packet_count * 3) / 4;
      for (packet_index = 0; packet_index < (recovery_target + 4);
           packet_index = packet_index + 1) begin
        capture_packet(first_word, second_word);
        expected_psn = INITIAL_PSN + packet_index;
        expected_reth = packet_index == 0;
        expected_opcode = expected_reth ? 8'h06 : 8'h07;
        assert_data_packet(first_word, second_word, expected_psn, expected_opcode,
                           expected_reth, REMOTE_BASE + (packet_index * 4096),
                           WR_SIZE_BYTES);
        assert_rfso_header(first_word, second_word, expected_reth, packet_index);
      end

      if (HOLD_RECOVERY_PATH_BUSY) tx_path_idle = 1'b0;
      drive_response(INITIAL_PSN + recovery_target, 8'h60);
      if (!RETRANSMISSION_ENABLE) begin
        repeat (100) @(posedge clk);
        if (!fault || configured || active ||
            fault_reason != 32'h0000_0005 || nak_count != 32'd1 ||
            retrans_count != 32'd0 || sequence_recovery_count != 32'd0 ||
            replay_active || tx_axis_tvalid) begin
          $fatal(1, "disabled fast replay did not quiesce safely");
        end
        $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-retransmission-disabled");
        $finish;
      end
      if (HOLD_RECOVERY_PATH_BUSY) begin
        wait (dut.fast_nak_pending);
        repeat (32) begin
          @(posedge clk);
          if (replay_active ||
              (dut.session_tx_psn == (INITIAL_PSN + recovery_target))) begin
            $fatal(1, "sequence replay started before the board TX path drained");
          end
        end
        send_sequence_nak(INITIAL_PSN + recovery_target);
        if (nak_count != 32'd1 || sequence_recovery_count != 32'd0) begin
          $fatal(1, "buffered duplicate NAK was not coalesced: nak=%0d recovery=%0d",
                 nak_count, sequence_recovery_count);
        end
        recovery_release_cycle = cycle_count;
        tx_path_idle = 1'b1;
      end
      fork : wait_for_sequence_rewind
        begin
          wait (dut.session_tx_psn == (INITIAL_PSN + recovery_target));
        end
        begin
          repeat (300) begin
            @(posedge clk);
            if (fault) begin
              $fatal(1, "sequence NAK faulted instead of rewinding: reason=%h",
                     fault_reason);
            end
          end
          $fatal(1, "sequence NAK did not rewind to requested PSN");
        end
      join_any
      disable wait_for_sequence_rewind;
      if (HOLD_RECOVERY_PATH_BUSY &&
          ((cycle_count - recovery_release_cycle) < 8)) begin
        $fatal(1, "sequence recovery did not observe the response quiet window");
      end

      for (packet_index = recovery_target; packet_index < packet_count;
           packet_index = packet_index + 1) begin
        capture_packet(first_word, second_word);
        expected_psn = INITIAL_PSN + packet_index;
        expected_reth = packet_index == 0;
        if (expected_reth) begin
          expected_opcode = (packet_count == 1) ? 8'h0A : 8'h06;
        end else if (packet_index == (packet_count - 1)) begin
          expected_opcode = 8'h08;
        end else begin
          expected_opcode = 8'h07;
        end
        assert_data_packet(first_word, second_word, expected_psn, expected_opcode,
                           expected_reth, REMOTE_BASE + (packet_index * 4096),
                           WR_SIZE_BYTES);
        assert_rfso_header(first_word, second_word, expected_reth, packet_index);
      end

      capture_immediate_commit(commit_first_word, commit_second_word, commit_third_word,
                               commit_third_keep);
      expected_psn = INITIAL_PSN + packet_count;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd1, interval_bytes, interval_bytes,
                              interval_bytes, 1'b0);
      pulse_stop();
      send_ack(expected_psn);

      capture_immediate_commit(commit_first_word, commit_second_word, commit_third_word,
                               commit_third_keep);
      expected_psn = expected_psn + 24'd1;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd2, interval_bytes, interval_bytes, 32'd0, 1'b1);
      send_ack(expected_psn);
      repeat (20) @(posedge clk);
      if (!drained || active || fault || nak_count != 32'd1 ||
          retrans_count != 32'd1 || retry_exhausted_count != 32'd0 ||
          commit_count != 32'd2 || producer_sequence != 64'd2 ||
          published_bytes != interval_bytes || issued_bytes != interval_bytes ||
          acked_bytes != interval_bytes) begin
        $fatal(1, "sequence recovery final state is wrong: drained=%b active=%b fault=%b nak=%0d retrans=%0d exhausted=%0d commits=%0d seq=%0d published=%0d issued=%0d acked=%0d",
               drained, active, fault, nak_count, retrans_count,
               retry_exhausted_count, commit_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-data-sequence-recovery target=%0d",
               recovery_target);
      $finish;
    end

    for (packet_index = 0; packet_index < packet_count; packet_index = packet_index + 1) begin
      capture_packet(first_word, second_word);
      expected_psn = INITIAL_PSN + packet_index;
      expected_reth = (packet_index % (WR_SIZE_BYTES / 4096)) == 0;
      if (expected_reth) begin
        expected_opcode = 8'h06;
      end else if ((packet_index % (WR_SIZE_BYTES / 4096)) ==
                   ((WR_SIZE_BYTES / 4096) - 1)) begin
        expected_opcode = 8'h08;
      end else begin
        expected_opcode = 8'h07;
      end
      assert_data_packet(first_word, second_word, expected_psn, expected_opcode,
                          expected_reth, REMOTE_BASE + (packet_index * 4096),
                          WR_SIZE_BYTES);
      assert_rfso_header(first_word, second_word, expected_reth, packet_index);
      if (!FAST_BENCHMARK_MODE) send_ack(expected_psn);
    end
    data_elapsed_cycles = cycle_count - data_start_cycle;
    if (FAST_BENCHMARK_MODE &&
        (data_elapsed_cycles > (longint'(packet_count) * 80 + 100))) begin
      $fatal(1, "fast path exceeded cycle budget: packets=%0d cycles=%0d",
             packet_count, data_elapsed_cycles);
    end

    if (INJECT_COMMIT_SEQUENCE_NAK) begin
      expected_psn = INITIAL_PSN + packet_count;
      fork
        capture_immediate_commit(commit_first_word, commit_second_word,
                                 commit_third_word, commit_third_keep);
        begin
          @(negedge clk iff (dut.inflight_is_commit &&
                             (debug_state == 4'd5) && tx_axis_tvalid));
          drive_response(expected_psn, 8'h60);
        end
      join
      if (!RETRANSMISSION_ENABLE) begin
        repeat (100) @(posedge clk);
        if (!fault || configured || active ||
            fault_reason != 32'h0000_0005 || nak_count != 32'd1 ||
            retrans_count != 32'd0 || sequence_recovery_count != 32'd0 ||
            last_nak_syndrome != 8'h60 || last_nak_psn != expected_psn ||
            tx_axis_tvalid) begin
          $fatal(1, "disabled retransmission did not block commit replay");
        end
        $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-commit-retransmission-disabled");
        $finish;
      end
      capture_immediate_commit(retry_first_word, retry_second_word,
                               retry_third_word, retry_third_keep);
      if (retry_first_word !== commit_first_word ||
          retry_second_word !== commit_second_word ||
          retry_third_word !== commit_third_word ||
          retry_third_keep !== commit_third_keep) begin
        $fatal(1, "sequence-NAK commit replay changed its wire image");
      end
      pulse_stop();
      send_ack(expected_psn);

      capture_immediate_commit(commit_first_word, commit_second_word,
                               commit_third_word, commit_third_keep);
      expected_psn = expected_psn + 24'd1;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd2, interval_bytes, interval_bytes, 32'd0, 1'b1);
      send_ack(expected_psn);
      repeat (20) @(posedge clk);
      if (!drained || active || fault || nak_count != 32'd1 ||
          retrans_count != 32'd1 || sequence_recovery_count != 32'd0 ||
          commit_count != 32'd2 || producer_sequence != 64'd2 ||
          published_bytes != interval_bytes || issued_bytes != interval_bytes ||
          acked_bytes != interval_bytes) begin
        $fatal(1, "commit sequence recovery state is wrong: drained=%b active=%b fault=%b nak=%0d retrans=%0d recovery=%0d commits=%0d seq=%0d published=%0d issued=%0d acked=%0d",
               drained, active, fault, nak_count, retrans_count,
               sequence_recovery_count, commit_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS fast-commit-sequence-recovery");
      $finish;
    end

    if (STOP_AT_FIRST_WR_BOUNDARY) begin
      pulse_stop();
      capture_immediate_commit(commit_first_word, commit_second_word, commit_third_word,
                               commit_third_keep);
      expected_psn = INITIAL_PSN + packet_count;
      assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                              64'd1, WR_SIZE_BYTES, WR_SIZE_BYTES, WR_SIZE_BYTES,
                              !FAST_BENCHMARK_MODE);
      assert_immediate_commit_icrc(commit_first_word, commit_second_word, commit_third_word,
                                   commit_third_keep);
      send_ack(expected_psn);
      if (FAST_BENCHMARK_MODE) begin
        capture_immediate_commit(commit_first_word, commit_second_word,
                                 commit_third_word, commit_third_keep);
        expected_psn = expected_psn + 24'd1;
        assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                                64'd2, WR_SIZE_BYTES, WR_SIZE_BYTES, 32'd0,
                                1'b1);
        assert_immediate_commit_icrc(commit_first_word, commit_second_word,
                                     commit_third_word, commit_third_keep);
        send_ack(expected_psn);
      end
      repeat (20) @(posedge clk);
      if (!drained || active || fault ||
          commit_count != (FAST_BENCHMARK_MODE ? 32'd2 : 32'd1) ||
          immediate_count != (FAST_BENCHMARK_MODE ? 32'd2 : 32'd1) ||
          producer_sequence != (FAST_BENCHMARK_MODE ? 64'd2 : 64'd1) ||
          published_bytes != WR_SIZE_BYTES ||
          issued_bytes != WR_SIZE_BYTES || acked_bytes != WR_SIZE_BYTES) begin
        $fatal(1, "WR-boundary stop state is wrong: drained=%b active=%b fault=%b commits=%0d immediate=%0d seq=%0d published=%0d issued=%0d acked=%0d",
               drained, active, fault, commit_count, immediate_count, producer_sequence,
               published_bytes, issued_bytes, acked_bytes);
      end
      $display("cmac_usplus_0_rdma_notification_interval_tb PASS WR-boundary-stop fast=%0d data_cycles=%0d",
               FAST_BENCHMARK_MODE, data_elapsed_cycles);
      $finish;
    end

    capture_immediate_commit(commit_first_word, commit_second_word, commit_third_word,
                             commit_third_keep);
    expected_psn = INITIAL_PSN + packet_count;
    assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                            64'd1, interval_bytes, interval_bytes,
                            interval_bytes, 1'b0);
    assert_immediate_commit_icrc(commit_first_word, commit_second_word, commit_third_word,
                                 commit_third_keep);

    // The commit is itself a reliable write. Its timeout retransmission must
    // preserve the Immediate header, payload, ICRC, and final AXIS beat.
    capture_immediate_commit(retry_first_word, retry_second_word, retry_third_word,
                             retry_third_keep);
    if (retry_first_word !== commit_first_word || retry_second_word !== commit_second_word ||
        retry_third_word !== commit_third_word || retry_third_keep !== commit_third_keep) begin
      $fatal(1, "Immediate commit retransmission changed its wire image");
    end
    assert_immediate_commit_icrc(retry_first_word, retry_second_word, retry_third_word,
                                 retry_third_keep);
    pulse_stop();
    send_ack(expected_psn);

    // Stopping while a periodic commit is in flight requires a distinct final
    // release record even though it publishes zero additional data bytes.
    capture_immediate_commit(commit_first_word, commit_second_word, commit_third_word,
                             commit_third_keep);
    expected_psn = expected_psn + 24'd1;
    assert_immediate_commit(commit_first_word, commit_second_word, expected_psn,
                            64'd2, interval_bytes, interval_bytes,
                            32'd0, 1'b1);
    assert_immediate_commit_icrc(commit_first_word, commit_second_word, commit_third_word,
                                 commit_third_keep);
    send_ack(expected_psn);
    repeat (20) @(posedge clk);
    if (!drained || active || fault || commit_count != 32'd2 || immediate_count != 32'd2 ||
        producer_sequence != 64'd2 || published_bytes != interval_bytes ||
        issued_bytes != interval_bytes || acked_bytes != interval_bytes) begin
      $fatal(1, "interval publication state is wrong: drained=%b active=%b fault=%b commits=%0d immediate=%0d seq=%0d published=%0d issued=%0d acked=%0d",
             drained, active, fault, commit_count, immediate_count, producer_sequence,
             published_bytes, issued_bytes, acked_bytes);
    end

    $display("cmac_usplus_0_rdma_notification_interval_tb PASS interval=%0d fast=%0d data_cycles=%0d",
             interval_bytes, FAST_BENCHMARK_MODE, data_elapsed_cycles);
    $finish;
  end

endmodule

module cmac_usplus_0_rdma_notification_1m_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_10m_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(10 * 1024 * 1024)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_stop_boundary_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(64 * 1024),
    .STOP_AT_FIRST_WR_BOUNDARY(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_data_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(10 * 1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(10 * 1024 * 1024),
    .INJECT_DATA_SEQUENCE_NAK(1'b1),
    .HOLD_RECOVERY_PATH_BUSY(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_retransmission_disabled_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(128 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(128 * 1024),
    .RETRANSMISSION_ENABLE(1'b0),
    .INJECT_DATA_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_credit_nak_race_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .INJECT_CREDIT_RESERVATION_NAK_RACE(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_abort_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(64 * 1024),
    .INJECT_ABORT(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_commit_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .INJECT_COMMIT_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_commit_nak_disabled_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .RETRANSMISSION_ENABLE(1'b0),
    .INJECT_COMMIT_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_out_of_window_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .INJECT_OUT_OF_WINDOW_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_oow_disabled_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .RETRANSMISSION_ENABLE(1'b0),
    .INJECT_OUT_OF_WINDOW_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_second_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .MAX_SEQUENCE_RECOVERIES(1),
    .INJECT_SECOND_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_repeated_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .INJECT_SECOND_SEQUENCE_NAK(1'b1),
    .EXPECT_SECOND_SEQUENCE_RECOVERY(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_repeated_nak_psn_wrap_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .INITIAL_PSN(24'hFF_FFFE),
    .INJECT_SECOND_SEQUENCE_NAK(1'b1),
    .EXPECT_SECOND_SEQUENCE_RECOVERY(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_cross_message_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(8 * 1024),
    .MAX_SEQUENCE_RECOVERIES(1),
    .INJECT_CROSS_MESSAGE_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_default_recovery_limit_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .INJECT_SEQUENCE_RECOVERY_LIMIT(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_limit0_disabled_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(16 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(16 * 1024),
    .MAX_SEQUENCE_RECOVERIES(0),
    .RETRANSMISSION_ENABLE(1'b0),
    .INJECT_SEQUENCE_RECOVERY_LIMIT(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_fatal_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .INJECT_FATAL_DATA_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_fatal_nak_retransmission_disabled_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(1024 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .RETRANSMISSION_ENABLE(1'b0),
    .INJECT_FATAL_DATA_NAK(1'b1)
  ) i_test ();
endmodule

module cmac_usplus_0_rdma_notification_fast_ring_boundary_nak_tb;
  cmac_usplus_0_rdma_notification_interval_tb #(
    .NOTIFY_INTERVAL_BYTES(8 * 1024),
    .FAST_BENCHMARK_MODE(1'b1),
    .WR_SIZE_BYTES(8 * 1024),
    .RING_SIZE_BYTES(12 * 1024),
    .INJECT_RING_BOUNDARY_SEQUENCE_NAK(1'b1)
  ) i_test ();
endmodule
