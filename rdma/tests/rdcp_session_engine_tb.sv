`timescale 1ns / 1ps

module rdcp_session_engine_tb;
  import rdcp_pkg::*;

  localparam logic [47:0] HOST_MAC = 48'h02_11_22_33_44_55;
  localparam logic [31:0] HOST_IP = 32'hC0A8_110A;
  localparam logic [15:0] HOST_PORT = 16'd55000;
  localparam logic [63:0] SESSION_ID = 64'h1122_3344_5566_7788;

  logic clk = 1'b0;
  logic reset = 1'b1;

  logic request_valid = 1'b0;
  logic request_ready;
  rdcp_request_descriptor_t request;
  logic transaction_active;

  logic response_valid;
  logic response_ready = 1'b0;
  rdcp_response_descriptor_t response_descriptor;
  logic replay_valid;
  logic replay_ready = 1'b0;
  logic cache_invalidate;
  logic cache_valid = 1'b0;
  logic [31:0] cache_transaction_id = 32'd0;
  logic [7:0] cache_opcode = 8'd0;
  logic response_done = 1'b0;

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
  logic command_abort_request;

  rdcp_endpoint_status_t endpoint_status;
  logic fault_abort_request;
  logic [63:0] consumed_bytes;
  logic [3:0] session_state;
  logic safe_to_release;
  logic [31:0] config_generation;

  always #2 clk = ~clk;

  rdcp_session_engine dut (
    .clk(clk),
    .reset(reset),
    .request_valid(request_valid),
    .request_ready(request_ready),
    .request(request),
    .transaction_active(transaction_active),
    .response_valid(response_valid),
    .response_ready(response_ready),
    .response_descriptor(response_descriptor),
    .replay_valid(replay_valid),
    .replay_ready(replay_ready),
    .cache_invalidate(cache_invalidate),
    .cache_valid(cache_valid),
    .cache_transaction_id(cache_transaction_id),
    .cache_opcode(cache_opcode),
    .response_done(response_done),
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
    .command_abort_request(command_abort_request),
    .endpoint_status(endpoint_status),
    .fault_abort_request(fault_abort_request),
    .consumed_bytes(consumed_bytes),
    .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  task automatic build_request(
    input logic [7:0] opcode,
    input logic [63:0] session_id,
    input logic [31:0] transaction_id
  );
    begin
      request = '0;
      request.identity.remote_mac = HOST_MAC;
      request.identity.remote_ip = HOST_IP;
      request.identity.remote_port = HOST_PORT;
      request.identity.session_id = session_id;
      request.identity.transaction_id = transaction_id;
      request.identity.opcode = opcode;
      request.parse_result = RDCP_RESULT_OK;
    end
  endtask

  task automatic set_valid_config;
    begin
      request.config_fields.remote_qpn = 32'h0012_3456;
      request.config_fields.local_psn = 32'h0065_4321;
      request.config_fields.remote_base = 64'h0000_1234_5678_9000;
      request.config_fields.rkey = 32'h89AB_CDEF;
      request.config_fields.ring_size = 32'h4000_0000;
      request.config_fields.wr_size = 32'h00A0_0000;
      request.config_fields.notify_interval_bytes = 32'h00A0_0000;
      request.config_fields.local_base = 64'd0;
      request.config_fields.commit_address = 64'h0000_1234_9678_9000;
      request.config_fields.flags = 32'h0000_0001;
      request.config_fields.reserved = 32'd0;
    end
  endtask

  task automatic submit_request;
    integer cycles;
    begin
      @(negedge clk);
      request_valid = 1'b1;
      cycles = 0;
      do begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles == 40)
          $fatal(1, "timeout waiting for session request_ready");
      end while (!request_ready);
      @(negedge clk);
      request_valid = 1'b0;
      if (!transaction_active)
        $fatal(1, "request handshake did not start a transaction");
    end
  endtask

  task automatic wait_response;
    integer cycles;
    begin
      cycles = 0;
      while (!response_valid && cycles < 80) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!response_valid)
        $fatal(1, "timeout waiting for session response");
    end
  endtask

  task automatic accept_response_and_retire;
    integer cycles;
    begin
      @(negedge clk);
      response_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      response_ready = 1'b0;
      response_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      response_done = 1'b0;
      cycles = 0;
      while (transaction_active && cycles < 20) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (transaction_active || !request_ready)
        $fatal(1, "response did not retire the transaction");
    end
  endtask

  task automatic accept_replay_and_retire;
    integer cycles;
    begin
      @(negedge clk);
      replay_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      replay_ready = 1'b0;
      response_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      response_done = 1'b0;
      cycles = 0;
      while (transaction_active && cycles < 20) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (transaction_active || !request_ready)
        $fatal(1, "replay did not retire the transaction");
    end
  endtask

  task automatic wait_config_request;
    integer cycles;
    begin
      cycles = 0;
      while (!cfg_valid && cycles < 80) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (!cfg_valid)
        $fatal(1, "timeout waiting for endpoint CONFIG tx %0d state %0d",
               request.identity.transaction_id, session_state);
    end
  endtask

  task automatic complete_config(
    input logic accepted,
    input logic [31:0] reason
  );
    begin
      cfg_accepted = accepted;
      cfg_reject_reason = reason;
      cfg_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cfg_done = 1'b0;
      cfg_accepted = 1'b0;
      cfg_reject_reason = 32'd0;
    end
  endtask

  task automatic wait_control_request(input logic [7:0] opcode);
    integer cycles;
    logic observed;
    begin
      cycles = 0;
      observed = 1'b0;
      while (!observed && cycles < 80) begin
        @(negedge clk);
        case (opcode)
          RDCP_OP_START: observed = start_request;
          RDCP_OP_STOP: observed = stop_request;
          default: observed = command_abort_request;
        endcase
        cycles = cycles + 1;
      end
      if (!observed)
        $fatal(1, "timeout waiting for endpoint control opcode %0d", opcode);
    end
  endtask

  task automatic expect_response(
    input logic [15:0] expected_result,
    input logic [3:0] expected_state,
    input logic expected_cache
  );
    begin
      wait_response();
      if (response_descriptor.result != expected_result ||
          response_descriptor.session_state != {4'd0, expected_state} ||
          response_descriptor.cache_enable != expected_cache ||
          response_descriptor.source !== request.identity)
        $fatal(1, "response descriptor mismatch result=%0d state=%0d",
               response_descriptor.result,
               response_descriptor.session_state);
    end
  endtask

  initial begin
    endpoint_status = '0;
    request = '0;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    @(negedge clk);
    if (!request_ready || transaction_active || response_valid || replay_valid ||
        cfg_valid || start_request || stop_request || command_abort_request ||
        cache_invalidate || fault_abort_request ||
        session_state != RDCP_SESSION_IDLE || safe_to_release ||
        consumed_bytes != 64'd0 || config_generation != 32'd0)
      $fatal(1, "session engine reset/idle state is wrong");

    // Unbound STATUS is allowed only for session zero.
    build_request(RDCP_OP_STATUS, 64'd0, 32'd1);
    submit_request();
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_IDLE, 1'b0);
    accept_response_and_retire();

    build_request(RDCP_OP_STATUS, SESSION_ID, 32'd2);
    submit_request();
    expect_response(RDCP_RESULT_INVALID_STATE, RDCP_SESSION_IDLE, 1'b0);
    accept_response_and_retire();

    // Invalid CONFIG is rejected locally and never reaches the endpoint.
    build_request(RDCP_OP_CONFIG, SESSION_ID, 32'd3);
    set_valid_config();
    request.config_fields.rkey = 32'd0;
    submit_request();
    expect_response(RDCP_RESULT_INVALID_CONFIG, RDCP_SESSION_IDLE, 1'b0);
    if (cfg_valid)
      $fatal(1, "invalid CONFIG reached the endpoint");
    accept_response_and_retire();

    // Endpoint busy leaves the session completely unbound.
    build_request(RDCP_OP_CONFIG, SESSION_ID, 32'd4);
    set_valid_config();
    cfg_ready = 1'b0;
    submit_request();
    expect_response(RDCP_RESULT_BUSY, RDCP_SESSION_IDLE, 1'b0);
    if (cfg_valid)
      $fatal(1, "busy CONFIG asserted cfg_valid");
    accept_response_and_retire();
    cfg_ready = 1'b1;

    // A started but rejected CONFIG briefly enters CONFIGURING, then unbinds.
    build_request(RDCP_OP_CONFIG, SESSION_ID, 32'd5);
    set_valid_config();
    submit_request();
    wait_config_request();
    if (cfg_remote_mac != HOST_MAC || cfg_remote_ip != HOST_IP ||
        cfg_remote_qpn != 24'h12_3456 || cfg_local_psn != 24'h65_4321 ||
        cfg_remote_base != 48'h1234_5678_9000 ||
        cfg_rkey != 32'h89AB_CDEF ||
        cfg_ring_size != 32'h4000_0000 || cfg_wr_size != 32'h00A0_0000 ||
        cfg_notify_interval_bytes != 32'h00A0_0000 ||
        cfg_local_base != 64'd0 ||
        cfg_commit_remote_addr != 48'h1234_9678_9000 ||
        !cfg_enable_immediate)
      $fatal(1, "CONFIG endpoint mapping is wrong");
    if (session_state != RDCP_SESSION_CONFIGURING || !cache_invalidate)
      $fatal(1, "started CONFIG did not enter CONFIGURING/invalidate replay");
    complete_config(1'b0, 32'h0000_0042);
    expect_response(RDCP_RESULT_INVALID_CONFIG, RDCP_SESSION_IDLE, 1'b0);
    if (response_descriptor.reason != 32'h0000_0042)
      $fatal(1, "CONFIG reject reason was not preserved");
    accept_response_and_retire();

    // Accepted CONFIG binds the source/session and creates generation one.
    build_request(RDCP_OP_CONFIG, SESSION_ID, 32'd6);
    set_valid_config();
    submit_request();
    wait_config_request();
    complete_config(1'b1, 32'd0);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_READY, 1'b1);
    if (config_generation != 32'd1 ||
        response_descriptor.config_generation != 32'd1 ||
        consumed_bytes != 64'd0)
      $fatal(1, "accepted CONFIG did not publish generation one");
    accept_response_and_retire();

    // The latest identical transaction is replayed without re-execution.
    cache_valid = 1'b1;
    cache_transaction_id = 32'd6;
    cache_opcode = RDCP_OP_CONFIG;
    submit_request();
    begin : wait_for_replay
      integer cycles;
      cycles = 0;
      while (!replay_valid && cycles < 30) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!replay_valid || cfg_valid || start_request || stop_request ||
          command_abort_request || response_valid)
        $fatal(1, "duplicate CONFIG was not routed to replay");
    end
    accept_replay_and_retire();
    cache_valid = 1'b0;

    // START executes exactly once and advances the externally visible state.
    build_request(RDCP_OP_START, SESSION_ID, 32'd7);
    submit_request();
    wait_control_request(RDCP_OP_START);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_RUNNING, 1'b1);
    accept_response_and_retire();

    // Wrong source and old transaction IDs do not execute commands.
    build_request(RDCP_OP_STATUS, SESSION_ID, 32'd8);
    request.identity.remote_ip = HOST_IP + 32'd1;
    submit_request();
    expect_response(RDCP_RESULT_BAD_SOURCE, RDCP_SESSION_RUNNING, 1'b0);
    accept_response_and_retire();

    build_request(RDCP_OP_STATUS, SESSION_ID, 32'd7);
    submit_request();
    expect_response(RDCP_RESULT_OLD_TRANSACTION, RDCP_SESSION_RUNNING, 1'b0);
    accept_response_and_retire();

    endpoint_status.published_bytes = 64'd8192;
    endpoint_status.credit_stalled = 1'b1;
    build_request(RDCP_OP_CONSUME, SESSION_ID, 32'd9);
    request.config_fields.remote_qpn = 32'd0;
    request.config_fields.local_psn = 32'd4096;
    submit_request();
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_RUNNING, 1'b1);
    if (consumed_bytes != 64'd4096 ||
        response_descriptor.consumed_bytes != 64'd4096 ||
        !response_descriptor.status_bits[6])
      $fatal(1, "valid CONSUME did not update progress/status atomically");
    accept_response_and_retire();

    build_request(RDCP_OP_CONSUME, SESSION_ID, 32'd10);
    request.config_fields.remote_qpn = 32'd0;
    request.config_fields.local_psn = 32'd12288;
    submit_request();
    expect_response(RDCP_RESULT_INVALID_PROGRESS, RDCP_SESSION_RUNNING, 1'b1);
    if (response_descriptor.reason != 32'h0000_0002 ||
        consumed_bytes != 64'd4096)
      $fatal(1, "invalid CONSUME changed progress or reason");
    accept_response_and_retire();

    build_request(RDCP_OP_STOP, SESSION_ID, 32'd11);
    submit_request();
    wait_control_request(RDCP_OP_STOP);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_STOPPING, 1'b1);
    accept_response_and_retire();
    endpoint_status.final_commit_acked = 1'b1;
    endpoint_status.drained = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (session_state != RDCP_SESSION_CLOSED || !safe_to_release)
      $fatal(1, "STOPPING did not converge to CLOSED/safe_to_release");

    // Reset and prove asynchronous endpoint fault preserves the reason and
    // emits one urgent abort pulse without requiring an RDCP transaction.
    reset = 1'b1;
    @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    endpoint_status = '0;

    // A drained endpoint may still expose a sticky fault from the previous
    // session.  A fresh CONFIG must be allowed to apply and clear that fault
    // before the session engine reports READY.
    endpoint_status.drained = 1'b1;
    endpoint_status.fault = 1'b1;
    endpoint_status.fault_reason = 32'h8000_0001;
    build_request(RDCP_OP_CONFIG, SESSION_ID + 64'd2, 32'd2);
    set_valid_config();
    submit_request();
    wait_config_request();
    complete_config(1'b1, 32'd0);
    endpoint_status.fault = 1'b0;
    endpoint_status.fault_reason = 32'd0;
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_READY, 1'b1);
    accept_response_and_retire();

    // The endpoint fault path still needs to preempt an active READY session.
    reset = 1'b1;
    @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    endpoint_status = '0;

    build_request(RDCP_OP_CONFIG, SESSION_ID + 64'd1, 32'd1);
    set_valid_config();
    submit_request();
    wait_config_request();
    complete_config(1'b1, 32'd0);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_READY, 1'b1);
    accept_response_and_retire();

    @(negedge clk);
    endpoint_status.fault_reason = 32'hDEAD_0040;
    endpoint_status.fault = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!fault_abort_request || session_state != RDCP_SESSION_FAULT_QUIESCING)
      $fatal(1, "endpoint fault did not issue an urgent abort pulse=%0d state=%0d",
             fault_abort_request, session_state);
    @(posedge clk);
    @(negedge clk);
    if (fault_abort_request)
      $fatal(1, "urgent fault abort was wider than one cycle");
    endpoint_status.drained = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (session_state != RDCP_SESSION_FAULTED || !safe_to_release)
      $fatal(1, "fault quiescing did not converge to FAULTED");

    $display("rdcp_session_engine_tb PASS");
    $finish;
  end
endmodule
