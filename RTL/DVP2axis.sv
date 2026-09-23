`timescale 1ns/1ps
`include "IF/if_axil.sv"
`include "IF/if_axis.sv"

// =============================================================================
// DVP2axis : DVP 图像输入 -> AXI-Stream 输出，附 AXI4-Lite 寄存器配置块
//
//   接口划分（信号与方向见 RTL/IF/ 下的接口声明）：
//     配置通路 : AXI4-Lite 从机  slv_if_axil.slv   —— 由 CPU/主机配置本模块
//     数据通路 : AXI-Stream 主机 mst_if_axis.mst   —— 输出图像流（占位待实现）
//     图像输入 : pclk 域离散信号（pdin/pvref/phref）
//
//   时钟域：
//     aclk 域 —— AXI4-Lite 寄存器块、AXI-Stream 输出
//     pclk 域 —— DVP 采集与像素/行计数
//     跨域     —— 见第 7、8 节：配置参数 aclk->pclk、状态计数 pclk->aclk，
//                 均采用「格雷码编码 -> 2 级同步 -> 格雷码解码」机制；
//                 配置方向另有整组 4 相握手（req/ack 翻转式）确认「已在帧边界生效」
//
//   寄存器行为继承 RTL/DVP2axi_stream.v（映射见 Doc/Reg_v_0_0.md）：
//     复位默认值 / wstrb 字节选通 / W1C / CTRL 自清零 / 粘滞事件 / ID 恒 0 / resp 恒 OKAY
//
//   注释标记约定：
//     // occupied —— 该处依赖尚未实现的数据通路行为，当前用占位常量/占位实现，
//                    待 DVP 采集与 AXI-Stream 打包通路接入后替换
//
//   注意：接口位宽由外部接口实例决定（接口参数不能在端口处重载），
//         模块的 AXI_LITE_* / AXI_STREAM_* 参数必须与接口实例保持一致。
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

    // 事件 -> 状态位 的位号定义（唯一定义处，掩码与写动作都引用）
    localparam int ERR_BIT_FIFO_OVF   = 0;   // ERR_FLAG : [0]=fifo_overflow [1]=line_err
    localparam int ERR_BIT_LINE       = 1;   //            [2]=frame_err     [3]=axis_err
    localparam int ERR_BIT_FRAME      = 2;   //            [4]=cfg_err
    localparam int ERR_BIT_AXIS       = 3;
    localparam int ERR_BIT_CFG        = 4;
    localparam int INT_BIT_FRAME_DONE = 0;   // INT_STATUS: [0]=frame_done   [1]=fifo_overflow
    localparam int INT_BIT_FIFO_OVF   = 1;   //             [2]=line_err     [3]=frame_err
    localparam int INT_BIT_LINE       = 2;   //             [4]=axis_err
    localparam int INT_BIT_FRAME      = 3;
    localparam int INT_BIT_AXIS       = 4;

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
    // 4. 状态源与硬件事件
    // =====================================================================
    // ---- 4.1 aclk 域状态源：占位常量，待 AXI-Stream 打包通路接入后替换 ----
    wire        status_axis_busy    = 1'b0;   // occupied
    wire        status_fifo_full    = 1'b0;   // occupied
    wire        status_fifo_empty   = 1'b0;   // occupied
    wire [15:0] fifo_level          = 16'h0;  // occupied
    wire        fifo_full           = 1'b0;   // occupied
    wire        fifo_empty          = 1'b0;   // occupied
    wire        fifo_overflow       = 1'b0;   // occupied
    wire        fifo_underflow      = 1'b0;   // occupied

    wire frame_done_event     = 1'b0;         // occupied
    wire fifo_overflow_event  = 1'b0;         // occupied
    wire line_err_event       = 1'b0;         // occupied
    wire frame_err_event      = 1'b0;         // occupied
    wire axis_err_event       = 1'b0;         // occupied
    wire cfg_err_event        = 1'b0;         // occupied
    wire fifo_underflow_event = 1'b0;         // occupied；仅经 FIFO_STATUS 暴露

    // ---- 4.2 pclk 域状态与计数源：跨到 aclk 侧供软件读回（见第 8 节）----
    wire [7:0]  pclk_fsm_state   = 8'h0;      // occupied：pclk 域采集主状态机编码
    wire        pclk_busy        = 1'b0;      // occupied：采集中
    wire        pclk_frame_valid = 1'b0;      // occupied：pvref 有效（可用 pvref_act 直接接入）
    wire        pclk_line_valid  = 1'b0;      // occupied：phref 有效（可用 phref_act 直接接入）
    wire [AXI_LITE_DWIDTH-1:0] pclk_pix_cnt  = '0;   // occupied：当前行已接收像素数
    wire [AXI_LITE_DWIDTH-1:0] pclk_line_cnt = '0;   // occupied：当前帧已接收行数

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
    // ---- 7.1 PVREF_POL：立即生效（1 bit 的格雷码即其自身，仍走 2 级同步）----
    wire pvref_pol_aclk = cfg_val(ADDR_DVP_CTRL)[DVP_BIT_PVREF_POL];

    logic pvref_pol_s1 = 1'b0;
    logic pvref_pol_s2 = 1'b0;

    // ---- 7.2 pvref 极性校正与有效边沿检测（pclk 域）----
    // 上升沿/下降沿各产生一个更新脉冲，统一用于加载下方影子配置
    wire pvref_act = pvref_pol_s2 ? pvref : ~pvref;   // 1 = 帧有效
    logic pvref_act_d = 1'b0;
    wire pvref_rise =  pvref_act & ~pvref_act_d;
    wire pvref_fall = ~pvref_act &  pvref_act_d;
    wire cfg_upd_pulse = pvref_rise | pvref_fall;     // 帧边界更新脉冲

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            pvref_pol_s1 <= 1'b0;
            pvref_pol_s2 <= 1'b0;
            pvref_act_d  <= 1'b0;
        end else begin
            pvref_pol_s1 <= pvref_pol_aclk;
            pvref_pol_s2 <= pvref_pol_s1;
            pvref_act_d  <= pvref_act;
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
    localparam int N_CDC_FRM           = 7;

    // AXIS_CTRL / AXIS_* / INT_EN / SCRATCH 只在 aclk 域使用，不在本组内
    localparam logic [7:0] CDC_FRM_ADDR [N_CDC_FRM] = '{
        ADDR_CTRL        ,   // CDC_FRM_CTRL
        ADDR_DVP_CTRL    ,   // CDC_FRM_DVP_CTRL
        ADDR_IMG_WIDTH   ,   // CDC_FRM_IMG_WIDTH
        ADDR_IMG_HEIGHT  ,   // CDC_FRM_IMG_HEIGHT
        ADDR_LINE_TOTAL  ,   // CDC_FRM_LINE_TOTAL
        ADDR_FRAME_TOTAL ,   // CDC_FRM_FRAME_TOTAL
        ADDR_FIFO_THRESHOLD  // CDC_FRM_FIFO_THRES
    };

    logic [N_CDC_FRM-1:0] cdc_frm_wr_hit;              // 本次写命中的组内字
    wire  [AXI_LITE_DWIDTH-1:0] cdc_frm_src [N_CDC_FRM];   // aclk 域源值

    for (genvar i = 0; i < N_CDC_FRM; i++) begin : g_frm_src
        assign cdc_frm_wr_hit[i] = (wr_addr == CDC_FRM_ADDR[i]);
        // CTRL 的自清零位在写通路已清掉（恒 0，见 11.4），可直接作为跨域源
        assign cdc_frm_src[i]    = (CDC_FRM_ADDR[i] == ADDR_CTRL) ? reg_ctrl
                                                                  : cfg_val(CDC_FRM_ADDR[i]);
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
    logic cfg_ack_timeout;        // occupied：请求超时标志，上报位置未定（STATUS/ERR 保留位）

    wire cfg_busy      = (cfg_req_tgl != cfg_ack_s2);   // 1 = 有请求在途
    wire cfg_issue     = cfg_dirty && !cfg_busy;        // 1 = 本拍发起请求
    wire cfg_req_pend  = (cfg_req_s2 != cfg_ack_tgl);   // pclk 域：有待提交的请求

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
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_ctrl        = '0;   // occupied：EN/SINGLE_SHOT/AUTO_RESTART 采集控制
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_dvp_ctrl    = '0;   // occupied：PIX_FMT/BYTE_SWAP/PHREF_POL
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_img_width   = '0;   // occupied：行像素比较
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_img_height  = '0;   // occupied：帧行数比较
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_line_total  = '0;   // occupied：行超时统计
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_frame_total = '0;   // occupied：帧完整性判断
    logic [AXI_LITE_DWIDTH-1:0] cfg_pclk_fifo_thres  = '0;   // occupied：FIFO 反压水位

    always_ff @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            cfg_pclk_ctrl        <= '0;
            cfg_pclk_dvp_ctrl    <= '0;
            cfg_pclk_img_width   <= '0;
            cfg_pclk_img_height  <= '0;
            cfg_pclk_line_total  <= '0;
            cfg_pclk_frame_total <= '0;
            cfg_pclk_fifo_thres  <= '0;
            cfg_ack_tgl          <= 1'b0;
        end else if (cfg_upd_pulse) begin
            cfg_pclk_ctrl        <= cdc_frm_bin_pclk[CDC_FRM_CTRL];
            cfg_pclk_dvp_ctrl    <= cdc_frm_bin_pclk[CDC_FRM_DVP_CTRL];
            cfg_pclk_img_width   <= cdc_frm_bin_pclk[CDC_FRM_IMG_WIDTH];
            cfg_pclk_img_height  <= cdc_frm_bin_pclk[CDC_FRM_IMG_HEIGHT];
            cfg_pclk_line_total  <= cdc_frm_bin_pclk[CDC_FRM_LINE_TOTAL];
            cfg_pclk_frame_total <= cdc_frm_bin_pclk[CDC_FRM_FRAME_TOTAL];
            cfg_pclk_fifo_thres  <= cdc_frm_bin_pclk[CDC_FRM_FIFO_THRES];
            if (cfg_req_pend) cfg_ack_tgl <= ~cfg_ack_tgl;   // 回确认：已提交
        end
    end

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
        2'b00,
        status_axis_busy,             // [5] AXI-Stream 忙（aclk 域）
        status_fifo_empty,            // [4] FIFO 空（aclk 域）
        status_fifo_full,             // [3] FIFO 满（aclk 域）
        rbk_status_aclk[2],           // [2] LINE_VALID（pclk 域跨域读回）
        rbk_status_aclk[1],           // [1] FRAME_VALID（pclk 域跨域读回）
        rbk_status_aclk[0]            // [0] BUSY（pclk 域跨域读回）
    };

    wire [AXI_LITE_DWIDTH-1:0] reg_fifo_status = {
        12'h0,
        fifo_underflow,
        fifo_overflow,
        fifo_empty,
        fifo_full,
        fifo_level
    };

    // 同拍事件掩码：W1C/SOFT_RST/CLR_CNT 用它把「与写操作同拍发生的事件」合并进结果，
    // 避免整向量赋值把粘滞事件静默丢弃
    wire [AXI_LITE_DWIDTH-1:0] err_event_mask = one_hot_mask(fifo_overflow_event, ERR_BIT_FIFO_OVF)
                                              | one_hot_mask(line_err_event,      ERR_BIT_LINE)
                                              | one_hot_mask(frame_err_event,     ERR_BIT_FRAME)
                                              | one_hot_mask(axis_err_event,      ERR_BIT_AXIS)
                                              | one_hot_mask(cfg_err_event,       ERR_BIT_CFG);
    wire [AXI_LITE_DWIDTH-1:0] int_event_mask = one_hot_mask(frame_done_event,    INT_BIT_FRAME_DONE)
                                              | one_hot_mask(fifo_overflow_event, INT_BIT_FIFO_OVF)
                                              | one_hot_mask(line_err_event,      INT_BIT_LINE)
                                              | one_hot_mask(frame_err_event,     INT_BIT_FRAME)
                                              | one_hot_mask(axis_err_event,      INT_BIT_AXIS);

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
            // DBG_PIX_CNT / DBG_LINE_CNT 位于 pclk 域，其清除需要跨域脉冲（握手）通路
            // occupied
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
                // CLR_FIFO：FIFO 尚未实现，暂无动作  // occupied
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
    // 12. DVP 采集与 AXI-Stream 输出（占位）
    //     TODO: 实现 DVP 采集/打包与 AXI-Stream 主机逻辑，
    //           由数据通路产生 tvalid/tdata/tlast 并按 axis_m.tready 反压；
    //           配置取值用本域的 cfg_pclk_* 影子寄存器，状态/计数接回 4.2 的 pclk 源
    //     // occupied
    // =====================================================================
    assign axis_m.tvalid = 1'b0;
    assign axis_m.tdata  = '0;
    assign axis_m.tstrb  = '1;
    assign axis_m.tkeep  = '1;
    assign axis_m.tlast  = 1'b0;

endmodule
