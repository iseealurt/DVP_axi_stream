//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Iseealurt
// 
// Create Date: 2025-11-18 19:00 
// Design Name:  
// Module Name: DVP_AXI
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 2.0  
///模块更名为DVP_AXI，
// 完善了起始地址的偏移机制，修改了行计数器的生成机制，
// 改进了分辨率的自适应能力，但目前暂不支持行有效值无法整除128的分辨率如 960*540
// 
//                       
//                                  
//////////////////////////////////////////////////////////////////////////////////
module DVP_AXI#(
	parameter   AXI_ADDR_WIDTH 		= 28			,   
                MEM_DQ_WIDTH       	= 32    		,
                WIDTH             	= 12'd640		,
                HEIGHT              = 12'd480		,
				PIXEL_DATA_WIDTH	= 16			,
				AXI_WLEN			= 4'd8			,
				BURST_LEN			= 16*AXI_WLEN	,
				FRAME_EN_VALUE		= 4'd10			,
				AXI_ID 				= 4'b0001		
				         
)(
	input 	wire 							rst_n				,
	
	input 	wire 							dvp_pclk			,
	input 	wire 	[7:0]					dvp_din				,
	input 	wire 							dvp_href			,
	input 	wire							dvp_vref			,
	
	input 	wire 	[AXI_ADDR_WIDTH-1:0]	write_buffer_offset	,
	
	input	wire 							axi_clk				,
	output 	reg 	[AXI_ADDR_WIDTH-1:0]	axi_awaddr			,
	input 	wire 							axi_awready			,
	output 	reg 							axi_awvalid			,
	output 	reg 	[3:0]					axi_awid			,
	output 	reg  	[3:0]					axi_awlen			,
	
	input 	wire 	[3:0]					axi_wid				,
	input 	wire 							axi_wready			,
	input 	wire 							axi_wlast			,
	output 	wire 	[MEM_DQ_WIDTH*8-1:0	]	axi_wdata			,
	output 	wire 	[MEM_DQ_WIDTH-1:0	]	axi_wstrb
);
	//--------------- dvp data receive layer ---------------
	localparam 	REQ_CNT_VALUE	= WIDTH * PIXEL_DATA_WIDTH / MEM_DQ_WIDTH;
	localparam 	COL_CNT_MAX_VAL	= WIDTH;
	localparam 	COL_CNT_WIDTH	= $clog2(COL_CNT_MAX_VAL);	
	localparam 	PIX_CNT_VALUE	= PIXEL_DATA_WIDTH/8;
	localparam 	PIX_CNT_WIDTH	= $clog2(PIX_CNT_VALUE);
	localparam	AXI_ADDR_STEP_VAL = PIXEL_DATA_WIDTH * BURST_LEN / MEM_DQ_WIDTH;
	
	wire 								dfifo_full, afifo_full;
	reg  	[15:0]						axi_addr_cal;
	wire 								vref_pose;
	wire 								fifo_rst;
	
	reg 	[3:0]						frame_cnt;
	reg 	[23:0]						afifo_din;
	reg 								afifo_wrreq;
	reg 								dfifo_wrreq;
	reg 	[1:0]						debug_row_cnt_href_reg;
	reg  	[11:0]						debug_row_cnt/*synthesis PAP_MARK_DEBUG="true"*/;	
	reg 	[7:0]						din_reg[3:0];
	reg		[3:0]						href_reg;
	reg		[3:0]						vref_reg;
	reg 	[MEM_DQ_WIDTH*8-1:0]		burst_data_reg;
	reg 	[COL_CNT_WIDTH:0]			col_cnt/*synthesis PAP_MARK_DEBUG="true"*/;
	
	assign vref_pose = vref_reg == 4'b0111;
	assign fifo_rst = !rst_n || vref_reg[3];
	
	//dvp interface signal synchronous
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			din_reg[0] <= 'd0;
			din_reg[1] <= 'd0;
			din_reg[2] <= 'd0;
			href_reg <= 'd0;
			vref_reg <= 'd0;
		end
		else begin
			din_reg[0] 	<= dvp_din;
			din_reg[1] 	<= din_reg[0];
			din_reg[2] 	<= din_reg[1];
			din_reg[3] 	<= din_reg[2];
			href_reg   	<= {href_reg[2:0],dvp_href};
			vref_reg	<= {vref_reg[2:0],dvp_vref};
		end
	end
	
	//frame count
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			frame_cnt <= 4'd0;
		end
		else begin
			if(vref_pose) frame_cnt <= frame_cnt == FRAME_EN_VALUE ? frame_cnt : frame_cnt + 4'd1;
		end
	end
	
	wire 								frame_en;
	assign frame_en = frame_cnt == FRAME_EN_VALUE;
	
	reg 	[PIXEL_DATA_WIDTH-1:0 ]		pix_reg;
	reg 	[PIX_CNT_WIDTH-1:0    ]		pix_valid_cnt;
	
	// data counter and shift register
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			pix_valid_cnt	<= 'd0;
			pix_reg 		<= 'hf;
		end
		else begin
			if(href_reg[3]) begin
				pix_reg 		<= {pix_reg[7:0],din_reg[3]};
				pix_valid_cnt 	<= pix_valid_cnt + 1'b1;
			end
			else begin
				pix_reg 		<= {PIXEL_DATA_WIDTH{1'b1}};
				pix_valid_cnt 	<= 'd0;
			end
		end
	end
	
	reg 	pix_valid_flag;
	
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			pix_valid_flag	<= 1'b0;
		end
		else begin
			pix_valid_flag <= pix_valid_cnt == PIX_CNT_VALUE - 1 && frame_en;
		end
	end
	
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			burst_data_reg <= 'd0;
			col_cnt <= 'd0;
		end
		else begin
			if(vref_pose) begin
				col_cnt <= 'd0;
			end
			else if(pix_valid_flag) begin
				burst_data_reg <= {pix_reg,burst_data_reg[MEM_DQ_WIDTH*8-1:PIXEL_DATA_WIDTH]};
				col_cnt <= col_cnt == COL_CNT_MAX_VAL - 1 ? 'd0 : col_cnt + 1'b1;
			end
		end	
	end
	
	
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			debug_row_cnt <= 'd0;
			debug_row_cnt_href_reg <= 'd0;
		end
		else begin	
			if(vref_pose) begin
				debug_row_cnt <= 'd0;
			end
			else if(debug_row_cnt_href_reg == 2'b10) begin
				debug_row_cnt <= debug_row_cnt == HEIGHT ? 'd0 : debug_row_cnt + 1'b1;
			end
			debug_row_cnt_href_reg <= {debug_row_cnt_href_reg[0],href_reg[2]};
		end
	end
	
	wire 							afifo_wr_en;
	reg 							dfifo_wr_en;
	
	assign afifo_wr_en = col_cnt[6:0] == 7'd127 && !afifo_full && pix_valid_flag;
	
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			dfifo_wr_en <= 'd0;
		end
		else begin	
			dfifo_wr_en <= col_cnt[3:0] == 4'd15 && !dfifo_full && pix_valid_flag;
		end
	end
	
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			axi_addr_cal <= 'd0;
		end
		else begin	
			if(vref_pose) begin
				axi_addr_cal <= 'd0;
			end
			else if(afifo_wr_en) begin
				axi_addr_cal <= axi_addr_cal + 1'b1;
			end
		end
	end
	
	//由于地址计算的组合逻辑比较深所以需要打一拍
	reg 	[MEM_DQ_WIDTH*8-1:0]	dfifo_din;
	always@(posedge dvp_pclk) begin
		if(!rst_n) begin
			afifo_din <= 'd0;
			afifo_wrreq <= 'd0;
			dfifo_wrreq <= 'd0;
			dfifo_din <= 'd0;
		end
		else begin
			afifo_din <= axi_addr_cal * AXI_ADDR_STEP_VAL;
			afifo_wrreq <= afifo_wr_en;
			dfifo_wrreq <= dfifo_wr_en;
			dfifo_din <= burst_data_reg;
		end
	end
	
	
	//--------------- AXI bus write address and data control channel ---------------
	
	parameter 	IDLE 		= 2'b00	, ADDR_SEND = 2'b01		, 
				DATA_SEND 	= 2'b11	, END 		= 2'b10		;
	
	reg 	[1:0]			axi_cur_st,axi_nex_st;
	
	wire 					afifo_rdreq,dfifo_rdreq;
	wire 					afifo_den_n,dfifo_den_n;
	wire 	[7:0]			afifo_rd_wl,dfifo_rd_wl;
	wire 	[23:0]			afifo_do;
	wire 	[MEM_DQ_WIDTH*8-1:0] dfifo_do;
	wire 					axi_send_en;
	reg						axi_send_en_reg;
	
	assign	axi_wdata = dfifo_do;
	assign 	axi_wstrb = {MEM_DQ_WIDTH{1'b1}};
	assign	axi_send_en = !afifo_den_n && !dfifo_den_n && dfifo_rd_wl >= 8'd8;
	assign	afifo_rdreq = axi_awvalid && axi_awready;
	assign	dfifo_rdreq = axi_wready && axi_wid == AXI_ID;
	
	always@(posedge axi_clk) begin
		axi_send_en_reg <= axi_send_en;
	end
	// 3-stage state machine of AXI bus control
	always@(*) begin
		axi_nex_st = axi_cur_st;
		case(axi_cur_st) 
			IDLE: 		begin 
				if (axi_send_en_reg) axi_nex_st = ADDR_SEND;
				else axi_nex_st = IDLE;
			end
			ADDR_SEND:	begin 
				if (afifo_rdreq) axi_nex_st = DATA_SEND;
				else axi_nex_st = ADDR_SEND;
			end
			DATA_SEND:	begin 
				if (axi_wlast) axi_nex_st = END;
				else axi_nex_st = DATA_SEND;
			end
			END:		begin 
				axi_nex_st = IDLE;
			end
			default:	begin
				axi_nex_st = IDLE;
			end
		endcase
	end
	
	always@(posedge axi_clk) begin
		if(!rst_n) begin
			axi_cur_st <= IDLE;
		end
		else begin
			axi_cur_st <= axi_nex_st;
		end
	end
	
	always@(posedge axi_clk) begin
		if(!rst_n) begin
			axi_awvalid <= 1'b0;
			axi_awid   <=4'd0;
			axi_awlen <= 4'd0;
			axi_awaddr <= 'd0;
		end
		else begin
			if (axi_cur_st == ADDR_SEND) begin
				if(axi_awvalid && axi_awready) begin
					axi_awvalid <= 1'b0;
					axi_awid   <=4'd0;
					axi_awlen <= 4'd0;
					axi_awaddr <= 'd0;
				end
				else begin
					axi_awvalid <= 1'b1;
					axi_awid   <= AXI_ID;
					axi_awlen <=  AXI_WLEN - 4'd1;
					axi_awaddr <= {4'd0,afifo_do} + write_buffer_offset;
				end
			end
			else begin 
				axi_awvalid <= 1'b0;
				axi_awid   <=4'd0;
				axi_awlen <= 4'd0;
				axi_awaddr <= 'd0;
			end
		end
	end
	
	//fifo instance
	fifo_256b6d dfifo (
		  .wr_data			(dfifo_din		),    	// input [255:0]
		  .wr_en			(dfifo_wrreq	),   	// input
		  .wr_clk			(dvp_pclk		),   	// input
		  .full				(dfifo_full		),    	// output
		  .wr_rst			(fifo_rst		),   	// input
		  .almost_full		(				),   	// output
		  .wr_water_level	(				),    	// output [6:0]
		  .rd_data			(dfifo_do		),  	// output [255:0]
		  .rd_en			(dfifo_rdreq	),   	// input
		  .rd_clk			(axi_clk		),  	// input
		  .empty			(dfifo_den_n	),   	// output
		  .rd_rst			(fifo_rst		),     	// input
		  .almost_empty		(				),		// output
		  .rd_water_level	(dfifo_rd_wl	)     	// output [6:0]
	);

	fifo_24b6d afifo (
		  .wr_data			(afifo_din		), 		// input [23:0]
		  .wr_en			(afifo_wrreq	), 		// input
		  .wr_clk			(dvp_pclk		),		// input
		  .full				(afifo_full		),  	// output
		  .wr_rst			(fifo_rst		),		// input
		  .almost_full		(				),      // output
		  .rd_data			(afifo_do		), 		// output [23:0]
		  .rd_en			(afifo_rdreq	),   	// input
		  .rd_clk			(axi_clk		), 		// input
		  .empty			(afifo_den_n	),		// output
		  .rd_rst			(fifo_rst		),   	// input
		  .almost_empty		(				)     	// output
	);
endmodule