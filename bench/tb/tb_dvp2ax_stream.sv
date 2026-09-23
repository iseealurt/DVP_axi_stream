`timescale 1ns/1ps
// =============================================================================
// DVP2axis 接入示例：以 VRF_AXI4L 库对 RTL/DVP2axis.sv 的
// AXI4-Lite 寄存器块做完整功能验证。
//   演示内容：
//     - 挂具模块 + DVP2axis 全部端口 `.*` 通配符自动连接
//       （AXI4-Lite 为接口端口 slv_if_axil.slv，由挂具内的接口实例按名连接）
//     - 细粒度环境 API：connect / start / submit / wait_idle / stop / report
//     - 定向功能测试（对标历史仿真报告的覆盖项）+ 受约束随机回归
//     - 内部事件注入（层次化 force）后由寄存器模型同步预测
//     - 复位打断响应事务的容错处理
//     - 协议断言、连通性自检、覆盖率与报告输出
// =============================================================================

// -----------------------------------------------------------------------------
// 协议检查器挂接：bind 语句由用例给出（库本体不含任何 DUT 名）；
//   编译期按 +define 选择目标，避免未实例化的目标产生未解析引用。
// -----------------------------------------------------------------------------
`ifdef VRF_AXIL_BIND_DVP2AXI
  // 检查器挂在挂具上：挂具内的 AXI4-Lite 信号与 DUT 接口端口逐根直连，
  // 电气上等价于挂在 DUT 端口；而 DUT 的接口端口受 modport 方向约束，
  // 直接按名连接检查器不可行，故绑定挂具。
  bind vrf_axil_harness_dvp2axi vrf_axil_chk u_vrf_axil_chk (.*);
`endif

// -----------------------------------------------------------------------------
// 挂具：DVP2axis 全部端口按名通配符自动连接
//   DVP 输入（pclk/prst_n/pdin/pvref/phref）由 tb 侧驱动：pclk/prst_n 为顶层时钟
//   与复位，pdin/pvref/phref 由 vrf_dvp_if 接口承载（第 3 阶段起由 DVP 激励发生器
//   驱动；寄存器阶段保持静态 0）。AXI-Stream 输出为接口端口（本模块是 AXI-Stream
//   主机），由 AXIS monitor 采样、tb 驱动 tready。
// -----------------------------------------------------------------------------
module vrf_axil_harness_dvp2axi (
  input logic pclk,
  input logic prst_n,
  input logic [7:0] pdin,
  input logic pvref,
  input logic phref,
  input logic aclk,
  input logic aresetn
);
  import vrf_axil_pkg::*;

  // AXI4-Lite 信号声明 + 接口挂接 + 句柄发布
  `VRF_AXIL_HOOK_DECL(32, 32, 4)

  // AXI-Stream 输出为接口端口（本模块是 AXI-Stream 主机）：tready 由 tb 驱动，
  // 其余信号由 AXIS monitor 采样（见 tb 内的轴监控进程）
  mst_if_axis #(.DWIDTH(256)) axis_m (
    .aclk    (aclk),
    .aresetn (aresetn)
  );

  // ------------------------ DUT 的 AXI4-Lite 接口实例 ------------------------
  // DVP2axis 是 AXI-Lite 从机，故用从机视角接口 slv_if_axil（与 DUT 端口一致）；
  // 接口参数必须与下方 DVP2axis 的 AXI_LITE_* 参数一致（接口参数不能在端口处重载）
  slv_if_axil #(.AWIDTH(32), .DWIDTH(32), .IDWIDTH(4)) slv_axil (
    .aclk    (aclk),
    .aresetn (aresetn)
  );

  // 挂具 AXI4-Lite 信号 <-> DUT 接口 逐根直连（保持原信号级挂接方式不变）
  assign slv_axil.awvalid = awvalid;              // 主机请求 -> DUT 从机接口
  assign slv_axil.awaddr  = awaddr;
  assign slv_axil.awport  = awport;
  assign slv_axil.wvalid  = wvalid;
  assign slv_axil.wdata   = wdata;
  assign slv_axil.wstrb   = wstrb;
  assign slv_axil.bready  = bready;
  assign slv_axil.arvalid = arvalid;
  assign slv_axil.araddr  = araddr;
  assign slv_axil.arport  = arport;
  assign slv_axil.rready  = rready;
  assign awready          = slv_axil.awready;     // DUT 从机响应 -> 挂具
  assign wready           = slv_axil.wready;
  assign bvalid           = slv_axil.bvalid;
  assign bid              = slv_axil.bid;
  assign bresp            = slv_axil.bresp;
  assign arready          = slv_axil.arready;
  assign rvalid           = slv_axil.rvalid;
  assign rdata            = slv_axil.rdata;
  assign rresp            = slv_axil.rresp;
  assign rid              = slv_axil.rid;

  // ------------------------ 被测 DUT：全部端口按名自动连接 ------------------------
  // slv_axil 端口与上方接口实例同名，由 `.*` 按名连接
  DVP2axis #(
    .DVP_DWIDTH            (8),
    .PIX_WIDTH             (16),
    .AXI_ID_WIDTH          (4),
    .AXI_STREAM_TID        (1),
    .AXI_STREAM_DWIDTH     (256),
    .AXI_STREAM_USER_WIDTH (4),
    .AXI_STREAM_TDEST_WIDTH(4),
    .AXI_LITE_DWIDTH       (32),
    .AXI_LITE_AWIDTH       (32),
    .AXI_LITE_BASE_ADDR_OFFSET(32'h0000_0000)
  ) u_dut (.*);
endmodule

