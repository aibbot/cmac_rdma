`timescale 1ns / 1ps

module cmac_usplus_0_rdcp_control_tb;
  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_110B;
  localparam logic [47:0] HOST_MAC = 48'h02_00_00_00_00_A0;
  localparam logic [31:0] HOST_IP = 32'hC0A8_110A;
  localparam logic [63:0] SESSION_ID = 64'h1122_3344_5566_7788;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic m_axis_tvalid;
  logic m_axis_tready = 1'b1;
  logic [511:0] m_axis_tdata;
  logic [63:0] m_axis_tkeep;
  logic m_axis_tlast;
  logic m_axis_tuser;

  logic cfg_valid;
  logic cfg_ready = 1'b1;
  logic [47:0] cfg_remote_mac;
  logic [31:0] cfg_remote_ip;
  logic [23:0] cfg_remote_qpn;
  logic [23:0] cfg_local_psn;
  logic [47:0] cfg_remote_base;
  logic [31:0] cfg_rkey;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_wr_size;
  logic [31:0] cfg_notify_interval_bytes;
  logic [63:0] cfg_local_base;
  logic [47:0] cfg_commit_remote_addr;
  logic cfg_enable_immediate;
  logic cfg_done = 1'b0;
  logic cfg_accepted = 1'b0;
  logic [31:0] cfg_reject_reason = 32'd0;
  logic start_request;
  logic stop_request;
  logic abort_request;

  logic endpoint_configured = 1'b0;
  logic endpoint_active = 1'b0;
  logic endpoint_stopping = 1'b0;
  logic endpoint_drained = 1'b1;
  logic endpoint_fault = 1'b0;
  logic [31:0] endpoint_fault_reason = 32'd0;
  logic endpoint_final_commit_acked = 1'b0;
  logic [23:0] endpoint_current_psn = 24'h12_3456;
  logic [63:0] endpoint_issued_bytes = 64'd0;
  logic [63:0] endpoint_acked_bytes = 64'd0;
  logic [63:0] endpoint_published_bytes = 64'd0;
  logic [63:0] endpoint_producer_sequence = 64'd0;
  logic close_endpoint = 1'b0;
  logic [3:0] session_state;
  logic safe_to_release;
  logic [31:0] config_generation;

  logic [7:0] request_bytes [128];
  logic [7:0] response_bytes [128];
  integer request_length;
  integer response_length;
  integer cfg_pulse_count = 0;
  integer stop_pulse_count = 0;
  integer abort_pulse_count = 0;
  logic request_error_on_last = 1'b0;
  logic [7:0] cached_response_bytes [126];

  always #2 clk = ~clk;

  cmac_usplus_0_rdcp_control #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP(LOCAL_IP)
  ) dut (
    .clk(clk),
    .reset(reset),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_remote_mac(cfg_remote_mac),
    .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn),
    .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base),
    .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size),
    .cfg_wr_size(cfg_wr_size),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_local_base(cfg_local_base),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_done(cfg_done),
    .cfg_accepted(cfg_accepted),
    .cfg_reject_reason(cfg_reject_reason),
    .start_request(start_request),
    .stop_request(stop_request),
    .abort_request(abort_request),
    .endpoint_configured(endpoint_configured),
    .endpoint_active(endpoint_active),
    .endpoint_stopping(endpoint_stopping),
    .endpoint_drained(endpoint_drained),
    .endpoint_fault(endpoint_fault),
    .endpoint_fault_reason(endpoint_fault_reason),
    .endpoint_final_commit_acked(endpoint_final_commit_acked),
    .endpoint_current_psn(endpoint_current_psn),
    .endpoint_issued_bytes(endpoint_issued_bytes),
    .endpoint_acked_bytes(endpoint_acked_bytes),
    .endpoint_published_bytes(endpoint_published_bytes),
    .endpoint_producer_sequence(endpoint_producer_sequence),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  always_ff @(posedge clk) begin
    cfg_done <= 1'b0;
    cfg_accepted <= 1'b0;
    if (cfg_valid) begin
      cfg_done <= 1'b1;
      cfg_accepted <= 1'b1;
      endpoint_configured <= 1'b1;
      endpoint_fault <= 1'b0;
      endpoint_final_commit_acked <= 1'b0;
      cfg_pulse_count <= cfg_pulse_count + 1;
    end
    if (start_request) begin
      endpoint_active <= 1'b1;
      endpoint_drained <= 1'b0;
    end
    if (stop_request) begin
      stop_pulse_count <= stop_pulse_count + 1;
      endpoint_active <= 1'b0;
      endpoint_stopping <= 1'b1;
    end
    if (abort_request) begin
      abort_pulse_count <= abort_pulse_count + 1;
      endpoint_active <= 1'b0;
      endpoint_stopping <= 1'b0;
      endpoint_drained <= 1'b1;
      endpoint_configured <= 1'b0;
    end
    if (close_endpoint) begin
      endpoint_active <= 1'b0;
      endpoint_stopping <= 1'b0;
      endpoint_drained <= 1'b1;
      endpoint_configured <= 1'b0;
      endpoint_final_commit_acked <= 1'b1;
    end
  end

  task automatic clear_request;
    integer index;
    begin
      for (index = 0; index < 128; index = index + 1)
        request_bytes[index] = 8'd0;
    end
  endtask

  task automatic set_be16(input integer offset, input logic [15:0] value);
    begin
      request_bytes[offset] = value[15:8];
      request_bytes[offset + 1] = value[7:0];
    end
  endtask

  task automatic set_be32(input integer offset, input logic [31:0] value);
    begin
      request_bytes[offset] = value[31:24];
      request_bytes[offset + 1] = value[23:16];
      request_bytes[offset + 2] = value[15:8];
      request_bytes[offset + 3] = value[7:0];
    end
  endtask

  task automatic set_be48(input integer offset, input logic [47:0] value);
    begin
      request_bytes[offset] = value[47:40];
      request_bytes[offset + 1] = value[39:32];
      request_bytes[offset + 2] = value[31:24];
      request_bytes[offset + 3] = value[23:16];
      request_bytes[offset + 4] = value[15:8];
      request_bytes[offset + 5] = value[7:0];
    end
  endtask

  task automatic set_be64(input integer offset, input logic [63:0] value);
    begin
      set_be32(offset, value[63:32]);
      set_be32(offset + 4, value[31:0]);
    end
  endtask

  task automatic begin_request(
    input logic [7:0] opcode,
    input logic [63:0] session_id,
    input logic [31:0] transaction_id,
    input logic [15:0] payload_length
  );
    logic [15:0] ip_length;
    logic [15:0] udp_length;
    begin
      clear_request();
      request_length = 62 + payload_length;
      set_be48(0, LOCAL_MAC);
      set_be48(6, HOST_MAC);
      set_be16(12, 16'h0800);
      request_bytes[14] = 8'h45;
      ip_length = 16'd48 + payload_length;
      set_be16(16, ip_length);
      set_be16(18, 16'h0102);
      set_be16(20, 16'h0000);
      request_bytes[22] = 8'd64;
      request_bytes[23] = 8'd17;
      set_be32(26, HOST_IP);
      set_be32(30, LOCAL_IP);
      set_be16(34, 16'd55000);
      set_be16(36, 16'd4792);
      udp_length = 16'd28 + payload_length;
      set_be16(38, udp_length);
      set_be32(42, 32'h5244_4350);
      request_bytes[46] = 8'd1;
      request_bytes[47] = opcode;
      set_be16(48, payload_length);
      set_be64(50, session_id);
      set_be32(58, transaction_id);
    end
  endtask

  task automatic begin_valid_config(
    input logic [63:0] session_id,
    input logic [31:0] transaction_id
  );
    begin
      begin_request(8'd2, session_id, transaction_id, 16'd56);
      set_be32(62, 32'h0012_3456);
      set_be32(66, 32'h00AB_CDEF);
      set_be64(70, 64'h0000_1234_5678_9000);
      set_be32(78, 32'h89AB_CDEF);
      set_be32(82, 32'h4000_0000);
      set_be32(86, 32'h00A0_0000);
      set_be32(90, 32'h00A0_0000);
      set_be64(94, 64'd0);
      set_be64(102, 64'h0000_1234_9678_9000);
      set_be32(110, 32'd0);
      set_be32(114, 32'd0);
    end
  endtask

  task automatic finish_checksums(input logic corrupt_udp_checksum);
    integer index;
    integer sum;
    logic [15:0] checksum;
    logic [15:0] udp_length;
    begin
      set_be16(24, 16'd0);
      sum = 0;
      for (index = 14; index < 34; index = index + 2)
        sum = sum + {request_bytes[index], request_bytes[index + 1]};
      sum = (sum & 16'hFFFF) + (sum >> 16);
      sum = (sum & 16'hFFFF) + (sum >> 16);
      checksum = ~sum[15:0];
      set_be16(24, checksum);

      set_be16(40, 16'd0);
      udp_length = {request_bytes[38], request_bytes[39]};
      sum = {request_bytes[26], request_bytes[27]} +
            {request_bytes[28], request_bytes[29]} +
            {request_bytes[30], request_bytes[31]} +
            {request_bytes[32], request_bytes[33]} + 16'd17 + udp_length;
      for (index = 34; index < request_length; index = index + 2) begin
        if (index + 1 < request_length)
          sum = sum + {request_bytes[index], request_bytes[index + 1]};
        else
          sum = sum + {request_bytes[index], 8'd0};
      end
      sum = (sum & 16'hFFFF) + (sum >> 16);
      sum = (sum & 16'hFFFF) + (sum >> 16);
      checksum = ~sum[15:0];
      if (checksum == 16'd0) checksum = 16'hFFFF;
      if (corrupt_udp_checksum) checksum = checksum ^ 16'h0001;
      set_be16(40, checksum);
    end
  endtask

  task automatic send_request;
    integer offset;
    integer index;
    integer valid_bytes;
    integer ready_cycles;
    logic [511:0] word;
    logic [63:0] keep;
    begin
      offset = 0;
      while (offset < request_length) begin
        word = 512'd0;
        keep = 64'd0;
        valid_bytes = request_length - offset;
        if (valid_bytes > 64) valid_bytes = 64;
        for (index = 0; index < valid_bytes; index = index + 1) begin
          word[index * 8 +: 8] = request_bytes[offset + index];
          keep[index] = 1'b1;
        end
        @(negedge clk);
        s_axis_tdata = word;
        s_axis_tkeep = keep;
        s_axis_tlast = (offset + valid_bytes == request_length);
        s_axis_tuser = request_error_on_last && s_axis_tlast;
        s_axis_tvalid = 1'b1;
        ready_cycles = 0;
        do begin
          @(posedge clk);
          ready_cycles = ready_cycles + 1;
          if (ready_cycles == 2000)
            $fatal(1, "timeout waiting for request ready, control_state=%0d",
                   dut.control_state);
        end while (!s_axis_tready);
        offset = offset + valid_bytes;
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tkeep = 64'd0;
      s_axis_tuser = 1'b0;
    end
  endtask

  task automatic wait_response_valid;
    integer cycles;
    begin
      cycles = 0;
      while (!m_axis_tvalid && cycles < 2000) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!m_axis_tvalid)
        $fatal(1, "timeout waiting for response, control_state=%0d session_state=%0d",
               dut.control_state, session_state);
    end
  endtask

  task automatic receive_response;
    integer cycles;
    integer index;
    logic received_last;
    begin
      response_length = 0;
      cycles = 0;
      received_last = 1'b0;
      while (cycles < 800 && !received_last) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (m_axis_tvalid && m_axis_tready) begin
          for (index = 0; index < 64; index = index + 1) begin
            if (m_axis_tkeep[index]) begin
              response_bytes[response_length] = m_axis_tdata[index * 8 +: 8];
              response_length = response_length + 1;
            end
          end
          if (m_axis_tlast) received_last = 1'b1;
        end
      end
      if (response_length != 126) $fatal(1, "response length is %0d", response_length);
      @(negedge clk);
    end
  endtask

  task automatic expect_no_response(input integer cycles);
    integer index;
    begin
      for (index = 0; index < cycles; index = index + 1) begin
        @(posedge clk);
        if (m_axis_tvalid) $fatal(1, "invalid control frame produced a response");
      end
    end
  endtask

  function automatic logic [15:0] response_be16(input integer offset);
    response_be16 = {response_bytes[offset], response_bytes[offset + 1]};
  endfunction

  function automatic logic [31:0] response_be32(input integer offset);
    response_be32 = {response_bytes[offset], response_bytes[offset + 1],
                     response_bytes[offset + 2], response_bytes[offset + 3]};
  endfunction

  task automatic expect_response_checksums;
    integer index;
    logic [31:0] sum;
    begin
      sum = 32'd0;
      for (index = 14; index < 34; index = index + 2)
        sum = sum + {response_bytes[index], response_bytes[index + 1]};
      sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
      sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
      if (sum[15:0] != 16'hFFFF)
        $fatal(1, "response IPv4 checksum is invalid");

      sum = {response_bytes[26], response_bytes[27]} +
            {response_bytes[28], response_bytes[29]} +
            {response_bytes[30], response_bytes[31]} +
            {response_bytes[32], response_bytes[33]} +
            32'd17 + response_be16(38);
      for (index = 34; index < 126; index = index + 2)
        sum = sum + {response_bytes[index], response_bytes[index + 1]};
      sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
      sum = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
      if (sum[15:0] != 16'hFFFF)
        $fatal(1, "response UDP checksum is invalid");
    end
  endtask

  task automatic expect_response(
    input logic [7:0] opcode,
    input logic [15:0] result,
    input logic [7:0] state
  );
    begin
      expect_response_checksums();
      if (response_be32(42) != 32'h5244_4350 ||
          response_bytes[46] != 8'd1 || response_bytes[47] != (opcode | 8'h80) ||
          response_be16(48) != 16'd64 || response_be16(62) != result ||
          response_bytes[64] != state)
        $fatal(1, "unexpected response opcode=%0h result=%0d state=%0d",
               response_bytes[47], response_be16(62), response_bytes[64]);
    end
  endtask

  initial begin
    integer index;
    logic [511:0] held_response_data;
    logic [63:0] held_response_keep;

    repeat (5) @(posedge clk);
    reset = 1'b0;

    begin_request(8'd1, 64'd0, 32'd1, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd1, 16'd0, 8'd0);
    if (response_be32(74) != 32'd1 ||
        response_be32(118) != 32'h0000_0007 ||
        response_be32(122) != 32'd4096)
      $fatal(1, "HELLO identity/capabilities are wrong");

    // A timed-out CONFIG is ambiguous to the host. ABORT must therefore bind
    // a safety-only session even when no configuration reached the endpoint.
    begin_request(8'd5, 64'hCAFE_BABE_0000_0001, 32'd2, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd5, 16'd0, 8'd6);
    repeat (4) @(posedge clk);
    if (abort_pulse_count != 1 || session_state != 4'd7 || !safe_to_release)
      $fatal(1, "unconfigured ABORT did not reach FAULTED + safe_to_release");

    // Model the next power-on session while retaining pulse counters so both
    // unconfigured and configured ABORT paths are covered in one regression.
    reset = 1'b1;
    repeat (3) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    begin_valid_config(SESSION_ID, 32'd10);
    finish_checksums(1'b0);
    m_axis_tready = 1'b0;
    send_request();
    wait_response_valid();
    held_response_data = m_axis_tdata;
    held_response_keep = m_axis_tkeep;
    repeat (3) begin
      @(posedge clk);
      if (!m_axis_tvalid || m_axis_tdata !== held_response_data ||
          m_axis_tkeep !== held_response_keep)
        $fatal(1, "RDCP response changed under TX backpressure");
    end
    @(negedge clk);
    m_axis_tready = 1'b1;
    receive_response();
    expect_response(8'd2, 16'd0, 8'd2);
    if (cfg_pulse_count != 1 || cfg_remote_mac != HOST_MAC ||
        cfg_remote_ip != HOST_IP || cfg_remote_qpn != 24'h12_3456 ||
        cfg_local_psn != 24'hAB_CDEF || cfg_ring_size != 32'h4000_0000 ||
        cfg_wr_size != 32'h00A0_0000 || cfg_enable_immediate)
      $fatal(1, "CONFIG was not atomically decoded");
    for (index = 0; index < 126; index = index + 1)
      cached_response_bytes[index] = response_bytes[index];

    send_request();
    receive_response();
    expect_response(8'd2, 16'd0, 8'd2);
    if (cfg_pulse_count != 1) $fatal(1, "duplicate CONFIG executed twice");
    for (index = 0; index < 126; index = index + 1) begin
      if (response_bytes[index] != cached_response_bytes[index])
        $fatal(1, "duplicate CONFIG response changed at byte %0d", index);
    end

    begin_request(8'd3, SESSION_ID, 32'd11, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd3, 16'd0, 8'd3);

    begin_valid_config(SESSION_ID, 32'd10);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd2, 16'd6, 8'd3);
    if (cfg_pulse_count != 1)
      $fatal(1, "old CONFIG executed while RUNNING");

    begin_request(8'd6, SESSION_ID, 32'd11, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd6, 8'd3);

    begin_request(8'd6, 64'hDEAD_BEEF_0000_0001, 32'd12, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd4, 8'd3);

    begin_request(8'd6, SESSION_ID, 32'd12, 16'd0);
    set_be48(6, 48'h02_00_00_00_00_B0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd5, 8'd3);

    begin_request(8'd6, SESSION_ID, 32'd10, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd6, 8'd3);

    begin_valid_config(SESSION_ID, 32'd12);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd2, 16'd9, 8'd3);
    if (cfg_pulse_count != 1) $fatal(1, "CONFIG executed while RUNNING");
    for (index = 0; index < 126; index = index + 1)
      cached_response_bytes[index] = response_bytes[index];

    send_request();
    receive_response();
    expect_response(8'd2, 16'd9, 8'd3);
    if (cfg_pulse_count != 1) $fatal(1, "rejected CONFIG executed on replay");
    for (index = 0; index < 126; index = index + 1) begin
      if (response_bytes[index] != cached_response_bytes[index])
        $fatal(1, "rejected CONFIG replay changed at byte %0d", index);
    end

    begin_request(8'd4, SESSION_ID, 32'd12, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd4, 16'd6, 8'd3);
    if (stop_pulse_count != 0)
      $fatal(1, "reused transaction ID executed STOP");

    begin_request(8'd4, SESSION_ID, 32'd13, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd4, 16'd0, 8'd4);
    if (stop_pulse_count != 1) $fatal(1, "STOP did not execute once");

    // Model a lost response by retransmitting the same STOP transaction.
    send_request();
    receive_response();
    expect_response(8'd4, 16'd0, 8'd4);
    if (stop_pulse_count != 1) $fatal(1, "duplicate STOP executed twice");

    close_endpoint = 1'b1;
    repeat (4) @(posedge clk);
    close_endpoint = 1'b0;
    begin_request(8'd6, SESSION_ID, 32'd14, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd0, 8'd5);
    if (!safe_to_release || (response_be32(70) & 32'h10) == 0)
      $fatal(1, "CLOSED did not assert safe_to_release");

    begin_valid_config(SESSION_ID, 32'd10);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd2, 16'd4, 8'd5);
    if (cfg_pulse_count != 1)
      $fatal(1, "old CONFIG resurrected a CLOSED session");

    begin_request(8'd3, SESSION_ID, 32'd11, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd3, 16'd6, 8'd5);
    if (endpoint_active || session_state != 4'd5)
      $fatal(1, "old START restarted a CLOSED session");

    // If a fresh CONFIG was lost while the previous session remains CLOSED,
    // the new host cannot know whether its MR was exposed. Its safety ABORT
    // must therefore be able to bind and reach FAULTED before teardown.
    begin_request(8'd5, SESSION_ID + 64'd99, 32'd15, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd5, 16'd0, 8'd6);
    repeat (4) @(posedge clk);
    if (abort_pulse_count != 2 || session_state != 4'd7 || !safe_to_release)
      $fatal(1, "new-session safety ABORT did not retire a CLOSED binding");

    begin_valid_config(SESSION_ID + 64'd1, 32'd20);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd2, 16'd0, 8'd2);
    if (config_generation != 32'd2 || cfg_pulse_count != 2)
      $fatal(1, "new session did not create a fresh configuration generation");

    begin_request(8'd3, SESSION_ID + 64'd1, 32'd21, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd3, 16'd0, 8'd3);

    begin_request(8'd5, SESSION_ID + 64'd1, 32'd22, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd5, 16'd0, 8'd6);
    repeat (4) @(posedge clk);
    if (abort_pulse_count != 3 || session_state != 4'd7 || !safe_to_release)
      $fatal(1, "ABORT did not converge to FAULTED + safe_to_release");

    begin_request(8'd6, SESSION_ID + 64'd1, 32'd23, 16'd0);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd6, 16'd0, 8'd7);

    begin_request(8'd1, 64'd0, 32'd30, 16'd0);
    set_be16(48, 16'd1);
    finish_checksums(1'b0);
    send_request();
    receive_response();
    expect_response(8'd1, 16'd3, 8'd7);

    begin_request(8'd1, 64'd0, 32'd31, 16'd0);
    finish_checksums(1'b0);
    request_bytes[24] = request_bytes[24] ^ 8'h01;
    send_request();
    expect_no_response(300);

    begin_request(8'd1, 64'd0, 32'd32, 16'd0);
    set_be16(20, 16'h2000);
    finish_checksums(1'b0);
    send_request();
    expect_no_response(300);

    begin_request(8'd1, 64'd0, 32'd33, 16'd0);
    finish_checksums(1'b0);
    request_error_on_last = 1'b1;
    send_request();
    request_error_on_last = 1'b0;
    expect_no_response(300);

    begin_request(8'd1, 64'd0, 32'd34, 16'd0);
    finish_checksums(1'b1);
    send_request();
    expect_no_response(300);

    $display("cmac_usplus_0_rdcp_control_tb PASS");
    $finish;
  end
endmodule
