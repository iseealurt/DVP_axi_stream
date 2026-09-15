`timescale 1ns/1ps
// =============================================================================
// AXI4-Lite 协议检查器（独立 binder 模块）
//   - 端口名与被测模块的 AXI4-Lite 端口一致，全部为 input，
//     通过 `bind <dut> vrf_axil_chk u_vrf_axil_chk (.*);` 挂接到 DUT，不侵入 RTL
//   - 检查项：
//       1) 复位期间不得有响应
//       2) 总线信号不得出现 X/Z（握手/控制信号常检，载荷按对应 valid 门控）
//       3) 握手稳定性：valid 拉高后载荷保持不变，直至对应 ready 到来
//       4) 通道协议：无请求不得有响应（AW 与 W 独立计数，互不要求同拍）
//       5) 响应合法性：resp 只能取 OKAY/SLVERR/DECERR，AXI4-Lite 不得出现 EXOKAY
//       6) 超时检测：握手停滞超过门限即报错（门限取自 cfg.timeout_cycles，语义与诊断值逐拍对齐）
//   - 属性按 formal 友好的形式编写，可直接被形式化工具复用
//   - 通过/失败次数累计到 vrf_axil_ctrl，供报告统计
//   - 请求/响应计数只在复位时清零：它是「总线状态」而非「检查状态」，
//     一旦在挂起期间清零，恢复检查后到达的响应会被误判为「无请求的响应」；
//     握手停滞计数在复位或挂起时清零（挂起会引入非真实停滞，恢复后不应立刻误报超时）
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

  // 超时门限统一取自 vrf_axil_ctrl::timeout_cycles（由 cfg 注入，与 driver/bringup/monitor 同源）：
  // 0 表示「第一个停滞周期即报错」，语义与其他组件一致，因此不再提供模块级兜底参数
  function automatic int timeout_limit();
    return vrf_axil_ctrl::timeout_cycles;
  endfunction

  // ---------------------------------------------------------------------
  // 请求/响应挂起计数
  //   AXI4-Lite 的 AW 与 W 是独立通道，握手可发生在不同周期，
  //   因此必须分别累计；B 响应只在 AW 与 W 均已收到时才允许出现。
  //   计数器饱和在 0，避免非法响应把计数打成负数后连续漏检。
  // ---------------------------------------------------------------------
  int  aw_cnt = 0;   // 已接受的 AW 数减去已响应的 B 数
  int  w_cnt  = 0;   // 已接受的 W  数减去已响应的 B 数
  int  ar_cnt = 0;   // 已接受的 AR 数减去已完成的 R 数
  bit  aw_inc, aw_dec, w_inc, w_dec, ar_inc, ar_dec;

  assign aw_inc = awvalid && awready;
  assign aw_dec = bvalid && bready;
  assign w_inc  = wvalid && wready;
  assign w_dec  = bvalid && bready;
  assign ar_inc = arvalid && arready;
  assign ar_dec = rvalid && rready;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_cnt <= 0;
      w_cnt  <= 0;
      ar_cnt <= 0;
    end else begin
      if (aw_inc && !aw_dec)      aw_cnt <= aw_cnt + 1;
      else if (!aw_inc && aw_dec) aw_cnt <= (aw_cnt > 0) ? aw_cnt - 1 : 0;

      if (w_inc && !w_dec)        w_cnt <= w_cnt + 1;
      else if (!w_inc && w_dec)   w_cnt <= (w_cnt > 0) ? w_cnt - 1 : 0;

      if (ar_inc && !ar_dec)      ar_cnt <= ar_cnt + 1;
      else if (!ar_inc && ar_dec) ar_cnt <= (ar_cnt > 0) ? ar_cnt - 1 : 0;
    end
  end

  // ---------------------------------------------------------------------
  // 握手停滞计数：超时检测
  //   采样时刻 aw_stuck 记录的是「此前已连续停滞的周期数」，
  //   本拍停滞对应的真实停滞长度 = aw_stuck + 1，
  //   比较与诊断统一使用 aw_stuck + 1，保证门限语义与报错数值一致。
  // ---------------------------------------------------------------------
  int aw_stuck = 0, w_stuck = 0, ar_stuck = 0, b_stuck = 0, r_stuck = 0;

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn || gating) begin
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
  // 2) X/Z 检查
  //    握手/控制信号任何时刻不得为 X/Z；
  //    载荷只在对应 valid 有效时才要求已知（AXI 允许 idle 时载荷未定义）。
  // ---------------------------------------------------------------------
  property p_no_xz;
    @(posedge aclk) disable iff (gating)
    // 握手/控制信号：常检
    !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
                 arvalid, arready, rvalid, rready})
    // 载荷：按 valid 门控
    && (!awvalid || !$isunknown({awaddr, awport}))
    && (!wvalid  || !$isunknown({wdata, wstrb}))
    && (!bvalid  || !$isunknown({bresp, bid}))
    && (!arvalid || !$isunknown({araddr, arport}))
    && (!rvalid  || !$isunknown({rdata, rresp, rid}));
  endproperty
  assert property (p_no_xz)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 总线出现 X/Z 未知态（控制信号或有效载荷）"); end

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
    bvalid |-> (aw_cnt > 0 && w_cnt > 0);
  endproperty
  assert property (p_b_needs_req)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 无完整写请求却出现 B 响应（aw_cnt=%0d w_cnt=%0d）",
                      aw_cnt, w_cnt); end

  property p_r_needs_req;
    @(posedge aclk) disable iff (gating || !aresetn)
    rvalid |-> (ar_cnt > 0);
  endproperty
  assert property (p_r_needs_req)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] 无读请求却出现 R 响应（ar_cnt=%0d）", ar_cnt); end

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
  // 6) 超时检测（停滞长度 = 计数 + 1，与诊断值一致）
  // ---------------------------------------------------------------------
  property p_aw_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (awvalid && !awready) |-> ((aw_stuck + 1) <= timeout_limit());
  endproperty
  assert property (p_aw_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AW 握手超时（已停滞 %0d 周期未收到 awready）",
                      aw_stuck + 1); end

  property p_w_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (wvalid && !wready) |-> ((w_stuck + 1) <= timeout_limit());
  endproperty
  assert property (p_w_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] W 握手超时（已停滞 %0d 周期未收到 wready）",
                      w_stuck + 1); end

  property p_ar_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (arvalid && !arready) |-> ((ar_stuck + 1) <= timeout_limit());
  endproperty
  assert property (p_ar_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] AR 握手超时（已停滞 %0d 周期未收到 arready）",
                      ar_stuck + 1); end

  property p_b_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (bvalid && !bready) |-> ((b_stuck + 1) <= timeout_limit());
  endproperty
  assert property (p_b_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] B 响应长时间未被接收（已停滞 %0d 周期）",
                      b_stuck + 1); end

  property p_r_timeout;
    @(posedge aclk) disable iff (gating || !aresetn)
    (rvalid && !rready) |-> ((r_stuck + 1) <= timeout_limit());
  endproperty
  assert property (p_r_timeout)
    begin vrf_axil_ctrl::assert_chk_cnt++; end
    else begin vrf_axil_ctrl::assert_fail_cnt++;
               $error("[VRF_AXIL][CHK] R 响应长时间未被接收（已停滞 %0d 周期）",
                      r_stuck + 1); end
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
