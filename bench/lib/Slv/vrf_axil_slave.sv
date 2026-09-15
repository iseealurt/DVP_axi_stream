`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 从机参考模型
//   - 端口名与标准 AXI4-Lite 从端一致，可被协议检查器通过 bind (.*) 自动连接
//   - 内部以 vrf_axil_slv_if 从机视角接口承载协议行为，可被后续从机 agent 复用
//   - 独立实现 32 位寄存器读写语义（R/W、只读、W1C、自清零、wstrb 字节使能）
//   - 寄存器提交放在单一 always 进程内，同一拍内「先采样读、后提交写」，
//     与 DVP2axi_stream 等 RTL 从端的边沿语义一致，保证并发同址读写结果确定
//   - 可配置 ready 延迟形成反压，作为库自测用例的对端
//
// 寄存器映射（与 vrf_axil_regmodel::build_ref_slave_map 保持一致）：
//   0x00 REF_CTL  R/W   复位 0x0，bit[1] 写后自清零
//   0x04 REF_STAT RO    复位 0x0
//   0x08 REF_DATA R/W   复位 0x1234_5678
//   0x0C REF_INT  W1C   复位 0x0
//   0x10 REF_MASK R/W   复位 0x0
//   0x18 REF_VER  RO    复位 0x0001_0000
//   0x80 REF_SCR  R/W   复位 0x0
// =============================================================================
module vrf_axil_slv_ref #(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4,
  parameter int RDY_DLY_MIN = 0,   // ready 最小延迟周期
  parameter int RDY_DLY_MAX = 2    // ready 最大延迟周期
)(
  input  wire                aclk,
  input  wire                aresetn,
  input  wire                awvalid,
  input  wire [AWIDTH-1:0]   awaddr,
  input  wire [2:0]          awport,
  output wire                awready,
  input  wire                wvalid,
  input  wire [DWIDTH-1:0]   wdata,
  input  wire [DWIDTH/8-1:0] wstrb,
  output wire                wready,
  input  wire                bready,
  output wire                bvalid,
  output wire [IDWIDTH-1:0]  bid,
  output wire [1:0]          bresp,
  input  wire                arvalid,
  input  wire [AWIDTH-1:0]   araddr,
  input  wire [2:0]          arport,
  output wire                arready,
  input  wire                rready,
  output wire                rvalid,
  output wire [DWIDTH-1:0]   rdata,
  output wire [1:0]          rresp,
  output wire [IDWIDTH-1:0]  rid
);
  import vrf_axil_pkg::*;

  localparam int STRBWIDTH = DWIDTH / 8;

  vrf_axil_slv_if #(AWIDTH, DWIDTH, IDWIDTH) slv (.aclk(aclk), .arstn(aresetn));

  // ------------------------ 端口 -> 从机视角接口 ------------------------
  assign slv.awvalid = awvalid;
  assign slv.awaddr  = awaddr;
  assign slv.awport  = awport;
  assign slv.wvalid  = wvalid;
  assign slv.wdata   = wdata;
  assign slv.wstrb   = wstrb;
  assign slv.bready  = bready;
  assign slv.arvalid = arvalid;
  assign slv.araddr  = araddr;
  assign slv.arport  = arport;
  assign slv.rready  = rready;

  // ------------------------ 从机视角接口 -> 端口 ------------------------
  assign awready = slv.awready;
  assign wready  = slv.wready;
  assign bvalid  = slv.bvalid;
  assign bid     = slv.bid;
  assign bresp   = slv.bresp;
  assign arready = slv.arready;
  assign rvalid  = slv.rvalid;
  assign rdata   = slv.rdata;
  assign rresp   = slv.rresp;
  assign rid     = slv.rid;

  // =====================================================================
  // 寄存器存储与访问语义
  // =====================================================================
  logic [31:0] store[int unsigned];
  logic [31:0] rd_cap;          // 读采样值：在 AR 握手拍锁存

  function automatic void init_store();
    store.delete();
    store[32'h00] = 32'h0000_0000;   // REF_CTL
    store[32'h04] = 32'h0000_0000;   // REF_STAT
    store[32'h08] = 32'h1234_5678;   // REF_DATA
    store[32'h0C] = 32'h0000_0000;   // REF_INT
    store[32'h10] = 32'h0000_0000;   // REF_MASK
    store[32'h18] = 32'h0001_0000;   // REF_VER
    store[32'h80] = 32'h0000_0000;   // REF_SCR
  endfunction

  function automatic bit is_mapped(input logic [31:0] off);
    return (off <= 32'hFF) && store.exists(off);
  endfunction

  function automatic bit is_ro(input logic [31:0] off);
    return (off == 32'h04) || (off == 32'h18);
  endfunction

  function automatic bit is_w1c(input logic [31:0] off);
    return (off == 32'h0C);
  endfunction

  function automatic logic [31:0] selfclear_mask(input logic [31:0] off);
    return (off == 32'h00) ? 32'h0000_0002 : 32'h0;
  endfunction

  // 写提交
  function automatic void do_write(
    input logic [31:0] off,
    input logic [31:0] data,
    input logic [3:0]  strb
  );
    logic [31:0] nv;
    logic [31:0] clr;
    if (!is_mapped(off)) return;             // 未映射：忽略
    if (is_ro(off))      return;             // 只读：忽略
    if (is_w1c(off)) begin
      clr = vrf_axil_wstrb_apply(32'h0, data, strb);
      store[off] = store[off] & ~clr;
      return;
    end
    nv = vrf_axil_wstrb_apply(store[off], data, strb);
    store[off] = nv & ~selfclear_mask(off);
  endfunction

  // 读采样
  function automatic logic [31:0] do_read(input logic [31:0] off);
    if (!is_mapped(off)) return 32'h0;
    return store[off];
  endfunction

  // ------------------------ 寄存器提交：单进程，同拍先读后写 ------------------------
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      init_store();
      rd_cap <= {DWIDTH{1'b0}};
    end else begin
      // 读采样使用本拍写提交前的镜像值，保证并发同址读写结果确定
      if (arvalid && arready) rd_cap <= do_read(araddr);
      // 写提交
      if (awvalid && awready && wvalid && wready) do_write(awaddr, wdata, wstrb);
    end
  end

  // =====================================================================
  // 协议行为（握手由从机视角接口驱动）
  // =====================================================================
  // 写通道：AW/W 同时有效后被接受，随后返回 B 响应
  task automatic wr_task();
    int d;
    forever begin
      do @(slv.cb); while (!(slv.cb.awvalid && slv.cb.wvalid) || !aresetn);
      if (!aresetn) continue;
      d = $urandom_range(RDY_DLY_MIN, RDY_DLY_MAX);
      repeat (d) @(slv.cb);
      // 拉高 ready 完成握手
      slv.cb.awready <= 1'b1;
      slv.cb.wready  <= 1'b1;
      @(slv.cb);
      slv.cb.awready <= 1'b0;
      slv.cb.wready  <= 1'b0;
      // B 响应
      slv.cb.bid    <= '0;
      slv.cb.bresp  <= 2'b00;
      slv.cb.bvalid <= 1'b1;
      do @(slv.cb); while (!(slv.cb.bvalid && slv.cb.bready) && aresetn);
      slv.cb.bvalid <= 1'b0;
    end
  endtask

  // 读通道
  task automatic rd_task();
    int d;
    forever begin
      do @(slv.cb); while (!slv.cb.arvalid || !aresetn);
      if (!aresetn) continue;
      d = $urandom_range(RDY_DLY_MIN, RDY_DLY_MAX);
      repeat (d) @(slv.cb);
      slv.cb.arready <= 1'b1;
      @(slv.cb);                 // AR 握手拍：提交进程锁存 rd_cap
      slv.cb.arready <= 1'b0;
      @(slv.cb);                 // 等 rd_cap 更新完成
      // R 通道
      slv.cb.rid    <= '0;
      slv.cb.rresp  <= 2'b00;
      slv.cb.rdata  <= rd_cap;
      slv.cb.rvalid <= 1'b1;
      do @(slv.cb); while (!(slv.cb.rvalid && slv.cb.rready) && aresetn);
      slv.cb.rvalid <= 1'b0;
    end
  endtask

  // 复位看守：复位期间释放全部驱动信号
  task automatic rst_task();
    forever begin
      @(negedge aresetn);
      slv.cb.awready <= 1'b0;
      slv.cb.wready  <= 1'b0;
      slv.cb.bvalid  <= 1'b0;
      slv.cb.arready <= 1'b0;
      slv.cb.rvalid  <= 1'b0;
    end
  endtask

  initial begin
    fork
      wr_task();
      rd_task();
      rst_task();
    join_none
  end
endmodule
