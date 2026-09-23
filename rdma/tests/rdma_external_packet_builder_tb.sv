`timescale 1ps / 1ps

module cmac_usplus_0_rdma_external_packet_builder_tb;
  localparam integer PAYLOAD_BYTES = 4096;
  localparam integer PAYLOAD_BEATS = PAYLOAD_BYTES / 64;
  localparam integer FRAME_BYTES = 14 + 20 + 8 + 12 + 16 + PAYLOAD_BYTES + 4;
  localparam integer FRAME_BEATS = (FRAME_BYTES + 63) / 64;
  localparam logic [31:0] ICRC_INIT = 32'hDEBB_20E3;

  logic clk = 1'b0;
  logic reset = 1'b1;
  logic start = 1'b0;
  logic busy;
  logic done;
  logic header_has_reth;
  logic [511:0] header_word0;
  logic [47:0] header_word1_prefix;
  logic payload_read_enable;
  logic [5:0] payload_read_address;
  logic [511:0] payload_read_data;
  logic packet_write_enable;
  logic [6:0] packet_write_address;
  logic [511:0] packet_write_data;
  logic [63:0] packet_write_keep;
  logic packet_write_last;
  logic [31:0] packet_icrc;
  logic [399:0] crc_header_data;
  logic [31:0] crc_header_result;
  logic [31:0] crc_body_seed;
  logic [511:0] crc_body_data;
  logic [31:0] crc_body_result;
  logic [31:0] crc_tail_seed;
  logic [47:0] crc_tail_data;
  logic [31:0] crc_tail_result;
  logic [31:0] crc_tail54_seed;
  logic [431:0] crc_tail54_data;
  logic [31:0] crc_tail54_result;

  logic [511:0] payload_memory [PAYLOAD_BEATS];
  logic [511:0] captured_data [FRAME_BEATS];
  logic [63:0] captured_keep [FRAME_BEATS];
  logic captured_last [FRAME_BEATS];

  always #2 clk = !clk;

  always_ff @(posedge clk) begin
    if (reset)
      payload_read_data <= 512'd0;
    else if (payload_read_enable)
      payload_read_data <= payload_memory[payload_read_address];
    if (packet_write_enable) begin
      captured_data[packet_write_address] <= packet_write_data;
      captured_keep[packet_write_address] <= packet_write_keep;
      captured_last[packet_write_address] <= packet_write_last;
    end
  end

  cmac_usplus_0_rdma_external_packet_builder dut (
    .clk(clk),
    .reset(reset),
    .start(start),
    .busy(busy),
    .done(done),
    .header_has_reth(header_has_reth),
    .header_word0(header_word0),
    .header_word1_prefix(header_word1_prefix),
    .payload_read_enable(payload_read_enable),
    .payload_read_address(payload_read_address),
    .payload_read_data(payload_read_data),
    .packet_write_enable(packet_write_enable),
    .packet_write_address(packet_write_address),
    .packet_write_data(packet_write_data),
    .packet_write_keep(packet_write_keep),
    .packet_write_last(packet_write_last),
    .packet_icrc(packet_icrc),
    .crc_header_data(crc_header_data),
    .crc_header_result(crc_header_result),
    .crc_body_seed(crc_body_seed),
    .crc_body_data(crc_body_data),
    .crc_body_result(crc_body_result),
    .crc_tail_seed(crc_tail_seed),
    .crc_tail_data(crc_tail_data),
    .crc_tail_result(crc_tail_result),
    .crc_tail54_seed(crc_tail54_seed),
    .crc_tail54_data(crc_tail54_data),
    .crc_tail54_result(crc_tail54_result)
  );

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(50)) i_crc_header (
    .crc_in(ICRC_INIT),
    .data_in(crc_header_data),
    .crc_out(crc_header_result)
  );

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(64)) i_crc_body (
    .crc_in(crc_body_seed),
    .data_in(crc_body_data),
    .crc_out(crc_body_result)
  );

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(6)) i_crc_tail (
    .crc_in(crc_tail_seed),
    .data_in(crc_tail_data),
    .crc_out(crc_tail_result)
  );

  cmac_usplus_0_rdma_crc32_parallel #(.DATA_BYTES(54)) i_crc_tail54 (
    .crc_in(crc_tail54_seed),
    .data_in(crc_tail54_data),
    .crc_out(crc_tail54_result)
  );

  function automatic logic [7:0] payload_byte(input integer index);
    payload_byte = ((index * 29) + 8'h53) & 8'hFF;
  endfunction

  function automatic logic [7:0] frame_byte_before_icrc(
    input integer index,
    input logic has_reth
  );
    integer header_bytes;
    begin
      header_bytes = has_reth ? 70 : 54;
    if (index < header_bytes && index < 64)
      frame_byte_before_icrc = header_word0[index * 8 +: 8];
    else if (index < header_bytes)
      frame_byte_before_icrc = header_word1_prefix[(index - 64) * 8 +: 8];
    else
      frame_byte_before_icrc = payload_byte(index - header_bytes);
    end
  endfunction

  function automatic logic [7:0] captured_byte(input integer index);
    captured_byte = captured_data[index / 64][(index % 64) * 8 +: 8];
  endfunction

  function automatic logic [31:0] crc32_byte_ref(
    input logic [31:0] seed,
    input logic [7:0] data_byte
  );
    logic [31:0] crc;
    integer bit_index;
    begin
      crc = seed ^ {24'd0, data_byte};
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
      crc32_byte_ref = crc;
    end
  endfunction

  integer beat;
  integer lane;
  integer index;
  integer cycles;
  integer frame_bytes;
  integer frame_beats;
  integer case_index;
  logic [7:0] reference_byte;
  logic [31:0] reference_crc;
  logic [31:0] reference_icrc;
  initial begin
    header_has_reth = 1'b1;
    header_word0 = 512'd0;
    header_word1_prefix = 48'd0;
    for (lane = 0; lane < 64; lane = lane + 1)
      header_word0[lane * 8 +: 8] = lane + 8'h21;
    for (lane = 0; lane < 6; lane = lane + 1)
      header_word1_prefix[lane * 8 +: 8] = lane + 8'hA1;
    for (beat = 0; beat < PAYLOAD_BEATS; beat = beat + 1) begin
      payload_memory[beat] = 512'd0;
      for (lane = 0; lane < 64; lane = lane + 1)
        payload_memory[beat][lane * 8 +: 8] = payload_byte(beat * 64 + lane);
    end
    for (beat = 0; beat < FRAME_BEATS; beat = beat + 1) begin
      captured_data[beat] = 512'd0;
      captured_keep[beat] = 64'd0;
      captured_last[beat] = 1'b0;
    end

    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    for (case_index = 0; case_index < 2; case_index = case_index + 1) begin
      header_has_reth = case_index == 0;
      frame_bytes = (header_has_reth ? 70 : 54) + PAYLOAD_BYTES + 4;
      frame_beats = (frame_bytes + 63) / 64;
      for (beat = 0; beat < FRAME_BEATS; beat = beat + 1) begin
        captured_data[beat] = 512'd0;
        captured_keep[beat] = 64'd0;
        captured_last[beat] = 1'b0;
      end

      start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      start = 1'b0;

      cycles = 0;
      while (!done && cycles < 100) begin
        @(posedge clk);
        cycles = cycles + 1;
      end
      if (!done)
        $fatal(1, "packet builder did not complete");
      if (cycles > 70)
        $fatal(1, "packet builder exceeded beat-level cycle budget: %0d", cycles);

      reference_crc = ICRC_INIT;
      for (index = 14; index < frame_bytes - 4; index = index + 1) begin
        reference_byte = frame_byte_before_icrc(index, header_has_reth);
        case (index - 14)
          1, 8, 10, 11, 26, 27, 32: reference_byte = 8'hFF;
          default: reference_byte = reference_byte;
        endcase
        reference_crc = crc32_byte_ref(reference_crc, reference_byte);
      end
      reference_icrc = ~reference_crc;

      for (index = 0; index < frame_bytes - 4; index = index + 1) begin
        if (captured_byte(index) !=
            frame_byte_before_icrc(index, header_has_reth))
          $fatal(1, "packet byte %0d mismatch: got %02h expected %02h",
                 index, captured_byte(index),
                 frame_byte_before_icrc(index, header_has_reth));
      end
      for (index = 0; index < 4; index = index + 1) begin
        if (captured_byte(frame_bytes - 4 + index) !=
            reference_icrc[index * 8 +: 8])
          $fatal(1, "ICRC byte %0d mismatch", index);
      end
      if (packet_icrc != reference_icrc)
        $fatal(1, "packet ICRC output mismatch");

      for (beat = 0; beat < frame_beats - 1; beat = beat + 1) begin
        if (captured_keep[beat] != 64'hFFFF_FFFF_FFFF_FFFF ||
            captured_last[beat])
          $fatal(1, "full packet beat %0d shape mismatch", beat);
      end
      if (captured_keep[frame_beats-1] !=
            (header_has_reth ? 64'h0000_0000_0000_03FF :
                               64'h03FF_FFFF_FFFF_FFFF) ||
          !captured_last[frame_beats-1])
        $fatal(1, "last packet beat shape mismatch");
    end

    $display("cmac_usplus_0_rdma_external_packet_builder_tb PASS");
    $finish;
  end
endmodule
