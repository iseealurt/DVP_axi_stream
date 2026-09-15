`timescale 1ns/1ps
`include "../IF/if_axil.sv"
package VRF_AXI4L;
  // ------------------------------- Definiiton of common types -------------------------------
  typedef enum logic [1:0] {
    PASS,
    FAIL,
    TIMEOUT
  } vrf_result_e;

  typedef enum logic [1:0] {
    OKAY,
    RSV,
    SLVERR,
    DECERR
  } axi_resp_e;

  typedef enum logic [1:0] {
    NORMAL,
    HIGH_IMPEDANCE,
    UNKNOWN_X
  } sig_status_e;

  // 事务方向
  typedef enum {AXIL_WR, AXIL_RD} axil_dir_e;

  // ------------------------------- AXI4-Lite transaction -------------------------------
  // package 与 typedef 均不支持参数化，位宽相关的数据类型只能由参数化 class 承载；
  // 各组件按自身参数声明，例如 axil_txn#(AWIDTH, DWIDTH, IDWIDTH)。
  class axil_txn#(
    parameter AWIDTH  = 32 ,
    parameter DWIDTH  = 64 ,
    parameter IDWIDTH = 4
  );
    localparam STRBWIDTH = DWIDTH/8;
    typedef axil_txn#(AWIDTH, DWIDTH, IDWIDTH) this_type;

    // ------------------------------ 随机激励 ------------------------------
    rand  axil_dir_e            txn_dir;     // 读写方向
    rand  logic [AWIDTH-1:0]    txn_addr;    // 本次地址
    rand  logic [DWIDTH-1:0]    txn_data;    // 本次数据
    rand  logic [STRBWIDTH-1:0] txn_strb;    // 字节选通，仅写事务有意义
    randc logic [IDWIDTH-1:0]   txn_mst_id;  // 主机 ID，按周期遍历取值

    // ------------------------------ 非随机属性 ------------------------------
    int    txn_id;    // 事务 ID，用于复现
    string txn_name;  // 用例名

    // ------------------------------ 结果，由 monitor/scoreboard 回填 ------------------------------
    axi_resp_e   txn_resp;    // 本次访问的 AXI 响应
    vrf_result_e txn_result;  // 比对结论
    string       txn_reason;  // 失败原因

    static int id_cnt = 0;    // 全局事务计数器，构造时自增

    // ------------------------------ 约束 ------------------------------
    // 读写方向均衡
    constraint c_dir_dist {
      txn_dir dist {AXIL_WR := 1, AXIL_RD := 1};
    }

    // 地址按数据位宽对齐，避免非法传输
    constraint c_addr_align {
      txn_addr % STRBWIDTH == 0;
    }

    // 写事务至少选通一个字节；读事务不关心 strb，统一置全 1
    // solve...before 只能出现在 constraint 块内部，用来指定求解顺序：
    // 先定方向，再据此定 strb，避免求解器在两者之间反复权衡
    constraint c_strb_legal {
      solve txn_dir before txn_strb;
      if (txn_dir == AXIL_WR) txn_strb != 0;
      else                    txn_strb == '1;
    }

    // ------------------------------ 构造 ------------------------------
    function new(string name = "axil_txn");
      txn_id     = id_cnt++;
      txn_name   = name;
      txn_resp   = OKAY;
      txn_result = PASS;
      txn_reason = "";
    endfunction

    // ------------------------------ 随机化回调 ------------------------------
    function void post_randomize();
      // 新激励产生后，上一轮的回填结果失效，需要重新判定
      txn_resp   = OKAY;
      txn_result = PASS;
      txn_reason = "";
    endfunction

    // ------------------------------ 拷贝 ------------------------------
    virtual function void copy(this_type rhs);
      this.txn_dir    = rhs.txn_dir;
      this.txn_addr   = rhs.txn_addr;
      this.txn_data   = rhs.txn_data;
      this.txn_strb   = rhs.txn_strb;
      this.txn_mst_id = rhs.txn_mst_id;
      this.txn_id     = rhs.txn_id;
      this.txn_name   = rhs.txn_name;
      this.txn_resp   = rhs.txn_resp;
      this.txn_result = rhs.txn_result;
      this.txn_reason = rhs.txn_reason;
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
      return $sformatf("%s[%0d] %s addr=0x%0h data=0x%0h strb=%b mst_id=%0d resp=%s",
                       txn_name, txn_id, dir_str,
                       txn_addr, txn_data, txn_strb, txn_mst_id, txn_resp.name());
    endfunction

    function void display(string prefix = "AXIL_TXN");
      $display("[%0t] %s : %s", $time, prefix, convert2string());
    endfunction
  endclass

endpackage
