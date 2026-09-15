`timescale 1ns/1ps
// =============================================================================
// 库自测用例（demo）
//   被测对端：AXI4-Lite 从机参考模型（不依赖任何 RTL 完成度）
//   演示内容：
//     - 挂具模块 + 端口通配符自动连接（VRF_AXIL_HOOK_DECL + `.*`）
//     - 定向用例按名注册并自动挂载到定向队列
//     - env.run_all() 一键启用环境并完成验证
//     - 寄存器模型自动预测、覆盖率收集、协议断言、报告输出
// =============================================================================

// -----------------------------------------------------------------------------
// 挂具：AXI4-Lite 端口按名与被测从机参考模型自动连接
// -----------------------------------------------------------------------------
module vrf_axil_harness_ref #(
  parameter int AW      = 32,
  parameter int DW      = 32,
  parameter int ID      = 4,
  parameter int RDY_MIN = 0,
  parameter int RDY_MAX = 2
)(
  input logic aclk,
  input logic aresetn
);
  import vrf_axil_pkg::*;

  // 通配符自动连接挂钩：声明与 DUT 端口同名的信号并挂接接口
  `VRF_AXIL_HOOK_DECL(AW, DW, ID)

  // 从机参考模型：端口按名自动连接
  vrf_axil_slv_ref #(
    .AWIDTH(AW), .DWIDTH(DW), .IDWIDTH(ID),
    .RDY_DLY_MIN(RDY_MIN), .RDY_DLY_MAX(RDY_MAX)
  ) u_dut (.*);
endmodule

