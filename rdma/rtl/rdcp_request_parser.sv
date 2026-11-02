`timescale 1ps / 1ps

module rdcp_request_parser (
  input  logic         clk,
  input  logic         reset,

  input  logic         request_valid,
  output logic         request_ready,
  input  rdcp_pkg::rdcp_validated_request_t request,

  output logic         parsed_request_valid,
  input  logic         parsed_request_ready,
  output rdcp_pkg::rdcp_request_descriptor_t parsed_request
);
  import rdcp_pkg::*;

  rdcp_request_descriptor_t decoded_request;
  logic [1023:0] request_words;
  rdcp_wire_header_t decoded_header;
  rdcp_wire_config_t decoded_config;

  // RX_VALIDATE holds the complete request in RX_HOLD, so parsing can remain
  // combinational without adding another copy of the packed descriptor.
  assign request_ready = parsed_request_ready;
  assign parsed_request_valid = request_valid;
  assign parsed_request = decoded_request;

  always_comb begin
    decoded_request = '0;
    request_words = {request.word1, request.word0};
    decoded_header = rdcp_decode_header(request_words);
    decoded_config = rdcp_decode_config(request_words);

    decoded_request.identity.remote_mac = rdcp_load_be48(request_words, 6);
    decoded_request.identity.remote_ip = rdcp_load_be32(request_words, 26);
    decoded_request.identity.remote_port = rdcp_load_be16(request_words, 34);
    decoded_request.identity.opcode = decoded_header.opcode;
    decoded_request.identity.session_id = decoded_header.session_id;
    decoded_request.identity.transaction_id = decoded_header.transaction_id;
    decoded_request.config_fields = decoded_config;
    decoded_request.parse_result = RDCP_RESULT_OK;
    if (decoded_header.version != RDCP_VERSION)
      decoded_request.parse_result = RDCP_RESULT_BAD_VERSION;
    else if (decoded_request.identity.opcode < RDCP_OP_HELLO ||
             decoded_request.identity.opcode > RDCP_OP_CONSUME)
      decoded_request.parse_result = RDCP_RESULT_BAD_OPCODE;
    else if (decoded_header.magic != RDCP_MAGIC ||
             request.payload_length != request.udp_length - 16'd28 ||
             (decoded_request.identity.opcode == RDCP_OP_CONFIG &&
              request.payload_length != 16'd56) ||
             (decoded_request.identity.opcode == RDCP_OP_CONSUME &&
              request.payload_length != 16'd8) ||
             (decoded_request.identity.opcode != RDCP_OP_CONFIG &&
              decoded_request.identity.opcode != RDCP_OP_CONSUME &&
              request.payload_length != 16'd0))
      decoded_request.parse_result = RDCP_RESULT_BAD_LENGTH;
  end

  // clk/reset are retained in the internal module signature for source-level
  // integration stability; RX_VALIDATE provides the required storage.
endmodule
