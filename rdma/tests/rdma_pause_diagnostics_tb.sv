`timescale 1ns / 1ps

module rdma_pause_diagnostics_tb;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic stat_rx_pause = 1'b0;
  logic [8:0] stat_rx_pause_req = 9'd0;
  logic [8:0] stat_rx_pause_valid = 9'd0;
  logic [15:0] stat_rx_pause_quanta8 = 16'd0;
  logic stat_rx_multicast = 1'b0;
  logic stat_rx_packet_64_bytes = 1'b0;
  logic [2:0] stat_rx_total_packets = 3'd0;
  logic stat_rx_user_pause = 1'b0;
  logic [2:0] pause_frame_count;
  logic [2:0] pause_valid8_count;
  logic [2:0] pause_req8_rise_count;
  logic [2:0] rx_multicast_count;
  logic [2:0] rx_packet_64_count;
  logic [2:0] rx_total_packet_count;
  logic [2:0] rx_user_pause_count;
  logic pause_seen_sticky;
  logic pause_req8_seen_sticky;
  logic [15:0] last_pause_quanta8;

  always #2 clk = ~clk;

  rdma_pause_diagnostics #(
    .COUNTER_WIDTH(3)
  ) dut (
    .clk(clk),
    .reset(reset),
    .stat_rx_pause(stat_rx_pause),
    .stat_rx_pause_req(stat_rx_pause_req),
    .stat_rx_pause_valid(stat_rx_pause_valid),
    .stat_rx_pause_quanta8(stat_rx_pause_quanta8),
    .stat_rx_multicast(stat_rx_multicast),
    .stat_rx_packet_64_bytes(stat_rx_packet_64_bytes),
    .stat_rx_total_packets(stat_rx_total_packets),
    .stat_rx_user_pause(stat_rx_user_pause),
    .pause_frame_count(pause_frame_count),
    .pause_valid8_count(pause_valid8_count),
    .pause_req8_rise_count(pause_req8_rise_count),
    .rx_multicast_count(rx_multicast_count),
    .rx_packet_64_count(rx_packet_64_count),
    .rx_total_packet_count(rx_total_packet_count),
    .rx_user_pause_count(rx_user_pause_count),
    .pause_seen_sticky(pause_seen_sticky),
    .pause_req8_seen_sticky(pause_req8_seen_sticky),
    .last_pause_quanta8(last_pause_quanta8)
  );

  task automatic step;
    begin
      @(posedge clk);
      #0.2;
    end
  endtask

  task automatic clear_inputs;
    begin
      stat_rx_pause = 1'b0;
      stat_rx_pause_req = 9'h000;
      stat_rx_pause_valid = 9'h000;
      stat_rx_multicast = 1'b0;
      stat_rx_packet_64_bytes = 1'b0;
      stat_rx_total_packets = 3'd0;
      stat_rx_user_pause = 1'b0;
    end
  endtask

  initial begin
    repeat (3) step();
    if (pause_frame_count != 3'd0 || pause_valid8_count != 3'd0 ||
        pause_req8_rise_count != 3'd0 || rx_multicast_count != 3'd0 ||
        rx_packet_64_count != 3'd0 || rx_total_packet_count != 3'd0 ||
        rx_user_pause_count != 3'd0 || pause_seen_sticky ||
        pause_req8_seen_sticky || last_pause_quanta8 != 16'h0000) begin
      $fatal(1, "diagnostics were not cleared during reset");
    end

    @(negedge clk);
    reset = 1'b0;

    // A raw MAC PAUSE indication is retained even if request/valid stay low,
    // but quanta is only valid when the corresponding valid bit is asserted.
    stat_rx_pause = 1'b1;
    stat_rx_pause_quanta8 = 16'h1234;
    step();
    clear_inputs();
    step();
    if (pause_frame_count != 3'd1 || !pause_seen_sticky ||
        pause_valid8_count != 3'd0 || pause_req8_rise_count != 3'd0 ||
        pause_req8_seen_sticky || last_pause_quanta8 != 16'h0000) begin
      $fatal(1, "raw PAUSE indication was not retained");
    end

    // Global valid and request activity are counted independently. A held
    // request is one edge, while valid pulses count every received update.
    stat_rx_pause_req = 9'h100;
    stat_rx_pause_valid = 9'h100;
    stat_rx_pause_quanta8 = 16'h4567;
    step();
    stat_rx_pause_valid = 9'h000;
    step();
    stat_rx_pause_valid = 9'h100;
    stat_rx_pause_quanta8 = 16'h89ab;
    step();
    clear_inputs();
    step();
    if (pause_valid8_count != 3'd2 || pause_req8_rise_count != 3'd1 ||
        !pause_req8_seen_sticky || last_pause_quanta8 != 16'h89ab) begin
      $fatal(1, "global PAUSE valid/request diagnostics are incorrect");
    end

    // Another request after a low interval must create a second edge.
    stat_rx_pause_req = 9'h100;
    step();
    clear_inputs();
    step();
    if (pause_req8_rise_count != 3'd2) begin
      $fatal(1, "second global PAUSE request edge was not counted");
    end

    // General CMAC RX statistics distinguish an unclassified control frame
    // from a frame that never reached the receive MAC.
    stat_rx_multicast = 1'b1;
    stat_rx_packet_64_bytes = 1'b1;
    stat_rx_total_packets = 3'd3;
    stat_rx_user_pause = 1'b1;
    step();
    clear_inputs();
    step();
    if (rx_multicast_count != 3'd1 || rx_packet_64_count != 3'd1 ||
        rx_total_packet_count != 3'd3 || rx_user_pause_count != 3'd1) begin
      $fatal(1, "general CMAC RX diagnostics were not counted");
    end

    // All diagnostic counters saturate instead of wrapping.
    repeat (8) begin
      stat_rx_pause = 1'b1;
      stat_rx_pause_valid = 9'h100;
      stat_rx_pause_req = 9'h100;
      stat_rx_multicast = 1'b1;
      stat_rx_packet_64_bytes = 1'b1;
      stat_rx_total_packets = 3'd2;
      stat_rx_user_pause = 1'b1;
      step();
      clear_inputs();
      step();
    end
    if (pause_frame_count != 3'h7 || pause_valid8_count != 3'h7 ||
        pause_req8_rise_count != 3'h7 || rx_multicast_count != 3'h7 ||
        rx_packet_64_count != 3'h7 || rx_total_packet_count != 3'h7 ||
        rx_user_pause_count != 3'h7) begin
      $fatal(1, "diagnostic counters did not saturate");
    end

    // Reset clears sticky state, counters, edge history, and latched quanta.
    reset = 1'b1;
    step();
    if (pause_frame_count != 3'd0 || pause_valid8_count != 3'd0 ||
        pause_req8_rise_count != 3'd0 || rx_multicast_count != 3'd0 ||
        rx_packet_64_count != 3'd0 || rx_total_packet_count != 3'd0 ||
        rx_user_pause_count != 3'd0 || pause_seen_sticky ||
        pause_req8_seen_sticky || last_pause_quanta8 != 16'h0000) begin
      $fatal(1, "diagnostics did not clear on reset");
    end

    $display("rdma_pause_diagnostics_tb PASS");
    $finish;
  end

endmodule
