`timescale 1ps / 1ps

// Frame-level CMAC arbitration. ARP/ICMP replies have priority only when the
// current RDMA frame has completed, so an incoming control response can never
// split a RoCE packet.
module rdma_tx_packet_arbiter (
  input  logic         clk,
  input  logic         reset,
  input  logic         rdma_abort,
  output logic         rdma_flush,

  output logic         reply_axis_tready,
  input  logic         reply_axis_tvalid,
  input  logic [511:0] reply_axis_tdata,
  input  logic [63:0]  reply_axis_tkeep,
  input  logic         reply_axis_tlast,
  input  logic         reply_axis_tuser,

  output logic         rdma_axis_tready,
  input  logic         rdma_axis_tvalid,
  input  logic [511:0] rdma_axis_tdata,
  input  logic [63:0]  rdma_axis_tkeep,
  input  logic         rdma_axis_tlast,
  input  logic         rdma_axis_tuser,

  input  logic         tx_axis_tready,
  output logic         tx_axis_tvalid,
  output logic [511:0] tx_axis_tdata,
  output logic [63:0]  tx_axis_tkeep,
  output logic         tx_axis_tlast,
  output logic         tx_axis_tuser
);

  typedef enum logic [1:0] {ARB_IDLE, ARB_REPLY, ARB_RDMA, ARB_ABORT} arb_state_t;
  arb_state_t state;
  logic rdma_frame_started;
  (* ASYNC_REG = "TRUE" *) logic rdma_abort_sync1;
  (* ASYNC_REG = "TRUE" *) logic rdma_abort_sync2;
  logic rdma_abort_pending;
  logic rdma_abort_active;

  assign rdma_abort_active = rdma_abort_sync2 || rdma_abort_pending;

  // rdma_abort can assert asynchronously when the RDMA MMCM loses lock. Only
  // the synchronized level may affect the CMAC-domain AXI state machine.
  always_ff @(posedge clk) begin
    if (reset) begin
      rdma_abort_sync1 <= 1'b1;
      rdma_abort_sync2 <= 1'b1;
    end else begin
      rdma_abort_sync1 <= rdma_abort;
      rdma_abort_sync2 <= rdma_abort_sync1;
    end
  end

  always_comb begin
    rdma_flush = 1'b0;
    reply_axis_tready = 1'b0;
    rdma_axis_tready = 1'b0;
    tx_axis_tvalid = 1'b0;
    tx_axis_tdata = 512'd0;
    tx_axis_tkeep = 64'd0;
    tx_axis_tlast = 1'b0;
    tx_axis_tuser = 1'b0;
    case (state)
      ARB_REPLY: begin
        reply_axis_tready = tx_axis_tready;
        tx_axis_tvalid = reply_axis_tvalid;
        tx_axis_tdata = reply_axis_tdata;
        tx_axis_tkeep = reply_axis_tkeep;
        tx_axis_tlast = reply_axis_tlast;
        tx_axis_tuser = reply_axis_tuser;
      end
      ARB_RDMA: begin
        // Once presented, an AXI beat remains visible until handshake even if
        // lock is lost. The state machine flushes any following buffered beat
        // on the same edge that accepts this one.
        rdma_axis_tready = tx_axis_tready;
        tx_axis_tvalid = rdma_axis_tvalid;
        tx_axis_tdata = rdma_axis_tdata;
        tx_axis_tkeep = rdma_axis_tkeep;
        tx_axis_tlast = rdma_axis_tlast;
        tx_axis_tuser = rdma_axis_tuser;
      end
      ARB_ABORT: begin
        // Close a partially transferred frame with an explicit bad-frame
        // marker. This releases the CMAC packet boundary before another
        // source is granted after the RDMA clock becomes available again.
        tx_axis_tvalid = 1'b1;
        tx_axis_tdata = 512'd0;
        tx_axis_tkeep = 64'h0000_0000_0000_0001;
        tx_axis_tlast = 1'b1;
        tx_axis_tuser = 1'b1;
      end
      default: begin
      end
    endcase

    case (state)
      ARB_IDLE, ARB_REPLY: rdma_flush = rdma_abort_active;
      ARB_RDMA: begin
        rdma_flush = rdma_abort_active &&
                     (!rdma_axis_tvalid || tx_axis_tready);
      end
      ARB_ABORT: rdma_flush = 1'b1;
      default: rdma_flush = 1'b0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= ARB_IDLE;
      rdma_frame_started <= 1'b0;
      rdma_abort_pending <= 1'b0;
    end else begin
      if ((state == ARB_RDMA) && rdma_abort_sync2) begin
        rdma_abort_pending <= 1'b1;
      end
      case (state)
        ARB_IDLE: begin
          rdma_frame_started <= 1'b0;
          if (!rdma_abort_sync2) rdma_abort_pending <= 1'b0;
          if (reply_axis_tvalid) state <= ARB_REPLY;
          else if (rdma_axis_tvalid && !rdma_abort_active) state <= ARB_RDMA;
        end
        ARB_REPLY: begin
          if (!rdma_abort_sync2) rdma_abort_pending <= 1'b0;
          if (reply_axis_tvalid && tx_axis_tready && reply_axis_tlast) state <= ARB_IDLE;
        end
        ARB_RDMA: begin
          if (rdma_abort_active) begin
            if (!rdma_axis_tvalid) begin
              state <= rdma_frame_started ? ARB_ABORT : ARB_IDLE;
            end else if (tx_axis_tready) begin
              if (rdma_axis_tlast) begin
                state <= ARB_IDLE;
                rdma_frame_started <= 1'b0;
              end else begin
                state <= ARB_ABORT;
                rdma_frame_started <= 1'b1;
              end
            end
          end else if (rdma_axis_tvalid && tx_axis_tready) begin
            if (rdma_axis_tlast) begin
              state <= ARB_IDLE;
              rdma_frame_started <= 1'b0;
            end else begin
              rdma_frame_started <= 1'b1;
            end
          end
        end
        ARB_ABORT: begin
          if (tx_axis_tready) begin
            state <= ARB_IDLE;
            rdma_frame_started <= 1'b0;
          end
        end
        default: state <= ARB_IDLE;
      endcase
    end
  end

endmodule
