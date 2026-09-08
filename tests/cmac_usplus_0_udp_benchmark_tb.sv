`timescale 1ns/1ps

module cmac_usplus_0_udp_benchmark_tb;

    localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
    localparam logic [31:0] LOCAL_IP = 32'hC0A8_650B;
    localparam logic [47:0] DEFAULT_DESTINATION_MAC = 48'h10_7C_61_5D_E2_5B;
    localparam logic [31:0] DEFAULT_DESTINATION_IP = 32'hC0A8_6507;
    localparam logic [15:0] DEFAULT_PAYLOAD_LENGTH = 16'd9000;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic enable = 1'b0;
    logic counter_reset = 1'b0;
    logic [31:0] local_ip = LOCAL_IP;
    logic [47:0] destination_mac = DEFAULT_DESTINATION_MAC;
    logic [31:0] destination_ip = DEFAULT_DESTINATION_IP;
    logic [15:0] source_port = 16'd5001;
    logic [15:0] destination_port = 16'd5001;
    logic [15:0] payload_length = DEFAULT_PAYLOAD_LENGTH;
    logic [31:0] gap_cycles = 32'd0;
    logic tx_axis_tready = 1'b1;
    logic tx_axis_tvalid;
    logic [511:0] tx_axis_tdata;
    logic tx_axis_tlast;
    logic [63:0] tx_axis_tkeep;
    logic tx_axis_tuser;
    logic [31:0] packet_count;
    logic [39:0] tx_rate_bytes_per_second;
    logic [31:0] tx_local_drop_count;

    logic [7:0] captured [0:9599];
    integer captured_length;
    integer captured_beats;
    logic [63:0] captured_last_keep;
    integer cycle_count = 0;

    cmac_usplus_0_udp_benchmark #(
        .LOCAL_MAC (LOCAL_MAC),
        .STATS_CLOCK_HZ (16)
    ) dut (
        .clk              (clk),
        .reset            (reset),
        .enable           (enable),
        .counter_reset    (counter_reset),
        .frame_start_inhibit (1'b0),
        .local_ip         (local_ip),
        .destination_mac  (destination_mac),
        .destination_ip   (destination_ip),
        .source_port      (source_port),
        .destination_port (destination_port),
        .payload_length   (payload_length),
        .gap_cycles       (gap_cycles),
        .tx_axis_tready   (tx_axis_tready),
        .tx_axis_tvalid   (tx_axis_tvalid),
        .tx_axis_tdata    (tx_axis_tdata),
        .tx_axis_tlast    (tx_axis_tlast),
        .tx_axis_tkeep    (tx_axis_tkeep),
        .tx_axis_tuser    (tx_axis_tuser),
        .packet_count     (packet_count),
        .tx_rate_bytes_per_second (tx_rate_bytes_per_second),
        .tx_local_drop_count      (tx_local_drop_count)
    );

    always #5 clk = ~clk;

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "UDP benchmark test timed out");
    end

    function automatic logic [15:0] captured_be16(input integer index);
        captured_be16 = {captured[index], captured[index + 1]};
    endfunction

    function automatic logic [31:0] captured_be32(input integer index);
        captured_be32 = {
            captured[index],
            captured[index + 1],
            captured[index + 2],
            captured[index + 3]
        };
    endfunction

    function automatic logic [47:0] captured_mac(input integer index);
        captured_mac = {
            captured[index],
            captured[index + 1],
            captured[index + 2],
            captured[index + 3],
            captured[index + 4],
            captured[index + 5]
        };
    endfunction

    task automatic reset_dut;
        begin
            @(negedge clk);
            reset = 1'b1;
            enable = 1'b0;
            counter_reset = 1'b0;
            tx_axis_tready = 1'b1;
            local_ip = LOCAL_IP;
            destination_mac = DEFAULT_DESTINATION_MAC;
            destination_ip = DEFAULT_DESTINATION_IP;
            source_port = 16'd5001;
            destination_port = 16'd5001;
            payload_length = DEFAULT_PAYLOAD_LENGTH;
            gap_cycles = 32'd0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    task automatic capture_frame;
        integer byte_index;
        logic saw_keep_zero;
        logic done;
        begin
            captured_length = 0;
            captured_beats = 0;
            captured_last_keep = 64'd0;
            done = 1'b0;
            while (!done) begin
                @(posedge clk);
                if (tx_axis_tvalid && tx_axis_tready) begin
                    captured_beats = captured_beats + 1;
                    if (captured_beats > 160)
                        $fatal(1, "UDP frame exceeded maximum beat count");
                    if (tx_axis_tuser)
                        $fatal(1, "UDP frame asserted tuser");
                    if (!tx_axis_tlast &&
                        (tx_axis_tkeep !== 64'hFFFF_FFFF_FFFF_FFFF))
                        $fatal(1, "Non-final UDP beat has partial tkeep");

                    saw_keep_zero = 1'b0;
                    for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
                        if (tx_axis_tkeep[byte_index]) begin
                            if (saw_keep_zero)
                                $fatal(1, "UDP tkeep is not contiguous from bit zero");
                            if (captured_length >= 9600)
                                $fatal(1, "UDP capture buffer overflow");
                            captured[captured_length] =
                                tx_axis_tdata[byte_index * 8 +: 8];
                            captured_length = captured_length + 1;
                        end else begin
                            saw_keep_zero = 1'b1;
                        end
                    end
                    if (tx_axis_tlast)
                        captured_last_keep = tx_axis_tkeep;
                    done = tx_axis_tlast;
                end
            end
        end
    endtask

    task automatic verify_frame(
        input integer expected_payload_length,
        input logic [31:0] expected_sequence,
        input logic [47:0] expected_destination_mac,
        input logic [31:0] expected_source_ip,
        input logic [31:0] expected_destination_ip,
        input logic [15:0] expected_source_port,
        input logic [15:0] expected_destination_port
    );
        integer expected_frame_length;
        integer expected_beats;
        integer final_beat_bytes;
        integer index;
        integer unsigned checksum_sum;
        logic [63:0] expected_last_keep;
        begin
            expected_frame_length = 42 + expected_payload_length;
            if (expected_frame_length < 60)
                expected_frame_length = 60;

            expected_beats = (expected_frame_length + 63) / 64;
            final_beat_bytes = expected_frame_length % 64;
            if (final_beat_bytes == 0)
                expected_last_keep = 64'hFFFF_FFFF_FFFF_FFFF;
            else
                expected_last_keep = (64'h1 << final_beat_bytes) - 1'b1;

            if (captured_length != expected_frame_length)
                $fatal(1, "Frame length %0d, expected %0d",
                       captured_length, expected_frame_length);
            if (captured_beats != expected_beats)
                $fatal(1, "Frame beats %0d, expected %0d",
                       captured_beats, expected_beats);
            if (captured_last_keep !== expected_last_keep)
                $fatal(1, "Final tkeep %016x, expected %016x",
                       captured_last_keep, expected_last_keep);
            if (captured_mac(0) !== expected_destination_mac)
                $fatal(1, "Destination MAC mismatch");
            if (captured_mac(6) !== LOCAL_MAC)
                $fatal(1, "Source MAC mismatch");
            if (captured_be16(12) !== 16'h0800)
                $fatal(1, "EtherType mismatch");
            if (captured[14] !== 8'h45 || captured[15] !== 8'h00)
                $fatal(1, "Unexpected IPv4 version/IHL or DSCP/ECN");
            if (captured_be16(16) !== expected_payload_length + 28)
                $fatal(1, "IPv4 total length mismatch");
            if (captured_be16(18) !== 16'h0000 ||
                captured_be16(20) !== 16'h0000)
                $fatal(1, "Unexpected IPv4 ID or fragmentation field");
            if (captured[22] !== 8'h40 || captured[23] !== 8'h11)
                $fatal(1, "Unexpected IPv4 TTL or protocol");
            if (captured_be32(26) !== expected_source_ip ||
                captured_be32(30) !== expected_destination_ip)
                $fatal(1, "IPv4 address mismatch");
            if (captured_be16(34) !== expected_source_port ||
                captured_be16(36) !== expected_destination_port)
                $fatal(1, "UDP port mismatch");
            if (captured_be16(38) !== expected_payload_length + 8)
                $fatal(1, "UDP length mismatch");
            if (captured_be16(40) !== 16'h0000)
                $fatal(1, "UDP checksum is not zero");
            if (captured_be32(42) !== 32'h5246_534F)
                $fatal(1, "Benchmark magic mismatch");
            if (captured_be32(46) !== expected_sequence)
                $fatal(1, "Sequence %08x, expected %08x",
                       captured_be32(46), expected_sequence);
            if (captured_be16(50) !== 16'd1)
                $fatal(1, "Benchmark version mismatch");
            if (captured_be16(52) !== 16'd24)
                $fatal(1, "Benchmark header length mismatch");
            if (captured_be32(54) !== expected_payload_length)
                $fatal(1, "Benchmark payload length mismatch");

            checksum_sum = 0;
            for (index = 14; index < 34; index = index + 2)
                checksum_sum = checksum_sum + captured_be16(index);
            checksum_sum = (checksum_sum & 16'hFFFF) + (checksum_sum >> 16);
            checksum_sum = (checksum_sum & 16'hFFFF) + (checksum_sum >> 16);
            if (checksum_sum[15:0] !== 16'hFFFF)
                $fatal(1, "IPv4 header checksum mismatch: %04x",
                       checksum_sum[15:0]);

            for (index = 58; index < 66; index = index + 1) begin
                if (captured[index] !== 8'h00)
                    $fatal(1, "Nonzero reserved header byte at %0d", index);
            end
            for (index = 66; index < 42 + expected_payload_length; index = index + 1) begin
                if (captured[index] !== 8'h00)
                    $fatal(1, "Nonzero UDP payload byte at %0d", index);
            end
            for (index = 42 + expected_payload_length;
                 index < expected_frame_length;
                 index = index + 1) begin
                if (captured[index] !== 8'h00)
                    $fatal(1, "Nonzero Ethernet padding byte at %0d", index);
            end
        end
    endtask

    task automatic capture_single_configured_frame(
        input logic [15:0] requested_length,
        input integer expected_length
    );
        begin
            reset_dut();
            @(negedge clk);
            payload_length = requested_length;
            gap_cycles = 32'd8;
            enable = 1'b1;
            capture_frame();
            verify_frame(
                expected_length,
                32'd0,
                DEFAULT_DESTINATION_MAC,
                LOCAL_IP,
                DEFAULT_DESTINATION_IP,
                16'd5001,
                16'd5001
            );
            #1;
            if (packet_count !== 32'd1)
                $fatal(1, "Packet count did not increment");
            @(negedge clk);
            enable = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic check_gap(input logic [31:0] configured_gap);
        integer frame_index;
        integer start_cycle [0:2];
        integer completion_cycle [0:2];
        logic in_frame;
        begin
            reset_dut();
            @(negedge clk);
            payload_length = 16'd4;
            gap_cycles = configured_gap;
            enable = 1'b1;
            frame_index = 0;
            in_frame = 1'b0;
            while (frame_index < 3) begin
                @(posedge clk);
                if (tx_axis_tvalid && tx_axis_tready && tx_axis_tlast) begin
                    if (!in_frame)
                        start_cycle[frame_index] = cycle_count;
                    completion_cycle[frame_index] = cycle_count;
                    frame_index = frame_index + 1;
                    in_frame = 1'b0;
                end else if (tx_axis_tvalid && tx_axis_tready && !in_frame) begin
                    start_cycle[frame_index] = cycle_count;
                    in_frame = 1'b1;
                end
            end
            if ((start_cycle[1] - completion_cycle[0]) !=
                (configured_gap + 1))
                $fatal(1, "First packet gap mismatch for gap_cycles=%0d",
                       configured_gap);
            if ((start_cycle[2] - completion_cycle[1]) !=
                (configured_gap + 1))
                $fatal(1, "Second packet gap mismatch for gap_cycles=%0d",
                       configured_gap);
            @(negedge clk);
            enable = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic check_fixed_source_port;
        integer frame_index;
        begin
            reset_dut();
            @(negedge clk);
            source_port = 16'd1234;
            payload_length = 16'd24;
            gap_cycles = 32'd0;
            enable = 1'b1;

            for (frame_index = 0; frame_index < 3;
                 frame_index = frame_index + 1) begin
                capture_frame();
                verify_frame(24, frame_index, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                             DEFAULT_DESTINATION_IP, 16'd1234,
                             16'd5001);
            end
            #1;
            if (packet_count !== 32'd3)
                $fatal(1, "Fixed source port did not transmit three frames");
            @(negedge clk);
            enable = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic check_tx_statistics;
        integer wait_cycles;
        begin
            reset_dut();
            @(negedge clk);
            payload_length = 16'd24;
            gap_cycles = 32'd32;
            enable = 1'b1;

            wait (tx_axis_tvalid && tx_axis_tready && tx_axis_tlast);
            for (wait_cycles = 0;
                 wait_cycles < 32 && tx_rate_bytes_per_second == 40'd0;
                 wait_cycles = wait_cycles + 1)
                @(posedge clk);
            if (tx_rate_bytes_per_second !== 40'd66)
                $fatal(1, "TX rate sample was %0d, expected 66 bytes/s",
                       tx_rate_bytes_per_second);
            if (tx_local_drop_count !== 32'd0)
                $fatal(1, "Clean TX frame incremented local drop count");
            @(negedge clk);
            enable = 1'b0;

            reset_dut();
            @(negedge clk);
            payload_length = 16'd24;
            gap_cycles = 32'd32;
            tx_axis_tready = 1'b0;
            enable = 1'b1;
            wait (tx_axis_tvalid && !tx_axis_tlast);
            @(negedge clk);
            tx_axis_tready = 1'b1;
            wait (tx_axis_tvalid && tx_axis_tlast);
            @(negedge clk);
            force dut.tx_axis_tuser = 1'b1;
            @(posedge clk);
            #1;
            release dut.tx_axis_tuser;
            @(posedge clk);
            #1;
            if (tx_local_drop_count !== 32'd1)
                $fatal(1, "TX error frame did not increment local drop count");
            @(negedge clk);
            enable = 1'b0;
        end
    endtask

    initial begin
        logic [511:0] held_data;
        logic [63:0] held_keep;
        logic held_last;
        logic random_done;
        logic [15:0] lfsr;
        integer stall_index;

        capture_single_configured_frame(16'd0, 24);
        capture_single_configured_frame(16'd24, 24);
        capture_single_configured_frame(16'd86, 86);
        capture_single_configured_frame(16'd1472, 1472);
        capture_single_configured_frame(DEFAULT_PAYLOAD_LENGTH,
                                        DEFAULT_PAYLOAD_LENGTH);
        capture_single_configured_frame(16'd9554, 9554);
        capture_single_configured_frame(16'hFFFF, 9554);

        reset_dut();
        @(negedge clk);
        payload_length = 16'd777;
        gap_cycles = 32'd8;
        enable = 1'b1;
        random_done = 1'b0;
        lfsr = 16'h1;
        fork
            begin
                while (!random_done) begin
                    @(negedge clk);
                    lfsr = {lfsr[14:0],
                            lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
                    tx_axis_tready = lfsr[0] | lfsr[3];
                end
            end
            begin
                capture_frame();
                random_done = 1'b1;
            end
        join
        tx_axis_tready = 1'b1;
        verify_frame(777, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                     DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
        @(negedge clk);
        enable = 1'b0;

        reset_dut();
        @(negedge clk);
        payload_length = 16'd100;
        gap_cycles = 32'd8;
        enable = 1'b1;
        wait (tx_axis_tvalid);
        @(negedge clk);
        tx_axis_tready = 1'b0;
        held_data = tx_axis_tdata;
        held_keep = tx_axis_tkeep;
        held_last = tx_axis_tlast;
        for (stall_index = 0; stall_index < 4; stall_index = stall_index + 1) begin
            @(posedge clk);
            #1;
            if (!tx_axis_tvalid || tx_axis_tdata !== held_data ||
                tx_axis_tkeep !== held_keep || tx_axis_tlast !== held_last)
                $fatal(1, "AXI output changed under backpressure");
        end
        @(negedge clk);
        tx_axis_tready = 1'b1;
        capture_frame();
        verify_frame(100, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                     DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
        @(negedge clk);
        enable = 1'b0;

        check_gap(32'd0);
        check_gap(32'd3);
        check_fixed_source_port();
        check_tx_statistics();

        reset_dut();
        @(negedge clk);
        payload_length = 16'd24;
        gap_cycles = 32'd0;
        enable = 1'b1;
        fork
            begin
                wait (tx_axis_tvalid && tx_axis_tready && !tx_axis_tlast);
                @(posedge clk);
                @(negedge clk);
                destination_mac = 48'hAA_BB_CC_DD_EE_FF;
                destination_ip = 32'h0A00_0001;
                source_port = 16'd1234;
                destination_port = 16'd4321;
                payload_length = 16'd24;
                gap_cycles = 32'd2;
            end
            begin
                capture_frame();
                verify_frame(24, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                             DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
                // The update may arrive after the following descriptor has
                // been admitted. That frame must remain entirely old or new;
                // the next frame must use the new configuration.
                capture_frame();
                if (captured_mac(0) == DEFAULT_DESTINATION_MAC) begin
                    verify_frame(24, 32'd1, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                                 DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
                    capture_frame();
                    verify_frame(24, 32'd2, 48'hAA_BB_CC_DD_EE_FF, LOCAL_IP,
                                 32'h0A00_0001, 16'd1234, 16'd4321);
                end else begin
                    verify_frame(24, 32'd1, 48'hAA_BB_CC_DD_EE_FF, LOCAL_IP,
                                 32'h0A00_0001, 16'd1234, 16'd4321);
                end
            end
        join
        @(negedge clk);
        reset = 1'b1;

        reset_dut();
        @(negedge clk);
        payload_length = 16'd200;
        gap_cycles = 32'd0;
        enable = 1'b1;
        wait (tx_axis_tvalid && !tx_axis_tlast);
        @(negedge clk);
        enable = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (packet_count !== 32'd0)
            $fatal(1, "Interrupted packet was counted as complete");
        if (tx_axis_tvalid)
            $fatal(1, "Generator did not stop after VIO disable");
        @(negedge clk);
        enable = 1'b1;
        capture_frame();
        verify_frame(200, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                     DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
        @(negedge clk);
        enable = 1'b0;

        reset_dut();
        @(negedge clk);
        payload_length = 16'd200;
        gap_cycles = 32'd0;
        enable = 1'b1;
        fork
            begin
                wait (tx_axis_tvalid);
                @(posedge clk);
                @(negedge clk);
                counter_reset = 1'b1;
            end
            begin
                capture_frame();
                verify_frame(200, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                             DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
            end
        join
        #1;
        if (packet_count !== 32'd0)
            $fatal(1, "Counter reset did not clear at the frame boundary");
        repeat (2) begin
            @(posedge clk);
            #1;
            if (tx_axis_tvalid)
                $fatal(1, "Generator ran while counter reset was asserted");
        end
        @(negedge clk);
        counter_reset = 1'b0;
        capture_frame();
        verify_frame(200, 32'd0, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                     DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
        @(negedge clk);
        reset = 1'b1;

        reset_dut();
        @(negedge clk);
        force dut.packet_count = 32'hFFFF_FFFF;
        #1 release dut.packet_count;
        payload_length = 16'd24;
        gap_cycles = 32'd8;
        enable = 1'b1;
        capture_frame();
        verify_frame(24, 32'hFFFF_FFFF, DEFAULT_DESTINATION_MAC, LOCAL_IP,
                     DEFAULT_DESTINATION_IP, 16'd5001, 16'd5001);
        #1;
        if (packet_count !== 32'd0)
            $fatal(1, "Packet counter did not wrap to zero");

        $display("cmac_usplus_0_udp_benchmark_tb PASS");
        $finish;
    end

endmodule
