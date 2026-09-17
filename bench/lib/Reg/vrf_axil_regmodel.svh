// =============================================================================
// 轻量寄存器模型（RAL-like）
//   - 寄存器描述：名称、偏移、访问属性、复位值、自清零掩码、动态标志
//   - 镜像值：按偏移索引，随总线写事务更新
//   - 预测：写预测（含 wstrb 字节使能、W1C、自清零、按偏移注册的副作用回调）
//           读预测（返回镜像值，未映射地址按 map 配置返回）
//   - 副作用注册表：DUT 专属的写副作用（如 CTRL 的 SOFT_RST/CLR_CNT）由各 map 注册，
//     通用模型本体不含任何 DUT 偏移
//   - 事件注入接口：供定向用例在注入内部事件后同步模型（相关偏移同样由 map 填写）
//
// 位宽：全模型按数据位宽参数化（`vrf_axil_regmodel #(DWIDTH)`），镜像值、字节选通与
//   预测接口一律按 DWIDTH 派生。当前内置的两套 map（DVP2AXI / REF_SLAVE）都按 32 位字
//   定义，因此 DWIDTH≠32 时构造即 $fatal，而不是静默按 32 位计算
//   （与从机参考模型 `vrf_axil_slv_ref` 的 32 位断言口径一致）。
// =============================================================================

// ------------------------------ 写副作用回调 ------------------------------
// 按偏移注册：模型完成常规写预测后调用该偏移的回调。
// 回调直接读写镜像关联数组，因此不需要依赖模型类型，也不会把 DUT 偏移带进通用本体。
class vrf_axil_wr_cb #(parameter int DWIDTH = 32);
  virtual function void apply(
    ref   logic [DWIDTH-1:0]      mirror[int unsigned],
    input logic [31:0]            offset,
    input logic [DWIDTH-1:0]      data,
    input logic [DWIDTH/8-1:0]    strb
  );
    // 默认无副作用
  endfunction
endclass

// DVP2axi_stream 的 CTRL 副作用实现（仅该 map 注册使用）
class vrf_axil_dvp2axi_ctrl_cb #(parameter int DWIDTH = 32) extends vrf_axil_wr_cb #(DWIDTH);
  // CTRL 动作位（与 Doc/Reg_v_0_0.md 一致）
  localparam int CTRL_BIT_SOFT_RST = 1;
  localparam int CTRL_BIT_CLR_CNT  = 4;
  // 受 CTRL 动作影响的寄存器偏移
  localparam logic [31:0] OFF_FRAME_CNT  = 32'h08;
  localparam logic [31:0] OFF_ERR_FLAG   = 32'h0C;
  localparam logic [31:0] OFF_INT_STATUS = 32'h14;
  localparam logic [31:0] OFF_DBG_PIX    = 32'h74;
  localparam logic [31:0] OFF_DBG_LINE   = 32'h78;
  localparam logic [31:0] OFF_DBG_BEAT   = 32'h7C;

  virtual function void apply(
    ref   logic [DWIDTH-1:0]   mirror[int unsigned],
    input logic [31:0]         offset,
    input logic [DWIDTH-1:0]   data,
    input logic [DWIDTH/8-1:0] strb
  );
    bit do_softrst, do_clrcnt;
    if (!strb[0]) return;                              // 动作位在低字节，需 wstrb[0] 选通
    do_softrst = data[CTRL_BIT_SOFT_RST];
    do_clrcnt  = data[CTRL_BIT_CLR_CNT];
    if (!do_softrst && !do_clrcnt) return;

    mirror[OFF_FRAME_CNT] = '0;
    mirror[OFF_ERR_FLAG]  = '0;
    mirror[OFF_DBG_PIX]   = '0;
    mirror[OFF_DBG_LINE]  = '0;
    mirror[OFF_DBG_BEAT]  = '0;
    // SOFT_RST 连中断状态一并清除；CLR_CNT 保留 INT_STATUS
    if (do_softrst) mirror[OFF_INT_STATUS] = '0;
    // CLR_FIFO 当前 RTL 未实现，不影响任何寄存器
  endfunction
