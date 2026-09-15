// =============================================================================
// 轻量寄存器模型（RAL-like）
//   - 寄存器描述：名称、偏移、访问属性、复位值、自清零掩码、特殊行为
//   - 镜像值：按偏移索引，随总线写事务更新
//   - 预测：写预测（含 wstrb 字节使能、W1C、自清零、CTRL 副作用）
//           读预测（返回镜像值，未映射地址返回 0）
//   - 事件注入接口：供定向用例在层次化 force 内部事件后同步模型
//
// 说明：本模型不依赖仿真器 RAL，仅用关联数组与队列实现最小可用子集，
//       便于跨工具复用；寄存器映射由 build_*_map() 按 DUT 组织。
// =============================================================================

// ------------------------------ 按字节选通的写合并 ------------------------------
function automatic logic [31:0] vrf_axil_wstrb_apply(
  input logic [31:0] old_val,
  input logic [31:0] new_val,
  input logic [3:0]  strb
);
  logic [31:0] tmp;
  tmp = old_val;
  for (int i = 0; i < 4; i++) begin
    if (strb[i]) tmp[i*8 +: 8] = new_val[i*8 +: 8];
  end
  return tmp;
endfunction

// ------------------------------ 寄存器描述 ------------------------------
class vrf_axil_reg_desc;
  string        name;            // 寄存器名
  logic [31:0]  offset;          // 字节偏移
  vrf_access_e  access;          // 访问属性
  logic [31:0]  reset_val;       // 复位默认值
  logic [31:0]  selfclear_mask;  // 写后自清零位掩码
  vrf_special_e special;         // 特殊行为（如 CTRL 的 SOFT_RST/CLR_CNT 副作用）
  bit           dynamic;         // 读值由硬件动态产生（模型仅做占位）

  function new(
    string        name        = "REG",
    logic [31:0]  offset      = 32'h0,
    vrf_access_e  access      = ACC_RW,
    logic [31:0]  reset_val   = 32'h0,
    logic [31:0]  selfclear_mask = 32'h0,
    vrf_special_e special     = SP_NONE,
    bit           dynamic     = 0
  );
    this.name           = name;
    this.offset         = offset;
    this.access         = access;
    this.reset_val      = reset_val;
    this.selfclear_mask = selfclear_mask;
    this.special        = special;
    this.dynamic        = dynamic;
  endfunction
endclass

