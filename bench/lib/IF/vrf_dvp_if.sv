`timescale 1ns/1ps
// =============================================================================
// DVP 输入接口（pclk 域离散信号）
//
//   用于挂载 DVP 图像输入：pclk 由外部（顶层 tb）产生，pdin/pvref/phref 由
//   DVP 激励发生器（vrf_dvp_driver）驱动，DUT 端口在挂具内按名连接。
//
// 驱动与采样约定（同 vrf_axil_if）：
//   1) 时钟块 cb 只声明 input，仅用于采样与提供时钟沿事件，不作为驱动通路；
//   2) 接口内不写初值（无 initial），避免与使用者形成多进程驱动；
//   3) 驱动一律在 @(cb) 唤醒后直接赋值，落在 NBA 区，与被测同沿采样无竞争。
// =============================================================================
interface vrf_dvp_if #(
  parameter int DWIDTH = 8
)(
  input logic pclk
);
  logic [DWIDTH-1:0] pdin;    // 像素字节（字节串行，每 pclk 一拍）
  logic              pvref;   // 帧有效（极性由 DVP_CTRL.PVREF_POL 校正）
  logic              phref;   // 行有效（极性由 DVP_CTRL.PHREF_POL 校正）

  clocking cb @(posedge pclk);
    input pdin, pvref, phref;
  endclocking
endinterface
