// =============================================================================
// 公共类型定义与全局运行控制
//   - AXI4-Lite 默认位宽参数（可由 typedef 重新特化，以对接不同位宽的 DUT）
//   - 事务方向/结果/响应/寄存器访问属性等枚举
//   - 运行期全局控制与完成计数（objection 式）
// =============================================================================

// ------------------------------ 默认位宽参数 ------------------------------
localparam int VRF_AW = 32;    // 地址位宽
localparam int VRF_DW = 32;    // 数据位宽
localparam int VRF_ID = 4;     // 事务 ID 位宽
localparam int VRF_SB = VRF_DW / 8;   // 字节选通位宽

// ------------------------------ 通用枚举 ------------------------------
typedef enum logic [1:0] { PASS, FAIL, TIMEOUT } vrf_result_e;               // 比对结论
typedef enum logic [1:0] { OKAY, EXOKAY, SLVERR, DECERR } axi_resp_e;        // AXI4 响应编码
typedef enum logic [1:0] { NORMAL, HIGH_IMPEDANCE, UNKNOWN_X } sig_status_e; // 信号状态
typedef enum { AXIL_WR, AXIL_RD } axil_dir_e;                                // 事务方向
typedef enum { VRF_ROLE_MST, VRF_ROLE_SLV } vrf_role_e;                      // 驱动器角色
typedef enum { ACC_RW, ACC_RO, ACC_W1C } vrf_access_e;                       // 寄存器访问属性

// ------------------------------ 全局接口句柄 ------------------------------
// 通配符自动连接桥 / 从机参考模型在 0 时刻把接口实例发布到此处，
// 环境、驱动器、监视器、上电检查统一从这里取用，无需依赖固定层次路径。
class vrf_axil_conn_h #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  static virtual vrf_axil_mst_if #(AWIDTH, DWIDTH, IDWIDTH) mst = null;
  static virtual vrf_axil_slv_if #(AWIDTH, DWIDTH, IDWIDTH) slv = null;
  static virtual vrf_axil_mnt_if #(AWIDTH, DWIDTH, IDWIDTH) mnt = null;
  static bit published = 1'b0;
  static bit conflict  = 1'b0;   // 1：出现过重复发布（同特化多个挂具实例）

  static function void clear();
    mst = null;
    slv = null;
    mnt = null;
    published = 1'b0;
    conflict  = 1'b0;
  endfunction
endclass

// ------------------------------ 全局运行控制 ------------------------------
// 连通性自检期间关闭监视采样与协议断言，避免自检激励被误判为协议违例
class vrf_axil_ctrl;
  static bit bringup_active  = 1;    // 1：处于上电连通性自检阶段
  static bit mon_enable      = 0;    // 1：监视器开始采样总线事务
  static bit checks_enable   = 1;    // 1：协议断言与检查总开关
  static int timeout_cycles  = 200;  // 握手超时门限（时钟周期）
  static int assert_chk_cnt  = 0;    // 协议断言检查次数
  static int assert_fail_cnt = 0;    // 协议断言失败次数

  static function void reset();
    bringup_active  = 1;
    mon_enable      = 0;
    checks_enable   = 1;
    assert_chk_cnt  = 0;
    assert_fail_cnt = 0;
  endfunction
endclass

// ------------------------------ 完成计数 ------------------------------
// sequence/环境每提交一笔事务 raise() 一次，计分板完成一笔比对 drop() 一次；归零即本轮验证结束。
// 计数只通过 raise()/drop() 修改，避免 ++/-- 散落在多处、配平脆弱。
class vrf_axil_done_ctrl;
  static int pending  = 0;
  static bit seq_done = 0;
  static bit all_done = 0;

  static function void reset();
    pending  = 0;
    seq_done = 0;
    all_done = 0;
  endfunction

  // 登记待完成事务（提交事务前调用）
  static function void raise(int n = 1);
    if (n <= 0) return;
    pending += n;
  endfunction

  // 释放一笔已完成比对的事务
  static function void drop();
    if (pending <= 0) begin
      // 计数下溢说明配平被破坏（多释放或漏登记）：按断言告警处理，不做静默钳位，
      // 否则「仿真提前结束」这类平台缺陷会被悄悄掩盖
      vrf_axil_ctrl::assert_fail_cnt++;
      $display("[%0t][VRF_AXIL][ERROR] 完成计数下溢：pending 已为 0 时仍调用 drop()（本次不递减）", $time);
      return;
    end
    pending--;
    if (seq_done && (pending == 0)) all_done = 1;
  endfunction
endclass
