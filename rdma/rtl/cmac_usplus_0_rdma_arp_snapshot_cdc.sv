`timescale 1ps / 1ps

// A one-entry acknowledged mailbox for learned ARP identity. Updates received
// while a transfer is active are coalesced into the latest value. The payload
// remains stable from request assertion through acknowledgement, and a reset
// of only the destination domain asks the source to replay its latest value.
module cmac_usplus_0_rdma_arp_snapshot_cdc (
  input  logic        src_clk,
  input  logic        src_reset,
  input  logic        src_update,
  input  logic [47:0] src_mac,
  input  logic [31:0] src_ip,
  input  logic        dst_clk,
  input  logic        dst_reset,
  output logic        dst_valid,
  output logic [47:0] dst_mac,
  output logic [31:0] dst_ip
);

  typedef enum logic [1:0] {SRC_IDLE, SRC_WAIT_ACK_HIGH, SRC_WAIT_ACK_LOW} src_state_t;
  src_state_t src_state;

  logic        src_value_valid;
  logic        src_pending;
  logic [47:0] src_latest_mac;
  logic [31:0] src_latest_ip;
  logic [47:0] src_transfer_mac;
  logic [31:0] src_transfer_ip;
  logic        src_request;

  (* ASYNC_REG = "TRUE" *) logic src_ack_sync1;
  (* ASYNC_REG = "TRUE" *) logic src_ack_sync2;
  (* ASYNC_REG = "TRUE" *) logic src_dst_reset_sync1;
  (* ASYNC_REG = "TRUE" *) logic src_dst_reset_sync2;

  (* ASYNC_REG = "TRUE" *) logic dst_request_sync1;
  (* ASYNC_REG = "TRUE" *) logic dst_request_sync2;
  (* ASYNC_REG = "TRUE" *) logic [47:0] dst_mac_sync1;
  (* ASYNC_REG = "TRUE" *) logic [47:0] dst_mac_sync2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] dst_ip_sync1;
  (* ASYNC_REG = "TRUE" *) logic [31:0] dst_ip_sync2;
  logic dst_ack;

  always_ff @(posedge src_clk) begin
    if (src_reset) begin
      src_state <= SRC_IDLE;
      src_value_valid <= 1'b0;
      src_pending <= 1'b0;
      src_latest_mac <= 48'd0;
      src_latest_ip <= 32'd0;
      src_transfer_mac <= 48'd0;
      src_transfer_ip <= 32'd0;
      src_request <= 1'b0;
      src_ack_sync1 <= 1'b0;
      src_ack_sync2 <= 1'b0;
      src_dst_reset_sync1 <= 1'b1;
      src_dst_reset_sync2 <= 1'b1;
    end else begin
      src_ack_sync1 <= dst_ack;
      src_ack_sync2 <= src_ack_sync1;
      src_dst_reset_sync1 <= dst_reset;
      src_dst_reset_sync2 <= src_dst_reset_sync1;

      if (src_update) begin
        src_value_valid <= 1'b1;
        src_latest_mac <= src_mac;
        src_latest_ip <= src_ip;
        src_pending <= 1'b1;
      end

      if (src_dst_reset_sync2) begin
        // Re-arm the four-phase handshake after a destination-only reset.
        src_state <= SRC_IDLE;
        src_request <= 1'b0;
        if (src_value_valid || src_update) src_pending <= 1'b1;
      end else begin
        case (src_state)
          SRC_IDLE: begin
            if (!src_ack_sync2 && (src_pending || src_update)) begin
              src_transfer_mac <= src_update ? src_mac : src_latest_mac;
              src_transfer_ip <= src_update ? src_ip : src_latest_ip;
              src_pending <= 1'b0;
              src_request <= 1'b1;
              src_state <= SRC_WAIT_ACK_HIGH;
            end
          end

          SRC_WAIT_ACK_HIGH: begin
            if (src_ack_sync2) begin
              src_request <= 1'b0;
              src_state <= SRC_WAIT_ACK_LOW;
            end
          end

          SRC_WAIT_ACK_LOW: begin
            if (!src_ack_sync2) src_state <= SRC_IDLE;
          end

          default: begin
            src_request <= 1'b0;
            src_state <= SRC_IDLE;
          end
        endcase
      end
    end
  end

  always_ff @(posedge dst_clk) begin
    if (dst_reset) begin
      dst_request_sync1 <= 1'b0;
      dst_request_sync2 <= 1'b0;
      dst_mac_sync1 <= 48'd0;
      dst_mac_sync2 <= 48'd0;
      dst_ip_sync1 <= 32'd0;
      dst_ip_sync2 <= 32'd0;
      dst_ack <= 1'b0;
      dst_valid <= 1'b0;
      dst_mac <= 48'd0;
      dst_ip <= 32'd0;
    end else begin
      dst_request_sync1 <= src_request;
      dst_request_sync2 <= dst_request_sync1;
      dst_mac_sync1 <= src_transfer_mac;
      dst_mac_sync2 <= dst_mac_sync1;
      dst_ip_sync1 <= src_transfer_ip;
      dst_ip_sync2 <= dst_ip_sync1;

      if (dst_request_sync2 && !dst_ack) begin
        dst_mac <= dst_mac_sync2;
        dst_ip <= dst_ip_sync2;
        dst_valid <= 1'b1;
        dst_ack <= 1'b1;
      end else if (!dst_request_sync2 && dst_ack) begin
        dst_ack <= 1'b0;
      end
    end
  end

endmodule