endclass

// ------------------------------ 寄存器描述 ------------------------------
class vrf_axil_reg_desc #(parameter int DWIDTH = 32);
  string             name;            // 寄存器名
  logic [31:0]       offset;          // 字节偏移
  vrf_access_e       access;          // 访问属性
  logic [DWIDTH-1:0] reset_val;       // 复位默认值
  logic [DWIDTH-1:0] selfclear_mask;  // 写后自清零位掩码
  bit                dynamic;         // 读值由硬件动态产生（模型仅做占位）

  function new(
    string             name          = "REG",
    logic [31:0]       offset        = 32'h0,
    vrf_access_e       access        = ACC_RW,
    logic [DWIDTH-1:0] reset_val     = '0,
    logic [DWIDTH-1:0] selfclear_mask= '0,
    bit                dynamic       = 0
  );
    this.name           = name;
    this.offset         = offset;
    this.access         = access;
    this.reset_val      = reset_val;
    this.selfclear_mask = selfclear_mask;
    this.dynamic        = dynamic;
  endfunction
endclass

// ------------------------------ 寄存器模型 ------------------------------
class vrf_axil_regmodel #(parameter int DWIDTH = 32);
  localparam int STRBWIDTH = DWIDTH / 8;
  typedef logic [DWIDTH-1:0]    data_t;
  typedef logic [STRBWIDTH-1:0] strb_t;
  typedef vrf_axil_reg_desc #(DWIDTH) desc_t;

  desc_t regs[$];                  // 寄存器映射表
  data_t mirror[int unsigned];     // 偏移 -> 镜像值

  // 未映射地址的预测行为（按 map 配置；默认与当前两台从端一致：返回 OKAY、读回 0）
  axi_resp_e unmap_resp  = OKAY;
  data_t     unmap_rdata = '0;

  // 写副作用回调注册表：偏移 -> 回调（由各 map 在构建时注册 DUT 专属行为）
  vrf_axil_wr_cb #(DWIDTH) special_cb[int unsigned];

  // 事件注入相关寄存器偏移（由各 map 填写，通用本体不写死任何 DUT 偏移）
  logic [31:0] evt_frame_cnt_off  = '0;
  logic [31:0] evt_err_flag_off   = '0;
  logic [31:0] evt_int_status_off = '0;

  function new();
    // 内置 map 按 32 位字定义：位宽不符时立即报错，避免按 32 位静默算错
    if (DWIDTH != 32) begin
      $fatal(1, "[VRF_AXIL] vrf_axil_regmodel：内置寄存器映射按 32 位字定义，DWIDTH=%0d 未适配（请先按位宽改写 map 再放开此断言）", DWIDTH);
    end
  endfunction

  // ------------------------------ 按字节选通的写合并（宽度按 DWIDTH 派生） ------------------------------
  static function data_t wstrb_apply(data_t old_val, data_t new_val, strb_t strb);
    data_t tmp;
    tmp = old_val;
    for (int i = 0; i < STRBWIDTH; i++) begin
      if (strb[i]) tmp[i*8 +: 8] = new_val[i*8 +: 8];
    end
    return tmp;
  endfunction

  // ------------------------------ 映射构建 ------------------------------
  // 按名字构建寄存器映射：名字与实现的对应关系收敛在本文件内（用例经 cfg.reg_map 选择），
  // 库本体其它文件不含任何 DUT 名
  function void build_map(string map_name);
    case (map_name)
      "DVP2AXI":   build_dvp2axi_stream_map();
      "REF_SLAVE": build_ref_slave_map();
      default: $fatal(1, "[VRF_AXIL] 未知的寄存器映射名 '%s'（可选：DVP2AXI / REF_SLAVE）", map_name);
    endcase
  endfunction

  function void add_reg(
    string        name,
    logic [31:0]  offset,
    vrf_access_e  access         = ACC_RW,
    data_t        reset_val      = '0,
    data_t        selfclear_mask = '0,
    bit           dynamic        = 0
  );
    desc_t d;
    d = new(name, offset, access, reset_val, selfclear_mask, dynamic);
    regs.push_back(d);
    mirror[offset] = reset_val;
  endfunction

  // 注册某偏移的写副作用回调（DUT 专属行为由 map 提供）
  function void reg_special_cb(logic [31:0] offset, vrf_axil_wr_cb #(DWIDTH) cb);
    if (cb == null) return;
    special_cb[offset] = cb;
  endfunction

  // DVP2axi_stream 寄存器映射（与 Doc/Reg_v_0_0.md 对齐）
  function void build_dvp2axi_stream_map();
    vrf_axil_dvp2axi_ctrl_cb #(DWIDTH) ctrl_cb;

    regs.delete();
    mirror.delete();
    special_cb.delete();

    // 未映射地址：RTL 当前实现返回 OKAY、读回 0
    unmap_resp  = OKAY;
    unmap_rdata = '0;

    // 事件注入涉及的寄存器偏移
    evt_frame_cnt_off  = 32'h08;
    evt_err_flag_off   = 32'h0C;
    evt_int_status_off = 32'h14;

    add_reg("CTRL",          32'h00, ACC_RW,  32'h0000_0000, 32'h0000_0032);
    add_reg("STATUS",        32'h04, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("FRAME_CNT",     32'h08, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("ERR_FLAG",      32'h0C, ACC_W1C, 32'h0000_0000, 32'h0,        1);
    add_reg("INT_EN",        32'h10, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("INT_STATUS",    32'h14, ACC_W1C, 32'h0000_0000, 32'h0,        1);
    add_reg("VERSION",       32'h18, ACC_RO,  32'h0001_0000);
    add_reg("DVP_CTRL",      32'h20, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("IMG_WIDTH",     32'h24, ACC_RW,  32'h0000_0780, 32'h0);
    add_reg("IMG_HEIGHT",    32'h28, ACC_RW,  32'h0000_0438, 32'h0);
    add_reg("LINE_TOTAL",    32'h2C, ACC_RW,  32'h0000_0800, 32'h0);
    add_reg("FRAME_TOTAL",   32'h30, ACC_RW,  32'h0000_0450, 32'h0);
    add_reg("AXIS_CTRL",     32'h40, ACC_RW,  32'h0000_0001, 32'h0);
    add_reg("AXIS_TID",      32'h44, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("AXIS_TDEST",    32'h48, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("AXIS_TUSER",    32'h4C, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("FIFO_STATUS",   32'h60, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("FIFO_THRESHOLD",32'h64, ACC_RW,  32'h0000_0010, 32'h0);
    add_reg("DBG_STATE",     32'h70, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("DBG_PIX_CNT",   32'h74, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("DBG_LINE_CNT",  32'h78, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("DBG_BEAT_CNT",  32'h7C, ACC_RO,  32'h0000_0000, 32'h0,        1);
    add_reg("SCRATCH",       32'h80, ACC_RW,  32'h0000_0000, 32'h0);

    // CTRL 的 SOFT_RST / CLR_CNT 副作用：按偏移注册回调，通用本体不含这些偏移
    ctrl_cb = new();
    reg_special_cb(32'h00, ctrl_cb);
  endfunction

  // 从机参考模型映射（供库自测 demo 使用，与被测从机模型保持一致）
  function void build_ref_slave_map();
    regs.delete();
    mirror.delete();
    special_cb.delete();

    unmap_resp  = OKAY;
    unmap_rdata = '0;

    add_reg("REF_CTL",  32'h00, ACC_RW,  32'h0000_0000, 32'h0000_0002);
    add_reg("REF_STAT", 32'h04, ACC_RO,  32'h0000_0000);
    add_reg("REF_DATA", 32'h08, ACC_RW,  32'h1234_5678, 32'h0);
    add_reg("REF_INT",  32'h0C, ACC_W1C, 32'h0000_0000, 32'h0);
    add_reg("REF_MASK", 32'h10, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("REF_VER",  32'h18, ACC_RO,  32'h0001_0000);
    add_reg("REF_SCR",  32'h80, ACC_RW,  32'h0000_0000, 32'h0);
  endfunction

  // ------------------------------ 查询 ------------------------------
  function desc_t find(logic [31:0] offset);
    foreach (regs[i]) begin
      if (regs[i].offset == offset) return regs[i];
    end
    return null;
  endfunction

  function bit is_mapped(logic [31:0] offset);
    return (find(offset) != null);
  endfunction

  function bit is_ro(logic [31:0] offset);
    desc_t d;
    d = find(offset);
    return (d != null) && (d.access == ACC_RO);
  endfunction

  function void reset();
    foreach (regs[i]) mirror[regs[i].offset] = regs[i].reset_val;
  endfunction

  function void set_mirror(logic [31:0] offset, data_t val);
    mirror[offset] = val;
  endfunction

  function data_t get_mirror(logic [31:0] offset);
    if (!mirror.exists(offset)) return '0;
    return mirror[offset];
  endfunction

  // ------------------------------ 预测 ------------------------------
  // 写预测：仅依据总线写事务更新镜像，未映射地址与只读寄存器写被忽略
  function void predict_write(logic [31:0] offset, data_t data, strb_t strb);
    desc_t d;
    data_t nv;
    data_t clr;

    d = find(offset);
    if (d == null) return;                 // 未映射地址：写被忽略

    case (d.access)
      ACC_RO: return;                      // 只读寄存器：写被忽略
      ACC_W1C: begin
        // 写 1 按位清除（字节选通限定）
        clr = wstrb_apply('0, data, strb);
        mirror[offset] = mirror[offset] & ~clr;
      end
      default: begin
        // 普通读写：按字节选通合并，并清除自清零位
        nv = wstrb_apply(mirror[offset], data, strb);
        nv = nv & ~d.selfclear_mask;
        mirror[offset] = nv;
      end
    endcase

    // 按偏移注册的副作用回调（DUT 专属行为，如 CTRL 的 SOFT_RST/CLR_CNT）
    if ((d.access != ACC_RO) && special_cb.exists(offset)) begin
      special_cb[offset].apply(mirror, offset, data, strb);
    end
  endfunction

  // 读预测：返回镜像值，未映射地址按 map 配置返回
  function data_t predict_read(logic [31:0] offset);
    if (find(offset) == null) return unmap_rdata;
    return get_mirror(offset);
  endfunction

  // 响应预测：已映射地址返回 OKAY，未映射地址按 map 配置返回
  function axi_resp_e predict_resp(axil_dir_e dir, logic [31:0] offset);
    if (find(offset) == null) return unmap_resp;
    return OKAY;
  endfunction

  // ------------------------------ 内部事件注入接口 ------------------------------
  // 定向用例注入内部事件后调用以下接口同步模型，使随后的回读事务仍可由模型自动预测。
  // 注意：事件到寄存器/位的映射语义属各 DUT 所有，偏移由 map 填写（evt_*_off）。
  function void event_frame_done();
    mirror[evt_frame_cnt_off] = get_mirror(evt_frame_cnt_off) + 1;
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off) | 32'h0000_0001);
  endfunction

  function void event_fifo_overflow();
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)   | 32'h0000_0001);
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off) | 32'h0000_0002);
  endfunction

  function void event_line_err();
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)   | 32'h0000_0002);
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off) | 32'h0000_0004);
  endfunction

  function void event_frame_err();
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)   | 32'h0000_0004);
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off) | 32'h0000_0008);
  endfunction

  function void event_axis_err();
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)   | 32'h0000_0008);
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off) | 32'h0000_0010);
  endfunction

  function void event_cfg_err();
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)   | 32'h0000_0010);
  endfunction
endclass

// 库内部使用的默认特化别名（按 32 位字映射特化）
typedef vrf_axil_regmodel #(VRF_DW) vrf_axil_regmodel_t;
