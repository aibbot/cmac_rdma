`timescale 1ns / 1ps

// Verifies that a logical WR which crosses the remote ring boundary is split
// into two independently-described RDMA WRITE messages.  The second physical
// message must retain the logical WR's next local byte address while its RETH
// restarts at remote_base.
module cmac_usplus_0_rdma_ring_tb #(
  parameter logic ALLOW_RING_WRAP = 1'b1
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
  logic cfg_clear_stats = 1'b0;
  logic cfg_force_remote_mac = 1'b1;
  logic [47:0] cfg_remote_mac = REMOTE_MAC;
  logic [31:0] cfg_remote_ip = REMOTE_IP;
  logic [23:0] cfg_local_qpn = 24'd1;
  logic [23:0] cfg_remote_qpn = 24'h12_34_56;
  logic [23:0] cfg_local_psn = 24'h00_1000;
  logic [23:0] cfg_remote_psn = 24'd0;
  logic [47:0] cfg_remote_base = REMOTE_BASE;
  logic [31:0] cfg_rkey = 32'hA5A5_5A5A;
  logic [31:0] cfg_ring_size = 32'd12288;
  logic [31:0] cfg_wr_size = 32'd8192;
  logic [63:0] cfg_local_base = 64'd0;
  logic cfg_enable_immediate = 1'b1;
  logic [31:0] cfg_notify_interval_bytes = 32'd8192;
  logic [47:0] cfg_commit_remote_addr = REMOTE_BASE + 48'd12288;
  logic cfg_allow_ring_wrap = ALLOW_RING_WRAP;

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
  logic drained;
  logic fault;
  logic [31:0] config_reject_count;
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

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_endpoint #(
    .LOCAL_MAC(LOCAL_MAC),
    .ACK_TIMEOUT_CYCLES(2000),
    .MAX_RETRIES(2)
  ) dut (
    .clk(clk),
    .reset(reset),
    .local_ip(LOCAL_IP),
    .learned_remote_valid(1'b0),
    .learned_remote_mac(48'd0),
    .learned_remote_ip(32'd0),
    .rx_overflow_source_count(32'd0),
    .cfg_apply(cfg_apply),
    .cfg_start(cfg_start),
    .cfg_stop(cfg_stop),
    .cfg_clear_stats(cfg_clear_stats),
    .cfg_force_remote_mac(cfg_force_remote_mac),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_local_qpn(cfg_local_qpn),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_psn(cfg_remote_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_local_base(cfg_local_base),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_allow_ring_wrap(cfg_allow_ring_wrap),
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
    .drained(drained),
    .fault(fault),
    .config_reject_count(config_reject_count),
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

  task automatic build_ack(input logic [23:0] psn, output logic [511:0] data);
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
      put_byte(data, 34, 8'h12);
      put_byte(data, 35, 8'hB7);
      put_byte(data, 36, 8'hC0);
      put_byte(data, 37, 8'h01);
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

  task automatic send_ack(input logic [23:0] psn);
    logic [511:0] data;
    begin
      build_ack(psn, data);
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
      repeat (55) @(posedge clk);
    end
  endtask

  task automatic capture_header(
    output logic [511:0] first_word,
    output logic [511:0] second_word
  );
    logic seen_first;
    logic seen_second;
    logic seen_last;
    begin
      first_word = 512'd0;
      second_word = 512'd0;
      seen_first = 1'b0;
      seen_second = 1'b0;
      seen_last = 1'b0;
      while (!seen_last) begin
        @(posedge clk);
        if (tx_axis_tvalid && tx_axis_tready) begin
          if (!seen_first) begin
            first_word = tx_axis_tdata;
            seen_first = 1'b1;
          end else if (!seen_second) begin
            second_word = tx_axis_tdata;
            seen_second = 1'b1;
          end
          if (tx_axis_tlast) seen_last = 1'b1;
        end
      end
    end
  endtask

  task automatic assert_reth_packet(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
    input logic [7:0] expected_opcode,
    input logic [23:0] expected_psn,
    input logic [47:0] expected_remote_address,
    input logic [31:0] expected_reth_length
  );
    logic [47:0] remote_address;
    begin
      remote_address = {get_byte(first_word, 56), get_byte(first_word, 57),
                        get_byte(first_word, 58), get_byte(first_word, 59),
                        get_byte(first_word, 60), get_byte(first_word, 61)};
      if (get_byte(first_word, 42) != expected_opcode ||
          get_be24(first_word, 51) != expected_psn ||
          remote_address != expected_remote_address ||
          get_be32(second_word, 2) != expected_reth_length) begin
        $fatal(1, "bad ring segment: opcode=%h psn=%h remote=%h reth_len=%h",
               get_byte(first_word, 42), get_be24(first_word, 51), remote_address,
               get_be32(second_word, 2));
      end
    end
  endtask

  task automatic assert_commit_packet(
    input logic [511:0] first_word,
    input logic [511:0] second_word,
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
      if (get_byte(first_word, 42) != 8'h0B ||
          get_be24(first_word, 51) != expected_psn ||
          remote_address != cfg_commit_remote_addr ||
          get_be32(second_word, 2) != 32'd64 ||
          get_be32(second_word, 6) != expected_sequence[31:0] ||
          get_le64(second_word, 10) != expected_total_bytes ||
          get_le32(second_word, 18) != expected_end_offset ||
           get_le32(second_word, 22) != expected_interval_bytes ||
           get_le32(second_word, 26) != {31'd0, expected_final} ||
          get_le64(second_word, 50) != expected_sequence) begin
        $fatal(1, "bad periodic commit: opcode=%h psn=%h addr=%h len=%h imm=%h seq=%h total=%h offset=%h interval=%h",
               get_byte(first_word, 42), get_be24(first_word, 51), remote_address,
               get_be32(second_word, 2), get_be32(second_word, 6),
               get_le64(second_word, 50), get_le64(second_word, 10),
               get_le32(second_word, 18), get_le32(second_word, 22));
      end
    end
  endtask

  initial begin
    logic [511:0] first_word;
    logic [511:0] second_word;

    repeat (5) @(posedge clk);
    reset = 1'b0;
    pulse_apply();
    repeat (3) @(posedge clk);
    if (!configured || fault) $fatal(1, "ring configuration was not accepted");
    pulse_start();

    // Logical WR 0: 8 KiB, represented as FIRST + LAST.
    capture_header(first_word, second_word);
    assert_reth_packet(first_word, second_word, 8'h06, 24'h00_1000, REMOTE_BASE, 32'd8192);
    send_ack(24'h00_1000);
    capture_header(first_word, second_word);
    if (get_byte(first_word, 42) != 8'h08 || get_be24(first_word, 51) != 24'h00_1001) begin
      $fatal(1, "first logical WR did not finish with WRITE_LAST");
    end
    send_ack(24'h00_1001);

    // The configured 8 KiB notification interval emits one ordered commit
    // write. Its Immediate Data is the producer sequence, not a data offset.
    capture_header(first_word, second_word);
    assert_commit_packet(first_word, second_word, 24'h00_1002,
                          64'd1, 64'd8192, 32'd8192, 32'd8192, 1'b0);
    send_ack(24'h00_1002);
    if (commit_count != 32'd1 || immediate_count != 32'd1 ||
        producer_sequence != 64'd1 || published_bytes != 64'd8192) begin
      $fatal(1, "first periodic commit counters are wrong");
    end

    // Logical WR 1 starts at the last 4 KiB of the ring.
    capture_header(first_word, second_word);
    assert_reth_packet(first_word, second_word, 8'h0A, 24'h00_1003,
                        REMOTE_BASE + 48'd8192, 32'd4096);
    send_ack(24'h00_1003);

    if (!ALLOW_RING_WRAP) begin
      // Safe bring-up mode must publish the tail and drain before the first
      // address is overwritten.
      capture_header(first_word, second_word);
      assert_commit_packet(first_word, second_word, 24'h00_1004,
                            64'd2, 64'd12288, 32'd0, 32'd4096, 1'b1);
      send_ack(24'h00_1004);
      if (!drained || active || fault || ring_offset != 32'd0 ||
          commit_count != 32'd2 || immediate_count != 32'd2 ||
          published_bytes != 64'd12288 || producer_sequence != 64'd2) begin
        $fatal(1, "ring guard did not drain before overwriting the first byte");
      end
      $display("cmac_usplus_0_rdma_ring_guard_tb PASS");
      $finish;
    end

    // The opt-in wrapping path continues with a new physical message at
    // remote_base, not a continuation of the tail's RETH.
    capture_header(first_word, second_word);
    assert_reth_packet(first_word, second_word, 8'h0A, 24'h00_1004,
                       REMOTE_BASE, 32'd4096);
    send_ack(24'h00_1004);
    capture_header(first_word, second_word);
    assert_commit_packet(first_word, second_word, 24'h00_1005,
                          64'd2, 64'd16384, 32'd4096, 32'd8192, 1'b0);
    send_ack(24'h00_1005);
    if (commit_count != 32'd2 || immediate_count != 32'd2 ||
        producer_sequence != 64'd2 || published_bytes != 64'd16384) begin
      $fatal(1, "second periodic commit counters are wrong");
    end

    $display("cmac_usplus_0_rdma_ring_tb PASS");
    $finish;
  end

endmodule

module cmac_usplus_0_rdma_ring_guard_tb;
  cmac_usplus_0_rdma_ring_tb #(
    .ALLOW_RING_WRAP(1'b0)
  ) i_test ();
endmodule
