`timescale 1ns/1ps
// =============================================================================
// 「AW/W 窗口期复位」监视器靶向定向用例
//
//   复现并回归缺陷 A1：
//     复位发生在「AW 已握手、W 未握手」窗口时，监视器的 aw_pend/w_pend 与暂存
//     地址/数据会滞留到复位之后，使复位后的新写事务被错误配对到旧 AW 地址。
//
//   为什么用「监视器靶向」而不是现有的全系统用例：
//     本库现有两台被测从端（DVP2axi_stream RTL 与 vrf_axil_slv_ref）都只在
//     awvalid&wvalid 同时有效时拉高 awready/wready（AW/W 联合握手），
//     因此「AW 已握手、W 未握手」这一协议合法窗口在全系统激励下不可达。
//     本用例直接驱动监视视角接口（白盒靶向），精确构造该窗口并检查复位后的配对结果。
//
//   检查项：
//     1) 窗口期的半笔写不得被静默丢弃——应作为「被复位打断」的观测上报（配平完成计数）
//     2) 复位后的新写事务必须按新地址/新数据/新字节选通配对（不得沿用窗口期的旧地址）
//     3) 复位后的读事务按新地址配对，读数据与模型预测一致
// =============================================================================
module tb_vrf_axil_rst_window;
  import vrf_axil_pkg::*;

  localparam int AW = 32;
  localparam int DW = 32;
  localparam int ID = 4;

  // 窗口期（复位前）只完成 AW 握手的写地址，与复位后的新地址刻意不同
  localparam logic [31:0] ADDR_A = 32'h08;
  localparam logic [31:0] DATA_A = 32'h1111_2222;
  localparam logic [3:0]  STRB_A = 4'hF;
  // 复位后的新事务
  localparam logic [31:0] ADDR_B = 32'h10;
  localparam logic [31:0] DATA_B = 32'h3333_4444;
  localparam logic [3:0]  STRB_B = 4'h5;

  logic aclk    = 1'b0;
  logic aresetn = 1'b0;

  always #5 aclk = ~aclk;

  // 监视视角接口：本用例直接驱动其信号（不实例化挂具与 DUT）
  vrf_axil_mnt_if #(AW, DW, ID) mnt_if (.aclk(aclk), .arstn(aresetn));
  // 库内各组件声明了 mst/slv/mnt 三种虚拟接口类型，ModelSim 在加载期要求这三种
  // 接口都有实例存在才能完成虚拟接口类型解析，故此处一并声明（本用例不使用其信号）
  vrf_axil_mst_if #(AW, DW, ID) mst_if (.aclk(aclk), .arstn(aresetn));
  vrf_axil_slv_if #(AW, DW, ID) slv_if (.aclk(aclk), .arstn(aresetn));

  vrf_axil_cfg        cfg;
  vrf_axil_regmodel   model;
  mailbox #(vrf_axil_txn_t) obs_mbx;
  vrf_axil_monitor_t  mon;

  vrf_axil_txn_t obs_q[$];

  string       log_dir;
  int unsigned seed;
  int          n_checked = 0;
  int          n_pass    = 0;
  int          n_fail    = 0;

  // ------------------------------ 采集监视器输出 ------------------------------
  task automatic collector();
    vrf_axil_txn_t o;
    forever begin
      obs_mbx.get(o);
      obs_q.push_back(o);
    end
  endtask

  // ------------------------------ 检查与记账 ------------------------------
  function void check(bit cond, string what);
    n_checked++;
    if (cond) begin
      n_pass++;
      $display("[%0t][CHECK-PASS] %s", $time, what);
    end else begin
      n_fail++;
      $display("[%0t][CHECK-FAIL] %s", $time, what);
    end
  endfunction

  // ------------------------------ 总线激励 ------------------------------
  task automatic bus_idle();
    mnt_if.awvalid = 1'b0; mnt_if.awaddr = '0; mnt_if.awport = '0; mnt_if.awready = 1'b0;
    mnt_if.wvalid  = 1'b0; mnt_if.wdata  = '0; mnt_if.wstrb  = '0; mnt_if.wready  = 1'b0;
    mnt_if.bvalid  = 1'b0; mnt_if.bready = 1'b0; mnt_if.bid = '0;   mnt_if.bresp   = 2'b00;
    mnt_if.arvalid = 1'b0; mnt_if.araddr = '0; mnt_if.arport = '0; mnt_if.arready = 1'b0;
    mnt_if.rvalid  = 1'b0; mnt_if.rready = 1'b0; mnt_if.rdata = '0;
    mnt_if.rresp   = 2'b00; mnt_if.rid = '0;
  endtask

  // 只完成 AW 握手：awvalid/awready 有效一拍，wvalid 始终无效
  task automatic aw_only_hs(input logic [31:0] a);
    @(negedge aclk);
    mnt_if.awvalid = 1'b1; mnt_if.awaddr = a; mnt_if.awport = 3'b000; mnt_if.awready = 1'b1;
    @(posedge aclk);              // 监视器在本拍采样到 AW 握手
    @(negedge aclk);
    mnt_if.awvalid = 1'b0; mnt_if.awready = 1'b0;
  endtask

  // 完整写事务：AW/W 同拍握手，下一拍 B 响应
  task automatic full_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s);
    @(negedge aclk);
    mnt_if.awvalid = 1'b1; mnt_if.awaddr = a; mnt_if.awready = 1'b1;
    mnt_if.wvalid  = 1'b1; mnt_if.wdata  = d; mnt_if.wstrb  = s; mnt_if.wready = 1'b1;
    @(posedge aclk);
    @(negedge aclk);
    mnt_if.awvalid = 1'b0; mnt_if.awready = 1'b0;
    mnt_if.wvalid  = 1'b0; mnt_if.wready  = 1'b0;
    mnt_if.bvalid  = 1'b1; mnt_if.bid = '0; mnt_if.bresp = 2'b00; mnt_if.bready = 1'b1;
    @(posedge aclk);
    @(negedge aclk);
    mnt_if.bvalid = 1'b0; mnt_if.bready = 1'b0;
  endtask

  // 完整读事务：AR 握手后下一拍 R 响应
  task automatic full_read(input logic [31:0] a, input logic [31:0] d);
    @(negedge aclk);
    mnt_if.arvalid = 1'b1; mnt_if.araddr = a; mnt_if.arport = 3'b000; mnt_if.arready = 1'b1;
    @(posedge aclk);
    @(negedge aclk);
    mnt_if.arvalid = 1'b0; mnt_if.arready = 1'b0;
    mnt_if.rvalid  = 1'b1; mnt_if.rdata = d; mnt_if.rresp = 2'b00; mnt_if.rid = '0;
    mnt_if.rready  = 1'b1;
    @(posedge aclk);
    @(negedge aclk);
    mnt_if.rvalid = 1'b0; mnt_if.rready = 1'b0;
  endtask

  // ------------------------------ 主流程 ------------------------------
  initial begin
    seed = 0;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    else void'($urandom(seed));

    log_dir = ".";
    void'($value$plusargs("log_dir=%s", log_dir));

    $display("================================================================");
    $display(" VRF_AXI4L 定向用例 : tb_vrf_axil_rst_window");
    $display(" 场景 : AW 已握手、W 未握手期间拉复位（缺陷 A1 的复现与回归）");
    $display(" 随机种子 : %0d", seed);
    $display("================================================================");

    bus_idle();
    aresetn = 1'b0;
    repeat (5) @(posedge aclk);
    aresetn = 1'b1;
    repeat (2) @(posedge aclk);

    cfg = new("tb_vrf_axil_rst_window");
    cfg.seed            = seed;
    cfg.reg_map         = "REF_SLAVE";
    cfg.log_dir         = log_dir;
    cfg.verbose         = 1'b0;
    cfg.enable_coverage = 1'b0;
    cfg.enable_repro    = 1'b0;
    cfg.timeout_cycles  = 50;

    model   = new();
    model.build_map(cfg.reg_map);
    obs_mbx = new();
    mon     = new(cfg, mnt_if, model, obs_mbx);

    vrf_axil_ctrl::reset();
    vrf_axil_ctrl::timeout_cycles = cfg.timeout_cycles;
    vrf_axil_ctrl::mon_enable     = 1'b1;

    fork
      collector();
      mon.run();
    join_none

    @(posedge aclk);

    // ---- 1) 缺陷窗口：AW 已握手、W 未握手 ----
    aw_only_hs(ADDR_A);
    repeat (2) @(posedge aclk);

    // ---- 2) 窗口期内拉复位 ----
    aresetn = 1'b0;
    repeat (3) @(posedge aclk);
    aresetn = 1'b1;
    repeat (2) @(posedge aclk);
    model.reset();

    // ---- 3) 复位后的新写事务与回读（地址与窗口期地址不同） ----
    full_write(ADDR_B, DATA_B, STRB_B);
    full_read (ADDR_B, DATA_B);
    repeat (10) @(posedge aclk);

    // ---- 4) 检查观测结果 ----
    begin
      vrf_axil_txn_t wr_q[$];
      vrf_axil_txn_t rd_q[$];
      foreach (obs_q[i]) begin
        if (obs_q[i].txn_dir == AXIL_WR) wr_q.push_back(obs_q[i]);
        else                            rd_q.push_back(obs_q[i]);
      end

      check(wr_q.size() == 2,
            $sformatf("写观测数应为 2（窗口期被打断的半笔 + 复位后完整一笔），实际 %0d", wr_q.size()));
      check(rd_q.size() == 1,
            $sformatf("读观测数应为 1，实际 %0d", rd_q.size()));

      if (wr_q.size() >= 1) begin
        check(wr_q[0].obs_addr === ADDR_A,
              $sformatf("第 1 笔写观测地址应为窗口期地址 0x%0h，实际 0x%0h",
                        ADDR_A, wr_q[0].obs_addr));
        check(wr_q[0].obs_wdata !== DATA_B,
              $sformatf("第 1 笔写观测不得携带复位后新事务的写数据 0x%0h（地址与数据来自不同事务即为错配），实际 0x%0h",
                        DATA_B, wr_q[0].obs_wdata));
        check(wr_q[0].obs_interrupted === 1'b1,
              "第 1 笔写观测应标记为「被复位打断」（窗口期半笔写不得静默丢弃）");
      end
      if (wr_q.size() >= 2) begin
        check(wr_q[1].obs_addr === ADDR_B,
              $sformatf("第 2 笔写观测地址应为复位后新地址 0x%0h，实际 0x%0h",
                        ADDR_B, wr_q[1].obs_addr));
        check(wr_q[1].obs_wdata === DATA_B,
              $sformatf("第 2 笔写观测数据应为 0x%0h，实际 0x%0h", DATA_B, wr_q[1].obs_wdata));
        check(wr_q[1].obs_strb === STRB_B,
              $sformatf("第 2 笔写观测字节选通应为 %b，实际 %b", STRB_B, wr_q[1].obs_strb));
        check(wr_q[1].obs_interrupted === 1'b0,
              "第 2 笔写观测不应被标记为复位打断");
      end
      if (rd_q.size() >= 1) begin
        check(rd_q[0].obs_addr === ADDR_B,
              $sformatf("读观测地址应为 0x%0h，实际 0x%0h", ADDR_B, rd_q[0].obs_addr));
        check(rd_q[0].obs_rdata === DATA_B,
              $sformatf("读观测数据应为 0x%0h，实际 0x%0h", DATA_B, rd_q[0].obs_rdata));
        check(rd_q[0].obs_resp === OKAY,
              $sformatf("读观测响应应为 OKAY，实际 %s", rd_q[0].obs_resp.name()));
      end
    end

    // ---- 5) 报告与结论 ----
    begin
      int    fd;
      string verdict;
      verdict = (n_fail == 0) ? "SIMULATION PASSED" : "SIMULATION FAILED";
      fd = $fopen($sformatf("%s/%s_report.txt", log_dir, cfg.test_name), "w");
      if (fd == 0) fd = 1;
      $fdisplay(fd, "# VRF_AXIL 验证报告");
      $fdisplay(fd, "测试用例     : %s", cfg.test_name);
      $fdisplay(fd, "被测对象     : %s（监视器靶向定向用例：直接驱动监视视角接口，不实例化 DUT）", cfg.reg_map);
      $fdisplay(fd, "随机种子     : %0d", cfg.seed);
      $fdisplay(fd, "场景         : AW 已握手、W 未握手期间拉复位；复位后新事务的地址/数据/选通配对检查");
      $fdisplay(fd, "");
      $fdisplay(fd, "================= 事务比对统计 =================");
      $fdisplay(fd, "发起事务数   : %0d", 3);
      $fdisplay(fd, "监视观测数   : %0d", obs_q.size());
      $fdisplay(fd, "参与比对检查 : %0d", n_checked);
      $fdisplay(fd, "通过         : %0d", n_pass);
      $fdisplay(fd, "失败         : %0d", n_fail);
      $fdisplay(fd, "跳过         : %0d", 0);
      $fdisplay(fd, "复现重注     : %0d", 0);
      $fdisplay(fd, "断言检查次数 : %0d", 0);
      $fdisplay(fd, "断言失败次数 : %0d", 0);
      $fdisplay(fd, "");
      $fdisplay(fd, "================= 结论 =================");
      $fdisplay(fd, "%s: 检查 %0d 项, 失败 %0d 项, 断言失败 %0d 项", verdict, n_checked, n_fail, 0);
      if (fd != 1) $fclose(fd);

      $display("================================================================");
      $display(" 监视器复位窗口用例结论 : %s", (n_fail == 0) ? "PASSED" : "FAILED");
      $display(" 检查 %0d 项, 通过 %0d 项, 失败 %0d 项", n_checked, n_pass, n_fail);
      $display(" 监视观测数 : %0d（写 %0d / 读 %0d）", obs_q.size(),
               obs_q.size() - 1, 1);
      $display("================================================================");
      $display("%s: 检查 %0d 项, 失败 %0d 项, 断言失败 %0d 项", verdict, n_checked, n_fail, 0);
      if (n_fail != 0) $display("SIMULATION FAILED");
      else             $display("SIMULATION PASSED");
    end

    $finish;
  end
endmodule
