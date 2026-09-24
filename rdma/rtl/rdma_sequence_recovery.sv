`timescale 1ps / 1ps

module cmac_usplus_0_rdma_sequence_recovery #(
  parameter integer MAX_RECOVERIES = 2,
  parameter integer QUIET_CYCLES = 8,
  parameter integer ATTEMPT_WIDTH =
    (MAX_RECOVERIES < 1) ? 1 : $clog2(MAX_RECOVERIES + 1)
) (
  input  logic clk,
  input  logic reset,
  input  logic clear,
  input  logic scheduler_safe,
  input  logic tx_path_idle,
  input  logic nak_observed,
  input  logic [7:0] nak_syndrome,
  input  logic [23:0] nak_psn,
  input  logic retransmission_enable,
  input  logic checkpoint_valid,
  input  logic [23:0] checkpoint_psn,
  input  logic [19:0] checkpoint_packet_count,
  input  logic [23:0] session_tx_psn,
  input  logic replay_active,
  input  logic [19:0] replay_remaining_packet_count,
  input  logic [ATTEMPT_WIDTH-1:0] recovery_attempts,
  output logic pending,
  output logic first_nak,
  output logic action_valid,
  output logic action_recover,
  output logic [31:0] action_fault_reason,
  output cmac_usplus_0_rdma_endpoint_pkg::rdma_recovery_action_t action
);
  import cmac_usplus_0_rdma_endpoint_pkg::*;

  localparam integer QUIET_LIMIT = (QUIET_CYCLES < 1) ? 1 : QUIET_CYCLES;
  localparam integer QUIET_COUNT_WIDTH =
    (QUIET_LIMIT <= 1) ? 1 : $clog2(QUIET_LIMIT);
  localparam logic [QUIET_COUNT_WIDTH-1:0] QUIET_LAST_COUNT =
    QUIET_COUNT_WIDTH'(QUIET_LIMIT - 1);
  localparam logic [ATTEMPT_WIDTH-1:0] MAX_RECOVERY_ATTEMPTS =
    ATTEMPT_WIDTH'(MAX_RECOVERIES);

  logic counts_valid;
  logic snapshot_valid;
  logic [7:0] pending_syndrome;
  logic [23:0] pending_psn;
  logic [23:0] packet_index;
  logic [23:0] sent_packets;
  logic [31:0] byte_offset;
  logic [31:0] replay_bytes;
  logic [QUIET_COUNT_WIDTH-1:0] quiet_count;
  logic [23:0] work_packet_count;
  logic recovery_qualified;
  logic quiet_elapsed;

  assign first_nak = nak_observed && !pending;
  assign work_packet_count = {4'd0, checkpoint_packet_count};
  assign recovery_qualified = (pending_syndrome == 8'h60) &&
    checkpoint_valid && (packet_index < work_packet_count) &&
    (packet_index < sent_packets) && (sent_packets <= work_packet_count) &&
    (recovery_attempts < MAX_RECOVERY_ATTEMPTS);
  assign quiet_elapsed = quiet_count == QUIET_LAST_COUNT;

  always_comb begin
    action.psn = pending_psn;
    action.packet_index = packet_index;
    action.byte_offset = byte_offset;
    action.replay_bytes = replay_bytes;

    action_valid = 1'b0;
    action_recover = 1'b0;
    action_fault_reason = 32'd0;
    if (pending && scheduler_safe && snapshot_valid && !nak_observed) begin
      if (!recovery_qualified) begin
        action_valid = 1'b1;
        if (pending_syndrome != 8'h60)
          action_fault_reason = 32'h0000_0103;
        else if (recovery_attempts >= MAX_RECOVERY_ATTEMPTS)
          action_fault_reason = 32'h0000_0102;
        else
          action_fault_reason = 32'h0000_0101;
      end else if (tx_path_idle && quiet_elapsed) begin
        action_valid = 1'b1;
        action_recover = retransmission_enable;
        if (!retransmission_enable)
          action_fault_reason = 32'h0000_0005;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset || clear) begin
      pending <= 1'b0;
      pending_syndrome <= 8'd0;
      pending_psn <= 24'd0;
      counts_valid <= 1'b0;
      snapshot_valid <= 1'b0;
      packet_index <= 24'd0;
      sent_packets <= 24'd0;
      byte_offset <= 32'd0;
      replay_bytes <= 32'd0;
      quiet_count <= '0;
    end else begin
      if (nak_observed) begin
        pending <= 1'b1;
        pending_syndrome <= nak_syndrome;
        pending_psn <= nak_psn;
      end else if (action_valid) begin
        pending <= 1'b0;
      end

      if (!pending || nak_observed || action_valid) begin
        counts_valid <= 1'b0;
        snapshot_valid <= 1'b0;
        quiet_count <= '0;
      end else if (scheduler_safe) begin
        if (!counts_valid) begin
          packet_index <= pending_psn - checkpoint_psn;
          sent_packets <= session_tx_psn - checkpoint_psn +
            (replay_active ?
              {4'd0, replay_remaining_packet_count} : 24'd0);
          counts_valid <= 1'b1;
          snapshot_valid <= 1'b0;
        end else if (!snapshot_valid) begin
          byte_offset <= {packet_index[19:0], 12'd0};
          replay_bytes <= {
            sent_packets[19:0] - packet_index[19:0], 12'd0
          };
          snapshot_valid <= 1'b1;
        end

        if (!snapshot_valid || !recovery_qualified || !tx_path_idle) begin
          quiet_count <= '0;
        end else if (!quiet_elapsed) begin
          quiet_count <= quiet_count + 1'b1;
        end
      end
    end
  end
endmodule
