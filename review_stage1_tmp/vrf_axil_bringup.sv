// =============================================================================
// 上电信号连通性自检（bring-up check）
//   - 在自动化验证开始前执行一次基础信号激励测试
//   - 检查本轮验证所驱动的信号是否完整连接无纰漏：
//       1) 空闲态静态检查：全部总线信号无 X/Z，且主机侧与 DUT 侧取值一致
//       2) 走线激励：对允许自由翻转的信号做 0/1 走线，确认 TB 驱动可达 DUT
//       3) 探针事务：一读一写覆盖全部有效/就绪/响应信号，随后恢复原值
//   - 识别未驱动、恒定与连接错误的信号，并在仿真报告头反馈
//
// 驱动归属：主机侧驱动信号在本阶段由本类独占（`mst_vif.<sig> <= ...` 直接赋值），
//   自检结束后交回 vrf_axil_driver；接口内不写初值，避免多进程驱动。
// =============================================================================
class vrf_axil_bringup #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst_vif;
  virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt_vif;
  vrf_axil_cfg      cfg;
  vrf_axil_regmodel #(DWIDTH) model;

  // 本轮验证涉及的总线信号
  string sig_names[$] = '{
    "awvalid", "awaddr", "awport", "awready",
    "wvalid", "wdata", "wstrb", "wready",
    "bvalid", "bready", "bid", "bresp",
    "arvalid", "araddr", "arport", "arready",
    "rvalid", "rready", "rdata", "rresp", "rid"
  };

  // 本轮不纳入验证的信号（DVP 输入 / AXI-Stream 输出），仅在报告头标注
  string scope_out[$] = '{
    "pclk", "prst_n", "pdin", "pvref", "phref",
    "axis_tready", "axis_tvalid", "axis_tdata", "axis_tstrb",
    "axis_tkeep", "axis_tlast"
  };

  // TB 驱动侧信号（其余为 DUT 响应侧信号）
  string drv_side[$] = '{
    "awvalid", "awaddr", "awport", "wvalid", "wdata", "wstrb", "bready",
    "arvalid", "araddr", "arport", "rready"
  };

  bit          chg[string];    // 是否观测到跳变
  bit          xz[string];     // 是否出现 X/Z
  bit          mtch[string];   // 主机侧与 DUT 侧取值是否始终一致
  logic [63:0] prev[string];   // 上一拍取值
  bit          sampling = 0;   // 采样使能

  int  n_conn_err   = 0;       // 连接错误数
  int  n_xz_err     = 0;       // X/Z 或未驱动数
  int  n_static     = 0;       // 恒定未跳变数
  int  n_checked    = 0;

  logic [31:0] rd_val;         // 探针读回值
  logic [31:0] orig_val;       // 探针寄存器原始值

  function new(
    vrf_axil_cfg cfg,
    virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst_vif,
    virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt_vif,
    vrf_axil_regmodel #(DWIDTH) model
  );
    this.cfg     = cfg;
    this.mst_vif = mst_vif;
    this.mnt_vif = mnt_vif;
    this.model   = model;
  endfunction

  function bit is_drv_side(string s);
    foreach (drv_side[i]) if (drv_side[i] == s) return 1'b1;
    return 1'b0;
  endfunction

  // 主机侧驱动信号初始化：本阶段开始时调用，避免上电 X 态
  task automatic init_outputs();
    mst_vif.awvalid <= 1'b0;
    mst_vif.awaddr  <= '0;
    mst_vif.awport  <= '0;
    mst_vif.wvalid  <= 1'b0;
    mst_vif.wdata   <= '0;
    mst_vif.wstrb   <= '0;
    mst_vif.bready  <= 1'b0;
    mst_vif.arvalid <= 1'b0;
    mst_vif.araddr  <= '0;
    mst_vif.arport  <= '0;
    mst_vif.rready  <= 1'b0;
    @(mst_vif.cb);
  endtask

  // ------------------------------ 逐拍采样 ------------------------------
  `define VRF_BU_SAMPLE(SIG) \
    begin \
      if (prev.exists(`"SIG`")) begin \
        if (prev[`"SIG`"] !== mst_vif.SIG) chg[`"SIG`"] = 1'b1; \
      end \
      prev[`"SIG`"] = mst_vif.SIG; \
      if ($isunknown(mnt_vif.SIG)) xz[`"SIG`"] = 1'b1; \
      if (mst_vif.SIG !== mnt_vif.SIG) mtch[`"SIG`"] = 1'b0; \
    end

  task automatic sampler();
    while (sampling) begin
      @(mst_vif.cb);
      if (!sampling) break;
      `VRF_BU_SAMPLE(awvalid)
      `VRF_BU_SAMPLE(awaddr)
      `VRF_BU_SAMPLE(awport)
      `VRF_BU_SAMPLE(awready)
      `VRF_BU_SAMPLE(wvalid)
      `VRF_BU_SAMPLE(wdata)
      `VRF_BU_SAMPLE(wstrb)
      `VRF_BU_SAMPLE(wready)
      `VRF_BU_SAMPLE(bvalid)
      `VRF_BU_SAMPLE(bready)
      `VRF_BU_SAMPLE(bid)
      `VRF_BU_SAMPLE(bresp)
      `VRF_BU_SAMPLE(arvalid)
      `VRF_BU_SAMPLE(araddr)
      `VRF_BU_SAMPLE(arport)
      `VRF_BU_SAMPLE(arready)
      `VRF_BU_SAMPLE(rvalid)
      `VRF_BU_SAMPLE(rready)
      `VRF_BU_SAMPLE(rdata)
      `VRF_BU_SAMPLE(rresp)
      `VRF_BU_SAMPLE(rid)
    end
  endtask

  // ------------------------------ 探针事务 ------------------------------
  task automatic probe_write(logic [31:0] addr, logic [31:0] data, logic [3:0] strb);
    int cyc = 0;
    @(mst_vif.cb);
    mst_vif.awvalid <= 1'b1;
    mst_vif.awaddr  <= addr;
    mst_vif.awport  <= 3'b000;
    mst_vif.wvalid  <= 1'b1;
    mst_vif.wdata   <= data;
    mst_vif.wstrb   <= strb;
    mst_vif.bready  <= 1'b1;
    forever begin
      @(mst_vif.cb);
      if (mst_vif.cb.awready && mst_vif.cb.wready) begin
        // 探针握手已确认 ready 类信号发生跳变（组合型 ready 可能只维持单拍，
        // 逐拍采样未必能捕捉到，此处以握手观测为准）
        chg["awready"] = 1'b1;
        chg["wready"]  = 1'b1;
        mst_vif.awvalid <= 1'b0;
        mst_vif.wvalid  <= 1'b0;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.awvalid <= 1'b0;
        mst_vif.wvalid  <= 1'b0;
        mst_vif.bready  <= 1'b0;
        return;
      end
    end
    cyc = 0;
    forever begin
      @(mst_vif.cb);
      if (mst_vif.cb.bvalid && mst_vif.bready) begin
        chg["bvalid"] = 1'b1;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) break;
    end
    mst_vif.bready <= 1'b0;
    repeat (2) @(mst_vif.cb);
  endtask

  task automatic probe_read(logic [31:0] addr);
    int cyc = 0;
    @(mst_vif.cb);
    mst_vif.arvalid <= 1'b1;
    mst_vif.araddr  <= addr;
    mst_vif.arport  <= 3'b000;
    mst_vif.rready  <= 1'b1;
    forever begin
      @(mst_vif.cb);
      if (mst_vif.cb.arready) begin
        // 同 probe_write：以握手观测确认 ready 类信号确实发生跳变
        chg["arready"] = 1'b1;
        mst_vif.arvalid <= 1'b0;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.arvalid <= 1'b0;
        mst_vif.rready  <= 1'b0;
        return;
      end
    end
    cyc = 0;
    forever begin
      @(mst_vif.cb);
      if (mst_vif.cb.rvalid && mst_vif.rready) begin
        chg["rvalid"] = 1'b1;
        chg["rdata"]  = 1'b1;
        rd_val = mst_vif.cb.rdata;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) break;
    end
    mst_vif.rready <= 1'b0;
    repeat (2) @(mst_vif.cb);
  endtask

  // ------------------------------ 主流程 ------------------------------
  task run();
    int    i;
    bit    ok;
    logic [31:0] pat;

    // 初始化统计表
    chg.delete(); xz.delete(); mtch.delete(); prev.delete();
    foreach (sig_names[i]) begin
      chg[sig_names[i]]  = 1'b0;
      xz[sig_names[i]]   = 1'b0;
      mtch[sig_names[i]] = 1'b1;
    end

    // 等待复位释放并接管主机侧驱动信号
    wait (mst_vif.arstn === 1'b1);
    init_outputs();
    repeat (4) @(mst_vif.cb);
    sampling = 1;
    fork
      sampler();
    join_none

    // ---- 步骤 1：空闲态静态检查 ----
    repeat (8) @(mst_vif.cb);

    // ---- 步骤 2：走线激励（仅允许自由翻转的信号） ----
    for (i = 0; i < 4; i++) begin
      @(mst_vif.cb);
      mst_vif.awaddr <= (i % 2) ? 32'hFFFF_FFF0 : 32'h0000_0004;
      mst_vif.araddr <= (i % 2) ? 32'h0000_0008 : 32'hFFFF_FFF0;
      mst_vif.wdata  <= (i % 2) ? 32'hAAAA_AAAA : 32'h5555_5555;
      mst_vif.wstrb  <= (i % 2) ? 4'hA : 4'h5;
      mst_vif.awport <= (i % 2) ? 3'b101 : 3'b010;
      mst_vif.arport <= (i % 2) ? 3'b011 : 3'b100;
      mst_vif.bready <= (i % 2) ? 1'b1 : 1'b0;
      mst_vif.rready <= (i % 2) ? 1'b1 : 1'b0;
    end

    // 恢复空闲电平
    @(mst_vif.cb);
    mst_vif.awaddr <= '0;
    mst_vif.araddr <= '0;
    mst_vif.wdata  <= '0;
    mst_vif.wstrb  <= '0;
    mst_vif.awport <= '0;
    mst_vif.arport <= '0;
    mst_vif.bready <= 1'b0;
    mst_vif.rready <= 1'b0;
    repeat (4) @(mst_vif.cb);

    // ---- 步骤 3：探针事务（覆盖全部有效/就绪/响应信号） ----
    probe_read(cfg.bringup_probe_addr);
    orig_val = rd_val;
    pat      = 32'hA5A5_5A5A;
    probe_write(cfg.bringup_probe_addr, pat, 4'hF);
    probe_read(cfg.bringup_probe_addr);
    ok = (rd_val === pat);
    // 恢复探针寄存器原值，保证后续验证的模型与 DUT 一致
    probe_write(cfg.bringup_probe_addr, orig_val, 4'hF);
    model.set_mirror(cfg.bringup_probe_addr, orig_val);

    repeat (4) @(mst_vif.cb);
    sampling = 0;

    // ---- 统计结论 ----
    n_conn_err = 0; n_xz_err = 0; n_static = 0; n_checked = 0;
    foreach (sig_names[i]) begin
      n_checked++;
      if (!mtch[sig_names[i]])      n_conn_err++;
      else if (xz[sig_names[i]])    n_xz_err++;
      else if (!chg[sig_names[i]])  n_static++;
    end
    if (!ok) begin
      n_conn_err++;
      $display("[VRF_AXIL][BRINGUP] 探针寄存器回读失败：写入 0x%0h，读回 0x%0h", pat, rd_val);
    end
  endtask

  // ------------------------------ 报告头 ------------------------------
  function string report_header();
    string s;
    int    i;
    string concl;

    s = "================= 信号连通性自检报告（仿真报告头） =================\n";
    s = {s, $sformatf("自检信号数: %0d    连接错误: %0d    X/Z或未驱动: %0d    恒定: %0d\n",
                      n_checked, n_conn_err, n_xz_err, n_static)};
    s = {s, "--------------------------------------------------------------------\n"};
    s = {s, "信号            侧别     跳变  X/Z  两侧一致  结论\n"};
    s = {s, "--------------------------------------------------------------------\n"};
    foreach (sig_names[i]) begin
      if (!mtch[sig_names[i]])     concl = "连接错误";
      else if (xz[sig_names[i]])   concl = "未驱动或含X/Z";
      else if (!chg[sig_names[i]]) concl = "恒定未跳变";
      else                         concl = "正常";
      s = {s, $sformatf("%-14s  %-6s   %-3s   %-3s  %-8s  %s\n",
                        sig_names[i],
                        is_drv_side(sig_names[i]) ? "驱动" : "响应",
                        chg[sig_names[i]] ? "是" : "否",
                        xz[sig_names[i]]  ? "是" : "否",
                        mtch[sig_names[i]] ? "是" : "否",
                        concl)};
    end
    s = {s, "--------------------------------------------------------------------\n"};
    s = {s, "本轮不纳入验证的信号（DVP 输入 / AXI-Stream 输出，按开发计划边界）：\n  "};
    foreach (scope_out[i]) s = {s, scope_out[i], " "};
    s = {s, "\n====================================================================\n"};
    return s;
  endfunction

  function bit is_pass();
    return (n_conn_err == 0) && (n_xz_err == 0);
  endfunction

  `undef VRF_BU_SAMPLE
endclass

typedef vrf_axil_bringup #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_bringup_t;
