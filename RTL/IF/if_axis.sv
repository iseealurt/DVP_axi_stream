`ifndef IF_AXIS_SV
`define IF_AXIS_SV

`timescale 1ns/1ps
interface mst_if_axis#(
  parameter int DWIDTH  = 32
)(
  input logic aclk ,
  input logic aresetn 
);
  localparam int STRBWIDTH = DWIDTH / 8;

  logic tready ;
  logic tvalid ;
  logic [DWIDTH-1:0] tdata ;
  logic [STRBWIDTH-1:0] tstrb ;
  logic [STRBWIDTH-1:0] tkeep ;
  logic tlast ;

  // master 侧视角：由主机驱动请求，采样从机返回
  modport mst (
    input aclk, aresetn ,
    input tready ,
    output tvalid ,tdata , tstrb , tkeep , tlast
  );

  clocking cb @(posedge aclk);
    input aclk, aresetn ;
    input tready ;
    input tvalid ,tdata , tstrb , tkeep , tlast ;
  endclocking
endinterface 

interface slv_if_axis#(
  parameter int DWIDTH  = 32 
)(
  input logic aclk ,
  input logic aresetn 
);
  localparam int STRBWIDTH = DWIDTH / 8;
  logic tready ;
  logic tvalid ;
  logic [DWIDTH-1:0] tdata ;
  logic [STRBWIDTH-1:0] tstrb ;
  logic [STRBWIDTH-1:0] tkeep ;
  logic tlast ;
  // master 侧视角：由主机驱动请求，采样从机返回
  modport slv (
    input aclk, aresetn ,
    output tready ,
    input tvalid ,tdata , tstrb , tkeep , tlast
  );

  clocking cb @(posedge aclk);
    input aclk, aresetn ;
    input tready ;
    input tvalid ,tdata , tstrb , tkeep , tlast ;
  endclocking
endinterface 
`endif