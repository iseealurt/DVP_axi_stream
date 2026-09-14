`timescale 1ns/1ps
interface mst_if_axil#(
  parameter AWIDTH = 32 ,
  parameter DWIDTH = 64 ,
  localparam STRBWIDTH = DWIDTH/8 ,
  parameter IDWIDTH = 4 
)(
  input aclk ,
  input arstn
);
  // ------------------------ write address channel ------------------------
  logic awready , awvalid ;
  logic [AWIDTH-1:0] awaddr ;
  logic [2:0] awport ;
  // ------------------------ write data channel ------------------------
  logic wvalid , wready ;
  logic [DWIDTH-1:0] wdata ;
  logic [STRBWIDTH-1:0] wstrb ;
  // ------------------------ write response channel ------------------------
  logic bvalid , bready ;
  logic [1:0] bresp ;
  // ------------------------ read address channel ------------------------
  logic arready , arvalid ;
  logic [AWIDTH-1:0] araddr ;
  logic [2:0] arport ;
  // ------------------------ read data channel ------------------------
  logic rvalid , rready ;
  logic [DWIDTH-1:0] rdata ;
  logic [1:0] rresp ;

  clocking cb @(posedge aclk or negedge arstn);
    input awready , wready , bvalid , bresp , arready , rvalid , rdata , rresp;
    output awvalid , awaddr , awport , wvalid , wdata , wstrb , bready , arvalid , araddr , arport , rready;
  endclocking 
endinterface

interface slv_if_axil#(
  parameter AWIDTH = 32 ,
  parameter DWIDTH = 64 ,
  localparam STRBWIDTH = DWIDTH/8 ,
  parameter IDWIDTH = 4 
)(
  input aclk ,
  input arstn
);
  // ------------------------ write address channel ------------------------
  logic awready , awvalid ;
  logic [AWIDTH-1:0] awaddr ;
  logic [2:0] awport ;
  // ------------------------ write data channel ------------------------
  logic wvalid , wready ;
  logic [DWIDTH-1:0] wdata ;
  logic [STRBWIDTH-1:0] wstrb ;
  // ------------------------ write response channel ------------------------
  logic bvalid , bready ;
  logic [1:0] bresp ;
  // ------------------------ read address channel ------------------------
  logic arready , arvalid ;
  logic [AWIDTH-1:0] araddr ;
  logic [2:0] arport ;
  // ------------------------ read data channel ------------------------
  logic rvalid , rready ;
  logic [DWIDTH-1:0] rdata ;
  logic [1:0] rresp ;

  clocking cb @(posedge aclk or negedge arstn);
    input  awvalid , awaddr , awport , wvalid , wdata , wstrb , bready , arvalid , araddr , arport , rready;
    output awready , wready , bvalid , bresp , arready , rvalid , rdata , rresp;
  endclocking 
endinterface

interface mnt_if_axil#(
  parameter AWIDTH = 32 ,
  parameter DWIDTH = 64 ,
  localparam STRBWIDTH = DWIDTH/8 ,
  parameter IDWIDTH = 4 
)(
  input aclk ,
  input arstn
);
  // ------------------------ write address channel ------------------------
  logic awready , awvalid ;
  logic [AWIDTH-1:0] awaddr ;
  logic [2:0] awport ;
  // ------------------------ write data channel ------------------------
  logic wvalid , wready ;
  logic [DWIDTH-1:0] wdata ;
  logic [STRBWIDTH-1:0] wstrb ;
  // ------------------------ write response channel ------------------------
  logic bvalid , bready ;
  logic [1:0] bresp ;
  // ------------------------ read address channel ------------------------
  logic arready , arvalid ;
  logic [AWIDTH-1:0] araddr ;
  logic [2:0] arport ;
  // ------------------------ read data channel ------------------------
  logic rvalid , rready ;
  logic [DWIDTH-1:0] rdata ;
  logic [1:0] rresp ;
  
  clocking cb @(posedge aclk or negedge arstn);
  input  awvalid , awaddr , awport , wvalid , wdata , wstrb , bready , arvalid , araddr , arport , rready;
  output awready , wready , bvalid , bresp , arready , rvalid , rdata , rresp;
  endclocking
endinterface