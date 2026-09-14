`timescale 1ns/1ps


module tb_DVP2axi_stream_v_1_0;
  // ------------------------------ Localparams ------------------------------
  localparam PERIOD_ACLK = 10; // 100MHz
  // ------------------------------ Parameters ------------------------------
  parameter DVP_DWIDTH = 8 ;
  parameter PIX_WIDTH = 16 ;
  parameter AXI_ID_WIDTH = 4 ;
  parameter AXI_STREAM_TID = 1 ;
  parameter AXI_STREAM_DWIDTH = 256 ;
  localparam AXI_STREAM_STRB_WIDTH = AXI_STREAM_DWIDTH/8 ;
  parameter AXI_STREAM_USER_WIDTH = 4 ;
  parameter AXI_STREAM_TDEST_WIDTH = 4 ;
  parameter AXI_LITE_DWIDTH = 32 ;
  localparam AXI_LITE_STRB_WIDTH = AXI_LITE_DWIDTH/8 ;
  parameter AXI_LITE_AWIDTH = 32 ;
  parameter AXI_LITE_BASE_ADDR_OFFSET = 32'h0000_0000 ;

  // ------------------------------ Imported packages ------------------------------
  import axil_test_pkg::*;
  
  // ------------------------------ Signals ------------------------------
  // AXI-Lite clock / reset
  logic aclk;
  logic aresetn;

  // ------------------------------ Packed Interfaces ------------------------------
  if_axil_aw#(AXI_LITE_AWIDTH) if_s_axil_aw (aclk);
  if_axil_dw#(AXI_LITE_DWIDTH) if_s_axil_dw (aclk);
  if_axil_ar#(AXI_LITE_AWIDTH) if_s_axil_ar (aclk);
  if_axil_dr#(AXI_LITE_DWIDTH) if_s_axil_dr (aclk);
  if_axil_wb#(AXI_ID_WIDTH) if_s_axil_wb (aclk);

  // ------------------------------ DUT ------------------------------
  DVP2axi_stream # (
    .DVP_DWIDTH(DVP_DWIDTH),
    .PIX_WIDTH(PIX_WIDTH),
    .AXI_ID_WIDTH(AXI_ID_WIDTH),
    .AXI_STREAM_TID(AXI_STREAM_TID),
    .AXI_STREAM_DWIDTH(AXI_STREAM_DWIDTH),
    .AXI_STREAM_USER_WIDTH(AXI_STREAM_USER_WIDTH),
    .AXI_STREAM_TDEST_WIDTH(AXI_STREAM_TDEST_WIDTH),
    .AXI_LITE_DWIDTH(AXI_LITE_DWIDTH),
    .AXI_LITE_AWIDTH(AXI_LITE_AWIDTH),
    .AXI_LITE_BASE_ADDR_OFFSET(AXI_LITE_BASE_ADDR_OFFSET)
  )
  DVP2axi_stream_inst (
    .pclk(),
    .prst_n(),
    .pdin(),
    .pvref(),
    .phref(),
    .aclk(aclk),
    .aresetn(aresetn),
    .awvalid(if_s_axil_aw.awvalid),
    .awaddr(if_s_axil_aw.awaddr),
    .awport(if_s_axil_aw.axif_awport),
    .awready(if_s_axil_aw.awready),
    .wvalid(if_s_axil_dw.wvalid),
    .wdata(if_s_axil_dw.wdata),
    .wstrb(if_s_axil_dw.wstrb),
    .wready(if_s_axil_dw.wready),
    .bready(if_s_axil_wb.bready),
    .bvalid(if_s_axil_wb.bvalid),
    .bid(if_s_axil_wb.axif_bid),
    .bresp(if_s_axil_wb.bresp),
    .arvalid(if_s_axil_ar.arvalid),
    .araddr(if_s_axil_ar.araddr),
    .arport(if_s_axil_ar.axif_arport),
    .arready(if_s_axil_ar.arready),
    .rready(if_s_axil_dr.rready),
    .rdata(if_s_axil_dr.rdata),
    .rresp(if_s_axil_dr.rresp),
    .rid(if_s_axil_dr.axif_rid),
    .rvalid(if_s_axil_dr.rvalid),
    .axis_tready(),
    .axis_tvalid(),
    .axis_tdata(),
    .axis_tstrb(),
    .axis_tkeep(),
    .axis_tlast()
  );

  
  // ------------------------------ Clock Signal ------------------------------
  initial begin
    aclk = 0;
    forever #PERIOD_ACLK aclk = ~aclk;
  end

  // ------------------------------ AXI resetn ------------------------------
  task global_reset(
    input bit rst_asrt ,
    input int duration ,
    output bit success 
  );
    begin
      aresetn = 1'b1;
      success = 1'b0;
      if(rst_asrt) begin
        $display("@ %0t ,[RESET] Reset asserted",$time);
        aresetn = 1'b0;
        repeat (duration) @(posedge aclk);
        aresetn = 1'b1;
        success = 1'b1;
      end
    end
  endtask

  
  endmodule