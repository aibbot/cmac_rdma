`timescale 1ps / 1ps

// Reply-priority AXI-Stream arbiter for four independently generated UDP
// streams. Each ingress owns a one-beat elastic buffer before arbitration.
// Its tready comes only from registered local capacity, not from the CMAC
// output-ready path, while a queued beat can be consumed and replaced every
// clock.
// A VIO enable update may discard buffered beats, which intentionally permits
// an in-flight frame to be interrupted.
module cmac_usplus_0_tx_packet_arbiter (
  input logic clk,
  input logic reset,

  output logic         reply_axis_tready,
  input  logic         reply_axis_tvalid,
  input  logic [511:0] reply_axis_tdata,
  input  logic         reply_axis_tlast,
  input  logic [ 63:0] reply_axis_tkeep,
  input  logic         reply_axis_tuser,
  input  logic         reply_pending,
  input  logic         udp_config_inhibit,

  input  logic [3:0]        udp_axis_enable,
  output logic [3:0]        udp_axis_tready,
  input  logic [3:0]        udp_axis_tvalid,
  input  logic [3:0][511:0] udp_axis_tdata,
  input  logic [3:0]        udp_axis_tlast,
  input  logic [3:0][ 63:0] udp_axis_tkeep,
  input  logic [3:0]        udp_axis_tuser,

  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic         tx_axis_tlast,
  output logic [ 63:0] tx_axis_tkeep,
  output logic         tx_axis_tuser
);

  localparam logic [2:0] SEL_IDLE = 3'd0;
  localparam logic [2:0] SEL_REPLY = 3'd1;
  localparam logic [2:0] SEL_UDP0 = 3'd2;
  localparam logic [2:0] SEL_UDP3 = 3'd5;

  logic   [  2:0]        frame_selection_q;
  logic   [  1:0]        udp_next_q;
  logic   [  3:0]        udp_axis_enable_q;
  logic                  idle_udp_grant_valid_q;
  (* max_fanout = 64 *)logic   [  1:0]        idle_udp_grant_index_q;
  logic                  reply_buffer_valid_q;
  logic   [511:0]        reply_buffer_data_q;
  logic                  reply_buffer_last_q;
  logic   [ 63:0]        reply_buffer_keep_q;
  logic                  reply_buffer_user_q;
  // One elastic beat per source is sufficient because a selected source can
  // dequeue and refill in one clock. Holding unselected sources at their
  // AXI boundary removes four redundant 512-bit FIFO entries.
  logic   [  3:0]        udp_buffer_valid_q;
  logic   [  3:0][511:0] udp_buffer_data_q;
  logic   [  3:0]        udp_buffer_last_q;
  logic   [  3:0][ 63:0] udp_buffer_keep_q;
  logic   [  3:0]        udp_buffer_user_q;

  logic                  output_valid_q;
  logic   [511:0]        output_data_q;
  logic                  output_last_q;
  logic   [ 63:0]        output_keep_q;
  logic                  output_user_q;

  logic   [  2:0]        selected_selection;
  logic   [  1:0]        selected_udp_index;
  logic                  selected_valid;
  logic   [511:0]        selected_data;
  logic                  selected_last;
  logic   [ 63:0]        selected_keep;
  logic                  selected_user;
  logic                  output_pop;
  logic                  output_has_space;
  logic                  output_load;
  logic                  reply_buffer_pop;
  logic   [  3:0]        udp_buffer_pop;
  logic   [  3:0]        udp_buffer_push;
  logic                  idle_udp_pick_valid;
  logic   [  1:0]        idle_udp_pick_index;

  function automatic logic [1:0] next_udp_index(input logic [1:0] stream_index);
    begin
      if (stream_index == 2'd3) next_udp_index = 2'd0;
      else next_udp_index = stream_index + 1'b1;
    end
  endfunction

  function automatic logic selection_enabled(input logic [2:0] selection);
    begin
      case (selection)
        SEL_UDP0: selection_enabled = udp_axis_enable_q[0];
        3'd3:     selection_enabled = udp_axis_enable_q[1];
        3'd4:     selection_enabled = udp_axis_enable_q[2];
        SEL_UDP3: selection_enabled = udp_axis_enable_q[3];
        default:  selection_enabled = 1'b1;
      endcase
    end
  endfunction

  // Compute the next frame grant independently of the wide data mux.  The
  // registered result keeps round-robin control routing off the first-beat
  // data path into output_data_q.
  always_comb begin
    idle_udp_pick_valid = 1'b0;
    idle_udp_pick_index = 2'd0;
    if ((frame_selection_q == SEL_IDLE) && !reply_buffer_valid_q && !reply_pending && !idle_udp_grant_valid_q) begin
      case (udp_next_q)
        2'd0: begin
          if (udp_axis_enable_q[0] && udp_buffer_valid_q[0]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd0;
          end else if (udp_axis_enable_q[1] && udp_buffer_valid_q[1]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd1;
          end else if (udp_axis_enable_q[2] && udp_buffer_valid_q[2]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd2;
          end else if (udp_axis_enable_q[3] && udp_buffer_valid_q[3]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd3;
          end
        end
        2'd1: begin
          if (udp_axis_enable_q[1] && udp_buffer_valid_q[1]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd1;
          end else if (udp_axis_enable_q[2] && udp_buffer_valid_q[2]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd2;
          end else if (udp_axis_enable_q[3] && udp_buffer_valid_q[3]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd3;
          end else if (udp_axis_enable_q[0] && udp_buffer_valid_q[0]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd0;
          end
        end
        2'd2: begin
          if (udp_axis_enable_q[2] && udp_buffer_valid_q[2]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd2;
          end else if (udp_axis_enable_q[3] && udp_buffer_valid_q[3]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd3;
          end else if (udp_axis_enable_q[0] && udp_buffer_valid_q[0]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd0;
          end else if (udp_axis_enable_q[1] && udp_buffer_valid_q[1]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd1;
          end
        end
        2'd3: begin
          if (udp_axis_enable_q[3] && udp_buffer_valid_q[3]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd3;
          end else if (udp_axis_enable_q[0] && udp_buffer_valid_q[0]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd0;
          end else if (udp_axis_enable_q[1] && udp_buffer_valid_q[1]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd1;
          end else if (udp_axis_enable_q[2] && udp_buffer_valid_q[2]) begin
            idle_udp_pick_valid = 1'b1;
            idle_udp_pick_index = 2'd2;
          end
        end
        default: begin
          idle_udp_pick_valid = 1'b0;
          idle_udp_pick_index = 2'd0;
        end
      endcase
    end
  end

  always_comb begin
    selected_selection = SEL_IDLE;
    selected_udp_index = 2'd0;
    selected_valid     = 1'b0;
    selected_data      = 512'd0;
    selected_last      = 1'b0;
    selected_keep      = 64'd0;
    selected_user      = 1'b0;

    // Continue a stored frame before selecting another source. If VIO
    // disabled that stream, omit its remaining buffered data instead.
    if (frame_selection_q == SEL_REPLY) begin
      if (reply_buffer_valid_q) begin
        selected_selection = SEL_REPLY;
        selected_valid     = 1'b1;
        selected_data      = reply_buffer_data_q;
        selected_last      = reply_buffer_last_q;
        selected_keep      = reply_buffer_keep_q;
        selected_user      = reply_buffer_user_q;
      end
    end else if ((frame_selection_q >= SEL_UDP0) && (frame_selection_q <= SEL_UDP3)) begin
      selected_udp_index = frame_selection_q - SEL_UDP0;
      if (udp_axis_enable_q[selected_udp_index] && udp_buffer_valid_q[selected_udp_index]) begin
        selected_selection = frame_selection_q;
        selected_valid     = 1'b1;
        selected_data      = udp_buffer_data_q[selected_udp_index];
        selected_last      = udp_buffer_last_q[selected_udp_index];
        selected_keep      = udp_buffer_keep_q[selected_udp_index];
        selected_user      = udp_buffer_user_q[selected_udp_index];
      end
    end else begin
      if (reply_buffer_valid_q) begin
        selected_selection = SEL_REPLY;
        selected_valid     = 1'b1;
        selected_data      = reply_buffer_data_q;
        selected_last      = reply_buffer_last_q;
        selected_keep      = reply_buffer_keep_q;
        selected_user      = reply_buffer_user_q;
      end else if (!reply_pending && idle_udp_grant_valid_q &&
                   udp_axis_enable_q[idle_udp_grant_index_q] &&
                   udp_buffer_valid_q[idle_udp_grant_index_q]) begin
        selected_selection = SEL_UDP0 + idle_udp_grant_index_q;
        selected_udp_index = idle_udp_grant_index_q;
        selected_valid     = 1'b1;
        selected_data      = udp_buffer_data_q[idle_udp_grant_index_q];
        selected_last      = udp_buffer_last_q[idle_udp_grant_index_q];
        selected_keep      = udp_buffer_keep_q[idle_udp_grant_index_q];
        selected_user      = udp_buffer_user_q[idle_udp_grant_index_q];
      end
    end

    output_pop       = output_valid_q && tx_axis_tready;
    output_has_space = !output_valid_q || output_pop;
    output_load      = output_has_space && selected_valid;
    reply_buffer_pop = output_load && (selected_selection == SEL_REPLY);
    udp_buffer_pop   = 4'd0;
    if (output_load && (selected_selection >= SEL_UDP0) &&
        (selected_selection <= SEL_UDP3))
      udp_buffer_pop[selected_udp_index] = 1'b1;

    // No input-ready expression references input tvalid or CMAC tready.
    // A full elastic buffer can accept a replacement when its stored beat
    // is selected for this output-register load.
    udp_axis_tready   = 4'd0;
    // Keep the reply ingress independent from CMAC tx_axis_tready.  The
    // response engine honors backpressure, and a one-entry reply buffer
    // is sufficient for its infrequent ARP/ICMP traffic.
    reply_axis_tready = !reply_buffer_valid_q;
    if (udp_axis_enable_q[0] && !udp_config_inhibit) udp_axis_tready[0] = !udp_buffer_valid_q[0] || udp_buffer_pop[0];
    if (udp_axis_enable_q[1] && !udp_config_inhibit) udp_axis_tready[1] = !udp_buffer_valid_q[1] || udp_buffer_pop[1];
    if (udp_axis_enable_q[2] && !udp_config_inhibit) udp_axis_tready[2] = !udp_buffer_valid_q[2] || udp_buffer_pop[2];
    if (udp_axis_enable_q[3] && !udp_config_inhibit) udp_axis_tready[3] = !udp_buffer_valid_q[3] || udp_buffer_pop[3];
    udp_buffer_push = udp_axis_tvalid & udp_axis_tready;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      frame_selection_q <= SEL_IDLE;
      udp_next_q        <= 2'd0;
      udp_axis_enable_q <= 4'd0;
    end else begin
      udp_axis_enable_q <= udp_axis_enable;
      if ((frame_selection_q != SEL_IDLE) && !selection_enabled(frame_selection_q)) begin
        frame_selection_q <= SEL_IDLE;
      end else if (output_load) begin
        if (selected_last) begin
          frame_selection_q <= SEL_IDLE;
          if ((selected_selection >= SEL_UDP0) &&
              (selected_selection <= SEL_UDP3))
            udp_next_q <= next_udp_index(selected_udp_index);
        end else begin
          frame_selection_q <= selected_selection;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      idle_udp_grant_valid_q <= 1'b0;
      idle_udp_grant_index_q <= 2'd0;
    end else if ((frame_selection_q != SEL_IDLE) || reply_buffer_valid_q || reply_pending) begin
      idle_udp_grant_valid_q <= 1'b0;
    end else if (idle_udp_grant_valid_q) begin
      if (!udp_axis_enable_q[idle_udp_grant_index_q] ||
          !udp_buffer_valid_q[idle_udp_grant_index_q] ||
          (output_load && (selected_selection >= SEL_UDP0) &&
           (selected_selection <= SEL_UDP3))) begin
        idle_udp_grant_valid_q <= 1'b0;
      end
    end else if (idle_udp_pick_valid) begin
      idle_udp_grant_valid_q <= 1'b1;
      idle_udp_grant_index_q <= idle_udp_pick_index;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      reply_buffer_valid_q <= 1'b0;
      reply_buffer_data_q  <= 512'd0;
      reply_buffer_last_q  <= 1'b0;
      reply_buffer_keep_q  <= 64'd0;
      reply_buffer_user_q  <= 1'b0;
      udp_buffer_valid_q   <= 4'd0;
      udp_buffer_data_q    <= '0;
      udp_buffer_last_q    <= 4'd0;
      udp_buffer_keep_q    <= '0;
      udp_buffer_user_q    <= 4'd0;
    end else begin
      if (reply_buffer_pop) reply_buffer_valid_q <= 1'b0;
      if (reply_axis_tvalid && reply_axis_tready) begin
        reply_buffer_valid_q <= 1'b1;
        reply_buffer_data_q  <= reply_axis_tdata;
        reply_buffer_last_q  <= reply_axis_tlast;
        reply_buffer_keep_q  <= reply_axis_tkeep;
        reply_buffer_user_q  <= reply_axis_tuser;
      end

      if (!udp_axis_enable_q[0]) begin
        udp_buffer_valid_q[0] <= 1'b0;
      end else if (udp_buffer_push[0]) begin
        // A push wins over a concurrent pop: the new beat is the
        // next contents of this one-entry elastic buffer.
        udp_buffer_valid_q[0] <= 1'b1;
        udp_buffer_data_q[0]  <= udp_axis_tdata[0];
        udp_buffer_last_q[0]  <= udp_axis_tlast[0];
        udp_buffer_keep_q[0]  <= udp_axis_tkeep[0];
        udp_buffer_user_q[0]  <= udp_axis_tuser[0];
      end else if (udp_buffer_pop[0]) begin
        udp_buffer_valid_q[0] <= 1'b0;
      end

      if (!udp_axis_enable_q[1]) begin
        udp_buffer_valid_q[1] <= 1'b0;
      end else if (udp_buffer_push[1]) begin
        udp_buffer_valid_q[1] <= 1'b1;
        udp_buffer_data_q[1]  <= udp_axis_tdata[1];
        udp_buffer_last_q[1]  <= udp_axis_tlast[1];
        udp_buffer_keep_q[1]  <= udp_axis_tkeep[1];
        udp_buffer_user_q[1]  <= udp_axis_tuser[1];
      end else if (udp_buffer_pop[1]) begin
        udp_buffer_valid_q[1] <= 1'b0;
      end

      if (!udp_axis_enable_q[2]) begin
        udp_buffer_valid_q[2] <= 1'b0;
      end else if (udp_buffer_push[2]) begin
        udp_buffer_valid_q[2] <= 1'b1;
        udp_buffer_data_q[2]  <= udp_axis_tdata[2];
        udp_buffer_last_q[2]  <= udp_axis_tlast[2];
        udp_buffer_keep_q[2]  <= udp_axis_tkeep[2];
        udp_buffer_user_q[2]  <= udp_axis_tuser[2];
      end else if (udp_buffer_pop[2]) begin
        udp_buffer_valid_q[2] <= 1'b0;
      end

      if (!udp_axis_enable_q[3]) begin
        udp_buffer_valid_q[3] <= 1'b0;
      end else if (udp_buffer_push[3]) begin
        udp_buffer_valid_q[3] <= 1'b1;
        udp_buffer_data_q[3]  <= udp_axis_tdata[3];
        udp_buffer_last_q[3]  <= udp_axis_tlast[3];
        udp_buffer_keep_q[3]  <= udp_axis_tkeep[3];
        udp_buffer_user_q[3]  <= udp_axis_tuser[3];
      end else if (udp_buffer_pop[3]) begin
        udp_buffer_valid_q[3] <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      output_valid_q <= 1'b0;
      output_data_q  <= 512'd0;
      output_last_q  <= 1'b0;
      output_keep_q  <= 64'd0;
      output_user_q  <= 1'b0;
    end else if (output_load) begin
      output_valid_q <= 1'b1;
      output_data_q  <= selected_data;
      output_last_q  <= selected_last;
      output_keep_q  <= selected_keep;
      output_user_q  <= selected_user;
    end else if (output_pop) begin
      output_valid_q <= 1'b0;
    end
  end

  always_comb begin
    tx_axis_tvalid = output_valid_q;
    tx_axis_tdata  = output_data_q;
    tx_axis_tlast  = output_last_q;
    tx_axis_tkeep  = output_keep_q;
    tx_axis_tuser  = output_user_q;
  end

endmodule
