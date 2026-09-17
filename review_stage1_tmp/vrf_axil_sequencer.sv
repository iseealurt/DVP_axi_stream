// =============================================================================
// sequencer 类
//   - 接收来自 sequence 与本环境的测试向量组成的队列
//   - 通过 mailbox 送往 driver
//   - 支持向 sequencer 内一键导入定向测试队列
//   - 支持失败用例单笔重注：复现事务优先于普通事务仲裁
//   - 三路队列均空时按接口时钟节拍轮询（时钟经全局连接表传入），不引入固定时延粒度
// =============================================================================
class vrf_axil_sequencer #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  mailbox #(txn_t) from_seq;    // 来自 sequence（generator）
  mailbox #(txn_t) from_env;    // 来自环境一键导入的定向队列
  mailbox #(txn_t) repro_mbx;   // 失败用例单笔重注（最高优先级）
  mailbox #(txn_t) to_drv;      // 送往 driver

  // 仲裁空转用的接口时钟（由 env 在连接阶段注入；未注入时按连接表兜底获取）
  virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) clk_vif;

  bit repro_enable = 0;         // 失败复现开关
  int n_arbitrated = 0;         // 已仲裁事务数

  function new();
    from_seq  = new();
    from_env  = new();
    repro_mbx = new();
    to_drv    = new();
  endfunction

  // 一键导入定向测试队列
  task import_directed_queue(txn_t q[$]);
    foreach (q[i]) begin
      if (q[i] != null) from_env.put(q[i]);
    end
  endtask

  // 失败用例单笔重注
  task inject_repro(txn_t t);
    if (t == null) return;
    repro_mbx.put(t);
  endtask

  // ------------------------------ 仲裁 ------------------------------
  // 优先级：复现事务 > 环境定向队列 > sequence 队列
  task run();
    txn_t t;
    // 空转节拍：使用接口时钟（clk_vif 由 env 注入，或从全局连接表兜底获取），
    // 而不使用固定时延轮询——固定时延会把仿真粒度耦合进库，长时间空闲时反复空转
    if (clk_vif == null) begin
      clk_vif = vrf_axil_conn_h #(AWIDTH, DWIDTH, IDWIDTH)::mst;
    end
    if (clk_vif == null) begin
      $display("[VRF_AXIL][ERROR] sequencer 未取到接口时钟（连接表未发布主机接口句柄），仲裁无法按节拍空转");
      $finish;
    end
    forever begin
      if (repro_mbx.try_get(t)) begin
        to_drv.put(t);
        n_arbitrated++;
      end else if (from_env.try_get(t)) begin
        to_drv.put(t);
        n_arbitrated++;
      end else if (from_seq.try_get(t)) begin
        to_drv.put(t);
        n_arbitrated++;
      end else begin
        @(clk_vif.cb);   // 均空时等下一个时钟沿，避免空转
      end
    end
  endtask
endclass

typedef vrf_axil_sequencer #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_sequencer_t;
