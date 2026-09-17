`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 从机参考模型
//   - 端口名与标准 AXI4-Lite 从端一致，可被协议检查器通过 bind (.*) 自动连接
//   - 内部以 vrf_axil_slv_if 从机视角接口承载协议行为，可被后续从机 agent 复用
//   - 独立实现寄存器读写语义（R/W、只读、W1C、自清零、wstrb 字节使能）
//   - 寄存器提交放在单一 always 进程内，同一拍内「先采样读、后提交写」，
//     与常见 RTL 从端的边沿语义一致，保证并发同址读写结果确定
//   - 可配置 ready 延迟形成反压，作为库自测用例的对端
//
// 驱动归属与复位处理（重要）：
//   从机侧驱动信号（awready/wready/bvalid/bid/bresp/arready/rvalid/rdata/rresp/rid）
//   由本模块独占，且每个信号只有唯一的任务写入（wr_task / rd_task 各管一半），
//   不存在多进程竞争写同一信号；驱动采用直接赋值 `slv.<sig> <= ...`，
//   不使用时钟块输出。
//   握手 ready 脉冲与响应等待都额外监听 aresetn 的下降沿：复位在 ready/valid 有效期间
//   被拉低时，任务在复位沿当拍撤销它们，而不是等到下一个时钟沿——否则复位期间会残留
//   有效 ready/valid（自检的 p_reset_no_resp 在复位期间采样沿前值，会判为协议违例）。
//   这样做既保持了「一个信号只有一个写者」的约定
//   （改用寄存进程驱动 valid 会引入第二个写者，且其复位值依赖异步复位路径）。
//   复位判定统一写成 (aresetn !== 1'b1)：0 与 X 都视为「处于复位」，
//   避免 X 与 4 态取反合成出 X 后被 while 当成「假」，把未知状态当成正常放行。
//
// 接受时序：本从端采用保守策略——AW 与 W 同时有效后才接受（单独的 AW 或 W 会被
//   保持等待）。这是 AXI 允许的从端行为；主机的 AW/W 分离到达会被正确等待而非丢失。
//   请求判定一律与 1'b1 做全等比较：采样到的 awvalid/wvalid/arvalid 为 X 时，
//   4 态逻辑的 &&/! 会得到 X 而被 while 当成「假」，导致把不存在的请求当成已接受，
//   因此必须显式比较，只有确定有效才认为收到请求。
//
// 寄存器映射（与 vrf_axil_regmodel::build_ref_slave_map 保持一致，按 32 位定义）：
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

  // 数据通路宽度随 DWIDTH 派生；寄存器映射本身按 32 位定义（见文件头）
  localparam int DW       = DWIDTH;
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
  logic [DW-1:0] store[int unsigned];
  logic [DW-1:0] rd_cap;          // 读采样值：在 AR 握手拍锁存

  // 本参考模型的寄存器映射按 32 位定义，非 32 位实例化直接报错而不是静默截断
  initial begin
    if (DWIDTH != 32) begin
      $fatal(1, "[VRF_AXIL] vrf_axil_slv_ref 的寄存器映射按 32 位定义，DWIDTH 必须为 32（当前 %0d）",
             DWIDTH);
    end
  end

  // 按字节选通的写合并（宽度随 DWIDTH 派生）
  function automatic logic [DW-1:0] wstrb_merge(
    input logic [DW-1:0]         old_val,
    input logic [DW-1:0]         new_val,
    input logic [STRBWIDTH-1:0]  strb
  );
    logic [DW-1:0] tmp;
    tmp = old_val;
    for (int i = 0; i < STRBWIDTH; i++) begin
      if (strb[i]) tmp[i*8 +: 8] = new_val[i*8 +: 8];
    end
    return tmp;
  endfunction

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

  function automatic logic [DW-1:0] selfclear_mask(input logic [31:0] off);
    return (off == 32'h00) ? 32'h0000_0002 : {DW{1'b0}};
  endfunction

  // 写提交
  function automatic void do_write(
    input logic [31:0]          off,
    input logic [DW-1:0]        data,
    input logic [STRBWIDTH-1:0] strb
  );
    logic [DW-1:0] nv;
    logic [DW-1:0] clr;
    if (!is_mapped(off)) return;             // 未映射：忽略
    if (is_ro(off))      return;             // 只读：忽略
    if (is_w1c(off)) begin
      clr = wstrb_merge({DW{1'b0}}, data, strb);
      store[off] = store[off] & ~clr;
      return;
    end
    nv = wstrb_merge(store[off], data, strb);
    store[off] = nv & ~selfclear_mask(off);
  endfunction

  // 读采样
  function automatic logic [DW-1:0] do_read(input logic [31:0] off);
    if (!is_mapped(off)) return {DW{1'b0}};
    return store[off];
  endfunction

  // ------------------------ 寄存器提交：单进程，同拍先读后写 ------------------------
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      init_store();
      rd_cap <= {DW{1'b0}};
    end else begin
      // 读采样使用本拍写提交前的镜像值，保证并发同址读写结果确定
      if (arvalid && arready) rd_cap <= do_read(araddr);
      // 写提交
      if (awvalid && awready && wvalid && wready) do_write(awaddr, wdata, wstrb);
    end
  end

  // =====================================================================
  // 协议行为（从机侧驱动信号由 wr_task / rd_task 各管一半，无多进程竞争）
  // =====================================================================
  // 写通道：AW/W 同时有效后被接受，随后返回 B 响应
  task automatic wr_task();
    int d;
    forever begin
      // 输出置为无效态，并覆盖 bid/bresp 初值（避免 X 进入自检的 X/Z 统计）
      slv.awready <= 1'b0;
      slv.wready  <= 1'b0;
      slv.bvalid  <= 1'b0;
      slv.bid     <= '0;
      slv.bresp   <= 2'b00;

      // 只有确定采样到 1'b1 才算收到请求（X 不得被当作有效请求）
      do @(slv.cb); while (!((slv.cb.awvalid === 1'b1) && (slv.cb.wvalid === 1'b1)) || (aresetn !== 1'b1));
      if (aresetn !== 1'b1) continue;

      // 反压延迟期间同样感知复位，避免复位后仍把 ready 拉高
      d = $urandom_range(RDY_DLY_MIN, RDY_DLY_MAX);
      for (int i = 0; i < d; i++) begin
        @(slv.cb);
        if (aresetn !== 1'b1) break;
      end
      if (aresetn !== 1'b1) continue;

      // 拉高 ready 完成握手；同时监听复位下降沿，复位沿当拍即撤销 ready，
      // 不在复位期间遗留有效 ready（与响应 valid 的处理一致）
      slv.awready <= 1'b1;
      slv.wready  <= 1'b1;
      fork
        @(slv.cb);
        if (aresetn === 1'b1) @(negedge aresetn);
      join_any
      disable fork;
      slv.awready <= 1'b0;
      slv.wready  <= 1'b0;
      if (aresetn !== 1'b1) continue;  // 复位期间不产生 B 响应

      // B 响应（bvalid 由本任务驱动，握手只需等待对端 bready）
      // fork 的第二支监听 aresetn 下降沿：复位在响应有效期间被拉低时，
      // 立即撤销 bvalid，而不是留到下一个时钟沿（复位期间不得有有效响应）
      slv.bvalid <= 1'b1;
      fork
        begin
          do @(slv.cb); while (!(slv.cb.bready === 1'b1) && (aresetn === 1'b1));
        end
        begin
          if (aresetn === 1'b1) @(negedge aresetn);
        end
      join_any
      disable fork;
      slv.bvalid <= 1'b0;
    end
  endtask

  // 读通道
  task automatic rd_task();
    int d;
    forever begin
      // 输出置为无效态，并覆盖 rdata/rresp/rid 初值
      slv.arready <= 1'b0;
      slv.rvalid  <= 1'b0;
      slv.rdata   <= '0;
      slv.rresp   <= 2'b00;
      slv.rid     <= '0;

      do @(slv.cb); while (!(slv.cb.arvalid === 1'b1) || (aresetn !== 1'b1));
      if (aresetn !== 1'b1) continue;

      d = $urandom_range(RDY_DLY_MIN, RDY_DLY_MAX);
      for (int i = 0; i < d; i++) begin
        @(slv.cb);
        if (aresetn !== 1'b1) break;
      end
      if (aresetn !== 1'b1) continue;

      // AR 握手拍：提交进程在本拍锁存 rd_cap；同样在复位沿当拍撤销 arready
      slv.arready <= 1'b1;
      fork
        @(slv.cb);
        if (aresetn === 1'b1) @(negedge aresetn);
      join_any
      disable fork;
      slv.arready <= 1'b0;
      if (aresetn !== 1'b1) continue;    // 复位期间不产生 R 响应
      @(slv.cb);                         // 等 rd_cap 更新完成

      // R 通道（rvalid 由本任务驱动，握手只需等待对端 rready；复位处理同 B 通道）
      slv.rdata  <= rd_cap;
      slv.rvalid <= 1'b1;
      fork
        begin
          do @(slv.cb); while (!(slv.cb.rready === 1'b1) && (aresetn === 1'b1));
        end
        begin
          if (aresetn === 1'b1) @(negedge aresetn);
        end
      join_any
      disable fork;
      slv.rvalid <= 1'b0;
    end
  endtask

  initial begin
    fork
      wr_task();
      rd_task();
    join_none
  end
endmodule
