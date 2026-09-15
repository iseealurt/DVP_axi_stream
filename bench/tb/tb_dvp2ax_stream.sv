`timescale 1ns/1ps
// =============================================================================
// DVP2axi_stream 接入示例：以 VRF_AXI4L 库对 RTL/DVP2axi_stream.v 的
// AXI4-Lite 寄存器块做完整功能验证。
//   演示内容：
//     - 挂具模块 + DVP2axi_stream 全部端口 `.*` 通配符自动连接
//     - 细粒度环境 API：connect / start / submit / wait_idle / stop / report
//     - 定向功能测试（对标历史仿真报告的覆盖项）+ 受约束随机回归
//     - 内部事件注入（层次化 force）后由寄存器模型同步预测
//     - 复位打断响应事务的容错处理
//     - 协议断言、连通性自检、覆盖率与报告输出
// =============================================================================

// -----------------------------------------------------------------------------
// 挂具：DVP2axi_stream 全部端口按名通配符自动连接
//   本轮验证范围为 AXI4-Lite 寄存器接口，DVP 输入与 AXI-Stream 输出端口
//   仅作占位声明（不 tie-off），由连通性自检报告头统一标注。
// -----------------------------------------------------------------------------
module vrf_axil_harness_dvp2axi (
  input logic pclk,
  input logic prst_n,
  input logic aclk,
  input logic aresetn
);
  import vrf_axil_pkg::*;

  // AXI4-Lite 信号声明 + 接口挂接 + 句柄发布
  `VRF_AXIL_HOOK_DECL(32, 32, 4)

  // ------------------------ 本轮不纳入验证的端口占位 ------------------------
  // 按开发计划边界处理：不做 tie-off，保持未驱动并由报告头统一告警
  wire [7:0]   pdin;
  wire         pvref;
  wire         phref;
  wire         axis_tready;
  wire         axis_tvalid;
  wire [255:0] axis_tdata;
  wire [31:0]  axis_tstrb;
  wire [31:0]  axis_tkeep;
  wire         axis_tlast;

  // ------------------------ 被测 DUT：全部端口按名自动连接 ------------------------
  DVP2axi_stream #(
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

  vrf_axil_harness_dvp2axi u_harness (
    .pclk    (),
    .prst_n  (),
    .aclk    (aclk),
    .aresetn (aresetn)
  );

  always #5 aclk = ~aclk;

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
  task automatic ph_reset_test();
    vrf_axil_txn_t t;
    $display("[%0t][TB] 定向：B 通道事务期间异步复位", $time);
    t = mk_wr("reset_during_b", ADDR_SCRATCH, 32'hCAFE_BABE, 4'hF);
    t.force_bready_delay = 60;   // 长时间保持 bvalid，等待复位打断
    t.expect_interrupt   = 1;
    env.submit(t);

    fork
      begin
        wait (u_harness.u_dut.bvalid === 1'b1);
        @(posedge aclk);
        aresetn = 1'b0;
        repeat (3) @(posedge aclk);
        aresetn = 1'b1;
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
    $display(" 被测对象 : RTL/DVP2axi_stream.v 的 AXI4-Lite 寄存器块");
    $display(" 随机种子 : %0d  (可用 +seed=%0d 复现)", seed, seed);
    $display("================================================================");

    // 复位
    aresetn = 1'b0;
    repeat (5) @(posedge aclk);
    aresetn = 1'b1;
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

    // ---- 复位测试 ----
    ph_reset_test();

    // ---- 收尾与报告 ----
    env.stop();
    env.report();

    ok = env.is_pass();
    $display("================================================================");
    $display(" DVP2axi_stream 寄存器块验证结论 : %s", ok ? "PASSED" : "FAILED");
    $display(" 总检查项 : 事务比对 %0d + 协议断言 %0d + 连通性自检 %0d = %0d",
             env.sb.n_checked, vrf_axil_ctrl::assert_chk_cnt,
             env.bringup.n_checked, env.total_checks());
    $display("================================================================");
    if (!ok) $display("SIMULATION FAILED");
    else     $display("SIMULATION PASSED");
    $finish;
  end
endmodule
