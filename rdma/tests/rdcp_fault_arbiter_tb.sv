`timescale 1ns / 1ps

module cmac_usplus_0_rdcp_fault_arbiter_tb;
  import cmac_usplus_0_rdcp_pkg::*;

  localparam logic [47:0] HOST_MAC = 48'h02_11_22_33_44_55;
  localparam logic [31:0] HOST_IP = 32'hC0A8_110A;
  localparam logic [15:0] HOST_PORT = 16'd55000;
  localparam logic [63:0] SESSION_ID = 64'h1122_3344_5566_7788;
  localparam logic [31:0] FAULT_REASON = 32'hDEAD_0040;

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

  integer start_effect_count;
  integer stop_effect_count;
  integer abort_effect_count;

  always #2 clk = ~clk;

  always_ff @(posedge clk) begin
    if (reset) begin
      start_effect_count <= 0;
      stop_effect_count <= 0;
      abort_effect_count <= 0;
    end else begin
      if (start_request)
        start_effect_count <= start_effect_count + 1;
      if (stop_request)
        stop_effect_count <= stop_effect_count + 1;
      abort_effect_count <= abort_effect_count + command_abort_request +
                            fault_abort_request;
    end
  end

  cmac_usplus_0_rdcp_session_engine dut (
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
    input logic [31:0] transaction_id
  );
    begin
      request = '0;
      request.identity.remote_mac = HOST_MAC;
      request.identity.remote_ip = HOST_IP;
      request.identity.remote_port = HOST_PORT;
      request.identity.session_id = SESSION_ID;
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
      request.config_fields.flags = 32'd1;
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
          $fatal(1, "request_ready timeout");
      end while (!request_ready);
      @(negedge clk);
      request_valid = 1'b0;
    end
  endtask

  task automatic wait_response;
    integer cycles;
    begin
      cycles = 0;
      while (!response_valid && cycles < 60) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!response_valid)
        $fatal(1, "response timeout");
    end
  endtask

  task automatic accept_response;
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
      if (transaction_active)
        $fatal(1, "transaction did not retire");
    end
  endtask

  task automatic wait_config_request;
    integer cycles;
    begin
      cycles = 0;
      while (!cfg_valid && cycles < 40) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (!cfg_valid)
        $fatal(1, "CONFIG request timeout");
    end
  endtask

  task automatic complete_config;
    begin
      cfg_accepted = 1'b1;
      cfg_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cfg_done = 1'b0;
      cfg_accepted = 1'b0;
    end
  endtask

  task automatic wait_control_request(input logic [7:0] opcode);
    integer cycles;
    logic observed;
    begin
      cycles = 0;
      observed = 1'b0;
      while (!observed && cycles < 40) begin
        @(negedge clk);
        case (opcode)
          RDCP_OP_START: observed = start_request;
          RDCP_OP_STOP: observed = stop_request;
          default: observed = command_abort_request;
        endcase
        cycles = cycles + 1;
      end
      if (!observed)
        $fatal(1, "control request timeout opcode=%0d", opcode);
    end
  endtask

  task automatic expect_fault_response(input logic [7:0] opcode);
    logic [15:0] expected_result;
    begin
      expected_result = opcode == RDCP_OP_ABORT ?
                        RDCP_RESULT_OK : RDCP_RESULT_INVALID_STATE;
      wait_response();
      if (response_descriptor.result != expected_result ||
          response_descriptor.session_state !=
            {4'd0, RDCP_SESSION_FAULT_QUIESCING} ||
          response_descriptor.reason != FAULT_REASON ||
          !response_descriptor.cache_enable)
        $fatal(1, "fault response mismatch opcode=%0d", opcode);
    end
  endtask

  task automatic expect_result(
    input logic [15:0] expected_result,
    input logic expected_cache_enable
  );
    begin
      wait_response();
      if (response_descriptor.result != expected_result ||
          response_descriptor.cache_enable != expected_cache_enable)
        $fatal(1, "response mismatch result=%0d/%0d",
               response_descriptor.result, expected_result);
    end
  endtask

  task automatic accept_replay;
    integer cycles;
    begin
      if (!replay_valid)
        $fatal(1, "replay was not presented");
      replay_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      replay_ready = 1'b0;
      if (!cache_invalidate)
        $fatal(1, "faulted replay did not invalidate cache");
      cache_valid = 1'b0;
      response_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      response_done = 1'b0;
      cycles = 0;
      while (transaction_active && cycles < 20) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (transaction_active)
        $fatal(1, "faulted replay did not retire");
    end
  endtask

  task automatic reset_engine;
    begin
      reset = 1'b1;
      endpoint_status = '0;
      cfg_done = 1'b0;
      cfg_accepted = 1'b0;
      cache_valid = 1'b0;
      replay_ready = 1'b0;
      response_ready = 1'b0;
      response_done = 1'b0;
      request_valid = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
    end
  endtask

  task automatic configure_ready;
    begin
      build_request(RDCP_OP_CONFIG, 32'd1);
      set_valid_config();
      submit_request();
      wait_config_request();
      complete_config();
      expect_result(RDCP_RESULT_OK, 1'b1);
      accept_response();
    end
  endtask

  task automatic start_running;
    begin
      build_request(RDCP_OP_START, 32'd2);
      submit_request();
      wait_control_request(RDCP_OP_START);
      expect_result(RDCP_RESULT_OK, 1'b1);
      accept_response();
    end
  endtask

  task automatic prepare_opcode(
    input logic [7:0] opcode,
    output logic [31:0] transaction_id
  );
    begin
      reset_engine();
      configure_ready();
      if (opcode == RDCP_OP_STOP) begin
        start_running();
        transaction_id = 32'd3;
      end else begin
        transaction_id = 32'd2;
      end
      build_request(opcode, transaction_id);
    end
  endtask

  task automatic check_effect_counts(
    input logic [7:0] opcode,
    input integer base_start,
    input integer base_stop,
    input integer base_abort,
    input logic command_was_issued
  );
    integer expected_start;
    integer expected_stop;
    begin
      expected_start = base_start;
      expected_stop = base_stop;
      if (command_was_issued && opcode == RDCP_OP_START)
        expected_start = expected_start + 1;
      if (command_was_issued && opcode == RDCP_OP_STOP)
        expected_stop = expected_stop + 1;
      if (start_effect_count != expected_start ||
          stop_effect_count != expected_stop ||
          abort_effect_count != base_abort + 1)
        $fatal(1, "fault effects mismatch opcode=%0d", opcode);
    end
  endtask

  task automatic test_dispatch_fault(input logic [7:0] opcode);
    logic [31:0] transaction_id;
    integer base_start;
    integer base_stop;
    integer base_abort;
    begin
      prepare_opcode(opcode, transaction_id);
      base_start = start_effect_count;
      base_stop = stop_effect_count;
      base_abort = abort_effect_count;
      submit_request();
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      if (!fault_abort_request || start_request || stop_request ||
          command_abort_request ||
          session_state != RDCP_SESSION_FAULT_QUIESCING)
        $fatal(1, "DISPATCH fault did not preempt opcode %0d", opcode);
      repeat (2) @(posedge clk);
      @(negedge clk);
      check_effect_counts(opcode, base_start, base_stop, base_abort, 1'b0);
      expect_fault_response(opcode);
      endpoint_status.fault = 1'b0;
      accept_response();
    end
  endtask

  task automatic test_action_fault(input logic [7:0] opcode);
    logic [31:0] transaction_id;
    integer base_start;
    integer base_stop;
    integer base_abort;
    begin
      prepare_opcode(opcode, transaction_id);
      base_start = start_effect_count;
      base_stop = stop_effect_count;
      base_abort = abort_effect_count;
      submit_request();
      wait_control_request(opcode);
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      if (opcode == RDCP_OP_ABORT) begin
        if (fault_abort_request)
          $fatal(1, "accepted ABORT was issued twice");
      end else if (!fault_abort_request) begin
        $fatal(1, "accepted opcode %0d did not issue urgent ABORT", opcode);
      end
      repeat (2) @(posedge clk);
      @(negedge clk);
      check_effect_counts(opcode, base_start, base_stop, base_abort, 1'b1);
      expect_fault_response(opcode);
      endpoint_status.fault = 1'b0;
      accept_response();
    end
  endtask

  task automatic test_new_fault_during_config;
    begin
      reset_engine();
      build_request(RDCP_OP_CONFIG, 32'd1);
      set_valid_config();
      submit_request();
      wait_config_request();
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      if (!fault_abort_request ||
          session_state != RDCP_SESSION_FAULT_QUIESCING || response_valid)
        $fatal(1, "new CONFIG fault did not preempt the command");
      complete_config();
      expect_fault_response(RDCP_OP_CONFIG);
      endpoint_status.fault = 1'b0;
      accept_response();
    end
  endtask

  task automatic test_identity_fault(
    input logic wrong_source,
    input logic wrong_session,
    input logic [15:0] expected_result
  );
    begin
      reset_engine();
      configure_ready();
      build_request(RDCP_OP_STATUS, 32'd2);
      if (wrong_source)
        request.identity.remote_mac = HOST_MAC ^ 48'h1;
      if (wrong_session)
        request.identity.session_id = SESSION_ID ^ 64'h1;
      submit_request();
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      if (!fault_abort_request)
        $fatal(1, "identity fault did not issue urgent ABORT");
      expect_result(expected_result, 1'b0);
      endpoint_status.fault = 1'b0;
      accept_response();
    end
  endtask

  task automatic test_old_transaction_fault;
    begin
      reset_engine();
      configure_ready();
      build_request(RDCP_OP_STATUS, 32'd2);
      submit_request();
      expect_result(RDCP_RESULT_OK, 1'b1);
      accept_response();
      build_request(RDCP_OP_STATUS, 32'd2);
      submit_request();
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      expect_result(RDCP_RESULT_OLD_TRANSACTION, 1'b0);
      endpoint_status.fault = 1'b0;
      accept_response();
    end
  endtask

  task automatic test_replay_fault;
    begin
      reset_engine();
      configure_ready();
      cache_valid = 1'b1;
      cache_transaction_id = 32'd2;
      cache_opcode = RDCP_OP_STATUS;
      build_request(RDCP_OP_STATUS, 32'd2);
      submit_request();
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      if (!replay_valid || response_valid || cache_invalidate)
        $fatal(1, "fault did not preserve cached replay precedence");
      endpoint_status.fault = 1'b0;
      accept_replay();
    end
  endtask

  task automatic test_replay_handshake_fault;
    begin
      reset_engine();
      configure_ready();
      cache_valid = 1'b1;
      cache_transaction_id = 32'd2;
      cache_opcode = RDCP_OP_STATUS;
      build_request(RDCP_OP_STATUS, 32'd2);
      submit_request();
      @(posedge clk);
      @(negedge clk);
      replay_ready = 1'b1;
      endpoint_status.fault_reason = FAULT_REASON;
      endpoint_status.fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      replay_ready = 1'b0;
      if (replay_valid || !cache_invalidate || !fault_abort_request ||
          dut.invalidate_after_replay)
        $fatal(1, "replay handshake fault arbitration is wrong");
      cache_valid = 1'b0;
      endpoint_status.fault = 1'b0;
      response_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      response_done = 1'b0;
    end
  endtask

  initial begin
    endpoint_status = '0;
    request = '0;
    repeat (3) @(posedge clk);

    test_dispatch_fault(RDCP_OP_START);
    test_dispatch_fault(RDCP_OP_STOP);
    test_dispatch_fault(RDCP_OP_ABORT);
    test_identity_fault(1'b1, 1'b0, RDCP_RESULT_BAD_SOURCE);
    test_identity_fault(1'b0, 1'b1, RDCP_RESULT_BAD_SESSION);
    test_old_transaction_fault();
    test_replay_fault();
    test_replay_handshake_fault();
    test_new_fault_during_config();
    test_action_fault(RDCP_OP_START);
    test_action_fault(RDCP_OP_STOP);
    test_action_fault(RDCP_OP_ABORT);

    $display("cmac_usplus_0_rdcp_fault_arbiter_tb PASS");
    $finish;
  end
endmodule