// ------------------------------ 寄存器模型 ------------------------------
class vrf_axil_regmodel;
  vrf_axil_reg_desc regs[$];                  // 寄存器映射表
  logic [31:0]      mirror[int unsigned];     // 偏移 -> 镜像值

  // CTRL 副作用涉及的寄存器偏移（可按 DUT 重设）
  logic [31:0] off_ctrl       = 32'h00;
  logic [31:0] off_frame_cnt  = 32'h08;
  logic [31:0] off_err_flag   = 32'h0C;
  logic [31:0] off_int_status = 32'h14;
  logic [31:0] off_dbg_pix    = 32'h74;
  logic [31:0] off_dbg_line   = 32'h78;
  logic [31:0] off_dbg_beat   = 32'h7C;
  bit          ctrl_side_effect = 1;          // 是否启用 SOFT_RST/CLR_CNT 副作用

  // ------------------------------ 映射构建 ------------------------------
  function void add_reg(
    string        name,
    logic [31:0]  offset,
    vrf_access_e  access        = ACC_RW,
    logic [31:0]  reset_val     = 32'h0,
    logic [31:0]  selfclear_mask= 32'h0,
    vrf_special_e special       = SP_NONE,
    bit           dynamic       = 0
  );
    vrf_axil_reg_desc d;
    d = new(name, offset, access, reset_val, selfclear_mask, special, dynamic);
    regs.push_back(d);
    mirror[offset] = reset_val;
  endfunction

  // DVP2axi_stream 寄存器映射（与 Doc/Reg_v_0_0.md 对齐）
  function void build_dvp2axi_stream_map();
    regs.delete();
    mirror.delete();
    add_reg("CTRL",          32'h00, ACC_RW,  32'h0000_0000, 32'h0000_0032, SP_CTRL);
    add_reg("STATUS",        32'h04, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("FRAME_CNT",     32'h08, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("ERR_FLAG",      32'h0C, ACC_W1C, 32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("INT_EN",        32'h10, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("INT_STATUS",    32'h14, ACC_W1C, 32'h0000_0000, 32'h0,         SP_NONE, 1);
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
    add_reg("FIFO_STATUS",   32'h60, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("FIFO_THRESHOLD",32'h64, ACC_RW,  32'h0000_0010, 32'h0);
    add_reg("DBG_STATE",     32'h70, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("DBG_PIX_CNT",   32'h74, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("DBG_LINE_CNT",  32'h78, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("DBG_BEAT_CNT",  32'h7C, ACC_RO,  32'h0000_0000, 32'h0,         SP_NONE, 1);
    add_reg("SCRATCH",       32'h80, ACC_RW,  32'h0000_0000, 32'h0);
  endfunction

  // 从机参考模型映射（供库自测 demo 使用，与被测从机模型保持一致）
  function void build_ref_slave_map();
    regs.delete();
    mirror.delete();
    add_reg("REF_CTL",  32'h00, ACC_RW,  32'h0000_0000, 32'h0000_0002);
    add_reg("REF_STAT", 32'h04, ACC_RO,  32'h0000_0000);
    add_reg("REF_DATA", 32'h08, ACC_RW,  32'h1234_5678, 32'h0);
    add_reg("REF_INT",  32'h0C, ACC_W1C, 32'h0000_0000, 32'h0);
    add_reg("REF_MASK", 32'h10, ACC_RW,  32'h0000_0000, 32'h0);
    add_reg("REF_VER",  32'h18, ACC_RO,  32'h0001_0000);
    add_reg("REF_SCR",  32'h80, ACC_RW,  32'h0000_0000, 32'h0);
  endfunction

  // ------------------------------ 查询 ------------------------------
  function vrf_axil_reg_desc find(logic [31:0] offset);
    foreach (regs[i]) begin
      if (regs[i].offset == offset) return regs[i];
    end
    return null;
  endfunction

  function bit is_mapped(logic [31:0] offset);
    return (find(offset) != null);
  endfunction

  function bit is_ro(logic [31:0] offset);
    vrf_axil_reg_desc d;
    d = find(offset);
    return (d != null) && (d.access == ACC_RO);
  endfunction

  function void reset();
    foreach (regs[i]) mirror[regs[i].offset] = regs[i].reset_val;
  endfunction

  function void set_mirror(logic [31:0] offset, logic [31:0] val);
    mirror[offset] = val;
  endfunction

  function logic [31:0] get_mirror(logic [31:0] offset);
    if (!mirror.exists(offset)) return 32'h0;
    return mirror[offset];
  endfunction

  // ------------------------------ 预测 ------------------------------
  // 写预测：仅依据总线写事务更新镜像，未映射地址与只读寄存器写被忽略
  function void predict_write(logic [31:0] offset, logic [31:0] data, logic [3:0] strb);
    vrf_axil_reg_desc d;
    logic [31:0] nv;
    logic [31:0] clr;

    d = find(offset);
    if (d == null) return;                 // 未映射地址：写被忽略

    case (d.access)
      ACC_RO: return;                      // 只读寄存器：写被忽略
      ACC_W1C: begin
        // 写 1 按位清除（字节选通限定）
        clr = vrf_axil_wstrb_apply(32'h0, data, strb);
        mirror[offset] = mirror[offset] & ~clr;
      end
      default: begin
        // 普通读写：按字节选通合并，并清除自清零位
        nv = vrf_axil_wstrb_apply(mirror[offset], data, strb);
        nv = nv & ~d.selfclear_mask;
        mirror[offset] = nv;
      end
    endcase

    // CTRL 特殊副作用：SOFT_RST / CLR_FIFO / CLR_CNT
    if (d.special == SP_CTRL && ctrl_side_effect) begin
      if (data[1] && strb[0]) begin        // SOFT_RST：清计数/错误/中断/调试计数
        mirror[off_frame_cnt]  = 32'h0;
        mirror[off_err_flag]   = 32'h0;
        mirror[off_int_status] = 32'h0;
        mirror[off_dbg_pix]    = 32'h0;
        mirror[off_dbg_line]   = 32'h0;
        mirror[off_dbg_beat]   = 32'h0;
      end
      if (data[4] && strb[0]) begin        // CLR_CNT：清帧计数/错误/调试计数
        mirror[off_frame_cnt]  = 32'h0;
        mirror[off_err_flag]   = 32'h0;
        mirror[off_dbg_pix]    = 32'h0;
        mirror[off_dbg_line]   = 32'h0;
        mirror[off_dbg_beat]   = 32'h0;
      end
      // CLR_FIFO 当前 RTL 未实现，不影响任何寄存器
    end
  endfunction

  // 读预测：返回镜像值，未映射地址返回 0
  function logic [31:0] predict_read(logic [31:0] offset);
    if (find(offset) == null) return 32'h0;
    return get_mirror(offset);
  endfunction

  // 响应预测：当前 DUT 未映射地址同样返回 OKAY
  function axi_resp_e predict_resp(axil_dir_e dir, logic [31:0] offset);
    return OKAY;
  endfunction

  // ------------------------------ 内部事件注入接口 ------------------------------
  // 定向用例通过层次化 force 注入内部事件后，调用以下接口同步模型，
  // 使随后的回读事务仍可由模型自动预测。
  function void event_frame_done();
    mirror[off_frame_cnt] = get_mirror(off_frame_cnt) + 1;
    set_mirror(off_int_status, get_mirror(off_int_status) | 32'h0000_0001);
  endfunction

  function void event_fifo_overflow();
    set_mirror(off_err_flag,   get_mirror(off_err_flag)   | 32'h0000_0001);
    set_mirror(off_int_status, get_mirror(off_int_status) | 32'h0000_0002);
  endfunction

  function void event_line_err();
    set_mirror(off_err_flag,   get_mirror(off_err_flag)   | 32'h0000_0002);
    set_mirror(off_int_status, get_mirror(off_int_status) | 32'h0000_0004);
  endfunction

  function void event_frame_err();
    set_mirror(off_err_flag,   get_mirror(off_err_flag)   | 32'h0000_0004);
    set_mirror(off_int_status, get_mirror(off_int_status) | 32'h0000_0008);
  endfunction

  function void event_axis_err();
    set_mirror(off_err_flag,   get_mirror(off_err_flag)   | 32'h0000_0008);
    set_mirror(off_int_status, get_mirror(off_int_status) | 32'h0000_0010);
  endfunction

  function void event_cfg_err();
    set_mirror(off_err_flag,   get_mirror(off_err_flag)   | 32'h0000_0010);
  endfunction
endclass
