`timescale 1ns/1ps
// =============================================================================
// axis_async_fifo : 参数化行为级异步 FIFO（写侧 pclk / 读侧 aclk）
//
//   用途：DVP2axis 数据通路中 pclk（写）-> aclk（读）的 beat 跨时钟域缓冲。
//   写侧：wr_en 与 wr_full 同时有效时本次写入被丢弃，并由 wr_ovf 给出单拍溢出脉冲
//         （DVP 源不可反压，溢出的语义是丢数据而不是反压）；
//   读侧：FWFT（首字直通）——rd_empty 为 0 时 rd_data 即为队首 beat，
//         rd_en 在同一拍弹出；rd_undf 给出「空读」单拍脉冲。
//
//   实现要点（Cummings 格雷码指针法）：
//     - 读写指针各多 1 位，用于区分「满」与「空」；
//     - 指针以格雷码跨域，接收侧 2 级同步后参与比较，保证同一时刻只有 1 bit 在变；
//     - 标志为组合比较（无额外寄存器），保证 FWFT 语义下数据即刻可用；
//     - 深度必须为 2 的幂，否则 $error 报错（不做静默截断）。
//
//   说明：本模块为仿真/行为级实现（mem 为行为化数组），综合阶段按其接口替换为
//         厂商原语即可（写侧/读侧时钟、使能、满空、数据、水位一一对应）。
// =============================================================================
module axis_async_fifo #(
    parameter int DWIDTH = 264,                          // 数据位宽（beat + sideband）
    parameter int DEPTH  = 1024,                         // 深度（必须为 2 的幂）
    // 水位位宽（0..DEPTH）：端口声明处不能引用模块体内 localparam，故在此按 DEPTH 派生
    parameter int LEVEL_WIDTH = $clog2(DEPTH) + 1
)(
    // ---- 写侧（pclk 域）----
    input  logic               wr_clk,
    input  logic               wr_rst_n,
    input  logic               wr_en,
    input  logic [DWIDTH-1:0]  wr_data,
    output logic               wr_full,
    output logic               wr_ovf,
    // ---- 读侧（aclk 域）----
    input  logic               rd_clk,
    input  logic               rd_rst_n,
    input  logic               rd_en,
    output logic [DWIDTH-1:0]  rd_data,
    output logic               rd_empty,
    output logic               rd_undf,
    output logic [LEVEL_WIDTH-1:0] rd_level
);

    localparam int AW          = $clog2(DEPTH);      // 地址位宽
    localparam int PW          = AW + 1;             // 指针位宽（多 1 位）

    // 深度必须是 2 的幂：否则格雷码指针的「环形」语义不成立
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin
            $error("axis_async_fifo：DEPTH=%0d 必须为不小于 2 的 2 的幂", DEPTH);
        end
    end

    // ---- 存储体（行为级）----
    logic [DWIDTH-1:0] mem [DEPTH];

    // ---- 指针与同步寄存器 ----
    logic [PW-1:0] wr_ptr_bin,  wr_ptr_gray;
    logic [PW-1:0] rd_ptr_bin,  rd_ptr_gray;
    logic [PW-1:0] rd_ptr_gray_w1, rd_ptr_gray_w2;   // 写侧同步（读指针）
    logic [PW-1:0] wr_ptr_gray_r1, wr_ptr_gray_r2;   // 读侧同步（写指针）
    logic [PW-1:0] wr_ptr_bin_r;                     // 读侧：解码写指针（算水位）

    // ---- 格雷码编解码 ----
    function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] bin);
        return bin ^ (bin >> 1);
    endfunction

    function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] gray);
        gray2bin[PW-1] = gray[PW-1];
        for (int i = PW - 2; i >= 0; i--) begin
            gray2bin[i] = gray2bin[i+1] ^ gray[i];
        end
        return gray2bin;
    endfunction

    wire [PW-1:0] wr_ptr_bin_nxt  = wr_ptr_bin + 1'b1;
    wire [PW-1:0] wr_ptr_gray_nxt = bin2gray(wr_ptr_bin_nxt);
    wire [PW-1:0] rd_ptr_bin_nxt  = rd_ptr_bin + 1'b1;

    // ---- 满/空判定（组合，FWFT）----
    // 满：再写一次后的写指针格雷码 = 同步过来的读指针「高两位取反」形态
    wire wr_full_v  = (wr_ptr_gray_nxt == {~rd_ptr_gray_w2[PW-1:PW-2], rd_ptr_gray_w2[PW-3:0]});
    // 空：读指针与同步过来的写指针相等
    wire rd_empty_v = (rd_ptr_gray == wr_ptr_gray_r2);

    wire wr_en_real = wr_en && !wr_full_v;
    wire rd_en_real = rd_en && !rd_empty_v;

    assign wr_full  = wr_full_v;
    assign rd_empty = rd_empty_v;
    assign wr_ovf   = wr_en && wr_full_v;      // 写溢出：本次写入被丢弃
    assign rd_undf  = rd_en && rd_empty_v;     // 空读：本次弹出无效

    // 水位（读侧视角）：同步后的写指针 - 读指针
    assign rd_level = wr_ptr_bin_r[LEVEL_WIDTH-1:0] - rd_ptr_bin[LEVEL_WIDTH-1:0];

    // FWFT 读数据：空时给 0，避免空态把未写过的存储体 X 态带上数据总线
    assign rd_data = rd_empty_v ? {DWIDTH{1'b0}} : mem[rd_ptr_bin[AW-1:0]];

    // ---- 写侧时序 ----
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin    <= '0;
            wr_ptr_gray   <= '0;
            rd_ptr_gray_w1 <= '0;
            rd_ptr_gray_w2 <= '0;
        end else begin
            rd_ptr_gray_w1 <= rd_ptr_gray;
            rd_ptr_gray_w2 <= rd_ptr_gray_w1;
            if (wr_en_real) begin
                mem[wr_ptr_bin[AW-1:0]] <= wr_data;
                wr_ptr_bin  <= wr_ptr_bin_nxt;
                wr_ptr_gray <= wr_ptr_gray_nxt;
            end
        end
    end

    // ---- 读侧时序 ----
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin    <= '0;
            rd_ptr_gray   <= '0;
            wr_ptr_gray_r1 <= '0;
            wr_ptr_gray_r2 <= '0;
            wr_ptr_bin_r  <= '0;
        end else begin
            wr_ptr_gray_r1 <= wr_ptr_gray;
            wr_ptr_gray_r2 <= wr_ptr_gray_r1;
            wr_ptr_bin_r   <= gray2bin(wr_ptr_gray_r2);
            if (rd_en_real) begin
                rd_ptr_bin  <= rd_ptr_bin_nxt;
                rd_ptr_gray <= bin2gray(rd_ptr_bin_nxt);
            end
        end
    end

endmodule
