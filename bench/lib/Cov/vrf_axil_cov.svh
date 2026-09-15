// =============================================================================
// 功能覆盖率收集器
//   - 覆盖维度：地址区间、读写方向、wstrb 组合、响应类型、主机 ID、只读/未映射访问
//     并对方向×地址区间、方向×字节选通、方向×响应做交叉覆盖
//   - 采样点：计分板每完成一笔事务比对即采样一次
//   - 报告：covergroup 覆盖率与 $get_coverage()，输出到文本报告
//   - UCDB 汇总由仿真脚本 coverage save 完成（vcover report 查看）
//
// 实现说明：covergroup 定义在 package 作用域，以 ref 形参绑定采样变量，
//   由覆盖率类持有实例并调用 sample() 采样。
//   ModelSim 不支持在类内声明内嵌 covergroup 实例变量，故采用此标准写法。
// =============================================================================
covergroup cg_axil (
  ref logic [1:0]  dir,
  ref logic [31:0] addr,
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

  // 地址区间
  cp_addr : coverpoint addr {
    bins r_000_01F = {[32'h00 : 32'h1F]};
    bins r_020_03F = {[32'h20 : 32'h3F]};
    bins r_040_05F = {[32'h40 : 32'h5F]};
    bins r_060_07F = {[32'h60 : 32'h7F]};
    bins r_080     = {32'h80};
    bins r_other   = default;
  }

  // 字节选通组合
  cp_strb : coverpoint strb {
    bins none    = {4'b0000};
    bins b0      = {4'b0001};
    bins b1      = {4'b0010};
    bins b2      = {4'b0100};
    bins b3      = {4'b1000};
    bins partial = {4'b0011, 4'b0101, 4'b0110, 4'b1001, 4'b1010,
                    4'b1100, 4'b0111, 4'b1011, 4'b1101, 4'b1110};
    bins full    = {4'b1111};
  }

  // 响应类型
  cp_resp : coverpoint resp {
    bins okay   = {2'd0};
    bins exokay = {2'd1};
    bins slverr = {2'd2};
    bins decerr = {2'd3};
  }

  // 主机 ID
  cp_id : coverpoint id;

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
  cx_dir_strb : cross cp_dir, cp_strb;
  cx_dir_resp : cross cp_dir, cp_resp;
endgroup

class vrf_axil_cov #(
  parameter int AWIDTH  = VRF_AW,
  parameter int DWIDTH  = VRF_DW,
  parameter int IDWIDTH = VRF_ID
);
  typedef vrf_axil_txn #(AWIDTH, DWIDTH, IDWIDTH) txn_t;

  vrf_axil_cfg cfg;

  // ------------------------------ 采样变量（ref 绑定到 covergroup） ------------------------------
  logic [1:0]  s_dir;
  logic [31:0] s_addr;
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
    s_dir = 2'd0; s_addr = 32'h0; s_strb = 4'h0;
    s_resp = 2'd0; s_id = 4'h0; s_ro_acc = 0; s_unmapped = 0;
    if (cfg.enable_coverage) begin
      cg_inst = new(s_dir, s_addr, s_strb, s_resp, s_id, s_ro_acc, s_unmapped);
      cov_on  = 1;
    end
  endfunction

  // ------------------------------ 采样 ------------------------------
  function void sample(txn_t t, bit is_ro, bit is_unmapped);
    if (!cov_on) return;
    s_dir      = t.txn_dir;
    s_addr     = t.obs_addr;
    s_strb     = (t.txn_dir == AXIL_WR) ? t.obs_strb : t.txn_strb;
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
    return $sformatf("vrf_axil_cg 功能覆盖率 = %0.2f%%  (采样 %0d 次)",
                     cg_inst.get_coverage(), n_sample);
  endfunction
endclass

typedef vrf_axil_cov #(VRF_AW, VRF_DW, VRF_ID) vrf_axil_cov_t;
