// =============================================================================
// 功能覆盖率收集器
//   - 覆盖维度：读写方向、地址区间、wstrb 组合、响应类型、主机 ID、只读/未映射访问
//     并对方向×地址区间、方向×字节选通、方向×响应做交叉覆盖
//   - 采样点：计分板每完成一笔事务比对即采样一次
//   - 报告：covergroup 覆盖率与 $get_coverage()，输出到文本报告
//   - UCDB 汇总由仿真脚本 coverage save 完成（vcover report 查看）
//
// 实现说明：covergroup 定义在 package 作用域，以 ref 形参绑定采样变量，
//   由覆盖率类持有实例并调用 sample() 采样。
//   ModelSim 不支持在类内声明内嵌 covergroup 实例变量，故采用此标准写法。
//
// DUT 能力与地址布局的解耦（原实现把这些写死在 covergroup 里，接入新 DUT 易漏改）：
//   1) 地址区间：covergroup 只对「区间码」采样，区间码由本类按 cfg.cov_addr_lo/hi 归一
//      （区间内四等分 + 顶部寄存器区 + 区间外），bin 定义与具体 DUT 的地址布局无关。
//   2) 异常响应 / 非 0 ID 的 bin 是否计入分母：由编译期开关决定
//      （+define+VRF_AXIL_COV_HAS_ERR / VRF_AXIL_COV_HAS_ID）——
//      ModelSim 2020.4 不支持 covergroup 参数端口（vlog-13069），
//      且 ignore_bins 上的运行期 iff 条件在 elaboration 期即固化（实测：构造后修改不生效，
//      并产生 vsim-8549 告警），故采用「按能力开关生成不同 bin 定义」的编译期方案；
//      cfg.has_err_resp / cfg.has_id 为 API 侧声明，构造时与编译期开关做一致性校验。
// =============================================================================

`ifdef VRF_AXIL_COV_HAS_ERR
  localparam bit VRF_COV_HAS_ERR_COMPILED = 1'b1;
`else
  localparam bit VRF_COV_HAS_ERR_COMPILED = 1'b0;
`endif

`ifdef VRF_AXIL_COV_HAS_ID
  localparam bit VRF_COV_HAS_ID_COMPILED = 1'b1;
`else
  localparam bit VRF_COV_HAS_ID_COMPILED = 1'b0;
`endif

