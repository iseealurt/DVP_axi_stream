`timescale 1ns/1ps
`include "AXI4-lite.sv"

module tb_DVP2axi_stream_v_1_0;
  // ------------------------------ Parameters ------------------------------
  parameter DVP_DWIDTH = 8 ;
  parameter PIX_WIDTH = 16 ;
  parameter AXI_ID_WIDTH = 4 ;
  parameter AXI_STREAM_TID = 1 ;
  parameter AXI_STREAM_DWIDTH = 256 ;
  localparam AXI_STREAM_STRB_WIDTH = AXI_STREAM_DWIDTH/8 ;
  parameter AXI_STREAM_USER_WIDTH = 4 ;
  parameter AXI_STREAM_TDEST_WIDTH = 4 ;
  parameter AXI_LITE_DWIDTH = 32 ;
  localparam AXI_LITE_STRB_WIDTH = AXI_LITE_DWIDTH/8 ;
  parameter AXI_LITE_AWIDTH = 32 ;
  parameter AXI_LITE_BASE_ADDR_OFFSET = 32'h0000_0000 ;

  // ------------------------------ Imported packages ------------------------------
  import axil_test_pkg::*;
  // ------------------------------ DUT ------------------------------
  
endmodule