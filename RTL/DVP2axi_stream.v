module DVP2axi_stream #(
    // parameter of dvp itfc
    parameter DVP_DWIDTH = 8 ,
    parameter PIX_WIDTH = 16 ,
    // parameter of AXI_stream itfc
    parameter AXI_ID_WIDTH = 4 ,
    parameter AXI_STREAM_TID = 1 ,
    parameter AXI_STREAM_DWIDTH = 256 ,
    localparam AXI_STREAM_STRB_WIDTH = AXI_STREAM_DWIDTH/8 ,
    parameter AXI_STREAM_USER_WIDTH = 4 ,
    parameter AXI_STREAM_TDEST_WIDTH = 4 ,
    // parameter of AXI-lite itfc
    parameter AXI_LITE_DWIDTH = 32 ,
    localparam AXI_LITE_STRB_WIDTH = AXI_LITE_DWIDTH/8 ,
    parameter AXI_LITE_AWIDTH = 32 ,
    parameter AXI_LITE_BASE_ADDR_OFFSET = 32'h0000_0000
) (
    input wire pclk ,
    input wire prst_n ,
    input wire [DVP_DWIDTH-1:0] pdin ,
    input wire pvref , 
    input wire phref , // pull high when a row is valid
    //axi4-lite for register config
    input wire aclk ,
    input wire aresetn ,
    // write address channel
    input wire awvalid ,
    input wire [AXI_LITE_AWIDTH-1:0] awaddr ,
    input wire [2:0] awport ,
    output wire awready ,
    // Write data channel
    input wire wvalid ,
    input wire [AXI_LITE_DWIDTH-1:0] wdata ,
    input wire [AXI_LITE_STRB_WIDTH-1:0] wstrb ,
    output wire wready ,
    // B channel
    input wire bready,
    output wire bvalid,
    output wire [AXI_ID_WIDTH-1:0] bid ,
    output wire [1:0] bresp,
    // read address channel
    input wire arvalid ,
    input wire [AXI_LITE_AWIDTH-1:0] araddr ,
    input wire [2:0 ]arport ,
    output wire arready ,
    // read data channel
    input wire rready ,
    output wire [AXI_LITE_DWIDTH-1:0] rdata ,
    output wire [1:0] rresp ,
    output wire [AXI_ID_WIDTH-1:0] rid,
    output wire rvalid ,
    // AXI-stream channel
    input wire axis_tready ,
    output wire axis_tvalid ,
    output wire [AXI_STREAM_DWIDTH-1:0] axis_tdata ,
    output wire [AXI_STREAM_STRB_WIDTH-1:0] axis_tstrb ,
    output wire [AXI_STREAM_STRB_WIDTH-1:0] axis_tkeep ,
    output wire axis_tlast 
);  

    // =====================================================================
    // AXI4-Lite register address map
    // =====================================================================
    localparam [7:0] ADDR_CTRL             = 8'h00;
    localparam [7:0] ADDR_STATUS           = 8'h04;
    localparam [7:0] ADDR_FRAME_CNT        = 8'h08;
    localparam [7:0] ADDR_ERR_FLAG         = 8'h0C;
    localparam [7:0] ADDR_INT_EN           = 8'h10;
    localparam [7:0] ADDR_INT_STATUS       = 8'h14;
    localparam [7:0] ADDR_VERSION          = 8'h18;
    localparam [7:0] ADDR_DVP_CTRL         = 8'h20;
    localparam [7:0] ADDR_IMG_WIDTH        = 8'h24;
    localparam [7:0] ADDR_IMG_HEIGHT       = 8'h28;
    localparam [7:0] ADDR_LINE_TOTAL       = 8'h2C;
    localparam [7:0] ADDR_FRAME_TOTAL      = 8'h30;
    localparam [7:0] ADDR_AXIS_CTRL        = 8'h40;
    localparam [7:0] ADDR_AXIS_TID         = 8'h44;
    localparam [7:0] ADDR_AXIS_TDEST       = 8'h48;
    localparam [7:0] ADDR_AXIS_TUSER       = 8'h4C;
    localparam [7:0] ADDR_FIFO_STATUS      = 8'h60;
    localparam [7:0] ADDR_FIFO_THRESHOLD   = 8'h64;
    localparam [7:0] ADDR_DBG_STATE        = 8'h70;
    localparam [7:0] ADDR_DBG_PIX_CNT      = 8'h74;
    localparam [7:0] ADDR_DBG_LINE_CNT     = 8'h78;
    localparam [7:0] ADDR_DBG_BEAT_CNT     = 8'h7C;
    localparam [7:0] ADDR_SCRATCH          = 8'h80;
    
    localparam [31:0] IP_VERSION = 32'h0001_0000;

    // AXI4-Lite channel transaction state encoding
    localparam [1:0] S_WR_IDLE = 2'd0;
    localparam [1:0] S_WR_RESP = 2'd1;
    localparam [1:0] S_RD_IDLE = 2'd0;
    localparam [1:0] S_RD_DATA = 2'd1;

    // =====================================================================
    // Internal status/debug signals
    // These are placeholders and should be connected to the DVP/AXI-Stream
    // datapath when it is implemented.
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

    // Sticky event pulses (placeholder, connect to real datapath)
    wire frame_done_event     = 1'b0;
    wire fifo_overflow_event  = 1'b0;
    wire line_err_event       = 1'b0;
    wire frame_err_event      = 1'b0;
    wire axis_err_event       = 1'b0;
    wire cfg_err_event        = 1'b0;
    wire fifo_underflow_event = 1'b0;

    // =====================================================================
    // Register declarations
    // =====================================================================
    reg [31:0] reg_ctrl;
    reg [31:0] reg_int_en;
    reg [31:0] reg_dvp_ctrl;
    reg [31:0] reg_img_width;
    reg [31:0] reg_img_height;
    reg [31:0] reg_line_total;
    reg [31:0] reg_frame_total;
    reg [31:0] reg_axis_ctrl;
    reg [31:0] reg_axis_tid;
    reg [31:0] reg_axis_tdest;
    reg [31:0] reg_axis_tuser;
    reg [31:0] reg_fifo_threshold;
    reg [31:0] reg_scratch;

    reg [31:0] reg_frame_cnt;
    reg [31:0] reg_err_flag;
    reg [31:0] reg_int_status;
    reg [31:0] reg_dbg_pix_cnt;
    reg [31:0] reg_dbg_line_cnt;
    reg [31:0] reg_dbg_beat_cnt;

    // =====================================================================
    // Byte-enable merge helper (32-bit AXI-Lite register map)
    //   注意：Verilog 要求 function/task 先声明后使用，
    //   因此这两个函数必须放在下方 ctrl_new_w 等调用点之前。
    // =====================================================================
    function [AXI_LITE_DWIDTH-1:0] apply_wstrb;
        input [AXI_LITE_DWIDTH-1:0] old;
        input [AXI_LITE_DWIDTH-1:0] new_val;
        input [AXI_LITE_STRB_WIDTH-1:0] strb;
        reg [AXI_LITE_DWIDTH-1:0] tmp;
        integer i;
        begin
            tmp = old;
            for (i = 0; i < AXI_LITE_STRB_WIDTH; i = i + 1) begin
                if (strb[i]) begin
                    tmp[i*8 +: 8] = new_val[i*8 +: 8];
                end
            end
            apply_wstrb = tmp;
        end
    endfunction

    // Build a byte-enabled write mask for W1C registers.
    function [AXI_LITE_DWIDTH-1:0] w1c_mask;
        input [AXI_LITE_DWIDTH-1:0] data;
        input [AXI_LITE_STRB_WIDTH-1:0] strb;
        reg [AXI_LITE_DWIDTH-1:0] tmp;
        integer i;
        begin
            tmp = {AXI_LITE_DWIDTH{1'b0}};
            for (i = 0; i < AXI_LITE_STRB_WIDTH; i = i + 1) begin
                if (strb[i]) begin
                    tmp[i*8 +: 8] = data[i*8 +: 8];
                end
            end
            w1c_mask = tmp;
        end
    endfunction

    // CTRL 的自清零位（写 1 后自动回 0）：[1]=SOFT_RST [4]=CLR_CNT [5]=CLR_FIFO
    // 位定义只写在这里：自清零掩码与下方 CTRL 写动作块都引用这些常量，避免两处手写失步
    localparam CTRL_BIT_SOFT_RST = 1;
    localparam CTRL_BIT_CLR_CNT  = 4;
    localparam CTRL_BIT_CLR_FIFO = 5;

    // CTRL 的下一拍值由组合逻辑给出（字节选通合并 + 自清零位清零）：
    // 在时序块中用阻塞赋值需要模块级变量，综合会推断出非预期的寄存器组，
    // 因此改为 wire 组合计算，仅保留 reg_ctrl 自身为寄存器。
    // 自清零位仅在 wstrb[0] 有效时清除，与下方写动作的字节选通条件保持一致。
    wire [31:0] ctrl_selfclear_mask = wstrb[0]
        ? ((32'd1 << CTRL_BIT_SOFT_RST) | (32'd1 << CTRL_BIT_CLR_CNT) | (32'd1 << CTRL_BIT_CLR_FIFO))
        : 32'h0000_0000;
    wire [31:0] ctrl_new_w = apply_wstrb(reg_ctrl, wdata, wstrb) & ~ctrl_selfclear_mask;

    // 事件 -> 状态位 的唯一定义：下方粘滞置位链与两个同拍事件掩码都引用这些常量，
    // 避免位映射在多处手写而失步（位定义见 Doc/Reg_v_0_0.md §3.4/§3.6）
    localparam ERR_BIT_FIFO_OVF   = 0;   // ERR_FLAG : [0]=fifo_overflow [1]=line_err
    localparam ERR_BIT_LINE       = 1;   //            [2]=frame_err     [3]=axis_err
    localparam ERR_BIT_FRAME      = 2;   //            [4]=cfg_err
    localparam ERR_BIT_AXIS       = 3;
    localparam ERR_BIT_CFG        = 4;
    localparam INT_BIT_FRAME_DONE = 0;   // INT_STATUS: [0]=frame_done   [1]=fifo_overflow
    localparam INT_BIT_FIFO_OVF   = 1;   //             [2]=line_err     [3]=frame_err
    localparam INT_BIT_LINE       = 2;   //             [4]=axis_err
    localparam INT_BIT_FRAME      = 3;
    localparam INT_BIT_AXIS       = 4;

    // 同拍硬件事件掩码：用于把「与写操作同拍发生的事件」合并进清除结果，
    // 避免后续整向量赋值把同拍事件静默丢弃（粘滞事件丢失）
    wire [31:0] err_event_mask = ({31'b0, fifo_overflow_event} << ERR_BIT_FIFO_OVF)
                               | ({31'b0, line_err_event}      << ERR_BIT_LINE)
                               | ({31'b0, frame_err_event}     << ERR_BIT_FRAME)
                               | ({31'b0, axis_err_event}      << ERR_BIT_AXIS)
                               | ({31'b0, cfg_err_event}       << ERR_BIT_CFG);
    wire [31:0] int_event_mask = ({31'b0, frame_done_event}    << INT_BIT_FRAME_DONE)
                               | ({31'b0, fifo_overflow_event}  << INT_BIT_FIFO_OVF)
                               | ({31'b0, line_err_event}       << INT_BIT_LINE)
                               | ({31'b0, frame_err_event}      << INT_BIT_FRAME)
                               | ({31'b0, axis_err_event}       << INT_BIT_AXIS);

    wire [31:0] reg_status;
    wire [31:0] reg_fifo_status;

    assign reg_status = {16'h0,
                         status_fsm_state,
                         2'b00,
                         status_axis_busy,
                         status_fifo_empty,
                         status_fifo_full,
                         status_line_valid,
                         status_frame_valid,
                         status_busy};

    assign reg_fifo_status = {12'h0,
                              fifo_underflow,
                              fifo_overflow,
                              fifo_empty,
                              fifo_full,
                              fifo_level};

    // =====================================================================
    // AXI4-Lite address offset decode
    // =====================================================================
    wire [AXI_LITE_AWIDTH-1:0] wr_offset = awaddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [AXI_LITE_AWIDTH-1:0] rd_offset = araddr - AXI_LITE_BASE_ADDR_OFFSET;
    wire [7:0] wr_addr = wr_offset[7:0];
    wire [7:0] rd_addr = rd_offset[7:0];
    // Only offsets inside the register map are decoded; higher address bits
    // must be zero so unmapped addresses do not alias into the register file.
    wire wr_hit = (wr_offset[AXI_LITE_AWIDTH-1:8] == {(AXI_LITE_AWIDTH-8){1'b0}});
    wire rd_hit = (rd_offset[AXI_LITE_AWIDTH-1:8] == {(AXI_LITE_AWIDTH-8){1'b0}});

    // =====================================================================
    // AXI4-Lite write channel transaction management
    //   S_WR_IDLE: wait until awvalid & wvalid, accept address+data
    //   S_WR_RESP: keep bvalid until bready
    // =====================================================================
    reg [1:0] wr_state;

    wire axi_wr = aresetn & (wr_state == S_WR_IDLE) & awvalid & wvalid;

    assign awready = axi_wr;
    assign wready  = axi_wr;
    assign bid     = {AXI_ID_WIDTH{1'b0}};
    // 说明：当前实现所有写访问均返回 OKAY，包括未映射地址与只读寄存器写（均被忽略）。
    //       如需错误上报，可在 !wr_hit 或对只读寄存器写时改为返回 SLVERR(2'b10)。
    assign bresp   = 2'b00;
    assign bvalid  = (wr_state == S_WR_RESP);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state <= S_WR_IDLE;
        end else begin
            case (wr_state)
                S_WR_IDLE: begin
                    if (awvalid & wvalid) begin
                        wr_state <= S_WR_RESP;
                    end
                end
                S_WR_RESP: begin
                    if (bready) begin
                        wr_state <= S_WR_IDLE;
                    end
                end
                default: begin
                    wr_state <= S_WR_IDLE;
                end
            endcase
        end
    end

    // =====================================================================
    // AXI4-Lite read channel transaction management
    //   S_RD_IDLE: wait until arvalid, accept address and capture rdata
    //   S_RD_DATA: keep rvalid until rready
    // =====================================================================
    reg [1:0] rd_state;
    reg [AXI_LITE_DWIDTH-1:0] rdata_reg;

    wire axi_rd = aresetn & (rd_state == S_RD_IDLE) & arvalid;

    assign arready = axi_rd;
    assign rid     = {AXI_ID_WIDTH{1'b0}};
    // 说明：当前实现所有读访问均返回 OKAY，包括未映射地址（读回 0）。
    //       如需错误上报，可在 !rd_hit 时改为返回 DECERR(2'b11)。
    assign rresp   = 2'b00;
    assign rvalid  = (rd_state == S_RD_DATA);
    assign rdata   = rdata_reg;

    // Read data mux
    reg [AXI_LITE_DWIDTH-1:0] rdata_mux;
    always @* begin
        if (!rd_hit) begin
            rdata_mux = {AXI_LITE_DWIDTH{1'b0}};
        end else begin
            case (rd_addr)
                ADDR_CTRL:            rdata_mux = reg_ctrl;
                ADDR_STATUS:          rdata_mux = reg_status;
                ADDR_FRAME_CNT:       rdata_mux = reg_frame_cnt;
                ADDR_ERR_FLAG:        rdata_mux = reg_err_flag;
                ADDR_INT_EN:          rdata_mux = reg_int_en;
                ADDR_INT_STATUS:      rdata_mux = reg_int_status;
                ADDR_VERSION:         rdata_mux = IP_VERSION;
                ADDR_DVP_CTRL:        rdata_mux = reg_dvp_ctrl;
                ADDR_IMG_WIDTH:       rdata_mux = reg_img_width;
                ADDR_IMG_HEIGHT:      rdata_mux = reg_img_height;
                ADDR_LINE_TOTAL:      rdata_mux = reg_line_total;
                ADDR_FRAME_TOTAL:     rdata_mux = reg_frame_total;
                ADDR_AXIS_CTRL:       rdata_mux = reg_axis_ctrl;
                ADDR_AXIS_TID:        rdata_mux = reg_axis_tid;
                ADDR_AXIS_TDEST:      rdata_mux = reg_axis_tdest;
                ADDR_AXIS_TUSER:      rdata_mux = reg_axis_tuser;
                ADDR_FIFO_STATUS:     rdata_mux = reg_fifo_status;
                ADDR_FIFO_THRESHOLD:  rdata_mux = reg_fifo_threshold;
                ADDR_DBG_STATE:       rdata_mux = {24'h0, status_fsm_state};
                ADDR_DBG_PIX_CNT:     rdata_mux = reg_dbg_pix_cnt;
                ADDR_DBG_LINE_CNT:    rdata_mux = reg_dbg_line_cnt;
                ADDR_DBG_BEAT_CNT:    rdata_mux = reg_dbg_beat_cnt;
                ADDR_SCRATCH:         rdata_mux = reg_scratch;
                default:              rdata_mux = {AXI_LITE_DWIDTH{1'b0}};
            endcase
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state  <= S_RD_IDLE;
            rdata_reg <= {AXI_LITE_DWIDTH{1'b0}};
        end else begin
            case (rd_state)
                S_RD_IDLE: begin
                    if (arvalid) begin
                        rd_state  <= S_RD_DATA;
                        rdata_reg <= rdata_mux;
                    end
                end
                S_RD_DATA: begin
                    if (rready) begin
                        rd_state <= S_RD_IDLE;
                    end
                end
                default: begin
                    rd_state <= S_RD_IDLE;
                end
            endcase
        end
    end

    // =====================================================================
    // Register write logic
    // =====================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_ctrl          <= 32'h0000_0000;
            reg_int_en        <= 32'h0000_0000;
            reg_dvp_ctrl      <= 32'h0000_0000;
            reg_img_width     <= 32'h0000_0780;
            reg_img_height    <= 32'h0000_0438;
            reg_line_total    <= 32'h0000_0800;
            reg_frame_total   <= 32'h0000_0450;
            reg_axis_ctrl     <= 32'h0000_0001;
            reg_axis_tid      <= 32'h0000_0000;
            reg_axis_tdest    <= 32'h0000_0000;
            reg_axis_tuser    <= 32'h0000_0000;
            reg_fifo_threshold<= 32'h0000_0010;
            reg_scratch       <= 32'h0000_0000;
            reg_frame_cnt     <= 32'h0000_0000;
            reg_err_flag      <= 32'h0000_0000;
            reg_int_status    <= 32'h0000_0000;
            reg_dbg_pix_cnt   <= 32'h0000_0000;
            reg_dbg_line_cnt  <= 32'h0000_0000;
            reg_dbg_beat_cnt  <= 32'h0000_0000;
        end else begin
            // -------------------------------------------------------------
            // 1) Hardware sticky events
            //    置位统一用 err_event_mask / int_event_mask 完成：
            //    「事件 → 状态位」的映射只在掩码定义处写一次，第 2、3 节的
            //    W1C / SOFT_RST / CLR_CNT 也 OR 同一掩码来保留同拍事件，
            //    因此两者天然同源，不会出现只改一处的失步。
            // -------------------------------------------------------------
            reg_err_flag   <= reg_err_flag   | err_event_mask;
            reg_int_status <= reg_int_status | int_event_mask;

            if (frame_done_event) begin
                reg_frame_cnt <= reg_frame_cnt + 1'b1;   // 事件计数（置位见掩码定义）
            end
            if (fifo_underflow_event) begin
                // FIFO underflow is only exposed through FIFO_STATUS for now
            end

            // -------------------------------------------------------------
            // 2) W1C clear for error flag and interrupt status
            //    写入的位按 W1C 清除，但同拍发生的事件必须保留（否则粘滞事件丢失）
            // -------------------------------------------------------------
            if (axi_wr && wr_hit && wr_addr == ADDR_ERR_FLAG) begin
                reg_err_flag <= (reg_err_flag & ~w1c_mask(wdata, wstrb)) | err_event_mask;
            end
            if (axi_wr && wr_hit && wr_addr == ADDR_INT_STATUS) begin
                reg_int_status <= (reg_int_status & ~w1c_mask(wdata, wstrb)) | int_event_mask;
            end

            // -------------------------------------------------------------
            // 3) CTRL self-clearing write actions
            // -------------------------------------------------------------
            if (axi_wr && wr_hit && wr_addr == ADDR_CTRL) begin
                if (wdata[CTRL_BIT_SOFT_RST] && wstrb[0]) begin // SOFT_RST
                    reg_frame_cnt    <= 32'h0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_int_status   <= int_event_mask;   // 清空但保留同拍事件
                    reg_dbg_pix_cnt  <= 32'h0;
                    reg_dbg_line_cnt <= 32'h0;
                    reg_dbg_beat_cnt <= 32'h0;
                end
                if (wdata[CTRL_BIT_CLR_CNT] && wstrb[0]) begin // CLR_CNT
                    reg_frame_cnt    <= 32'h0;
                    reg_err_flag     <= err_event_mask;   // 清空但保留同拍事件
                    reg_dbg_pix_cnt  <= 32'h0;
                    reg_dbg_line_cnt <= 32'h0;
                    reg_dbg_beat_cnt <= 32'h0;
                end
                if (wdata[CTRL_BIT_CLR_FIFO] && wstrb[0]) begin // CLR_FIFO: no FIFO implemented yet
                    // TODO: clear FIFO pointers when FIFO is added
                end
            end

            // -------------------------------------------------------------
            // 4) Normal register writes
            // -------------------------------------------------------------
            if (axi_wr && wr_hit) begin
                case (wr_addr)
                    ADDR_CTRL: begin
                        reg_ctrl <= ctrl_new_w;
                    end
                    ADDR_INT_EN: begin
                        reg_int_en <= apply_wstrb(reg_int_en, wdata, wstrb);
                    end
                    ADDR_DVP_CTRL: begin
                        reg_dvp_ctrl <= apply_wstrb(reg_dvp_ctrl, wdata, wstrb);
                    end
                    ADDR_IMG_WIDTH: begin
                        reg_img_width <= apply_wstrb(reg_img_width, wdata, wstrb);
                    end
                    ADDR_IMG_HEIGHT: begin
                        reg_img_height <= apply_wstrb(reg_img_height, wdata, wstrb);
                    end
                    ADDR_LINE_TOTAL: begin
                        reg_line_total <= apply_wstrb(reg_line_total, wdata, wstrb);
                    end
                    ADDR_FRAME_TOTAL: begin
                        reg_frame_total <= apply_wstrb(reg_frame_total, wdata, wstrb);
                    end
                    ADDR_AXIS_CTRL: begin
                        reg_axis_ctrl <= apply_wstrb(reg_axis_ctrl, wdata, wstrb);
                    end
                    ADDR_AXIS_TID: begin
                        reg_axis_tid <= apply_wstrb(reg_axis_tid, wdata, wstrb);
                    end
                    ADDR_AXIS_TDEST: begin
                        reg_axis_tdest <= apply_wstrb(reg_axis_tdest, wdata, wstrb);
                    end
                    ADDR_AXIS_TUSER: begin
                        reg_axis_tuser <= apply_wstrb(reg_axis_tuser, wdata, wstrb);
                    end
                    ADDR_FIFO_THRESHOLD: begin
                        reg_fifo_threshold <= apply_wstrb(reg_fifo_threshold, wdata, wstrb);
                    end
                    ADDR_SCRATCH: begin
                        reg_scratch <= apply_wstrb(reg_scratch, wdata, wstrb);
                    end
                    default: ;
                endcase
            end
        end
    end

    // =====================================================================
    // AXI-Stream datapath placeholder
    // TODO: implement DVP capture, packing and AXI-Stream master logic.
    // =====================================================================
    assign axis_tvalid = 1'b0;
    assign axis_tdata  = {AXI_STREAM_DWIDTH{1'b0}};
    assign axis_tstrb  = {AXI_STREAM_STRB_WIDTH{1'b1}};
    assign axis_tkeep  = {AXI_STREAM_STRB_WIDTH{1'b1}};
    assign axis_tlast  = 1'b0;

endmodule
