`timescale 1ps / 1ps

// Applies CMAC receive PAUSE requests at the final transmit frame boundary.
// Mode 0 selects global PAUSE (bit 8); mode 1 selects PFC priority 0 (bit 0).
module cmac_usplus_0_rdma_pause_control #(
  parameter integer EVENT_COUNTER_WIDTH = 32
) (
  input  logic                           clk,
  input  logic                           reset,
  input  logic                           pfc0_mode,
  input  logic [8:0]                     stat_rx_pause_req,
  input  logic [8:0]                     stat_rx_pause_valid,
  output logic [8:0]                     ctl_rx_pause_enable,
  output logic [8:0]                     ctl_rx_pause_ack,
  output logic                           pause_pending,
  output logic                           pause_active,
  output logic                           frame_active,
  output logic [EVENT_COUNTER_WIDTH-1:0] pause_event_count,

  output logic                           s_axis_tready,
  input  logic                           s_axis_tvalid,
  input  logic [511:0]                   s_axis_tdata,
  input  logic [63:0]                    s_axis_tkeep,
  input  logic                           s_axis_tlast,
  input  logic                           s_axis_tuser,

  input  logic                           m_axis_tready,
  output logic                           m_axis_tvalid,
  output logic [511:0]                   m_axis_tdata,
  output logic [63:0]                    m_axis_tkeep,
  output logic                           m_axis_tlast,
  output logic                           m_axis_tuser
);

  localparam logic [8:0] GLOBAL_PAUSE_MASK = 9'h100;
  localparam logic [8:0] PFC0_PAUSE_MASK = 9'h001;
  localparam logic [EVENT_COUNTER_WIDTH-1:0] EVENT_COUNTER_MAX =
      {EVENT_COUNTER_WIDTH{1'b1}};

  logic [8:0] selected_mask;
  logic [8:0] pause_mask;
  logic selected_request;
  logic selected_valid;
  logic block_new_frame;
  logic axis_handshake;
  logic frame_ends_now;

  always_comb begin
    selected_mask = pfc0_mode ? PFC0_PAUSE_MASK : GLOBAL_PAUSE_MASK;
    ctl_rx_pause_enable = (pause_active || pause_pending) ?
                          pause_mask : selected_mask;
    ctl_rx_pause_ack = pause_active ? pause_mask : 9'h000;
    selected_request = |(stat_rx_pause_req & ctl_rx_pause_enable);
    selected_valid = |(stat_rx_pause_valid & ctl_rx_pause_enable);

    block_new_frame = pause_active || pause_pending || selected_request;
    m_axis_tvalid = s_axis_tvalid && (frame_active || !block_new_frame);
    s_axis_tready = m_axis_tready && (frame_active || !block_new_frame);
    m_axis_tdata = s_axis_tdata;
    m_axis_tkeep = s_axis_tkeep;
    m_axis_tlast = s_axis_tlast;
    m_axis_tuser = s_axis_tuser;

    axis_handshake = m_axis_tvalid && m_axis_tready;
    frame_ends_now = axis_handshake && s_axis_tlast;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      pause_mask <= 9'h000;
      pause_pending <= 1'b0;
      pause_active <= 1'b0;
      frame_active <= 1'b0;
      pause_event_count <= {EVENT_COUNTER_WIDTH{1'b0}};
    end else begin
      // Once TVALID is presented, AXI requires the beat to remain visible
      // until handshake. Treat that presentation as the frame boundary lock.
      if (m_axis_tvalid) begin
        frame_active <= !(axis_handshake && s_axis_tlast);
      end

      if (selected_valid && (pause_event_count != EVENT_COUNTER_MAX)) begin
        pause_event_count <= pause_event_count + {{(EVENT_COUNTER_WIDTH-1){1'b0}}, 1'b1};
      end

      if (pause_active) begin
        if (!(|(stat_rx_pause_req & pause_mask))) begin
          pause_mask <= 9'h000;
          pause_active <= 1'b0;
        end
      end else if (pause_pending) begin
        if (frame_ends_now) begin
          pause_pending <= 1'b0;
          pause_active <= 1'b1;
        end
      end else if (selected_request) begin
        pause_mask <= selected_mask;
        if (!frame_active || frame_ends_now) begin
          pause_active <= 1'b1;
        end else begin
          pause_pending <= 1'b1;
        end
      end
    end
  end

endmodule
