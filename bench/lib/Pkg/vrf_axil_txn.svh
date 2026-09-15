// =============================================================================
// AXI4-Lite 事务类
//   - 随机激励：方向、地址、数据、字节选通、主机 ID
//   - 随机范围控制：地址上下限、strb 模式（由 sequence/config 注入）
//   - 时序控制：AW/W 分离间隔、B/R 通道反压延迟（定向用例可单独指定）
//   - 观测回填：monitor 采样到的地址/数据/选通/响应/ID
//   - 预期回填：monitor 在握手当拍由寄存器模型预测的期望读数据与响应
// =============================================================================
class vrf_axil_txn #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  localparam int STRBWIDTH = DWIDTH / 8;
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) this_type;

  // ------------------------------ 随机激励 ------------------------------
  rand  axil_dir_e            txn_dir;     // 读写方向
  rand  logic [AWIDTH-1:0]    txn_addr;    // 本次地址
  rand  logic [DWIDTH-1:0]    txn_data;    // 本次写数据
  rand  logic [STRBWIDTH-1:0] txn_strb;    // 字节选通，仅写事务有意义
  randc logic [IDWIDTH-1:0]   txn_mst_id;  // 主机 ID，按周期遍历取值

  // ------------------------------ 随机范围控制（非随机） ------------------------------
  logic [AWIDTH-1:0] addr_min  = '0;                    // 地址下限
  logic [AWIDTH-1:0] addr_max  = {AWIDTH{1'b1}};        // 地址上限
  int unsigned       strb_mode = 0;                     // 0=随机 1=全选通 2=单字节

  // ------------------------------ 时序控制（非随机，-1 表示沿用 config） ------------------------------
  int aw_delay         = -1;   // AW 通道 valid 相对事务开始的延迟周期
  int w_delay          = -1;   // W  通道 valid 相对事务开始的延迟周期
  int force_bready_delay = -1; // B  通道 bready 延迟
  int force_rready_delay = -1; // R  通道 rready 延迟

  // ------------------------------ 非随机属性 ------------------------------
  int    txn_id;                 // 事务 ID，用于复现
  string txn_name;               // 用例名
  bit    is_directed;            // 是否定向用例
  bit    is_repro;               // 是否失败复现重注事务
  bit    check_enable   = 1;     // 0：本笔不参与比对
  bit    expect_interrupt = 0;   // 1：本笔预期被复位打断，不计入失败

  // ------------------------------ 观测值（由 monitor/driver 回填） ------------------------------
  logic [AWIDTH-1:0]    obs_addr;
  logic [DWIDTH-1:0]    obs_wdata;
  logic [STRBWIDTH-1:0] obs_strb;
  logic [DWIDTH-1:0]    obs_rdata;
  logic [IDWIDTH-1:0]   obs_id;
  axi_resp_e            obs_resp;
  bit                   obs_interrupted;   // 传输被复位打断

  // ------------------------------ 预期值（由 monitor 依据寄存器模型回填） ------------------------------
  logic [DWIDTH-1:0] exp_rdata;
  axi_resp_e         exp_resp;

  // ------------------------------ 结论 ------------------------------
  vrf_result_e txn_result;
  string       txn_reason;

  static int id_cnt = 0;   // 全局事务计数器，构造时自增

  // ------------------------------ 约束 ------------------------------
  // 读写方向均衡
  constraint c_dir_dist {
    txn_dir dist {AXIL_WR := 1, AXIL_RD := 1};
  }

  // 地址按数据位宽对齐，避免非法传输
  constraint c_addr_align {
    txn_addr % STRBWIDTH == 0;
  }

  // 地址落在配置区间内
  constraint c_addr_range {
    txn_addr inside {[addr_min : addr_max]};
  }

  // 写事务至少选通一个字节；读事务不关心 strb，统一置全 1
  // solve...before 只能出现在 constraint 块内部，用来指定求解顺序：
  // 先定方向，再据此定 strb，避免求解器在两者之间反复权衡
  constraint c_strb_legal {
    solve txn_dir before txn_strb;
    if (txn_dir == AXIL_WR) {
      if (strb_mode == 1)      txn_strb == '1;
      else if (strb_mode == 2) $countones(txn_strb) == 1;
      else                     txn_strb != 0;
    } else {
      txn_strb == '1;
    }
  }

  // ------------------------------ 构造 ------------------------------
  function new(string name = "axil_txn");
    txn_id     = id_cnt++;
    txn_name   = name;
    txn_dir    = AXIL_WR;
    txn_addr   = '0;
    txn_data   = '0;
    txn_strb   = '0;
    txn_mst_id = '0;
    txn_resp_default();
  endfunction

  function void txn_resp_default();
    obs_addr        = '0;
    obs_wdata       = '0;
    obs_strb        = '0;
    obs_rdata       = '0;
    obs_id          = '0;
    obs_resp        = OKAY;
    txn_result      = PASS;
    txn_reason      = "";
    obs_interrupted = 0;
  endfunction

  // ------------------------------ 随机化回调 ------------------------------
  function void post_randomize();
    // 新激励产生后，上一轮的观测与结论失效，需要重新判定
    txn_resp_default();
  endfunction

  // ------------------------------ 拷贝与克隆 ------------------------------
  virtual function void copy(this_type rhs);
    this.txn_dir             = rhs.txn_dir;
    this.txn_addr            = rhs.txn_addr;
    this.txn_data            = rhs.txn_data;
    this.txn_strb            = rhs.txn_strb;
    this.txn_mst_id          = rhs.txn_mst_id;
    this.addr_min            = rhs.addr_min;
    this.addr_max            = rhs.addr_max;
    this.strb_mode           = rhs.strb_mode;
    this.aw_delay            = rhs.aw_delay;
    this.w_delay             = rhs.w_delay;
    this.force_bready_delay  = rhs.force_bready_delay;
    this.force_rready_delay  = rhs.force_rready_delay;
    this.txn_id              = rhs.txn_id;
    this.txn_name            = rhs.txn_name;
    this.is_directed         = rhs.is_directed;
    this.is_repro            = rhs.is_repro;
    this.check_enable        = rhs.check_enable;
    this.expect_interrupt    = rhs.expect_interrupt;
    this.obs_addr            = rhs.obs_addr;
    this.obs_wdata           = rhs.obs_wdata;
    this.obs_strb            = rhs.obs_strb;
    this.obs_rdata           = rhs.obs_rdata;
    this.obs_id              = rhs.obs_id;
    this.obs_resp            = rhs.obs_resp;
    this.obs_interrupted     = rhs.obs_interrupted;
    this.exp_rdata           = rhs.exp_rdata;
    this.exp_resp            = rhs.exp_resp;
    this.txn_result          = rhs.txn_result;
    this.txn_reason          = rhs.txn_reason;
  endfunction

  // 深拷贝：邮箱传递 handler 时必须用它，否则多笔事务会指向同一对象
  virtual function this_type clone();
    clone = new(txn_name);
    clone.copy(this);
  endfunction

  // ------------------------------ 打印 ------------------------------
  function string convert2string();
    string dir_str;
    dir_str = (txn_dir == AXIL_WR) ? "WR" : "RD";
    return $sformatf("%s[%0d] %s addr=0x%0h data=0x%0h strb=%b mst_id=%0d",
                     txn_name, txn_id, dir_str,
                     txn_addr, txn_data, txn_strb, txn_mst_id);
  endfunction

  function string convert2string_obs();
    string dir_str;
    dir_str = (txn_dir == AXIL_WR) ? "WR" : "RD";
    return $sformatf("%s[%0d] %s addr=0x%0h wdata=0x%0h strb=%b rdata=0x%0h resp=%s",
                     txn_name, txn_id, dir_str, obs_addr, obs_wdata,
                     obs_strb, obs_rdata, obs_resp.name());
  endfunction

  function void display(string prefix = "AXIL_TXN");
    $display("[%0t] %s : %s", $time, prefix, convert2string());
  endfunction
endclass

// 库内部使用的默认特化别名：修改此处即可整体切换位宽
typedef vrf_axil_txn #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_txn_t;
