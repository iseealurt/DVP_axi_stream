`ifndef IF_AXIL_SV
`define IF_AXIL_SV

`timescale 1ns/1ps
interface mst_if_axil#(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input logic aclk ,
  input logic aresetn 
);
  localparam int STRBWIDTH = DWIDTH / 8;
  // ------------------------ write address channel ------------------------
  logic                awvalid;
  logic [AWIDTH-1:0]   awaddr;
  logic [2:0]          awport;
  logic                awready;
  // ------------------------ write data channel ------------------------
  logic                wvalid;
  logic [DWIDTH-1:0]   wdata;
  logic [STRBWIDTH-1:0] wstrb;
  logic                wready;
  // ------------------------ write response channel ------------------------
  logic                bvalid;
  logic                bready;
  logic [IDWIDTH-1:0]  bid;
  logic [1:0]          bresp;
  // ------------------------ read address channel ------------------------
  logic                arvalid;
  logic [AWIDTH-1:0]   araddr;
  logic [2:0]          arport;
  logic                arready;
  // ------------------------ read data channel ------------------------
  logic                rvalid;
  logic                rready;
  logic [DWIDTH-1:0]   rdata;
  logic [1:0]          rresp;
  logic [IDWIDTH-1:0]  rid;

  // master 侧视角：由主机驱动请求，采样从机返回
  modport mst (
    input aclk, aresetn,
    input awready, wready, bvalid, bid, bresp, arready, rvalid, rdata, rresp, rid,
    output awvalid, awaddr, awport, wvalid, wdata, wstrb, bready,
           arvalid, araddr, arport, rready
  );

  // 仅用于采样与提供时钟沿；不声明 output（避免与外部直接赋值形成多驱动，
  // 与 bench/lib/IF/vrf_axil_if.sv 的约定一致）
  clocking cb @(posedge aclk);
    input aresetn;
    input awvalid, awaddr, awport, awready, wvalid, wdata, wstrb, wready,
          bvalid, bready, bid, bresp, arvalid, araddr, arport, arready,
          rvalid, rready, rdata, rresp, rid;
  endclocking
endinterface 

interface slv_if_axil#(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input logic aclk ,
  input logic aresetn 
);
  localparam int STRBWIDTH = DWIDTH / 8;
  // ------------------------ write address channel ------------------------
  logic                awvalid;
  logic [AWIDTH-1:0]   awaddr;
  logic [2:0]          awport;
  logic                awready;
  // ------------------------ write data channel ------------------------
  logic                wvalid;
  logic [DWIDTH-1:0]   wdata;
  logic [STRBWIDTH-1:0] wstrb;
  logic                wready;
  // ------------------------ write response channel ------------------------
  logic                bvalid;
  logic                bready;
  logic [IDWIDTH-1:0]  bid;
  logic [1:0]          bresp;
  // ------------------------ read address channel ------------------------
  logic                arvalid;
  logic [AWIDTH-1:0]   araddr;
  logic [2:0]          arport;
  logic                arready;
  // ------------------------ read data channel ------------------------
  logic                rvalid;
  logic                rready;
  logic [DWIDTH-1:0]   rdata;
  logic [1:0]          rresp;
  logic [IDWIDTH-1:0]  rid;
  modport slv (
    input aclk, aresetn,
    output awready, wready, bvalid, bid, bresp, arready, rvalid, rdata, rresp, rid,
    input awvalid, awaddr, awport, wvalid, wdata, wstrb, bready,
           arvalid, araddr, arport, rready
  );
  // 仅用于采样与提供时钟沿；不声明 output，避免与模块内直接赋值形成多驱动
  // （否则 vopt/vsim-3838：变量同时被连续赋值与时钟块驱动）
  clocking cb @(posedge aclk);
    input aresetn;
    input awvalid, awaddr, awport, awready, wvalid, wdata, wstrb, wready,
          bvalid, bready, bid, bresp, arvalid, araddr, arport, arready,
          rvalid, rready, rdata, rresp, rid;
  endclocking
endinterface 
`endif