// -----------------------------------------------------------------------------
// 顶层测试
// -----------------------------------------------------------------------------
module tb_vrf_axil_demo;
  import vrf_axil_pkg::*;

  localparam int AW = 32;
  localparam int DW = 32;
  localparam int ID = 4;

  logic aclk    = 1'b0;
  logic aresetn = 1'b0;

  vrf_axil_harness_ref #(.AW(AW), .DW(DW), .ID(ID), .RDY_MIN(0), .RDY_MAX(2))
    u_harness (.aclk(aclk), .aresetn(aresetn));

  always #5 aclk = ~aclk;

  vrf_axil_cfg   cfg;
  vrf_axil_env_t env;
  int unsigned   seed;
  int            n_rand;
  string         log_dir;
  int            fault_inject;
  bit            ok;

  // ------------------------------ 定向用例构造辅助 ------------------------------
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

  // ------------------------------ 定向用例注册（按名自动挂载） ------------------------------
  task register_directed_cases();
    int i;
    vrf_axil_txn_t t;

    // 1) 复位默认值回读
    foreach (env.model.regs[i]) begin
      t = mk_rd("dir_reset_default", env.model.regs[i].offset);
      vrf_axil_direct_lib_t::reg_case("ref_reset_defaults", t);
    end

    // 2) 全部 R/W 寄存器写入后回读
    t = mk_wr("dir_rw", 32'h00, 32'h0000_0000, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_rd("dir_rw", 32'h00);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_wr("dir_rw", 32'h08, 32'hDEAD_BEEF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_rd("dir_rw", 32'h08);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_wr("dir_rw", 32'h10, 32'h00FF_00FF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_rd("dir_rw", 32'h10);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_wr("dir_rw", 32'h80, 32'hA5A5_5A5A, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);
    t = mk_rd("dir_rw", 32'h80);
    vrf_axil_direct_lib_t::reg_case("ref_rw_readback", t);

    // 3) wstrb 字节使能
    for (i = 0; i < 4; i++) begin
      t = mk_wr("dir_wstrb", 32'h08, 32'hFFFF_FFFF, 4'b0001 << i);
      vrf_axil_direct_lib_t::reg_case("ref_wstrb", t);
    end
    t = mk_rd("dir_wstrb", 32'h08);
    vrf_axil_direct_lib_t::reg_case("ref_wstrb", t);

    // 4) 自清零位：写 bit[1] 后回读应为 0
    t = mk_wr("dir_selfclear", 32'h00, 32'h0000_0002, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_selfclear", t);
    t = mk_rd("dir_selfclear", 32'h00);
    vrf_axil_direct_lib_t::reg_case("ref_selfclear", t);

    // 5) 只读寄存器写保护
    t = mk_wr("dir_ro_wr", 32'h04, 32'hFFFF_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_rd("dir_ro_rd", 32'h04);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_wr("dir_ro_wr", 32'h18, 32'h0000_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_rd("dir_ro_rd", 32'h18);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);

    // 6) 未映射地址：读返回 0，写被忽略
    t = mk_rd("dir_unmapped_rd", 32'h0000_0100);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);
    t = mk_wr("dir_unmapped_wr", 32'h0000_0100, 32'hFFFF_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);
    t = mk_rd("dir_unmapped_rd", 32'h0000_01C0);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);

    // 7) B / R 通道反压
    t = mk_wr("dir_bp_wr", 32'h80, 32'h0F0F_0F0F, 4'hF);
    t.force_bready_delay = 6;
    vrf_axil_direct_lib_t::reg_case("ref_backpressure", t);
    t = mk_rd("dir_bp_rd", 32'h80);
    t.force_rready_delay = 6;
    vrf_axil_direct_lib_t::reg_case("ref_backpressure", t);

    // 8) AW / W 分离握手
    t = mk_wr("dir_aw_w_split", 32'h80, 32'h1234_ABCD, 4'hF);
    t.aw_delay = 0;
    t.w_delay  = 6;
    vrf_axil_direct_lib_t::reg_case("ref_aw_w_split", t);
    t = mk_rd("dir_aw_w_split_rd", 32'h80);
    vrf_axil_direct_lib_t::reg_case("ref_aw_w_split", t);

    // 9) 读写并发
    t = mk_wr("dir_conc_wr", 32'h10, 32'h5555_AAAA, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_concurrent", t);
    t = mk_rd("dir_conc_rd", 32'h08);
    vrf_axil_direct_lib_t::reg_case("ref_concurrent", t);
  endtask

  // ------------------------------ 主流程 ------------------------------
  initial begin
    seed = 0;
    if (!$value$plusargs("seed=%d", seed)) seed = $urandom;
    else void'($urandom(seed));

    log_dir = ".";
    void'($value$plusargs("log_dir=%s", log_dir));

    n_rand = 250;
    void'($value$plusargs("n_rand=%d", n_rand));

    $display("================================================================");
    $display(" VRF_AXI4L 库自测用例 : tb_vrf_axil_demo");
    $display(" 随机种子 : %0d  (可用 +seed=%0d 复现)", seed, seed);
    $display("================================================================");

    // 复位
    aresetn = 1'b0;
    repeat (5) @(posedge aclk);
    aresetn = 1'b1;
    repeat (3) @(posedge aclk);

    // 配置
    cfg = new("vrf_axil_demo");
    cfg.seed               = seed;
    cfg.reg_map            = "REF_SLAVE";
    cfg.addr_min           = 32'h00;
    cfg.addr_max           = 32'h80;
    cfg.bringup_probe_addr = 32'h80;
    cfg.n_rand_txn         = n_rand;
    cfg.log_dir            = log_dir;
    cfg.enable_directed    = 1;
    cfg.directed_case      = "ALL";
    cfg.enable_repro       = 1;
    cfg.repro_max_attempts = 2;
    cfg.verbose            = 1;

    // 环境
    env = new(cfg);
    register_directed_cases();

    // 故障注入自测：故意让寄存器模型与 DUT 不一致，
    // 用于验证「失败检测 → 失败用例回注复现 → 宽监视 → 错误报告 → 种子落盘」链路
    fault_inject = 0;
    void'($value$plusargs("fault_inject=%d", fault_inject));

    if (fault_inject) begin
      $display("--- 故障注入模式：验证失败复现与错误报告链路 ---");
      env.connect();
      env.start();
      env.model.set_mirror(32'h80, 32'hDEAD_BEEF);   // 人为破坏模型镜像
      env.submit(mk_rd("fault_inject_rd", 32'h80));
      env.wait_idle();
      env.stop();
      env.report();
    end else begin
      // 一键连接 + 启动 + 运行 + 报告
      env.run_all();
    end

    ok = env.is_pass();
    $display("================================================================");
    $display(" 库自测结论 : %s", ok ? "PASSED" : "FAILED");
    $display(" 总检查项   : 事务比对 %0d + 协议断言 %0d + 连通性自检 %0d = %0d",
             env.sb.n_checked, vrf_axil_ctrl::assert_chk_cnt,
             env.bringup.n_checked, env.total_checks());
    $display("================================================================");
    if (!ok) $display("SIMULATION FAILED");
    else     $display("SIMULATION PASSED");
    $finish;
  end
endmodule
