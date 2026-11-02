`timescale 1ns / 1ps

module rdma_pause_control_tb;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic pfc0_mode = 1'b0;
  logic [8:0] stat_rx_pause_req = 9'd0;
  logic [8:0] stat_rx_pause_valid = 9'd0;
  logic [8:0] ctl_rx_pause_enable;
  logic [8:0] ctl_rx_pause_ack;
  logic pause_pending;
  logic pause_active;
  logic frame_active;
  logic [2:0] pause_event_count;

  logic s_axis_tready;
  logic s_axis_tvalid = 1'b0;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic m_axis_tready = 1'b1;
  logic m_axis_tvalid;
  logic [511:0] m_axis_tdata;
  logic [63:0] m_axis_tkeep;
  logic m_axis_tlast;
  logic m_axis_tuser;

  logic [511:0] observed_data [0:15];
  logic observed_last [0:15];
  integer observed_count = 0;
  integer pulse_index;

  always #2 clk = ~clk;

  rdma_pause_control #(
    .EVENT_COUNTER_WIDTH(3)
  ) dut (
    .clk(clk),
    .reset(reset),
    .pfc0_mode(pfc0_mode),
    .stat_rx_pause_req(stat_rx_pause_req),
    .stat_rx_pause_valid(stat_rx_pause_valid),
    .ctl_rx_pause_enable(ctl_rx_pause_enable),
    .ctl_rx_pause_ack(ctl_rx_pause_ack),
    .pause_pending(pause_pending),
    .pause_active(pause_active),
    .frame_active(frame_active),
    .pause_event_count(pause_event_count),
    .s_axis_tready(s_axis_tready),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tready(m_axis_tready),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  always @(posedge clk) begin
    if (m_axis_tvalid && m_axis_tready) begin
      observed_data[observed_count] = m_axis_tdata;
      observed_last[observed_count] = m_axis_tlast;
      observed_count = observed_count + 1;
    end
  end

  task automatic step;
    begin
      @(posedge clk);
      #0.2;
    end
  endtask

  task automatic present_beat(
    input logic [511:0] data,
    input logic last
  );
    begin
      @(negedge clk);
      s_axis_tvalid = 1'b1;
      s_axis_tdata = data;
      s_axis_tkeep = 64'hffff_ffff_ffff_ffff;
      s_axis_tlast = last;
      s_axis_tuser = 1'b0;
    end
  endtask

  task automatic remove_beat;
    begin
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    step();

    if (ctl_rx_pause_enable != 9'h100 || ctl_rx_pause_ack != 9'h000) begin
      $fatal(1, "global PAUSE must be enabled by default");
    end

    // Global mode ignores PFC priorities, including a nonzero priority.
    present_beat(512'hA1, 1'b1);
    stat_rx_pause_req = 9'h002;
    stat_rx_pause_valid = 9'h002;
    step();
    if (observed_count != 1 || ctl_rx_pause_ack != 9'h000 ||
        pause_event_count != 3'd0) begin
      $fatal(1, "global mode reacted to an unrelated PFC request");
    end
    remove_beat();
    stat_rx_pause_req = 9'h000;
    stat_rx_pause_valid = 9'h000;

    // A global request while idle blocks the next frame before its first beat.
    present_beat(512'hB1, 1'b1);
    stat_rx_pause_req = 9'h100;
    stat_rx_pause_valid = 9'h100;
    #0.2;
    if (s_axis_tready || m_axis_tvalid) begin
      $fatal(1, "idle PAUSE did not block a new frame immediately");
    end
    step();
    if (!pause_active || pause_pending || ctl_rx_pause_ack != 9'h100 ||
        ctl_rx_pause_enable != 9'h100 || observed_count != 1 ||
        pause_event_count != 3'd1) begin
      $fatal(1, "idle global PAUSE did not enter the acknowledged state");
    end

    stat_rx_pause_req = 9'h000;
    stat_rx_pause_valid = 9'h000;
    step();
    if (pause_active || ctl_rx_pause_ack != 9'h000) begin
      $fatal(1, "global PAUSE did not release after request deassertion");
    end
    step();
    if (observed_count != 2 || observed_data[1] != 512'hB1) begin
      $fatal(1, "blocked frame did not resume after global PAUSE release");
    end
    remove_beat();

    // A request in the middle of a frame may not truncate that frame.
    present_beat(512'hC1, 1'b0);
    step();
    if (!frame_active || observed_count != 3) begin
      $fatal(1, "multi-beat frame did not start");
    end
    @(negedge clk);
    s_axis_tdata = 512'hC2;
    s_axis_tlast = 1'b1;
    stat_rx_pause_req = 9'h100;
    stat_rx_pause_valid = 9'h100;
    #0.2;
    if (!s_axis_tready || !m_axis_tvalid) begin
      $fatal(1, "mid-frame PAUSE truncated the current frame");
    end
    step();
    if (observed_count != 4 || observed_data[3] != 512'hC2 ||
        !observed_last[3] || frame_active || !pause_active || pause_pending ||
        ctl_rx_pause_ack != 9'h100 || pause_event_count != 3'd2) begin
      $fatal(1, "PAUSE was not acknowledged exactly after TLAST");
    end
    stat_rx_pause_valid = 9'h000;
    remove_beat();

    present_beat(512'hD1, 1'b1);
    step();
    if (observed_count != 4) begin
      $fatal(1, "PAUSE allowed a new frame after the current TLAST");
    end
    stat_rx_pause_req = 9'h000;
    stat_rx_pause_valid = 9'h000;
    step();
    step();
    if (observed_count != 5 || observed_data[4] != 512'hD1) begin
      $fatal(1, "second source frame did not resume after PAUSE release");
    end
    remove_beat();

    // PFC0 mode ignores global PAUSE and priorities 1-7.
    pfc0_mode = 1'b1;
    stat_rx_pause_req = 9'h102;
    stat_rx_pause_valid = 9'h102;
    present_beat(512'hE1, 1'b1);
    step();
    if (ctl_rx_pause_enable != 9'h001 || ctl_rx_pause_ack != 9'h000 ||
        observed_count != 6 || pause_event_count != 3'd2) begin
      $fatal(1, "PFC0 mode reacted to another class: enable=%03h ack=%03h observed=%0d events=%0d active=%0b pending=%0b",
             ctl_rx_pause_enable, ctl_rx_pause_ack, observed_count,
             pause_event_count, pause_active, pause_pending);
    end
    remove_beat();

    // While a PFC0 request is active, both ACK and enable retain the latched
    // mask even if the VIO mode changes. Mode changes are operationally made
    // only while traffic and PAUSE are idle.
    stat_rx_pause_req = 9'h001;
    stat_rx_pause_valid = 9'h001;
    step();
    if (!pause_active || ctl_rx_pause_ack != 9'h001 ||
        ctl_rx_pause_enable != 9'h001 || pause_event_count != 3'd3) begin
      $fatal(1, "priority-0 request was not acknowledged");
    end
    pfc0_mode = 1'b0;
    stat_rx_pause_valid = 9'h000;
    step();
    if (ctl_rx_pause_ack != 9'h001 || ctl_rx_pause_enable != 9'h001) begin
      $fatal(1, "active PAUSE mask changed with the VIO mode");
    end

    // Once PFC0 releases, a pending global request must be recognized without
    // allowing a new frame to start between the two pause modes.
    stat_rx_pause_req = 9'h100;
    step();
    if (pause_active || ctl_rx_pause_ack != 9'h000 ||
        ctl_rx_pause_enable != 9'h100 || s_axis_tready) begin
      $fatal(1, "mode transition did not release the old ACK and block global PAUSE");
    end
    step();
    if (!pause_active || ctl_rx_pause_ack != 9'h100) begin
      $fatal(1, "global PAUSE did not engage after the locked PFC0 request");
    end
    stat_rx_pause_req = 9'h000;
    step();

    // Matching valid pulses count PAUSE frames and saturate instead of wrapping.
    for (pulse_index = 0; pulse_index < 10; pulse_index = pulse_index + 1) begin
      stat_rx_pause_valid = 9'h100;
      step();
      stat_rx_pause_valid = 9'h000;
      step();
    end
    if (pause_event_count != 3'h7) begin
      $fatal(1, "PAUSE event counter did not saturate: count=%0d", pause_event_count);
    end

    // AXI TVALID cannot be withdrawn after the first beat has been presented,
    // even when CMAC TREADY is low and PAUSE arrives before its handshake.
    m_axis_tready = 1'b0;
    present_beat(512'hF1, 1'b1);
    step();
    if (!m_axis_tvalid || !frame_active || m_axis_tdata != 512'hF1) begin
      $fatal(1, "stalled first beat was not locked as an active frame");
    end
    stat_rx_pause_req = 9'h100;
    #0.2;
    if (!m_axis_tvalid || m_axis_tdata != 512'hF1 || ctl_rx_pause_ack != 9'h000) begin
      $fatal(1, "PAUSE withdrew a first beat that was already presented");
    end
    m_axis_tready = 1'b1;
    step();
    if (observed_count != 7 || !pause_active || frame_active ||
        ctl_rx_pause_ack != 9'h100) begin
      $fatal(1, "stalled one-beat frame did not finish before PAUSE ACK");
    end
    remove_beat();
    stat_rx_pause_req = 9'h000;
    step();

    $display("rdma_pause_control_tb PASS");
    $finish;
  end

endmodule
