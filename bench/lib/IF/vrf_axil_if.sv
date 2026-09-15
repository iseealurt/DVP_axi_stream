`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 三视角接口与通配符自动连接挂钩
//
//   vrf_axil_mst_if : 主机视角，驱动请求、采样响应（driver 使用）
//   vrf_axil_slv_if : 从机视角，驱动响应、采样请求（从机参考模型使用）
//   vrf_axil_mnt_if : 监视视角，全部为输入（monitor / 上电检查使用）
//
// 通配符自动连接说明：
//   SystemVerilog 的 `bind` 只能观测目标模块内部信号，无法驱动其输入端口，
//   因此本库采用「挂具模块 + 端口按名通配符连接」方案：
//     1) 在挂具模块中展开 `VRF_AXIL_HOOK_DECL(AW, DW, ID)`，
//        它声明与 DUT 端口同名的 AXI4-Lite 信号、实例化 mst/mnt 接口、
//        按名完成接口与信号的双向挂钩，并把句柄发布到 vrf_axil_conn_h；
//     2) 挂具内用 `DUT u_dut (.*);` 实例化被测模块，
//        DUT 的全部端口（含本轮不验证的 DVP/AXIS 端口）按名自动连接，
//        无需逐根手写端口映射。
//   新增 DUT 时只需照抄挂具模板并补齐不验证端口的占位声明。
// =============================================================================

// -----------------------------------------------------------------------------
// 主机视角接口
// -----------------------------------------------------------------------------
interface vrf_axil_mst_if #(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input logic aclk,
  input logic arstn
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

  clocking cb @(posedge aclk);
    input  arstn;
    input  awready, wready, bvalid, bid, bresp, arready, rvalid, rdata, rresp, rid;
    output awvalid, awaddr, awport, wvalid, wdata, wstrb, bready,
           arvalid, araddr, arport, rready;
  endclocking

  // 主机侧驱动信号初值，避免上电 X 态
  initial begin
    awvalid = 1'b0;
    awaddr  = '0;
    awport  = '0;
    wvalid  = 1'b0;
    wdata   = '0;
    wstrb   = '0;
    bready  = 1'b0;
    arvalid = 1'b0;
    araddr  = '0;
    arport  = '0;
    rready  = 1'b0;
  end
endinterface

// -----------------------------------------------------------------------------
// 从机视角接口
// -----------------------------------------------------------------------------
interface vrf_axil_slv_if #(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input logic aclk,
  input logic arstn
);
  localparam int STRBWIDTH = DWIDTH / 8;

  logic                awvalid;
  logic [AWIDTH-1:0]   awaddr;
  logic [2:0]          awport;
  logic                awready;

  logic                wvalid;
  logic [DWIDTH-1:0]   wdata;
  logic [STRBWIDTH-1:0] wstrb;
  logic                wready;

  logic                bvalid;
  logic                bready;
  logic [IDWIDTH-1:0]  bid;
  logic [1:0]          bresp;

  logic                arvalid;
  logic [AWIDTH-1:0]   araddr;
  logic [2:0]          arport;
  logic                arready;

  logic                rvalid;
  logic                rready;
  logic [DWIDTH-1:0]   rdata;
  logic [1:0]          rresp;
  logic [IDWIDTH-1:0]  rid;

  clocking cb @(posedge aclk);
    input  arstn;
    input  awvalid, awaddr, awport, wvalid, wdata, wstrb, bready,
           arvalid, araddr, arport, rready;
    output awready, wready, bvalid, bid, bresp, arready, rvalid, rdata, rresp, rid;
  endclocking

  // 从机侧驱动信号初值
  initial begin
    awready = 1'b0;
    wready  = 1'b0;
    bvalid  = 1'b0;
    bid     = '0;
    bresp   = 2'b00;
    arready = 1'b0;
    rvalid  = 1'b0;
    rdata   = '0;
    rresp   = 2'b00;
    rid     = '0;
  end
endinterface

// -----------------------------------------------------------------------------
// 监视视角接口（全部为输入，纯观测）
// -----------------------------------------------------------------------------
interface vrf_axil_mnt_if #(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input logic aclk,
  input logic arstn
);
  localparam int STRBWIDTH = DWIDTH / 8;

  logic                awvalid;
  logic [AWIDTH-1:0]   awaddr;
  logic [2:0]          awport;
  logic                awready;

  logic                wvalid;
  logic [DWIDTH-1:0]   wdata;
  logic [STRBWIDTH-1:0] wstrb;
  logic                wready;

  logic                bvalid;
  logic                bready;
  logic [IDWIDTH-1:0]  bid;
  logic [1:0]          bresp;

  logic                arvalid;
  logic [AWIDTH-1:0]   araddr;
  logic [2:0]          arport;
  logic                arready;

  logic                rvalid;
  logic                rready;
  logic [DWIDTH-1:0]   rdata;
  logic [1:0]          rresp;
  logic [IDWIDTH-1:0]  rid;

  clocking cb @(posedge aclk);
    input arstn;
    input awvalid, awaddr, awport, awready, wvalid, wdata, wstrb, wready,
          bvalid, bready, bid, bresp, arvalid, araddr, arport, arready,
          rvalid, rready, rdata, rresp, rid;
  endclocking
endinterface

// -----------------------------------------------------------------------------
// 通配符自动连接挂钩宏
//   在被测模块的挂具中展开，完成：
//     - 声明与 DUT 端口同名的 AXI4-Lite 信号（供 `DUT u_dut (.*);` 自动连接）
//     - 实例化 mst/mnt 接口并按名双向挂钩
//     - 把接口句柄发布到全局连接表
//   前置条件：挂具模块内存在 aclk / aresetn 两个时钟复位信号
// -----------------------------------------------------------------------------
`define VRF_AXIL_HOOK_DECL(AW, DW, ID)                                                    \
  /* 与 DUT 端口同名的 AXI4-Lite 信号 */                                                 \
  wire                awvalid;                                                           \
  wire [AW-1:0]       awaddr;                                                            \
  wire [2:0]          awport;                                                            \
  wire                awready;                                                           \
  wire                wvalid;                                                            \
  wire [DW-1:0]       wdata;                                                             \
  wire [DW/8-1:0]     wstrb;                                                             \
  wire                wready;                                                            \
  wire                bvalid;                                                            \
  wire                bready;                                                            \
  wire [ID-1:0]       bid;                                                               \
  wire [1:0]          bresp;                                                             \
  wire                arvalid;                                                           \
  wire [AW-1:0]       araddr;                                                            \
  wire [2:0]          arport;                                                            \
  wire                arready;                                                           \
  wire                rvalid;                                                            \
  wire                rready;                                                            \
  wire [DW-1:0]       rdata;                                                             \
  wire [1:0]          rresp;                                                             \
  wire [ID-1:0]       rid;                                                               \
                                                                                          \
  /* 主机 / 监视视角接口 */                                                              \
  vrf_axil_mst_if #(AW, DW, ID) mst_vif (.aclk(aclk), .arstn(aresetn));                  \
  vrf_axil_mnt_if #(AW, DW, ID) mnt_vif (.aclk(aclk), .arstn(aresetn));                  \
                                                                                          \
  /* 主机侧 -> DUT 输入 */                                                               \
  assign awvalid = mst_vif.awvalid;                                                      \
  assign awaddr  = mst_vif.awaddr;                                                       \
  assign awport  = mst_vif.awport;                                                       \
  assign wvalid  = mst_vif.wvalid;                                                       \
  assign wdata   = mst_vif.wdata;                                                        \
  assign wstrb   = mst_vif.wstrb;                                                        \
  assign bready  = mst_vif.bready;                                                       \
  assign arvalid = mst_vif.arvalid;                                                      \
  assign araddr  = mst_vif.araddr;                                                       \
  assign arport  = mst_vif.arport;                                                       \
  assign rready  = mst_vif.rready;                                                       \
                                                                                          \
  /* DUT 输出 -> 主机侧采样 */                                                           \
  assign mst_vif.awready = awready;                                                      \
  assign mst_vif.wready  = wready;                                                       \
  assign mst_vif.bvalid  = bvalid;                                                       \
  assign mst_vif.bid     = bid;                                                          \
  assign mst_vif.bresp   = bresp;                                                        \
  assign mst_vif.arready = arready;                                                      \
  assign mst_vif.rvalid  = rvalid;                                                       \
  assign mst_vif.rdata   = rdata;                                                        \
  assign mst_vif.rresp   = rresp;                                                        \
  assign mst_vif.rid     = rid;                                                          \
                                                                                          \
  /* 监视接口在 DUT 端口处采样 */                                                        \
  assign mnt_vif.awvalid = awvalid;                                                      \
  assign mnt_vif.awaddr  = awaddr;                                                       \
  assign mnt_vif.awport  = awport;                                                       \
  assign mnt_vif.awready = awready;                                                      \
  assign mnt_vif.wvalid  = wvalid;                                                       \
  assign mnt_vif.wdata   = wdata;                                                        \
  assign mnt_vif.wstrb   = wstrb;                                                        \
  assign mnt_vif.wready  = wready;                                                       \
  assign mnt_vif.bvalid  = bvalid;                                                       \
  assign mnt_vif.bready  = bready;                                                       \
  assign mnt_vif.bid     = bid;                                                          \
  assign mnt_vif.bresp   = bresp;                                                        \
  assign mnt_vif.arvalid = arvalid;                                                      \
  assign mnt_vif.araddr  = araddr;                                                       \
  assign mnt_vif.arport  = arport;                                                       \
  assign mnt_vif.arready = arready;                                                      \
  assign mnt_vif.rvalid  = rvalid;                                                       \
  assign mnt_vif.rready  = rready;                                                       \
  assign mnt_vif.rdata   = rdata;                                                        \
  assign mnt_vif.rresp   = rresp;                                                        \
  assign mnt_vif.rid     = rid;                                                          \
                                                                                          \
  /* 发布接口句柄，供环境/驱动器/监视器统一取用 */                                       \
  initial begin                                                                          \
    vrf_axil_conn_h #(AW, DW, ID)::mst       = mst_vif;                                  \
    vrf_axil_conn_h #(AW, DW, ID)::mnt       = mnt_vif;                                  \
    vrf_axil_conn_h #(AW, DW, ID)::published = 1'b1;                                     \
  end
