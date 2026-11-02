`timescale 1ps / 1ps

module rdma_ack_receiver_tb;
  import rdma_endpoint_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
  localparam logic [23:0] LOCAL_QPN = 24'd1;
  localparam logic [47:0] REMOTE_MAC = 48'h6C_B3_11_21_E4_DC;
  localparam logic [31:0] LOCAL_IP = 32'hC0A8_650B;
  localparam logic [31:0] REMOTE_IP = 32'hC0A8_650A;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic clear_counters = 1'b0;
  logic rx_axis_tvalid = 1'b0;
  logic rx_axis_tready;
  logic [511:0] rx_axis_tdata = 512'd0;
  logic [63:0] rx_axis_tkeep = 64'd0;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;
  logic event_valid;
  logic [23:0] event_psn;
  logic [7:0] event_syndrome;
  logic event_is_nak;
  logic invalid_packet_pulse;
  logic [31:0] icrc_drop_count;
  integer event_count = 0;
  integer invalid_count = 0;

  always #2000 clk = ~clk;
  always_ff @(posedge clk) begin
    if (event_valid) event_count <= event_count + 1;
    if (invalid_packet_pulse) invalid_count <= invalid_count + 1;
  end

  rdma_ack_receiver #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_QPN(LOCAL_QPN)
  ) dut (
    .clk(clk),
    .reset(reset),
    .clear_counters(clear_counters),
    .remote_mac(REMOTE_MAC),
    .local_ip(LOCAL_IP),
    .remote_ip(REMOTE_IP),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(rx_axis_tkeep),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .event_valid(event_valid),
    .event_psn(event_psn),
    .event_syndrome(event_syndrome),
    .event_is_nak(event_is_nak),
    .invalid_packet_pulse(invalid_packet_pulse),
    .icrc_drop_count(icrc_drop_count)
  );

  function automatic logic [7:0] get_byte(
    input logic [511:0] data,
    input integer index
  );
    get_byte = data[index * 8 +: 8];
  endfunction

  task automatic put_byte(
    inout logic [511:0] data,
    input integer index,
    input logic [7:0] value
  );
    data[index * 8 +: 8] = value;
  endtask

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      crc32_byte_ref = crc;
    end
  endfunction

  task automatic build_ack(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input logic corrupt_icrc,
    input logic corrupt_header,
    output logic [511:0] data
  );
    logic [31:0] crc;
    logic [31:0] icrc;
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
      put_byte(data, 14, 8'h45);
      put_byte(data, 23, 8'd17);
      put_byte(data, 26, REMOTE_IP[31:24]);
      put_byte(data, 27, REMOTE_IP[23:16]);
      put_byte(data, 28, REMOTE_IP[15:8]);
      put_byte(data, 29, REMOTE_IP[7:0]);
      put_byte(data, 30, LOCAL_IP[31:24]);
      put_byte(data, 31, LOCAL_IP[23:16]);
      put_byte(data, 32, LOCAL_IP[15:8]);
      put_byte(data, 33, LOCAL_IP[7:0]);
      put_byte(data, 36, 8'h12);
      put_byte(data, 37, 8'hB7);
      put_byte(data, 38, 8'h00);
      put_byte(data, 39, 8'h1C);
      put_byte(data, 42, 8'h11);
      put_byte(data, 47, LOCAL_QPN[23:16]);
      put_byte(data, 48, LOCAL_QPN[15:8]);
      put_byte(data, 49, LOCAL_QPN[7:0]);
      put_byte(data, 51, psn[23:16]);
      put_byte(data, 52, psn[15:8]);
      put_byte(data, 53, psn[7:0]);
      put_byte(data, 54, syndrome);
      if (corrupt_header) put_byte(data, 42, 8'h12);

      crc = RDMA_ICRC_INIT;
      for (index = 0; index < 44; index = index + 1) begin
        crc_byte = get_byte(data, 14 + index);
        case (index)
          1, 8, 10, 11, 26, 27, 32: crc_byte = 8'hFF;
          default: crc_byte = crc_byte;
        endcase
        crc = crc32_byte_ref(crc, crc_byte);
      end
      icrc = ~crc;
      if (corrupt_icrc) icrc = icrc ^ 32'd1;
      put_byte(data, 58, icrc[7:0]);
      put_byte(data, 59, icrc[15:8]);
      put_byte(data, 60, icrc[23:16]);
      put_byte(data, 61, icrc[31:24]);
    end
  endtask

  task automatic send_ack(
    input logic [23:0] psn,
    input logic [7:0] syndrome,
    input logic corrupt_icrc,
    input logic corrupt_header
  );
    logic [511:0] data;
    begin
      build_ack(psn, syndrome, corrupt_icrc, corrupt_header, data);
      while (!rx_axis_tready) @(posedge clk);
      @(negedge clk);
      rx_axis_tdata = data;
      rx_axis_tkeep = 64'h3FFF_FFFF_FFFF_FFFF;
      rx_axis_tlast = 1'b1;
      rx_axis_tvalid = 1'b1;
      @(negedge clk);
      rx_axis_tvalid = 1'b0;
      rx_axis_tlast = 1'b0;
      rx_axis_tkeep = 64'd0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    send_ack(24'h01_0203, 8'h1F, 1'b0, 1'b0);
    wait (event_count == 1);
    if (event_psn != 24'h01_0203 || event_syndrome != 8'h1F || event_is_nak)
      $fatal(1, "valid ACK event mismatch");

    send_ack(24'h01_0204, 8'h21, 1'b1, 1'b0);
    wait (icrc_drop_count == 32'd1);
    if (event_count != 1) $fatal(1, "bad ICRC produced an ACK event");

    send_ack(24'h01_0205, 8'h60, 1'b0, 1'b1);
    wait (invalid_count == 1);
    if (event_count != 1) $fatal(1, "bad header produced an ACK event");

    @(negedge clk);
    clear_counters = 1'b1;
    @(negedge clk);
    clear_counters = 1'b0;
    @(posedge clk);
    if (icrc_drop_count != 32'd0) $fatal(1, "ICRC counter clear failed");

    $display("rdma_ack_receiver_tb PASS");
    $finish;
  end

  initial begin
    #3_000_000;
    $fatal(1, "ACK receiver test timeout");
  end
endmodule
