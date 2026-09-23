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

    logic [31:0] output_tag [0:15];
    logic        output_last [0:15];
    logic [63:0] output_keep [0:15];
    logic        output_user [0:15];
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
        if (!reset && tx_axis_tvalid && tx_axis_tready) begin
            if (output_count >= 16)
                $fatal(1, "Arbiter emitted more beats than the test can record");
            output_tag[output_count] = tx_axis_tdata[31:0];
            output_last[output_count] = tx_axis_tlast;
            output_keep[output_count] = tx_axis_tkeep;
            output_user[output_count] = tx_axis_tuser;
            output_count = output_count + 1;
        end
    end

    task automatic reset_dut;
        begin
            @(negedge clk);
            reset = 1'b1;
            reply_axis_tvalid = 1'b0;
            reply_axis_tdata = '0;
            reply_axis_tlast = 1'b0;
            reply_axis_tkeep = '0;
            reply_axis_tuser = 1'b0;
            reply_pending = 1'b0;
            udp_config_inhibit = 1'b0;
            udp_axis_enable = 4'b0000;
            udp_axis_tvalid = 4'b0000;
            udp_axis_tdata = '0;
            udp_axis_tlast = 4'b0000;
            udp_axis_tkeep = '0;
            udp_axis_tuser = 4'b0000;
            tx_axis_tready = 1'b0;
            output_count = 0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    task automatic drive_udp_beat(
        input integer stream_index,
        input logic [31:0] tag,
        input logic last
    );
        begin
            udp_axis_tdata[stream_index] = '0;
            udp_axis_tdata[stream_index][31:0] = tag;
            udp_axis_tlast[stream_index] = last;
            udp_axis_tkeep[stream_index] = 64'hFFFF_FFFF_FFFF_FFFF;
            udp_axis_tuser[stream_index] = 1'b0;
            udp_axis_tvalid[stream_index] = 1'b1;
        end
    endtask

    task automatic send_udp_beat(
        input integer stream_index,
        input logic [31:0] tag,
        input logic last
    );
        integer wait_cycles;
        begin
            @(negedge clk);
            drive_udp_beat(stream_index, tag, last);
            wait_cycles = 0;
            while (!udp_axis_tready[stream_index]) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 24)
                    $fatal(1, "UDP stream %0d never became ready", stream_index);
            end
            @(negedge clk);
            udp_axis_tvalid[stream_index] = 1'b0;
        end
    endtask

    task automatic wait_for_output_count(input integer expected_count);
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (output_count < expected_count) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 48)
                    $fatal(1, "Timed out waiting for %0d output beats", expected_count);
            end
        end
    endtask

    task automatic verify_single_beat(
        input integer output_index,
        input logic [31:0] expected_tag
    );
        begin
            if (output_tag[output_index] !== expected_tag ||
                !output_last[output_index] ||
                output_keep[output_index] !== 64'hFFFF_FFFF_FFFF_FFFF ||
                output_user[output_index])
                $fatal(1, "Unexpected single-beat output at index %0d", output_index);
        end
    endtask

    initial begin
        integer wait_cycles;

        // A full one-beat ingress buffer must backpressure its source, then
        // dequeue and refill without changing frame order. Only public AXI
        // signals are used to characterize the elastic-buffer behavior.
        reset_dut();
        @(negedge clk);
        udp_axis_enable = 4'b0001;
        reply_pending = 1'b1;
        repeat (2) @(posedge clk);
        send_udp_beat(0, 32'h1111_0001, 1'b0);

        repeat (2) @(posedge clk);
        if (udp_axis_tready[0])
            $fatal(1, "Full one-beat UDP buffer did not apply backpressure");

        @(negedge clk);
        drive_udp_beat(0, 32'h2222_0002, 1'b1);
        repeat (2) @(posedge clk);
        if (udp_axis_tready[0])
            $fatal(1, "A second beat bypassed the full elastic buffer");

        @(negedge clk);
        reply_pending = 1'b0;
        wait_cycles = 0;
        while (!udp_axis_tready[0]) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 16)
                $fatal(1, "Arbiter did not schedule the buffered UDP frame");
        end
        @(negedge clk);
        udp_axis_tvalid[0] = 1'b0;

        repeat (2) begin
            @(posedge clk);
            if (!tx_axis_tvalid || tx_axis_tdata[31:0] !== 32'h1111_0001 ||
                tx_axis_tlast)
                $fatal(1, "Arbiter output changed while CMAC tready was low");
        end

        @(negedge clk);
        tx_axis_tready = 1'b1;
        wait_for_output_count(2);
        if (output_tag[0] !== 32'h1111_0001 || output_last[0] ||
            output_tag[1] !== 32'h2222_0002 || !output_last[1])
            $fatal(1, "Elastic-buffer dequeue/refill changed frame order");

        // Completing stream 2 makes stream 3 the next round-robin candidate.
        // With all four streams then pending together, the public output order
        // must wrap through 3, 0, 1, 2 rather than fall back to fixed priority.
        reset_dut();
        @(negedge clk);
        udp_axis_enable = 4'b1111;
        tx_axis_tready = 1'b1;
        repeat (2) @(posedge clk);
        send_udp_beat(2, 32'hA002_0000, 1'b1);
        wait_for_output_count(1);
        verify_single_beat(0, 32'hA002_0000);

        @(negedge clk);
        drive_udp_beat(0, 32'hB000_0000, 1'b1);
        drive_udp_beat(1, 32'hB001_0000, 1'b1);
        drive_udp_beat(2, 32'hB002_0000, 1'b1);
        drive_udp_beat(3, 32'hB003_0000, 1'b1);
        #1;
        if (udp_axis_tready !== 4'b1111)
            $fatal(1, "Empty enabled UDP buffers were not all ready");
        @(posedge clk);
        @(negedge clk);
        udp_axis_tvalid = 4'b0000;

        wait_for_output_count(5);
        verify_single_beat(1, 32'hB003_0000);
        verify_single_beat(2, 32'hB000_0000);
        verify_single_beat(3, 32'hB001_0000);
        verify_single_beat(4, 32'hB002_0000);

        // A beat buffered while enabled must be discarded if its stream is
        // masked before arbitration. Disabled sources must stay not-ready,
        // while enabled streams 1 and 3 continue round-robinning.
        reset_dut();
        @(negedge clk);
        udp_axis_enable = 4'b1111;
        reply_pending = 1'b1;
        tx_axis_tready = 1'b1;
        repeat (2) @(posedge clk);
        send_udp_beat(2, 32'hC002_0000, 1'b1);
        @(negedge clk);
        udp_axis_enable = 4'b1010;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reply_pending = 1'b0;
        repeat (8) @(posedge clk);
        if (output_count != 0)
            $fatal(1, "Masked buffered stream emitted a stale beat");

        @(negedge clk);
        drive_udp_beat(0, 32'hD000_0000, 1'b1);
        drive_udp_beat(1, 32'hD001_0000, 1'b1);
        drive_udp_beat(2, 32'hD002_0000, 1'b1);
        drive_udp_beat(3, 32'hD003_0000, 1'b1);
        #1;
        if (udp_axis_tready !== 4'b1010)
            $fatal(1, "UDP stream mask did not control source readiness");
        @(posedge clk);
        @(negedge clk);
        udp_axis_tvalid = 4'b0000;

        wait_for_output_count(2);
        verify_single_beat(0, 32'hD001_0000);
        verify_single_beat(1, 32'hD003_0000);
        repeat (8) @(posedge clk);
        if (output_count != 2)
            $fatal(1, "Disabled UDP stream was accepted by the arbiter");

        $display("cmac_usplus_0_tx_packet_arbiter_tb PASS");
        $finish;
    end

endmodule
