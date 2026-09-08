`timescale 1ns/1ps

module cmac_usplus_0_ping_responder_tb;

    localparam [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] LOCAL_IP  = 32'hC0A8_650B;
    localparam [63:0] KEEP_60   = 64'h0FFF_FFFF_FFFF_FFFF;
    localparam [63:0] KEEP_38   = 64'h0000_003F_FFFF_FFFF;
    localparam [63:0] KEEP_34   = 64'h0000_0003_FFFF_FFFF;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [31:0] local_ip = LOCAL_IP;
    reg rx_axis_tvalid = 1'b0;
    reg [511:0] rx_axis_tdata = 512'd0;
    reg rx_axis_tlast = 1'b0;
    reg [63:0] rx_axis_tkeep = 64'd0;
    reg rx_axis_tuser = 1'b0;
    reg tx_axis_tready = 1'b0;
    wire tx_axis_tvalid;
    wire [511:0] tx_axis_tdata;
    wire tx_axis_tlast;
    wire [63:0] tx_axis_tkeep;
    wire tx_axis_tuser;
    wire arp_sender_update;
    wire [47:0] arp_sender_mac;
    wire [31:0] arp_sender_ip;

    reg [511:0] arp_request;
    reg [511:0] unrelated_arp_request;
    reg [511:0] icmp_request_0;
    reg [511:0] icmp_request_1;
    reg [511:0] stalled_reply;
    integer i;

    cmac_usplus_0_ping_reply_engine #(
        .LOCAL_MAC(LOCAL_MAC)
    ) dut (
        .clk           (clk),
        .reset         (reset),
        .local_ip      (local_ip),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tdata (rx_axis_tdata),
        .rx_axis_tlast (rx_axis_tlast),
        .rx_axis_tkeep (rx_axis_tkeep),
        .rx_axis_tuser (rx_axis_tuser),
        .arp_sender_update(arp_sender_update),
        .arp_sender_mac   (arp_sender_mac),
        .arp_sender_ip    (arp_sender_ip),
        .tx_axis_tready(tx_axis_tready),
        .tx_axis_tvalid(tx_axis_tvalid),
        .tx_axis_tdata (tx_axis_tdata),
        .tx_axis_tlast (tx_axis_tlast),
        .tx_axis_tkeep (tx_axis_tkeep),
        .tx_axis_tuser (tx_axis_tuser)
    );

    always #5 clk = ~clk;

    task put_byte;
        inout [511:0] data;
        input integer index;
        input [7:0] value;
        begin
            data[index*8 +: 8] = value;
        end
    endtask

    function [7:0] get_byte;
        input [511:0] data;
        input integer index;
        begin
            get_byte = data[index*8 +: 8];
        end
    endfunction

    task expect_byte;
        input [511:0] data;
        input integer index;
        input [7:0] expected;
        begin
            if (get_byte(data, index) !== expected) begin
                $display("byte %0d: expected %02x, got %02x", index, expected, get_byte(data, index));
                $fatal;
            end
        end
    endtask

    task expect_bit;
        input actual;
        input expected;
        begin
            if (actual !== expected) begin
                $display("bit: expected %b, got %b", expected, actual);
                $fatal;
            end
        end
    endtask

    initial begin
        arp_request = 512'd0;
        for (i = 0; i < 6; i = i + 1)
            put_byte(arp_request, i, 8'hFF);
        put_byte(arp_request, 6, 8'h10);
        put_byte(arp_request, 7, 8'h11);
        put_byte(arp_request, 8, 8'h12);
        put_byte(arp_request, 9, 8'h13);
        put_byte(arp_request, 10, 8'h14);
        put_byte(arp_request, 11, 8'h15);
        put_byte(arp_request, 12, 8'h08);
        put_byte(arp_request, 13, 8'h06);
        put_byte(arp_request, 14, 8'h00);
        put_byte(arp_request, 15, 8'h01);
        put_byte(arp_request, 16, 8'h08);
        put_byte(arp_request, 17, 8'h00);
        put_byte(arp_request, 18, 8'h06);
        put_byte(arp_request, 19, 8'h04);
        put_byte(arp_request, 20, 8'h00);
        put_byte(arp_request, 21, 8'h01);
        put_byte(arp_request, 22, 8'h10);
        put_byte(arp_request, 23, 8'h11);
        put_byte(arp_request, 24, 8'h12);
        put_byte(arp_request, 25, 8'h13);
        put_byte(arp_request, 26, 8'h14);
        put_byte(arp_request, 27, 8'h15);
        put_byte(arp_request, 28, 8'hC0);
        put_byte(arp_request, 29, 8'hA8);
        put_byte(arp_request, 30, 8'h65);
        put_byte(arp_request, 31, 8'h14);
        put_byte(arp_request, 38, 8'hC0);
        put_byte(arp_request, 39, 8'hA8);
        put_byte(arp_request, 40, 8'h65);
        put_byte(arp_request, 41, 8'h0B);

        unrelated_arp_request = arp_request;
        put_byte(unrelated_arp_request, 41, 8'h0C);

        // CMAC AXI4-Stream maps packet byte 0 to tdata[7:0].
        if (arp_request[7:0] !== 8'hFF ||
            arp_request[95:88] !== 8'h15 ||
            arp_request[335:328] !== 8'h0B) $fatal;

        icmp_request_0 = 512'd0;
        put_byte(icmp_request_0, 0, 8'h02);
        put_byte(icmp_request_0, 5, 8'h01);
        put_byte(icmp_request_0, 6, 8'h20);
        put_byte(icmp_request_0, 7, 8'h21);
        put_byte(icmp_request_0, 8, 8'h22);
        put_byte(icmp_request_0, 9, 8'h23);
        put_byte(icmp_request_0, 10, 8'h24);
        put_byte(icmp_request_0, 11, 8'h25);
        put_byte(icmp_request_0, 12, 8'h08);
        put_byte(icmp_request_0, 13, 8'h00);
        put_byte(icmp_request_0, 14, 8'h45);
        put_byte(icmp_request_0, 16, 8'h00);
        put_byte(icmp_request_0, 17, 8'h54);
        put_byte(icmp_request_0, 18, 8'h12);
        put_byte(icmp_request_0, 19, 8'h34);
        put_byte(icmp_request_0, 20, 8'h40);
        put_byte(icmp_request_0, 22, 8'h40);
        put_byte(icmp_request_0, 23, 8'h01);
        put_byte(icmp_request_0, 24, 8'hAB);
        put_byte(icmp_request_0, 25, 8'hCD);
        put_byte(icmp_request_0, 26, 8'hC0);
        put_byte(icmp_request_0, 27, 8'hA8);
        put_byte(icmp_request_0, 28, 8'h65);
        put_byte(icmp_request_0, 29, 8'h14);
        put_byte(icmp_request_0, 30, 8'hC0);
        put_byte(icmp_request_0, 31, 8'hA8);
        put_byte(icmp_request_0, 32, 8'h65);
        put_byte(icmp_request_0, 33, 8'h0B);
        put_byte(icmp_request_0, 34, 8'h08);
        put_byte(icmp_request_0, 36, 8'h12);
        put_byte(icmp_request_0, 37, 8'h34);
        put_byte(icmp_request_0, 38, 8'h00);
        put_byte(icmp_request_0, 39, 8'h01);
        put_byte(icmp_request_0, 40, 8'h00);
        put_byte(icmp_request_0, 41, 8'h02);
        for (i = 42; i < 64; i = i + 1)
            put_byte(icmp_request_0, i, i[7:0]);

        icmp_request_1 = 512'd0;
        for (i = 0; i < 34; i = i + 1)
            put_byte(icmp_request_1, i, 8'h80 + i[7:0]);

        repeat (3) @(posedge clk);
        reset = 1'b0;

        // A valid ARP packet for another IP must not change the UDP peer.
        @(negedge clk);
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = unrelated_arp_request;
        rx_axis_tkeep = KEEP_60;
        rx_axis_tlast = 1'b1;
        @(posedge clk);
        #1;
        if (arp_sender_update) begin
            $display("ARP for another IP updated the sender fields");
            $fatal;
        end
        @(negedge clk);
        rx_axis_tvalid = 1'b0;
        rx_axis_tlast = 1'b0;
        rx_axis_tkeep = 64'd0;
        repeat (2) @(posedge clk);
        if (tx_axis_tvalid) begin
            $display("responder accepted an ARP request for another IP");
            $fatal;
        end

        @(negedge clk);
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = arp_request;
        rx_axis_tkeep = KEEP_60;
        rx_axis_tlast = 1'b1;
        @(posedge clk);
        #1;
        if (!arp_sender_update || arp_sender_mac !== 48'h10_11_12_13_14_15 ||
            arp_sender_ip !== 32'hC0A8_6514) begin
            $display("ARP sender fields were not decoded");
            $fatal;
        end
        @(negedge clk);
        rx_axis_tvalid = 1'b0;
        rx_axis_tlast = 1'b0;
        rx_axis_tkeep = 64'd0;
        wait (tx_axis_tvalid);
        #1;
        stalled_reply = tx_axis_tdata;
        expect_bit(tx_axis_tlast, 1'b1);
        expect_bit(tx_axis_tuser, 1'b0);
        if (tx_axis_tkeep !== KEEP_60) $fatal;
        expect_byte(tx_axis_tdata, 0, 8'h10);
        expect_byte(tx_axis_tdata, 5, 8'h15);
        expect_byte(tx_axis_tdata, 6, 8'h02);
        expect_byte(tx_axis_tdata, 11, 8'h01);
        expect_byte(tx_axis_tdata, 20, 8'h00);
        expect_byte(tx_axis_tdata, 21, 8'h02);
        expect_byte(tx_axis_tdata, 22, 8'h02);
        expect_byte(tx_axis_tdata, 27, 8'h01);
        expect_byte(tx_axis_tdata, 28, 8'hC0);
        expect_byte(tx_axis_tdata, 30, 8'h65);
        expect_byte(tx_axis_tdata, 31, 8'h0B);
        expect_byte(tx_axis_tdata, 32, 8'h10);
        expect_byte(tx_axis_tdata, 37, 8'h15);
        expect_byte(tx_axis_tdata, 38, 8'hC0);
        expect_byte(tx_axis_tdata, 40, 8'h65);
        expect_byte(tx_axis_tdata, 41, 8'h14);
        @(negedge clk);
        local_ip = 32'h0A00_0001;
        @(posedge clk);
        #1;
        if (!tx_axis_tvalid || tx_axis_tdata !== stalled_reply) begin
            $display("ARP reply changed while stalled after local_ip update");
            $fatal;
        end
        // CMAC RX has no tready. A frame arriving while TX is held must be
        // discarded through tlast, rather than treating its second beat as a
        // new packet. The tail is deliberately shaped as a valid ARP request.
        @(negedge clk);
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = 512'd0;
        rx_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
        rx_axis_tlast = 1'b0;
        tx_axis_tready = 1'b1;
        @(negedge clk);
        tx_axis_tready = 1'b0;
        rx_axis_tdata = arp_request;
        rx_axis_tkeep = KEEP_60;
        rx_axis_tlast = 1'b1;
        @(negedge clk);
        rx_axis_tvalid = 1'b0;
        rx_axis_tlast = 1'b0;
        rx_axis_tkeep = 64'd0;
        local_ip = LOCAL_IP;
        repeat (2) @(posedge clk);
        if (tx_axis_tvalid) begin
            $display("responder accepted a tail from a frame discarded during TX");
            $fatal;
        end

        // A truncated ICMP header must not be classified as an echo request.
        // Bytes 38 through 41 contain the echo identifier and sequence fields.
        @(negedge clk);
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = icmp_request_0;
        rx_axis_tkeep = KEEP_38;
        rx_axis_tlast = 1'b1;
        @(negedge clk);
        rx_axis_tvalid = 1'b0;
        rx_axis_tlast = 1'b0;
        rx_axis_tkeep = 64'd0;
        repeat (2) @(posedge clk);
        if (tx_axis_tvalid) begin
            $display("responder accepted a truncated ICMP header");
            $fatal;
        end

        @(negedge clk);
        rx_axis_tvalid = 1'b1;
        rx_axis_tdata = icmp_request_0;
        rx_axis_tkeep = 64'hFFFF_FFFF_FFFF_FFFF;
        rx_axis_tlast = 1'b0;
        @(negedge clk);
        rx_axis_tdata = icmp_request_1;
        rx_axis_tkeep = KEEP_34;
        rx_axis_tlast = 1'b1;
        @(negedge clk);
        rx_axis_tvalid = 1'b0;
        rx_axis_tlast = 1'b0;
        rx_axis_tkeep = 64'd0;
        wait (tx_axis_tvalid);
        #1;
        expect_bit(tx_axis_tlast, 1'b0);
        if (tx_axis_tkeep !== 64'hFFFF_FFFF_FFFF_FFFF) $fatal;
        expect_byte(tx_axis_tdata, 0, 8'h20);
        expect_byte(tx_axis_tdata, 5, 8'h25);
        expect_byte(tx_axis_tdata, 6, 8'h02);
        expect_byte(tx_axis_tdata, 11, 8'h01);
        expect_byte(tx_axis_tdata, 26, 8'hC0);
        expect_byte(tx_axis_tdata, 28, 8'h65);
        expect_byte(tx_axis_tdata, 29, 8'h0B);
        expect_byte(tx_axis_tdata, 30, 8'hC0);
        expect_byte(tx_axis_tdata, 32, 8'h65);
        expect_byte(tx_axis_tdata, 33, 8'h14);
        expect_byte(tx_axis_tdata, 34, 8'h00);
        expect_byte(tx_axis_tdata, 36, 8'h1A);
        expect_byte(tx_axis_tdata, 37, 8'h34);
        @(negedge clk);
        tx_axis_tready = 1'b1;
        @(negedge clk);
        tx_axis_tready = 1'b0;
        #1;
        expect_bit(tx_axis_tvalid, 1'b1);
        expect_bit(tx_axis_tlast, 1'b1);
        if (tx_axis_tkeep !== KEEP_34) $fatal;
        if (tx_axis_tdata !== icmp_request_1) $fatal;
        @(negedge clk);
        tx_axis_tready = 1'b1;
        @(negedge clk);
        tx_axis_tready = 1'b0;

        $display("cmac_usplus_0_ping_responder_tb PASS");
        $finish;
    end

endmodule
