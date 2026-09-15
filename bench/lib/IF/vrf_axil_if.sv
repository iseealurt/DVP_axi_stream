`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 三视角接口与通配符自动连接挂钩
//
//   vrf_axil_mst_if : 主机视角，驱动请求、采样响应（driver 使用）
//   vrf_axil_slv_if : 从机视角，驱动响应、采样请求（从机参考模型使用）
//   vrf_axil_mnt_if : 监视视角，全部为输入（monitor / 上电检查使用）
//
// 驱动与采样约定（重要）：
//   1) 时钟块 cb 只声明 input，仅用于「采样 + 提供时钟沿事件」，不作为驱动通路；
//      否则同一信号会同时被时钟块输出与直接赋值驱动。
//   2) 接口内不写初值（无 initial），避免与使用者形成多进程驱动。
//      各侧驱动信号的归属：
//        主机侧（awvalid/awaddr/awport/wvalid/wdata/wstrb/bready/arvalid/araddr/arport/rready）
//          —— 由 vrf_axil_bringup（上电自检阶段）与 vrf_axil_driver（自检之后）顺序独占；
//        从机侧（awready/wready/bvalid/bid/bresp/arready/rvalid/rdata/rresp/rid）
//          —— 由 vrf_axil_slv_ref 独占。
//   3) 驱动一律用直接赋值（`mst_vif.awvalid <= 1'b1;`），在 `@(mst_vif.cb)` 唤醒之后执行，
//      落在 NBA 区，与被测 DUT 的同沿采样无竞争。
//   4) 采样必须区分来源，否则会在握手当拍取到错误的相位：
//        - 自己驱动的信号：直接读接口变量（如 `mst_vif.awvalid`）→ 本拍前沿值；
//        - 被测/对端驱动的信号：必须用时钟块采样（如 `mst_vif.cb.awready`）→ 前沿值。
//      原因：对端信号经 `assign` 连到接口变量上，组合型 ready/valid 会在握手当拍
//      被对端更新为后沿值，直读会取到后沿值而漏判握手；时钟块以 #1step 采样取前沿值。
//
// 通配符自动连接说明：
//   SystemVerilog 的 `bind` 只能观测目标模块内部信号、无法驱动其输入端口，
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

  // 仅用于采样与时钟沿同步；驱动见文件头说明
  clocking cb @(posedge aclk);
    input arstn;
    input awready, wready, bvalid, bid, bresp, arready, rvalid, rdata, rresp, rid;
  endclocking
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
    input arstn;
    input awvalid, awaddr, awport, wvalid, wdata, wstrb, bready,
          arvalid, araddr, arport, rready;
  endclocking
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
//     - 把接口句柄发布到全局连接表（检测重复发布，避免句柄被静默覆盖）
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
  /* 发布接口句柄；重复发布视为连接冲突，显式报错而非静默覆盖 */                         \
  initial begin                                                                          \
    if (vrf_axil_conn_h #(AW, DW, ID)::published === 1'b1) begin                          \
      vrf_axil_conn_h #(AW, DW, ID)::conflict = 1'b1;                                    \
      $display("[%0t][VRF_AXIL][ERROR] 检测到重复的挂具实例（特化 %0d/%0d/%0d）：后一个实例的接口句柄被丢弃，仍保留最先发布的句柄，通配符自动连接存在冲突", \
               $time, AW, DW, ID);                                                       \
    end else begin                                                                        \
      vrf_axil_conn_h #(AW, DW, ID)::mst       = mst_vif;                                \
      vrf_axil_conn_h #(AW, DW, ID)::mnt       = mnt_vif;                                \
      vrf_axil_conn_h #(AW, DW, ID)::published = 1'b1;                                   \
    end                                                                                   \
  end