// -----------------------------------------------------------------------------
// 顶层测试
// -----------------------------------------------------------------------------
module tb_dvp2ax_stream;
  import vrf_axil_pkg::*;
  import vrf_dvp_pkg::*;      // DVP 数据通路组件（激励/帧级参考模型/覆盖率）

  // ------------------------ 寄存器偏移 ------------------------
  localparam logic [31:0] ADDR_CTRL          = 32'h00;
  localparam logic [31:0] ADDR_STATUS        = 32'h04;
  localparam logic [31:0] ADDR_FRAME_CNT     = 32'h08;
  localparam logic [31:0] ADDR_ERR_FLAG      = 32'h0C;
  localparam logic [31:0] ADDR_INT_EN        = 32'h10;
  localparam logic [31:0] ADDR_INT_STATUS    = 32'h14;
  localparam logic [31:0] ADDR_VERSION       = 32'h18;
  localparam logic [31:0] ADDR_DVP_CTRL      = 32'h20;
  localparam logic [31:0] ADDR_IMG_WIDTH     = 32'h24;
  localparam logic [31:0] ADDR_IMG_HEIGHT    = 32'h28;
  localparam logic [31:0] ADDR_LINE_TOTAL    = 32'h2C;
  localparam logic [31:0] ADDR_FRAME_TOTAL   = 32'h30;
  localparam logic [31:0] ADDR_AXIS_CTRL     = 32'h40;
  localparam logic [31:0] ADDR_AXIS_TID      = 32'h44;
  localparam logic [31:0] ADDR_AXIS_TDEST    = 32'h48;
  localparam logic [31:0] ADDR_AXIS_TUSER    = 32'h4C;
  localparam logic [31:0] ADDR_FIFO_STATUS   = 32'h60;
  localparam logic [31:0] ADDR_FIFO_THRESHOLD= 32'h64;
  localparam logic [31:0] ADDR_DBG_STATE     = 32'h70;
  localparam logic [31:0] ADDR_DBG_PIX_CNT   = 32'h74;
  localparam logic [31:0] ADDR_DBG_LINE_CNT  = 32'h78;
  localparam logic [31:0] ADDR_DBG_BEAT_CNT  = 32'h7C;
  localparam logic [31:0] ADDR_SCRATCH       = 32'h80;

  logic aclk    = 1'b0;
  logic aresetn = 1'b0;
  logic pclk    = 1'b0;      // DVP 像素时钟（周期 20ns，aclk 周期 10ns）
  logic prst_n  = 1'b0;      // pclk 域异步复位

  // DVP 输入接口：pdin/pvref/phref 由 DVP 激励发生器驱动（寄存器阶段静态 0）
  vrf_dvp_if #(.DWIDTH(8)) u_dvp_if (
    .pclk (pclk)
  );

  vrf_axil_harness_dvp2axi u_harness (
    .pclk    (pclk),
    .prst_n  (prst_n),
    .pdin    (u_dvp_if.pdin),
    .pvref   (u_dvp_if.pvref),
    .phref   (u_dvp_if.phref),
    .aclk    (aclk),
    .aresetn (aresetn)
  );

  always #5  aclk = ~aclk;
  always #10 pclk = ~pclk;

  vrf_axil_cfg   cfg;
  vrf_axil_env_t env;

  logic [31:0] rw_list[$];
  logic [31:0] ro_list[$];
  int unsigned seed;
  int          n_rand;
  string       log_dir;
  bit          ok;

  // ------------------------------ 辅助构造 ------------------------------
  function vrf_axil_txn_t mk_rd(string name, logic [31:0] addr);
    vrf_axil_txn_t t;
    t = new(name);
    t.txn_dir  = AXIL_RD;
    t.txn_addr = addr;
    t.txn_strb = '1;
    return t;
  endfunction

  function vrf_axil_txn_t mk_wr(string name, logic [31:0] addr,
                                logic [31:0] data, logic [3:0] strb);
    vrf_axil_txn_t t;
    t = new(name);
    t.txn_dir  = AXIL_WR;
    t.txn_addr = addr;
    t.txn_data = data;
    t.txn_strb = strb;
    return t;
  endfunction

  // 内部事件注入：层次化 force 一个周期后释放，并同步寄存器模型
  task automatic inject_event(string ev);
    case (ev)
      "frame_done": begin
        force u_harness.u_dut.frame_done_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.frame_done_event;
        env.model.event_frame_done();
      end
      "fifo_overflow": begin
        force u_harness.u_dut.fifo_overflow_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.fifo_overflow_event;
        env.model.event_fifo_overflow();
      end
      "line_err": begin
        force u_harness.u_dut.line_err_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.line_err_event;
        env.model.event_line_err();
      end
      "frame_err": begin
        force u_harness.u_dut.frame_err_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.frame_err_event;
        env.model.event_frame_err();
      end
      "axis_err": begin
        force u_harness.u_dut.axis_err_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.axis_err_event;
        env.model.event_axis_err();
      end
      "cfg_err": begin
        force u_harness.u_dut.cfg_err_event = 1'b1;
        @(posedge aclk);
        release u_harness.u_dut.cfg_err_event;
        env.model.event_cfg_err();
      end
      default: $display("[VRF_AXIL][WARN] 未知事件 %s", ev);
    endcase
    repeat (2) @(posedge aclk);
  endtask

  // ------------------------------ 定向功能测试 ------------------------------
  // 1) 复位默认值回读
  task automatic ph_reset_defaults();
    $display("[%0t][TB] 定向：复位默认值回读", $time);
    foreach (env.model.regs[i]) begin
      env.submit(mk_rd("reset_default", env.model.regs[i].offset));
    end
    env.wait_idle();
  endtask

  // 2) 全部 R/W 寄存器写入后回读一致
  task automatic ph_rw_readback();
    $display("[%0t][TB] 定向：R/W 寄存器写入回读", $time);
    foreach (rw_list[i]) begin
      env.submit(mk_wr("rw_write", rw_list[i], rw_list[i] + 32'h1234_5600 + 32'h00A5, 4'hF));
      env.submit(mk_rd("rw_read",  rw_list[i]));
    end
    env.wait_idle();
  endtask

  // 3) wstrb 字节使能
  task automatic ph_wstrb();
    logic [3:0] s;
    $display("[%0t][TB] 定向：wstrb 字节使能", $time);
    env.submit(mk_wr("wstrb_pre", ADDR_SCRATCH, 32'h0000_0000, 4'hF));
    for (int i = 0; i < 5; i++) begin
      case (i)
        0: s = 4'b0001;
        1: s = 4'b0010;
        2: s = 4'b0100;
        3: s = 4'b1000;
        default: s = 4'b1010;
      endcase
      env.submit(mk_wr("wstrb_write", ADDR_SCRATCH, 32'hFFFF_FFFF, s));
      env.submit(mk_rd("wstrb_read",  ADDR_SCRATCH));
    end
    env.wait_idle();
  endtask

  // 4) CTRL 自清零位与写动作
  task automatic ph_ctrl_actions();
    $display("[%0t][TB] 定向：CTRL 自清零与写动作", $time);
    env.submit(mk_wr("ctrl_en",      ADDR_CTRL, 32'h0000_0001, 4'hF)); // EN 置位
    env.submit(mk_rd("ctrl_rd",      ADDR_CTRL));
    env.submit(mk_wr("ctrl_softrst", ADDR_CTRL, 32'h0000_0002, 4'hF)); // SOFT_RST
    env.submit(mk_rd("ctrl_rd",      ADDR_CTRL));
    env.submit(mk_wr("ctrl_clrcnt",  ADDR_CTRL, 32'h0000_0010, 4'hF)); // CLR_CNT
    env.submit(mk_rd("ctrl_rd",      ADDR_CTRL));
    env.submit(mk_wr("ctrl_clrfifo", ADDR_CTRL, 32'h0000_0020, 4'hF)); // CLR_FIFO
    env.submit(mk_rd("ctrl_rd",      ADDR_CTRL));
    env.wait_idle();
  endtask

  // 5) 内部粘滞事件对计数/错误/中断状态的影响
  task automatic ph_events();
    $display("[%0t][TB] 定向：内部事件注入", $time);
    inject_event("frame_done");
    env.submit(mk_rd("ev_frame_cnt",  ADDR_FRAME_CNT));
    env.submit(mk_rd("ev_int_status", ADDR_INT_STATUS));
    env.wait_idle();

    inject_event("fifo_overflow");
    inject_event("line_err");
    inject_event("frame_err");
    inject_event("axis_err");
    inject_event("cfg_err");
    env.submit(mk_rd("ev_err_flag",   ADDR_ERR_FLAG));
    env.submit(mk_rd("ev_int_status", ADDR_INT_STATUS));
    env.wait_idle();
  endtask

  // 6) W1C 清除行为
  task automatic ph_w1c();
    $display("[%0t][TB] 定向：W1C 清除", $time);
    env.submit(mk_wr("w1c_err", ADDR_ERR_FLAG,   32'h0000_001F, 4'hF));
    env.submit(mk_rd("w1c_err", ADDR_ERR_FLAG));
    env.submit(mk_wr("w1c_int", ADDR_INT_STATUS, 32'h0000_001F, 4'hF));
    env.submit(mk_rd("w1c_int", ADDR_INT_STATUS));
    env.wait_idle();
  endtask

  // 7) SOFT_RST / CLR_CNT 对状态寄存器的作用
  task automatic ph_softrst_cmp();
    $display("[%0t][TB] 定向：SOFT_RST / CLR_CNT 行为对比", $time);
    inject_event("frame_done");
    inject_event("fifo_overflow");
    env.submit(mk_rd("pre_clr_frame_cnt", ADDR_FRAME_CNT));
    env.submit(mk_rd("pre_clr_err_flag",  ADDR_ERR_FLAG));
    env.submit(mk_rd("pre_clr_int_stat",  ADDR_INT_STATUS));
    env.wait_idle();

    // CLR_CNT：清 FRAME_CNT 与 ERR_FLAG，但保留 INT_STATUS
    env.submit(mk_wr("clr_cnt", ADDR_CTRL, 32'h0000_0010, 4'hF));
    env.submit(mk_rd("post_clr_frame_cnt", ADDR_FRAME_CNT));
    env.submit(mk_rd("post_clr_err_flag",  ADDR_ERR_FLAG));
    env.submit(mk_rd("post_clr_int_stat",  ADDR_INT_STATUS));
    env.wait_idle();

    // SOFT_RST：清计数/错误/中断状态，但保留配置寄存器
    env.submit(mk_wr("cfg_before_rst", ADDR_IMG_WIDTH, 32'h0000_0123, 4'hF));
    env.submit(mk_wr("soft_rst",       ADDR_CTRL,      32'h0000_0002, 4'hF));
    env.submit(mk_rd("post_rst_int_stat", ADDR_INT_STATUS));
    env.submit(mk_rd("post_rst_cfg",      ADDR_IMG_WIDTH));
    env.wait_idle();
  endtask

  // 8) 只读寄存器写保护
  task automatic ph_ro_protect();
    $display("[%0t][TB] 定向：只读寄存器写保护", $time);
    foreach (ro_list[i]) begin
      env.submit(mk_wr("ro_write", ro_list[i], 32'hFFFF_FFFF, 4'hF));
      env.submit(mk_rd("ro_read",  ro_list[i]));
    end
    env.wait_idle();
  endtask

  // 9) 未映射地址与保留地址
  task automatic ph_unmapped();
    $display("[%0t][TB] 定向：未映射/保留地址", $time);
    env.submit(mk_rd("unmapped_rd", 32'h0000_0100));
    env.submit(mk_wr("unmapped_wr", 32'h0000_0100, 32'hFFFF_FFFF, 4'hF));
    env.submit(mk_rd("unmapped_rd", 32'h0000_0100));
    env.submit(mk_rd("reserved_rd", 32'h0000_001C));
    env.submit(mk_wr("reserved_wr", 32'h0000_0034, 32'hFFFF_FFFF, 4'hF));
    env.submit(mk_rd("reserved_rd", 32'h0000_0034));
    env.submit(mk_rd("reserved_rd", 32'h0000_0050));
    env.wait_idle();
  endtask

  // 10) B / R 通道反压
  task automatic ph_backpressure();
    vrf_axil_txn_t t;
    $display("[%0t][TB] 定向：B/R 通道反压", $time);
    t = mk_wr("bp_write", ADDR_SCRATCH, 32'h0000_5A5A, 4'hF);
    t.force_bready_delay = 10;
    env.submit(t);
    t = mk_rd("bp_read", ADDR_SCRATCH);
    t.force_rready_delay = 10;
    env.submit(t);
    env.wait_idle();
  endtask

  // 11) AW / W 分离握手
  task automatic ph_aw_w_split();
    vrf_axil_txn_t t;
    $display("[%0t][TB] 定向：AW/W 分离握手", $time);
    t = mk_wr("aw_w_split", ADDR_SCRATCH, 32'h0000_1234, 4'hF);
    t.aw_delay = 0;
    t.w_delay  = 12;
    env.submit(t);
    t = mk_rd("aw_w_split_rd", ADDR_SCRATCH);
    env.submit(t);
    env.wait_idle();
  endtask

  // 12) 读、写通道并发
  task automatic ph_concurrent();
    $display("[%0t][TB] 定向：读写通道并发", $time);
    env.submit(mk_wr("conc_write", ADDR_FIFO_THRESHOLD, 32'h0000_0022, 4'hF));
    env.submit(mk_rd("conc_read",  ADDR_IMG_HEIGHT));
    env.wait_idle();
  endtask

  // 13) 复位打断响应事务 + 复位后默认值校验
  //     注意：异步 FIFO 的写侧（prst_n）与读侧（aresetn）必须同时复位，否则指针失配
  //     （本用例此前已驱动过数据通路，故此处补充 prst_n 脉冲）
  task automatic ph_reset_test();
    vrf_axil_txn_t t;
    $display("[%0t][TB] 定向：B 通道事务期间异步复位", $time);
    t = mk_wr("reset_during_b", ADDR_SCRATCH, 32'hCAFE_BABE, 4'hF);
    t.force_bready_delay = 60;   // 长时间保持 bvalid，等待复位打断
    t.expect_interrupt   = 1;
    env.submit(t);

    fork
      begin
        wait (u_harness.u_dut.slv_axil.bvalid === 1'b1);
        @(posedge aclk);
        prst_n  = 1'b0;
        aresetn = 1'b0;
        repeat (3) @(posedge aclk);
        aresetn = 1'b1;
        repeat (3) @(posedge aclk);
        prst_n  = 1'b1;
        repeat (4) @(posedge aclk);
      end
    join_none

    env.wait_idle();

    // 复位后模型与 DUT 同步到默认值，再全部回读校验
    env.model.reset();
    foreach (env.model.regs[i]) begin
      env.submit(mk_rd("post_reset_default", env.model.regs[i].offset));
    end
    env.wait_idle();
  endtask

  // ------------------------------ 阶段三：DVP 数据通路用例 ------------------------------
  // 覆盖：正常帧（多分辨率/格式）、4 类边界（行短/行长/帧短/帧长）与组合、
  //       中断置位/W1C/使能门控、参数帧边界生效、FIFO 溢出
  //
  // 配置提交时序（见 RTL 第 7/12 节）：配置与采集使能均在 pvref 帧边界提交，
  //   因此每个用例的固定流程为：
  //     写配置（EN=0）-> 静默帧（只翻 pvref，提交配置且不产生输出）
  //     -> 写 EN=1 -> 热身帧（提交 EN=1，本帧不采集）-> 测量帧（采集并与参考模型比对）
  typedef struct {
    int  img_w;
    int  img_h;
    int  pix_fmt;
    bit  dvp_bswap;
    bit  pack_en;
    int  pack_mode;
    bit  axis_bswap;
    bit  tlast_mode;
    bit  tstrb_en;
  } dvp_cfg_t;

  vrf_dvp_driver_t     dvp_drv;
  vrf_axis_frame_chk_t dvp_chk;
  vrf_dvp_cov          dvp_cov;
  virtual mst_if_axis #(256) axis_vif;

  int  dvp_n_case = 0;
  int  dvp_n_fail = 0;
  bit  dvp_pclk_inv = 1'b0;    // DVP_CTRL.PCLK_INV（采样沿），由采样沿用例单独置位

  function int dvp_pix_bytes(int fmt);
    case (fmt)
      2:       return 1;
      4:       return 3;
      default: return 2;
    endcase
  endfunction

  function int dvp_px_per_beat(int pack_mode, bit pack_en, int pbytes);
    if (pack_mode == 1) return 1;
    if (pack_mode == 2) return 2;
    if (pack_mode == 3) return 4;
    if (!pack_en)       return 1;
    return (pbytes == 1) ? 32 : (pbytes == 2) ? 16 : 10;
  endfunction

  function logic [31:0] dvp_axis_ctrl_word(dvp_cfg_t c);
    logic [31:0] w;
    w      = '0;
    w[0]   = c.pack_en;
    w[1]   = c.axis_bswap;
    w[2]   = c.tlast_mode;
    w[3]   = c.tstrb_en;
    w[5:4] = c.pack_mode[1:0];
    return w;
  endfunction

  // AXIS 空闲等待：连续 quiet_cycles 拍无 tvalid 视为已排空
  task automatic wait_axis_idle(int quiet_cycles = 300);
    int q     = 0;
    int guard = 0;
    while ((q < quiet_cycles) && (guard < 500000)) begin
      @(posedge aclk);
      if (axis_vif.tvalid === 1'b1) q = 0;
      else                          q++;
      guard++;
    end
  endtask

  // 单次用例主流程
  //   说明：配置经「整组握手 + 帧边界提交」生效，每个 pvref 边沿最多推进一次请求，
  //   因此写完整批配置后需驱动若干个静默帧（只翻 pvref、不产生输出）把配置全部提交，
  //   之后再驱动测量帧即可确定性地使用新配置。
  task automatic dvp_run_case(string name, dvp_cfg_t c,
                              int line_delta, int frame_delta,
                              int boundary_code, int int_en_word,
                              bit exp_line_short, bit exp_line_long,
                              bit exp_frame_short, bit exp_frame_long);
    int  pbytes;
    int  ppx;
    int  n_lines;
    bit  ok;
    int  cmp0, err0;

    dvp_n_case++;
    pbytes = dvp_pix_bytes(c.pix_fmt);
    ppx    = dvp_px_per_beat(c.pack_mode, c.pack_en, pbytes);

    // ---- 1) 先关采集并提交（EN=0 生效），避免后续静默帧被判为「0 行帧」 ----
    //   注：此处可能因上一用例遗留的 EN=1 产生一次无行帧（会置边界标志），
    //       随后的 SOFT_RST 会把这些粘滞标志清掉，因此不影响本用例期望。
    env.submit(mk_wr("dvp_en0", ADDR_CTRL, 32'h0000_0000, 4'hF));
    env.wait_idle();
    dvp_drv.img_w = c.img_w; dvp_drv.img_h = c.img_h; dvp_drv.pix_bytes = pbytes;
    dvp_drv.line_pix_delta = 0; dvp_drv.frame_line_delta = 0;
    dvp_drv.line_override.delete();
    dvp_drv.drive_quiet_frames(2);

    // ---- 2) 清状态 + 写几何/格式/打包配置（EN 保持 0）----
    env.submit(mk_wr("dvp_softrst",  ADDR_CTRL, 32'h0000_0002, 4'hF));
    env.submit(mk_wr("dvp_int_en",   ADDR_INT_EN, int_en_word, 4'hF));
    env.submit(mk_wr("dvp_img_w",    ADDR_IMG_WIDTH,  c.img_w, 4'hF));
    env.submit(mk_wr("dvp_img_h",    ADDR_IMG_HEIGHT, c.img_h, 4'hF));
    //   注：PIX_FMT 位于 DVP_CTRL[6:4]，此处按 int 移位后再截断（不可用 logic' 单比特转型）
    env.submit(mk_wr("dvp_dvp_ctrl", ADDR_DVP_CTRL,
                     (c.dvp_bswap ? 32'h0000_0080 : 32'h0) | (dvp_pclk_inv ? 32'h1 : 32'h0)
                     | (c.pix_fmt << 4), 4'hF));
    env.submit(mk_wr("dvp_axis_ctrl", ADDR_AXIS_CTRL, dvp_axis_ctrl_word(c), 4'hF));
    env.wait_idle();
    dvp_drv.data_seed = dvp_n_case;
    dvp_drv.drive_quiet_frames(5);          // 静默提交整批配置（EN=0，无输出、无边界事件）

    // ---- 3) 打开采集（EN=1 由下一次帧边沿提交，本帧不采集）----
    env.submit(mk_wr("dvp_en1", ADDR_CTRL, 32'h0000_0001, 4'hF));
    env.wait_idle();
    dvp_drv.line_pix_delta   = line_delta;
    dvp_drv.frame_line_delta = frame_delta;
    dvp_drv.drive_frame();                  // 热身帧：提交 EN=1

    // ---- 4) 测量帧：帧级像素比对（配置与 EN 均已提交）----
    dvp_chk.pix_bytes    = pbytes;
    dvp_chk.target_bytes = ppx * pbytes;
    dvp_chk.dvp_bswap    = c.dvp_bswap;
    dvp_chk.axis_bswap   = c.axis_bswap;
    dvp_chk.tlast_mode   = c.tlast_mode;
    dvp_chk.tstrb_en     = c.tstrb_en;

    dvp_chk.begin_frame();
    dvp_drv.drive_frame();
    wait_axis_idle();

    dvp_chk.build_expect(c.img_w, c.img_h, dvp_drv.n_sent_lines,
                         dvp_drv.sent_pix_cnt, dvp_drv.sent_pix);
    cmp0 = dvp_chk.n_cmp;
    err0 = dvp_chk.n_err;
    ok   = dvp_chk.compare_frame(name);
    env.ext_check_num += (dvp_chk.n_cmp - cmp0);
    env.ext_fail_num  += (dvp_chk.n_err - err0);
    $display("[%0t][TB]   %s：期望 %0d 拍 / 观测 %0d 拍 / 帧级比对%s",
             $time, name, dvp_chk.exp_len.size(), dvp_chk.obs_data.size(),
             ok ? "通过" : "失败");

    // ---- 6) 寄存器回读：帧计数 / 边界标志 / 中断 / 调试计数 ----
    // 配置已在帧边界提交完毕（EN=1 写入也已 ack），通知模型把 CFG_PENDING 归零
    env.model.notify_commit();
    // 模型同步（事件侧）；动态 RO 计数按本用例的期望置入镜像
    env.model.event_frame_done();
    if (exp_line_short)  env.model.event_line_short();
    if (exp_line_long)   env.model.event_line_long();
    if (exp_frame_short) env.model.event_frame_short();
    if (exp_frame_long)  env.model.event_frame_long();

    n_lines = dvp_drv.n_sent_lines;
    env.model.set_mirror(ADDR_DBG_PIX_CNT,  dvp_drv.sent_pix_cnt[n_lines-1]);
    env.model.set_mirror(ADDR_DBG_LINE_CNT, n_lines);
    env.model.set_mirror(ADDR_DBG_BEAT_CNT, dvp_chk.exp_len.size());

    env.submit(mk_rd("dvp_frame_cnt",  ADDR_FRAME_CNT));
    env.submit(mk_rd("dvp_err_flag",   ADDR_ERR_FLAG));
    env.submit(mk_rd("dvp_int_status", ADDR_INT_STATUS));
    env.submit(mk_rd("dvp_dbg_pix",    ADDR_DBG_PIX_CNT));
    env.submit(mk_rd("dvp_dbg_line",   ADDR_DBG_LINE_CNT));
    env.submit(mk_rd("dvp_dbg_beat",   ADDR_DBG_BEAT_CNT));
    env.submit(mk_rd("dvp_fifo_stat",  ADDR_FIFO_STATUS));
    env.submit(mk_rd("dvp_status",     ADDR_STATUS));
    env.wait_idle();

    dvp_cov.sample(boundary_code, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
    if (!ok) dvp_n_fail++;
  endtask

  // 中断用例：置位 -> W1C 清除 -> 使能门控（LINE_SHORT 事件）
  task automatic dvp_case_interrupt();
    dvp_cfg_t c;
    c = '{img_w:12, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:0};
    // (1) INT_EN=0：ERR_FLAG 置位、INT_STATUS[5] 被门控（仍置汇总位 [2]）
    $display("[%0t][TB] DVP 用例：中断使能门控关闭（INT_EN=0）", $time);
    dvp_run_case("int_gate_off", c, -5, 0, 1, 32'h0000_0000, 1, 0, 0, 0);
    // (2) W1C 清除：写 1 清 ERR_FLAG/INT_STATUS
    $display("[%0t][TB] DVP 用例：W1C 清除错误/中断标志", $time);
    env.submit(mk_wr("w1c_err", ADDR_ERR_FLAG,   32'h0000_01FF, 4'hF));
    env.submit(mk_rd("w1c_err_rd", ADDR_ERR_FLAG));
    env.submit(mk_wr("w1c_int", ADDR_INT_STATUS, 32'h0000_01FF, 4'hF));
    env.submit(mk_rd("w1c_int_rd", ADDR_INT_STATUS));
    env.wait_idle();
    dvp_cov.sample(1, 0, 0, 0, 0, 0);

    // (3) INT_EN[6]=1：同一事件置位 INT_STATUS[5]
    $display("[%0t][TB] DVP 用例：中断使能门控打开（INT_EN[6]=1）", $time);
    dvp_run_case("int_gate_on", c, -5, 0, 1, 32'h0000_0040, 1, 0, 0, 0);
  endtask

  // 参数帧边界生效：帧进行中写配置 -> 当帧不变；下一帧生效
  task automatic dvp_case_cfg_timing();
    dvp_cfg_t c;
    int       pbytes;
    int       cmp0, err0;

    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：参数帧边界生效（当帧不变 / 下一帧生效）", $time);
    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:0};
    pbytes = dvp_pix_bytes(c.pix_fmt);

    // 1) 关采集提交 + 清状态 + 配置 A（EN=0）+ 静默帧提交
    env.submit(mk_wr("cfg_en0", ADDR_CTRL, 32'h0000_0000, 4'hF));
    env.wait_idle();
    dvp_drv.img_w = c.img_w; dvp_drv.img_h = c.img_h; dvp_drv.pix_bytes = pbytes;
    dvp_drv.line_pix_delta = 0; dvp_drv.frame_line_delta = 0;
    dvp_drv.line_override.delete();
    dvp_drv.drive_quiet_frames(2);

    env.submit(mk_wr("cfg_a_softrst", ADDR_CTRL, 32'h0000_0002, 4'hF));
    env.submit(mk_wr("cfg_a_int_en",  ADDR_INT_EN, 32'h0, 4'hF));
    env.submit(mk_wr("cfg_a_w",  ADDR_IMG_WIDTH,  c.img_w, 4'hF));
    env.submit(mk_wr("cfg_a_h",  ADDR_IMG_HEIGHT, c.img_h, 4'hF));
    env.submit(mk_wr("cfg_a_dvp", ADDR_DVP_CTRL, 32'h0, 4'hF));
    env.submit(mk_wr("cfg_a_axis", ADDR_AXIS_CTRL, dvp_axis_ctrl_word(c), 4'hF));
    env.wait_idle();
    dvp_drv.data_seed = 900;
    dvp_drv.drive_quiet_frames(5);

    // 2) 打开采集 + 热身帧（提交 EN=1，本帧不采集）
    env.submit(mk_wr("cfg_a_en", ADDR_CTRL, 32'h0000_0001, 4'hF));
    env.wait_idle();
    dvp_drv.drive_frame();

    // 帧 1：使用配置 A（8 像素/行）
    dvp_chk.pix_bytes = pbytes; dvp_chk.target_bytes = 16 * pbytes;
    dvp_chk.dvp_bswap = 0; dvp_chk.axis_bswap = 0; dvp_chk.tlast_mode = 0; dvp_chk.tstrb_en = 0;
    dvp_chk.begin_frame();
    fork
      dvp_drv.drive_frame();                   // 帧 1（A 几何）
      begin
        repeat (40) @(posedge pclk);           // 帧进行中
        // 帧进行中改写几何：按「本帧用旧值」处理，本帧输出不受影响
        env.submit(mk_wr("cfg_b_w", ADDR_IMG_WIDTH,  6, 4'hF));
        env.submit(mk_wr("cfg_b_h", ADDR_IMG_HEIGHT, 2, 4'hF));
        env.wait_idle();
      end
    join
    wait_axis_idle();
    cmp0 = dvp_chk.n_cmp; err0 = dvp_chk.n_err;
    dvp_chk.build_expect(c.img_w, c.img_h, dvp_drv.n_sent_lines,
                         dvp_drv.sent_pix_cnt, dvp_drv.sent_pix);
    if (!dvp_chk.compare_frame("cfg_timing_frame1"))
      env.ext_fail_num++;
    env.ext_check_num += (dvp_chk.n_cmp - cmp0);
    env.ext_fail_num  += (dvp_chk.n_err - err0);
    env.model.event_frame_done();

    // 帧 2：使用配置 B（6 像素/行）
    dvp_drv.img_w = 6;
    dvp_drv.line_override.delete();
    dvp_chk.begin_frame();
    dvp_drv.drive_frame();
    wait_axis_idle();
    cmp0 = dvp_chk.n_cmp; err0 = dvp_chk.n_err;
    dvp_chk.build_expect(6, 2, dvp_drv.n_sent_lines, dvp_drv.sent_pix_cnt, dvp_drv.sent_pix);
    if (!dvp_chk.compare_frame("cfg_timing_frame2"))
      env.ext_fail_num++;
    env.ext_check_num += (dvp_chk.n_cmp - cmp0);
    env.ext_fail_num  += (dvp_chk.n_err - err0);
    env.model.event_frame_done();

    env.model.set_mirror(ADDR_DBG_PIX_CNT,  dvp_drv.sent_pix_cnt[dvp_drv.n_sent_lines-1]);
    env.model.set_mirror(ADDR_DBG_LINE_CNT, dvp_drv.n_sent_lines);
    env.model.set_mirror(ADDR_DBG_BEAT_CNT, dvp_chk.exp_len.size());
    env.submit(mk_rd("cfg_t_frame_cnt", ADDR_FRAME_CNT));      // 期望 2 帧
    env.submit(mk_rd("cfg_t_img_w",     ADDR_IMG_WIDTH));      // 期望 6（新值）
    env.submit(mk_rd("cfg_t_err_flag",  ADDR_ERR_FLAG));       // 期望 0（无边界错误）
    env.wait_idle();
    dvp_cov.sample(0, 0, 0, 0, 0, 0);
  endtask

  // FIFO 溢出：读侧长时间不就绪（tready=0）导致写满后丢弃并上报
  task automatic dvp_case_fifo_ovf();
    dvp_cfg_t c;
    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：FIFO 溢出（读侧不就绪）", $time);
    // 1 像素/拍、1100 拍 > FIFO 深度 1024
    c = '{img_w:1100, img_h:1, pix_fmt:2, dvp_bswap:0, pack_en:0, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:0};

    // 1) 关采集提交 + 清状态 + 配置（EN=0）+ 静默提交
    env.submit(mk_wr("ovf_en0", ADDR_CTRL, 32'h0000_0000, 4'hF));
    env.wait_idle();
    dvp_drv.img_w = c.img_w; dvp_drv.img_h = c.img_h; dvp_drv.pix_bytes = 1;
    dvp_drv.line_pix_delta = 0; dvp_drv.frame_line_delta = 0;
    dvp_drv.line_override.delete();
    dvp_drv.drive_quiet_frames(2);

    env.submit(mk_wr("ovf_softrst", ADDR_CTRL, 32'h0000_0002, 4'hF));
    env.submit(mk_wr("ovf_int_en",  ADDR_INT_EN, 32'h0, 4'hF));
    env.submit(mk_wr("ovf_img_w",   ADDR_IMG_WIDTH,  c.img_w, 4'hF));
    env.submit(mk_wr("ovf_img_h",   ADDR_IMG_HEIGHT, c.img_h, 4'hF));
    env.submit(mk_wr("ovf_dvp",     ADDR_DVP_CTRL,   (c.pix_fmt << 4), 4'hF));
    env.submit(mk_wr("ovf_axis",    ADDR_AXIS_CTRL, dvp_axis_ctrl_word(c), 4'hF));
    env.wait_idle();
    dvp_drv.data_seed = 77;
    dvp_drv.drive_quiet_frames(5);

    // 2) 打开采集 + 热身帧（提交 EN=1，本帧不采集，避免未被采集而测不到溢出）
    env.submit(mk_wr("ovf_en1", ADDR_CTRL, 32'h0000_0001, 4'hF));
    env.wait_idle();
    dvp_drv.drive_frame();

    u_harness.axis_m.tready = 1'b0;            // 读侧堵塞
    dvp_drv.drive_frame();                     // 测量帧：写满后丢弃 -> 溢出
    repeat (20) @(posedge aclk);               // 等溢出事件跨域落到 aclk（翻转位 + 2 级同步）
    u_harness.axis_m.tready = 1'b1;            // 恢复读侧并排空
    wait_axis_idle();

    // 模型同步：FIFO 溢出事件（满时写入被丢弃）+ FIFO_STATUS 溢出粘滞位
    //   说明：本用例读侧堵塞导致尾部 beat（含帧末拍）被丢弃，因此不产生 frame_done，
    //   FRAME_CNT/DBG 计数不作为本用例检查项（语义见 Doc/Dev_report_0923.md）
    env.model.event_fifo_overflow();
    env.model.set_mirror(ADDR_FIFO_STATUS, 32'h0006_0000);   // EMPTY + OVERFLOW
    env.submit(mk_rd("ovf_err_flag",  ADDR_ERR_FLAG));
    env.submit(mk_rd("ovf_int_stat",  ADDR_INT_STATUS));
    env.submit(mk_rd("ovf_fifo_stat", ADDR_FIFO_STATUS));
    env.wait_idle();
    dvp_cov.sample(0, 0, 2, 1, 0, 0);
  endtask

  // ------------------------------ 扩展用例：未实现项补齐后的定向验证 ------------------------------
  // 配置提交序列（写配置 → 静默帧提交 → 写 EN=1 → 热身帧），供扩展用例复用
  task automatic dvp_setup(dvp_cfg_t c, int int_en_word, bit with_en, bit warmup);
    int pbytes;
    pbytes = dvp_pix_bytes(c.pix_fmt);

    env.submit(mk_wr("set_en0", ADDR_CTRL, 32'h0000_0000, 4'hF));
    env.wait_idle();
    dvp_drv.img_w = c.img_w; dvp_drv.img_h = c.img_h; dvp_drv.pix_bytes = pbytes;
    dvp_drv.line_pix_delta = 0; dvp_drv.frame_line_delta = 0;
    dvp_drv.line_override.delete();
    dvp_drv.drive_quiet_frames(2);

    env.submit(mk_wr("set_softrst", ADDR_CTRL, 32'h0000_0002, 4'hF));
    env.submit(mk_wr("set_int_en",  ADDR_INT_EN, int_en_word, 4'hF));
    env.submit(mk_wr("set_img_w",   ADDR_IMG_WIDTH,  c.img_w, 4'hF));
    env.submit(mk_wr("set_img_h",   ADDR_IMG_HEIGHT, c.img_h, 4'hF));
    env.submit(mk_wr("set_dvp",     ADDR_DVP_CTRL,
                     (c.dvp_bswap ? 32'h80 : 32'h0) | (dvp_pclk_inv ? 32'h1 : 32'h0)
                     | (c.pix_fmt << 4), 4'hF));
    env.submit(mk_wr("set_axis",    ADDR_AXIS_CTRL, dvp_axis_ctrl_word(c), 4'hF));
    env.submit(mk_wr("set_fifo_th", ADDR_FIFO_THRESHOLD, 32'h0, 4'hF));  // 关闭高水位指示（恢复默认）
    env.wait_idle();
    dvp_drv.drive_quiet_frames(5);

    if (with_en) begin
      env.submit(mk_wr("set_en1", ADDR_CTRL, 32'h0000_0001, 4'hF));
      env.wait_idle();
      if (warmup) dvp_drv.drive_frame();       // 热身帧：提交 EN=1（本帧不采集）
    end
  endtask

  // AXIS_ERR：tvalid 持续有效而 tready 长期不就绪（超时门限 8192 个 aclk）
  task automatic dvp_case_axis_timeout();
    dvp_cfg_t c;
    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：AXIS_ERR（tready 超时）", $time);
    c = '{img_w:8, img_h:1, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_setup(c, 32'h0, 1'b1, 1'b1);

    dvp_drv.data_seed = 500;
    u_harness.axis_m.tready = 1'b0;            // 读侧不就绪：1 拍留在 FIFO，tvalid 持续有效
    dvp_drv.drive_frame();
    repeat (9000) @(posedge aclk);             // > AXIS_TREADY_TIMEOUT(8192)

    env.model.event_axis_err();
    env.submit(mk_rd("tmo_frame_cnt", ADDR_FRAME_CNT));    // 期望 0（帧末拍未被接收）
    env.submit(mk_rd("tmo_err_flag",  ADDR_ERR_FLAG));     // 期望 AXIS_ERR
    env.submit(mk_rd("tmo_int_stat",  ADDR_INT_STATUS));   // 期望 AXIS_ERR 中断位
    env.wait_idle();

    u_harness.axis_m.tready = 1'b1;            // 恢复握手并排空
    wait_axis_idle();
    dvp_cov.sample(0, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
  endtask

  // FIFO_THRESHOLD 参与判定：水位达到阈值置 FIFO_STATUS.ALMOST_FULL
  task automatic dvp_case_almost_full();
    dvp_cfg_t c;
    int beats;
    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：FIFO_THRESHOLD 高水位指示", $time);
    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_setup(c, 32'h0, 1'b1, 1'b1);
    env.submit(mk_wr("af_thresh", ADDR_FIFO_THRESHOLD, 32'd2, 4'hF));   // 阈值 = 2
    env.wait_idle();

    dvp_drv.data_seed = 600;
    u_harness.axis_m.tready = 1'b0;            // 数据堆积在 FIFO
    dvp_chk.begin_frame();
    dvp_drv.drive_frame();
    repeat (20) @(posedge aclk);

    beats = 2;                                 // 8 像素/行 × 2 字节 = 16 字节 -> 1 拍/行，2 行 = 2 拍
    env.model.set_mirror(ADDR_FIFO_STATUS, 32'h0010_0000 | beats);      // ALMOST_FULL + LEVEL
    env.model.notify_commit();
    env.submit(mk_rd("af_fifo_stat", ADDR_FIFO_STATUS));
    env.wait_idle();

    u_harness.axis_m.tready = 1'b1;
    wait_axis_idle();
    env.model.set_mirror(ADDR_FIFO_STATUS, '0);  // 交回读预测回调（空闲稳态）
    dvp_cov.sample(0, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
  endtask

  // CFG_ERR：提交非法 PIX_FMT（>4）时置位且不采集
  task automatic dvp_case_cfg_err();
    dvp_cfg_t c;
    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：CFG_ERR（PIX_FMT 非法）", $time);
    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    // EN=0 提交干净配置：避免静默帧（无 phref）在 EN=1 时被判为 0 行帧而置 FRAME_SHORT
    dvp_setup(c, 32'h0, 1'b0, 1'b0);

    env.submit(mk_wr("ce_dvp_bad", ADDR_DVP_CTRL, (32'd7 << 4), 4'hF));  // PIX_FMT=7 非法
    env.wait_idle();
    dvp_drv.drive_quiet_frames(3);             // EN=0：提交非法配置（产生 CFG_ERR），无边界事件

    env.submit(mk_wr("ce_en1", ADDR_CTRL, 32'h0000_0001, 4'hF));
    env.wait_idle();
    dvp_drv.drive_quiet_frames(2);             // 提交 EN=1（配置仍非法，不重复上报 CFG_ERR）

    dvp_drv.data_seed = 700;
    dvp_chk.begin_frame();
    dvp_drv.drive_frame();                     // 配置非法 -> 本帧不采集
    wait_axis_idle();

    env.model.notify_commit();
    env.model.event_cfg_err();
    env.submit(mk_rd("ce_frame_cnt", ADDR_FRAME_CNT));    // 期望 0
    env.submit(mk_rd("ce_err_flag",  ADDR_ERR_FLAG));     // 期望 CFG_ERR
    env.wait_idle();
    $display("[%0t][TB]   cfg_err：观测 %0d 拍（期望 0）", $time, dvp_chk.obs_data.size());
    if (dvp_chk.obs_data.size() != 0) env.ext_fail_num++;
    env.ext_check_num++;
    dvp_cov.sample(0, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
  endtask

  // STATUS.CFG_PENDING：写配置后在途为 1、帧边界提交后为 0
  task automatic dvp_case_cfg_pending();
    dvp_cfg_t c;
    dvp_n_case++;
    $display("[%0t][TB] DVP 用例：STATUS.CFG_PENDING（配置在途可观测）", $time);
    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_drv.img_w = c.img_w; dvp_drv.img_h = c.img_h; dvp_drv.pix_bytes = 2;
    dvp_drv.line_pix_delta = 0; dvp_drv.frame_line_delta = 0;
    dvp_drv.line_override.delete();

    // 1) 关采集并提交干净（在途清零）
    env.submit(mk_wr("cp_en0", ADDR_CTRL, 32'h0000_0000, 4'hF));
    env.wait_idle();
    dvp_drv.drive_quiet_frames(3);
    env.model.notify_commit();
    env.submit(mk_rd("cp_status_idle", ADDR_STATUS));     // 期望 0x10（CFG_PENDING=0）
    env.wait_idle();

    // 2) 写一批配置（未提交 -> 在途）
    env.submit(mk_wr("cp_softrst", ADDR_CTRL, 32'h0000_0002, 4'hF));
    env.submit(mk_wr("cp_img_w",   ADDR_IMG_WIDTH,  c.img_w, 4'hF));
    env.submit(mk_wr("cp_img_h",   ADDR_IMG_HEIGHT, c.img_h, 4'hF));
    env.submit(mk_wr("cp_dvp",     ADDR_DVP_CTRL, (c.pix_fmt << 4), 4'hF));
    env.submit(mk_wr("cp_axis",    ADDR_AXIS_CTRL, dvp_axis_ctrl_word(c), 4'hF));
    env.wait_idle();
    env.submit(mk_rd("cp_status_pend", ADDR_STATUS));     // 期望 0x50（CFG_PENDING=1）
    env.wait_idle();

    // 3) 驱动帧边界提交 -> 在途清零
    dvp_drv.drive_quiet_frames(5);
    env.model.notify_commit();
    env.submit(mk_rd("cp_status_done", ADDR_STATUS));     // 期望 0x10（CFG_PENDING=0）
    env.wait_idle();
    dvp_cov.sample(0, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
  endtask

  // 清除类写动作（跨域一致）：mode 0=CLR_CNT，1=CLR_FIFO，2=SOFT_RST
  task automatic dvp_case_clear(int mode);
    dvp_cfg_t c;
    int  beats;
    int  cmp0, err0;
    bit  use_stall;
    string name;
    dvp_n_case++;
    name = (mode == 0) ? "CLR_CNT" : (mode == 1) ? "CLR_FIFO" : "SOFT_RST";
    $display("[%0t][TB] DVP 用例：%s 跨域清除", $time, name);

    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_setup(c, 32'h0, 1'b1, 1'b1);
    dvp_drv.data_seed = 800 + mode;
    use_stall = (mode != 0);
    beats     = 2;

    if (!use_stall) begin
      // CLR_CNT：正常采集一帧（tready=1），随后清计数
      dvp_chk.pix_bytes    = 2;
      dvp_chk.target_bytes = 32;               // 自动打包：16 像素/拍 × 2 字节 = 32 字节（AXIS 位宽）
      dvp_chk.dvp_bswap    = 0;
      dvp_chk.axis_bswap   = 0;
      dvp_chk.tlast_mode   = 0;
      dvp_chk.tstrb_en     = 1;
      dvp_chk.begin_frame();
      dvp_drv.drive_frame();
      wait_axis_idle();
      dvp_chk.build_expect(c.img_w, c.img_h, dvp_drv.n_sent_lines,
                           dvp_drv.sent_pix_cnt, dvp_drv.sent_pix);
      cmp0 = dvp_chk.n_cmp; err0 = dvp_chk.n_err;
      if (!dvp_chk.compare_frame("clr_cnt_frame")) env.ext_fail_num++;
      env.ext_check_num += (dvp_chk.n_cmp - cmp0);
      env.ext_fail_num  += (dvp_chk.n_err - err0);
      env.model.event_frame_done();
      env.model.notify_commit();
      env.model.set_mirror(ADDR_DBG_BEAT_CNT, dvp_chk.exp_len.size());  // 本帧已输出 beat 数
      env.submit(mk_rd("clr_pre_frame_cnt", ADDR_FRAME_CNT));    // 期望 1
      env.submit(mk_rd("clr_pre_dbg_beat",  ADDR_DBG_BEAT_CNT)); // 期望 2
      env.wait_idle();
    end else begin
      // CLR_FIFO/SOFT_RST：读侧堵塞让 beat 堆积在 FIFO
      u_harness.axis_m.tready = 1'b0;
      dvp_chk.begin_frame();
      dvp_drv.drive_frame();
      repeat (20) @(posedge aclk);
      env.model.set_mirror(ADDR_FIFO_STATUS, beats);             // EMPTY=0、LEVEL=2
      env.model.notify_commit();
      env.submit(mk_rd("clr_pre_fifo", ADDR_FIFO_STATUS));       // 期望 LEVEL=2
      env.wait_idle();
    end

    // 写清除位（同时保持 EN=1，避免影响后续用例）
    case (mode)
      0:       env.submit(mk_wr("clr_wr", ADDR_CTRL, 32'h0000_0011, 4'hF));  // EN | CLR_CNT
      1:       env.submit(mk_wr("clr_wr", ADDR_CTRL, 32'h0000_0021, 4'hF));  // EN | CLR_FIFO
      default: env.submit(mk_wr("clr_wr", ADDR_CTRL, 32'h0000_0003, 4'hF));  // EN | SOFT_RST
    endcase
    env.wait_idle();
    repeat (20) @(posedge aclk);               // 等跨域清除完成

    // 清除后回读
    env.submit(mk_rd("clr_frame_cnt", ADDR_FRAME_CNT));          // 期望 0
    env.submit(mk_rd("clr_err_flag",  ADDR_ERR_FLAG));           // 期望 0
    env.submit(mk_rd("clr_dbg_pix",   ADDR_DBG_PIX_CNT));        // 期望 0（跨域清除生效）
    env.submit(mk_rd("clr_dbg_line",  ADDR_DBG_LINE_CNT));       // 期望 0
    env.submit(mk_rd("clr_dbg_beat",  ADDR_DBG_BEAT_CNT));       // 期望 0
    if (mode == 0) begin
      env.submit(mk_rd("clr_int_stat", ADDR_INT_STATUS));        // 期望保留帧完成中断位
    end else begin
      env.submit(mk_rd("clr_fifo_stat", ADDR_FIFO_STATUS));      // 期望 EMPTY（已冲刷）
      env.submit(mk_rd("clr_status",    ADDR_STATUS));           // 期望 0x50（AXIS 空闲 + 配置在途）
    end
    env.wait_idle();

    if (use_stall) begin
      // 冲刷后确认没有残留 beat 被送出
      repeat (100) @(posedge aclk);
      $display("[%0t][TB]   %s：冲刷后观测 %0d 拍（期望 0）", $time, name, dvp_chk.obs_data.size());
      if (dvp_chk.obs_data.size() != 0) env.ext_fail_num++;
      env.ext_check_num++;
      u_harness.axis_m.tready = 1'b1;
      wait_axis_idle();
      env.model.set_mirror(ADDR_FIFO_STATUS, '0);
    end
    dvp_cov.sample(0, c.tlast_mode, c.pix_fmt, c.pack_mode, c.axis_bswap, c.tstrb_en);
  endtask

  // 阶段三主入口：按矩阵跑全部 DVP 用例
  task automatic dvp_phases();
    dvp_cfg_t c;
    $display("[%0t][TB] ===== 阶段三：DVP 数据通路 / 边界处理 / 中断 用例 =====", $time);
    // 数据通路阶段关闭「失败回注 + 宽监视」：帧级失败会同时由帧级参考模型与逐笔事务
    // 报告给出，逐拍宽监视在长帧下会使日志爆炸（寄存器阶段仍保持开启）
    cfg.enable_repro = 0;

    // ---- 正常帧：多分辨率 × 多格式 × 打包模式 ----
    c = '{img_w:8,  img_h:4, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:0};
    dvp_run_case("normal_yuv422_auto_t0", c, 0, 0, 0, 32'h0, 0,0,0,0);

    c = '{img_w:12, img_h:3, pix_fmt:1, dvp_bswap:0, pack_en:1, pack_mode:2,
          axis_bswap:0, tlast_mode:1, tstrb_en:1};
    dvp_run_case("normal_rgb565_2ppb_t1", c, 0, 0, 0, 32'h0, 0,0,0,0);

    c = '{img_w:20, img_h:2, pix_fmt:2, dvp_bswap:0, pack_en:1, pack_mode:1,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("normal_raw8_1ppb_t0", c, 0, 0, 0, 32'h0, 0,0,0,0);

    c = '{img_w:7,  img_h:3, pix_fmt:4, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:1, tlast_mode:1, tstrb_en:1};
    dvp_run_case("normal_rgb888_be_t1", c, 0, 0, 0, 32'h0, 0,0,0,0);

    c = '{img_w:9,  img_h:4, pix_fmt:3, dvp_bswap:1, pack_en:1, pack_mode:3,
          axis_bswap:0, tlast_mode:1, tstrb_en:0};
    dvp_run_case("normal_raw10_4ppb_bswap", c, 0, 0, 0, 32'h0, 0,0,0,0);

    c = '{img_w:33, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:0, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("normal_yuv422_1px", c, 0, 0, 0, 32'h0, 0,0,0,0);

    // ---- 边界矩阵：4 类边界 × TLAST_MODE + 组合（行短且帧短）----
    c = '{img_w:12, img_h:3, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("line_short_t0", c, -5, 0, 1, 32'h0, 1,0,0,0);

    c.tlast_mode = 1;
    dvp_run_case("line_short_t1", c, -5, 0, 1, 32'h0, 1,0,0,0);

    c = '{img_w:8, img_h:3, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("line_long_t0", c, 6, 0, 2, 32'h0, 0,1,0,0);

    c.tlast_mode = 1;
    dvp_run_case("line_long_t1", c, 6, 0, 2, 32'h0, 0,1,0,0);

    c = '{img_w:8, img_h:5, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("frame_short_t0", c, 0, -2, 3, 32'h0, 0,0,1,0);

    c.tlast_mode = 1;
    dvp_run_case("frame_short_t1", c, 0, -2, 3, 32'h0, 0,0,1,0);

    c = '{img_w:8, img_h:3, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("frame_long_t0", c, 0, 3, 4, 32'h0, 0,0,0,1);

    c.tlast_mode = 1;
    dvp_run_case("frame_long_t1", c, 0, 3, 4, 32'h0, 0,0,0,1);

    c = '{img_w:10, img_h:4, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_run_case("short_combo_t0", c, -4, -2, 5, 32'h0, 1,0,1,0);

    c.tlast_mode = 1;
    dvp_run_case("short_combo_t1", c, -4, -2, 5, 32'h0, 1,0,1,0);

    // ---- 中断置位 / W1C / 使能门控 ----
    dvp_case_interrupt();

    // ---- 参数帧边界生效 ----
    dvp_case_cfg_timing();

    // ---- 未实现项补齐验证：采样沿 / 配置在途可观测 / CFG_ERR / 高水位 / AXIS 超时 / 跨域清除 ----
    c = '{img_w:8, img_h:2, pix_fmt:0, dvp_bswap:0, pack_en:1, pack_mode:0,
          axis_bswap:0, tlast_mode:0, tstrb_en:1};
    dvp_pclk_inv = 1'b1;                    // 下降沿采样（DVP_CTRL.PCLK_INV=1）
    dvp_run_case("pclk_inv_falling_edge", c, 0, 0, 0, 32'h0, 0,0,0,0);
    dvp_pclk_inv = 1'b0;
    dvp_case_cfg_pending();
    dvp_case_cfg_err();
    dvp_case_almost_full();
    dvp_case_axis_timeout();
    dvp_case_clear(0);      // CLR_CNT
    dvp_case_clear(1);      // CLR_FIFO
    dvp_case_clear(2);      // SOFT_RST

    // ---- FIFO 溢出（读侧不就绪）：放最后，其粘滞溢出位不影响后续用例 ----
    dvp_case_fifo_ovf();

    $display("[%0t][TB] DVP 用例小结：用例 %0d 个，帧级比对失败 %0d 个（累计拍 %0d，失败 %0d）",
             $time, dvp_n_case, dvp_n_fail, dvp_chk.n_cmp, dvp_chk.n_err);
    dvp_chk.report();
    $display("[%0t][TB] %s", $time, dvp_cov.report_string());
  endtask

  // ------------------------------ 主流程 ------------------------------
  initial begin
    seed = 0;
    if (!$value$plusargs("seed=%d", seed)) seed = $urandom;
    else void'($urandom(seed));

    log_dir = ".";
    void'($value$plusargs("log_dir=%s", log_dir));

    n_rand = 400;
    void'($value$plusargs("n_rand=%d", n_rand));

    $display("================================================================");
    $display(" VRF_AXI4L 接入示例 : tb_dvp2ax_stream");
    $display(" 被测对象 : RTL/DVP2axis.sv 的 AXI4-Lite 寄存器块");
    $display(" 随机种子 : %0d  (可用 +seed=%0d 复现)", seed, seed);
    $display("================================================================");

    // 复位
    aresetn = 1'b0;
    prst_n  = 1'b0;
    // DVP 输入静态 0（寄存器阶段无 DVP 活动，保证 pclk 域计数/状态恒为 0）
    u_dvp_if.pdin  = 8'h00;
    u_dvp_if.pvref = 1'b0;
    u_dvp_if.phref = 1'b0;
    // AXI-Stream 从端恒就绪（寄存器阶段 FIFO 恒空，不产生实际传输）
    u_harness.axis_m.tready = 1'b1;

    repeat (5) @(posedge aclk);
    aresetn = 1'b1;
    prst_n  = 1'b1;
    repeat (3) @(posedge aclk);

    // 寄存器清单
    rw_list = '{ADDR_CTRL, ADDR_INT_EN, ADDR_DVP_CTRL, ADDR_IMG_WIDTH, ADDR_IMG_HEIGHT,
                ADDR_LINE_TOTAL, ADDR_FRAME_TOTAL, ADDR_AXIS_CTRL, ADDR_AXIS_TID,
                ADDR_AXIS_TDEST, ADDR_AXIS_TUSER, ADDR_FIFO_THRESHOLD, ADDR_SCRATCH};
    ro_list = '{ADDR_STATUS, ADDR_FRAME_CNT, ADDR_VERSION, ADDR_FIFO_STATUS,
                ADDR_DBG_STATE, ADDR_DBG_PIX_CNT, ADDR_DBG_LINE_CNT, ADDR_DBG_BEAT_CNT};

    // 环境配置
    cfg = new("tb_dvp2ax_stream");
    cfg.seed               = seed;
    cfg.reg_map            = "DVP2AXI";
    cfg.addr_min           = 32'h00;
    cfg.addr_max           = 32'h80;
    cfg.bringup_probe_addr = ADDR_SCRATCH;
    cfg.log_dir            = log_dir;
    cfg.n_rand_txn         = 0;          // 随机事务由测试直接控制
    cfg.enable_directed    = 0;
    cfg.enable_repro       = 1;
    cfg.repro_max_attempts = 2;
    cfg.verbose            = 1;
    cfg.timeout_cycles     = 200;

    // 环境组装与启动（含上电连通性自检）
    env = new(cfg);
    env.connect();
    env.start();

    // ---- DVP 数据通路组件（阶段三）----
    axis_vif = u_harness.axis_m;
    dvp_drv  = new(u_dvp_if);
    dvp_chk  = new();
    dvp_cov  = new();
    // AXIS 输出监视：每拍握手推入帧级参考模型
    fork
      forever begin
        @(axis_vif.cb);
        if (axis_vif.cb.tvalid === 1'b1 && axis_vif.cb.tready === 1'b1) begin
          dvp_chk.push_beat(axis_vif.cb.tdata, axis_vif.cb.tstrb,
                            axis_vif.cb.tkeep, axis_vif.cb.tlast);
        end
      end
    join_none

    // ---- 定向功能测试 ----
    ph_reset_defaults();
    ph_rw_readback();
    ph_wstrb();
    ph_ctrl_actions();
    ph_events();
    ph_w1c();
    ph_softrst_cmp();
    ph_ro_protect();
    ph_unmapped();
    ph_backpressure();
    ph_aw_w_split();
    ph_concurrent();

    // ---- 受约束随机回归 ----
    $display("[%0t][TB] 随机回归：%0d 笔受约束随机事务", $time, n_rand);
    env.run_random(n_rand);
    env.wait_idle();

    // ---- 数据通路 / 边界处理 / 中断（阶段三）----
    dvp_phases();

    // ---- 复位测试 ----
    ph_reset_test();

    // ---- 收尾与报告 ----
    env.stop();
    env.report();

    ok = env.is_pass();
    $display("================================================================");
    $display(" DVP2axis 寄存器块验证结论 : %s", ok ? "PASSED" : "FAILED");
    $display(" 总检查项 : 总线比对 %0d + 数据通路帧级比对 %0d + 协议断言 %0d + 连通性自检 %0d = %0d",
             env.sb.n_checked, env.ext_check_num, vrf_axil_ctrl::assert_chk_cnt,
             env.bringup.n_checked, env.total_checks());
    $display("================================================================");
    if (!ok) $display("SIMULATION FAILED");
    else     $display("SIMULATION PASSED");
    $finish;
  end
endmodule
