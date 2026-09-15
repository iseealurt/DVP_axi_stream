`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 协议检查器（独立 binder 模块）
//   - 端口名与被测模块的 AXI4-Lite 端口一致，全部为 input，
//     通过 `bind <dut> vrf_axil_chk u_vrf_axil_chk (.*);` 挂接到 DUT，不侵入 RTL
//   - 检查项：
//       1) 复位期间不得有响应
//       2) 总线信号不得出现 X/Z
//       3) 握手稳定性：valid 拉高后载荷保持不变，直至对应 ready 到来
//       4) 通道协议：无请求不得有响应（B/R 不得凭空出现）
//       5) 响应合法性：resp 只能取 OKAY/SLVERR/DECERR，AXI4-Lite 不得出现 EXOKAY
//       6) 超时检测：握手停滞超过门限即报错
//   - 属性按 formal 友好的形式编写，可直接被形式化工具复用
//   - 通过/失败次数累计到 vrf_axil_ctrl，供报告统计
// =============================================================================
module vrf_axil_chk #(
  parameter int AWIDTH  = 32,
  parameter int DWIDTH  = 32,
  parameter int IDWIDTH = 4
)(
  input wire                aclk,
  input wire                aresetn,
  input wire                awvalid,
  input wire [AWIDTH-1:0]   awaddr,
  input wire [2:0]          awport,
  input wire                awready,
  input wire                wvalid,
  input wire [DWIDTH-1:0]   wdata,
  input wire [DWIDTH/8-1:0] wstrb,
  input wire                wready,
  input wire                bvalid,
  input wire                bready,
  input wire [IDWIDTH-1:0]  bid,
  input wire [1:0]          bresp,
  input wire                arvalid,
  input wire [AWIDTH-1:0]   araddr,
  input wire [2:0]          arport,
  input wire                arready,
  input wire                rvalid,
  input wire                rready,
  input wire [DWIDTH-1:0]   rdata,
  input wire [1:0]          rresp,
  input wire [IDWIDTH-1:0]  rid
);
  import vrf_axil_pkg::*;

  // 检查总闸：连通性自检期间与显式关闭检查时全部挂起
  wire gating = vrf_axil_ctrl::bringup_active || !vrf_axil_ctrl::checks_enable;

  // ---------------------------------------------------------------------
  // 事务挂起计数：无请求不得有响应
  // ---------------------------------------------------------------------
  int  wr_pend = 0;
  int  rd_pend = 0;
  bit  wr_inc, wr_dec, rd_inc, rd_dec;

  assign wr_inc = awvalid && awready && wvalid && wready;
  assign wr_dec = bvalid && bready;
  assign rd_inc = arvalid && arready;
  assign rd_dec = rvalid && rready;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_pend <= 0;
      rd_pend <= 0;
    end else begin
      if (wr_inc && !wr_dec)      wr_pend <= wr_pend + 1;
      else if (!wr_inc && wr_dec) wr_pend <= wr_pend - 1;
      if (rd_inc && !rd_dec)      rd_pend <= rd_pend + 1;
      else if (!rd_inc && rd_dec) rd_pend <= rd_pend - 1;
    end
  end

  // ---------------------------------------------------------------------
  // 握手停滞计数：超时检测
  // ---------------------------------------------------------------------
  int aw_stuck = 0, w_stuck = 0, ar_stuck = 0, b_stuck = 0, r_stuck = 0;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_stuck <= 0; w_stuck <= 0; ar_stuck <= 0; b_stuck <= 0; r_stuck <= 0;
    end else begin
      aw_stuck <= (awvalid && !awready) ? aw_stuck + 1 : 0;
      w_stuck  <= (wvalid  && !wready)  ? w_stuck  + 1 : 0;
      ar_stuck <= (arvalid && !arready) ? ar_stuck + 1 : 0;
      b_stuck  <= (bvalid  && !bready)  ? b_stuck  + 1 : 0;
      r_stuck  <= (rvalid  && !rready)  ? r_stuck  + 1 : 0;
    end
  end

  // ---------------------------------------------------------------------
  // 1) 复位期间不得有响应
  // ---------------------------------------------------------------------
  property p_reset_no_resp;
    @(posedge aclk) disable iff (gating)
    !aresetn |-> (!bvalid && !rvalid);
  endproperty
  assert property (p_reset_no_resp)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 复位期间出现 B/R 响应"); end

  // ---------------------------------------------------------------------
  // 2) 总线信号不得出现 X/Z
  // ---------------------------------------------------------------------
  property p_no_xz;
    @(posedge aclk) disable iff (gating)
    !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
                 arvalid, arready, rvalid, rready,
                 awaddr, araddr, wdata, wstrb, rdata, bresp, rresp, bid, rid,
                 awport, arport});
  endproperty
  assert property (p_no_xz)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 总线出现 X/Z 未知态"); end

  // ---------------------------------------------------------------------
  // 3) 握手稳定性检查
  // ---------------------------------------------------------------------
  property p_aw_stable;
    @(posedge aclk) disable iff (gating || !aresetn)
    (awvalid && !awready) |=> (awvalid && $stable(awaddr) && $stable(awport));
  endproperty
  assert property (p_aw_stable)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AW 通道握手期间地址不稳定或 valid 提前撤销"); end

  property p_w_stable;
    @(posedge aclk) disable iff (gating || !aresetn)
    (wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb));
  endproperty
  assert property (p_w_stable)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] W 通道握手期间数据/选通不稳定或 valid 提前撤销"); end

  property p_ar_stable;
    @(posedge aclk) disable iff (gating || !aresetn)
    (arvalid && !arready) |=> (arvalid && $stable(araddr) && $stable(arport));
  endproperty
  assert property (p_ar_stable)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AR 通道握手期间地址不稳定或 valid 提前撤销"); end

  property p_b_stable;
    @(posedge aclk) disable iff (gating || !aresetn)
    (bvalid && !bready) |=> (bvalid && $stable(bresp) && $stable(bid));
  endproperty
  assert property (p_b_stable)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] B 通道握手期间响应载荷不稳定或 valid 提前撤销"); end

  property p_r_stable;
    @(posedge aclk) disable iff (gating || !aresetn)
    (rvalid && !rready) |=> (rvalid && $stable(rdata) && $stable(rresp) && $stable(rid));
  endproperty
  assert property (p_r_stable)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] R 通道握手期间数据/响应不稳定或 valid 提前撤销"); end

  // ---------------------------------------------------------------------
  // 4) 通道协议：无请求不得有响应
  // ---------------------------------------------------------------------
  property p_b_needs_req;
    @(posedge aclk) disable iff (gating || !aresetn)
    bvalid |-> (wr_pend > 0);
  endproperty
  assert property (p_b_needs_req)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 无写请求却出现 B 响应"); end

  property p_r_needs_req;
    @(posedge aclk) disable iff (gating || !aresetn)
    rvalid |-> (rd_pend > 0);
  endproperty
  assert property (p_r_needs_req)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 无读请求却出现 R 响应"); end

  // ---------------------------------------------------------------------
  // 5) 响应合法性
  // ---------------------------------------------------------------------
  property p_rresp_legal;
    @(posedge aclk) disable iff (gating || !aresetn)
    rvalid |-> (rresp inside {OKAY, SLVERR, DECERR});
  endproperty
  assert property (p_rresp_legal)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] R 响应编码非法（AXI4-Lite 仅允许 OKAY/SLVERR/DECERR）"); end

  property p_bresp_legal;
    @(posedge aclk) disable iff (gating || !aresetn)
    bvalid |-> (bresp inside {OKAY, SLVERR, DECERR});
  endproperty
  assert property (p_bresp_legal)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] B 响应编码非法（AXI4-Lite 仅允许 OKAY/SLVERR/DECERR）"); end

  // ---------------------------------------------------------------------
  // 6) 超时检测
  // ---------------------------------------------------------------------
  property p_aw_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (awvalid && !awready) |-> (aw_stuck < vrf_axil_ctrl::timeout_cycles);
  endproperty
  assert property (p_aw_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AW 握手超时（%0d 周期未收到 awready）", aw_stuck); end

  property p_w_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (wvalid && !wready) |-> (w_stuck < vrf_axil_ctrl::timeout_cycles);
  endproperty
  assert property (p_w_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] W 握手超时（%0d 周期未收到 wready）", w_stuck); end

  property p_ar_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (arvalid && !arready) |-> (ar_stuck < vrf_axil_ctrl::timeout_cycles);
  endproperty
  assert property (p_ar_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AR 握手超时（%0d 周期未收到 arready）", ar_stuck); end

  property p_b_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (bvalid && !bready) |-> (b_stuck < vrf_axil_ctrl::timeout_cycles);
  endproperty
  assert property (p_b_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] B 响应长时间未被接收"); end

  property p_r_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (rvalid && !rready) |-> (r_stuck < vrf_axil_ctrl::timeout_cycles);
  endproperty
  assert property (p_r_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] R 响应长时间未被接收"); end
endmodule

// -----------------------------------------------------------------------------
// 挂接：被测 DUT 与从机参考模型共用同一套协议检查器
//   编译期按测试选择 bind 目标（避免未实例化的目标产生未解析引用）：
//     库自测 demo   : +define+VRF_AXIL_BIND_REF
//     DVP2axi_stream: +define+VRF_AXIL_BIND_DVP2AXI
// -----------------------------------------------------------------------------
`ifdef VRF_AXIL_BIND_DVP2AXI
  bind DVP2axi_stream vrf_axil_chk u_vrf_axil_chk (. *);
`endif

`ifdef VRF_AXIL_BIND_REF
  bind vrf_axil_slv_ref vrf_axil_chk u_vrf_axil_chk (. *);
`endif
