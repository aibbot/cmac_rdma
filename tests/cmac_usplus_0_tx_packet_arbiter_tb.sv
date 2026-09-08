`timescale 1ns/1ps

module cmac_usplus_0_tx_packet_arbiter_tb;

    logic clk = 1'b0;
    logic reset = 1'b1;

    logic reply_axis_tready;
    logic reply_axis_tvalid = 1'b0;
    logic [511:0] reply_axis_tdata = '0;
    logic reply_axis_tlast = 1'b0;
    logic [63:0] reply_axis_tkeep = '0;
    logic reply_axis_tuser = 1'b0;
    logic reply_pending = 1'b0;
    logic udp_config_inhibit = 1'b0;

    logic [3:0] udp_axis_enable = 4'b0000;
    logic [3:0] udp_axis_tready;
    logic [3:0] udp_axis_tvalid = 4'b0000;
    logic [3:0][511:0] udp_axis_tdata = '0;
    logic [3:0] udp_axis_tlast = 4'b0000;
    logic [3:0][63:0] udp_axis_tkeep = '0;
    logic [3:0] udp_axis_tuser = 4'b0000;

    logic tx_axis_tready = 1'b0;
    logic tx_axis_tvalid;
    logic [511:0] tx_axis_tdata;
    logic tx_axis_tlast;
    logic [63:0] tx_axis_tkeep;
    logic tx_axis_tuser;

    logic [31:0] output_tag [0:1];
    logic        output_last [0:1];
    integer      output_count = 0;

    cmac_usplus_0_tx_packet_arbiter dut (
        .clk               (clk),
        .reset             (reset),
        .reply_axis_tready (reply_axis_tready),
        .reply_axis_tvalid (reply_axis_tvalid),
        .reply_axis_tdata  (reply_axis_tdata),
        .reply_axis_tlast  (reply_axis_tlast),
        .reply_axis_tkeep  (reply_axis_tkeep),
        .reply_axis_tuser  (reply_axis_tuser),
        .reply_pending     (reply_pending),
        .udp_config_inhibit(udp_config_inhibit),
        .udp_axis_enable   (udp_axis_enable),
        .udp_axis_tready   (udp_axis_tready),
        .udp_axis_tvalid   (udp_axis_tvalid),
        .udp_axis_tdata    (udp_axis_tdata),
        .udp_axis_tlast    (udp_axis_tlast),
        .udp_axis_tkeep    (udp_axis_tkeep),
        .udp_axis_tuser    (udp_axis_tuser),
        .tx_axis_tready    (tx_axis_tready),
        .tx_axis_tvalid    (tx_axis_tvalid),
        .tx_axis_tdata     (tx_axis_tdata),
        .tx_axis_tlast     (tx_axis_tlast),
        .tx_axis_tkeep     (tx_axis_tkeep),
        .tx_axis_tuser     (tx_axis_tuser)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (tx_axis_tvalid && tx_axis_tready) begin
            if (output_count >= 2)
                $fatal(1, "Arbiter emitted more than the two expected beats");
            output_tag[output_count] = tx_axis_tdata[31:0];
            output_last[output_count] = tx_axis_tlast;
            output_count = output_count + 1;
        end
    end

    task automatic send_first_beat;
        begin
            @(negedge clk);
            udp_axis_tvalid[0] = 1'b1;
            udp_axis_tdata[0] = '0;
            udp_axis_tdata[0][31:0] = 32'h1111_0001;
            udp_axis_tlast[0] = 1'b0;
            udp_axis_tkeep[0] = 64'hFFFF_FFFF_FFFF_FFFF;
            udp_axis_tuser[0] = 1'b0;
            while (!(udp_axis_tvalid[0] && udp_axis_tready[0]))
                @(posedge clk);
            @(negedge clk);
            udp_axis_tvalid[0] = 1'b0;
        end
    endtask

    initial begin
        integer wait_cycles;

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        udp_axis_enable = 4'b0001;
        // Hold idle arbitration while the first beat enters the elastic
        // buffer. The next source beat must be stalled by its one-beat depth.
        reply_pending = 1'b1;
        repeat (2) @(posedge clk);
        send_first_beat();

        repeat (2) @(posedge clk);
        if (udp_axis_tready[0] || !dut.udp_buffer_valid_q[0])
            $fatal(1, "Full one-beat UDP buffer did not apply backpressure");

        @(negedge clk);
        udp_axis_tvalid[0] = 1'b1;
        udp_axis_tdata[0] = '0;
        udp_axis_tdata[0][31:0] = 32'h2222_0002;
        udp_axis_tlast[0] = 1'b1;
        udp_axis_tkeep[0] = 64'hFFFF_FFFF_FFFF_FFFF;
        udp_axis_tuser[0] = 1'b0;
        repeat (2) @(posedge clk);
        if (udp_axis_tready[0])
            $fatal(1, "A second beat bypassed the full elastic buffer");

        // Releasing arbitration makes the first beat pop into the output
        // register. The second beat must handshake in that same clock.
        @(negedge clk);
        reply_pending = 1'b0;
        wait_cycles = 0;
        while (!(udp_axis_tvalid[0] && udp_axis_tready[0])) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 16)
                $fatal(1, "Arbiter did not schedule the buffered UDP frame");
        end
        if (!dut.udp_buffer_pop[0] || !dut.udp_buffer_valid_q[0])
            $fatal(1, "Full elastic buffer did not dequeue and refill together");
        @(negedge clk);
        udp_axis_tvalid[0] = 1'b0;

        // Backpressure must hold the first registered output beat unchanged.
        repeat (2) begin
            @(posedge clk);
            if (!tx_axis_tvalid || tx_axis_tdata[31:0] !== 32'h1111_0001 ||
                tx_axis_tlast)
                $fatal(1, "Arbiter output changed while CMAC tready was low");
        end

        @(negedge clk);
        tx_axis_tready = 1'b1;
        wait_cycles = 0;
        while (output_count < 2) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 16)
                $fatal(1, "Arbiter did not drain the refilled elastic buffer");
        end

        if (output_tag[0] !== 32'h1111_0001 || output_last[0] ||
            output_tag[1] !== 32'h2222_0002 || !output_last[1])
            $fatal(1, "Elastic-buffer dequeue/refill changed frame order");
        if (tx_axis_tuser)
            $fatal(1, "Arbiter changed UDP tuser");

        $display("cmac_usplus_0_tx_packet_arbiter_tb PASS");
        $finish;
    end

endmodule
