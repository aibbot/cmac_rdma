`timescale 1ns / 1ps

module cmac_usplus_0_rdcp_config_recovery_tb;
  import cmac_usplus_0_rdcp_pkg::*;

  localparam logic [47:0] HOST_MAC = 48'h02_11_22_33_44_55;
  localparam logic [31:0] HOST_IP = 32'hC0A8_110A;
  localparam logic [31:0] FPGA_IP = 32'hC0A8_110B;
  localparam logic [63:0] FIRST_SESSION = 64'h1122_3344_5566_7788;

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
  logic cache_invalidate;
  logic response_done = 1'b0;
  logic cfg_valid;
  logic cfg_ready;
  logic cfg_done;
  logic cfg_accepted;
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
  logic start_request;
  logic stop_request;
  logic command_abort_request;
  logic fault_abort_request;
  logic [63:0] consumed_bytes;
  logic [3:0] session_state;
  logic safe_to_release;
  logic [31:0] config_generation;
  rdcp_endpoint_status_t endpoint_status;

  logic configured;
  logic active;
  logic stopping;
  logic drained;
  logic fault;
  logic [31:0] fault_reason;
  logic final_commit_acked;
  logic [31:0] config_reject_count;
  logic [31:0] config_reject_reason;
  logic [23:0] current_psn;
  logic [63:0] issued_bytes;
  logic [63:0] acked_bytes;
  logic [63:0] published_bytes;
  logic credit_stalled;
  integer abort_count = 0;

  always #2 clk = ~clk;

  always_ff @(posedge clk) begin
    if (reset)
      abort_count <= 0;
    else if (command_abort_request || fault_abort_request)
      abort_count <= abort_count + 1;
  end

  always_comb begin
    endpoint_status = '0;
    endpoint_status.configured = configured;
    endpoint_status.active = active;
    endpoint_status.stopping = stopping;
    endpoint_status.drained = drained;
    endpoint_status.fault = fault;
    endpoint_status.fault_reason = fault_reason;
    endpoint_status.final_commit_acked = final_commit_acked;
    endpoint_status.current_psn = current_psn;
    endpoint_status.issued_bytes = issued_bytes;
    endpoint_status.acked_bytes = acked_bytes;
    endpoint_status.published_bytes = published_bytes;
    endpoint_status.credit_stalled = credit_stalled;
  end

  cmac_usplus_0_rdcp_session_engine session_engine (
    .clk(clk), .reset(reset),
    .request_valid(request_valid), .request_ready(request_ready),
    .request(request), .transaction_active(transaction_active),
    .response_valid(response_valid), .response_ready(response_ready),
    .response_descriptor(response_descriptor),
    .replay_valid(replay_valid), .replay_ready(1'b0),
    .cache_invalidate(cache_invalidate), .cache_valid(1'b0),
    .cache_transaction_id(32'd0), .cache_opcode(8'd0),
    .response_done(response_done),
    .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
    .cfg_remote_mac(cfg_remote_mac), .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn), .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base), .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size), .cfg_wr_size(cfg_wr_size),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_local_base(cfg_local_base),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_done(cfg_done), .cfg_accepted(cfg_accepted),
    .cfg_reject_reason(config_reject_reason),
    .start_request(start_request), .stop_request(stop_request),
    .command_abort_request(command_abort_request),
    .endpoint_status(endpoint_status),
    .fault_abort_request(fault_abort_request),
    .consumed_bytes(consumed_bytes), .session_state(session_state),
    .safe_to_release(safe_to_release),
    .config_generation(config_generation)
  );

  cmac_usplus_0_rdma_endpoint endpoint (
    .clk(clk), .reset(reset), .local_ip(FPGA_IP),
    .rx_overflow_source_count(32'd0),
    .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
    .cfg_done(cfg_done), .cfg_accepted(cfg_accepted),
    .cfg_remote_mac(cfg_remote_mac), .cfg_remote_ip(cfg_remote_ip),
    .cfg_remote_qpn(cfg_remote_qpn), .cfg_local_psn(cfg_local_psn),
    .cfg_remote_base(cfg_remote_base), .cfg_rkey(cfg_rkey),
    .cfg_ring_size(cfg_ring_size), .cfg_wr_size(cfg_wr_size),
    .cfg_local_base(cfg_local_base),
    .cfg_enable_immediate(cfg_enable_immediate),
    .cfg_notify_interval_bytes(cfg_notify_interval_bytes),
    .cfg_commit_remote_addr(cfg_commit_remote_addr),
    .cfg_use_external_payload(1'b0),
    .start_request(start_request), .stop_request(stop_request),
    .abort_request(command_abort_request || fault_abort_request),
    .consumed_bytes(consumed_bytes), .tx_path_idle(1'b1),
    .retransmission_enable(1'b1),
    .payload_packet_valid(1'b0), .payload_packet_length(16'd0),
    .payload_packet_release(), .payload_buffer_empty(1'b1),
    .payload_ingress_enable(), .payload_flush(),
    .payload_read_enable(), .payload_read_address(),
    .payload_read_data(512'd0),
    .rx_axis_tvalid(1'b0), .rx_axis_tready(),
    .rx_axis_tdata(512'd0), .rx_axis_tkeep(64'd0),
    .rx_axis_tlast(1'b0), .rx_axis_tuser(1'b0),
    .tx_axis_tready(1'b1), .tx_axis_tvalid(),
    .tx_axis_tdata(), .tx_axis_tkeep(),
    .tx_axis_tlast(), .tx_axis_tuser(),
    .configured(configured), .active(active),
    .credit_stalled(credit_stalled), .stopping(stopping),
    .drained(drained), .fault(fault), .fault_reason(fault_reason),
    .final_commit_acked(final_commit_acked),
    .config_reject_count(config_reject_count),
    .config_reject_reason(config_reject_reason),
    .icrc_drop_count(), .invalid_psn_count(),
    .nak_count(), .retrans_count(),
    .retry_exhausted_count(), .rx_overflow_count(),
    .tx_underflow_count(), .issued_bytes(issued_bytes),
    .acked_bytes(acked_bytes), .ring_offset(),
    .current_psn(current_psn), .debug_state(),
    .commit_count(), .immediate_count(),
    .published_bytes(published_bytes), .producer_sequence(),
    .last_nak_syndrome(), .last_nak_psn(),
    .sequence_recovery_count(), .replay_active(),
    .external_payload_active()
  );

  task automatic send_request(
    input logic [7:0] opcode,
    input logic [63:0] session_id,
    input logic [31:0] transaction_id
  );
    integer cycles;
    begin
      @(negedge clk);
      request = '0;
      request.identity.remote_mac = HOST_MAC;
      request.identity.remote_ip = HOST_IP;
      request.identity.remote_port = 16'd55000;
      request.identity.session_id = session_id;
      request.identity.transaction_id = transaction_id;
      request.identity.opcode = opcode;
      request.parse_result = RDCP_RESULT_OK;
      if (opcode == RDCP_OP_CONFIG) begin
        request.config_fields.remote_qpn = 32'h0012_3456;
        request.config_fields.local_psn = 32'h0065_4321;
        request.config_fields.remote_base = 64'h0000_1234_5678_9000;
        request.config_fields.rkey = 32'h89AB_CDEF;
        request.config_fields.ring_size = 32'h4000_0000;
        request.config_fields.wr_size = 32'h00A0_0000;
        request.config_fields.notify_interval_bytes = 32'h00A0_0000;
        request.config_fields.commit_address = 64'h0000_1234_9678_9000;
        request.config_fields.flags = 32'd1;
      end
      request_valid = 1'b1;
      cycles = 0;
      do begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles == 40)
          $fatal(1, "request handshake timeout opcode=%0d", opcode);
      end while (!request_ready);
      @(negedge clk);
      request_valid = 1'b0;
    end
  endtask

  task automatic expect_response(
    input logic [15:0] expected_result,
    input logic [3:0] expected_state
  );
    integer cycles;
    begin
      cycles = 0;
      while (!response_valid && cycles < 80) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (!response_valid)
        $fatal(1, "response timeout");
      if (response_descriptor.result != expected_result ||
          response_descriptor.session_state != {4'd0, expected_state})
        $fatal(1, "response result=%0d state=%0d reason=%08h, expected %0d/%0d",
               response_descriptor.result, response_descriptor.session_state,
               response_descriptor.reason, expected_result, expected_state);
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
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (transaction_active)
        $fatal(1, "response transaction did not retire");
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(negedge clk);
    if (!drained || fault)
      $fatal(1, "endpoint reset state is not drained and fault-free");

    send_request(RDCP_OP_ABORT, FIRST_SESSION, 32'd1);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_FAULT_QUIESCING);
    repeat (4) @(negedge clk);
    if (!fault || fault_reason != 32'h8000_0001 || !drained ||
        session_state != RDCP_SESSION_FAULTED || abort_count != 1)
      $fatal(1, "old session did not leave the expected sticky ABORT fault");

    send_request(RDCP_OP_HELLO, 64'd0, 32'd0);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_FAULTED);
    send_request(RDCP_OP_CONFIG, FIRST_SESSION + 64'd1, 32'd2);
    expect_response(RDCP_RESULT_OK, RDCP_SESSION_READY);
    if (!configured || fault || config_reject_count != 32'd0 ||
        abort_count != 1 || config_generation != 32'd1)
      $fatal(1, "CONFIG did not clear the prior fault without aborting");

    $display("cmac_usplus_0_rdcp_config_recovery_tb PASS");
    $finish;
  end
endmodule
