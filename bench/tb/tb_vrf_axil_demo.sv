`timescale 1ns/1ps
// =============================================================================
// 库自测用例（demo）—— 逐行注释的学习版
//
//   被测对端：AXI4-Lite 从机参考模型（vrf_axil_slv_ref，不依赖任何 RTL 完成度）
//   学习目标：一个完整的 SV 验证平台是如何搭起来的——
//     1) 挂具模块 + 端口通配符自动连接（VRF_AXIL_HOOK_DECL + `.*`）
//     2) 事务对象的构造（类 + 句柄）与「定向用例按名注册、自动挂载」
//     3) 随机种子的取用与复现（+seed plusarg）
//     4) 配置对象 cfg 的逐项含义
//     5) env.run_all() 一键流程（连接 → 自检 → 启动 → 跑用例 → 收尾 → 报告）
//     6) 故障注入：人为制造失败，验证「失败检测 → 回注复现 → 宽监视 → 错误报告」链路
//
//   阅读顺序建议：先看第 1 段「挂具」，再看顶部 initial 主流程（第 4 段），
//   最后回头看第 3 段「定向用例注册」——它只是往库里塞事务，主流程才是驱动全场的骨架。
//
//   本文件只加注释、不改代码；编译与运行结果与注释前完全一致。
// =============================================================================

// -----------------------------------------------------------------------------
// 第 1 段：挂具（harness）
//   为什么要「挂具」？因为 SystemVerilog 的 bind 只能观测目标模块内部信号，
//   无法驱动目标模块的输入端口；本库改用「把 DUT 实例化进一个挂具模块」的方案：
//   挂具里声明与 DUT 端口同名的信号，再用 `.*` 让 DUT 按名自动连上来，
//   接口句柄则通过这些同名信号与 DUT 双向连通。
// -----------------------------------------------------------------------------
module vrf_axil_harness_ref #(
  parameter int AW      = 32,   // 地址位宽（AWADDR/ARADDR 宽度）
  parameter int DW      = 32,   // 数据位宽（WDATA/RDATA 宽度）
  parameter int ID      = 4,    // 事务 ID 位宽（BID/RID 宽度）
  parameter int RDY_MIN = 0,    // 从机 ready 最小延迟周期数（制造随机反压）
  parameter int RDY_MAX = 2     // 从机 ready 最大延迟周期数
)(
  input logic aclk,             // 总线时钟，由顶层 TB 产生后接进来
  input logic aresetn           // 低有效异步复位，同样由顶层 TB 驱动
);
  import vrf_axil_pkg::*;       // 引入验证库的类型/类定义（三视角接口、句柄表等）

  // 通配符自动连接挂钩宏。它一次性完成四件事：
  //   a) 声明与 DUT 端口同名的 AXI4-Lite 信号（awvalid/awaddr/.../rid）；
  //   b) 实例化「主机视角 mst_vif」与「监视视角 mnt_vif」两个接口；
  //   c) 用 assign 把接口变量与这些同名信号双向连起来（主机驱动 → DUT 输入，
  //      DUT 输出 → 主机采样 / 监视采样）；
  //   d) 把接口句柄发布到全局连接表 vrf_axil_conn_h，供 driver/monitor 取用，
  //      并检测「重复挂具」冲突（同一特化出现两个挂具时报错而不是静默覆盖）。
  // 之所以用宏：新增 DUT 时只需在挂具里写这一行，不必手抄 20 多根端口映射。
  `VRF_AXIL_HOOK_DECL(AW, DW, ID)

  // 被验证的「DUT」：这里是从机参考模型（纯 SV 行为模型，没有 RTL）。
  // `(.*)` 表示端口按名字自动连接——挂具里刚好有同名信号，所以不用逐个写 .awvalid(awvalid)。
  // 参数显式传递：数据/地址宽度与顶层保持一致，ready 延迟范围决定反压的随机性。
  vrf_axil_slv_ref #(
    .AWIDTH(AW), .DWIDTH(DW), .IDWIDTH(ID),
    .RDY_DLY_MIN(RDY_MIN), .RDY_DLY_MAX(RDY_MAX)
  ) u_dut (.*);
