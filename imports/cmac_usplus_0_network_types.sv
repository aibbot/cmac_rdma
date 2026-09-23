`timescale 1ps / 1ps

// verilog_lint: waive package-filename
package cmac_usplus_0_network_types_pkg;

  // A descriptor is immutable from the first beat of a UDP frame through
  // its final handshake. One shared producer supplies all UDP streams.
  typedef struct packed {
    logic [31:0] generation;
    logic [47:0] destination_mac;
    logic [31:0] local_ip;
    logic [31:0] destination_ip;
    logic [15:0] source_port;
    logic [15:0] destination_port;
    logic [15:0] payload_length;
    logic [15:0] ip_total_length;
    logic [15:0] udp_length;
    logic [15:0] ip_checksum;
    logic [31:0] gap_cycles;
    logic [7:0]  last_word_index;
    logic [63:0] last_word_keep;
  } udp_frame_descriptor_t;

endpackage
