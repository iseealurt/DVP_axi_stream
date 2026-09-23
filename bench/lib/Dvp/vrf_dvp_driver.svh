// =============================================================================
// DVP 激励发生器（vrf_dvp_driver）
//   - 驱动 pclk 域 pdin/pvref/phref，按「像素格式 -> 每像素字节数」字节串行发送
//   - 支持正常帧与边界注入：每行像素数、每帧行数可多于/少于设定值（行短/行长/帧短/帧长）
//   - 记录实际发送的像素值，供 AXIS 侧帧级参考模型构建期望
//
//   驱动约定（同库内其它驱动器）：在 @(vif.cb) 唤醒之后直接赋值（NBA 区），
//   与被测同沿采样无竞争；极性由 pvref_pol/phref_pol 指定（0=高有效，1=低有效）。
//
//   字节序约定（见 Doc/Reg_v_0_0.md §3.8）：
//     每像素 n 拍、首个拍为像素最高字节（MSB first）；
//     DVP_CTRL.BYTE_SWAP=1 时 RTL 在合并处交换像素内字节（由参考模型按位反转体现）。
// =============================================================================
class vrf_dvp_driver #(parameter int DWIDTH = 8);
  virtual vrf_dvp_if #(DWIDTH) vif;

  // ---- 几何与格式（须与寄存器配置一致）----
  int  img_w     = 8;      // 设定输出宽（IMG_WIDTH）
  int  img_h     = 4;      // 设定输出高（IMG_HEIGHT）
  int  pix_bytes = 2;      // 每像素字节数（由 PIX_FMT 决定）
  bit  pvref_pol = 0;      // 帧有效极性：0=高有效 1=低有效
  bit  phref_pol = 0;      // 行有效极性：0=高有效 1=低有效
  int  data_seed = 0;      // 像素数据种子（确定性伪随机，便于复现）

  // ---- 边界注入 ----
  int  line_pix_delta   = 0;      // 每行实际像素数 = img_w + delta（<0 行短，>0 行长）
  int  frame_line_delta = 0;      // 实际行数 = img_h + delta（<0 帧短，>0 帧长）
  int  line_override[int];        // 指定行（0 起）的实际像素数，优先于 line_pix_delta
  int  line_blank_pclk  = 8;      // 行间消隐拍数（须 > RTL 输入同步链深度 4）
  int  frame_blank_pclk = 8;      // 帧内首个行前的消隐拍数
  int  frame_gap_pclk   = 12;     // 帧末消隐拍数

  // ---- 记录：最近一次 drive_frame 实际发送的内容 ----
  int        n_sent_lines = 0;
  int        sent_pix_cnt[];      // 每行实际发送像素数
  bit [31:0] sent_pix    [][];    // [行][列] 像素值（低位对齐，有效位宽 = pix_bytes*8）

  function new(virtual vrf_dvp_if #(DWIDTH) vif);
    this.vif = vif;
  endfunction

  // ------------------------------ 数据生成 ------------------------------
  function bit [31:0] pix_mask();
    return (pix_bytes >= 4) ? 32'hFFFF_FFFF : ((32'h1 << (8*pix_bytes)) - 1);
  endfunction

  // 确定性伪随机像素（与行列号、data_seed 相关；不使用 $urandom，保证可复现）
  function bit [31:0] gen_pix(int l, int p);
    bit [31:0] v;
    v = (l * 32'd2654435761) ^ (p * 32'd40503) ^ (data_seed * 32'd2246822519);
    v = v ^ (v >> 13);
    v = v * 32'd2654435761;
    return v & pix_mask();
  endfunction

  function int line_pix_of(int l);
    if (line_override.exists(l)) return line_override[l];
    return img_w + line_pix_delta;
  endfunction

  // 生成一次驱动计划（不驱动引脚）：n_lines 行、每行像素数按边界设定
  function void plan_frame();
    int cnt;
    n_sent_lines = img_h + frame_line_delta;
    if (n_sent_lines < 0) n_sent_lines = 0;
    sent_pix_cnt = new[n_sent_lines];
    sent_pix     = new[n_sent_lines];
    for (int l = 0; l < n_sent_lines; l++) begin
      cnt = line_pix_of(l);
      if (cnt < 0) cnt = 0;
      sent_pix_cnt[l] = cnt;
      sent_pix[l]     = new[cnt];
      for (int p = 0; p < cnt; p++) sent_pix[l][p] = gen_pix(l, p);
    end
  endfunction

  // ------------------------------ 引脚驱动 ------------------------------
  task automatic drive_levels(bit pv, bit ph, logic [DWIDTH-1:0] d);
    vif.pvref = pvref_pol ? ~pv : pv;
    vif.phref = phref_pol ? ~ph : ph;
    vif.pdin  = d;
  endtask

  // 空闲保持：无帧、无行（寄存器阶段使用）
  task automatic quiesce();
    drive_levels(1'b0, 1'b0, '0);
    repeat (4) @(vif.cb);
  endtask

  // 只翻 pvref（不产生任何行）：用于「让配置在帧边界提交但本帧不产生输出」
  //   每个 pvref 边沿最多提交/确认一次配置请求，因此提交一批配置需要多个静默帧
  task automatic drive_quiet_frame(int hi_pclk = 8, int lo_pclk = 12);
    @(vif.cb);
    drive_levels(1'b1, 1'b0, '0);
    repeat (hi_pclk) @(vif.cb);
    drive_levels(1'b0, 1'b0, '0);
    repeat (lo_pclk) @(vif.cb);
    n_sent_lines = 0;
  endtask

  // 连续 n 个静默帧：用于把一批配置全部推进到 pclk 域影子寄存器（帧边界提交）
  task automatic drive_quiet_frames(int n);
    repeat (n) drive_quiet_frame();
  endtask

  // 驱动一帧（按 plan_frame 生成的计划），返回后 sent_pix/sent_pix_cnt/n_sent_lines 有效
  task automatic drive_frame();
    @(vif.cb);
    plan_frame();
    drive_levels(1'b1, 1'b0, '0);                 // 帧有效开始
    repeat (frame_blank_pclk) @(vif.cb);
    for (int l = 0; l < n_sent_lines; l++) begin
      drive_levels(1'b1, 1'b1, '0);               // 行有效开始
      for (int p = 0; p < sent_pix_cnt[l]; p++) begin
        for (int b = pix_bytes - 1; b >= 0; b--) begin   // 首拍为像素最高字节
          vif.pdin = sent_pix[l][p][8*b +: 8];
          @(vif.cb);
        end
      end
      drive_levels(1'b1, 1'b0, '0);               // 行有效结束
      repeat (line_blank_pclk) @(vif.cb);
    end
    drive_levels(1'b0, 1'b0, '0);                 // 帧有效结束
    repeat (frame_gap_pclk) @(vif.cb);
  endtask

  // 连续驱动 n 帧（每帧内容相同，由 data_seed 决定）
  task automatic drive_frames(int n);
    repeat (n) drive_frame();
  endtask
endclass

typedef vrf_dvp_driver #(8) vrf_dvp_driver_t;
