`timescale 1ps / 1ps

// Minimal untagged Ethernet ARP and IPv4 ICMP echo reply engine.
module cmac_usplus_0_ping_reply_engine #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01
) (
  input logic        clk,
  input logic        reset,
  input logic [31:0] local_ip,

  input logic         rx_axis_tvalid,
  input logic [511:0] rx_axis_tdata,
  input logic         rx_axis_tlast,
  input logic [ 63:0] rx_axis_tkeep,
  input logic         rx_axis_tuser,

  output wire        arp_sender_update,
  output wire [47:0] arp_sender_mac,
  output wire [31:0] arp_sender_ip,

  input  logic         tx_axis_tready,
  output wire          tx_axis_tvalid,
  output wire  [511:0] tx_axis_tdata,
  output wire          tx_axis_tlast,
  output wire  [ 63:0] tx_axis_tkeep,
  output wire          tx_axis_tuser
);

  localparam integer MAX_FRAME_WORDS = 24;  // 1536 bytes, enough for a 1500-byte MTU frame
  localparam logic [63:0] KEEP_60 = 64'h0FFF_FFFF_FFFF_FFFF;

  typedef enum logic [1:0] {
    ST_IDLE = 2'd0,
    ST_RX   = 2'd1,
    ST_TX   = 2'd2,
    ST_DROP = 2'd3
  } state_t;

  logic   [511:0] frame_data          [MAX_FRAME_WORDS];
  logic   [ 63:0] frame_keep          [MAX_FRAME_WORDS];
  state_t         state;
  logic   [  5:0] rx_word_index;
  logic   [  5:0] frame_word_count;
  logic   [  5:0] tx_word_index;
  logic           frame_is_arp;
  logic           frame_is_icmp;
  logic           frame_bad;
  logic           response_is_arp;
  logic           rx_drop_in_progress;
  logic   [ 31:0] frame_local_ip;
  logic   [ 31:0] response_local_ip;

  function automatic logic [7:0] get_byte(input logic [511:0] data, input int unsigned byte_index);
    get_byte = data[byte_index*8+:8];
  endfunction

  function automatic logic [15:0] get_be16(input logic [511:0] data, input int unsigned byte_index);
    get_be16 = {get_byte(data, byte_index), get_byte(data, byte_index + 1)};
  endfunction

  function automatic logic [31:0] get_be32(input logic [511:0] data, input int unsigned byte_index);
    get_be32 = {
      get_byte(data, byte_index),
      get_byte(data, byte_index + 1),
      get_byte(data, byte_index + 2),
      get_byte(data, byte_index + 3)
    };
  endfunction

  function automatic logic [47:0] get_mac(input logic [511:0] data, input int unsigned byte_index);
    get_mac = {
      get_byte(data, byte_index),
      get_byte(data, byte_index + 1),
      get_byte(data, byte_index + 2),
      get_byte(data, byte_index + 3),
      get_byte(data, byte_index + 4),
      get_byte(data, byte_index + 5)
    };
  endfunction

  function automatic logic [511:0] set_byte(
    input logic [511:0] data,
    input int unsigned byte_index,
    input logic [7:0] value
  );
    logic [511:0] updated;
    begin
      updated                  = data;
      updated[byte_index*8+:8] = value;
      set_byte                 = updated;
    end
  endfunction

  function automatic logic [511:0] set_be16(
    input logic [511:0] data,
    input int unsigned byte_index,
    input logic [15:0] value
  );
    logic [511:0] updated;
    begin
      updated  = set_byte(data, byte_index, value[15:8]);
      updated  = set_byte(updated, byte_index + 1, value[7:0]);
      set_be16 = updated;
    end
  endfunction

  function automatic logic [511:0] set_be32(
    input logic [511:0] data,
    input int unsigned byte_index,
    input logic [31:0] value
  );
    logic [511:0] updated;
    begin
      updated  = set_byte(data, byte_index, value[31:24]);
      updated  = set_byte(updated, byte_index + 1, value[23:16]);
      updated  = set_byte(updated, byte_index + 2, value[15:8]);
      updated  = set_byte(updated, byte_index + 3, value[7:0]);
      set_be32 = updated;
    end
  endfunction

  function automatic logic [511:0] set_mac(
    input logic [511:0] data,
    input int unsigned byte_index,
    input logic [47:0] value
  );
    logic [511:0] updated;
    begin
      updated = set_byte(data, byte_index, value[47:40]);
      updated = set_byte(updated, byte_index + 1, value[39:32]);
      updated = set_byte(updated, byte_index + 2, value[31:24]);
      updated = set_byte(updated, byte_index + 3, value[23:16]);
      updated = set_byte(updated, byte_index + 4, value[15:8]);
      updated = set_byte(updated, byte_index + 5, value[7:0]);
      set_mac = updated;
    end
  endfunction

  function automatic logic is_arp_request(input logic [511:0] data, input logic [63:0] keep);
    begin
      is_arp_request = keep[41] &&
        ((get_mac(data, 0) == 48'hFF_FF_FF_FF_FF_FF) ||
         (get_mac(data, 0) == LOCAL_MAC)) &&
        (get_be16(data, 12) == 16'h0806) &&
        (get_be16(data, 14) == 16'h0001) &&
        (get_be16(data, 16) == 16'h0800) &&
        (get_byte(data, 18) == 8'h06) &&
        (get_byte(data, 19) == 8'h04) &&
        (get_be16(data, 20) == 16'h0001) &&
        (get_be32(data, 38) == local_ip);
    end
  endfunction

  // ARP sender fields are usable as a UDP destination only when this is a
  // complete, untagged ARP request or reply addressed to the local IP.
  function automatic logic is_arp_sender_for_local(
    input logic [511:0] data,
    input logic [63:0] keep
  );
    begin
      is_arp_sender_for_local = (&keep[41:0]) &&
        ((get_mac(data, 0) == 48'hFF_FF_FF_FF_FF_FF) ||
         (get_mac(data, 0) == LOCAL_MAC)) &&
        (get_mac(data, 6) == get_mac(data, 22)) &&
        (get_be16(data, 12) == 16'h0806) &&
        (get_be16(data, 14) == 16'h0001) &&
        (get_be16(data, 16) == 16'h0800) &&
        (get_byte(data, 18) == 8'h06) &&
        (get_byte(data, 19) == 8'h04) &&
        ((get_be16(data, 20) == 16'h0001) ||
         (get_be16(data, 20) == 16'h0002)) &&
        (get_be32(data, 28) != 32'd0) &&
        (get_be32(data, 38) == local_ip);
    end
  endfunction

  function automatic logic is_icmp_echo_request(input logic [511:0] data, input logic [63:0] keep);
    begin
      is_icmp_echo_request = keep[41] &&
        (get_mac(data, 0) == LOCAL_MAC) &&
        (get_be16(data, 12) == 16'h0800) &&
        (get_byte(data, 14) == 8'h45) &&
        (get_be16(data, 16) >= 16'd28) &&
        ((get_be16(data, 20) & 16'h3FFF) == 16'd0) &&
        (get_byte(data, 23) == 8'h01) &&
        (get_be32(data, 30) == local_ip) &&
        (get_be16(data, 34) == 16'h0800);
    end
  endfunction

  function automatic logic [15:0] icmp_reply_checksum(input logic [15:0] request_checksum);
    logic [16:0] sum;
    begin
      // RFC 1624 incremental update for ICMP type 8 -> 0.
      sum                 = {1'b0, ~request_checksum} + 17'h0F7FF;
      sum                 = {1'b0, sum[15:0]} + sum[16];
      icmp_reply_checksum = ~sum[15:0];
    end
  endfunction

  function automatic logic [511:0] make_arp_reply(input logic [511:0] request);
    logic [511:0] reply;
    begin
      reply          = 512'd0;
      reply          = set_mac(reply, 0, get_mac(request, 6));
      reply          = set_mac(reply, 6, LOCAL_MAC);
      reply          = set_be16(reply, 12, 16'h0806);
      reply          = set_be16(reply, 14, 16'h0001);
      reply          = set_be16(reply, 16, 16'h0800);
      reply          = set_byte(reply, 18, 8'h06);
      reply          = set_byte(reply, 19, 8'h04);
      reply          = set_be16(reply, 20, 16'h0002);
      reply          = set_mac(reply, 22, LOCAL_MAC);
      reply          = set_be32(reply, 28, response_local_ip);
      reply          = set_mac(reply, 32, get_mac(request, 6));
      reply          = set_be32(reply, 38, get_be32(request, 28));
      make_arp_reply = reply;
    end
  endfunction

  function automatic logic [511:0] make_icmp_reply(input logic [511:0] request);
    logic [511:0] reply;
    begin
      reply           = request;
      reply           = set_mac(reply, 0, get_mac(request, 6));
      reply           = set_mac(reply, 6, LOCAL_MAC);
      // Swapping IPv4 source/destination leaves the IPv4 checksum unchanged.
      reply           = set_be32(reply, 26, get_be32(request, 30));
      reply           = set_be32(reply, 30, get_be32(request, 26));
      reply           = set_byte(reply, 34, 8'h00);
      reply           = set_be16(reply, 36, icmp_reply_checksum(get_be16(request, 36)));
      make_icmp_reply = reply;
    end
  endfunction

  // An Ethernet ARP frame is no longer than one 64-byte CMAC beat. Waiting
  // for TLAST ensures a malformed multi-beat frame cannot change UDP state.
  assign arp_sender_update = rx_axis_tvalid && rx_axis_tlast &&
    !rx_axis_tuser && is_arp_sender_for_local(rx_axis_tdata, rx_axis_tkeep);
  assign arp_sender_mac    = get_mac(rx_axis_tdata, 22);
  assign arp_sender_ip     = get_be32(rx_axis_tdata, 28);

  assign tx_axis_tvalid    = (state == ST_TX);
  assign tx_axis_tuser     = 1'b0;
  assign tx_axis_tdata = (state != ST_TX) ? 512'd0 :
    response_is_arp ? make_arp_reply(frame_data[0]) :
    (tx_word_index == 6'd0) ? make_icmp_reply(frame_data[0]) :
    frame_data[tx_word_index];
  assign tx_axis_tkeep = (state != ST_TX) ? 64'd0 :
    response_is_arp ? KEEP_60 : frame_keep[tx_word_index];
  assign tx_axis_tlast = (state != ST_TX) ? 1'b0 :
    response_is_arp ? 1'b1 : (tx_word_index == (frame_word_count - 1'b1));

  always_ff @(posedge clk) begin
    if (reset) begin
      state               <= ST_IDLE;
      rx_word_index       <= 6'd0;
      frame_word_count    <= 6'd0;
      tx_word_index       <= 6'd0;
      frame_is_arp        <= 1'b0;
      frame_is_icmp       <= 1'b0;
      frame_bad           <= 1'b0;
      response_is_arp     <= 1'b0;
      rx_drop_in_progress <= 1'b0;
      frame_local_ip      <= 32'd0;
      response_local_ip   <= 32'd0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (rx_axis_tvalid) begin
            frame_data[0]  <= rx_axis_tdata;
            frame_keep[0]  <= rx_axis_tkeep;
            frame_is_arp   <= is_arp_request(rx_axis_tdata, rx_axis_tkeep);
            frame_is_icmp  <= is_icmp_echo_request(rx_axis_tdata, rx_axis_tkeep);
            frame_bad      <= rx_axis_tuser;
            frame_local_ip <= local_ip;
            if (rx_axis_tlast) begin
              frame_word_count <= 6'd1;
              tx_word_index    <= 6'd0;
              if (!rx_axis_tuser && is_arp_request(rx_axis_tdata, rx_axis_tkeep)) begin
                response_is_arp   <= 1'b1;
                response_local_ip <= local_ip;
                state             <= ST_TX;
              end else if (!rx_axis_tuser &&
                           is_icmp_echo_request(rx_axis_tdata, rx_axis_tkeep)) begin
                response_is_arp   <= 1'b0;
                response_local_ip <= local_ip;
                state             <= ST_TX;
              end
            end else begin
              rx_word_index <= 6'd1;
              state         <= ST_RX;
            end
          end
        end

        ST_RX: begin
          if (rx_axis_tvalid) begin
            frame_data[rx_word_index] <= rx_axis_tdata;
            frame_keep[rx_word_index] <= rx_axis_tkeep;
            frame_bad                 <= frame_bad | rx_axis_tuser;
            if (rx_axis_tlast) begin
              frame_word_count <= rx_word_index + 1'b1;
              tx_word_index    <= 6'd0;
              if (!(frame_bad | rx_axis_tuser) && (frame_is_arp || frame_is_icmp)) begin
                response_is_arp   <= frame_is_arp;
                response_local_ip <= frame_local_ip;
                state             <= ST_TX;
              end else begin
                state <= ST_IDLE;
              end
            end else if (rx_word_index == MAX_FRAME_WORDS - 1) begin
              state <= ST_DROP;
            end else begin
              rx_word_index <= rx_word_index + 1'b1;
            end
          end
        end

        ST_TX: begin
          // CMAC RX has no ready signal. Keep the receive frame
          // boundary while a response is being sent.
          if (rx_axis_tvalid) rx_drop_in_progress <= !rx_axis_tlast;
          if (tx_axis_tready) begin
            if (response_is_arp || (tx_word_index == (frame_word_count - 1'b1))) begin
              if (rx_axis_tvalid ? !rx_axis_tlast : rx_drop_in_progress) state <= ST_DROP;
              else state <= ST_IDLE;
            end else begin
              tx_word_index <= tx_word_index + 1'b1;
            end
          end
        end

        ST_DROP: begin
          if (rx_axis_tvalid && rx_axis_tlast) begin
            rx_drop_in_progress <= 1'b0;
            state               <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
