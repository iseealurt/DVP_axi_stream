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
//   寄存器行为继承 RTL/DVP2axi_stream.v（映射见 Doc/Reg_v_0_0.md）：
//     复位默认值 / wstrb 字节选通 / W1C / CTRL 自清零 / 粘滞事件 / ID 恒 0 / resp 恒 OKAY
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
    // 1. 寄存器偏移（见 Doc/Reg_v_0_0.md）
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

    // CTRL 自清零位（写 1 后自动回 0）
    localparam int CTRL_BIT_SOFT_RST = 1;
    localparam int CTRL_BIT_CLR_CNT  = 4;
    localparam int CTRL_BIT_CLR_FIFO = 5;

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
    logic [AXI_LITE_DWIDTH-1:0] reg_dbg_pix_cnt;
    logic [AXI_LITE_DWIDTH-1:0] reg_dbg_line_cnt;
    logic [AXI_LITE_DWIDTH-1:0] reg_dbg_beat_cnt;

    // =====================================================================
    // 4. 状态源与硬件事件
    //    以下均为占位常量，待 DVP 采集/AXI-Stream 打包通路接入后替换为真实信号
    // =====================================================================
    wire        status_busy         = 1'b0;
    wire        status_frame_valid  = 1'b0;
    wire        status_line_valid   = 1'b0;
    wire        status_fifo_full    = 1'b0;
    wire        status_fifo_empty   = 1'b0;
    wire        status_axis_busy    = 1'b0;
    wire [7:0]  status_fsm_state    = 8'h0;
    wire [15:0] fifo_level          = 16'h0;
    wire        fifo_full           = 1'b0;
    wire        fifo_empty          = 1'b0;
    wire        fifo_overflow       = 1'b0;
    wire        fifo_underflow      = 1'b0;

    wire frame_done_event     = 1'b0;
    wire fifo_overflow_event  = 1'b0;
    wire line_err_event       = 1'b0;
    wire frame_err_event      = 1'b0;
    wire axis_err_event       = 1'b0;
    wire cfg_err_event        = 1'b0;
    wire fifo_underflow_event = 1'b0;   // 仅经 FIFO_STATUS 暴露，不置位状态寄存器

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

    // =====================================================================
    // 6. 寄存器读回组合值与事件掩码
    // =====================================================================
    wire [AXI_LITE_DWIDTH-1:0] reg_status = {
        16'h0,
        status_fsm_state,
        2'b00,
        status_axis_busy,
        status_fifo_empty,
        status_fifo_full,
        status_line_valid,
        status_frame_valid,
        status_busy
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

    // =====================================================================
    // 7. CTRL 组合下一值与地址译码
    // =====================================================================
    // CTRL 下一值：字节选通合并后清掉自清零位（仅在 wstrb[0] 有效时清除）
    wire [AXI_LITE_DWIDTH-1:0] ctrl_selfclear_mask = slv_axil.wstrb[0]
        ? one_hot_mask(1'b1, CTRL_BIT_SOFT_RST)
        | one_hot_mask(1'b1, CTRL_BIT_CLR_CNT)
        | one_hot_mask(1'b1, CTRL_BIT_CLR_FIFO)
        : '0;
    wire [AXI_LITE_DWIDTH-1:0] ctrl_next_w =
        apply_wstrb(reg_ctrl, slv_axil.wdata, slv_axil.wstrb) & ~ctrl_selfclear_mask;

    // 地址译码：仅译低位偏移，高位非 0 视为未映射地址，不别名到寄存器区
    wire [AXI_LITE_AWIDTH-1:0] wr_offset = slv_axil.awaddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [AXI_LITE_AWIDTH-1:0] rd_offset = slv_axil.araddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [7:0] wr_addr = wr_offset[7:0];
    wire [7:0] rd_addr = rd_offset[7:0];
    wire wr_hit = (wr_offset[AXI_LITE_AWIDTH-1:8] == '0);
    wire rd_hit = (rd_offset[AXI_LITE_AWIDTH-1:8] == '0);

    // =====================================================================
    // 8. AXI4-Lite 通道握手（从机侧）
    //     写：AW 与 W 同时握手后接受地址+数据，再由 B 通道回响应
    //     读：AR 握手后捕获读数据，再由 R 通道返回
    // =====================================================================
    typedef enum logic [1:0] {WR_IDLE, WR_RESP} wr_state_e;
    typedef enum logic [1:0] {RD_IDLE, RD_DATA} rd_state_e;

    wr_state_e wr_state;
    rd_state_e rd_state;
    logic [AXI_LITE_DWIDTH-1:0] rdata_reg;
    logic [AXI_LITE_DWIDTH-1:0] rdata_mux;   // 读数据组合选择结果（见下方 always_comb）

    wire wr_accept = aresetn && (wr_state == WR_IDLE) && slv_axil.awvalid && slv_axil.wvalid;
    wire rd_accept = aresetn && (rd_state == RD_IDLE) && slv_axil.arvalid;

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
            for (int i = 0; i < N_CFG; i++) begin
                if (rd_addr == CFG_TAB[i].offset) rdata_mux = cfg_reg[i];
            end
            case (rd_addr)
                ADDR_CTRL:         rdata_mux = reg_ctrl;
                ADDR_STATUS:       rdata_mux = reg_status;
                ADDR_FRAME_CNT:    rdata_mux = reg_frame_cnt;
                ADDR_ERR_FLAG:     rdata_mux = reg_err_flag;
                ADDR_INT_STATUS:   rdata_mux = reg_int_status;
                ADDR_VERSION:      rdata_mux = IP_VERSION;
                ADDR_FIFO_STATUS:  rdata_mux = reg_fifo_status;
                ADDR_DBG_STATE:    rdata_mux = {{(AXI_LITE_DWIDTH-8){1'b0}}, status_fsm_state};
                ADDR_DBG_PIX_CNT:  rdata_mux = reg_dbg_pix_cnt;
                ADDR_DBG_LINE_CNT: rdata_mux = reg_dbg_line_cnt;
                ADDR_DBG_BEAT_CNT: rdata_mux = reg_dbg_beat_cnt;
                default:           ;
            endcase
        end
    end

    // =====================================================================
    // 9. 寄存器写通路
    //    顺序即优先级：粘滞事件 -> W1C -> CTRL 写动作 -> 配置寄存器写入
    // =====================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_ctrl         <= '0;
            reg_frame_cnt    <= '0;
            reg_err_flag     <= '0;
            reg_int_status   <= '0;
            reg_dbg_pix_cnt  <= '0;
            reg_dbg_line_cnt <= '0;
            reg_dbg_beat_cnt <= '0;
            for (int i = 0; i < N_CFG; i++) cfg_reg[i] <= CFG_TAB[i].reset;
        end else begin
            // ---- 9.1 硬件粘滞事件 ----
            reg_err_flag   <= reg_err_flag   | err_event_mask;
            reg_int_status <= reg_int_status | int_event_mask;
            if (frame_done_event) reg_frame_cnt <= reg_frame_cnt + 1'b1;

            // ---- 9.2 W1C：写入位清除，同拍事件保留 ----
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

            // ---- 9.3 CTRL 写动作（自清零位随 9.4 一并生效）----
            if (wr_accept && wr_hit && (wr_addr == ADDR_CTRL)) begin
                if (slv_axil.wdata[CTRL_BIT_SOFT_RST] && slv_axil.wstrb[0]) begin  // SOFT_RST
                    reg_frame_cnt    <= '0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_int_status   <= int_event_mask;
                    reg_dbg_pix_cnt  <= '0;
                    reg_dbg_line_cnt <= '0;
                    reg_dbg_beat_cnt <= '0;
                end
                if (slv_axil.wdata[CTRL_BIT_CLR_CNT] && slv_axil.wstrb[0]) begin   // CLR_CNT
                    reg_frame_cnt    <= '0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_dbg_pix_cnt  <= '0;
                    reg_dbg_line_cnt <= '0;
                    reg_dbg_beat_cnt <= '0;
                end
                // CLR_FIFO：FIFO 尚未实现，暂无动作
            end

            // ---- 9.4 寄存器写入：CTRL 单独处理，其余配置寄存器按表遍历 ----
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
    // 10. DVP 采集与 AXI-Stream 输出（占位）
    //     TODO: 实现 DVP 采集/打包与 AXI-Stream 主机逻辑，
    //           由数据通路产生 tvalid/tdata/tlast 并按 axis_m.tready 反压
    // =====================================================================
    assign axis_m.tvalid = 1'b0;
    assign axis_m.tdata  = '0;
    assign axis_m.tstrb  = '1;
    assign axis_m.tkeep  = '1;
    assign axis_m.tlast  = 1'b0;

endmodule
