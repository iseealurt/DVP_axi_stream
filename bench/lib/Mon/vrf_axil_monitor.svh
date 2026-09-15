// =============================================================================
// monitor（监视器）类
//   - 接收来自 config 的配置信息，依据配置决定监视范围与日志粒度
//   - 单进程逐拍采样总线，保证同一拍内「先预测读、后更新写」的确定性顺序
//   - 事务握手当拍由寄存器模型完成读/写预测，回填到观测事务
//   - 生成并输出运行日志文件
//   - 失败复现时进入宽监视模式：逐拍记录全部总线信号，配合计分板产出错误报告
// =============================================================================
class vrf_axil_monitor #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  localparam int STRBWIDTH = DWIDTH / 8;
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt_vif;
  vrf_axil_cfg      cfg;
  vrf_axil_regmodel model;
  mailbox #(txn_t)  obs_mbx;     // 观测事务，送往计分板
  mailbox #(txn_t)  wr_pend_mbx; // 已接受、等待 B 响应的写事务
  mailbox #(txn_t)  rd_pend_mbx; // 已接受、等待 R 响应的读事务

  int  log_fd;                   // 运行日志文件句柄
  bit  wide_mode = 0;            // 失败复现时的宽监视模式
  int  trace_fd  = 0;

  // 采集状态
  bit                aw_pend, w_pend, ar_pend;
  logic [AWIDTH-1:0] aw_addr;
  logic [DWIDTH-1:0] w_data;
  logic [STRBWIDTH-1:0] w_strb;
  logic [AWIDTH-1:0] ar_addr;
  logic [DWIDTH-1:0] rd_pred;
  axi_resp_e         rd_pred_resp;

  int n_observed = 0;

  function new(
    vrf_axil_cfg cfg,
    virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt_vif,
    vrf_axil_regmodel model,
    mailbox #(txn_t) obs_mbx
  );
    this.cfg     = cfg;
    this.mnt_vif = mnt_vif;
    this.model   = model;
    this.obs_mbx = obs_mbx;
    wr_pend_mbx  = new();
    rd_pend_mbx  = new();
    aw_pend = 0; w_pend = 0; ar_pend = 0;
  endfunction

  function void open_log();
    log_fd = $fopen($sformatf("%s/%s_log.txt", cfg.log_dir, cfg.test_name), "w");
    if (log_fd == 0) begin
      $display("[VRF_AXIL][WARN] 无法打开运行日志文件，日志仅输出到终端");
    end
  endfunction

  function void close_log();
    if (log_fd != 0) $fclose(log_fd);
    if (trace_fd != 0) $fclose(trace_fd);
  endfunction

  task run();
    fork
      main_loop();
      wr_waiter();
      rd_waiter();
      wide_tracer();
    join
  endtask

  // ------------------------------ 单进程采样主循环 ------------------------------
  task automatic main_loop();
    txn_t o;
    forever begin
      @(mnt_vif.cb);

      if (!vrf_axil_ctrl::mon_enable) begin
        aw_pend = 0; w_pend = 0; ar_pend = 0;
        continue;
      end

      // ---- 读地址接受：立即预测，使同一拍的写事务对本次读不可见 ----
      if (!ar_pend && mnt_vif.cb.arvalid && mnt_vif.cb.arready) begin
        o = new("mon_rd");
        o.txn_dir       = AXIL_RD;
        o.obs_addr      = mnt_vif.cb.araddr;
        o.obs_strb      = '1;        // 读事务无字节选通语义，统一记为全选通
        o.exp_rdata     = model.predict_read(mnt_vif.cb.araddr);
        o.exp_resp      = model.predict_resp(AXIL_RD, mnt_vif.cb.araddr);
        o.txn_result    = PASS;
        ar_pend         = 1;
        // 交给读通道等待进程处理，避免在主循环内 fork 造成句柄共享
        rd_pend_mbx.put(o);
      end

      // ---- 写地址/数据接受 ----
      if (!aw_pend && mnt_vif.cb.awvalid && mnt_vif.cb.awready) begin
        aw_addr = mnt_vif.cb.awaddr;
        aw_pend = 1;
      end
      if (!w_pend && mnt_vif.cb.wvalid && mnt_vif.cb.wready) begin
        w_data = mnt_vif.cb.wdata;
        w_strb = mnt_vif.cb.wstrb;
        w_pend = 1;
      end
      if (aw_pend && w_pend) begin
        o = new("mon_wr");
        o.txn_dir    = AXIL_WR;
        o.obs_addr   = aw_addr;
        o.obs_wdata  = w_data;
        o.obs_strb   = w_strb;
        o.exp_rdata  = model.predict_read(aw_addr);
        o.exp_resp   = model.predict_resp(AXIL_WR, aw_addr);
        o.txn_result = PASS;
        // 写事务对寄存器的影响自下一拍起可见（与 RTL 边沿语义一致）
        model.predict_write(aw_addr, w_data, w_strb);
        aw_pend = 0;
        w_pend  = 0;
        wr_pend_mbx.put(o);
      end
    end
  endtask

  // 写响应等待进程：写流串行，同一时刻至多一笔写未完成
  task automatic wr_waiter();
    txn_t w;
    forever begin
      wr_pend_mbx.get(w);
      wait_b_resp(w);
      n_observed++;
      emit(w);
    end
  endtask

  // 读响应等待进程：读流串行，同一时刻至多一笔读未完成
  task automatic rd_waiter();
    txn_t r;
    forever begin
      rd_pend_mbx.get(r);
      wait_r_resp(r);
      ar_pend = 0;
      n_observed++;
      emit(r);
    end
  endtask

  task automatic wait_b_resp(txn_t o);
    int cyc = 0;
    while (!(mnt_vif.cb.bvalid && mnt_vif.cb.bready)) begin
      @(mnt_vif.cb);
      cyc++;
      if (!mnt_vif.arstn) begin
        o.obs_interrupted = 1;
        break;
      end
      if (cyc > cfg.timeout_cycles) begin
        o.txn_result = TIMEOUT;
        o.txn_reason = "监视器等待 B 响应超时";
        break;
      end
    end
    if (!o.obs_interrupted) begin
      o.obs_resp = axi_resp_e'(mnt_vif.cb.bresp);
      o.obs_id   = mnt_vif.cb.bid;
    end
  endtask

  task automatic wait_r_resp(txn_t o);
    int cyc = 0;
    while (!(mnt_vif.cb.rvalid && mnt_vif.cb.rready)) begin
      @(mnt_vif.cb);
      cyc++;
      if (!mnt_vif.arstn) begin
        o.obs_interrupted = 1;
        break;
      end
      if (cyc > cfg.timeout_cycles) begin
        o.txn_result = TIMEOUT;
        o.txn_reason = "监视器等待 R 响应超时";
        break;
      end
    end
    if (!o.obs_interrupted) begin
      o.obs_rdata = mnt_vif.cb.rdata;
      o.obs_resp  = axi_resp_e'(mnt_vif.cb.rresp);
      o.obs_id    = mnt_vif.cb.rid;
    end
  endtask

  task automatic emit(txn_t o);
    obs_mbx.put(o);
    if (cfg.verbose && log_fd != 0) begin
      $fdisplay(log_fd, "[%0t] %s", $time, o.convert2string_obs());
    end
  endtask

  // ------------------------------ 宽监视模式 ------------------------------
  // 失败复现时逐拍记录全部总线信号，扩大并虚化信号监测范围
  function void set_wide_mode(bit on);
    wide_mode = on;
    if (on && trace_fd == 0) begin
      trace_fd = $fopen($sformatf("%s/%s_wide_trace.txt", cfg.log_dir, cfg.test_name), "w");
      if (trace_fd == 0) trace_fd = 1;   // 退化为标准输出并打标记
    end
  endfunction

  task automatic wide_tracer();
    forever begin
      @(mnt_vif.cb);
      if (!wide_mode || !vrf_axil_ctrl::mon_enable) continue;
      if (trace_fd > 0) begin
        $fdisplay(trace_fd,
          "[%0t] AW v=%b a=0x%0h p=%0d r=%b | W v=%b d=0x%0h s=%b r=%b | B v=%b r=%b resp=%b id=%0d | ",
          $time, mnt_vif.cb.awvalid, mnt_vif.cb.awaddr, mnt_vif.cb.awport, mnt_vif.cb.awready,
          mnt_vif.cb.wvalid, mnt_vif.cb.wdata, mnt_vif.cb.wstrb, mnt_vif.cb.wready,
          mnt_vif.cb.bvalid, mnt_vif.cb.bready, mnt_vif.cb.bresp, mnt_vif.cb.bid);
        $fdisplay(trace_fd,
          "          AR v=%b a=0x%0h r=%b | R v=%b r=%b d=0x%0h resp=%b id=%0d",
          mnt_vif.cb.arvalid, mnt_vif.cb.araddr, mnt_vif.cb.arready,
          mnt_vif.cb.rvalid, mnt_vif.cb.rready, mnt_vif.cb.rdata, mnt_vif.cb.rresp, mnt_vif.cb.rid);
      end else begin
        $display("[WIDE][%0t] AW v=%b r=%b W v=%b r=%b B v=%b r=%b AR v=%b r=%b R v=%b r=%b",
                 $time, mnt_vif.cb.awvalid, mnt_vif.cb.awready,
                 mnt_vif.cb.wvalid, mnt_vif.cb.wready,
                 mnt_vif.cb.bvalid, mnt_vif.cb.bready,
                 mnt_vif.cb.arvalid, mnt_vif.cb.arready,
                 mnt_vif.cb.rvalid, mnt_vif.cb.rready);
      end
    end
  endtask
endclass

typedef vrf_axil_monitor #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_monitor_t;
