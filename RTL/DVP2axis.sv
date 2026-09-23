`timescale 1ns/1ps
`include "IF/if_axil.sv"
`include "IF/if_axis.sv"

// =============================================================================
// DVP2axis : DVP 图像输入 -> AXI-Stream 输出，附 AXI4-Lite 寄存器配置块
//
//   接口划分（信号与方向见 RTL/IF/ 下的接口声明）：
//     配置通路 : AXI4-Lite 从机  slv_if_axil.slv   —— 由 CPU/主机配置本模块
//     数据通路 : AXI-Stream 主机 mst_if_axis.mst   —— 输出图像流
//     图像输入 : pclk 域离散信号（pdin/pvref/phref）
//
//   数据通路结构（参考 RTL/Ref/DVP_AXI_v_2_0.v 的采集/合并/打包/双 FIFO 结构，
//   但输出改为 AXI-Stream，且分辨率一律走 AXI-Lite 影子配置）：
//     pclk 域：输入 4 级同步链 -> 像素合并（按 PIX_FMT 决定每像素字节数）
//              -> 行/帧边界判定（LINE_SHORT/LONG、FRAME_SHORT/LONG）
//              -> beat 打包（按 AXIS_CTRL 的 PACK_EN/PACK_MODE/BYTE_SWAP/TLAST_MODE）
//     aclk 域：异步 FIFO 读侧 -> AXI-Stream 输出（tvalid/tdata/tstrb/tkeep/tlast）
//
//   地址口径（见 Doc/Reg_v_0_0.md）：
//     首像素位于 beat 低字节（小端）；AXIS_CTRL.BYTE_SWAP=1 时整 beat 字节反转（大端）；
//     行长/帧长恒等于 IMG_WIDTH/IMG_HEIGHT —— 短的按实际长度结束、长的丢弃多余部分。
//
//   时钟域：
//     aclk 域 —— AXI4-Lite 寄存器块、AXI-Stream 输出、异步 FIFO 读侧
//     pclk 域 —— DVP 采集、像素合并、beat 打包、异步 FIFO 写侧
//     跨域     —— 见第 7、8、12.5 节：配置参数 aclk->pclk（格雷码 + 2 级同步 +
//                 整组 4 相握手 + 帧边界提交 + ack 超时）、状态/计数 pclk->aclk
//                 （格雷码 + 2 级同步）、事件脉冲 pclk->aclk（翻转位 + 2 级同步 +
//                 边沿检测）
//
//   寄存器行为继承 RTL/DVP2axi_stream.v（映射见 Doc/Reg_v_0_0.md）：
//     复位默认值 / wstrb 字节选通 / W1C / CTRL 自清零 / 粘滞事件 / ID 恒 0 / resp 恒 OKAY
//
//   注意：接口位宽由外部接口实例决定（接口参数不能在端口处重载），
//         模块的 AXI_LITE_* / AXI_STREAM_* 参数必须与接口实例保持一致。
//   说明：DVP 输入为字节串行（DVP_DWIDTH=8）；其他取值在 elaboration 期报错。
// =============================================================================
module DVP2axis #(
    // ---- DVP 输入 ----
    parameter int DVP_DWIDTH  = 8,
    parameter int PIX_WIDTH   = 16,
    // ---- AXI-Stream 输出（须与 mst_if_axis 实例的 DWIDTH 一致）----
    parameter int AXI_STREAM_DWIDTH      = 256,
    parameter int AXI_STREAM_TID         = 1,
    parameter int AXI_STREAM_USER_WIDTH  = 4,
    parameter int AXI_STREAM_TDEST_WIDTH = 4,
    localparam int AXI_STREAM_STRB_WIDTH = AXI_STREAM_DWIDTH / 8,
    // ---- 数据通路 ----
    parameter int FIFO_DEPTH     = 1024,   // 异步 FIFO 深度（beat，须为 2 的幂；综合前可调）
    // ---- AXI4-Lite 配置（须与 slv_if_axil 实例的参数一致）----
    parameter int AXI_LITE_DWIDTH = 32,
    parameter int AXI_LITE_AWIDTH = 32,
    parameter int AXI_ID_WIDTH    = 4,
    localparam int AXI_LITE_STRB_WIDTH = AXI_LITE_DWIDTH / 8,
    parameter logic [AXI_LITE_AWIDTH-1:0] AXI_LITE_BASE_ADDR_OFFSET = '0
)(
    input logic pclk,
    input logic prst_n,
    input logic [DVP_DWIDTH-1:0] pdin,
    input logic pvref,
    input logic phref,                  // 行有效指示：一行有效期间保持高
    // AXI4-Lite 配置接口（从机侧）
    input logic aclk,
    input logic aresetn,
    slv_if_axil.slv slv_axil,
    // AXI-Stream 输出接口（主机侧）
    mst_if_axis.mst axis_m
);

    // =====================================================================
    // 1. 寄存器偏移与位定义（见 Doc/Reg_v_0_0.md）
    // =====================================================================
    localparam logic [7:0] ADDR_CTRL         = 8'h00;
    localparam logic [7:0] ADDR_STATUS       = 8'h04;
    localparam logic [7:0] ADDR_FRAME_CNT    = 8'h08;
    localparam logic [7:0] ADDR_ERR_FLAG     = 8'h0C;
    localparam logic [7:0] ADDR_INT_EN       = 8'h10;
    localparam logic [7:0] ADDR_INT_STATUS   = 8'h14;
    localparam logic [7:0] ADDR_VERSION      = 8'h18;
    localparam logic [7:0] ADDR_DVP_CTRL     = 8'h20;
    localparam logic [7:0] ADDR_IMG_WIDTH    = 8'h24;
    localparam logic [7:0] ADDR_IMG_HEIGHT   = 8'h28;
    localparam logic [7:0] ADDR_LINE_TOTAL   = 8'h2C;
    localparam logic [7:0] ADDR_FRAME_TOTAL  = 8'h30;
    localparam logic [7:0] ADDR_AXIS_CTRL    = 8'h40;
    localparam logic [7:0] ADDR_AXIS_TID     = 8'h44;
    localparam logic [7:0] ADDR_AXIS_TDEST   = 8'h48;
    localparam logic [7:0] ADDR_AXIS_TUSER   = 8'h4C;
    localparam logic [7:0] ADDR_FIFO_STATUS  = 8'h60;
    localparam logic [7:0] ADDR_FIFO_THRESHOLD = 8'h64;
    localparam logic [7:0] ADDR_DBG_STATE    = 8'h70;
    localparam logic [7:0] ADDR_DBG_PIX_CNT  = 8'h74;
    localparam logic [7:0] ADDR_DBG_LINE_CNT = 8'h78;
    localparam logic [7:0] ADDR_DBG_BEAT_CNT = 8'h7C;
    localparam logic [7:0] ADDR_SCRATCH      = 8'h80;

    localparam logic [AXI_LITE_DWIDTH-1:0] IP_VERSION = 32'h0001_0000;

    // CTRL 位序号
    localparam int CTRL_BIT_EN           = 0;
    localparam int CTRL_BIT_SOFT_RST     = 1;   // 自清零
    localparam int CTRL_BIT_SINGLE_SHOT  = 2;
    localparam int CTRL_BIT_AUTO_RESTART = 3;
    localparam int CTRL_BIT_CLR_CNT      = 4;   // 自清零
    localparam int CTRL_BIT_CLR_FIFO     = 5;   // 自清零

    // DVP_CTRL 位序号
    localparam int DVP_BIT_PCLK_INV  = 0;
    localparam int DVP_BIT_PVREF_POL = 1;
    localparam int DVP_BIT_PHREF_POL = 2;
    localparam int DVP_BIT_PIX_FMT   = 4;   // [6:4]
    localparam int DVP_BIT_BYTE_SWAP = 7;   // 像素内高低字节交换（合并处生效）

    // AXIS_CTRL 位序号
    localparam int AXIS_BIT_PACK_EN   = 0;
    localparam int AXIS_BIT_BYTE_SWAP = 1;
    localparam int AXIS_BIT_TLAST_MODE= 2;
    localparam int AXIS_BIT_TSTRB_EN  = 3;
    localparam int AXIS_BIT_PACK_MODE = 4;   // [5:4]

    // 事件 -> 状态位 的位号定义（唯一定义处，掩码与写动作都引用）
    localparam int ERR_BIT_FIFO_OVF   = 0;   // ERR_FLAG : [0]=fifo_overflow [1]=line_err
    localparam int ERR_BIT_LINE       = 1;   //            [2]=frame_err     [3]=axis_err
    localparam int ERR_BIT_FRAME      = 2;   //            [4]=cfg_err       [5]=line_short
    localparam int ERR_BIT_AXIS       = 3;   //            [6]=line_long     [7]=frame_short
    localparam int ERR_BIT_CFG        = 4;   //            [8]=frame_long
    localparam int ERR_BIT_LINE_SHORT = 5;
    localparam int ERR_BIT_LINE_LONG  = 6;
    localparam int ERR_BIT_FRAME_SHORT= 7;
    localparam int ERR_BIT_FRAME_LONG = 8;

    localparam int INT_BIT_FRAME_DONE = 0;   // INT_STATUS: [0]=frame_done   [1]=fifo_overflow
    localparam int INT_BIT_FIFO_OVF   = 1;   //             [2]=line_err     [3]=frame_err
    localparam int INT_BIT_LINE       = 2;   //             [4]=axis_err     [5]=line_short
    localparam int INT_BIT_FRAME      = 3;   //             [6]=line_long    [7]=frame_short
    localparam int INT_BIT_AXIS       = 4;   //             [8]=frame_long
    localparam int INT_BIT_LINE_SHORT = 5;
    localparam int INT_BIT_LINE_LONG  = 6;
    localparam int INT_BIT_FRAME_SHORT= 7;
    localparam int INT_BIT_FRAME_LONG = 8;

    // INT_EN 使能位号：INT_STATUS[n] 的中断使能位于 INT_EN[n+1]（n>=1，与既有寄存器说明一致）
    localparam int INT_EN_BIT_FRAME_DONE  = 0;
    localparam int INT_EN_BIT_ERR         = 1;   // 错误总使能（保留：当前未参与门控）
    localparam int INT_EN_BIT_FIFO_OVF    = 2;
    localparam int INT_EN_BIT_LINE        = 3;
    localparam int INT_EN_BIT_FRAME       = 4;
    localparam int INT_EN_BIT_AXIS        = 5;
    localparam int INT_EN_BIT_LINE_SHORT  = 6;
    localparam int INT_EN_BIT_LINE_LONG   = 7;
    localparam int INT_EN_BIT_FRAME_SHORT = 8;
    localparam int INT_EN_BIT_FRAME_LONG  = 9;

    // 数据通路几何常量（像素合并/打包/异步 FIFO）
    localparam int PIX_BYTES_MAX = 3;                                        // 支持的最大每像素字节数（RGB888）
    localparam int PIX_SR_W      = (PIX_WIDTH > (8*PIX_BYTES_MAX)) ? PIX_WIDTH : (8*PIX_BYTES_MAX);
    localparam logic [2:0] PIX_FMT_MAX = 3'd4;                               // PIX_FMT 合法上限
    localparam int FIFO_SB_WIDTH = 8;                                        // sideband: {frame_last, tlast, bswap, valid_bytes-1[4:0]}
    localparam int FIFO_DWIDTH   = AXI_STREAM_DWIDTH + FIFO_SB_WIDTH;
    localparam int FIFO_LEVEL_W  = $clog2(FIFO_DEPTH) + 1;
    localparam int FIFO_BSWAP_BIT= AXI_STREAM_DWIDTH + 5;
    localparam int FIFO_TLAST_BIT= AXI_STREAM_DWIDTH + 6;
    localparam int FIFO_FLAST_BIT= AXI_STREAM_DWIDTH + 7;

    // =====================================================================
    // 2. 配置寄存器组（总线可读写）
    //    偏移与复位值集中在 CFG_TAB：写通路遍历该表，读通路复用同一张表，
    //    新增/删除寄存器只需改这张表，不再需要同步「复位清单 / 写分支 / 读分支」
    // =====================================================================
    typedef struct packed {
        logic [7:0]                 offset;
        logic [AXI_LITE_DWIDTH-1:0] reset;
    } cfg_desc_t;

    localparam int N_CFG = 12;
    localparam cfg_desc_t CFG_TAB [N_CFG] = '{
        '{ADDR_INT_EN,         '0           },
        '{ADDR_DVP_CTRL,       '0           },
        '{ADDR_IMG_WIDTH,      32'h0000_0780},
        '{ADDR_IMG_HEIGHT,     32'h0000_0438},
        '{ADDR_LINE_TOTAL,     32'h0000_0800},
        '{ADDR_FRAME_TOTAL,    32'h0000_0450},
        '{ADDR_AXIS_CTRL,      32'h0000_0001},
        '{ADDR_AXIS_TID,       '0           },
        '{ADDR_AXIS_TDEST,     '0           },
        '{ADDR_AXIS_TUSER,     '0           },
        '{ADDR_FIFO_THRESHOLD, 32'h0000_0010},
        '{ADDR_SCRATCH,        '0           }
    };

    // CFG_TAB 下标常量：仅用于「连续赋值/组合逻辑中按固定偏移取配置值」的场合。
    //   why：仿真器 vopt 会把「实参为常量的 cfg_val 调用」在 elaboration 期折叠成常量，
    //        而 cfg_reg 在时刻 0 仍为 X，折叠结果会恒为 X（连续赋值无法恢复）。
    //        因此对固定偏移的读取一律改用下标直接索引 cfg_reg。
    //   注意：新增/删除 CFG_TAB 条目时必须同步维护本组下标。
    localparam int CFG_INT_EN      = 0;
    localparam int CFG_DVP_CTRL    = 1;
    localparam int CFG_IMG_WIDTH   = 2;
    localparam int CFG_IMG_HEIGHT  = 3;
    localparam int CFG_LINE_TOTAL  = 4;
    localparam int CFG_FRAME_TOTAL = 5;
    localparam int CFG_AXIS_CTRL   = 6;
    localparam int CFG_AXIS_TID    = 7;
    localparam int CFG_AXIS_TDEST  = 8;
    localparam int CFG_AXIS_TUSER  = 9;
    localparam int CFG_FIFO_THRES  = 10;
    localparam int CFG_SCRATCH     = 11;

    logic [AXI_LITE_DWIDTH-1:0] cfg_reg [N_CFG];   // 普通配置寄存器本体

    // =====================================================================
    // 3. 状态与调试寄存器（总线只读，由硬件事件/数据通路更新）
    // =====================================================================
    logic [AXI_LITE_DWIDTH-1:0] reg_ctrl;          // CTRL 含自清零位，独立存放
    logic [AXI_LITE_DWIDTH-1:0] reg_frame_cnt;
    logic [AXI_LITE_DWIDTH-1:0] reg_err_flag;
    logic [AXI_LITE_DWIDTH-1:0] reg_int_status;
    logic [AXI_LITE_DWIDTH-1:0] reg_dbg_beat_cnt;  // AXI-Stream beat 计数（aclk 域）

    // =====================================================================
    // 4. 状态源与硬件事件（源端由第 12 节数据通路驱动）
    // =====================================================================
    // ---- 4.1 aclk 域状态源：FIFO 读侧与 AXIS 输出 ----
    wire        status_axis_busy;     // 1 = FIFO 非空，等待 AXI-Stream 接收
    wire        status_fifo_full;     // 1 = FIFO 满（按读侧水位判定）
    wire        status_fifo_empty;    // 1 = FIFO 空
    wire [15:0] fifo_level;           // FIFO 当前水位（beat）
    wire        fifo_full;
    wire        fifo_empty;
    wire        fifo_almost_full;     // 水位达到 FIFO_THRESHOLD（阈值 0 = 关闭）
    wire        fifo_overflow;        // 溢出粘滞（仅经 FIFO_STATUS 暴露）
    wire        fifo_underflow;       // 空读粘滞（仅经 FIFO_STATUS 暴露）

    // 事件（aclk 域单拍脉冲）：pclk 域事件经第 12.5 节「翻转位 + 2 级同步 + 边沿检测」跨域
    wire frame_done_event;
    wire fifo_overflow_event;
    wire line_err_event;              // 行错误汇总 = line_short | line_long
    wire frame_err_event;             // 帧错误汇总 = frame_short | frame_long
    wire axis_err_event;              // AXI-Stream 握手异常（tready 超时，见 §12.9）
    wire cfg_err_event;               // 配置非法（PIX_FMT 超出取值范围）
    wire line_short_event;
    wire line_long_event;
    wire frame_short_event;
    wire frame_long_event;
    wire fifo_underflow_event;        // 仅经 FIFO_STATUS 暴露

    // ---- 4.2 pclk 域状态与计数源：跨到 aclk 侧供软件读回（见第 8 节）----
    logic [7:0]  pclk_fsm_state;      // pclk 域采集主状态机编码
    logic        pclk_busy;           // 采集中（帧/行处理中）
    logic        pclk_frame_valid;    // pvref 有效
    logic        pclk_line_valid;     // phref 有效
    logic [31:0] pclk_pix_cnt;        // 当前行已接收像素数（含越界丢弃的像素）
    logic [31:0] pclk_line_cnt;       // 当前帧已接收行数

    // ---- 4.3 AXI-Stream 输出侧（aclk 域）状态 ----
    wire  beat_xfer;                  // 1 = 本拍 AXI-Stream 拍被接收（tvalid & tready）
    logic dbg_in_frame;               // 1 = 已收到本帧首个 beat（DBG_BEAT_CNT 口径标志）

    // =====================================================================
    // 5. 公用函数（须先声明后使用）
    // =====================================================================
    // 把单比特标志放到第 idx 位（其余位 0），用于拼装事件掩码与自清零掩码
    function automatic logic [AXI_LITE_DWIDTH-1:0] one_hot_mask(input logic val, input int idx);
        one_hot_mask = '0;
        one_hot_mask[idx] = val;
        return one_hot_mask;
    endfunction

    // wstrb 字节选通合并：仅更新 wstrb 有效的字节
    function automatic logic [AXI_LITE_DWIDTH-1:0] apply_wstrb(
        input logic [AXI_LITE_DWIDTH-1:0]     cur,
        input logic [AXI_LITE_DWIDTH-1:0]     data,
        input logic [AXI_LITE_STRB_WIDTH-1:0] strb
    );
        apply_wstrb = cur;
        for (int i = 0; i < AXI_LITE_STRB_WIDTH; i++) begin
            if (strb[i]) apply_wstrb[i*8 +: 8] = data[i*8 +: 8];
        end
        return apply_wstrb;
    endfunction

    // W1C：wstrb 有效字节中写 1 的位清零
    function automatic logic [AXI_LITE_DWIDTH-1:0] w1c_clear(
        input logic [AXI_LITE_DWIDTH-1:0]     cur,
        input logic [AXI_LITE_DWIDTH-1:0]     data,
        input logic [AXI_LITE_STRB_WIDTH-1:0] strb
    );
        return cur & ~apply_wstrb('0, data, strb);
    endfunction

    // 按偏移取配置寄存器当前值（读通路与跨域源共用；未命中返回 0）
    function automatic logic [AXI_LITE_DWIDTH-1:0] cfg_val(input logic [7:0] offset);
        cfg_val = '0;
        for (int i = 0; i < N_CFG; i++) begin
            if (offset == CFG_TAB[i].offset) cfg_val = cfg_reg[i];
        end
        return cfg_val;
    endfunction

    // 二进制 -> 格雷码
    function automatic logic [AXI_LITE_DWIDTH-1:0] bin2gray(input logic [AXI_LITE_DWIDTH-1:0] bin);
        return bin ^ (bin >> 1);
    endfunction

    // 格雷码 -> 二进制（逐位异或链）
    function automatic logic [AXI_LITE_DWIDTH-1:0] gray2bin(input logic [AXI_LITE_DWIDTH-1:0] gray);
        gray2bin[AXI_LITE_DWIDTH-1] = gray[AXI_LITE_DWIDTH-1];
        for (int i = AXI_LITE_DWIDTH-2; i >= 0; i--) begin
            gray2bin[i] = gray2bin[i+1] ^ gray[i];
        end
        return gray2bin;
    endfunction

    // PIX_FMT -> 每像素字节数：0=YUV422(2B) 1=RGB565(2B) 2=RAW8(1B) 3=RAW10(2B) 4=RGB888(3B)
    function automatic logic [1:0] pix_bytes_of(input logic [2:0] fmt);
        case (fmt)
            3'd2:    pix_bytes_of = 2'd1;
            3'd4:    pix_bytes_of = 2'd3;
            default: pix_bytes_of = 2'd2;
        endcase
    endfunction

    // 像素内字节序反转（DVP_CTRL.BYTE_SWAP=1）：仅低 n 字节参与，其余位保持
    function automatic logic [PIX_SR_W-1:0] pix_swap(
        input logic [PIX_SR_W-1:0] v,
        input int unsigned         n
    );
        pix_swap = v;
        for (int i = 0; i < n; i++) begin
            pix_swap[i*8 +: 8] = v[(n-1-i)*8 +: 8];
        end
        return pix_swap;
    endfunction

    // 把像素的低 n 字节拼到 beat 的第 base 字节起（调用方保证 base+n <= STRB_WIDTH）
    function automatic logic [AXI_STREAM_DWIDTH-1:0] beat_insert(
        input logic [AXI_STREAM_DWIDTH-1:0] cur,
        input logic [PIX_SR_W-1:0]          pix,
        input int unsigned                  base,
        input int unsigned                  n
    );
        beat_insert = cur;
        for (int i = 0; i < n; i++) begin
            beat_insert[(base+i)*8 +: 8] = pix[i*8 +: 8];
        end
        return beat_insert;
    endfunction

    // 低 n 字节有效掩码（tstrb 用）
    function automatic logic [AXI_STREAM_STRB_WIDTH-1:0] byte_mask(input int unsigned n);
        byte_mask = '0;
        for (int i = 0; i < AXI_STREAM_STRB_WIDTH; i++) begin
            if (i < n) byte_mask[i] = 1'b1;
        end
        return byte_mask;
    endfunction

    // 高 n 字节有效掩码（大端输出时有效字节位于 beat 高位）
    function automatic logic [AXI_STREAM_STRB_WIDTH-1:0] byte_mask_hi(input int unsigned n);
        byte_mask_hi = byte_mask(n) << (AXI_STREAM_STRB_WIDTH - n);
    endfunction

    // 整 beat 字节反转（AXIS_CTRL.BYTE_SWAP=1：byte i <-> byte STRB-1-i）
    function automatic logic [AXI_STREAM_DWIDTH-1:0] beat_reverse(
        input logic [AXI_STREAM_DWIDTH-1:0] v
    );
        for (int i = 0; i < AXI_STREAM_STRB_WIDTH; i++) begin
            beat_reverse[i*8 +: 8] = v[(AXI_STREAM_STRB_WIDTH-1-i)*8 +: 8];
        end
        return beat_reverse;
    endfunction

    // =====================================================================
    // 6. 地址译码与事务接受条件
    //    仅译低位偏移；高位非 0 视为未映射地址，不别名到寄存器区
    //    接受条件放在此处（而非第 10 节），是因为第 7 节的跨域请求发生器要引用
    //    wr_accept —— SystemVerilog 要求先声明后使用
    // =====================================================================
    wire [AXI_LITE_AWIDTH-1:0] wr_offset = slv_axil.awaddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [AXI_LITE_AWIDTH-1:0] rd_offset = slv_axil.araddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [7:0] wr_addr = wr_offset[7:0];
    wire [7:0] rd_addr = rd_offset[7:0];
    wire wr_hit = (wr_offset[AXI_LITE_AWIDTH-1:8] == '0);
    wire rd_hit = (rd_offset[AXI_LITE_AWIDTH-1:8] == '0);

    // 写通道：AW 与 W 同时握手且处于空闲态；读通道：AR 握手且处于空闲态
    typedef enum logic [1:0] {WR_IDLE, WR_RESP} wr_state_e;
    typedef enum logic [1:0] {RD_IDLE, RD_DATA} rd_state_e;

    wr_state_e wr_state;
    rd_state_e rd_state;

    wire wr_accept = aresetn && (wr_state == WR_IDLE) && slv_axil.awvalid && slv_axil.wvalid;
    wire rd_accept = aresetn && (rd_state == RD_IDLE) && slv_axil.arvalid;

    // =====================================================================
    // 7. 跨时钟域：配置参数 aclk -> pclk
    //    数据通路：aclk 域编码为格雷码并冻结寄存 -> pclk 域 2 级同步 -> 解码
    //    握手确认（整组 4 相，覆盖 7.3 的更新组）：
    //      aclk 侧写命中组内偏移 -> 置 dirty；无在途事务时发起：
    //        冻结本次数据 + 翻转 cfg_req_tgl
    //      pclk 侧 2 级同步请求 -> 在 pvref 有效边沿（帧边界）提交影子寄存器，
    //        并翻转 cfg_ack_tgl 回 aclk，表示「本组配置已在该帧边界生效」
    //      aclk 侧 2 级同步 ack -> 清除在途标志；若等待超时则置 cfg_ack_timeout
    //    更新策略：
    //      - DVP_CTRL.PVREF_POL 配置后立即生效（极性本身必须先可用，
    //        否则无法判断 pvref 何时有效），不参与握手
    //      - 其余作用于 pclk 域的配置参数只在 pvref 有效边沿统一加载
    //    说明：源端在请求发出后冻结到 ack 返回，因此数据在途期间稳定；
    //          格雷码在此之上作为冗余保护保留（应对单字变化与计数器类通路）
    // =====================================================================
    // ---- 7.0 DVP 输入同步链（din/href/vref 同链，深度 4）----
    // 对齐使用：同一级的 din/href/vref 取自同一拍，避免合并相位错位（同参考模块）
    // 采样沿选择（PCLK_INV，立即生效）：=0 直接采 pdin/pvref/phref（pclk 上升沿）；
    //   =1 先用 negedge 寄存一拍再进同步链（等效于下降沿采样，代价是半拍相位延迟）
    wire pclk_inv_aclk = cfg_reg[CFG_DVP_CTRL][DVP_BIT_PCLK_INV];
    logic pclk_inv_s1 = 1'b0;
    logic pclk_inv_s2 = 1'b0;

    localparam int DVP_SYNC_STAGES = 4;

    logic [DVP_DWIDTH-1:0] din_neg  = '0;
    logic                  href_neg = 1'b0;
    logic                  vref_neg = 1'b0;

    always_ff @(negedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            din_neg  <= '0;
            href_neg <= 1'b0;
            vref_neg <= 1'b0;
        end else begin
            din_neg  <= pdin;
            href_neg <= phref;
            vref_neg <= pvref;
        end
    end

    wire [DVP_DWIDTH-1:0] din_in  = pclk_inv_s2 ? din_neg  : pdin;
    wire                  href_in = pclk_inv_s2 ? href_neg : phref;
    wire                  vref_in = pclk_inv_s2 ? vref_neg : pvref;

    logic [DVP_DWIDTH-1:0] din_sync [DVP_SYNC_STAGES] = '{default:'0};
    logic                  href_sync[DVP_SYNC_STAGES] = '{default:'0};
    logic                  vref_sync[DVP_SYNC_STAGES] = '{default:'0};

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            for (int i = 0; i < DVP_SYNC_STAGES; i++) begin
                din_sync[i]  <= '0;
                href_sync[i] <= 1'b0;
                vref_sync[i] <= 1'b0;
            end
            pclk_inv_s1 <= 1'b0;
            pclk_inv_s2 <= 1'b0;
        end else begin
            pclk_inv_s1  <= pclk_inv_aclk;
            pclk_inv_s2  <= pclk_inv_s1;
            din_sync[0]  <= din_in;
            href_sync[0] <= href_in;
            vref_sync[0] <= vref_in;
            for (int i = 1; i < DVP_SYNC_STAGES; i++) begin
                din_sync[i]  <= din_sync[i-1];
                href_sync[i] <= href_sync[i-1];
                vref_sync[i] <= vref_sync[i-1];
            end
        end
    end

    wire [DVP_DWIDTH-1:0] din_s     = din_sync [DVP_SYNC_STAGES-1];   // 同步后的像素字节
    wire                  phref_raw = href_sync[DVP_SYNC_STAGES-1];   // 同步后的原始行有效
    wire                  pvref_raw = vref_sync[DVP_SYNC_STAGES-1];   // 同步后的原始帧有效

    logic pvref_raw_d = 1'b0;

    // ---- 7.1 PVREF_POL：立即生效（1 bit 的格雷码即其自身，仍走 2 级同步）----
    // 极性必须先可用，否则无法判断 pvref 何时有效，故不参与帧边界握手
    wire pvref_pol_aclk = cfg_reg[CFG_DVP_CTRL][DVP_BIT_PVREF_POL];

    logic pvref_pol_s1 = 1'b0;
    logic pvref_pol_s2 = 1'b0;

    // ---- 7.2 帧有效极性校正与帧边界更新脉冲（pclk 域）----
    // pvref_act：1 = 帧有效；极性取立即生效的 PVREF_POL（见 7.1）：
    //   PVREF_POL=0 高有效（active = 原始电平）、=1 低有效（active = 取反）
    //   （行有效 phref_act 依赖帧边界提交的影子配置，声明位置见第 12.1 节）
    // cfg_upd_pulse：影子配置提交脉冲，取**原始 pvref** 的边沿（上升/下降均提交）。
    //   不用校正后的边沿：极性寄存器本身可被软件随时改写，用校正后的边沿会因极性写入
    //   而凭空产生「帧边界」（在 pvref 恒定、无真实 DVP 活动时把配置提前提交）。
    wire pvref_act = pvref_pol_s2 ? ~pvref_raw : pvref_raw;      // 1 = 帧有效

    logic pvref_act_d = 1'b0;
    wire pvref_rise =  pvref_act & ~pvref_act_d;
    wire pvref_fall = ~pvref_act &  pvref_act_d;
    wire cfg_upd_pulse = pvref_raw ^ pvref_raw_d;                // 帧边界更新脉冲（原始 pvref 边沿）

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pvref_pol_s1 <= 1'b0;
            pvref_pol_s2 <= 1'b0;
            pvref_act_d  <= 1'b0;
            pvref_raw_d  <= 1'b0;
        end else begin
            pvref_pol_s1 <= pvref_pol_aclk;
            pvref_pol_s2 <= pvref_pol_s1;
            pvref_act_d  <= pvref_act;
            pvref_raw_d  <= pvref_raw;
        end
    end

    // ---- 7.3 帧边界更新组：组内偏移表（唯一来源），下标即 CDC_FRM_* 常量 ----
    localparam int CDC_FRM_CTRL        = 0;
    localparam int CDC_FRM_DVP_CTRL    = 1;
    localparam int CDC_FRM_IMG_WIDTH   = 2;
    localparam int CDC_FRM_IMG_HEIGHT  = 3;
    localparam int CDC_FRM_LINE_TOTAL  = 4;
    localparam int CDC_FRM_FRAME_TOTAL = 5;
    localparam int CDC_FRM_FIFO_THRES  = 6;
    localparam int CDC_FRM_AXIS_CTRL   = 7;   // AXIS_CTRL 作用于打包/tlast 的位需随帧边界生效
    localparam int N_CDC_FRM           = 8;

    // AXIS_TID / AXIS_TDEST / AXIS_TUSER / INT_EN / SCRATCH 只在 aclk 域使用，不在本组内
    localparam logic [7:0] CDC_FRM_ADDR [N_CDC_FRM] = '{
        ADDR_CTRL        ,   // CDC_FRM_CTRL
        ADDR_DVP_CTRL    ,   // CDC_FRM_DVP_CTRL
        ADDR_IMG_WIDTH   ,   // CDC_FRM_IMG_WIDTH
        ADDR_IMG_HEIGHT  ,   // CDC_FRM_IMG_HEIGHT
        ADDR_LINE_TOTAL  ,   // CDC_FRM_LINE_TOTAL
        ADDR_FRAME_TOTAL ,   // CDC_FRM_FRAME_TOTAL
        ADDR_FIFO_THRESHOLD, // CDC_FRM_FIFO_THRES
        ADDR_AXIS_CTRL       // CDC_FRM_AXIS_CTRL
    };

    logic [N_CDC_FRM-1:0] cdc_frm_wr_hit;              // 本次写命中的组内字
    logic [AXI_LITE_DWIDTH-1:0] cdc_frm_src [N_CDC_FRM];   // aclk 域源值

    for (genvar i = 0; i < N_CDC_FRM; i++) begin : g_frm_src
        assign cdc_frm_wr_hit[i] = (wr_addr == CDC_FRM_ADDR[i]);
    end

    // 源值按组下标直接取（不在连续赋值里用常量实参调用 cfg_val，理由见 CFG_TAB 下标常量处）；
    // CTRL 的自清零位在写通路已清掉（恒 0，见 11.4），可直接作为跨域源
    always_comb begin
        cdc_frm_src[CDC_FRM_CTRL]        = reg_ctrl;
        cdc_frm_src[CDC_FRM_DVP_CTRL]    = cfg_reg[CFG_DVP_CTRL];
        cdc_frm_src[CDC_FRM_IMG_WIDTH]   = cfg_reg[CFG_IMG_WIDTH];
        cdc_frm_src[CDC_FRM_IMG_HEIGHT]  = cfg_reg[CFG_IMG_HEIGHT];
        cdc_frm_src[CDC_FRM_LINE_TOTAL]  = cfg_reg[CFG_LINE_TOTAL];
        cdc_frm_src[CDC_FRM_FRAME_TOTAL] = cfg_reg[CFG_FRAME_TOTAL];
        cdc_frm_src[CDC_FRM_FIFO_THRES]  = cfg_reg[CFG_FIFO_THRES];
        cdc_frm_src[CDC_FRM_AXIS_CTRL]   = cfg_reg[CFG_AXIS_CTRL];
    end

    wire cfg_frm_wr = wr_accept && wr_hit && (cdc_frm_wr_hit != '0);

    // ---- 7.4 握手：请求侧（aclk 域）----
    // 单次在途 + dirty 重发：在途期间到达的写入靠 cfg_dirty 在 ack 后重新发起，
    // 保证任何一次配置写入都不会丢失
    logic cfg_dirty;              // aclk 域：有写入尚未随请求发出
    logic cfg_req_tgl;            // aclk 域：请求电平（翻转式）
    logic cfg_req_s1;             // pclk 域：请求同步 1 级
    logic cfg_req_s2;             // pclk 域：请求同步 2 级
    logic cfg_ack_tgl;            // pclk 域：确认电平（翻转式）
    logic cfg_ack_s1;             // aclk 域：确认同步 1 级
    logic cfg_ack_s2;             // aclk 域：确认同步 2 级
    logic [AXI_LITE_DWIDTH-1:0] cdc_frm_gray_aclk [N_CDC_FRM];   // 冻结的格雷码数据

    localparam int CFG_ACK_WAIT_BITS = 16;   // ack 等待超时门限位宽（约 2^16 个 aclk）

    logic [CFG_ACK_WAIT_BITS-1:0] cfg_wait_cnt;
    logic cfg_ack_timeout;        // 请求超时标志：仅用于让等待计数饱和（未引出到寄存器，见 Reg_v_0_0.md §6.4）

    wire cfg_busy      = (cfg_req_tgl != cfg_ack_s2);   // 1 = 有请求在途
    wire cfg_issue     = cfg_dirty && !cfg_busy;        // 1 = 本拍发起请求
    wire cfg_req_pend  = (cfg_req_s2 != cfg_ack_tgl);   // pclk 域：有待提交的请求
    wire cfg_pending   = cfg_busy || cfg_dirty;         // 1 = 配置尚未在帧边界提交完毕（STATUS[6]）

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cfg_dirty   <= 1'b0;
            cfg_req_tgl <= 1'b0;
            for (int i = 0; i < N_CDC_FRM; i++) cdc_frm_gray_aclk[i] <= '0;
        end else begin
            // dirty 先置位：与「发起」同拍的写入在下一轮（ack 之后）重新发起，
            // 因为本拍的 cfg_reg 尚未更新，捕获到的仍是旧值
            if (cfg_frm_wr)     cfg_dirty <= 1'b1;
            else if (cfg_issue) cfg_dirty <= 1'b0;

            if (cfg_issue) begin
                cfg_req_tgl <= ~cfg_req_tgl;      // 翻转请求
                for (int i = 0; i < N_CDC_FRM; i++) begin
                    cdc_frm_gray_aclk[i] <= bin2gray(cdc_frm_src[i]);   // 冻结本次数据
                end
            end
        end
    end

    // ack 同步回 aclk 域 + 等待超时计数（pclk 不翻转时给出可观测标志）
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cfg_ack_s1      <= 1'b0;
            cfg_ack_s2      <= 1'b0;
            cfg_wait_cnt    <= '0;
            cfg_ack_timeout <= 1'b0;
        end else begin
            cfg_ack_s1 <= cfg_ack_tgl;
            cfg_ack_s2 <= cfg_ack_s1;

            if (!cfg_busy) begin
                cfg_wait_cnt    <= '0;
                cfg_ack_timeout <= 1'b0;
            end else if (!cfg_ack_timeout) begin
                cfg_wait_cnt <= cfg_wait_cnt + 1'b1;
                if (cfg_wait_cnt == {CFG_ACK_WAIT_BITS{1'b1}}) cfg_ack_timeout <= 1'b1;
            end
        end
    end

    // ---- 7.5 握手：确认侧（pclk 域）----
    // pclk 域：2 级同步（声明即置 0：prst_n 未驱动时 pclk 域不向 AXIL 读回通路注入 X）
    logic [AXI_LITE_DWIDTH-1:0] cdc_frm_gray_s1 [N_CDC_FRM] = '{default:'0};
    logic [AXI_LITE_DWIDTH-1:0] cdc_frm_gray_s2 [N_CDC_FRM] = '{default:'0};
    wire  [AXI_LITE_DWIDTH-1:0] cdc_frm_bin_pclk [N_CDC_FRM];

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            for (int i = 0; i < N_CDC_FRM; i++) begin
                cdc_frm_gray_s1[i] <= '0;
                cdc_frm_gray_s2[i] <= '0;
            end
        end else begin
            for (int i = 0; i < N_CDC_FRM; i++) begin
                cdc_frm_gray_s1[i] <= cdc_frm_gray_aclk[i];
                cdc_frm_gray_s2[i] <= cdc_frm_gray_s1[i];
            end
        end
    end

    for (genvar i = 0; i < N_CDC_FRM; i++) begin : g_frm_decode
        assign cdc_frm_bin_pclk[i] = gray2bin(cdc_frm_gray_s2[i]);
    end

    // 请求 2 级同步进 pclk 域
    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            cfg_req_s1 <= 1'b0;
            cfg_req_s2 <= 1'b0;
        end else begin
            cfg_req_s1 <= cfg_req_tgl;
            cfg_req_s2 <= cfg_req_s1;
        end
    end

    // pclk 域影子配置 + 提交确认：每次帧边界统一加载；
    // 若本次加载对应一个未确认的请求（cfg_req_pend），翻转 ack 告知 aclk 侧
    // 「本组配置已在该帧边界生效」
    // pclk 域影子配置（组下标即 cfg_pclk_* 与 CDC_FRM_* 常量的对应关系）
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_ctrl        = '0;   // EN/SINGLE_SHOT/AUTO_RESTART 采集控制
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_dvp_ctrl    = '0;   // PIX_FMT/PHREF_POL/BYTE_SWAP
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_img_width   = '0;   // 行像素比较
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_img_height  = '0;   // 帧行数比较
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_line_total  = '0;   // 保留：行总周期（当前未参与判定）
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_frame_total = '0;   // 保留：帧总行数（当前未参与判定）
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_fifo_thres  = '0;   // 保留：FIFO 水位阈值（当前未参与判定）
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_axis_ctrl   = '0;   // PACK_EN/PACK_MODE/BYTE_SWAP/TLAST_MODE

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            cfg_pclk_ctrl        <= '0;
            cfg_pclk_dvp_ctrl    <= '0;
            cfg_pclk_img_width   <= '0;
            cfg_pclk_img_height  <= '0;
            cfg_pclk_line_total  <= '0;
            cfg_pclk_frame_total <= '0;
            cfg_pclk_fifo_thres  <= '0;
            cfg_pclk_axis_ctrl   <= '0;
            cfg_ack_tgl          <= 1'b0;
        end else if (cfg_upd_pulse) begin
            cfg_pclk_ctrl        <= cdc_frm_bin_pclk[CDC_FRM_CTRL];
            cfg_pclk_dvp_ctrl    <= cdc_frm_bin_pclk[CDC_FRM_DVP_CTRL];
            cfg_pclk_img_width   <= cdc_frm_bin_pclk[CDC_FRM_IMG_WIDTH];
            cfg_pclk_img_height  <= cdc_frm_bin_pclk[CDC_FRM_IMG_HEIGHT];
            cfg_pclk_line_total  <= cdc_frm_bin_pclk[CDC_FRM_LINE_TOTAL];
            cfg_pclk_frame_total <= cdc_frm_bin_pclk[CDC_FRM_FRAME_TOTAL];
            cfg_pclk_fifo_thres  <= cdc_frm_bin_pclk[CDC_FRM_FIFO_THRES];
            cfg_pclk_axis_ctrl   <= cdc_frm_bin_pclk[CDC_FRM_AXIS_CTRL];
            if (cfg_req_pend) cfg_ack_tgl <= ~cfg_ack_tgl;   // 回确认：已提交
        end
    end

    // ---- 7.7 清除类写动作（SOFT_RST / CLR_CNT / CLR_FIFO）的跨域一致处理 ----
    // 三个自清零位都作用于 pclk 域（主状态机/行帧计数/打包寄存器）与 FIFO 两侧指针，
    // 因此用「请求电平 + 确认电平」的翻转式握手把它们一致化：
    //   aclk：写 1 置请求（单次在途；在途期间的重复清除合并——清除类操作可合并）
    //   pclk：同步为「清除电平」，电平有效期间保持主状态机复位、计数清零；
    //         若该请求需要冲刷则同时复位 FIFO 写侧（CLR_CNT 不复位 FIFO）；
    //         收到请求即回确认，电平随之撤销（约 1~2 个 pclk）
    //   aclk：同步回 ack 后结束「冲刷窗口」；窗口内 AXIS 输出暂停、FIFO 读侧复位，
    //         避免窗口内指针失配向外送出幻影数据
    // 说明：SOFT_RST/CLR_FIFO 需要冲刷 FIFO；CLR_CNT 只清计数，不冲刷 FIFO。
    wire ctrl_clr_wr  = wr_accept && wr_hit && (wr_addr == ADDR_CTRL) && slv_axil.wstrb[0];
    wire soft_rst_w   = ctrl_clr_wr && slv_axil.wdata[CTRL_BIT_SOFT_RST];
    wire clr_cnt_w    = ctrl_clr_wr && slv_axil.wdata[CTRL_BIT_CLR_CNT];
    wire clr_fifo_w   = ctrl_clr_wr && slv_axil.wdata[CTRL_BIT_CLR_FIFO];
    wire clr_any_w    = soft_rst_w | clr_cnt_w | clr_fifo_w;
    wire fifo_flush_w = soft_rst_w | clr_fifo_w;          // 需要冲刷 FIFO 的动作

    logic       clr_req_tgl    = 1'b0;      // aclk 域：请求电平（翻转式）
    logic       clr_ack_tgl    = 1'b0;      // pclk 域：确认电平（翻转式）
    logic       clr_ack_s1     = 1'b0;      // aclk 域：确认同步
    logic       clr_ack_s2     = 1'b0;
    logic       clr_req_s1     = 1'b0;      // pclk 域：请求同步
    logic       clr_req_s2     = 1'b0;
    logic       clr_req_flush  = 1'b0;      // aclk 域：在途请求是否需要冲刷 FIFO（随请求同步）
    logic       clr_flush_s1   = 1'b0;      // pclk 域：冲刷标志同步
    logic       clr_flush_s2   = 1'b0;
    logic       fifo_flush_aclk= 1'b0;      // 1 = 冲刷窗口（读侧复位 + 输出暂停）
    logic [3:0] flush_rel_cnt  = 4'd0;

    wire clr_pend_aclk  = (clr_req_tgl != clr_ack_s2);
    wire clr_pclk_level = (clr_req_s2 != clr_ack_tgl);    // pclk 域：清除电平

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            clr_req_tgl     <= 1'b0;
            clr_ack_s1      <= 1'b0;
            clr_ack_s2      <= 1'b0;
            clr_req_flush   <= 1'b0;
            fifo_flush_aclk <= 1'b0;
            flush_rel_cnt   <= 4'd0;
        end else begin
            clr_ack_s1 <= clr_ack_tgl;
            clr_ack_s2 <= clr_ack_s1;

            if (clr_any_w && !clr_pend_aclk) begin
                clr_req_tgl   <= ~clr_req_tgl;
                clr_req_flush <= fifo_flush_w;      // 与请求翻转同拍登记，随请求一起同步到 pclk
            end

            if (fifo_flush_w) begin
                fifo_flush_aclk <= 1'b1;
                flush_rel_cnt   <= 4'd0;
            end else if (fifo_flush_aclk && !clr_pend_aclk) begin
                // 等 ack 返回后再保持 3 拍，让 FIFO 两侧指针同步稳定后放开输出
                if (flush_rel_cnt == 4'd3) fifo_flush_aclk <= 1'b0;
                else                       flush_rel_cnt   <= flush_rel_cnt + 4'd1;
            end
        end
    end

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            clr_req_s1  <= 1'b0;
            clr_req_s2  <= 1'b0;
            clr_flush_s1<= 1'b0;
            clr_flush_s2<= 1'b0;
            clr_ack_tgl <= 1'b0;
        end else begin
            clr_req_s1  <= clr_req_tgl;
            clr_req_s2  <= clr_req_s1;
            clr_flush_s1<= clr_req_flush;
            clr_flush_s2<= clr_flush_s1;
            if (clr_pclk_level) clr_ack_tgl <= clr_req_s2;   // 确认：电平随之撤销
        end
    end

    // FIFO 两侧复位：
    //   写侧（pclk）：随 pclk 清除电平，但仅当该请求需要冲刷（SOFT_RST/CLR_FIFO）时才复位；
    //     CLR_CNT 只清计数、不动 FIFO 指针——若单侧复位会造成格雷码指针失配并输出幻影数据。
    //   读侧（aclk）：随冲刷窗口复位。两侧只在冲刷动作上成对复位，指针保持一致。
    wire fifo_wr_rst_n = prst_n  & ~(clr_pclk_level & clr_flush_s2);
    wire fifo_rd_rst_n = aresetn & ~fifo_flush_aclk;

    // =====================================================================
    // 8. 跨时钟域：状态与计数 pclk -> aclk（供软件读回）
    //    机制同上：pclk 域编码寄存 -> aclk 域 2 级同步 -> aclk 域解码
    // =====================================================================
    localparam int CDC_RBK_PIX_CNT  = 0;
    localparam int CDC_RBK_LINE_CNT = 1;
    localparam int CDC_RBK_STATUS   = 2;
    localparam int N_CDC_RBK        = 3;

    // pclk 域状态字：位定义与 STATUS 一致（[15:8]=FSM_STATE [2]=LINE_VALID
    //                                     [1]=FRAME_VALID [0]=BUSY）
    wire [AXI_LITE_DWIDTH-1:0] pclk_status = {
        16'h0,
        pclk_fsm_state,
        5'h0,                 // [7:3]：FIFO/AXIS 状态在 aclk 域，不经本通路
        pclk_line_valid,
        pclk_frame_valid,
        pclk_busy
    };

    // pclk 域：格雷码编码寄存
    logic [AXI_LITE_DWIDTH-1:0] cdc_rbk_gray_pclk [N_CDC_RBK] = '{default:'0};

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            for (int i = 0; i < N_CDC_RBK; i++) cdc_rbk_gray_pclk[i] <= '0;
        end else begin
            cdc_rbk_gray_pclk[CDC_RBK_PIX_CNT]  <= bin2gray(pclk_pix_cnt);
            cdc_rbk_gray_pclk[CDC_RBK_LINE_CNT] <= bin2gray(pclk_line_cnt);
            cdc_rbk_gray_pclk[CDC_RBK_STATUS]   <= bin2gray(pclk_status);
        end
    end

    // aclk 域：2 级同步 + 解码
    logic [AXI_LITE_DWIDTH-1:0] cdc_rbk_gray_s1 [N_CDC_RBK];
    logic [AXI_LITE_DWIDTH-1:0] cdc_rbk_gray_s2 [N_CDC_RBK];
    wire  [AXI_LITE_DWIDTH-1:0] rbk_pix_cnt_aclk;
    wire  [AXI_LITE_DWIDTH-1:0] rbk_line_cnt_aclk;
    wire  [AXI_LITE_DWIDTH-1:0] rbk_status_aclk;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            for (int i = 0; i < N_CDC_RBK; i++) begin
                cdc_rbk_gray_s1[i] <= '0;
                cdc_rbk_gray_s2[i] <= '0;
            end
        end else begin
            for (int i = 0; i < N_CDC_RBK; i++) begin
                cdc_rbk_gray_s1[i] <= cdc_rbk_gray_pclk[i];
                cdc_rbk_gray_s2[i] <= cdc_rbk_gray_s1[i];
            end
        end
    end

    assign rbk_pix_cnt_aclk  = gray2bin(cdc_rbk_gray_s2[CDC_RBK_PIX_CNT]);
    assign rbk_line_cnt_aclk = gray2bin(cdc_rbk_gray_s2[CDC_RBK_LINE_CNT]);
    assign rbk_status_aclk   = gray2bin(cdc_rbk_gray_s2[CDC_RBK_STATUS]);

    // =====================================================================
    // 9. 寄存器读回组合值与事件掩码
    // =====================================================================
    wire [AXI_LITE_DWIDTH-1:0] reg_status = {
        16'h0,
        rbk_status_aclk[15:8],        // [15:8] FSM_STATE（pclk 域跨域读回）
        cfg_pending,                  // [6] 配置在途/未提交（1 = 有请求未确认或有写入未发起）
        status_axis_busy,             // [5] AXI-Stream 忙（aclk 域）
        status_fifo_empty,            // [4] FIFO 空（aclk 域）
        status_fifo_full,             // [3] FIFO 满（aclk 域）
        rbk_status_aclk[2],           // [2] LINE_VALID（pclk 域跨域读回）
        rbk_status_aclk[1],           // [1] FRAME_VALID（pclk 域跨域读回）
        rbk_status_aclk[0]            // [0] BUSY（pclk 域跨域读回）
    };

    wire [AXI_LITE_DWIDTH-1:0] reg_fifo_status = {
        11'h0,
        fifo_almost_full,             // [20] 水位达到 FIFO_THRESHOLD（阈值 0 = 关闭）
        fifo_underflow,               // [19]
        fifo_overflow,                // [18]
        fifo_empty,                   // [17]
        fifo_full,                    // [16]
        fifo_level                    // [15:0]
    };

    // 同拍事件掩码：W1C/SOFT_RST/CLR_CNT 用它把「与写操作同拍发生的事件」合并进结果，
    // 避免整向量赋值把粘滞事件静默丢弃
    //   ERR_FLAG：全部错误事件均置位（粘滞，不受 INT_EN 影响）
    //   INT_STATUS：[0] 帧完成；[1:4] 既有错误位（沿用当前不受门控的行为）；
    //               [5:8] 为新增边界错误位，按 INT_EN[6:9] 门控
    wire [AXI_LITE_DWIDTH-1:0] int_en_w = cfg_reg[CFG_INT_EN];

    wire [AXI_LITE_DWIDTH-1:0] err_event_mask = one_hot_mask(fifo_overflow_event, ERR_BIT_FIFO_OVF)
                                              | one_hot_mask(line_err_event,      ERR_BIT_LINE)
                                              | one_hot_mask(frame_err_event,     ERR_BIT_FRAME)
                                              | one_hot_mask(axis_err_event,      ERR_BIT_AXIS)
                                              | one_hot_mask(cfg_err_event,       ERR_BIT_CFG)
                                              | one_hot_mask(line_short_event,    ERR_BIT_LINE_SHORT)
                                              | one_hot_mask(line_long_event,     ERR_BIT_LINE_LONG)
                                              | one_hot_mask(frame_short_event,   ERR_BIT_FRAME_SHORT)
                                              | one_hot_mask(frame_long_event,    ERR_BIT_FRAME_LONG);

    wire [AXI_LITE_DWIDTH-1:0] int_event_mask = one_hot_mask(frame_done_event,    INT_BIT_FRAME_DONE)
                                              | one_hot_mask(fifo_overflow_event, INT_BIT_FIFO_OVF)
                                              | one_hot_mask(line_err_event,      INT_BIT_LINE)
                                              | one_hot_mask(frame_err_event,     INT_BIT_FRAME)
                                              | one_hot_mask(axis_err_event,      INT_BIT_AXIS)
                                              | one_hot_mask(line_short_event  & int_en_w[INT_EN_BIT_LINE_SHORT],  INT_BIT_LINE_SHORT)
                                              | one_hot_mask(line_long_event   & int_en_w[INT_EN_BIT_LINE_LONG],   INT_BIT_LINE_LONG)
                                              | one_hot_mask(frame_short_event & int_en_w[INT_EN_BIT_FRAME_SHORT], INT_BIT_FRAME_SHORT)
                                              | one_hot_mask(frame_long_event  & int_en_w[INT_EN_BIT_FRAME_LONG],  INT_BIT_FRAME_LONG);

    // CTRL 下一值：字节选通合并后清掉自清零位（仅在 wstrb[0] 有效时清除）
    wire [AXI_LITE_DWIDTH-1:0] ctrl_selfclear_mask = slv_axil.wstrb[0]
        ? one_hot_mask(1'b1, CTRL_BIT_SOFT_RST)
        | one_hot_mask(1'b1, CTRL_BIT_CLR_CNT)
        | one_hot_mask(1'b1, CTRL_BIT_CLR_FIFO)
        : '0;
    wire [AXI_LITE_DWIDTH-1:0] ctrl_next_w =
        apply_wstrb(reg_ctrl, slv_axil.wdata, slv_axil.wstrb) & ~ctrl_selfclear_mask;

    // =====================================================================
    // 10. AXI4-Lite 通道握手（从机侧）与读数据选择
    //     写：AW 与 W 同时握手后接受地址+数据，再由 B 通道回响应
    //     读：AR 握手后捕获读数据，再由 R 通道返回
    // =====================================================================
    // 状态/接受条件与枚举声明见第 6 节（先声明后使用）
    logic [AXI_LITE_DWIDTH-1:0] rdata_reg;
    logic [AXI_LITE_DWIDTH-1:0] rdata_mux;   // 读数据组合选择结果（见下方 always_comb）

    assign slv_axil.awready = wr_accept;
    assign slv_axil.wready  = wr_accept;
    assign slv_axil.bvalid  = (wr_state == WR_RESP);
    assign slv_axil.bid     = '0;      // 本设计不使用写响应 ID
    assign slv_axil.bresp   = 2'b00;   // 恒 OKAY：未映射地址与只读寄存器写均被忽略
                                       // （如需报错：!wr_hit 时返回 SLVERR 2'b10）
    assign slv_axil.arready = rd_accept;
    assign slv_axil.rvalid  = (rd_state == RD_DATA);
    assign slv_axil.rid     = '0;      // 本设计不使用读数据 ID
    assign slv_axil.rresp   = 2'b00;   // 恒 OKAY：未映射地址读回 0
                                       // （如需报错：!rd_hit 时返回 DECERR 2'b11）
    assign slv_axil.rdata   = rdata_reg;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state <= WR_IDLE;
        end else begin
            case (wr_state)
                WR_IDLE: if (slv_axil.awvalid && slv_axil.wvalid) wr_state <= WR_RESP;
                WR_RESP: if (slv_axil.bready)                     wr_state <= WR_IDLE;
                default:                                          wr_state <= WR_IDLE;
            endcase
        end
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state  <= RD_IDLE;
            rdata_reg <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: if (slv_axil.arvalid) begin
                             rd_state  <= RD_DATA;
                             rdata_reg <= rdata_mux;
                         end
                RD_DATA: if (slv_axil.rready) rd_state <= RD_IDLE;
                default:                      rd_state <= RD_IDLE;
            endcase
        end
    end

    // 读数据选择：越界地址读 0；配置寄存器按 CFG_TAB 命中，状态寄存器逐个列出
    always_comb begin
        rdata_mux = '0;
        if (rd_hit) begin
            rdata_mux = cfg_val(rd_addr);           // 命中 CFG_TAB 的配置寄存器
            case (rd_addr)
                ADDR_CTRL:         rdata_mux = reg_ctrl;
                ADDR_STATUS:       rdata_mux = reg_status;
                ADDR_FRAME_CNT:    rdata_mux = reg_frame_cnt;
                ADDR_ERR_FLAG:     rdata_mux = reg_err_flag;
                ADDR_INT_STATUS:   rdata_mux = reg_int_status;
                ADDR_VERSION:      rdata_mux = IP_VERSION;
                ADDR_FIFO_STATUS:  rdata_mux = reg_fifo_status;
                ADDR_DBG_STATE:    rdata_mux = {{(AXI_LITE_DWIDTH-8){1'b0}}, rbk_status_aclk[15:8]};
                ADDR_DBG_PIX_CNT:  rdata_mux = rbk_pix_cnt_aclk;    // pclk 域计数跨域读回
                ADDR_DBG_LINE_CNT: rdata_mux = rbk_line_cnt_aclk;   // pclk 域计数跨域读回
                ADDR_DBG_BEAT_CNT: rdata_mux = reg_dbg_beat_cnt;
                default:           ;
            endcase
        end
    end

    // =====================================================================
    // 11. 寄存器写通路
    //     顺序即优先级：粘滞事件 -> W1C -> CTRL 写动作 -> 配置寄存器写入
    // =====================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_ctrl         <= '0;
            reg_frame_cnt    <= '0;
            reg_err_flag     <= '0;
            reg_int_status   <= '0;
            reg_dbg_beat_cnt <= '0;
            for (int i = 0; i < N_CFG; i++) cfg_reg[i] <= CFG_TAB[i].reset;
        end else begin
            // ---- 11.1 硬件粘滞事件 ----
            reg_err_flag   <= reg_err_flag   | err_event_mask;
            reg_int_status <= reg_int_status | int_event_mask;
            if (frame_done_event) reg_frame_cnt <= reg_frame_cnt + 1'b1;
            // DBG_BEAT_CNT：本帧已输出 beat 数（帧首 beat 起从 1 计数；
            // 帧结束后保持该帧总数，下一帧首 beat 时归 1）
            if (beat_xfer) reg_dbg_beat_cnt <= dbg_in_frame ? (reg_dbg_beat_cnt + 1'b1) : 32'd1;

            // ---- 11.2 W1C：写入位清除，同拍事件保留 ----
            if (wr_accept && wr_hit) begin
                if (wr_addr == ADDR_ERR_FLAG) begin
                    reg_err_flag <= w1c_clear(reg_err_flag, slv_axil.wdata, slv_axil.wstrb)
                                    | err_event_mask;
                end
                if (wr_addr == ADDR_INT_STATUS) begin
                    reg_int_status <= w1c_clear(reg_int_status, slv_axil.wdata, slv_axil.wstrb)
                                      | int_event_mask;
                end
            end

            // ---- 11.3 CTRL 写动作（自清零位随 11.4 一并生效）----
            // aclk 域计数/标志在此直接清除；pclk 域（DBG_PIX_CNT/DBG_LINE_CNT、主状态机、
            // 像素合并/打包寄存器）与 FIFO 指针的清除经 §7.7 的跨域握手完成
            if (wr_accept && wr_hit && (wr_addr == ADDR_CTRL)) begin
                if (slv_axil.wdata[CTRL_BIT_SOFT_RST] && slv_axil.wstrb[0]) begin  // SOFT_RST
                    reg_frame_cnt    <= '0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_int_status   <= int_event_mask;
                    reg_dbg_beat_cnt <= '0;
                end
                if (slv_axil.wdata[CTRL_BIT_CLR_CNT] && slv_axil.wstrb[0]) begin   // CLR_CNT
                    reg_frame_cnt    <= '0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_dbg_beat_cnt <= '0;
                end
                // CLR_FIFO 不涉及 aclk 域寄存器，其作用（冲刷 FIFO + 清 FIFO_STATUS 粘滞位）见 §7.7
            end

            // ---- 11.4 寄存器写入：CTRL 单独处理，其余配置寄存器按表遍历 ----
            // 自清零位只在 wstrb[0] 有效时清除（见 ctrl_selfclear_mask），
            // 因此 reg_ctrl[1]/[4]/[5] 在任意时刻恒为 0，可直接作为跨域源
            if (wr_accept && wr_hit) begin
                if (wr_addr == ADDR_CTRL) reg_ctrl <= ctrl_next_w;
                for (int i = 0; i < N_CFG; i++) begin
                    if (wr_addr == CFG_TAB[i].offset) begin
                        cfg_reg[i] <= apply_wstrb(cfg_reg[i], slv_axil.wdata, slv_axil.wstrb);
                    end
                end
            end
        end
    end

    // =====================================================================
    // 12. DVP 采集 / 像素合并 / beat 打包 / 异步 FIFO / AXI-Stream 输出
    //
    //   结构参考 RTL/Ref/DVP_AXI_v_2_0.v：输入 4 级同步链 -> 像素多拍合并
    //   -> 打包移位寄存 -> 异步 FIFO（pclk 写 / aclk 读）-> 输出。
    //   与参考模块的差异：输出为 AXI-Stream；不要求行长整除打包位宽
    //   （按字节粒度打包、行末不足一拍时以 sideband 记录有效字节数）；
    //   分辨率/格式一律取帧边界提交的影子配置。
    //
    //   行/帧边界语义（见 Doc/Reg_v_0_0.md）：
    //     行长 = phref 有效期间接收的像素数，帧长 = pvref 有效期间接收的行数；
    //     不足设定值时按实际长度结束（不填充），超出设定值的数据丢弃（不输出）；
    //     输出尺寸恒等于 IMG_WIDTH / IMG_HEIGHT。
    // =====================================================================
    // ---- 12.1 像素几何与打包参数（pclk 域，取帧边界提交的影子配置）----
    // DVP 输入为字节串行：DVP_DWIDTH 必须为 8（其他取值在 elaboration 期报错）
    initial begin
        if (DVP_DWIDTH != 8) begin
            $error("DVP2axis：数据通路按字节串行实现，要求 DVP_DWIDTH=8，当前为 %0d", DVP_DWIDTH);
        end
    end

    // 行有效极性校正（依赖帧边界提交的影子配置，故在本节声明）
    //   同样遵循「0=高有效 / 1=低有效」
    wire  phref_act = cfg_pclk_dvp_ctrl[DVP_BIT_PHREF_POL] ? ~phref_raw : phref_raw;

    logic phref_act_d = 1'b0;
    wire  phref_rise =  phref_act & ~phref_act_d;
    wire  phref_fall = ~phref_act &  phref_act_d;

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) phref_act_d <= 1'b0;
        else         phref_act_d <= phref_act;
    end

    // PIX_FMT -> 每像素字节数；PIX_FMT 越界视为配置非法（不采集，置 CFG_ERR）
    wire [2:0] pix_fmt       = cfg_pclk_dvp_ctrl[DVP_BIT_PIX_FMT +: 3];
    wire [1:0] pix_bytes     = pix_bytes_of(pix_fmt);
    wire       fmt_ok_shadow = (pix_fmt <= PIX_FMT_MAX);
    wire       dvp_bswap     = cfg_pclk_dvp_ctrl[DVP_BIT_BYTE_SWAP];

    // AXIS_CTRL 影子（作用于打包/tlast 的位随帧边界生效；TSTRB_EN 只在 aclk 侧使用）
    wire       pack_en    = cfg_pclk_axis_ctrl[AXIS_BIT_PACK_EN];
    wire       axis_bswap = cfg_pclk_axis_ctrl[AXIS_BIT_BYTE_SWAP];
    wire       tlast_mode = cfg_pclk_axis_ctrl[AXIS_BIT_TLAST_MODE];
    wire [1:0] pack_mode  = cfg_pclk_axis_ctrl[AXIS_BIT_PACK_MODE +: 2];

    // 每拍像素数：PACK_MODE!=0 取手动值（1=1 像素/拍 2=2 像素/拍 3=4 像素/拍）；
    // 否则 PACK_EN=1 取整拍可容纳上限、=0 取 1
    wire [5:0] auto_px_per_beat = (pix_bytes == 2'd1) ? 6'd32 :
                                  (pix_bytes == 2'd2) ? 6'd16 : 6'd10;
    wire [5:0] px_per_beat = (pack_mode == 2'd1) ? 6'd1 :
                             (pack_mode == 2'd2) ? 6'd2 :
                             (pack_mode == 2'd3) ? 6'd4 :
                             (pack_en ? auto_px_per_beat : 6'd1);
    wire [6:0] target_bytes = {1'b0, px_per_beat} * {5'b0, pix_bytes};   // 每拍目标字节数（<=32）

    // ---- 12.2 采集主状态机与行/帧边界判定 ----
    typedef enum logic [7:0] {
        DVP_ST_IDLE  = 8'h00,   // 未使能 / 等待帧开始
        DVP_ST_FRAME = 8'h01,   // 帧有效（pvref 有效），等待行
        DVP_ST_LINE  = 8'h02,   // 行有效（phref 有效），像素合并/打包中
        DVP_ST_DONE  = 8'h03    // 单帧模式已结束（SINGLE_SHOT=1 且 AUTO_RESTART=0）
    } dvp_state_e;

    dvp_state_e dvp_state = DVP_ST_IDLE;

    wire en_shadow = cfg_pclk_ctrl[CTRL_BIT_EN];
    wire ss_shadow = cfg_pclk_ctrl[CTRL_BIT_SINGLE_SHOT];
    wire ar_shadow = cfg_pclk_ctrl[CTRL_BIT_AUTO_RESTART];

    wire collecting   = (dvp_state == DVP_ST_FRAME) || (dvp_state == DVP_ST_LINE);
    wire line_active  = phref_act && collecting;

    wire [31:0] img_w = cfg_pclk_img_width;
    wire [31:0] img_h = cfg_pclk_img_height;

    // 本帧已接收行数（含当前行）：phref 有效期间 pvref 结束时用于帧边界判定
    wire [31:0] frame_lines_now = pclk_line_cnt + ((dvp_state == DVP_ST_LINE) ? 32'd1 : 32'd0);

    wire frame_start = (dvp_state == DVP_ST_IDLE) && en_shadow && fmt_ok_shadow && pvref_rise;
    wire line_start  = (dvp_state == DVP_ST_FRAME) && phref_rise;

    // 行/像素序号采用「本拍即为清零拍」的组合值：pclk_line_cnt/pclk_pix_cnt 的清零在
    // 下一拍才生效，若直接用寄存器值，行首/帧首那一个像素会被误判为越界而丢弃
    wire [31:0] line_idx_now = frame_start ? 32'd0 : pclk_line_cnt;
    wire [31:0] pix_idx_now  = line_start  ? 32'd0 : pclk_pix_cnt;

    wire row_out_en   = (line_idx_now < img_h);       // 本行在输出范围内（超出 IMG_HEIGHT 的行丢弃）
    wire pix_in_range = (pix_idx_now  < img_w);       // 本像素在行有效范围内（超出 IMG_WIDTH 的像素丢弃）

    wire line_end_evt  = phref_fall && (dvp_state == DVP_ST_LINE);   // 行结束（phref 有效沿结束点）
    wire frame_end_evt = pvref_fall && collecting;                   // 帧结束（pvref 有效沿结束点）

    wire frame_done_next = ss_shadow && !ar_shadow;                  // 单帧模式：结束帧后停采

    // 行/帧边界事件源（pclk 域单拍脉冲）
    wire line_short_evt_p  = line_end_evt  && (pclk_pix_cnt < img_w);
    wire line_long_evt_p   = line_end_evt  && (pclk_pix_cnt > img_w);
    wire frame_short_evt_p = frame_end_evt && (frame_lines_now < img_h);
    wire frame_long_evt_p  = frame_end_evt && (frame_lines_now > img_h);

    // ---- 12.3 像素合并（每 pix_bytes 个 pclk 拍合成一个像素）----
    // 移位方向同参考模块：首个拍落在像素最高字节（pix_sr 左移、新拍进最低字节）
    logic [PIX_SR_W-1:0] pix_sr      = '0;
    logic [1:0]          pix_tap_idx = 2'd0;
    wire  [PIX_SR_W-1:0] pix_sr_next = {pix_sr[PIX_SR_W-9:0], din_s[7:0]};

    wire pix_tap_last = (pix_tap_idx == (pix_bytes - 2'd1));
    wire pix_done     = line_active && pix_tap_last;                       // 本拍合并出完整像素
    // 越界（行长超限/帧行超限）的像素不打包；帧末拍同拍完成的像素不计入（避免跨帧归属）
    wire pix_keep     = pix_done && row_out_en && pix_in_range && !frame_end_evt;
    wire [PIX_SR_W-1:0] pix_val = dvp_bswap ? pix_swap(pix_sr_next, pix_bytes) : pix_sr_next;

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pix_sr      <= '0;
            pix_tap_idx <= 2'd0;
        end else if (clr_pclk_level) begin          // 清除电平：像素合并复位
            pix_sr      <= '0;
            pix_tap_idx <= 2'd0;
        end else if (line_active) begin
            pix_sr      <= pix_sr_next;
            pix_tap_idx <= pix_tap_last ? 2'd0 : (pix_tap_idx + 2'd1);
        end else begin
            pix_tap_idx <= 2'd0;   // 行间隙复位，保证每行从像素边界开始合并
        end
    end

    // ---- 12.4 行/帧计数（供边界判定、DBG_PIX_CNT/DBG_LINE_CNT 读回）----
    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pclk_pix_cnt  <= '0;
            pclk_line_cnt <= '0;
        end else if (clr_pclk_level) begin          // 清除电平：行/帧计数清零
            pclk_pix_cnt  <= '0;
            pclk_line_cnt <= '0;
        end else begin
            // 行计数：帧首清零；行末累加；pvref 在行进行中提前结束则计为一行
            //   （帧在行间隙结束时不得再加，否则帧末会被多计一行）
            if (frame_start)                        pclk_line_cnt <= '0;
            else if (line_end_evt)                  pclk_line_cnt <= pclk_line_cnt + 32'd1;
            else if (frame_end_evt && (dvp_state == DVP_ST_LINE))
                                                    pclk_line_cnt <= pclk_line_cnt + 32'd1;
            // 像素计数：行首清零；行内每合成一个像素累加（含越界丢弃的像素）
            if (line_start)    pclk_pix_cnt <= pix_done ? 32'd1 : '0;
            else if (pix_done) pclk_pix_cnt <= pclk_pix_cnt + 32'd1;
        end
    end

    // ---- 12.5 beat 打包（字节粒度；beat 缓存一拍再推入 FIFO，保证行末拍可带 tlast）----
    // beat_sr/beat_byte_cnt：当前正在拼装的 beat；
    // beat_line_last：已拼满且行已结束的 beat（暂存一拍，等待下一行首像素或帧末决定归属）
    logic [AXI_STREAM_DWIDTH-1:0] beat_sr        = '0;
    logic [5:0]                   beat_byte_cnt  = 6'd0;
    logic                         beat_line_last = 1'b0;

    wire [6:0] cnt_next  = {1'b0, beat_byte_cnt} + {5'b0, pix_bytes};
    wire       beat_fits = (cnt_next <= target_bytes);

    // 推出条件：①下一像素装不下（先把已缓存拍推入并带上行末标记）；②帧末（推入并带 frame_last）
    wire pack_push  = pix_keep && (beat_line_last || !beat_fits);
    wire line_hold  = line_end_evt && (beat_byte_cnt != 6'd0);
    wire frame_push = frame_end_evt && (beat_byte_cnt != 6'd0);

    wire push_evt        = pack_push || frame_push;
    wire push_line_last  = frame_push || (pack_push && beat_line_last);
    wire push_frame_last = frame_push;

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            beat_sr        <= '0;
            beat_byte_cnt  <= 6'd0;
            beat_line_last <= 1'b0;
        end else if (clr_pclk_level) begin          // 清除电平：打包寄存器复位
            beat_sr        <= '0;
            beat_byte_cnt  <= 6'd0;
            beat_line_last <= 1'b0;
        end else if (pack_push) begin
            // 已缓存拍由组合逻辑推入 FIFO；本拍以当前像素开新拍（计数只含本像素）
            beat_sr        <= beat_insert('0, pix_val, 0, pix_bytes);
            beat_byte_cnt  <= {4'b0, pix_bytes};
            beat_line_last <= 1'b0;
        end else if (frame_push) begin
            beat_sr        <= '0;
            beat_byte_cnt  <= 6'd0;
            beat_line_last <= 1'b0;
        end else if (pix_keep) begin
            beat_sr        <= beat_insert(beat_sr, pix_val, beat_byte_cnt, pix_bytes);
            beat_byte_cnt  <= cnt_next[5:0];
            beat_line_last <= 1'b0;
        end else if (line_hold) begin
            beat_line_last <= 1'b1;    // 数据保留，标记为行末拍
        end
    end

    // ---- 12.6 异步 FIFO 写入（pclk 域）----
    // sideband 随 beat 一起过 FIFO：{frame_last, tlast, bswap, valid_bytes-1[4:0]}
    //   有效字节数取 -1 编码以压进 5 bit；bswap 随拍携带，读侧无需依赖跨域配置
    wire tlast_pclk = tlast_mode ? push_frame_last : push_line_last;

    wire [AXI_STREAM_DWIDTH-1:0] beat_data_out = axis_bswap ? beat_reverse(beat_sr) : beat_sr;
    wire [4:0]                   beat_bytes_m1 = beat_byte_cnt[4:0] - 5'd1;

    wire [FIFO_DWIDTH-1:0] fifo_wr_data = {push_frame_last, tlast_pclk, axis_bswap,
                                           beat_bytes_m1, beat_data_out};

    wire fifo_wr_en   = push_evt;
    wire fifo_wr_full;                                       // 写侧满标志（FIFO 输出）
    wire fifo_ovf_evt = fifo_wr_en && fifo_wr_full;           // 满时本次写入被丢弃 -> 溢出事件

    // ---- 12.7 AXI-Stream 输出（aclk 域，FIFO 读侧）----
    logic [FIFO_DWIDTH-1:0] fifo_rd_data;
    wire                    fifo_rd_empty;
    wire                    fifo_rd_in_undf;
    wire [FIFO_LEVEL_W-1:0] fifo_rd_level;

    wire [4:0]                   out_bytes_m1 = fifo_rd_data[AXI_STREAM_DWIDTH +: 5];
    wire [5:0]                   out_bytes    = {1'b0, out_bytes_m1} + 6'd1;
    wire                         out_bswap    = fifo_rd_data[FIFO_BSWAP_BIT];
    wire [AXI_STREAM_DWIDTH-1:0] out_data     = fifo_rd_data[AXI_STREAM_DWIDTH-1:0];
    wire                         out_tlast    = fifo_rd_data[FIFO_TLAST_BIT];
    wire                         out_f_last   = fifo_rd_data[FIFO_FLAST_BIT];
    wire                         tstrb_en_out = cfg_reg[CFG_AXIS_CTRL][AXIS_BIT_TSTRB_EN];

    assign axis_m.tvalid = !fifo_rd_empty && !fifo_flush_aclk;   // 冲刷窗口内暂停输出
    assign axis_m.tdata  = out_data;
    assign axis_m.tstrb  = tstrb_en_out ? (out_bswap ? byte_mask_hi(out_bytes) : byte_mask(out_bytes))
                                       : {AXI_STREAM_STRB_WIDTH{1'b1}};
    assign axis_m.tkeep  = {AXI_STREAM_STRB_WIDTH{1'b1}};      // tkeep 恒全 1：整拍有效由 tstrb 表达
    assign axis_m.tlast  = out_tlast;

    wire fifo_rd_en = axis_m.tvalid && axis_m.tready;
    assign beat_xfer = fifo_rd_en;

    // ---- AXI-Stream 握手异常：tvalid 持续有效而 tready 长期不就绪（默认 8192 个 aclk）----
    localparam int AXIS_TREADY_TIMEOUT = 8192;
    localparam int AXIS_WAIT_BITS      = $clog2(AXIS_TREADY_TIMEOUT);

    logic [AXIS_WAIT_BITS-1:0] axis_stall_cnt = '0;
    logic                      axis_err_latch = 1'b0;   // 一次停滞只上报一次
    wire  axis_stall   = axis_m.tvalid && !axis_m.tready;
    wire  axis_err_w   = axis_stall && !axis_err_latch &&
                         (axis_stall_cnt == AXIS_WAIT_BITS'(AXIS_TREADY_TIMEOUT-1));

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axis_stall_cnt <= '0;
            axis_err_latch <= 1'b0;
        end else if (!axis_stall) begin
            axis_stall_cnt <= '0;                 // 握手恢复即清零（可再次上报）
            axis_err_latch <= 1'b0;
        end else if (!axis_err_latch) begin
            axis_stall_cnt <= axis_stall_cnt + 1'b1;
            if (axis_err_w) axis_err_latch <= 1'b1;
        end
    end

    wire frame_done_w = beat_xfer && out_f_last;
    assign frame_done_event = frame_done_w;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            dbg_in_frame <= 1'b0;
        end else if (frame_done_w) begin
            dbg_in_frame <= 1'b0;
        end else if (beat_xfer) begin
            dbg_in_frame <= 1'b1;
        end
    end

    // ---- 12.8 异步 FIFO 实例（pclk 写 / aclk 读）----
    axis_async_fifo #(
        .DWIDTH      (FIFO_DWIDTH),
        .DEPTH       (FIFO_DEPTH),
        .LEVEL_WIDTH (FIFO_LEVEL_W)
    ) u_axis_fifo (
        .wr_clk   (pclk),
        .wr_rst_n (fifo_wr_rst_n),          // 仅 SOFT_RST/CLR_FIFO 复位（与读侧成对，指针保持一致）
        .wr_en    (fifo_wr_en),
        .wr_data  (fifo_wr_data),
        .wr_full  (fifo_wr_full),
        .wr_ovf   (),                       // 溢出由本模块按「写且满」判定，避免重复计数
        .rd_clk   (aclk),
        .rd_rst_n (fifo_rd_rst_n),          // 随冲刷窗口复位（与写侧指针一致复位）
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .rd_empty (fifo_rd_empty),
        .rd_undf  (fifo_rd_in_undf),
        .rd_level (fifo_rd_level)
    );

    // ---- 12.9 aclk 域状态 / 溢出与下溢粘滞 ----
    assign status_axis_busy  = !fifo_rd_empty && !fifo_flush_aclk;
    assign status_fifo_empty = fifo_rd_empty;
    assign status_fifo_full  = (fifo_rd_level >= FIFO_LEVEL_W'(FIFO_DEPTH));   // 真满（水位=深度）
    assign fifo_level        = {{(16-FIFO_LEVEL_W){1'b0}}, fifo_rd_level};
    assign fifo_full         = status_fifo_full;
    assign fifo_empty        = fifo_rd_empty;
    // 高水位阈值（FIFO_THRESHOLD，aclk 侧读，写后立即生效；阈值 0 = 关闭该指示）
    wire [15:0] fifo_thresh_w = cfg_reg[CFG_FIFO_THRES][15:0];
    assign fifo_almost_full   = (fifo_thresh_w != 16'd0) && (fifo_level >= fifo_thresh_w);

    logic ovf_sticky  = 1'b0;
    logic undf_sticky = 1'b0;

    // ---- 12.10 事件跨域：pclk 域事件脉冲 -> aclk 域单拍脉冲 ----
    // 机制：事件侧翻转 1 bit，接收侧 3 级同步后边沿检测（同型事件间隔 <2 个 aclk 才可能被合并，
    //       本设计 aclk 不低于 pclk/2，且错误标志为粘滞位，合并只影响计数不影响置位语义）
    localparam int N_PEVT     = 6;
    localparam int PEVT_OVF   = 0;
    localparam int PEVT_LSHRT = 1;
    localparam int PEVT_LLONG = 2;
    localparam int PEVT_FSHRT = 3;
    localparam int PEVT_FLONG = 4;
    localparam int PEVT_CFG   = 5;

    logic [N_PEVT-1:0] pevt_tgl    = '0;    // pclk 域：事件翻转位
    logic [N_PEVT-1:0] pevt_tgl_s1 = '0;
    logic [N_PEVT-1:0] pevt_tgl_s2 = '0;
    logic [N_PEVT-1:0] pevt_tgl_s3 = '0;
    wire  [N_PEVT-1:0] pevt_pulse  = pevt_tgl_s2 ^ pevt_tgl_s3;

    // CFG_ERR：配置提交时 PIX_FMT 由合法变为非法（持续非法不重复上报）
    wire fmt_valid_next = (cdc_frm_bin_pclk[CDC_FRM_DVP_CTRL][DVP_BIT_PIX_FMT +: 3] <= PIX_FMT_MAX[2:0]);
    wire cfg_err_evt_p  = cfg_upd_pulse && !fmt_valid_next && fmt_ok_shadow;

    wire [N_PEVT-1:0] pevt_set = {cfg_err_evt_p, frame_long_evt_p, frame_short_evt_p,
                                  line_long_evt_p, line_short_evt_p, fifo_ovf_evt};

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pevt_tgl <= '0;
        end else begin
            for (int i = 0; i < N_PEVT; i++) begin
                if (pevt_set[i]) pevt_tgl[i] <= ~pevt_tgl[i];
            end
        end
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            pevt_tgl_s1 <= '0;
            pevt_tgl_s2 <= '0;
            pevt_tgl_s3 <= '0;
            ovf_sticky  <= 1'b0;
            undf_sticky <= 1'b0;
        end else begin
            pevt_tgl_s1 <= pevt_tgl;
            pevt_tgl_s2 <= pevt_tgl_s1;
            pevt_tgl_s3 <= pevt_tgl_s2;
            if (fifo_flush_w) begin                     // SOFT_RST/CLR_FIFO：清 FIFO 状态粘滞位
                ovf_sticky  <= 1'b0;
                undf_sticky <= 1'b0;
            end else begin
                if (pevt_pulse[PEVT_OVF]) ovf_sticky  <= 1'b1;    // 溢出：粘滞到下次复位/清除
                if (fifo_rd_in_undf)      undf_sticky <= 1'b1;    // 空读：读侧同域事件
            end
        end
    end

    assign fifo_overflow       = ovf_sticky;
    assign fifo_underflow      = undf_sticky;
    assign fifo_overflow_event = pevt_pulse[PEVT_OVF];
    assign line_short_event    = pevt_pulse[PEVT_LSHRT];
    assign line_long_event     = pevt_pulse[PEVT_LLONG];
    assign frame_short_event   = pevt_pulse[PEVT_FSHRT];
    assign frame_long_event    = pevt_pulse[PEVT_FLONG];
    assign cfg_err_event       = pevt_pulse[PEVT_CFG];
    assign line_err_event      = line_short_event | line_long_event;      // 行错误汇总位
    assign frame_err_event     = frame_short_event | frame_long_event;    // 帧错误汇总位
    assign axis_err_event      = axis_err_w;   // tready 超时（输出握手异常）
    assign fifo_underflow_event= fifo_rd_in_undf;

    // ---- 12.11 采集主状态机 ----
    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            dvp_state <= DVP_ST_IDLE;
        end else if (clr_pclk_level) begin
            dvp_state <= DVP_ST_IDLE;     // 清除电平：主状态机复位（需下一个帧边界重新开始采集）
        end else begin
            case (dvp_state)
                DVP_ST_IDLE:  if (frame_start)      dvp_state <= DVP_ST_FRAME;
                DVP_ST_FRAME: if (phref_rise)       dvp_state <= DVP_ST_LINE;
                              else if (frame_end_evt) dvp_state <= frame_done_next ? DVP_ST_DONE : DVP_ST_IDLE;
                DVP_ST_LINE:  if (line_end_evt && frame_end_evt)
                                                        dvp_state <= frame_done_next ? DVP_ST_DONE : DVP_ST_IDLE;
                              else if (line_end_evt)    dvp_state <= DVP_ST_FRAME;
                              else if (frame_end_evt)   dvp_state <= frame_done_next ? DVP_ST_DONE : DVP_ST_IDLE;
                DVP_ST_DONE:  if (!en_shadow)       dvp_state <= DVP_ST_IDLE;   // 重新使能后可再次采集
                default:                            dvp_state <= DVP_ST_IDLE;
            endcase
        end
    end

    // ---- 12.12 pclk 域状态寄存器（跨域读回源，见第 8 节）----
    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pclk_fsm_state   <= 8'h0;
            pclk_busy        <= 1'b0;
            pclk_frame_valid <= 1'b0;
            pclk_line_valid  <= 1'b0;
        end else begin
            pclk_fsm_state   <= dvp_state;
            pclk_busy        <= collecting;
            pclk_frame_valid <= pvref_act;
            pclk_line_valid  <= phref_act;
        end
    end

endmodule
