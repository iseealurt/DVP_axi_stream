// =============================================================================
// 计分板（scoreboard）
//   - 统一收集测试结果与预期结果，逐笔比对并统计
//   - 预期值由 monitor 在握手当拍依据寄存器模型预测后随观测事务送入
//   - 比对维度：地址一致性、写数据/字节选通一致性、读数据一致性、响应合法性、ID
//   - 生成功能覆盖率报告（采样交给覆盖率收集器）
//   - 依据配置启用失败用例自动化复现：失败事务回传 sequencer 单笔重注，
//     并通知 monitor 进入宽监视模式，输出格式化错误报告
// =============================================================================
class vrf_axil_scoreboard #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  localparam int STRBWIDTH = DWIDTH / 8;
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  vrf_axil_cfg      cfg;
  vrf_axil_regmodel #(DWIDTH) model;
  vrf_axil_cov_t    cov;

  mailbox #(txn_t)  from_drv;     // 已发起事务
  mailbox #(txn_t)  from_mon;     // 已观测事务

  vrf_axil_sequencer_t  repro_seqr;   // 失败复现：回传通道
  vrf_axil_monitor_t    mon_h;        // 失败复现：宽监视模式

  txn_t wr_iss[$];                // 待匹配的写事务（按方向分离，保证可确定性配对）
  txn_t rd_iss[$];

  int n_issued   = 0;
  int n_checked  = 0;
  int n_pass     = 0;
  int n_fail     = 0;
  int n_skip     = 0;
  int n_repro    = 0;

  txn_t fail_q[$];                // 失败事务清单
  int   err_fd;                   // 错误报告文件句柄

  function new(vrf_axil_cfg cfg, vrf_axil_regmodel #(DWIDTH) model, vrf_axil_cov_t cov,
               mailbox #(txn_t) from_drv, mailbox #(txn_t) from_mon);
    this.cfg      = cfg;
    this.model    = model;
    this.cov      = cov;
    this.from_drv = from_drv;
    this.from_mon = from_mon;
  endfunction

  function void open_report();
    err_fd = $fopen($sformatf("%s/%s_err.txt", cfg.log_dir, cfg.test_name), "w");
    if (err_fd != 0) begin
      $fdisplay(err_fd, "# %s 失败用例错误报告", cfg.test_name);
      $fdisplay(err_fd, "# 仿真时间: %0t ns, 随机种子: %0d", $time, cfg.seed);
      $fdisplay(err_fd, "# ---------------------------------------------------------------");
    end
  endfunction

  function void close_report();
    if (err_fd != 0) $fclose(err_fd);
  endfunction

  task run();
    fork
      collect_issued();
      check_observed();
    join
  endtask

  // ------------------------------ 收集已发起事务 ------------------------------
  task automatic collect_issued();
    txn_t t;
    forever begin
      from_drv.get(t);
      n_issued++;
      if (t.txn_dir == AXIL_WR) wr_iss.push_back(t);
      else                      rd_iss.push_back(t);
    end
  endtask

  // ------------------------------ 比对已观测事务 ------------------------------
  task automatic check_observed();
    txn_t o, iss;
    forever begin
      from_mon.get(o);
      iss = null;
      if (o.txn_dir == AXIL_WR) begin
        if (wr_iss.size() > 0) iss = wr_iss.pop_front();
      end else begin
        if (rd_iss.size() > 0) iss = rd_iss.pop_front();
      end

      if (iss == null) begin
        // 观测到未经发起的事务：直接判失败
        n_checked++;
        n_fail++;
        report_fail(null, o, "观测到未发起的事务");
        vrf_axil_done_ctrl::drop();
        continue;
      end

      if (iss.txn_result == TIMEOUT) begin
        if (iss.expect_interrupt && (iss.obs_interrupted || o.obs_interrupted)) begin
          n_skip++;
        end else begin
          n_checked++;
          n_fail++;
          report_fail(iss, o, (iss.txn_reason == "") ? "事务超时" : iss.txn_reason);
        end
      end else if (iss.obs_interrupted || o.obs_interrupted) begin
        if (iss.expect_interrupt) begin
          n_skip++;                         // 预期被复位打断，不计失败
        end else begin
          n_checked++;
          n_fail++;
          report_fail(iss, o, "事务被复位非预期打断");
        end
      end else if (!iss.check_enable) begin
        n_skip++;                           // 定向用例主动关闭比对
      end else begin
        n_checked++;
        if (compare(iss, o)) begin
          n_pass++;
        end else begin
          n_fail++;
          fail_q.push_back(iss.clone());
          report_fail(iss, o, iss.txn_reason);
          do_repro(iss);
        end
        if (cov != null) cov.sample(o, model.is_ro(o.obs_addr), !model.is_mapped(o.obs_addr));
      end

      vrf_axil_done_ctrl::drop();
    end
  endtask

  // ------------------------------ 逐项比对 ------------------------------
  function bit compare(txn_t iss, txn_t o);
    bit ok = 1'b1;
    iss.txn_reason = "";

    // 地址一致性
    if (o.obs_addr !== iss.txn_addr) begin
      ok = 0;
      iss.txn_reason = $sformatf("地址不一致：驱动 0x%0h，总线观测 0x%0h", iss.txn_addr, o.obs_addr);
      return ok;
    end

    if (iss.txn_dir == AXIL_WR) begin
      // 写数据与字节选通一致性
      if (o.obs_wdata !== iss.txn_data) begin
        ok = 0;
        iss.txn_reason = $sformatf("写数据不一致：驱动 0x%0h，总线观测 0x%0h", iss.txn_data, o.obs_wdata);
        return ok;
      end
      if (o.obs_strb !== iss.txn_strb) begin
        ok = 0;
        iss.txn_reason = $sformatf("字节选通不一致：驱动 %b，总线观测 %b", iss.txn_strb, o.obs_strb);
        return ok;
      end
    end else begin
      // 读数据一致性（期望值由寄存器模型在握手当拍预测）
      if (o.obs_rdata !== o.exp_rdata) begin
        ok = 0;
        iss.txn_reason = $sformatf("读数据不一致：模型预期 0x%0h，总线返回 0x%0h", o.exp_rdata, o.obs_rdata);
        return ok;
      end
    end

    // 响应合法性
    if (o.obs_resp !== o.exp_resp) begin
      ok = 0;
      iss.txn_reason = $sformatf("响应不一致：预期 %s，实际 %s", o.exp_resp.name(), o.obs_resp.name());
      return ok;
    end
    if (o.obs_resp == EXOKAY) begin
      ok = 0;
      iss.txn_reason = "AXI4-Lite 不应出现 EXOKAY 响应";
      return ok;
    end

    // ID 一致性：期望值来自 cfg（ID 是否检查、期望值属 DUT 能力，不写死在库内）
    if (cfg.exp_id_check && (o.obs_id !== cfg.exp_id_value[IDWIDTH-1:0])) begin
      ok = 0;
      iss.txn_reason = $sformatf("事务 ID 不符：预期 %0d，实际 %0d", cfg.exp_id_value, o.obs_id);
      return ok;
    end

    return ok;
  endfunction

  // ------------------------------ 错误报告格式化输出 ------------------------------
  function void report_fail(txn_t iss, txn_t o, string reason);
    if (err_fd == 0) return;
    $fdisplay(err_fd, "----- 失败事务 #%0d -----", n_fail);
    $fdisplay(err_fd, "  时间戳   : %0t ns", $time);
    if (iss != null) begin
      $fdisplay(err_fd, "  激励     : %s", iss.convert2string());
    end else begin
      $fdisplay(err_fd, "  激励     : <未发起>");
    end
    $fdisplay(err_fd, "  观测     : %s", o.convert2string_obs());
    if (iss != null && !iss.obs_interrupted) begin
      $fdisplay(err_fd, "  期望读数据: 0x%0h", o.exp_rdata);
      $fdisplay(err_fd, "  期望响应 : %s", o.exp_resp.name());
    end
    $fdisplay(err_fd, "  失败原因 : %s", reason);
    $fdisplay(err_fd, "");
    $display("[%0t][VRF_AXIL][FAIL] %s : %s", $time,
             (iss == null) ? "<未发起>" : iss.convert2string(), reason);
  endfunction

  // ------------------------------ 失败用例自动化复现 ------------------------------
  task automatic do_repro(txn_t iss);
    txn_t r;
    int   fd;
    if (!cfg.enable_repro) return;
    if (n_repro >= cfg.repro_max_attempts) return;
    if (repro_seqr == null) return;
    r = iss.clone();
    r.is_repro = 1'b1;
    // 复现事务同样计入完成计数，否则 wait_idle 会在复现完成前提前返回
    repro_seqr.inject_repro(r);
    vrf_axil_done_ctrl::raise();
    n_repro++;
    if (mon_h != null) mon_h.set_wide_mode(1'b1);
    $display("[%0t][VRF_AXIL][REPRO] 失败事务已回注 sequencer 复现，并开启宽监视模式", $time);
    // 记录随机种子，供脚本以相同种子整用例回放（落在日志目录，避免污染工程根目录）
    fd = $fopen($sformatf("%s/%s", cfg.log_dir, cfg.seed_file), "w");
    if (fd != 0) begin
      $fdisplay(fd, "%0d", cfg.seed);
      $fclose(fd);
    end
  endtask
endclass

typedef vrf_axil_scoreboard #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_scoreboard_t;
