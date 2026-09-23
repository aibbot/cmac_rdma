`timescale 1ps / 1ps

module cmac_usplus_0_rdma_config_manager (
  input  logic clk,
  input  logic reset,
  input  logic drained,
  input  logic request_valid,
  output logic request_ready,
  output logic request_done,
  output logic request_accepted,
  input  cmac_usplus_0_rdma_endpoint_pkg::rdma_endpoint_config_t request,
  output logic apply_valid,
  output cmac_usplus_0_rdma_endpoint_pkg::rdma_endpoint_config_t active_config,
  output logic busy,
  output logic [31:0] reject_count,
  output logic [31:0] reject_reason
);
  import cmac_usplus_0_rdma_endpoint_pkg::*;

  logic response_pending;
  logic [31:0] request_reject_reason;
  logic [31:0] pending_reject_reason;

  assign request_ready = drained && !response_pending;
  assign busy = response_pending;
  assign apply_valid = response_pending && (pending_reject_reason == 32'd0);

  always_comb begin
    logic [48:0] remote_end;
    logic [48:0] commit_end;

    remote_end = {1'b0, request.remote_base} + {17'd0, request.ring_size};
    commit_end = {1'b0, request.commit_remote_addr} + 49'd64;
    request_reject_reason = 32'd0;
    request_reject_reason[0] = !drained;
    request_reject_reason[1] = (request.remote_mac == 48'd0);
    request_reject_reason[4] = (request.remote_qpn == 24'd0);
    request_reject_reason[5] = (request.remote_ip == 32'd0);
    request_reject_reason[6] = (request.ring_size == 32'd0);
    request_reject_reason[7] = (request.wr_size == 32'd0);
    request_reject_reason[8] = (request.ring_size[11:0] != 12'd0);
    request_reject_reason[9] = (request.wr_size[11:0] != 12'd0);
    request_reject_reason[10] = (request.wr_size > request.ring_size);
    request_reject_reason[11] = (request.local_base[2:0] != 3'd0);
    request_reject_reason[12] = (request.notify_interval_bytes == 32'd0);
    request_reject_reason[13] =
      (request.notify_interval_bytes[11:0] != 12'd0);
    request_reject_reason[14] =
      (request.notify_interval_bytes > request.ring_size);
    request_reject_reason[15] = (request.commit_remote_addr == 48'd0);
    request_reject_reason[16] = (request.commit_remote_addr[5:0] != 6'd0);
    request_reject_reason[17] = remote_end[48];
    request_reject_reason[18] = commit_end[48];
    request_reject_reason[19] =
      !((commit_end <= {1'b0, request.remote_base}) ||
        ({1'b0, request.commit_remote_addr} >= remote_end));
  end

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    sat_inc32 = (&value) ? value : value + 32'd1;
  endfunction

  always_ff @(posedge clk) begin
    if (reset) begin
      response_pending <= 1'b0;
      active_config <= '0;
      pending_reject_reason <= 32'd0;
      request_done <= 1'b0;
      request_accepted <= 1'b0;
      reject_count <= 32'd0;
      reject_reason <= 32'd0;
    end else begin
      request_done <= 1'b0;
      request_accepted <= 1'b0;

      if (response_pending) begin
        response_pending <= 1'b0;
        request_done <= 1'b1;
        request_accepted <= (pending_reject_reason == 32'd0);
        if (pending_reject_reason == 32'd0) begin
          reject_count <= 32'd0;
          reject_reason <= 32'd0;
        end else begin
          reject_count <= sat_inc32(reject_count);
          reject_reason <= pending_reject_reason;
        end
      end else if (request_valid && request_ready) begin
        response_pending <= 1'b1;
        pending_reject_reason <= request_reject_reason;
        if (request_reject_reason == 32'd0) begin
          active_config <= request;
        end
      end
    end
  end
endmodule
