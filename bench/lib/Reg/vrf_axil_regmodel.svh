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

// ------------------------------ 读预测回调 ------------------------------
// 按偏移注册：动态 RO 寄存器的读值由硬件产生，模型按「空闲稳态」给出期望值。
// 回调直接读写镜像关联数组，因此不需要依赖模型类型，也不会把 DUT 偏移带进通用本体。
// 另提供两个通用通知钩子（默认空实现），供 map 侧跟踪「配置是否已提交」：
//   on_group_write()：有配置组写入发生（配置可能尚未生效）
//   on_commit()     ：配置已提交（帧边界已生效 / 复位后状态确定）
class vrf_axil_rd_cb #(parameter int DWIDTH = 32);
  virtual function logic [DWIDTH-1:0] apply(
    ref   logic [DWIDTH-1:0]   mirror[int unsigned],
    input logic [31:0]         offset
  );
    return mirror.exists(offset) ? mirror[offset] : '0;
  endfunction

  virtual function void on_group_write();
    // 默认无动作
  endfunction

  virtual function void on_commit();
    // 默认无动作
  endfunction
endclass

// DVP2axi_stream 的动态 RO 读预测实现（仅该 map 注册使用）
//   数据通路落地后 STATUS/FIFO_STATUS 由硬件实时产生，复位后空闲稳态为：
//     STATUS      = 0x0000_0010            —— FIFO_EMPTY=1（FIFO 已实现且复位后为空）
//                                            其余位 0；PVREF_POL=1（低有效）时 DVP 输入
//                                            静态 0 会被判为「帧有效」，故 FRAME_VALID=1
//                                            [6]=CFG_PENDING：有配置写入尚未在帧边界提交
//     FIFO_STATUS = 0x0002_0000            —— EMPTY=1、LEVEL=0、FULL=0、ALMOST_FULL=0、
//                                            OVERFLOW/UNDERFLOW=0
//   说明：仅表征「空闲稳态」；数据通路运行期间的实时值需由用例自行断言（set_mirror 覆盖，
//         非 0 镜像优先）或关闭比对。
class vrf_axil_dvp2axi_dyn_ro_rd_cb #(parameter int DWIDTH = 32) extends vrf_axil_rd_cb #(DWIDTH);
  localparam logic [31:0] OFF_STATUS      = 32'h04;
  localparam logic [31:0] OFF_FIFO_STATUS = 32'h60;
  localparam logic [31:0] OFF_DVP_CTRL    = 32'h20;
  localparam logic [31:0] OFF_FIFO_THRESH = 32'h64;
  localparam int          DVP_BIT_PVREF_POL = 1;
  localparam int          STATUS_BIT_CFG_PENDING = 6;

  bit cfg_pending = 1'b0;      // 1 = 有配置写入尚未在帧边界提交（由分组写回调置位、on_commit 清除）

  virtual function void on_group_write();
    cfg_pending = 1'b1;
  endfunction

  virtual function void on_commit();
    cfg_pending = 1'b0;
  endfunction

  virtual function logic [DWIDTH-1:0] apply(
    ref   logic [DWIDTH-1:0]   mirror[int unsigned],
    input logic [31:0]         offset
  );
    logic [DWIDTH-1:0] st;
    logic [DWIDTH-1:0] dvp;
    // 用例可用 set_mirror() 显式置入期望值（非 0 时优先），以便断言非空闲稳态
    // （如数据通路运行期间/溢出后的状态寄存器值）
    if (offset == OFF_FIFO_STATUS) begin
      return (mirror.exists(offset) && (mirror[offset] != '0)) ? mirror[offset]
                                                                : 32'h0002_0000;
    end
    if (offset != OFF_STATUS) return mirror.exists(offset) ? mirror[offset] : '0;
    if (mirror.exists(offset) && (mirror[offset] != '0)) return mirror[offset];

    st  = 32'h0000_0010;                                       // FIFO_EMPTY=1
    dvp = mirror.exists(OFF_DVP_CTRL) ? mirror[OFF_DVP_CTRL] : '0;
    if (dvp[DVP_BIT_PVREF_POL]) st[1] = 1'b1;                  // FRAME_VALID：低有效 + 静态 0 输入
    if (cfg_pending)            st[STATUS_BIT_CFG_PENDING] = 1'b1;
    return st;
  endfunction

  // 说明：ALMOST_FULL（FIFO_STATUS[20]）在空闲稳态恒为 0（水位 0 < 阈值），
  //       故此处无需参与推算；用例断言该位时用 set_mirror() 覆盖。
endclass

// DVP2axi_stream 的 CTRL 副作用实现（仅该 map 注册使用）
//   声明位置须在 dyn_ro_rd_cb 之后（owner 字段引用该类型；SystemVerilog 不允许前向引用类）
//   职责合并说明：CTRL 同属「配置提交组」——任何 CTRL 写入都要置「配置在途」，
//   而同一偏移只能注册一个写回调，故把「分组写通知」并入本回调，避免互相覆盖导致副作用丢失。
class vrf_axil_dvp2axi_ctrl_cb #(parameter int DWIDTH = 32) extends vrf_axil_wr_cb #(DWIDTH);
  // CTRL 动作位（与 Doc/Reg_v_0_0.md 一致）
  localparam int CTRL_BIT_SOFT_RST = 1;
  localparam int CTRL_BIT_CLR_CNT  = 4;
  localparam int CTRL_BIT_CLR_FIFO = 5;
  // 受 CTRL 动作影响的寄存器偏移
  localparam logic [31:0] OFF_FRAME_CNT   = 32'h08;
  localparam logic [31:0] OFF_ERR_FLAG    = 32'h0C;
  localparam logic [31:0] OFF_INT_STATUS  = 32'h14;
  localparam logic [31:0] OFF_FIFO_STATUS = 32'h60;
  localparam logic [31:0] OFF_DBG_PIX     = 32'h74;
  localparam logic [31:0] OFF_DBG_LINE    = 32'h78;
  localparam logic [31:0] OFF_DBG_BEAT    = 32'h7C;

  // 「配置在途」跟踪所有者（由 map 在注册时注入）
  vrf_axil_dvp2axi_dyn_ro_rd_cb #(DWIDTH) owner;

  virtual function void apply(
    ref   logic [DWIDTH-1:0]   mirror[int unsigned],
    input logic [31:0]         offset,
    input logic [DWIDTH-1:0]   data,
    input logic [DWIDTH/8-1:0] strb
  );
    bit do_softrst, do_clrcnt, do_clrfifo;
    // CTRL 属配置提交组：任何写入都置「配置在途」
    if (owner != null) owner.on_group_write();
    if (!strb[0]) return;                              // 动作位在低字节，需 wstrb[0] 选通
    do_softrst = data[CTRL_BIT_SOFT_RST];
    do_clrcnt  = data[CTRL_BIT_CLR_CNT];
    do_clrfifo = data[CTRL_BIT_CLR_FIFO];

    if (do_softrst || do_clrcnt) begin
      mirror[OFF_FRAME_CNT] = '0;
      mirror[OFF_ERR_FLAG]  = '0;
      mirror[OFF_DBG_PIX]   = '0;
      mirror[OFF_DBG_LINE]  = '0;
      mirror[OFF_DBG_BEAT]  = '0;
      // SOFT_RST 连中断状态一并清除；CLR_CNT 保留 INT_STATUS
      if (do_softrst) mirror[OFF_INT_STATUS] = '0;
    end
    // CLR_FIFO 与 SOFT_RST 都会冲刷 FIFO，并把 FIFO_STATUS 粘滞位清零（回到空闲稳态）
    if (do_softrst || do_clrfifo) mirror[OFF_FIFO_STATUS] = '0;
  endfunction
endclass

// DVP2axi_stream 的配置组写回调：组内无副作用的寄存器写入只置「配置在途」
//   （CTRL 因带副作用而由上面的 ctrl_cb 一并承担同一职责）
class vrf_axil_dvp2axi_group_wr_cb #(parameter int DWIDTH = 32) extends vrf_axil_wr_cb #(DWIDTH);
  vrf_axil_dvp2axi_dyn_ro_rd_cb #(DWIDTH) owner;

  virtual function void apply(
    ref   logic [DWIDTH-1:0]   mirror[int unsigned],
    input logic [31:0]         offset,
    input logic [DWIDTH-1:0]   data,
    input logic [DWIDTH/8-1:0] strb
  );
    if (owner != null) owner.on_group_write();
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

  // 读预测回调注册表：偏移 -> 回调（动态 RO 寄存器的空闲稳态期望值，由各 map 注册）
  vrf_axil_rd_cb #(DWIDTH) rd_cb[int unsigned];

  // 事件注入相关寄存器偏移（由各 map 填写，通用本体不写死任何 DUT 偏移）
  logic [31:0] evt_frame_cnt_off  = '0;
  logic [31:0] evt_err_flag_off   = '0;
  logic [31:0] evt_int_status_off = '0;
  logic [31:0] evt_int_en_off     = '0;   // 新增边界错误位的 INT_EN 门控来源（0 = 不做门控）

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

  // 注册某偏移的读预测回调（动态 RO 寄存器的期望值由 map 提供）
  function void reg_rd_cb(logic [31:0] offset, vrf_axil_rd_cb #(DWIDTH) cb);
    if (cb == null) return;
    rd_cb[offset] = cb;
  endfunction

  // 通知全部读预测回调：配置已提交（帧边界生效 / 复位后状态确定）
  //   用例在「驱动足够帧边界使配置生效」后调用，使动态 RO 的 CFG_PENDING 位回到 0
  function void notify_commit();
    foreach (rd_cb[i]) rd_cb[i].on_commit();
  endfunction

  // DVP2axi_stream 寄存器映射（与 Doc/Reg_v_0_0.md 对齐）
  function void build_dvp2axi_stream_map();
    vrf_axil_dvp2axi_ctrl_cb #(DWIDTH) ctrl_cb;
    vrf_axil_dvp2axi_dyn_ro_rd_cb #(DWIDTH) dyn_ro_cb;
    vrf_axil_dvp2axi_group_wr_cb #(DWIDTH) grp_wr_cb;

    regs.delete();
    mirror.delete();
    special_cb.delete();
    rd_cb.delete();

    // 未映射地址：RTL 当前实现返回 OKAY、读回 0
    unmap_resp  = OKAY;
    unmap_rdata = '0;

    // 事件注入涉及的寄存器偏移
    evt_frame_cnt_off  = 32'h08;
    evt_err_flag_off   = 32'h0C;
    evt_int_status_off = 32'h14;
    evt_int_en_off     = 32'h10;

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

    // 动态 RO 寄存器（STATUS / FIFO_STATUS）的读预测：空闲稳态期望值由 map 提供
    dyn_ro_cb = new();
    reg_rd_cb(32'h04, dyn_ro_cb);
    reg_rd_cb(32'h60, dyn_ro_cb);

    // CTRL 的 SOFT_RST / CLR_CNT / CLR_FIFO 副作用：按偏移注册回调，通用本体不含这些偏移
    //   同时把 dyn_ro_cb 注入为 owner：CTRL 写入也要置「配置在途」（STATUS.CFG_PENDING）
    ctrl_cb = new();
    ctrl_cb.owner = dyn_ro_cb;
    reg_special_cb(32'h00, ctrl_cb);

    // 配置组（pclk 帧边界提交组）其余寄存器的写入回调：置「配置在途」标志
    //   组内偏移：DVP_CTRL/IMG_WIDTH/IMG_HEIGHT/LINE_TOTAL/FRAME_TOTAL/AXIS_CTRL/FIFO_THRESHOLD
    //   （CTRL 已在上面与副作用合并注册，此处不再重复注册以免覆盖）
    grp_wr_cb = new();
    grp_wr_cb.owner = dyn_ro_cb;
    reg_special_cb(32'h20, grp_wr_cb);
    reg_special_cb(32'h24, grp_wr_cb);
    reg_special_cb(32'h28, grp_wr_cb);
    reg_special_cb(32'h2C, grp_wr_cb);
    reg_special_cb(32'h30, grp_wr_cb);
    reg_special_cb(32'h40, grp_wr_cb);
    reg_special_cb(32'h64, grp_wr_cb);
  endfunction

  // 从机参考模型映射（供库自测 demo 使用，与被测从机模型保持一致）
  function void build_ref_slave_map();
    regs.delete();
    mirror.delete();
    special_cb.delete();
    rd_cb.delete();

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
    notify_commit();          // 复位后配置状态确定（CFG_PENDING 等动态位回到空闲稳态）
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

  // 读预测：返回镜像值；动态 RO 寄存器（若地图注册了读回调）返回回调给出的空闲稳态值；
  // 未映射地址按 map 配置返回
  function data_t predict_read(logic [31:0] offset);
    if (find(offset) == null) return unmap_rdata;
    if (rd_cb.exists(offset)) return rd_cb[offset].apply(mirror, offset);
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

  // ---- 行/帧边界事件（ERR_FLAG[5:8]、INT_STATUS[5:8]）----
  //   位映射（见 Doc/Reg_v_0_0.md §3.4/§3.6）：
  //     [5]=LINE_SHORT [6]=LINE_LONG [7]=FRAME_SHORT [8]=FRAME_LONG
  //   ERR_FLAG 恒置位（粘滞）；INT_STATUS 由 INT_EN[6:9] 门控，
  //   同时 ERR_FLAG/INT_STATUS 的汇总位 [1]/[2]（LINE_ERR/FRAME_ERR）一并置位。
  localparam logic [31:0] EFS = 32'h0000_0020;   // ERR_FLAG[5] / INT_STATUS[5] 起  4 位
  localparam logic [31:0] IEN = 32'h0000_03C0;   // INT_EN[9:6] 对应 4 位

  function bit int_gate(int sel);
    // 无 INT_EN 映射（其它 DUT）时不门控；INT_EN[9:6] 与 INT_STATUS[8:5] 一一对应：
    //   INT_STATUS[5] <- INT_EN[6] ... INT_STATUS[8] <- INT_EN[9]
    logic [31:0] v;
    if (evt_int_en_off == '0) return 1'b1;
    if (!mirror.exists(evt_int_en_off)) return 1'b1;
    v = (get_mirror(evt_int_en_off) & IEN) >> 6;
    return v[sel];
  endfunction

  // sel：0=LINE_SHORT 1=LINE_LONG 2=FRAME_SHORT 3=FRAME_LONG
  //   err_sum_bit / int_sum_bit：ERR_FLAG 与 INT_STATUS 各自的汇总位（两者位号不同：
  //   ERR_FLAG[1]=LINE_ERR、[2]=FRAME_ERR；INT_STATUS[2]=LINE_ERR、[3]=FRAME_ERR）。
  //   汇总位与 ERR_FLAG 明细位恒置位（不受 INT_EN 门控，与 RTL 一致）；
  //   INT_STATUS 明细位 [5:8] 由 INT_EN[6:9] 门控。
  function void event_boundary(int sel, int err_sum_bit, int int_sum_bit);
    logic [31:0] bit_mask;
    bit_mask = EFS << sel;
    set_mirror(evt_err_flag_off,   get_mirror(evt_err_flag_off)
                                   | bit_mask | (32'h1 << err_sum_bit));
    set_mirror(evt_int_status_off, get_mirror(evt_int_status_off)
                                   | (32'h1 << int_sum_bit)
                                   | (int_gate(sel) ? bit_mask : 32'h0));
  endfunction

  function void event_line_short();  event_boundary(0, 1, 2); endfunction
  function void event_line_long();   event_boundary(1, 1, 2); endfunction
  function void event_frame_short(); event_boundary(2, 2, 3); endfunction
  function void event_frame_long();  event_boundary(3, 2, 3); endfunction
endclass

// 库内部使用的默认特化别名（按 32 位字映射特化）
typedef vrf_axil_regmodel #(VRF_DW) vrf_axil_regmodel_t;
