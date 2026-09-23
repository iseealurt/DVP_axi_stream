// =============================================================================
// 环境类（env）
//   存放与封装其他组件，提供 new() / connect() / start() / run() 一键启用测试环境；
//   支持向 sequencer 一键导入定向测试队列；
//   内部以完成计数实现 objection 式结束判据，并由时间/事务上限兜底。
//
// 使用方式：
//   env = new(cfg);
//   env.connect();                 // 等待通配符自动连接句柄并组装组件
//   env.start();                   // 上电连通性自检 + 启动全部组件进程
//   env.submit(txn);               // 提交单笔定向事务
//   env.import_directed_queue(q);  // 一键导入定向测试队列
//   env.run_random(200);           // 批量随机
//   env.wait_idle();               // 等待全部事务完成
//   env.stop();  env.report();     // 停止组件并输出报告
// =============================================================================
class vrf_axil_env #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  vrf_axil_cfg           cfg;
  vrf_axil_regmodel #(DWIDTH) model;
  vrf_axil_sequencer_t   seqr;
  vrf_axil_sequence_t    seq;
  vrf_axil_driver_t      drv;
  vrf_axil_monitor_t     mon;
  vrf_axil_scoreboard_t  sb;
  vrf_axil_cov_t         cov;
  vrf_axil_bringup_t     bringup;

  virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst_vif;
  virtual vrf_axil_slv_if #(AWIDTH, DWIDTH, IDWIDTH) slv_vif;
  virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt_vif;

  mailbox #(txn_t) req_mbx;     // sequencer -> driver
  mailbox #(txn_t) done_mbx;    // driver -> scoreboard
  mailbox #(txn_t) obs_mbx;     // monitor -> scoreboard

  bit     connected      = 0;
  bit     started        = 0;
  bit     bringup_ok     = 1'b1;
  string  bringup_hdr    = "";
  int     n_rand_submit  = 0;

  // 外部检查项计数：供用例把「AXI4-Lite 总线之外」的检查（如数据通路帧级比对）
  // 汇入统一报告与结论口径；不改变既有用例的统计（默认 0）
  int     ext_check_num  = 0;
  int     ext_fail_num   = 0;

  process p_drv, p_mon, p_seqr, p_sb;

  function new(vrf_axil_cfg cfg);
    this.cfg = cfg;
    vrf_axil_ctrl::reset();
    vrf_axil_done_ctrl::reset();
    model = new();
    model.build_map(cfg.reg_map);   // 映射名由 cfg 选择，具体实现在寄存器模型文件内
    cov = new(cfg);
  endfunction

  // ------------------------------ 建立连接与组件 ------------------------------
  task connect();
    int guard = 0;
    // 等待通配符自动连接桥发布接口句柄
    while (!vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::published && guard < 100000) begin
      #1ns;
      guard++;
    end
    mst_vif = vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::mst;
    mnt_vif = vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::mnt;
    slv_vif = vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::slv;

    if (vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::conflict) begin
      $display("[VRF_AXIL][ERROR] 检测到同特化的多个挂具实例，接口句柄已被覆盖，自动连接结果不可信");
      $finish;
    end
    if (mst_vif == null || mnt_vif == null) begin
      $display("[VRF_AXIL][ERROR] 未获取到接口句柄，通配符自动连接失败");
      $finish;
    end

    vrf_axil_ctrl::timeout_cycles = cfg.timeout_cycles;

    req_mbx  = new();
    done_mbx = new();
    obs_mbx  = new();

    seqr = new();
    seqr.repro_enable = cfg.enable_repro;
    seqr.clk_vif      = mst_vif;      // 仲裁空转按接口时钟节拍，时钟取自连接表
    seq  = new(cfg, seqr.from_seq);
    drv  = new(cfg, mst_vif, slv_vif, seqr.to_drv, done_mbx);
    mon  = new(cfg, mnt_vif, model, obs_mbx);
    sb   = new(cfg, model, cov, done_mbx, obs_mbx);
    sb.repro_seqr = seqr;
    sb.mon_h      = mon;
    bringup = new(cfg, mst_vif, mnt_vif, model);

    connected = 1;
    $display("[%0t][VRF_AXIL] 环境连接完成：DUT=%s，寄存器数=%0d", $time, cfg.reg_map, model.regs.size());
  endtask

  // ------------------------------ 启动 ------------------------------
  task start();
    if (!connected) connect();

    // ---- 上电连通性自检（在自动化验证开始前） ----
    if (cfg.enable_bringup_check) begin
      vrf_axil_ctrl::bringup_active = 1'b1;
      vrf_axil_ctrl::mon_enable     = 1'b0;
      bringup.run();
      bringup_hdr = bringup.report_header();
      bringup_ok  = bringup.is_pass();
      $display("%s", bringup_hdr);
      if (!bringup_ok) begin
        $display("[VRF_AXIL][WARN] 连通性自检发现问题，详见报告头");
      end
    end

    vrf_axil_ctrl::bringup_active = 1'b0;
    vrf_axil_ctrl::mon_enable     = 1'b1;

    mon.open_log();
    sb.open_report();

    fork
      begin p_drv  = process::self(); drv.run();  end
      begin p_mon  = process::self(); mon.run();  end
      begin p_seqr = process::self(); seqr.run(); end
      begin p_sb   = process::self(); sb.run();   end
    join_none

    started = 1;
    $display("[%0t][VRF_AXIL] 测试环境已启动：%s", $time, cfg.test_name);
  endtask

  // ------------------------------ 激励提交 ------------------------------
  // 一键导入定向测试队列（mailbox.put 为任务，故本接口为任务）
  task import_directed_queue(txn_t q[$]);
    seqr.import_directed_queue(q);
    vrf_axil_done_ctrl::raise(q.size());
  endtask

  // 提交单笔定向事务
  task submit(txn_t t);
    seqr.from_env.put(t);
    vrf_axil_done_ctrl::raise();
  endtask

  // 批量提交随机事务
  task run_random(int n);
    txn_t t;
    repeat (n) begin
      t = new("rand");
      t.addr_min  = cfg.addr_min;
      t.addr_max  = cfg.addr_max;
      t.strb_mode = cfg.strb_mode;
      if (!t.randomize()) begin
        $display("[%0t][VRF_AXIL][ERROR] 随机化失败", $time);
        vrf_axil_ctrl::assert_fail_cnt++;
      end else begin
        seqr.from_seq.put(t);
        vrf_axil_done_ctrl::raise();
        n_rand_submit++;
      end
    end
  endtask

  // ------------------------------ 完成等待 ------------------------------
  task wait_idle();
    int guard = 0;
    while ((vrf_axil_done_ctrl::pending != 0) && (guard < cfg.max_txn)) begin
      @(mst_vif.cb);
      guard++;
      if (guard >= cfg.max_txn) begin
        $display("[VRF_AXIL][WARN] 等待事务完成超限，强制结束等待");
        break;
      end
    end
    repeat (4) @(mst_vif.cb);
  endtask

  // ------------------------------ 停止 ------------------------------
  task stop();
    if (p_drv  != null) p_drv.kill();
    if (p_mon  != null) p_mon.kill();
    if (p_seqr != null) p_seqr.kill();
    if (p_sb   != null) p_sb.kill();
    mon.close_log();
    sb.close_report();
    started = 0;
  endtask

  // ------------------------------ 一键运行 ------------------------------
  task run();
    fork
      seq.body();
    join_none
    while (vrf_axil_done_ctrl::seq_done != 1'b1) @(mst_vif.cb);
    wait_idle();
    stop();
    report();
  endtask

  task run_all();
    connect();
    start();
    run();
  endtask

  // ------------------------------ 报告 ------------------------------
  task report();
    int    fd;
    string line;

    fd = $fopen($sformatf("%s/%s_report.txt", cfg.log_dir, cfg.test_name), "w");
    if (fd == 0) fd = 1;   // 退化为仅终端输出

    $fdisplay(fd, "# VRF_AXIL 验证报告");
    $fdisplay(fd, "测试用例     : %s", cfg.test_name);
    $fdisplay(fd, "被测对象     : %s", cfg.reg_map);
    $fdisplay(fd, "随机种子     : %0d", cfg.seed);
    $fdisplay(fd, "结束时间     : %0t ns", $time);
    $fdisplay(fd, "");
    $fdisplay(fd, "%s", bringup_hdr);
    $fdisplay(fd, "");
    $fdisplay(fd, "================= 事务比对统计 =================");
    $fdisplay(fd, "发起事务数   : %0d", sb.n_issued);
    $fdisplay(fd, "监视观测数   : %0d", mon.n_observed);
    $fdisplay(fd, "参与比对检查 : %0d", sb.n_checked + ext_check_num);
    $fdisplay(fd, "通过         : %0d", sb.n_pass);
    $fdisplay(fd, "失败         : %0d", sb.n_fail + ext_fail_num);
    $fdisplay(fd, "跳过         : %0d", sb.n_skip);
    $fdisplay(fd, "复现重注     : %0d", sb.n_repro);
    $fdisplay(fd, "断言检查次数 : %0d", vrf_axil_ctrl::assert_chk_cnt);
    $fdisplay(fd, "断言失败次数 : %0d", vrf_axil_ctrl::assert_fail_cnt);
    $fdisplay(fd, "");
    $fdisplay(fd, "================= 功能覆盖率 =================");
    $fdisplay(fd, "%s", cov.report_string());
    $fdisplay(fd, "%s", cov.report_note());
    $fdisplay(fd, "整体覆盖率   : %0.2f%%", $get_coverage());
    $fdisplay(fd, "");
    if (sb.fail_q.size() > 0) begin
      $fdisplay(fd, "================= 失败事务清单 =================");
      foreach (sb.fail_q[i]) begin
        $fdisplay(fd, "  #%0d %s", i, sb.fail_q[i].convert2string());
      end
      $fdisplay(fd, "");
    end

    line = (sb.n_fail == 0 && vrf_axil_ctrl::assert_fail_cnt == 0 && bringup_ok
            && ext_fail_num == 0)
           ? "SIMULATION PASSED" : "SIMULATION FAILED";
    $fdisplay(fd, "================= 结论 =================");
    $fdisplay(fd, "%s: 检查 %0d 项, 失败 %0d 项, 断言失败 %0d 项",
              line, sb.n_checked + ext_check_num, sb.n_fail + ext_fail_num,
              vrf_axil_ctrl::assert_fail_cnt);
    if (fd != 1) $fclose(fd);

    $display("");
    $display("================= VRF_AXIL 验证结论 =================");
    $display("测试用例     : %s", cfg.test_name);
    $display("随机种子     : %0d", cfg.seed);
    $display("发起事务数   : %0d", sb.n_issued);
    $display("参与比对检查 : %0d    通过: %0d    失败: %0d    跳过: %0d",
             sb.n_checked + ext_check_num, sb.n_pass, sb.n_fail + ext_fail_num, sb.n_skip);
    $display("断言检查次数 : %0d    失败: %0d",
             vrf_axil_ctrl::assert_chk_cnt, vrf_axil_ctrl::assert_fail_cnt);
    $display("%s", cov.report_string());
    $display("整体覆盖率   : %0.2f%%", $get_coverage());
    $display("%s: 检查 %0d 项, 失败 %0d 项, 断言失败 %0d 项",
             line, sb.n_checked + ext_check_num, sb.n_fail + ext_fail_num,
             vrf_axil_ctrl::assert_fail_cnt);
    $display("====================================================");
  endtask

  function bit is_pass();
    return (sb.n_fail == 0) && (vrf_axil_ctrl::assert_fail_cnt == 0) && bringup_ok
           && (ext_fail_num == 0);
  endfunction

  function int total_checks();
    return sb.n_checked + vrf_axil_ctrl::assert_chk_cnt + bringup.n_checked + ext_check_num;
  endfunction
endclass

typedef vrf_axil_env #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_env_t;
