// =============================================================================
// 定向用例库
//   用例按名注册（reg），环境/测试按名一键挂载（load），
//   对应开发计划中的「定向用例/序列按名自动注册并挂载到环境的定向队列」。
// =============================================================================
class vrf_axil_direct_lib #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  static txn_t db[string][$];   // 用例名 -> 事务队列

  // 注册一笔定向事务到指定用例名
  static function void reg_case(string case_name, txn_t t);
    if (t == null) return;
    t.is_directed = 1;
    t.txn_name    = case_name;
    if (!db.exists(case_name)) db[case_name] = {};
    db[case_name].push_back(t);
  endfunction

  // 按名挂载：case_name=="ALL" 时挂载全部用例
  static function void load(string case_name, ref txn_t q[$]);
    if (case_name == "ALL") begin
      foreach (db[s, i]) begin
        q.push_back(db[s][i]);
      end
    end else if (db.exists(case_name)) begin
      foreach (db[case_name, i]) q.push_back(db[case_name][i]);
    end
  endfunction

  static function bit has(string case_name);
    return db.exists(case_name);
  endfunction

  static function int total();
    int n = 0;
    foreach (db[s, i]) n++;
    return n;
  endfunction

  static function void clear();
    db.delete();
  endfunction
endclass

typedef vrf_axil_direct_lib #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_direct_lib_t;
