`timescale 1ps / 1ps

module cmac_usplus_0_rdcp_request_parser (
  input  logic         clk,
  input  logic         reset,

  input  logic         request_valid,
  output logic         request_ready,
  input  cmac_usplus_0_rdcp_pkg::rdcp_validated_request_t request,

  output logic         parsed_request_valid,
  input  logic         parsed_request_ready,
  output cmac_usplus_0_rdcp_pkg::rdcp_request_descriptor_t parsed_request
);
  import cmac_usplus_0_rdcp_pkg::*;

  rdcp_request_descriptor_t decoded_request;
  logic [1023:0] request_words;
  logic [7:0] decoded_version;
  logic [15:0] decoded_payload_length;

  // RX_VALIDATE holds the complete request in RX_HOLD, so parsing can remain
  // combinational without adding another copy of the packed descriptor.
  assign request_ready = parsed_request_ready;
  assign parsed_request_valid = request_valid;
  assign parsed_request = decoded_request;

  always_comb begin
    decoded_request = '0;
    request_words = {request.word1, request.word0};

    decoded_request.identity.remote_mac = rdcp_load_be48(request_words, 6);
    decoded_request.identity.remote_ip = rdcp_load_be32(request_words, 26);
    decoded_request.identity.remote_port = rdcp_load_be16(request_words, 34);
    decoded_version = rdcp_load_be8(request_words, 46);
    decoded_request.identity.opcode = rdcp_load_be8(request_words, 47);
    decoded_payload_length = request.payload_length;
    decoded_request.identity.session_id = rdcp_load_be64(request_words, 50);
    decoded_request.identity.transaction_id = rdcp_load_be32(request_words, 58);

    decoded_request.config_fields.remote_qpn = rdcp_load_be32(request_words, 62);
    decoded_request.config_fields.local_psn = rdcp_load_be32(request_words, 66);
    decoded_request.config_fields.remote_base = rdcp_load_be64(request_words, 70);
    decoded_request.config_fields.rkey = rdcp_load_be32(request_words, 78);
    decoded_request.config_fields.ring_size = rdcp_load_be32(request_words, 82);
    decoded_request.config_fields.wr_size = rdcp_load_be32(request_words, 86);
    decoded_request.config_fields.notify_interval_bytes =
      rdcp_load_be32(request_words, 90);
    decoded_request.config_fields.local_base = rdcp_load_be64(request_words, 94);
    decoded_request.config_fields.commit_address =
      rdcp_load_be64(request_words, 102);
    decoded_request.config_fields.flags = rdcp_load_be32(request_words, 110);
    decoded_request.config_fields.reserved = rdcp_load_be32(request_words, 114);
    decoded_request.parse_result = RDCP_RESULT_OK;
    if (decoded_version != RDCP_VERSION)
      decoded_request.parse_result = RDCP_RESULT_BAD_VERSION;
    else if (decoded_request.identity.opcode < RDCP_OP_HELLO ||
             decoded_request.identity.opcode > RDCP_OP_CONSUME)
      decoded_request.parse_result = RDCP_RESULT_BAD_OPCODE;
    else if (decoded_payload_length != request.udp_length - 16'd28 ||
             (decoded_request.identity.opcode == RDCP_OP_CONFIG &&
              decoded_payload_length != 16'd56) ||
             (decoded_request.identity.opcode == RDCP_OP_CONSUME &&
              decoded_payload_length != 16'd8) ||
             (decoded_request.identity.opcode != RDCP_OP_CONFIG &&
              decoded_request.identity.opcode != RDCP_OP_CONSUME &&
              decoded_payload_length != 16'd0))
      decoded_request.parse_result = RDCP_RESULT_BAD_LENGTH;
  end

  // clk/reset are retained in the internal module signature for source-level
  // integration stability; RX_VALIDATE provides the required storage.
endmodule
