`timescale 1ns / 1ps

module rdma_axis_register_tb;

  localparam integer RANDOM_BEAT_COUNT = 96;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic flush = 1'b0;
  logic s_axis_tvalid = 1'b0;
  logic s_axis_tready;
  logic [511:0] s_axis_tdata = 512'd0;
  logic [63:0] s_axis_tkeep = 64'd0;
  logic s_axis_tlast = 1'b0;
  logic s_axis_tuser = 1'b0;
  logic m_axis_tvalid;
  logic m_axis_tready = 1'b0;
  logic [511:0] m_axis_tdata;
  logic [63:0] m_axis_tkeep;
  logic m_axis_tlast;
  logic m_axis_tuser;

  logic [511:0] observed_data [0:3];
  integer observed_count = 0;
  logic directed_capture_active = 1'b1;

  logic output_stalled = 1'b0;
  logic [511:0] stalled_data = 512'd0;
  logic [63:0] stalled_keep = 64'd0;
  logic stalled_last = 1'b0;
  logic stalled_user = 1'b0;

  logic random_test_active = 1'b0;
  integer random_sent = 0;
  integer random_received = 0;
  integer random_valid_gap_cycles = 0;
  integer random_ready_low_cycles = 0;
  integer random_source_stall_cycles = 0;
  integer random_output_stall_cycles = 0;

  always #2 clk = ~clk;

  rdma_axis_register dut (
    .clk(clk),
    .reset(reset),
    .flush(flush),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser)
  );

  always @(posedge clk) begin
    if (directed_capture_active && m_axis_tvalid && m_axis_tready) begin
      observed_data[observed_count] = m_axis_tdata;
      observed_count = observed_count + 1;
    end

    if (reset || flush) begin
      output_stalled = 1'b0;
    end else begin
      if (output_stalled &&
          (!m_axis_tvalid ||
           (m_axis_tdata !== stalled_data) ||
           (m_axis_tkeep !== stalled_keep) ||
           (m_axis_tlast !== stalled_last) ||
           (m_axis_tuser !== stalled_user))) begin
        $fatal(1, "AXI output changed while valid was held without ready");
      end

      output_stalled = m_axis_tvalid && !m_axis_tready;
      if (m_axis_tvalid && !m_axis_tready) begin
        stalled_data = m_axis_tdata;
        stalled_keep = m_axis_tkeep;
        stalled_last = m_axis_tlast;
        stalled_user = m_axis_tuser;
      end
    end

    if (random_test_active) begin
      if (s_axis_tvalid && s_axis_tready)
        random_sent = random_sent + 1;

      if (m_axis_tvalid && m_axis_tready) begin
        if ((m_axis_tdata !== expected_random_data(random_received)) ||
            (m_axis_tkeep !== expected_random_keep(random_received)) ||
            (m_axis_tlast !== expected_random_last(random_received)) ||
            (m_axis_tuser !== expected_random_user(random_received))) begin
          $fatal(1, "randomized AXI beat %0d was corrupted or reordered",
                 random_received);
        end
        random_received = random_received + 1;
      end

      if (!s_axis_tvalid && (random_sent < RANDOM_BEAT_COUNT))
        random_valid_gap_cycles = random_valid_gap_cycles + 1;
      if (!m_axis_tready)
        random_ready_low_cycles = random_ready_low_cycles + 1;
      if (s_axis_tvalid && !s_axis_tready)
        random_source_stall_cycles = random_source_stall_cycles + 1;
      if (m_axis_tvalid && !m_axis_tready)
        random_output_stall_cycles = random_output_stall_cycles + 1;
    end
  end

  function automatic logic [511:0] expected_random_data(
    input logic [31:0] beat_index
  );
    expected_random_data = {16{32'hA5C3_0000 ^ beat_index}};
  endfunction

  function automatic logic [63:0] expected_random_keep(
    input logic [31:0] beat_index
  );
    expected_random_keep = 64'hFFFF_FFFF_FFFF_FFFF >> beat_index[4:0];
  endfunction

  function automatic logic expected_random_last(
    input logic [31:0] beat_index
  );
    expected_random_last = (beat_index[2:0] == 3'd6) ||
                           (beat_index == RANDOM_BEAT_COUNT - 1);
  endfunction

  function automatic logic expected_random_user(
    input logic [31:0] beat_index
  );
    expected_random_user = beat_index[0] ^ beat_index[3];
  endfunction

  task automatic present_beat(
    input logic [511:0] data,
    input logic [63:0] keep,
    input logic last,
    input logic user
  );
    begin
      @(negedge clk);
      s_axis_tvalid = 1'b1;
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tuser = user;
      if (!s_axis_tready) $fatal(1, "axis register unexpectedly backpressured an available slot");
      @(posedge clk);
      #1;
      s_axis_tvalid = 1'b0;
    end
  endtask

  task automatic run_randomized_stalls;
    logic [31:0] prng_state;
    integer cycle_count;
    begin
      prng_state = 32'h1ACE_B00C;
      cycle_count = 0;
      random_sent = 0;
      random_received = 0;
      random_valid_gap_cycles = 0;
      random_ready_low_cycles = 0;
      random_source_stall_cycles = 0;
      random_output_stall_cycles = 0;

      @(negedge clk);
      s_axis_tvalid = 1'b0;
      m_axis_tready = 1'b0;
      random_test_active = 1'b1;

      while ((random_received < RANDOM_BEAT_COUNT) &&
             (cycle_count < 2000)) begin
        @(negedge clk);
        prng_state = {prng_state[30:0],
                      prng_state[31] ^ prng_state[21] ^
                      prng_state[1] ^ prng_state[0]};
        m_axis_tready = prng_state[8];

        if (!(s_axis_tvalid && !s_axis_tready)) begin
          if ((random_sent < RANDOM_BEAT_COUNT) && prng_state[0]) begin
            s_axis_tvalid = 1'b1;
            s_axis_tdata = expected_random_data(random_sent);
            s_axis_tkeep = expected_random_keep(random_sent);
            s_axis_tlast = expected_random_last(random_sent);
            s_axis_tuser = expected_random_user(random_sent);
          end else begin
            s_axis_tvalid = 1'b0;
          end
        end

        cycle_count = cycle_count + 1;
      end

      @(negedge clk);
      random_test_active = 1'b0;
      s_axis_tvalid = 1'b0;
      m_axis_tready = 1'b0;

      if ((random_sent != RANDOM_BEAT_COUNT) ||
          (random_received != RANDOM_BEAT_COUNT)) begin
        $fatal(1, "randomized AXI test timed out: sent=%0d received=%0d cycles=%0d",
               random_sent, random_received, cycle_count);
      end
      if ((random_valid_gap_cycles == 0) ||
          (random_ready_low_cycles == 0) ||
          (random_source_stall_cycles == 0) ||
          (random_output_stall_cycles == 0)) begin
        $fatal(1, "randomized AXI test did not exercise all stall modes");
      end

      $display("randomized AXI stalls: valid_gaps=%0d ready_low=%0d source_stalls=%0d output_stalls=%0d cycles=%0d",
               random_valid_gap_cycles, random_ready_low_cycles,
               random_source_stall_cycles, random_output_stall_cycles,
               cycle_count);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    // Two entries absorb downstream backpressure without exposing a
    // combinational m_axis_tready -> s_axis_tready path.
    present_beat(512'hA1, 64'hFFFF_FFFF_FFFF_FFFF, 1'b0, 1'b0);
    if (!m_axis_tvalid || m_axis_tdata != 512'hA1 || !s_axis_tready) begin
      $fatal(1, "axis register did not retain one output beat and one free slot");
    end

    present_beat(512'hB2, 64'h0000_0000_0000_00FF, 1'b1, 1'b0);
    if (!m_axis_tvalid || m_axis_tdata != 512'hA1 || s_axis_tready) begin
      $fatal(1, "axis register did not report a full two-entry buffer");
    end

    @(negedge clk);
    m_axis_tready = 1'b1;
    #1;
    if (s_axis_tready) begin
      $fatal(1, "upstream ready changed combinationally with downstream ready");
    end

    @(posedge clk);
    #1;
    if (!m_axis_tvalid || m_axis_tdata != 512'hB2 || !s_axis_tready) begin
      $fatal(1, "axis register did not advance to the second buffered beat");
    end

    @(negedge clk);
    s_axis_tvalid = 1'b1;
    s_axis_tdata = 512'hC3;
    s_axis_tkeep = 64'h1;
    s_axis_tlast = 1'b1;
    s_axis_tuser = 1'b1;
    @(posedge clk);
    #1;
    s_axis_tvalid = 1'b0;
    if (!m_axis_tvalid || m_axis_tdata != 512'hC3) begin
      $fatal(1, "axis register did not sustain simultaneous dequeue and enqueue");
    end

    @(posedge clk);
    #1;
    if (m_axis_tvalid || observed_count != 3 ||
        observed_data[0] != 512'hA1 || observed_data[1] != 512'hB2 ||
        observed_data[2] != 512'hC3) begin
      $fatal(1, "axis register reordered or lost data under backpressure");
    end

    // A synchronous flush discards stale beats after a coordinated abort.
    m_axis_tready = 1'b0;
    present_beat(512'hD4, 64'h1, 1'b1, 1'b0);
    @(negedge clk);
    flush = 1'b1;
    s_axis_tvalid = 1'b1;
    s_axis_tdata = 512'hE5;
    @(posedge clk);
    #1;
    if (m_axis_tvalid || !s_axis_tready) begin
      $fatal(1, "axis register flush did not discard buffered data");
    end
    flush = 1'b0;
    s_axis_tvalid = 1'b0;
    present_beat(512'hF6, 64'h1, 1'b1, 1'b0);
    if (!m_axis_tvalid || m_axis_tdata != 512'hF6) begin
      $fatal(1, "axis register exposed stale data after flush");
    end
    @(negedge clk);
    m_axis_tready = 1'b1;
    @(posedge clk);
    #1;
    m_axis_tready = 1'b0;

    directed_capture_active = 1'b0;
    run_randomized_stalls();

    $display("rdma_axis_register_tb PASS");
    $finish;
  end

endmodule