covergroup cg_axil (
  ref logic [1:0]  dir,
  ref logic [2:0]  region,     // 地址区间码（由覆盖率类按 cfg 归一）
  ref logic [3:0]  strb,
  ref logic [1:0]  resp,
  ref logic [3:0]  id,
  ref bit          ro_acc,
  ref bit          unmap
);
  option.per_instance = 1;
  option.name         = "vrf_axil_cg";

  // 读写方向
  cp_dir : coverpoint dir {
    bins wr = {2'd0};
    bins rd = {2'd1};
  }

  // 地址区间码：0~3 为区间内四等分段，4 为顶部寄存器区，5 为区间外
  cp_addr : coverpoint region {
    bins r_seg0 = {3'd0};
    bins r_seg1 = {3'd1};
    bins r_seg2 = {3'd2};
    bins r_seg3 = {3'd3};
    bins r_top  = {3'd4};
    bins r_other= {3'd5};
  }

  // 字节选通：仅写事务具备字节使能语义，读事务不采样该覆盖点
  cp_strb : coverpoint strb iff (dir == 2'd0) {
    bins b0      = {4'b0001};
    bins b1      = {4'b0010};
    bins b2      = {4'b0100};
    bins b3      = {4'b1000};
    bins partial = {4'b0011, 4'b0101, 4'b0110, 4'b1001, 4'b1010,
                    4'b1100, 4'b0111, 4'b1011, 4'b1101, 4'b1110};
    bins full    = {4'b1111};
    // 结构非法：AXI 写事务必须至少选通一个字节，写激励约束亦禁止全零选通
    ignore_bins ig_none = {4'b0000};
  }

  // 响应类型：AXI4-Lite 不使用 EXOKAY；异常响应 bin 依 DUT 能力（编译期开关）生成
  cp_resp : coverpoint resp {
    bins okay = {2'd0};
`ifdef VRF_AXIL_COV_HAS_ERR
    bins slverr = {2'd2};
    bins decerr = {2'd3};
`else
    // 被测从端不产生错误响应，两种异常响应均不可达
    ignore_bins ig_slverr = {2'd2};
    ignore_bins ig_decerr = {2'd3};
`endif
    ignore_bins ig_exokay = {2'd1};
  }

  // 主机 ID：非 0 ID bin 依 DUT 能力（编译期开关）生成
  cp_id : coverpoint id {
    bins id0 = {4'd0};
`ifdef VRF_AXIL_COV_HAS_ID
    bins id_oth = {[4'd1 : 4'd15]};
`else
    // 被测从端 bid/rid 恒为 0，仅 0 号 ID 可达
    ignore_bins ig_other_id = {[4'd1 : 4'd15]};
`endif
  }

  // 只读访问 / 未映射访问
  cp_ro : coverpoint ro_acc {
    bins yes = {1'b1};
    bins no  = {1'b0};
  }
  cp_unmapped : coverpoint unmap {
    bins yes = {1'b1};
    bins no  = {1'b0};
  }

  // 交叉覆盖
  cx_dir_addr : cross cp_dir, cp_addr;

  // 方向×字节选通：读方向无字节选通语义，整体忽略读方向列
  cx_dir_strb : cross cp_dir, cp_strb {
    ignore_bins ig_rd = binsof(cp_dir) intersect {2'd1};
  }

  // 方向×响应：异常响应已在 cp_resp 中以 ignore_bins 排除，交叉无需重复声明
  cx_dir_resp : cross cp_dir, cp_resp;
endgroup

class vrf_axil_cov #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  localparam logic [2:0] REGION_TOP   = 3'd4;   // 顶部寄存器区
  localparam logic [2:0] REGION_OTHER = 3'd5;   // 覆盖区间之外

  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  vrf_axil_cfg cfg;

  // ------------------------------ 采样变量（ref 绑定到 covergroup） ------------------------------
  logic [1:0]  s_dir;
  logic [2:0]  s_region;
  logic [3:0]  s_strb;
  logic [1:0]  s_resp;
  logic [3:0]  s_id;
  bit          s_ro_acc;
  bit          s_unmapped;

  cg_axil cg_inst;
  bit     cov_on = 0;
  int     n_sample = 0;

  function new(vrf_axil_cfg cfg);
    this.cfg = cfg;
    s_dir = 2'd0; s_region = 3'd0; s_strb = 4'h0;
    s_resp = 2'd0; s_id = 4'h0; s_ro_acc = 0; s_unmapped = 0;

    // 能力开关一致性校验：bin 生成是编译期的，cfg 是 API 侧声明，两者必须一致，
    // 否则覆盖率分母会与实际 DUT 能力不符（例如声明有错误响应却仍按不可达排除）
    if (cfg.has_err_resp !== VRF_COV_HAS_ERR_COMPILED) begin
      $fatal(1, "[VRF_AXIL] 覆盖率能力开关不一致：cfg.has_err_resp=%0b，编译期 VRF_AXIL_COV_HAS_ERR=%0b（bin 定义由编译期开关决定，两者必须一致）",
              cfg.has_err_resp, VRF_COV_HAS_ERR_COMPILED);
    end
    if (cfg.has_id !== VRF_COV_HAS_ID_COMPILED) begin
      $fatal(1, "[VRF_AXIL] 覆盖率能力开关不一致：cfg.has_id=%0b，编译期 VRF_AXIL_COV_HAS_ID=%0b（bin 定义由编译期开关决定，两者必须一致）",
              cfg.has_id, VRF_COV_HAS_ID_COMPILED);
    end

    if (cfg.enable_coverage) begin
      cg_inst = new(s_dir, s_region, s_strb, s_resp, s_id, s_ro_acc, s_unmapped);
      cov_on  = 1;
    end
  endfunction

  // ------------------------------ 地址区间归一 ------------------------------
  // 把地址映射为区间码，使 covergroup 的 bin 定义与具体 DUT 的地址布局解耦：
  //   区间 [cov_addr_lo, cov_addr_hi] 内四等分 -> 0~3；顶部寄存器区 -> 4；区间外 -> 5
  function logic [2:0] region_of(logic [31:0] addr);
    int unsigned span, seg, idx;
    if ((addr < cfg.cov_addr_lo) || (addr > cfg.cov_addr_hi)) return REGION_OTHER;
    span = cfg.cov_addr_hi - cfg.cov_addr_lo + 1;
    seg  = span / 4;
    if (seg == 0) return REGION_TOP;
    idx = (addr - cfg.cov_addr_lo) / seg;
    if (idx > 3) return REGION_TOP;
    return idx[2:0];
  endfunction

  // ------------------------------ 采样 ------------------------------
  function void sample(txn_t t, bit is_ro, bit is_unmapped);
    if (!cov_on) return;
    s_dir      = t.txn_dir;
    s_region   = region_of(t.obs_addr);
    s_strb     = t.obs_strb;      // 读事务由监视器统一记为全选通
    s_resp     = t.obs_resp;
    s_id       = t.obs_id;
    s_ro_acc   = is_ro;
    s_unmapped = is_unmapped;
    cg_inst.sample();
    n_sample++;
  endfunction

  function real get_coverage();
    if (!cov_on) return 0.0;
    return cg_inst.get_coverage();
  endfunction

  function string report_string();
    if (!cov_on) return "覆盖率收集未启用";
    return $sformatf("vrf_axil_cg 功能覆盖率 = %0.2f%%  (采样 %0d 次)", cg_inst.get_coverage(), n_sample);
  endfunction

  // 覆盖率口径说明：以下 bin 以 ignore_bins 排除，不计入覆盖率分母
  function string report_note();
    string s;
    s = "  口径说明：已排除结构非法/当前 DUT 不可达的 bin——\n";
    s = {s, "    写事务全零选通（结构非法）、读方向×字节选通（读事务无字节选通语义）、\n"};
    s = {s, "    EXOKAY（AXI4-Lite 不使用）"};
    if (!cfg.has_err_resp) s = {s, "、SLVERR/DECERR（本 DUT 不产生错误响应）"};
    if (!cfg.has_id)       s = {s, "、非 0 主机 ID（本 DUT 的 bid/rid 恒为 0）"};
    s = {s, "。\n"};
    s = {s, $sformatf("  地址区间按 cfg.cov_addr_lo/hi（0x%0h~0x%0h）归一为「四等分 + 顶部寄存器区 + 区间外」六段。\n",
                      cfg.cov_addr_lo, cfg.cov_addr_hi)};
    return s;
  endfunction
endclass

typedef vrf_axil_cov #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_cov_t;