endmodule

// -----------------------------------------------------------------------------
// 第 2 段：顶层测试模块（TB）
//   TB 不参与综合，只负责：产生时钟/复位、配置环境、注册激励、启动仿真、输出结论。
// -----------------------------------------------------------------------------
module tb_vrf_axil_demo;
  import vrf_axil_pkg::*;       // 让本模块能直接使用库里的类名（vrf_axil_cfg / vrf_axil_env_t ...）

  // 位宽参数：写成 localparam 便于一次性改动，且与挂具实例化处保持一致。
  localparam int AW = 32;
  localparam int DW = 32;
  localparam int ID = 4;

  // 时钟与复位：用 4 态 logic 而非 bit，便于观察 X 传播（复位未驱动时接口会处于 X）。
  // 初值在这里给出（aclk=0、aresetn=0 即「上电即处于复位」），
  // 这样接口内不需要写 initial，避免出现多进程驱动同一变量。
  logic aclk    = 1'b0;
  logic aresetn = 1'b0;

  // 实例化第 1 段的挂具，并把时钟/复位接进去。
  // RDY_MIN=0 / RDY_MAX=2 表示从机 ready 会随机延迟 0~2 拍，用来制造反压场景。
  vrf_axil_harness_ref #(.AW(AW), .DW(DW), .ID(ID), .RDY_MIN(0), .RDY_MAX(2))
    u_harness (.aclk(aclk), .aresetn(aresetn));

  // 时钟产生：每 5ns 翻转一次 → 周期 10ns、频率 100MHz。
  // 用 always 而不是 forever 循环，是因为它天然在 0 时刻之后持续运行，写法最简洁。
  always #5 aclk = ~aclk;

  // ------------------------------ 测试平台用到的变量 ------------------------------
  vrf_axil_cfg   cfg;           // 配置对象句柄（class 句柄，默认初值是 null）
  vrf_axil_env_t env;           // 环境对象句柄（汇聚 driver/monitor/scoreboard/覆盖率/自检）
  int unsigned   seed;          // 随机种子：决定所有 $urandom 的取值序列
  int            n_rand;        // 随机事务条数（可被 +n_rand 覆盖）
  string         log_dir;       // 日志目录（可被 +log_dir 覆盖，用于落盘 repro_seed.txt）
  int            fault_inject;  // 故障注入开关（+fault_inject=1 打开）
  bit            ok;            // 2 态结论标志：整体是否通过

  // ------------------------------ 第 3 段：事务构造与定向用例注册 ------------------------------
  // 辅助函数：构造一笔「读事务」并返回其句柄。
  //   注意 function 里 new 出来的对象是动态分配的，返回的是句柄（引用），
  //   调用方拿到后可以继续修改字段（例如后面设置 force_rready_delay）。
  function vrf_axil_txn_t mk_rd(string name, logic [31:0] addr);
    vrf_axil_txn_t t;           // 事务对象句柄
    t = new(name);              // 分配对象并带上名字（名字会出现在日志/失败报告里）
    t.txn_dir  = AXIL_RD;       // 方向：读
    t.txn_addr = addr;          // 读地址
    t.txn_strb = '1;            // 读不带字节选通，但字段填全（'1 表示全 1）便于日志与覆盖采样
    return t;                   // 返回句柄
  endfunction

  // 辅助函数：构造一笔「写事务」并返回其句柄（含写数据与字节选通）。
  function vrf_axil_txn_t mk_wr(string name, logic [31:0] addr,
                                logic [31:0] data, logic [3:0] strb);
    vrf_axil_txn_t t;
    t = new(name);
    t.txn_dir  = AXIL_WR;       // 方向：写
    t.txn_addr = addr;
    t.txn_data = data;          // 写数据
    t.txn_strb = strb;          // 字节选通：4'hF=四字节全写，4'b0001=只写最低字节……
    return t;
  endfunction

  // 定向用例注册：把「按顺序该做的事情」逐条登记到定向用例库中。
  //   机制：vrf_axil_direct_lib_t::reg_case("用例名", 事务) 是「类静态方法」（::调用），
  //   内部把事务挂到全局表里；环境启动时会根据 cfg.directed_case（本 TB 填 "ALL"）
  //   把这些事务按注册顺序取出来依次下发。这样用例与执行引擎解耦：
  //   TB 只描述「要做什么」，何时发、怎么配对、怎么比对都交给库。
  task register_directed_cases();
    int i;                      // 循环变量（SV 允许在 for 里声明，这里放在任务顶部便于阅读）
    vrf_axil_txn_t t;           // 复用的事务句柄

    // 1) 复位默认值回读：遍历寄存器模型里的每个寄存器，各发一笔读。
    //    env.model.regs 是「按地址索引的寄存器数组」，foreach (regs[i]) 的 i 是索引。
    //    每笔读都会与模型镜像值比对，等于把「复位后所有寄存器默认值」一次性查一遍。
    foreach (env.model.regs[i]) begin
      t = mk_rd("dir_reset_default", env.model.regs[i].offset);   // 用寄存器偏移作为读地址
      vrf_axil_direct_lib_t::reg_case("ref_reset_defaults", t);
    end

    // 2) R/W 寄存器写后回读：每对「写 + 读」用同一个用例名注册，保证它们成对出现。
    //    写值特意选了 0x0000_0000 / 0xDEAD_BEEF 等「边界感」明显的图案，便于日志辨认。
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

    // 3) wstrb 字节使能：对同一个寄存器连写 4 次，每次只选通 1 个字节
    //    （4'b0001 << i 依次得到 0001/0010/0100/1000），最后整体回读。
    //    预期：只有被选通的字节被改写，其余字节保持不变——这是寄存器模型的字节合并语义。
    for (i = 0; i < 4; i++) begin
      t = mk_wr("dir_wstrb", 32'h08, 32'hFFFF_FFFF, 4'b0001 << i);
      vrf_axil_direct_lib_t::reg_case("ref_wstrb", t);
    end
    t = mk_rd("dir_wstrb", 32'h08);
    vrf_axil_direct_lib_t::reg_case("ref_wstrb", t);

    // 4) 自清零位：写 bit[1]=1，随后回读应为 0（该位写 1 触发动作后自动清 0）。
    t = mk_wr("dir_selfclear", 32'h00, 32'h0000_0002, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_selfclear", t);
    t = mk_rd("dir_selfclear", 32'h00);
    vrf_axil_direct_lib_t::reg_case("ref_selfclear", t);

    // 5) 只读寄存器写保护：对 RO 寄存器写全 F，再回读——写必须被忽略（值不变）。
    t = mk_wr("dir_ro_wr", 32'h04, 32'hFFFF_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_rd("dir_ro_rd", 32'h04);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_wr("dir_ro_wr", 32'h18, 32'h0000_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);
    t = mk_rd("dir_ro_rd", 32'h18);
    vrf_axil_direct_lib_t::reg_case("ref_ro_protect", t);

    // 6) 未映射 / 保留地址：读应返回 0、写应被忽略（地址 0x100、0x1C0 都不在寄存器映射内）。
    t = mk_rd("dir_unmapped_rd", 32'h0000_0100);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);
    t = mk_wr("dir_unmapped_wr", 32'h0000_0100, 32'hFFFF_FFFF, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);
    t = mk_rd("dir_unmapped_rd", 32'h0000_01C0);
    vrf_axil_direct_lib_t::reg_case("ref_unmapped", t);

    // 7) B / R 通道反压：给事务加「响应通道延迟」，让从机延后拉 bready/rready 的等待。
    //    force_bready_delay 表示主机在收到 bvalid 后延迟 N 拍再拉高 bready（制造反压），
    //    用来验证「valid 拉高后载荷必须保持稳定、握手不能被误判」等协议属性。
    t = mk_wr("dir_bp_wr", 32'h80, 32'h0F0F_0F0F, 4'hF);
    t.force_bready_delay = 6;
    vrf_axil_direct_lib_t::reg_case("ref_backpressure", t);
    t = mk_rd("dir_bp_rd", 32'h80);
    t.force_rready_delay = 6;
    vrf_axil_direct_lib_t::reg_case("ref_backpressure", t);

    // 8) AW / W 分离握手：AW 与 W 是两条独立通道，握手可以不同拍。
    //    aw_delay=0、w_delay=6 表示地址先到、数据晚 6 拍才到；
    //    从端在 AW/W 都有效后才接受，这个场景专门检查「分离到达不会丢事务、不误判」。
    t = mk_wr("dir_aw_w_split", 32'h80, 32'h1234_ABCD, 4'hF);
    t.aw_delay = 0;
    t.w_delay  = 6;
    vrf_axil_direct_lib_t::reg_case("ref_aw_w_split", t);
    t = mk_rd("dir_aw_w_split_rd", 32'h80);
    vrf_axil_direct_lib_t::reg_case("ref_aw_w_split", t);

    // 9) 读写并发：把一笔写和一笔读注册在同一用例下，测试平台会同时下发两条流，
    //    验证读写通道互不阻塞，以及「同址并发读写」的比对结果仍然确定。
    t = mk_wr("dir_conc_wr", 32'h10, 32'h5555_AAAA, 4'hF);
    vrf_axil_direct_lib_t::reg_case("ref_concurrent", t);
    t = mk_rd("dir_conc_rd", 32'h08);
    vrf_axil_direct_lib_t::reg_case("ref_concurrent", t);
  endtask

  // ------------------------------ 第 4 段：主流程 ------------------------------
  initial begin
    // ---- 4.1 取随机种子 ----
    // 先给默认值 0，再尝试从命令行 plusarg 读取 +seed=<n>；读不到就用 $urandom 取一个随机种子。
    // 这样既能「指定种子复现」，也能「每次跑不同的随机序列」。
    seed = 0;
    if (!$value$plusargs("seed=%d", seed)) seed = $urandom;
    else void'($urandom(seed));
    // 上一行：若用户显式给了种子，就用它初始化随机数发生器（$urandom(seed) 设定种子）；
    // void'(...) 表示「函数有返回值但这里故意丢弃」，避免编译告警。

    // ---- 4.2 日志目录：默认当前目录，可被 +log_dir 覆盖 ----
    // 失败复现时 TB 会把复现种子写到 <log_dir>/repro_seed.txt，
    // 回归脚本会给每个种子分配独立目录，因此这里必须可配置。
    log_dir = ".";
    void'($value$plusargs("log_dir=%s", log_dir));

    // ---- 4.3 随机事务条数：默认 250，可被 +n_rand 覆盖 ----
    // 注意：显式传 +n_rand=0 是有效取值（表示只跑定向用例、不发随机事务）。
    n_rand = 250;
    void'($value$plusargs("n_rand=%d", n_rand));

    // ---- 4.4 打印运行头（种子一定要打印，否则失败后无法复现） ----
    $display("================================================================");
    $display(" VRF_AXI4L 库自测用例 : tb_vrf_axil_demo");
    $display(" 随机种子 : %0d  (可用 +seed=%0d 复现)", seed, seed);
    $display("================================================================");

    // ---- 4.5 复位时序 ----
    // 先拉低复位保持 5 拍（让 DUT/参考模型进入确定的复位态），再释放，
    // 之后额外等 3 拍，保证复位释放后的第一个时钟沿之前所有信号都已稳定，
    // 避免环境启动时采样到 X（自检的 X/Z 检查会因此误报）。
    aresetn = 1'b0;
    repeat (5) @(posedge aclk);   // 等待 5 个时钟上升沿（repeat 与 @ 组合是通用的定时写法）
    aresetn = 1'b1;
    repeat (3) @(posedge aclk);

    // ---- 4.6 配置对象：环境的所有可调项都在这里 ----
    // new("tb_vrf_axil_demo") 的参数是「用例名」，必须与脚本里的 -Test 同名，
    // 因为回归脚本靠 <Test>_report.txt 找报告、靠 <Test>.exit 读退出码。
    cfg = new("tb_vrf_axil_demo");
    cfg.seed               = seed;            // 把种子传给环境（内部初始化各组件 RNG）
    cfg.reg_map            = "REF_SLAVE";     // 选择寄存器映射：与从机参考模型匹配的那一套
    cfg.addr_min           = 32'h00;          // 随机地址下界（含）
    cfg.addr_max           = 32'h80;          // 随机地址上界（含）
    cfg.bringup_probe_addr = 32'h80;          // 上电连通性自检时用来探针的地址
    cfg.n_rand_txn         = n_rand;          // 随机事务条数
    cfg.log_dir            = log_dir;         // 日志/报告/复现种子落盘目录
    cfg.enable_directed    = 1;               // 打开定向用例
    cfg.directed_case      = "ALL";           // 挂载全部已注册的定向用例
    cfg.enable_repro       = 1;               // 打开失败复现（失败事务回注 + 宽监视）
    cfg.repro_max_attempts = 2;               // 每笔失败最多回注复现 2 次
    cfg.verbose            = 1;               // 打开详细日志（逐笔事务写 <log_dir>/<test>_log.txt）

    // ---- 4.7 构造环境 + 注册激励 ----
    // new(cfg) 只「构造对象」，此时还不连接接口、不启动进程；
    // register_directed_cases() 必须在此之前/之后、但一定在启动前完成注册，
    // 因为环境启动时会一次性把定向队列取空。
    env = new(cfg);
    register_directed_cases();

    // ---- 4.8 故障注入开关 ----
    // 仅用于「自测失败链路」：故意让寄存器模型与真实响应不一致，检查平台能否
    // 检测失败 → 回注复现 → 打印宽监视波形 → 生成格式化错误报告 → 落盘种子。
    fault_inject = 0;
    void'($value$plusargs("fault_inject=%d", fault_inject));

    if (fault_inject) begin
      $display("--- 故障注入模式：验证失败复现与错误报告链路 ---");
      // 故障模式下不能用 run_all()（它会一口气跑完并收尾），所以要手工分步：
      env.connect();                        // 连接接口句柄 + 配置 RAL 模型（不含自检）
      env.start();                          // 启动 driver/monitor/scoreboard 等进程
      env.model.set_mirror(32'h80, 32'hDEAD_BEEF);   // 人为破坏模型镜像：让预期值与真实值不同
      env.submit(mk_rd("fault_inject_rd", 32'h80));  // 下发一笔读：必然比对失败
      env.wait_idle();                      // 等行业务处理完（含失败复现流程）
      env.stop();                           // 停止所有进程
      env.report();                         // 生成报告（含失败明细、宽监视内容）
    end else begin
      // ---- 正常模式：一键流程 ----
      // run_all() 等价于 connect + 上电连通性自检 + start + 跑完定向与随机 + wait_idle + stop + report，
      // 是「库自测」最省事的入口；需要精细控制时（如上面的故障注入）再手工分步。
      env.run_all();
    end

    // ---- 4.9 结论与退出 ----
    // is_pass() 汇总三部分证据：事务比对无失败 + 协议断言无失败 + 自检无连接错误。
    ok = env.is_pass();
    $display("================================================================");
    $display(" 库自测结论 : %s", ok ? "PASSED" : "FAILED");
    // 总检查项 = 事务比对 + 协议断言 + 连通性自检；这里把三者的来源分别打印出来，
    // 便于和报告文件里的统计字段对照（regression.ps1 就是解析这些字段的）。
    $display(" 总检查项   : 事务比对 %0d + 协议断言 %0d + 连通性自检 %0d = %0d",
             env.sb.n_checked, vrf_axil_ctrl::assert_chk_cnt,
             env.bringup.n_checked, env.total_checks());
    $display("================================================================");
    // 结论字符串是脚本/报告判定通过与否的文本依据（run.ps1 退出码只反映仿真器是否正常退出）。
    if (!ok) $display("SIMULATION FAILED");
    else     $display("SIMULATION PASSED");
    $finish;   // 结束仿真（$finish 让 vsim 正常退出，退出码为 0）
  end
endmodule
