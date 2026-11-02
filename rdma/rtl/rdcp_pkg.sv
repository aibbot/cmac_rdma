`timescale 1ps / 1ps

package rdcp_pkg;
  localparam logic [31:0] RDCP_MAGIC = 32'h5244_4350;
  localparam logic [7:0] RDCP_VERSION = 8'd2;
  localparam logic [15:0] RDCP_CONTROL_PORT = 16'd4792;

  localparam logic [7:0] RDCP_OP_HELLO = 8'd1;
  localparam logic [7:0] RDCP_OP_CONFIG = 8'd2;
  localparam logic [7:0] RDCP_OP_START = 8'd3;
  localparam logic [7:0] RDCP_OP_STOP = 8'd4;
  localparam logic [7:0] RDCP_OP_ABORT = 8'd5;
  localparam logic [7:0] RDCP_OP_STATUS = 8'd6;
  localparam logic [7:0] RDCP_OP_CONSUME = 8'd7;

  localparam logic [15:0] RDCP_RESULT_OK = 16'd0;
  localparam logic [15:0] RDCP_RESULT_BAD_VERSION = 16'd1;
  localparam logic [15:0] RDCP_RESULT_BAD_OPCODE = 16'd2;
  localparam logic [15:0] RDCP_RESULT_BAD_LENGTH = 16'd3;
  localparam logic [15:0] RDCP_RESULT_BAD_SESSION = 16'd4;
  localparam logic [15:0] RDCP_RESULT_BAD_SOURCE = 16'd5;
  localparam logic [15:0] RDCP_RESULT_OLD_TRANSACTION = 16'd6;
  localparam logic [15:0] RDCP_RESULT_BUSY = 16'd7;
  localparam logic [15:0] RDCP_RESULT_INVALID_CONFIG = 16'd8;
  localparam logic [15:0] RDCP_RESULT_INVALID_STATE = 16'd9;
  localparam logic [15:0] RDCP_RESULT_INVALID_PROGRESS = 16'd10;

  localparam logic [3:0] RDCP_SESSION_IDLE = 4'd0;
  localparam logic [3:0] RDCP_SESSION_CONFIGURING = 4'd1;
  localparam logic [3:0] RDCP_SESSION_READY = 4'd2;
  localparam logic [3:0] RDCP_SESSION_RUNNING = 4'd3;
  localparam logic [3:0] RDCP_SESSION_STOPPING = 4'd4;
  localparam logic [3:0] RDCP_SESSION_CLOSED = 4'd5;
  localparam logic [3:0] RDCP_SESSION_FAULT_QUIESCING = 4'd6;
  localparam logic [3:0] RDCP_SESSION_FAULTED = 4'd7;

  typedef struct packed {
    logic [511:0] word0;
    logic [511:0] word1;
    logic [15:0] udp_length;
    logic [15:0] payload_length;
  } rdcp_validated_request_t;

  // Numeric views of the fixed RDCP fields.  The byte-order conversion is
  // kept at these two packet boundaries; users of the descriptors deal only
  // with naturally sized fields.
  typedef struct packed {
    logic [31:0] magic;
    logic [7:0] version;
    logic [7:0] opcode;
    logic [15:0] payload_length;
    logic [63:0] session_id;
    logic [31:0] transaction_id;
  } rdcp_wire_header_t;

  typedef struct packed {
    logic [31:0] remote_qpn;
    logic [31:0] local_psn;
    logic [63:0] remote_base;
    logic [31:0] rkey;
    logic [31:0] ring_size;
    logic [31:0] wr_size;
    logic [31:0] notify_interval_bytes;
    logic [63:0] local_base;
    logic [63:0] commit_address;
    logic [31:0] flags;
    logic [31:0] reserved;
  } rdcp_wire_config_t;

  typedef struct packed {
    logic [15:0] result;
    logic [7:0] state;
    logic [7:0] reserved;
    logic [31:0] reason;
    logic [31:0] status_bits;
    logic [31:0] local_qpn;
    logic [31:0] current_psn;
    logic [31:0] config_generation;
    logic [63:0] issued_bytes;
    logic [63:0] acked_bytes;
    logic [63:0] published_bytes;
    logic [63:0] consumed_bytes;
    logic [31:0] capabilities;
    logic [31:0] pmtu_bytes;
  } rdcp_wire_status_t;

  typedef struct packed {
    logic [47:0] remote_mac;
    logic [31:0] remote_ip;
    logic [15:0] remote_port;
    logic [63:0] session_id;
    logic [31:0] transaction_id;
    logic [7:0] opcode;
  } rdcp_request_identity_t;

  typedef rdcp_request_identity_t rdcp_response_source_t;

  typedef rdcp_wire_config_t rdcp_config_request_t;

  typedef struct packed {
    rdcp_request_identity_t identity;
    logic [15:0] parse_result;
    rdcp_config_request_t config_fields;
  } rdcp_request_descriptor_t;

  typedef struct packed {
    rdcp_response_source_t source;
    logic [15:0] result;
    logic [7:0] session_state;
    logic [31:0] reason;
    logic [31:0] status_bits;
    logic [23:0] current_psn;
    logic [31:0] config_generation;
    logic [63:0] issued_bytes;
    logic [63:0] acked_bytes;
    logic [63:0] published_bytes;
    logic [63:0] consumed_bytes;
    logic cache_enable;
  } rdcp_response_descriptor_t;

  typedef struct packed {
    logic configured;
    logic active;
    logic stopping;
    logic drained;
    logic fault;
    logic [31:0] fault_reason;
    logic final_commit_acked;
    logic [23:0] current_psn;
    logic [63:0] issued_bytes;
    logic [63:0] acked_bytes;
    logic [63:0] published_bytes;
    logic credit_stalled;
  } rdcp_endpoint_status_t;

  function automatic logic [7:0] rdcp_load_be8(
    input logic [1023:0] words,
    input integer index
  );
    rdcp_load_be8 = words[index * 8 +: 8];
  endfunction

  function automatic logic [15:0] rdcp_load_be16(
    input logic [1023:0] words,
    input integer index
  );
    rdcp_load_be16 = {rdcp_load_be8(words, index),
                      rdcp_load_be8(words, index + 1)};
  endfunction

  function automatic logic [31:0] rdcp_load_be32(
    input logic [1023:0] words,
    input integer index
  );
    rdcp_load_be32 = {rdcp_load_be16(words, index),
                      rdcp_load_be16(words, index + 2)};
  endfunction

  function automatic logic [47:0] rdcp_load_be48(
    input logic [1023:0] words,
    input integer index
  );
    rdcp_load_be48 = {rdcp_load_be16(words, index),
                      rdcp_load_be32(words, index + 2)};
  endfunction

  function automatic logic [63:0] rdcp_load_be64(
    input logic [1023:0] words,
    input integer index
  );
    rdcp_load_be64 = {rdcp_load_be32(words, index),
                      rdcp_load_be32(words, index + 4)};
  endfunction

  function automatic rdcp_wire_header_t rdcp_decode_header(
    input logic [1023:0] words
  );
    rdcp_wire_header_t decoded;
    begin
      decoded = '0;
      decoded.magic = rdcp_load_be32(words, 42);
      decoded.version = rdcp_load_be8(words, 46);
      decoded.opcode = rdcp_load_be8(words, 47);
      decoded.payload_length = rdcp_load_be16(words, 48);
      decoded.session_id = rdcp_load_be64(words, 50);
      decoded.transaction_id = rdcp_load_be32(words, 58);
      rdcp_decode_header = decoded;
    end
  endfunction

  function automatic rdcp_wire_config_t rdcp_decode_config(
    input logic [1023:0] words
  );
    rdcp_wire_config_t decoded;
    begin
      decoded = '0;
      decoded.remote_qpn = rdcp_load_be32(words, 62);
      decoded.local_psn = rdcp_load_be32(words, 66);
      decoded.remote_base = rdcp_load_be64(words, 70);
      decoded.rkey = rdcp_load_be32(words, 78);
      decoded.ring_size = rdcp_load_be32(words, 82);
      decoded.wr_size = rdcp_load_be32(words, 86);
      decoded.notify_interval_bytes = rdcp_load_be32(words, 90);
      decoded.local_base = rdcp_load_be64(words, 94);
      decoded.commit_address = rdcp_load_be64(words, 102);
      decoded.flags = rdcp_load_be32(words, 110);
      decoded.reserved = rdcp_load_be32(words, 114);
      rdcp_decode_config = decoded;
    end
  endfunction

  function automatic logic [15:0] rdcp_store_be16(
    input logic [15:0] value
  );
    rdcp_store_be16 = {value[7:0], value[15:8]};
  endfunction

  function automatic logic [31:0] rdcp_store_be32(
    input logic [31:0] value
  );
    rdcp_store_be32 = {
      value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  function automatic logic [47:0] rdcp_store_be48(
    input logic [47:0] value
  );
    rdcp_store_be48 = {
      value[7:0], value[15:8], value[23:16],
      value[31:24], value[39:32], value[47:40]};
  endfunction

  function automatic logic [63:0] rdcp_store_be64(
    input logic [63:0] value
  );
    rdcp_store_be64 = {
      value[7:0], value[15:8], value[23:16], value[31:24],
      value[39:32], value[47:40], value[55:48], value[63:56]};
  endfunction

  function automatic logic [159:0] rdcp_encode_header(
    input rdcp_wire_header_t header
  );
    logic [159:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 32] = rdcp_store_be32(header.magic);
      encoded[32 +: 8] = header.version;
      encoded[40 +: 8] = header.opcode;
      encoded[48 +: 16] = rdcp_store_be16(header.payload_length);
      encoded[64 +: 64] = rdcp_store_be64(header.session_id);
      encoded[128 +: 32] = rdcp_store_be32(header.transaction_id);
      rdcp_encode_header = encoded;
    end
  endfunction

  function automatic logic [447:0] rdcp_encode_config(
    input rdcp_wire_config_t config_fields
  );
    logic [447:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 32] = rdcp_store_be32(config_fields.remote_qpn);
      encoded[32 +: 32] = rdcp_store_be32(config_fields.local_psn);
      encoded[64 +: 64] = rdcp_store_be64(config_fields.remote_base);
      encoded[128 +: 32] = rdcp_store_be32(config_fields.rkey);
      encoded[160 +: 32] = rdcp_store_be32(config_fields.ring_size);
      encoded[192 +: 32] = rdcp_store_be32(config_fields.wr_size);
      encoded[224 +: 32] = rdcp_store_be32(config_fields.notify_interval_bytes);
      encoded[256 +: 64] = rdcp_store_be64(config_fields.local_base);
      encoded[320 +: 64] = rdcp_store_be64(config_fields.commit_address);
      encoded[384 +: 32] = rdcp_store_be32(config_fields.flags);
      encoded[416 +: 32] = rdcp_store_be32(config_fields.reserved);
      rdcp_encode_config = encoded;
    end
  endfunction

  function automatic logic [511:0] rdcp_encode_status(
    input rdcp_wire_status_t status
  );
    logic [511:0] encoded;
    begin
      encoded = '0;
      encoded[0 +: 16] = rdcp_store_be16(status.result);
      encoded[16 +: 8] = status.state;
      encoded[24 +: 8] = status.reserved;
      encoded[32 +: 32] = rdcp_store_be32(status.reason);
      encoded[64 +: 32] = rdcp_store_be32(status.status_bits);
      encoded[96 +: 32] = rdcp_store_be32(status.local_qpn);
      encoded[128 +: 32] = rdcp_store_be32(status.current_psn);
      encoded[160 +: 32] = rdcp_store_be32(status.config_generation);
      encoded[192 +: 64] = rdcp_store_be64(status.issued_bytes);
      encoded[256 +: 64] = rdcp_store_be64(status.acked_bytes);
      encoded[320 +: 64] = rdcp_store_be64(status.published_bytes);
      encoded[384 +: 64] = rdcp_store_be64(status.consumed_bytes);
      encoded[448 +: 32] = rdcp_store_be32(status.capabilities);
      encoded[480 +: 32] = rdcp_store_be32(status.pmtu_bytes);
      rdcp_encode_status = encoded;
    end
  endfunction

  function automatic logic [63:0] rdcp_keep_mask(
    input logic [6:0] byte_count
  );
    if (byte_count >= 7'd64)
      rdcp_keep_mask = 64'hFFFF_FFFF_FFFF_FFFF;
    else if (byte_count == 7'd0)
      rdcp_keep_mask = 64'd0;
    else
      rdcp_keep_mask = ~(64'hFFFF_FFFF_FFFF_FFFF << byte_count);
  endfunction

  function automatic logic [15:0] rdcp_fold_checksum(
    input logic [31:0] value
  );
    logic [16:0] first_fold;
    logic [16:0] second_fold;
    begin
      first_fold = {1'b0, value[15:0]} + {1'b0, value[31:16]};
      second_fold = {1'b0, first_fold[15:0]} + {16'd0, first_fold[16]};
      rdcp_fold_checksum =
        second_fold[15:0] + {15'd0, second_fold[16]};
    end
  endfunction

endpackage
