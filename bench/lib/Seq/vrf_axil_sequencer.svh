// =============================================================================
// sequencer 类
//   - 接收来自 sequence 与本环境的测试向量组成的队列
//   - 通过 mailbox 送往 driver
//   - 支持向 sequencer 内一键导入定向测试队列
//   - 支持失败用例单笔重注：复现事务优先于普通事务仲裁
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
        #1ns;   // 均空时让出时间片，避免空转
      end
    end
  endtask
endclass

typedef vrf_axil_sequencer #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_sequencer_t;
