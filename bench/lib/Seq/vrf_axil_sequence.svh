// =============================================================================
// sequence（generator）类
//   - 依据 config 产生测试向量，通过 mailbox 发往 sequencer 缓存与仲裁
//   - 定向队列按名自动挂载
//   - 随机队列按 config 规模产生
//   - 每提交一笔事务，完成计数 +1（objection 式结束判据）
// =============================================================================
class vrf_axil_sequence #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn        #(AWIDTH, DWIDTH, IDWIDTH) txn_t;
  typedef vrf_axil_direct_lib #(AWIDTH, DWIDTH, IDWIDTH) dir_lib_t;

  vrf_axil_cfg      cfg;
  mailbox #(txn_t)  seq_mbx;      // 发往 sequencer
  txn_t             directed_q[$]; // 本轮的定向用例队列

  function new(vrf_axil_cfg cfg, mailbox #(txn_t) seq_mbx);
    this.cfg     = cfg;
    this.seq_mbx = seq_mbx;
  endfunction

  // ------------------------------ 定向队列 ------------------------------
  function void add_directed(txn_t t);
    directed_q.push_back(t);
  endfunction

  function void load_directed_by_name(string case_name);
    directed_q.delete();
    dir_lib_t::load(case_name, directed_q);
  endfunction

  // ------------------------------ 产生测试向量 ------------------------------
  task body();
    txn_t t;

    // 1) 定向用例队列（按名挂载）
    if (cfg.enable_directed) begin
      load_directed_by_name(cfg.directed_case);
      foreach (directed_q[i]) begin
        t = directed_q[i];
        if (t == null) continue;
        seq_mbx.put(t);
        vrf_axil_done_ctrl::pending++;
      end
    end

    // 2) 受约束随机队列
    repeat (cfg.n_rand_txn) begin
      t = new("rand");
      t.addr_min  = cfg.addr_min;
      t.addr_max  = cfg.addr_max;
      t.strb_mode = cfg.strb_mode;
      if (!t.randomize()) begin
        $display("[%0t][VRF_AXIL][ERROR] 随机化失败，请检查地址区间与约束", $time);
        vrf_axil_ctrl::assert_fail_cnt++;
      end else begin
        seq_mbx.put(t);
        vrf_axil_done_ctrl::pending++;
      end
    end

    vrf_axil_done_ctrl::seq_done = 1;
  endtask
endclass

typedef vrf_axil_sequence #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_sequence_t;
