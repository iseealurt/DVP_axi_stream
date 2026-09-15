// =============================================================================
// driver（驱动器）类
//   - 持有虚拟主机接口，按事务对象驱动 AXI4-Lite 激励
//   - 可空行为模型：空闲周期、AW/W 到达延迟、B/R 通道反压延迟均可配置，
//     置零即退化为无延迟的直连驱动
//   - 读写分别由独立流驱动，允许读事务与写事务在总线上并发
//   - 握手超时与复位中断均被记录并随事务回传给计分板
//
// 驱动方式：直接对接口变量做非阻塞赋值（`mst_vif.awvalid <= ...`），
//   在 `@(mst_vif.cb)` 唤醒之后执行，落在 NBA 区，
//   与 DUT 同沿采样无竞争；不使用时钟块输出，避免同一信号多进程驱动。
//   主机侧驱动信号由本驱动器独占（上电自检阶段由 vrf_axil_bringup 独占）。
// =============================================================================
class vrf_axil_driver #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  localparam int STRBWIDTH = DWIDTH / 8;
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst_vif;   // 虚拟主机接口
  virtual vrf_axil_slv_if #(AWIDTH, DWIDTH, IDWIDTH) slv_vif;   // 虚拟从机接口（预留复用）
  vrf_axil_cfg       cfg;
  vrf_role_e         role = VRF_ROLE_MST;                       // 驱动器角色

  mailbox #(txn_t)   req_mbx;    // 来自 sequencer
  mailbox #(txn_t)   done_mbx;   // 已驱动事务，送往计分板
  mailbox #(txn_t)   wr_q;       // 内部写流队列
  mailbox #(txn_t)   rd_q;       // 内部读流队列

  int n_driven = 0;

  function new(
    vrf_axil_cfg cfg,
    virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst_vif,
    virtual vrf_axil_slv_if #(AWIDTH, DWIDTH, IDWIDTH) slv_vif,
    mailbox #(txn_t) req_mbx,
    mailbox #(txn_t) done_mbx
  );
    this.cfg      = cfg;
    this.mst_vif  = mst_vif;
    this.slv_vif  = slv_vif;
    this.req_mbx  = req_mbx;
    this.done_mbx = done_mbx;
    this.wr_q     = new();
    this.rd_q     = new();
  endfunction

  // 主机侧驱动信号初始化：驱动器接管总线前调用，避免上电 X 态
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

  task run();
    init_outputs();
    fork
      dispatch();
      wr_stream();
      rd_stream();
    join
  endtask

  // 按方向分发，使读、写各自串行、彼此并发
  task automatic dispatch();
    txn_t t;
    forever begin
      req_mbx.get(t);
      if (t.txn_dir == AXIL_WR) wr_q.put(t);
      else                      rd_q.put(t);
    end
  endtask

  task automatic wr_stream();
    txn_t t;
    forever begin
      wr_q.get(t);
      // 先向计分板登记已发起事务，再上总线：
      // 监视器在握手当拍即可完成观测，登记必须早于任何总线活动，
      // 否则同方向的事务配对会整体错位一笔
      done_mbx.put(t);
      drive_write(t);
      n_driven++;
    end
  endtask

  task automatic rd_stream();
    txn_t t;
    forever begin
      rd_q.get(t);
      done_mbx.put(t);
      drive_read(t);
      n_driven++;
    end
  endtask

  // ------------------------------ 写事务 ------------------------------
  task automatic drive_write(txn_t t);
    int d_aw, d_w;
    t.txn_result = PASS;
    t.obs_interrupted = 0;

    d_aw = (t.aw_delay >= 0) ? t.aw_delay : $urandom_range(cfg.aw_delay_min, cfg.aw_delay_max);
    d_w  = (t.w_delay  >= 0) ? t.w_delay  : $urandom_range(cfg.w_delay_min,  cfg.w_delay_max);

    repeat ($urandom_range(cfg.idle_cycles_min, cfg.idle_cycles_max)) @(mst_vif.cb);

    fork
      drive_aw(t, d_aw);
      drive_w(t, d_w);
    join

    if (t.obs_interrupted) begin
      t.check_enable = 1'b0;
      t.txn_result   = TIMEOUT;
      return;                       // 已被复位打断，不再等待 B 通道
    end
    wait_b(t);
  endtask

  task automatic drive_aw(txn_t t, int delay);
    int cyc = 0;
    repeat (delay) @(mst_vif.cb);
    mst_vif.awvalid <= 1'b1;
    mst_vif.awaddr  <= t.txn_addr;
    mst_vif.awport  <= 3'b000;
    forever begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        mst_vif.awvalid <= 1'b0;
        t.obs_interrupted = 1'b1;
        t.txn_reason      = "AW 握手期间发生复位";
        return;
      end
      // 自身驱动信号直读（本拍前沿值），被测信号必须用时钟块采样（前沿值）
      if (mst_vif.awvalid && mst_vif.cb.awready) begin
        t.obs_addr = mst_vif.awaddr;
        mst_vif.awvalid <= 1'b0;
        return;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.awvalid <= 1'b0;
        t.txn_result      = TIMEOUT;
        t.txn_reason      = "AW 握手超时";
        return;
      end
    end
  endtask

  task automatic drive_w(txn_t t, int delay);
    int cyc = 0;
    repeat (delay) @(mst_vif.cb);
    mst_vif.wvalid <= 1'b1;
    mst_vif.wdata  <= t.txn_data;
    mst_vif.wstrb  <= t.txn_strb;
    forever begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        mst_vif.wvalid <= 1'b0;
        t.obs_interrupted = 1'b1;
        t.txn_reason      = "W 握手期间发生复位";
        return;
      end
      if (mst_vif.wvalid && mst_vif.cb.wready) begin
        t.obs_wdata = mst_vif.wdata;
        t.obs_strb  = mst_vif.wstrb;
        mst_vif.wvalid <= 1'b0;
        return;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.wvalid <= 1'b0;
        t.txn_result      = TIMEOUT;
        t.txn_reason      = "W 握手超时";
        return;
      end
    end
  endtask

  task automatic wait_b(txn_t t);
    int d, cyc = 0;
    d = (t.force_bready_delay >= 0) ? t.force_bready_delay
                                    : $urandom_range(cfg.bready_delay_min, cfg.bready_delay_max);
    // 反压等待期间同样要感知复位，否则会漏判复位中断
    for (int i = 0; i < d; i++) begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        t.obs_interrupted = 1'b1;
        t.check_enable    = 1'b0;
        t.txn_reason      = "B 通道等待期间发生复位";
        return;
      end
    end
    mst_vif.bready <= 1'b1;
    forever begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        mst_vif.bready <= 1'b0;
        t.obs_interrupted = 1'b1;
        t.check_enable    = 1'b0;
        t.txn_reason      = "B 通道等待期间发生复位";
        return;
      end
      if (mst_vif.cb.bvalid && mst_vif.bready) begin
        t.obs_resp = axi_resp_e'(mst_vif.cb.bresp);
        t.obs_id   = mst_vif.cb.bid;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.bready <= 1'b0;
        t.txn_result      = TIMEOUT;
        t.txn_reason      = "B 响应超时";
        return;
      end
    end
    mst_vif.bready <= 1'b0;
  endtask

  // ------------------------------ 读事务 ------------------------------
  task automatic drive_read(txn_t t);
    int d, cyc = 0;
    t.txn_result = PASS;
    t.obs_interrupted = 0;

    repeat ($urandom_range(cfg.idle_cycles_min, cfg.idle_cycles_max)) @(mst_vif.cb);

    mst_vif.arvalid <= 1'b1;
    mst_vif.araddr  <= t.txn_addr;
    mst_vif.arport  <= 3'b000;
    forever begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        mst_vif.arvalid <= 1'b0;
        t.obs_interrupted = 1'b1;
        t.txn_reason      = "AR 握手期间发生复位";
        return;
      end
      if (mst_vif.arvalid && mst_vif.cb.arready) begin
        t.obs_addr = mst_vif.araddr;
        mst_vif.arvalid <= 1'b0;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.arvalid <= 1'b0;
        t.txn_result      = TIMEOUT;
        t.txn_reason      = "AR 握手超时";
        return;
      end
    end

    d = (t.force_rready_delay >= 0) ? t.force_rready_delay
                                    : $urandom_range(cfg.rready_delay_min, cfg.rready_delay_max);
    for (int i = 0; i < d; i++) begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        t.obs_interrupted = 1'b1;
        t.check_enable    = 1'b0;
        t.txn_reason      = "R 通道等待期间发生复位";
        return;
      end
    end
    mst_vif.rready <= 1'b1;
    cyc = 0;
    forever begin
      @(mst_vif.cb);
      if (!mst_vif.arstn) begin
        mst_vif.rready <= 1'b0;
        t.obs_interrupted = 1'b1;
        t.check_enable    = 1'b0;
        t.txn_reason      = "R 通道等待期间发生复位";
        return;
      end
      if (mst_vif.cb.rvalid && mst_vif.rready) begin
        t.obs_rdata = mst_vif.cb.rdata;
        t.obs_resp  = axi_resp_e'(mst_vif.cb.rresp);
        t.obs_id    = mst_vif.cb.rid;
        break;
      end
      cyc++;
      if (cyc > cfg.timeout_cycles) begin
        mst_vif.rready <= 1'b0;
        t.txn_result      = TIMEOUT;
        t.txn_reason      = "R 响应超时";
        return;
      end
    end
    mst_vif.rready <= 1'b0;
  endtask
endclass

typedef vrf_axil_driver #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_driver_t;
