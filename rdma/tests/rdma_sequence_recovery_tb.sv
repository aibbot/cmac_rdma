`timescale 1ns / 1ps

module cmac_usplus_0_rdma_sequence_recovery_tb;
  import cmac_usplus_0_rdma_endpoint_pkg::*;

  localparam logic [23:0] BASE_PSN = 24'h12_3400;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic clear = 1'b0;
  logic scheduler_safe = 1'b1;
  logic tx_path_idle = 1'b1;
  logic nak_observed = 1'b0;
  logic [7:0] nak_syndrome = 8'd0;
  logic [23:0] nak_psn = 24'd0;
  logic retransmission_enable = 1'b1;
  rdma_recovery_checkpoint_t checkpoint;
  logic [23:0] session_tx_psn = BASE_PSN + 24'd3;
  logic replay_active = 1'b0;
  logic [31:0] replay_remaining_bytes = 32'd0;
  logic [1:0] recovery_attempts = 2'd0;
  logic pending;
  logic first_nak;
  logic action_valid;
  logic action_recover;
  logic [31:0] action_fault_reason;
  rdma_recovery_action_t action;

  always #2 clk = ~clk;

  cmac_usplus_0_rdma_sequence_recovery #(
    .MAX_RECOVERIES(2),
    .QUIET_CYCLES(3),
    .ATTEMPT_WIDTH(2)
  ) dut (
    .clk(clk),
    .reset(reset),
    .clear(clear),
    .scheduler_safe(scheduler_safe),
    .tx_path_idle(tx_path_idle),
    .nak_observed(nak_observed),
    .nak_syndrome(nak_syndrome),
    .nak_psn(nak_psn),
    .retransmission_enable(retransmission_enable),
    .checkpoint_valid(checkpoint.valid),
    .checkpoint_psn(checkpoint.psn),
    .checkpoint_packet_count(checkpoint.work_length[31:12]),
    .session_tx_psn(session_tx_psn),
    .replay_active(replay_active),
    .replay_remaining_packet_count(replay_remaining_bytes[31:12]),
    .recovery_attempts(recovery_attempts),
    .pending(pending),
    .first_nak(first_nak),
    .action_valid(action_valid),
    .action_recover(action_recover),
    .action_fault_reason(action_fault_reason),
    .action(action)
  );

  task automatic pulse_nak(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input logic expected_first
  );
    begin
      @(negedge clk);
      nak_psn = psn;
      nak_syndrome = syndrome;
      nak_observed = 1'b1;
      #1;
      if (first_nak !== expected_first)
        $fatal(1, "first_nak mismatch for PSN %h", psn);
      @(negedge clk);
      nak_observed = 1'b0;
    end
  endtask

  task automatic wait_for_action;
    integer cycles;
    begin
      cycles = 0;
      while (!action_valid && (cycles < 16)) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (!action_valid) $fatal(1, "recovery action timed out");
    end
  endtask

  task automatic clear_recovery;
    begin
      @(negedge clk);
      clear = 1'b1;
      @(negedge clk);
      clear = 1'b0;
      if (pending || action_valid) $fatal(1, "clear did not reset recovery");
    end
  endtask

  initial begin
    checkpoint = '0;
    checkpoint.valid = 1'b1;
    checkpoint.psn = BASE_PSN;
    checkpoint.work_length = 32'd16384;

    repeat (3) @(posedge clk);
    reset = 1'b0;

    pulse_nak(BASE_PSN + 24'd1, 8'h60, 1'b1);
    pulse_nak(BASE_PSN + 24'd2, 8'h60, 1'b0);
    wait_for_action();
    if (!action_recover || action_fault_reason != 32'd0 ||
        action.psn != BASE_PSN + 24'd2 || action.packet_index != 24'd2 ||
        action.byte_offset != 32'd8192 || action.replay_bytes != 32'd4096)
      $fatal(1, "coalesced recovery action is wrong");
    @(negedge clk);
    if (pending) $fatal(1, "completed recovery remained pending");

    clear_recovery();
    retransmission_enable = 1'b0;
    pulse_nak(BASE_PSN + 24'd1, 8'h60, 1'b1);
    wait_for_action();
    if (action_recover || action_fault_reason != 32'h0000_0005)
      $fatal(1, "disabled retransmission did not fault");

    clear_recovery();
    retransmission_enable = 1'b1;
    pulse_nak(BASE_PSN + 24'd1, 8'h61, 1'b1);
    wait_for_action();
    if (action_recover || action_fault_reason != 32'h0000_0103)
      $fatal(1, "fatal NAK classification is wrong");

    clear_recovery();
    recovery_attempts = 2'd2;
    pulse_nak(BASE_PSN + 24'd1, 8'h60, 1'b1);
    wait_for_action();
    if (action_recover || action_fault_reason != 32'h0000_0102)
      $fatal(1, "recovery limit classification is wrong");

    $display("cmac_usplus_0_rdma_sequence_recovery_tb PASS");
    $finish;
  end
endmodule
