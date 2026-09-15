`timescale 1ps / 1ps

module cmac_usplus_0_rdcp_control #(
  parameter logic [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] LOCAL_IP = 32'hC0A8_110B,
  parameter logic [23:0] LOCAL_QPN = 24'd1
) (
  input  logic         clk,
  input  logic         reset,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic [511:0] s_axis_tdata,
  input  logic [63:0]  s_axis_tkeep,
  input  logic         s_axis_tlast,
  input  logic         s_axis_tuser,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic [511:0] m_axis_tdata,
  output logic [63:0]  m_axis_tkeep,
  output logic         m_axis_tlast,
  output logic         m_axis_tuser,

  output logic         cfg_valid,
  input  logic         cfg_ready,
  output logic [47:0]  cfg_remote_mac,
  output logic [31:0]  cfg_remote_ip,
  output logic [23:0]  cfg_remote_qpn,
  output logic [23:0]  cfg_local_psn,
  output logic [47:0]  cfg_remote_base,
  output logic [31:0]  cfg_rkey,
  output logic [31:0]  cfg_ring_size,
  output logic [31:0]  cfg_wr_size,
  output logic [31:0]  cfg_notify_interval_bytes,
  output logic [63:0]  cfg_local_base,
  output logic [47:0]  cfg_commit_remote_addr,
  output logic         cfg_enable_immediate,
  input  logic         cfg_done,
  input  logic         cfg_accepted,
  input  logic [31:0]  cfg_reject_reason,

  output logic         start_request,
  output logic         stop_request,
  output logic         abort_request,
  input  logic         endpoint_configured,
  input  logic         endpoint_active,
  input  logic         endpoint_stopping,
  input  logic         endpoint_drained,
  input  logic         endpoint_fault,
  input  logic [31:0]  endpoint_fault_reason,
  input  logic         endpoint_final_commit_acked,
  input  logic [23:0]  endpoint_current_psn,
  input  logic [63:0]  endpoint_issued_bytes,
  input  logic [63:0]  endpoint_acked_bytes,
  input  logic [63:0]  endpoint_published_bytes,
  input  logic [63:0]  endpoint_producer_sequence,
  output logic [3:0]   session_state,
  output logic         safe_to_release,
  output logic [31:0]  config_generation
);
  localparam logic [31:0] RDCP_MAGIC = 32'h5244_4350;
  localparam logic [7:0] RDCP_VERSION = 8'd1;
  localparam logic [15:0] CONTROL_PORT = 16'd4792;
  localparam logic [15:0] RESPONSE_IP_LENGTH = 16'd112;
  localparam logic [15:0] RESPONSE_UDP_LENGTH = 16'd92;
  localparam logic [15:0] RESPONSE_FRAME_LENGTH = 16'd126;
  localparam logic [31:0] CAPABILITIES = 32'h0000_0007;
  localparam logic [31:0] PMTU_BYTES = 32'd4096;

  localparam logic [7:0] OP_HELLO = 8'd1;
  localparam logic [7:0] OP_CONFIG = 8'd2;
  localparam logic [7:0] OP_START = 8'd3;
  localparam logic [7:0] OP_STOP = 8'd4;
  localparam logic [7:0] OP_ABORT = 8'd5;
  localparam logic [7:0] OP_STATUS = 8'd6;

  localparam logic [15:0] RESULT_OK = 16'd0;
  localparam logic [15:0] RESULT_BAD_VERSION = 16'd1;
  localparam logic [15:0] RESULT_BAD_OPCODE = 16'd2;
  localparam logic [15:0] RESULT_BAD_LENGTH = 16'd3;
  localparam logic [15:0] RESULT_BAD_SESSION = 16'd4;
  localparam logic [15:0] RESULT_BAD_SOURCE = 16'd5;
  localparam logic [15:0] RESULT_OLD_TRANSACTION = 16'd6;
  localparam logic [15:0] RESULT_BUSY = 16'd7;
  localparam logic [15:0] RESULT_INVALID_CONFIG = 16'd8;
  localparam logic [15:0] RESULT_INVALID_STATE = 16'd9;

  localparam logic [3:0] SESSION_IDLE = 4'd0;
  localparam logic [3:0] SESSION_CONFIGURING = 4'd1;
  localparam logic [3:0] SESSION_READY = 4'd2;
  localparam logic [3:0] SESSION_RUNNING = 4'd3;
  localparam logic [3:0] SESSION_STOPPING = 4'd4;
  localparam logic [3:0] SESSION_CLOSED = 4'd5;
  localparam logic [3:0] SESSION_FAULT_QUIESCING = 4'd6;
  localparam logic [3:0] SESSION_FAULTED = 4'd7;

  typedef enum logic [4:0] {
    CTRL_RX_FIRST,
    CTRL_RX_SECOND,
    CTRL_RX_DROP,
    CTRL_VALIDATE,
    CTRL_VALIDATE_RESULT,
    CTRL_IP_CHECKSUM,
    CTRL_IP_CHECKSUM_DONE,
    CTRL_UDP_PSEUDO_CHECKSUM,
    CTRL_UDP_CHECKSUM,
    CTRL_UDP_CHECKSUM_DONE,
    CTRL_DISPATCH,
    CTRL_CONFIG_PARSE,
    CTRL_CONFIG_ADDRESS,
    CTRL_CONFIG_VALIDATE,
    CTRL_WAIT_CONFIG,
    CTRL_RESPONSE_BUILD,
    CTRL_RESPONSE_IP_CHECKSUM,
    CTRL_RESPONSE_IP_CHECKSUM_DONE,
    CTRL_RESPONSE_UDP_PSEUDO_CHECKSUM,
    CTRL_RESPONSE_UDP_CHECKSUM,
    CTRL_RESPONSE_UDP_CHECKSUM_DONE,
    CTRL_RESPONSE_FINALIZE,
    CTRL_RESPONSE_SEND_FIRST,
    CTRL_RESPONSE_SEND_SECOND
  } control_state_t;

  control_state_t control_state;
  logic [511:0] request_word0;
  logic [511:0] request_word1;
  logic [63:0] request_keep0;
  logic [63:0] request_keep1;
  logic request_two_words;
  logic request_bad;
  logic [15:0] request_udp_length;
  logic [15:0] request_payload_length;
  logic [5:0] request_udp_word_count;
  logic request_udp_odd;
  logic request_shape_valid;
  logic request_header_valid;
  logic [31:0] checksum_sum;
  logic [511:0] checksum_shift;
  logic [5:0] checksum_words_left;
  logic [3:0] checksum_first_words_left;

  logic config_session_valid;
  logic config_qpn_valid;
  logic config_psn_valid;
  logic config_rkey_valid;
  logic config_ring_valid;
  logic config_wr_valid;
  logic config_notify_valid;
  logic config_local_base_valid;
  logic config_flags_valid;
  logic config_address_shape_valid;
  logic config_address_valid;
  logic [64:0] config_expected_commit_address;
  logic [63:0] config_commit_address_value;

  logic source_bound;
  logic [47:0] bound_remote_mac;
  logic [31:0] bound_remote_ip;
  logic [15:0] bound_remote_port;
  logic [63:0] bound_session_id;
  logic [31:0] last_transaction_id;
  logic [31:0] session_fault_reason;

  logic cache_valid;
  logic [511:0] cache_word0;
  logic [511:0] cache_word1;
  logic [31:0] cache_transaction_id;
  logic [7:0] cache_opcode;

  logic [47:0] response_remote_mac;
  logic [31:0] response_remote_ip;
  logic [15:0] response_remote_port;
  logic [63:0] response_session_id;
  logic [31:0] response_transaction_id;
  logic [7:0] response_opcode_value;
  logic [15:0] response_result;
  logic [7:0] response_session_state;
  logic [31:0] response_reason;
  logic [31:0] response_status_bits;
  logic [23:0] response_current_psn;
  logic [31:0] response_config_generation;
  logic [63:0] response_issued_bytes;
  logic [63:0] response_acked_bytes;
  logic [63:0] response_published_bytes;
  logic [63:0] response_producer_sequence;
  logic [15:0] response_ip_id;
  logic [511:0] response_word0;
  logic [511:0] response_word1;
  logic response_cache_enable;
  logic [15:0] next_response_ip_id;

  function automatic logic [7:0] word_byte(
    input logic [511:0] word,
    input integer index
  );
    word_byte = word[index * 8 +: 8];
  endfunction

  function automatic logic [7:0] request_byte(input integer index);
    if (index < 64)
      request_byte = word_byte(request_word0, index);
    else
      request_byte = word_byte(request_word1, index - 64);
  endfunction

  function automatic logic [15:0] request_be16(input integer index);
    request_be16 = {request_byte(index), request_byte(index + 1)};
  endfunction

  function automatic logic [31:0] request_be32(input integer index);
    request_be32 = {request_byte(index), request_byte(index + 1),
                    request_byte(index + 2), request_byte(index + 3)};
  endfunction

  function automatic logic [47:0] request_be48(input integer index);
    request_be48 = {request_byte(index), request_byte(index + 1),
                    request_byte(index + 2), request_byte(index + 3),
                    request_byte(index + 4), request_byte(index + 5)};
  endfunction

  function automatic logic [63:0] request_be64(input integer index);
    request_be64 = {request_be32(index), request_be32(index + 4)};
  endfunction

  function automatic logic [63:0] keep_mask(input logic [6:0] byte_count);
    if (byte_count >= 7'd64)
      keep_mask = 64'hFFFF_FFFF_FFFF_FFFF;
    else if (byte_count == 7'd0)
      keep_mask = 64'd0;
    else
      keep_mask = ~(64'hFFFF_FFFF_FFFF_FFFF << byte_count);
  endfunction

  function automatic logic [15:0] fold_checksum(input logic [31:0] value);
    logic [16:0] first_fold;
    logic [16:0] second_fold;
    begin
      first_fold = {1'b0, value[15:0]} + {1'b0, value[31:16]};
      second_fold = {1'b0, first_fold[15:0]} + first_fold[16];
      fold_checksum = second_fold[15:0] + second_fold[16];
    end
  endfunction

  function automatic logic [15:0] store_be16(input logic [15:0] value);
    store_be16 = {value[7:0], value[15:8]};
  endfunction

  function automatic logic [31:0] store_be32(input logic [31:0] value);
    store_be32 = {value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  function automatic logic [47:0] store_be48(input logic [47:0] value);
    store_be48 = {value[7:0], value[15:8], value[23:16],
                  value[31:24], value[39:32], value[47:40]};
  endfunction

  function automatic logic [63:0] store_be64(input logic [63:0] value);
    store_be64 = {value[7:0], value[15:8], value[23:16], value[31:24],
                  value[39:32], value[47:40], value[55:48], value[63:56]};
  endfunction

  task automatic queue_response(
    input logic [15:0] result_value,
    input logic [7:0] state_value,
    input logic [31:0] reason_value,
    input logic cache_enable
  );
    logic [31:0] status_value;
    begin
      status_value = 32'd0;
      if (endpoint_configured) status_value[0] = 1'b1;
      if (endpoint_active) status_value[1] = 1'b1;
      if (endpoint_drained) status_value[2] = 1'b1;
      if (endpoint_fault || state_value == SESSION_FAULT_QUIESCING ||
          state_value == SESSION_FAULTED) status_value[3] = 1'b1;
      if (state_value == SESSION_CLOSED || state_value == SESSION_FAULTED)
        status_value[4] = 1'b1;
      if (endpoint_final_commit_acked) status_value[5] = 1'b1;

      response_remote_mac <= request_be48(6);
      response_remote_ip <= request_be32(26);
      response_remote_port <= request_be16(34);
      response_session_id <= request_be64(50);
      response_transaction_id <= request_be32(58);
      response_opcode_value <= request_byte(47) | 8'h80;
      response_result <= result_value;
      response_session_state <= state_value;
      response_reason <= reason_value;
      response_status_bits <= status_value;
      response_current_psn <= endpoint_current_psn;
      response_config_generation <= config_generation;
      response_issued_bytes <= endpoint_issued_bytes;
      response_acked_bytes <= endpoint_acked_bytes;
      response_published_bytes <= endpoint_published_bytes;
      response_producer_sequence <= endpoint_producer_sequence;
      response_ip_id <= next_response_ip_id;
      next_response_ip_id <= next_response_ip_id + 16'd1;
      response_cache_enable <= cache_enable;
      control_state <= CTRL_RESPONSE_BUILD;
      if (cache_enable) begin
        last_transaction_id <= request_be32(58);
        cache_transaction_id <= request_be32(58);
        cache_opcode <= request_byte(47);
      end
    end
  endtask

  assign safe_to_release = (session_state == SESSION_CLOSED) ||
                           (session_state == SESSION_FAULTED);
  assign s_axis_tready = (control_state == CTRL_RX_FIRST) ||
                         (control_state == CTRL_RX_SECOND) ||
                         (control_state == CTRL_RX_DROP);
  assign m_axis_tvalid = (control_state == CTRL_RESPONSE_SEND_FIRST) ||
                         (control_state == CTRL_RESPONSE_SEND_SECOND);
  assign m_axis_tdata = (control_state == CTRL_RESPONSE_SEND_FIRST) ?
                        response_word0 : response_word1;
  assign m_axis_tkeep = (control_state == CTRL_RESPONSE_SEND_FIRST) ?
                        64'hFFFF_FFFF_FFFF_FFFF :
                        keep_mask(RESPONSE_FRAME_LENGTH - 16'd64);
  assign m_axis_tlast = control_state == CTRL_RESPONSE_SEND_SECOND;
  assign m_axis_tuser = 1'b0;

  always_ff @(posedge clk) begin
    logic [15:0] folded_checksum;
    logic [15:0] checksum_word;
    logic [15:0] checksum_value;
    logic [15:0] actual_frame_length;
    logic [15:0] request_udp_length_value;
    logic shape_valid;
    logic semantic_length_valid;
    logic source_matches;
    logic session_matches;
    logic transaction_replay;
    logic transaction_old;
    logic [31:0] request_remote_qpn_value;
    logic [31:0] request_local_psn_value;
    logic [63:0] request_remote_base_value;
    logic [63:0] request_commit_address_value;
    logic [31:0] request_flags_value;
    logic [511:0] built_word0;
    logic [511:0] built_word1;
    logic [511:0] completed_word;

    if (reset) begin
      control_state <= CTRL_RX_FIRST;
      request_word0 <= 512'd0;
      request_word1 <= 512'd0;
      request_keep0 <= 64'd0;
      request_keep1 <= 64'd0;
      request_two_words <= 1'b0;
      request_bad <= 1'b0;
      request_udp_length <= 16'd0;
      request_payload_length <= 16'd0;
      request_udp_word_count <= 6'd0;
      request_udp_odd <= 1'b0;
      request_shape_valid <= 1'b0;
      request_header_valid <= 1'b0;
      checksum_sum <= 32'd0;
      checksum_shift <= 512'd0;
      checksum_words_left <= 6'd0;
      checksum_first_words_left <= 4'd0;
      config_session_valid <= 1'b0;
      config_qpn_valid <= 1'b0;
      config_psn_valid <= 1'b0;
      config_rkey_valid <= 1'b0;
      config_ring_valid <= 1'b0;
      config_wr_valid <= 1'b0;
      config_notify_valid <= 1'b0;
      config_local_base_valid <= 1'b0;
      config_flags_valid <= 1'b0;
      config_address_shape_valid <= 1'b0;
      config_address_valid <= 1'b0;
      config_expected_commit_address <= 65'd0;
      config_commit_address_value <= 64'd0;
      source_bound <= 1'b0;
      bound_remote_mac <= 48'd0;
      bound_remote_ip <= 32'd0;
      bound_remote_port <= 16'd0;
      bound_session_id <= 64'd0;
      last_transaction_id <= 32'd0;
      session_fault_reason <= 32'd0;
      cache_valid <= 1'b0;
      cache_word0 <= 512'd0;
      cache_word1 <= 512'd0;
      cache_transaction_id <= 32'd0;
      cache_opcode <= 8'd0;
      response_remote_mac <= 48'd0;
      response_remote_ip <= 32'd0;
      response_remote_port <= 16'd0;
      response_session_id <= 64'd0;
      response_transaction_id <= 32'd0;
      response_opcode_value <= 8'd0;
      response_result <= RESULT_OK;
      response_session_state <= SESSION_IDLE;
      response_reason <= 32'd0;
      response_status_bits <= 32'd0;
      response_current_psn <= 24'd0;
      response_config_generation <= 32'd0;
      response_issued_bytes <= 64'd0;
      response_acked_bytes <= 64'd0;
      response_published_bytes <= 64'd0;
      response_producer_sequence <= 64'd0;
      response_ip_id <= 16'd0;
      response_word0 <= 512'd0;
      response_word1 <= 512'd0;
      response_cache_enable <= 1'b0;
      next_response_ip_id <= 16'd0;
      cfg_valid <= 1'b0;
      cfg_remote_mac <= 48'd0;
      cfg_remote_ip <= 32'd0;
      cfg_remote_qpn <= 24'd0;
      cfg_local_psn <= 24'd0;
      cfg_remote_base <= 48'd0;
      cfg_rkey <= 32'd0;
      cfg_ring_size <= 32'd0;
      cfg_wr_size <= 32'd0;
      cfg_notify_interval_bytes <= 32'd0;
      cfg_local_base <= 64'd0;
      cfg_commit_remote_addr <= 48'd0;
      cfg_enable_immediate <= 1'b0;
      start_request <= 1'b0;
      stop_request <= 1'b0;
      abort_request <= 1'b0;
      session_state <= SESSION_IDLE;
      config_generation <= 32'd0;
    end else begin
      cfg_valid <= 1'b0;
      start_request <= 1'b0;
      stop_request <= 1'b0;
      abort_request <= 1'b0;

      if (session_state == SESSION_RUNNING && endpoint_stopping)
        session_state <= SESSION_STOPPING;
      if (session_state == SESSION_STOPPING && endpoint_final_commit_acked &&
          endpoint_drained)
        session_state <= SESSION_CLOSED;
      if (session_state == SESSION_FAULT_QUIESCING && endpoint_drained)
        session_state <= SESSION_FAULTED;
      if (endpoint_fault &&
          (session_state == SESSION_READY || session_state == SESSION_RUNNING ||
           session_state == SESSION_STOPPING)) begin
        session_fault_reason <= endpoint_fault_reason;
        session_state <= SESSION_FAULT_QUIESCING;
        abort_request <= 1'b1;
      end

      case (control_state)
        CTRL_RX_FIRST: begin
          if (s_axis_tvalid && s_axis_tready) begin
            request_word0 <= s_axis_tdata;
            request_keep0 <= s_axis_tkeep;
            request_bad <= s_axis_tuser;
            request_two_words <= 1'b0;
            if (s_axis_tlast)
              control_state <= CTRL_VALIDATE;
            else
              control_state <= CTRL_RX_SECOND;
          end
        end

        CTRL_RX_SECOND: begin
          if (s_axis_tvalid && s_axis_tready) begin
            request_word1 <= s_axis_tdata;
            request_keep1 <= s_axis_tkeep;
            request_bad <= request_bad || s_axis_tuser;
            request_two_words <= 1'b1;
            if (s_axis_tlast)
              control_state <= CTRL_VALIDATE;
            else
              control_state <= CTRL_RX_DROP;
          end
        end

        CTRL_RX_DROP: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
            control_state <= CTRL_RX_FIRST;
        end

        CTRL_VALIDATE: begin
          request_udp_length_value = request_be16(38);
          request_udp_length <= request_udp_length_value;
          request_payload_length <= request_be16(48);
          request_udp_word_count <= request_udp_length_value[15:1] +
                                    request_udp_length_value[0];
          request_udp_odd <= request_udp_length_value[0];
          actual_frame_length = 16'd14 + request_be16(16);
          shape_valid = 1'b0;
          if (actual_frame_length <= 16'd64)
            shape_valid = !request_two_words &&
                          request_keep0 == keep_mask(actual_frame_length[6:0]);
          else if (actual_frame_length <= 16'd128)
            shape_valid = request_two_words &&
                          request_keep0 == 64'hFFFF_FFFF_FFFF_FFFF &&
                          request_keep1 == keep_mask(actual_frame_length - 16'd64);

          request_shape_valid <= !request_bad && shape_valid;
          request_header_valid <=
            request_be48(0) == LOCAL_MAC && request_be48(6) != 48'd0 &&
            request_be16(12) == 16'h0800 && request_byte(14) == 8'h45 &&
            request_be16(16) >= 16'd48 &&
            (request_be16(20) & 16'h3FFF) == 16'd0 &&
            request_byte(23) == 8'd17 && request_be32(26) != 32'd0 &&
            request_be32(30) == LOCAL_IP && request_be16(36) == CONTROL_PORT &&
            request_udp_length_value >= 16'd28 &&
            request_udp_length_value <= 16'd84 &&
            request_be16(16) == request_udp_length_value + 16'd20 &&
            request_be16(40) != 16'd0 && request_be32(42) == RDCP_MAGIC;
          checksum_sum <= 32'd0;
          checksum_shift <= request_word0 >> 112;
          checksum_words_left <= 6'd10;
          checksum_first_words_left <= 4'd0;
          control_state <= CTRL_VALIDATE_RESULT;
        end

        CTRL_VALIDATE_RESULT: begin
          if (request_shape_valid && request_header_valid)
            control_state <= CTRL_IP_CHECKSUM;
          else
            control_state <= CTRL_RX_FIRST;
        end

        CTRL_IP_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          checksum_shift <= checksum_shift >> 16;
          checksum_words_left <= checksum_words_left - 6'd1;
          if (checksum_words_left == 6'd1)
            control_state <= CTRL_IP_CHECKSUM_DONE;
        end

        CTRL_IP_CHECKSUM_DONE: begin
          folded_checksum = fold_checksum(checksum_sum);
          if (folded_checksum != 16'hFFFF) begin
            control_state <= CTRL_RX_FIRST;
          end else begin
            checksum_sum <= 32'd0;
            checksum_shift <= {
              416'd0,
              request_word0[38 * 8 +: 16],
              16'h1100,
              request_word0[30 * 8 +: 32],
              request_word0[26 * 8 +: 32]
            };
            checksum_words_left <= 6'd6;
            control_state <= CTRL_UDP_PSEUDO_CHECKSUM;
          end
        end

        CTRL_UDP_PSEUDO_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          if (checksum_words_left == 6'd1) begin
            checksum_shift <= request_word0 >> 272;
            checksum_words_left <= request_udp_word_count;
            checksum_first_words_left <= 4'd15;
            control_state <= CTRL_UDP_CHECKSUM;
          end else begin
            checksum_shift <= checksum_shift >> 16;
            checksum_words_left <= checksum_words_left - 6'd1;
          end
        end

        CTRL_UDP_CHECKSUM: begin
          if (checksum_words_left == 6'd1 && request_udp_odd)
            checksum_word = {checksum_shift[7:0], 8'd0};
          else
            checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          if (checksum_words_left == 6'd1) begin
            checksum_words_left <= 6'd0;
            control_state <= CTRL_UDP_CHECKSUM_DONE;
          end else begin
            checksum_words_left <= checksum_words_left - 6'd1;
            if (checksum_first_words_left == 4'd1) begin
              checksum_shift <= request_word1;
              checksum_first_words_left <= 4'd0;
            end else begin
              checksum_shift <= checksum_shift >> 16;
              if (checksum_first_words_left != 4'd0)
                checksum_first_words_left <= checksum_first_words_left - 4'd1;
            end
          end
        end

        CTRL_UDP_CHECKSUM_DONE: begin
          folded_checksum = fold_checksum(checksum_sum);
          if (folded_checksum == 16'hFFFF)
            control_state <= CTRL_DISPATCH;
          else
            control_state <= CTRL_RX_FIRST;
        end

        CTRL_DISPATCH: begin
          semantic_length_valid =
            request_payload_length == (request_udp_length - 16'd28);
          source_matches = request_be48(6) == bound_remote_mac &&
                           request_be32(26) == bound_remote_ip &&
                           request_be16(34) == bound_remote_port;
          session_matches = request_be64(50) == bound_session_id;
          transaction_replay = cache_valid && source_matches && session_matches &&
                               request_be32(58) == cache_transaction_id &&
                               request_byte(47) == cache_opcode;
          transaction_old = request_be32(58) <= last_transaction_id;

          if (request_byte(46) != RDCP_VERSION) begin
            queue_response(RESULT_BAD_VERSION, {4'd0, session_state}, 32'd0, 1'b0);
          end else if (request_byte(47) < OP_HELLO || request_byte(47) > OP_STATUS) begin
            queue_response(RESULT_BAD_OPCODE, {4'd0, session_state}, 32'd0, 1'b0);
          end else if (!semantic_length_valid ||
                       ((request_byte(47) == OP_CONFIG) &&
                        (request_payload_length != 16'd56)) ||
                       ((request_byte(47) != OP_CONFIG) &&
                        (request_payload_length != 16'd0))) begin
            queue_response(RESULT_BAD_LENGTH, {4'd0, session_state}, 32'd0, 1'b0);
          end else if (request_byte(47) == OP_HELLO) begin
            queue_response(RESULT_OK, {4'd0, session_state}, session_fault_reason, 1'b0);
          end else if (transaction_replay) begin
            response_word0 <= cache_word0;
            response_word1 <= cache_word1;
            control_state <= CTRL_RESPONSE_SEND_FIRST;
          end else if (request_byte(47) == OP_ABORT &&
                       request_be64(50) != 64'd0 &&
                       (session_state == SESSION_IDLE ||
                        session_state == SESSION_CLOSED ||
                        session_state == SESSION_FAULTED) &&
                       (!source_bound || !session_matches)) begin
            // CONFIG timeout is ambiguous. In a state with no live MR access,
            // bind the caller's safety-only session so teardown can converge.
            source_bound <= 1'b1;
            bound_remote_mac <= request_be48(6);
            bound_remote_ip <= request_be32(26);
            bound_remote_port <= request_be16(34);
            bound_session_id <= request_be64(50);
            session_fault_reason <= 32'd0;
            abort_request <= 1'b1;
            session_state <= SESSION_FAULT_QUIESCING;
            queue_response(RESULT_OK, {4'd0, SESSION_FAULT_QUIESCING},
                           32'd0, 1'b1);
          end else if (request_byte(47) == OP_CONFIG) begin
            if (!(session_state == SESSION_IDLE || session_state == SESSION_CLOSED ||
                  session_state == SESSION_FAULTED)) begin
              if (source_bound && source_matches && session_matches &&
                  transaction_old)
                queue_response(RESULT_OLD_TRANSACTION,
                               {4'd0, session_state}, session_fault_reason, 1'b0);
              else
                queue_response(RESULT_INVALID_STATE, {4'd0, session_state},
                               session_fault_reason,
                               source_bound && source_matches && session_matches);
            end else if (source_bound && session_matches) begin
              // CLOSED/FAULTED terminates the session. An old CONFIG must not
              // resurrect its rkey after the host has released that MR.
              queue_response(RESULT_BAD_SESSION, {4'd0, session_state},
                             session_fault_reason, 1'b0);
            end else begin
              control_state <= CTRL_CONFIG_PARSE;
            end
          end else if (!source_bound) begin
            if (request_byte(47) == OP_STATUS && request_be64(50) == 64'd0)
              queue_response(RESULT_OK, {4'd0, session_state}, session_fault_reason, 1'b0);
            else
              queue_response(RESULT_INVALID_STATE, {4'd0, session_state},
                             session_fault_reason, 1'b0);
          end else if (!source_matches) begin
            queue_response(RESULT_BAD_SOURCE, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (!session_matches) begin
            queue_response(RESULT_BAD_SESSION, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (transaction_old) begin
            queue_response(RESULT_OLD_TRANSACTION, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else begin
            case (request_byte(47))
              OP_START: begin
                if (session_state == SESSION_READY) begin
                  start_request <= 1'b1;
                  session_state <= SESSION_RUNNING;
                  queue_response(RESULT_OK, {4'd0, SESSION_RUNNING}, 32'd0, 1'b1);
                end else begin
                  queue_response(RESULT_INVALID_STATE, {4'd0, session_state},
                                 session_fault_reason, 1'b1);
                end
              end

              OP_STOP: begin
                if (session_state == SESSION_RUNNING) begin
                  stop_request <= 1'b1;
                  session_state <= SESSION_STOPPING;
                  queue_response(RESULT_OK, {4'd0, SESSION_STOPPING}, 32'd0, 1'b1);
                end else if (session_state == SESSION_STOPPING ||
                             session_state == SESSION_CLOSED) begin
                  queue_response(RESULT_OK, {4'd0, session_state}, 32'd0, 1'b1);
                end else begin
                  queue_response(RESULT_INVALID_STATE, {4'd0, session_state},
                                 session_fault_reason, 1'b1);
                end
              end

              OP_ABORT: begin
                if (session_state == SESSION_FAULTED) begin
                  queue_response(RESULT_OK, {4'd0, SESSION_FAULTED},
                                 session_fault_reason, 1'b1);
                end else begin
                  abort_request <= 1'b1;
                  session_state <= SESSION_FAULT_QUIESCING;
                  queue_response(RESULT_OK, {4'd0, SESSION_FAULT_QUIESCING},
                                 session_fault_reason, 1'b1);
                end
              end

              OP_STATUS: begin
                queue_response(RESULT_OK, {4'd0, session_state},
                               session_fault_reason, 1'b1);
              end

              default: begin
                queue_response(RESULT_INVALID_STATE, {4'd0, session_state},
                               session_fault_reason, 1'b1);
              end
            endcase
          end
        end

        CTRL_CONFIG_PARSE: begin
          request_remote_qpn_value = request_be32(62);
          request_local_psn_value = request_be32(66);
          request_remote_base_value = request_be64(70);
          request_commit_address_value = request_be64(102);
          request_flags_value = request_be32(110);

          cfg_remote_mac <= request_be48(6);
          cfg_remote_ip <= request_be32(26);
          cfg_remote_qpn <= request_remote_qpn_value[23:0];
          cfg_local_psn <= request_local_psn_value[23:0];
          cfg_remote_base <= request_remote_base_value[47:0];
          cfg_rkey <= request_be32(78);
          cfg_ring_size <= request_be32(82);
          cfg_wr_size <= request_be32(86);
          cfg_notify_interval_bytes <= request_be32(90);
          cfg_local_base <= request_be64(94);
          cfg_commit_remote_addr <= request_commit_address_value[47:0];
          cfg_enable_immediate <= request_flags_value[0];

          config_session_valid <= request_be64(50) != 64'd0;
          config_qpn_valid <= request_remote_qpn_value != 32'd0 &&
                              request_remote_qpn_value[31:24] == 8'd0;
          config_psn_valid <= request_local_psn_value != 32'd0 &&
                             request_local_psn_value[31:24] == 8'd0;
          config_rkey_valid <= request_be32(78) != 32'd0;
          config_ring_valid <= request_be32(82) == 32'h4000_0000;
          config_wr_valid <= request_be32(86) == 32'h00A0_0000;
          config_notify_valid <= request_be32(90) == 32'h00A0_0000;
          config_local_base_valid <= request_be64(94) == 64'd0;
          config_flags_valid <=
            (request_flags_value & 32'hFFFF_FFFE) == 32'd0 &&
            request_be32(114) == 32'd0;
          config_address_shape_valid <=
            request_remote_base_value[63:48] == 16'd0 &&
            request_commit_address_value[63:48] == 16'd0 &&
            request_commit_address_value[5:0] == 6'd0;
          config_expected_commit_address <=
            {1'b0, request_remote_base_value} + {33'd0, request_be32(82)};
          config_commit_address_value <= request_commit_address_value;
          control_state <= CTRL_CONFIG_ADDRESS;
        end

        CTRL_CONFIG_ADDRESS: begin
          config_address_valid <= config_address_shape_valid &&
            !config_expected_commit_address[64] &&
            config_commit_address_value == config_expected_commit_address[63:0];
          control_state <= CTRL_CONFIG_VALIDATE;
        end

        CTRL_CONFIG_VALIDATE: begin
          if (!(config_session_valid && config_qpn_valid && config_psn_valid &&
                config_rkey_valid && config_ring_valid && config_wr_valid &&
                config_notify_valid && config_local_base_valid &&
                config_flags_valid && config_address_valid)) begin
            queue_response(RESULT_INVALID_CONFIG, {4'd0, session_state},
                           32'h0000_0001, 1'b0);
          end else if (!cfg_ready) begin
            queue_response(RESULT_BUSY, {4'd0, session_state}, 32'd0, 1'b0);
          end else begin
            source_bound <= 1'b1;
            bound_remote_mac <= cfg_remote_mac;
            bound_remote_ip <= cfg_remote_ip;
            bound_remote_port <= request_be16(34);
            bound_session_id <= request_be64(50);
            cache_valid <= 1'b0;
            session_fault_reason <= 32'd0;
            cfg_valid <= 1'b1;
            session_state <= SESSION_CONFIGURING;
            control_state <= CTRL_WAIT_CONFIG;
          end
        end

        CTRL_WAIT_CONFIG: begin
          if (cfg_done) begin
            if (cfg_accepted) begin
              config_generation <= config_generation + 32'd1;
              session_state <= SESSION_READY;
              queue_response(RESULT_OK, {4'd0, SESSION_READY}, 32'd0, 1'b1);
              response_config_generation <= config_generation + 32'd1;
            end else begin
              source_bound <= 1'b0;
              bound_session_id <= 64'd0;
              session_state <= SESSION_IDLE;
              queue_response(RESULT_INVALID_CONFIG, {4'd0, SESSION_IDLE},
                             cfg_reject_reason, 1'b0);
            end
          end
        end

        CTRL_RESPONSE_BUILD: begin
          built_word0 = 512'd0;
          built_word0[0 * 8 +: 48] = store_be48(response_remote_mac);
          built_word0[6 * 8 +: 48] = store_be48(LOCAL_MAC);
          built_word0[12 * 8 +: 16] = store_be16(16'h0800);
          built_word0[14 * 8 +: 8] = 8'h45;
          built_word0[16 * 8 +: 16] = store_be16(RESPONSE_IP_LENGTH);
          built_word0[18 * 8 +: 16] = store_be16(response_ip_id);
          built_word0[22 * 8 +: 8] = 8'd64;
          built_word0[23 * 8 +: 8] = 8'd17;
          built_word0[26 * 8 +: 32] = store_be32(LOCAL_IP);
          built_word0[30 * 8 +: 32] = store_be32(response_remote_ip);
          built_word0[34 * 8 +: 16] = store_be16(CONTROL_PORT);
          built_word0[36 * 8 +: 16] = store_be16(response_remote_port);
          built_word0[38 * 8 +: 16] = store_be16(RESPONSE_UDP_LENGTH);
          built_word0[42 * 8 +: 32] = store_be32(RDCP_MAGIC);
          built_word0[46 * 8 +: 8] = RDCP_VERSION;
          built_word0[47 * 8 +: 8] = response_opcode_value;
          built_word0[48 * 8 +: 16] = store_be16(16'd64);
          built_word0[50 * 8 +: 64] = store_be64(response_session_id);
          built_word0[58 * 8 +: 32] = store_be32(response_transaction_id);
          built_word0[62 * 8 +: 16] = store_be16(response_result);

          built_word1 = 512'd0;
          built_word1[0 * 8 +: 8] = response_session_state;
          built_word1[2 * 8 +: 32] = store_be32(response_reason);
          built_word1[6 * 8 +: 32] = store_be32(response_status_bits);
          built_word1[10 * 8 +: 32] = store_be32({8'd0, LOCAL_QPN});
          built_word1[14 * 8 +: 32] =
            store_be32({8'd0, response_current_psn});
          built_word1[18 * 8 +: 32] =
            store_be32(response_config_generation);
          built_word1[22 * 8 +: 64] = store_be64(response_issued_bytes);
          built_word1[30 * 8 +: 64] = store_be64(response_acked_bytes);
          built_word1[38 * 8 +: 64] = store_be64(response_published_bytes);
          built_word1[46 * 8 +: 64] =
            store_be64(response_producer_sequence);
          built_word1[54 * 8 +: 32] = store_be32(CAPABILITIES);
          built_word1[58 * 8 +: 32] = store_be32(PMTU_BYTES);

          response_word0 <= built_word0;
          response_word1 <= built_word1;
          checksum_sum <= 32'd0;
          checksum_shift <= built_word0 >> 112;
          checksum_words_left <= 6'd10;
          checksum_first_words_left <= 4'd0;
          control_state <= CTRL_RESPONSE_IP_CHECKSUM;
        end

        CTRL_RESPONSE_IP_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          checksum_shift <= checksum_shift >> 16;
          checksum_words_left <= checksum_words_left - 6'd1;
          if (checksum_words_left == 6'd1)
            control_state <= CTRL_RESPONSE_IP_CHECKSUM_DONE;
        end

        CTRL_RESPONSE_IP_CHECKSUM_DONE: begin
          checksum_value = ~fold_checksum(checksum_sum);
          completed_word = response_word0;
          completed_word[24 * 8 +: 16] = store_be16(checksum_value);
          response_word0 <= completed_word;
          checksum_sum <= 32'd0;
          checksum_shift <= {
            416'd0,
            store_be16(RESPONSE_UDP_LENGTH),
            16'h1100,
            store_be32(response_remote_ip),
            store_be32(LOCAL_IP)
          };
          checksum_words_left <= 6'd6;
          control_state <= CTRL_RESPONSE_UDP_PSEUDO_CHECKSUM;
        end

        CTRL_RESPONSE_UDP_PSEUDO_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          if (checksum_words_left == 6'd1) begin
            checksum_shift <= response_word0 >> 272;
            checksum_words_left <= 6'd46;
            checksum_first_words_left <= 4'd15;
            control_state <= CTRL_RESPONSE_UDP_CHECKSUM;
          end else begin
            checksum_shift <= checksum_shift >> 16;
            checksum_words_left <= checksum_words_left - 6'd1;
          end
        end

        CTRL_RESPONSE_UDP_CHECKSUM: begin
          checksum_word = {checksum_shift[7:0], checksum_shift[15:8]};
          checksum_sum <= checksum_sum + checksum_word;
          if (checksum_words_left == 6'd1) begin
            checksum_words_left <= 6'd0;
            control_state <= CTRL_RESPONSE_UDP_CHECKSUM_DONE;
          end else begin
            checksum_words_left <= checksum_words_left - 6'd1;
            if (checksum_first_words_left == 4'd1) begin
              checksum_shift <= response_word1;
              checksum_first_words_left <= 4'd0;
            end else begin
              checksum_shift <= checksum_shift >> 16;
              if (checksum_first_words_left != 4'd0)
                checksum_first_words_left <= checksum_first_words_left - 4'd1;
            end
          end
        end

        CTRL_RESPONSE_UDP_CHECKSUM_DONE: begin
          checksum_value = ~fold_checksum(checksum_sum);
          if (checksum_value == 16'd0)
            checksum_value = 16'hFFFF;
          completed_word = response_word0;
          completed_word[40 * 8 +: 16] = store_be16(checksum_value);
          response_word0 <= completed_word;
          control_state <= CTRL_RESPONSE_FINALIZE;
        end

        CTRL_RESPONSE_FINALIZE: begin
          if (response_cache_enable) begin
            cache_word0 <= response_word0;
            cache_word1 <= response_word1;
            cache_valid <= 1'b1;
          end
          control_state <= CTRL_RESPONSE_SEND_FIRST;
        end

        CTRL_RESPONSE_SEND_FIRST: begin
          if (m_axis_tvalid && m_axis_tready)
            control_state <= CTRL_RESPONSE_SEND_SECOND;
        end

        CTRL_RESPONSE_SEND_SECOND: begin
          if (m_axis_tvalid && m_axis_tready)
            control_state <= CTRL_RX_FIRST;
        end

        default: control_state <= CTRL_RX_FIRST;
      endcase
    end
  end
endmodule
