// =============================================================================
// AXIS 帧级参考模型与比对（vrf_axis_frame_chk）
//   - 观测侧：由用例的监视进程在每拍握手（tvalid & tready）时 push_beat()
//   - 参考侧：按 DVP 驱动计划（每行像素数 + 像素值）+ 打包配置重建期望 beat 序列
//             （含有效字节数、tlast、字节序变换与填充），与观测逐拍比对
//
//   参考模型口径（与 RTL 第 12 节一致）：
//     1) 行内像素按「小端」拼进 beat：首像素在最低字节、像素内 LSB 字节在低字节；
//     2) 每行独立打包（beat 不跨行）；每拍目标字节数 = px_per_beat * pix_bytes，
//        行末不足一拍时该拍有效字节数 = 行内剩余字节数；
//     3) tlast 语义：TLAST_MODE=0 行末拍、=1 帧末拍；帧末拍（最后一行末拍）两种模式下
//        均为 1（线末即为帧末）；
//     4) 有效字节位于低字节；AXIS_CTRL.BYTE_SWAP=1 时整 beat 字节反转（有效字节落到高字节）；
//     5) tstrb：TSTRB_EN=1 时按有效字节位置产生掩码，=0 时恒全 1；tkeep 恒全 1；
//     6) 溢出/越界裁剪：输出行数 = min(实际行数, IMG_HEIGHT)，
//        每行输出像素数 = min(实际像素数, IMG_WIDTH)。
// =============================================================================
class vrf_axis_frame_chk #(parameter int DWIDTH = 256);
  localparam int STRB = DWIDTH / 8;

  // ---- 打包配置（须与寄存器写入一致）----
  int  pix_bytes    = 2;      // 每像素字节数
  int  target_bytes = 32;     // 每拍目标字节数（= px_per_beat * pix_bytes）
  bit  dvp_bswap    = 0;      // DVP_CTRL.BYTE_SWAP
  bit  axis_bswap   = 0;      // AXIS_CTRL.BYTE_SWAP
  bit  tlast_mode   = 0;      // AXIS_CTRL.TLAST_MODE
  bit  tstrb_en     = 0;      // AXIS_CTRL.TSTRB_EN

  // ---- 期望（重建结果：扁平字节流 + 每拍长度 + 每拍 tlast）----
  bit [7:0] exp_flat[$];
  int       exp_len[$];
  bit       exp_tlast[$];

  // ---- 观测（由 push_beat 填入）----
  bit [DWIDTH-1:0] obs_data[$];
  bit [STRB-1:0]   obs_strb[$];
  bit [STRB-1:0]   obs_keep[$];
  bit              obs_tlast[$];

  // ---- 统计 ----
  int n_frame    = 0;      // 已比对帧数
  int n_cmp      = 0;      // 已比对拍数
  int n_err      = 0;      // 失败拍数
  string err_log[$];       // 失败明细（最多保留 max_log 条）

  int max_log = 20;
  int n_log_frame = 0;      // 单帧已打印条数（避免大量不匹配时刷屏）

  function new(int dwidth = 256);
  endfunction

  // ------------------------------ 观测入口 ------------------------------
  function void begin_frame();
    obs_data.delete(); obs_strb.delete(); obs_keep.delete(); obs_tlast.delete();
  endfunction

  function void push_beat(bit [DWIDTH-1:0] data, bit [STRB-1:0] strb,
                          bit [STRB-1:0] keep, bit last);
    obs_data.push_back(data);
    obs_strb.push_back(strb);
    obs_keep.push_back(keep);
    obs_tlast.push_back(last);
  endfunction

  // ------------------------------ 期望重建 ------------------------------
  function bit [31:0] pix_swap(input bit [31:0] v);
    bit [31:0] r;
    r = '0;
    for (int i = 0; i < pix_bytes; i++) r[i*8 +: 8] = v[(pix_bytes-1-i)*8 +: 8];
    return r;
  endfunction

  function bit [STRB-1:0] mask_lo(input int n);
    bit [STRB-1:0] m;
    m = '0;
    for (int i = 0; i < n; i++) m[i] = 1'b1;
    return m;
  endfunction

  function bit [STRB-1:0] mask_hi(input int n);
    return mask_lo(n) << (STRB - n);
  endfunction

  // 依据驱动计划重建期望：输出行数/像素数按边界裁剪
  function void build_expect(int img_w, int img_h, int n_lines, int cnt[],
                            bit [31:0] pix[][]);
    int out_lines;
    int total;
    int off;
    int n;
    bit [7:0] lb[$];
    bit [31:0] pv;

    exp_flat.delete(); exp_len.delete(); exp_tlast.delete();

    out_lines = (n_lines < img_h) ? n_lines : img_h;
    for (int l = 0; l < out_lines; l++) begin
      lb.delete();
      total = (cnt[l] < img_w) ? cnt[l] : img_w;      // 行长裁剪
      for (int p = 0; p < total; p++) begin
        pv = dvp_bswap ? pix_swap(pix[l][p]) : pix[l][p];
        for (int b = 0; b < pix_bytes; b++) lb.push_back(pv[8*b +: 8]);   // 小端：LSB 字节在前
      end
      total = lb.size();
      if (total == 0) continue;                        // 该行无输出
      off = 0;
      while (off < total) begin
        n = total - off;
        if (n > target_bytes) n = target_bytes;
        for (int i = 0; i < n; i++) exp_flat.push_back(lb[off+i]);
        exp_len.push_back(n);
        off += n;
        exp_tlast.push_back((off == total) && (tlast_mode == 0));   // 行末拍且行 tlast 模式
      end
    end
    if (exp_len.size() != 0) begin
      // 帧末拍：两种 tlast 模式下均为 1（TLAST_MODE=1 时帧末拍即行末拍）
      exp_tlast[exp_len.size()-1] = 1'b1;
    end
  endfunction

  // ------------------------------ 逐拍比对 ------------------------------
  function void log_err(string s);
    if (err_log.size() < max_log) err_log.push_back(s);
    if (n_log_frame < 5) $display("[VRF_DVP][CHK] %s", s);
    n_log_frame++;
  endfunction

  function bit compare_frame(string tag);
    int    base = 0;
    int    n;
    bit    ok = 1;
    bit [DWIDTH-1:0] d;
    bit [STRB-1:0]   m_exp;
    bit [7:0]        ob;
    n_frame++;
    n_log_frame = 0;
    n_cmp += exp_len.size();

    if (obs_data.size() != exp_len.size()) begin
      n_err++;
      ok = 0;
      log_err($sformatf("[%s] beat 数不符：期望 %0d 拍，观测 %0d 拍",
                        tag, exp_len.size(), obs_data.size()));
    end

    for (int i = 0; i < exp_len.size(); i++) begin
      n = exp_len[i];
      if (i >= obs_data.size()) break;
      d = obs_data[i];
      // 有效字节数/位置
      m_exp = axis_bswap ? mask_hi(n) : mask_lo(n);
      if (tstrb_en) begin
        if (obs_strb[i] !== m_exp) begin
          n_err++; ok = 0;
          log_err($sformatf("[%s] 第 %0d 拍 tstrb 不符：期望 %b 实际 %b", tag, i, m_exp, obs_strb[i]));
        end
      end else if (obs_strb[i] !== {STRB{1'b1}}) begin
        n_err++; ok = 0;
        log_err($sformatf("[%s] 第 %0d 拍 tstrb 应为全 1：实际 %b", tag, i, obs_strb[i]));
      end
      if (obs_keep[i] !== {STRB{1'b1}}) begin
        n_err++; ok = 0;
        log_err($sformatf("[%s] 第 %0d 拍 tkeep 应为全 1：实际 %b", tag, i, obs_keep[i]));
      end
      if (obs_tlast[i] !== exp_tlast[i]) begin
        n_err++; ok = 0;
        log_err($sformatf("[%s] 第 %0d 拍 tlast 不符：期望 %0b 实际 %0b",
                          tag, i, exp_tlast[i], obs_tlast[i]));
      end
      // 数据字节（先还原为「有效字节在低位」的规范序）
      for (int j = 0; j < n; j++) begin
        ob = axis_bswap ? d[(STRB-1-j)*8 +: 8] : d[j*8 +: 8];
        if (ob !== exp_flat[base+j]) begin
          n_err++; ok = 0;
          log_err($sformatf("[%s] 第 %0d 拍第 %0d 字节不符：期望 0x%02h 实际 0x%02h",
                            tag, i, j, exp_flat[base+j], ob));
        end
      end
      // 填充字节应为 0
      for (int j = n; j < STRB; j++) begin
        ob = axis_bswap ? d[(STRB-1-j)*8 +: 8] : d[j*8 +: 8];
        if (ob !== 8'h00) begin
          n_err++; ok = 0;
          log_err($sformatf("[%s] 第 %0d 拍填充字节 %0d 非 0：0x%02h", tag, i, j, ob));
        end
      end
      base += n;
    end
    return ok;
  endfunction

  function void report();
    foreach (err_log[i]) $display("[VRF_DVP][CHK] %s", err_log[i]);
    $display("[VRF_DVP][CHK] 帧级比对：帧 %0d，拍 %0d，失败 %0d", n_frame, n_cmp, n_err);
  endfunction
endclass

typedef vrf_axis_frame_chk #(256) vrf_axis_frame_chk_t;
