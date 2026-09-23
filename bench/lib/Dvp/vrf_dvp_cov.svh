// =============================================================================
// DVP 数据通路功能覆盖率（vrf_dvp_cov）
//   - 覆盖「边界类型 × TLAST_MODE」交叉，以及像素格式/打包模式/字节序/tstrb 的取值分布
//   - 边界类型编码（与用例一致）：
//       0=正常  1=LINE_SHORT  2=LINE_LONG  3=FRAME_SHORT  4=FRAME_LONG  5=行短且帧短
//   - 可达 bin 口径：由定向用例矩阵全覆盖（见 Doc/Dev_report_0923.md 覆盖率表）
// =============================================================================
class vrf_dvp_cov;
  // 采样变量（先赋值再 sample）
  int  cp_boundary   = 0;
  int  cp_tlast_mode = 0;
  int  cp_pix_fmt    = 0;
  int  cp_pack_mode  = 0;
  int  cp_bswap      = 0;
  int  cp_tstrb_en   = 0;

  covergroup cg;
    option.name = "vrf_dvp_cg";

    cp_boundary_cp: coverpoint cp_boundary {
      bins b[] = {0, 1, 2, 3, 4, 5};
    }
    cp_tlast_cp: coverpoint cp_tlast_mode {
      bins b[] = {0, 1};
    }
    cp_fmt_cp: coverpoint cp_pix_fmt {
      bins b[] = {0, 1, 2, 3, 4};
    }
    cp_pack_cp: coverpoint cp_pack_mode {
      bins b[] = {0, 1, 2, 3};
    }
    cp_bswap_cp: coverpoint cp_bswap {
      bins b[] = {0, 1};
    }
    cp_tstrb_cp: coverpoint cp_tstrb_en {
      bins b[] = {0, 1};
    }
    x_boundary_tlast: cross cp_boundary_cp, cp_tlast_cp;
  endgroup

  int n_sample = 0;

  function new();
    cg = new();
  endfunction

  function void sample(int boundary, int tlast_mode, int pix_fmt, int pack_mode,
                       bit bswap, bit tstrb_en);
    cp_boundary   = boundary;
    cp_tlast_mode = tlast_mode;
    cp_pix_fmt    = pix_fmt;
    cp_pack_mode  = pack_mode;
    cp_bswap      = bswap;
    cp_tstrb_en   = tstrb_en;
    n_sample++;
    cg.sample();
  endfunction

  function string report_string();
    return $sformatf("vrf_dvp_cg 边界/打包覆盖率 = %0.2f%%  (采样 %0d 次)",
                     cg.get_coverage(), n_sample);
  endfunction
endclass
