`timescale 1ns/1ps

import cmac_usplus_0_network_types_pkg::*;

module cmac_usplus_0_network_endpoint_tb;

    localparam logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
    localparam logic [31:0] LOCAL_IP = 32'hC0A8_650B;
    localparam logic [47:0] HOST_MAC = 48'h10_7C_61_5D_E2_5B;
    localparam logic [31:0] HOST_IP = 32'hC0A8_6507;
    localparam logic [47:0] ARP_REQUEST_MAC = 48'hA0_B1_C2_D3_E4_F5;
    localparam logic [31:0] ARP_REQUEST_IP = 32'hC0A8_6519;
    localparam logic [47:0] ARP_REPLY_MAC = 48'hB0_C1_D2_E3_F4_A5;
    localparam logic [31:0] ARP_REPLY_IP = 32'hC0A8_651A;
    localparam integer UDP_STREAM_COUNT = 4;

    logic clk = 1'b0;
    logic reset = 1'b1;

    logic rx_axis_tvalid = 1'b0;
    logic [511:0] rx_axis_tdata = 512'd0;
    logic rx_axis_tlast = 1'b0;
    logic [63:0] rx_axis_tkeep = 64'd0;
    logic rx_axis_tuser = 1'b0;

    logic reply_axis_tready;
    logic reply_axis_tvalid;
    logic [511:0] reply_axis_tdata;
    logic reply_axis_tlast;
    logic [63:0] reply_axis_tkeep;
    logic reply_axis_tuser;

    logic [UDP_STREAM_COUNT-1:0] udp_axis_tready;
    logic [UDP_STREAM_COUNT-1:0] udp_axis_tvalid;
    logic [UDP_STREAM_COUNT-1:0][511:0] udp_axis_tdata;
    logic [UDP_STREAM_COUNT-1:0] udp_axis_tlast;
    logic [UDP_STREAM_COUNT-1:0][63:0] udp_axis_tkeep;
    logic [UDP_STREAM_COUNT-1:0] udp_axis_tuser;
    logic [UDP_STREAM_COUNT-1:0][31:0] udp_packet_count;
    logic [UDP_STREAM_COUNT-1:0][39:0] udp_tx_rate_bytes_per_second;
    logic [UDP_STREAM_COUNT-1:0][31:0] udp_tx_local_drop_count;

    logic tx_axis_tready = 1'b1;
    logic tx_axis_tvalid;
    logic [511:0] tx_axis_tdata;
    logic tx_axis_tlast;
    logic [63:0] tx_axis_tkeep;
    logic tx_axis_tuser;

    logic udp_enable = 1'b0;
    logic udp_enable_q;
    logic [UDP_STREAM_COUNT-1:0] udp_stream_mask = {UDP_STREAM_COUNT{1'b1}};
    logic [UDP_STREAM_COUNT-1:0] udp_stream_mask_q;
    logic udp_counter_reset = 1'b0;
    logic [15:0] udp_payload_length = 16'd100;
    logic [31:0] udp_gap_cycles = 32'd0;
    logic [15:0] udp_source_port = 16'd5001;
    logic [15:0] udp_destination_port = 16'd5001;
    logic udp_descriptor_valid;
    udp_frame_descriptor_t udp_descriptor;

    logic arp_sender_update;
    logic arp_sender_update_q;
    logic arp_destination_update_q;
    logic [47:0] arp_sender_mac;
    logic [31:0] arp_sender_ip;
    logic [47:0] arp_sender_mac_q;
    logic [31:0] arp_sender_ip_q;
    logic learned_destination_valid;
    logic [47:0] learned_destination_mac;
    logic [31:0] learned_destination_ip;
    wire [47:0] effective_destination_mac;
    wire [31:0] effective_destination_ip;

    logic [7:0] captured [0:511];
    integer captured_length;
    integer captured_beats;
    integer frame_index;

    cmac_usplus_0_ping_reply_engine #(
        .LOCAL_MAC (LOCAL_MAC)
    ) reply_engine (
        .clk            (clk),
        .reset          (reset),
        .local_ip       (LOCAL_IP),
        .rx_axis_tvalid (rx_axis_tvalid),
        .rx_axis_tdata  (rx_axis_tdata),
        .rx_axis_tlast  (rx_axis_tlast),
        .rx_axis_tkeep  (rx_axis_tkeep),
        .rx_axis_tuser  (rx_axis_tuser),
        .arp_sender_update (arp_sender_update),
        .arp_sender_mac    (arp_sender_mac),
        .arp_sender_ip     (arp_sender_ip),
        .tx_axis_tready (reply_axis_tready),
        .tx_axis_tvalid (reply_axis_tvalid),
        .tx_axis_tdata  (reply_axis_tdata),
        .tx_axis_tlast  (reply_axis_tlast),
        .tx_axis_tkeep  (reply_axis_tkeep),
        .tx_axis_tuser  (reply_axis_tuser)
    );

    // Match the endpoint topology: every flow snapshots the same completed
    // descriptor, then applies only its compile-time UDP destination offset.
    cmac_usplus_0_udp_config_pipeline udp_config_pipeline (
        .clk              (clk),
        .reset            (reset),
        .local_ip         (LOCAL_IP),
        .destination_mac  (effective_destination_mac),
        .destination_ip   (effective_destination_ip),
        .source_port      (udp_source_port),
        .destination_port (udp_destination_port),
        .payload_length   (udp_payload_length),
        .gap_cycles       (udp_gap_cycles),
        .descriptor_valid (udp_descriptor_valid),
        .descriptor       (udp_descriptor)
    );

    genvar udp_benchmark_index;
    generate
        for (udp_benchmark_index = 0;
             udp_benchmark_index < UDP_STREAM_COUNT;
             udp_benchmark_index = udp_benchmark_index + 1) begin : g_udp_benchmark
            localparam logic [15:0] DESTINATION_PORT_OFFSET =
                udp_benchmark_index;

            cmac_usplus_0_udp_benchmark_core #(
                .LOCAL_MAC (LOCAL_MAC),
                .DESTINATION_PORT_OFFSET (DESTINATION_PORT_OFFSET)
            ) udp_benchmark (
                .clk              (clk),
                .reset            (reset),
                .enable           (udp_enable_q &&
                                    udp_stream_mask_q[udp_benchmark_index]),
                .counter_reset    (udp_counter_reset),
                .frame_start_inhibit (arp_sender_update_q ||
                                       arp_destination_update_q),
                .descriptor_valid (udp_descriptor_valid),
                .descriptor       (udp_descriptor),
                .tx_axis_tready   (udp_axis_tready[udp_benchmark_index]),
                .tx_axis_tvalid   (udp_axis_tvalid[udp_benchmark_index]),
                .tx_axis_tdata    (udp_axis_tdata[udp_benchmark_index]),
                .tx_axis_tlast    (udp_axis_tlast[udp_benchmark_index]),
                .tx_axis_tkeep    (udp_axis_tkeep[udp_benchmark_index]),
                .tx_axis_tuser    (udp_axis_tuser[udp_benchmark_index]),
                .packet_count     (udp_packet_count[udp_benchmark_index]),
                .tx_rate_bytes_per_second (udp_tx_rate_bytes_per_second[udp_benchmark_index]),
                .tx_local_drop_count      (udp_tx_local_drop_count[udp_benchmark_index])
            );
        end
    endgenerate

    cmac_usplus_0_tx_packet_arbiter arbiter (
        .clk               (clk),
        .reset             (reset),
        .reply_axis_tready (reply_axis_tready),
        .reply_axis_tvalid (reply_axis_tvalid),
        .reply_axis_tdata  (reply_axis_tdata),
        .reply_axis_tlast  (reply_axis_tlast),
        .reply_axis_tkeep  (reply_axis_tkeep),
        .reply_axis_tuser  (reply_axis_tuser),
        .reply_pending     (rx_axis_tvalid || reply_axis_tvalid),
        .udp_config_inhibit(arp_sender_update_q || arp_destination_update_q),
        .udp_axis_enable   ({UDP_STREAM_COUNT{udp_enable_q}} &
                            udp_stream_mask_q),
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

    // Mirrors the destination-learning mux in cmac_usplus_0_ping_responder.
    always_ff @(posedge clk) begin
        if (reset) begin
            arp_sender_update_q      <= 1'b0;
            arp_destination_update_q <= 1'b0;
            arp_sender_mac_q         <= 48'd0;
            arp_sender_ip_q          <= 32'd0;
            learned_destination_valid <= 1'b0;
            learned_destination_mac   <= 48'd0;
            learned_destination_ip    <= 32'd0;
        end else begin
            arp_sender_update_q <= arp_sender_update;
            arp_destination_update_q <= arp_sender_update_q;
            if (arp_sender_update) begin
                arp_sender_mac_q <= arp_sender_mac;
                arp_sender_ip_q  <= arp_sender_ip;
            end
            if (arp_sender_update_q) begin
                learned_destination_valid <= 1'b1;
                learned_destination_mac   <= arp_sender_mac_q;
                learned_destination_ip    <= arp_sender_ip_q;
            end
        end
    end

    assign effective_destination_mac = learned_destination_valid ?
                                       learned_destination_mac : HOST_MAC;
    assign effective_destination_ip = learned_destination_valid ?
                                      learned_destination_ip : HOST_IP;

    always_ff @(posedge clk) begin
        if (reset) begin
            udp_enable_q <= 1'b0;
            udp_stream_mask_q <= '0;
        end else begin
            udp_enable_q <= udp_enable;
            udp_stream_mask_q <= udp_stream_mask;
        end
    end

    function automatic logic [7:0] stream_byte(
        input logic [511:0] data,
        input integer index
    );
        stream_byte = data[index * 8 +: 8];
    endfunction

    function automatic logic [15:0] stream_be16(
        input logic [511:0] data,
        input integer index
    );
        stream_be16 = {stream_byte(data, index), stream_byte(data, index + 1)};
    endfunction

    function automatic logic [15:0] captured_be16(input integer index);
        captured_be16 = {captured[index], captured[index + 1]};
    endfunction

    function automatic logic [31:0] captured_be32(input integer index);
        captured_be32 = {
            captured[index], captured[index + 1],
            captured[index + 2], captured[index + 3]
        };
    endfunction

    function automatic logic [47:0] captured_mac(input integer index);
        captured_mac = {
            captured[index], captured[index + 1], captured[index + 2],
            captured[index + 3], captured[index + 4], captured[index + 5]
        };
    endfunction

    task automatic put_byte(
        inout logic [511:0] data,
        input integer index,
        input logic [7:0] value
    );
        data[index * 8 +: 8] = value;
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            reset = 1'b1;
            udp_enable = 1'b0;
            udp_stream_mask = {UDP_STREAM_COUNT{1'b1}};
            udp_counter_reset = 1'b0;
            udp_payload_length = 16'd100;
            udp_gap_cycles = 32'd0;
            udp_source_port = 16'd5001;
            udp_destination_port = 16'd5001;
            rx_axis_tvalid = 1'b0;
            rx_axis_tdata = 512'd0;
            rx_axis_tlast = 1'b0;
            rx_axis_tkeep = 64'd0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
            udp_enable = 1'b1;
        end
    endtask

    task automatic capture_frame;
        integer byte_index;
        logic done;
        begin
            captured_length = 0;
            captured_beats = 0;
            done = 1'b0;
            while (!done) begin
                @(posedge clk);
                if (tx_axis_tvalid && tx_axis_tready) begin
                    captured_beats = captured_beats + 1;
                    if (tx_axis_tuser)
                        $fatal(1, "Arbitrated stream asserted tuser");
                    for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1) begin
                        if (tx_axis_tkeep[byte_index]) begin
                            captured[captured_length] =
                                tx_axis_tdata[byte_index * 8 +: 8];
                            captured_length = captured_length + 1;
                        end
                    end
                    done = tx_axis_tlast;
                end
            end
        end
    endtask

    task automatic capture_frame_with_backpressure;
        logic done;
        logic ready_toggle;
        begin
            done = 1'b0;
            ready_toggle = 1'b0;
            @(negedge clk);
            tx_axis_tready = 1'b0;
            fork
                begin
                    while (!done) begin
                        @(negedge clk);
                        ready_toggle = ~ready_toggle;
                        tx_axis_tready = ready_toggle;
                    end
                end
                begin
                    capture_frame();
                    done = 1'b1;
            end
            join
            @(negedge clk);
            tx_axis_tready = 1'b0;
        end
    endtask

    task automatic verify_udp(
        input logic [31:0] expected_sequence,
        input logic [47:0] expected_destination_mac,
        input logic [31:0] expected_destination_ip,
        input logic [15:0] expected_destination_port
    );
        begin
            if (captured_length != 142 || captured_beats != 3)
                $fatal(1, "UDP frame was truncated or interleaved");
            if (captured_be16(12) !== 16'h0800 || captured[23] !== 8'h11)
                $fatal(1, "Expected UDP frame");
            if (captured_mac(0) !== expected_destination_mac ||
                captured_be32(30) !== expected_destination_ip)
                $fatal(1, "UDP destination was not updated from ARP");
            if (captured_be32(42) !== 32'h5246_534F)
                $fatal(1, "Unexpected UDP benchmark magic");
            if (captured_be32(46) !== expected_sequence)
                $fatal(1, "Unexpected UDP sequence number");
            if (captured_be16(34) !== 16'd5001 ||
                captured_be16(36) !== expected_destination_port)
                $fatal(1, "Unexpected UDP port selection");
        end
    endtask

    task automatic wait_for_first_udp_handshake;
        begin
            while (1'b1) begin
                @(posedge clk);
                if (tx_axis_tvalid && tx_axis_tready &&
                    (stream_be16(tx_axis_tdata, 12) == 16'h0800) &&
                    (stream_byte(tx_axis_tdata, 23) == 8'h11))
                    return;
            end
        end
    endtask

    task automatic send_arp_during_udp(
        input logic [15:0] opcode,
        input logic [47:0] sender_mac,
        input logic [31:0] sender_ip
    );
        logic [511:0] request;
        integer index;
        begin
            request = 512'd0;
            if (opcode == 16'h0001) begin
                for (index = 0; index < 6; index = index + 1)
                    put_byte(request, index, 8'hFF);
            end else begin
                put_byte(request, 0, LOCAL_MAC[47:40]);
                put_byte(request, 1, LOCAL_MAC[39:32]);
                put_byte(request, 2, LOCAL_MAC[31:24]);
                put_byte(request, 3, LOCAL_MAC[23:16]);
                put_byte(request, 4, LOCAL_MAC[15:8]);
                put_byte(request, 5, LOCAL_MAC[7:0]);
            end
            put_byte(request, 6, sender_mac[47:40]);
            put_byte(request, 7, sender_mac[39:32]);
            put_byte(request, 8, sender_mac[31:24]);
            put_byte(request, 9, sender_mac[23:16]);
            put_byte(request, 10, sender_mac[15:8]);
            put_byte(request, 11, sender_mac[7:0]);
            put_byte(request, 12, 8'h08);
            put_byte(request, 13, 8'h06);
            put_byte(request, 14, 8'h00);
            put_byte(request, 15, 8'h01);
            put_byte(request, 16, 8'h08);
            put_byte(request, 17, 8'h00);
            put_byte(request, 18, 8'h06);
            put_byte(request, 19, 8'h04);
            put_byte(request, 20, opcode[15:8]);
            put_byte(request, 21, opcode[7:0]);
            put_byte(request, 22, sender_mac[47:40]);
            put_byte(request, 23, sender_mac[39:32]);
            put_byte(request, 24, sender_mac[31:24]);
            put_byte(request, 25, sender_mac[23:16]);
            put_byte(request, 26, sender_mac[15:8]);
            put_byte(request, 27, sender_mac[7:0]);
            put_byte(request, 28, sender_ip[31:24]);
            put_byte(request, 29, sender_ip[23:16]);
            put_byte(request, 30, sender_ip[15:8]);
            put_byte(request, 31, sender_ip[7:0]);
            if (opcode == 16'h0002) begin
                put_byte(request, 32, LOCAL_MAC[47:40]);
                put_byte(request, 33, LOCAL_MAC[39:32]);
                put_byte(request, 34, LOCAL_MAC[31:24]);
                put_byte(request, 35, LOCAL_MAC[23:16]);
                put_byte(request, 36, LOCAL_MAC[15:8]);
                put_byte(request, 37, LOCAL_MAC[7:0]);
            end
            put_byte(request, 38, LOCAL_IP[31:24]);
            put_byte(request, 39, LOCAL_IP[23:16]);
            put_byte(request, 40, LOCAL_IP[15:8]);
            put_byte(request, 41, LOCAL_IP[7:0]);

            wait_for_first_udp_handshake();
            @(negedge clk);
            rx_axis_tvalid = 1'b1;
            rx_axis_tdata = request;
            rx_axis_tkeep = 64'h0FFF_FFFF_FFFF_FFFF;
            rx_axis_tlast = 1'b1;
            @(negedge clk);
            rx_axis_tvalid = 1'b0;
            rx_axis_tlast = 1'b0;
            rx_axis_tkeep = 64'd0;
        end
    endtask

    task automatic send_icmp_during_udp;
        logic [511:0] request_0;
        logic [511:0] request_1;
        integer index;
        begin
            request_0 = 512'd0;
            request_1 = 512'd0;
            put_byte(request_0, 0, LOCAL_MAC[47:40]);
            put_byte(request_0, 1, LOCAL_MAC[39:32]);
            put_byte(request_0, 2, LOCAL_MAC[31:24]);
            put_byte(request_0, 3, LOCAL_MAC[23:16]);
            put_byte(request_0, 4, LOCAL_MAC[15:8]);
            put_byte(request_0, 5, LOCAL_MAC[7:0]);
            put_byte(request_0, 6, HOST_MAC[47:40]);
            put_byte(request_0, 7, HOST_MAC[39:32]);
            put_byte(request_0, 8, HOST_MAC[31:24]);
            put_byte(request_0, 9, HOST_MAC[23:16]);
            put_byte(request_0, 10, HOST_MAC[15:8]);
            put_byte(request_0, 11, HOST_MAC[7:0]);
            put_byte(request_0, 12, 8'h08);
            put_byte(request_0, 13, 8'h00);
            put_byte(request_0, 14, 8'h45);
            put_byte(request_0, 16, 8'h00);
            put_byte(request_0, 17, 8'h46);
            put_byte(request_0, 20, 8'h40);
            put_byte(request_0, 22, 8'h40);
            put_byte(request_0, 23, 8'h01);
            put_byte(request_0, 26, HOST_IP[31:24]);
            put_byte(request_0, 27, HOST_IP[23:16]);
            put_byte(request_0, 28, HOST_IP[15:8]);
            put_byte(request_0, 29, HOST_IP[7:0]);
            put_byte(request_0, 30, LOCAL_IP[31:24]);
            put_byte(request_0, 31, LOCAL_IP[23:16]);
            put_byte(request_0, 32, LOCAL_IP[15:8]);
            put_byte(request_0, 33, LOCAL_IP[7:0]);
            put_byte(request_0, 34, 8'h08);
            put_byte(request_0, 36, 8'h12);
            put_byte(request_0, 37, 8'h34);
            for (index = 38; index < 64; index = index + 1)
                put_byte(request_0, index, index[7:0]);
            for (index = 0; index < 20; index = index + 1)
                put_byte(request_1, index, 8'h80 + index[7:0]);

            wait_for_first_udp_handshake();
            @(negedge clk);
            rx_axis_tvalid = 1'b1;
            rx_axis_tdata = request_0;
            rx_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
            rx_axis_tlast = 1'b0;
            @(negedge clk);
            rx_axis_tdata = request_1;
            rx_axis_tkeep = 64'h0000_0000_000F_FFFF;
            rx_axis_tlast = 1'b1;
            @(negedge clk);
            rx_axis_tvalid = 1'b0;
            rx_axis_tlast = 1'b0;
            rx_axis_tkeep = 64'd0;
        end
    endtask

    initial begin
        // A stable four-stream configuration must produce four complete,
        // independently numbered UDP flows on consecutive destination ports.
        reset_dut();
        capture_frame_with_backpressure();
        verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5001);
        capture_frame_with_backpressure();
        verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5002);
        @(negedge clk);
        tx_axis_tready = 1'b1;
        for (frame_index = 0; frame_index < 2;
             frame_index = frame_index + 1) begin
            capture_frame();
            verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5003 + frame_index);
        end
        for (frame_index = 0; frame_index < UDP_STREAM_COUNT;
             frame_index = frame_index + 1) begin
            capture_frame();
            verify_udp(32'd1, HOST_MAC, HOST_IP, 16'd5001 + frame_index);
        end
        #1;
        for (frame_index = 0; frame_index < UDP_STREAM_COUNT;
             frame_index = frame_index + 1) begin
            if (udp_packet_count[frame_index] !== 32'd2)
                $fatal(1, "UDP streams did not maintain independent counters");
        end

        // Each mask bit controls only its matching UDP stream. A stable mask
        // must leave the enabled streams round-robinning without emitting the
        // disabled destination ports.
        reset_dut();
        @(negedge clk);
        udp_stream_mask = 4'b0101;
        repeat (3) @(posedge clk);
        capture_frame();
        verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5001);
        capture_frame();
        verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5003);
        capture_frame();
        verify_udp(32'd1, HOST_MAC, HOST_IP, 16'd5001);
        capture_frame();
        verify_udp(32'd1, HOST_MAC, HOST_IP, 16'd5003);
        #1;
        if (udp_packet_count[0] !== 32'd2 ||
            udp_packet_count[1] !== 32'd0 ||
            udp_packet_count[2] !== 32'd2 ||
            udp_packet_count[3] !== 32'd0)
            $fatal(1, "UDP stream mask did not gate each stream independently");

        reset_dut();
        fork
            send_arp_during_udp(16'h0001, ARP_REQUEST_MAC, ARP_REQUEST_IP);
            begin
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5001);
                capture_frame();
                if (captured_length != 60 || captured_beats != 1 ||
                    captured_be16(12) !== 16'h0806 ||
                    captured_be16(20) !== 16'h0002)
                    $fatal(1, "ARP reply did not win the next packet boundary");
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5002);
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5003);
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5004);
                capture_frame();
                // The frame that was admitted in the ARP detection cycle
                // keeps the prior destination; later frame starts use ARP.
                verify_udp(32'd1, HOST_MAC, HOST_IP, 16'd5001);
                capture_frame();
                verify_udp(32'd1, ARP_REQUEST_MAC, ARP_REQUEST_IP, 16'd5002);
            end
        join

        reset_dut();
        fork
            send_arp_during_udp(16'h0002, ARP_REPLY_MAC, ARP_REPLY_IP);
            begin
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5001);
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5002);
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5003);
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5004);
                capture_frame();
                verify_udp(32'd1, HOST_MAC, HOST_IP, 16'd5001);
                capture_frame();
                verify_udp(32'd1, ARP_REPLY_MAC, ARP_REPLY_IP, 16'd5002);
            end
        join

        reset_dut();
        fork
            send_icmp_during_udp();
            begin
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5001);
                capture_frame();
                if (captured_length != 84 || captured_beats != 2 ||
                    captured_be16(12) !== 16'h0800 || captured[23] !== 8'h01 ||
                    captured[34] !== 8'h00)
                    $fatal(1, "ICMP reply did not win the next packet boundary");
                capture_frame();
                verify_udp(32'd0, HOST_MAC, HOST_IP, 16'd5002);
            end
        join

        $display("cmac_usplus_0_network_endpoint_tb PASS");
        $finish;
    end

endmodule
