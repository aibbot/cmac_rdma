`timescale 1ps / 1ps

module rdma_config_manager_tb;
  import rdma_endpoint_pkg::*;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic drained = 1'b0;
  logic request_valid = 1'b0;
  logic request_ready;
  logic request_done;
  logic request_accepted;
  logic apply_valid;
  logic busy;
  logic [31:0] reject_count;
  logic [31:0] reject_reason;
  rdma_endpoint_config_t request;
  rdma_endpoint_config_t active_config;

  always #2000 clk = ~clk;

  rdma_config_manager dut (
    .clk(clk),
    .reset(reset),
    .drained(drained),
    .request_valid(request_valid),
    .request_ready(request_ready),
    .request_done(request_done),
    .request_accepted(request_accepted),
    .request(request),
    .apply_valid(apply_valid),
    .active_config(active_config),
    .busy(busy),
    .reject_count(reject_count),
    .reject_reason(reject_reason)
  );

  function automatic rdma_endpoint_config_t make_valid_config(
    input logic [23:0] initial_psn
  );
    rdma_endpoint_config_t value;
    begin
      value = '0;
      value.remote_mac = 48'h6C_B3_11_21_E4_DC;
      value.local_ip = 32'hC0A8_650B;
      value.remote_ip = 32'hC0A8_650A;
      value.remote_qpn = 24'h12_3456;
      value.initial_psn = initial_psn;
      value.remote_base = 48'h0000_1000_0000;
      value.rkey = 32'hB0FC_6F39;
      value.ring_size = 32'h0000_4000;
      value.wr_size = 32'h0000_2000;
      value.local_base = 64'h0000_0001_0000_0000;
      value.enable_immediate = 1'b1;
      value.notify_interval_bytes = 32'h0000_2000;
      value.commit_remote_addr = 48'h0000_2000_0000;
      value.use_external_payload = 1'b1;
      make_valid_config = value;
    end
  endfunction

  task automatic submit(input rdma_endpoint_config_t value);
    begin
      while (!request_ready) @(posedge clk);
      @(negedge clk);
      request = value;
      request_valid = 1'b1;
      @(negedge clk);
      request_valid = 1'b0;
      request = '1;
      while (!request_done) @(negedge clk);
      #1;
    end
  endtask

  initial begin
    rdma_endpoint_config_t candidate;

    request = '0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    drained = 1'b1;

    candidate = make_valid_config(24'h12_3400);
    submit(candidate);
    if (!request_accepted || reject_count != 32'd0 || reject_reason != 32'd0)
      $fatal(1, "valid configuration was rejected");
    if (active_config !== candidate)
      $fatal(1, "configuration was not captured atomically");

    candidate = make_valid_config(24'h22_2200);
    candidate.notify_interval_bytes = 32'h0000_2001;
    submit(candidate);
    if (request_accepted || reject_count != 32'd1 ||
        reject_reason != 32'h0000_2000)
      $fatal(1, "misaligned notification interval reject mismatch");
    if (active_config.initial_psn != 24'h12_3400)
      $fatal(1, "rejected request changed active configuration");

    candidate = make_valid_config(24'h33_3300);
    submit(candidate);
    if (!request_accepted || reject_count != 32'd0 || reject_reason != 32'd0)
      $fatal(1, "accepted configuration did not clear reject diagnostics");
    if (active_config.initial_psn != 24'h33_3300)
      $fatal(1, "replacement configuration was not applied");

    drained = 1'b0;
    @(posedge clk);
    if (request_ready) $fatal(1, "manager accepted configuration while not drained");

    $display("rdma_config_manager_tb PASS");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "configuration manager test timeout");
  end
endmodule
