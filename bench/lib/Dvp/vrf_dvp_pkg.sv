`timescale 1ns/1ps
// =============================================================================
// VRF_DVP —— DVP 数据通路验证组件（激励 / 帧级参考模型 / 覆盖率）
//
//   独立于 vrf_axil_pkg：这些组件持有 `virtual vrf_dvp_if`，而虚接口类型在
//   elaboration 期必须能解析到对应接口实例；把它们放进 AXI 库 package 会让
//   「不驱动 DVP 的用例」（如 tb_vrf_axil_demo / tb_vrf_axil_rst_window）
//   在加载阶段直接失败。因此按需单独 import 本 package。
//
//   依赖：接口位于 bench/lib/IF/vrf_dvp_if.sv，需与本文件处于同一编译单元
//         （vlog -mfcu）。
// =============================================================================
package vrf_dvp_pkg;
  // ------------------------------ 激励与参考模型 ------------------------------
  `include "../Dvp/vrf_dvp_driver.svh"
  `include "../Dvp/vrf_axis_frame_chk.svh"

  // ------------------------------ 覆盖率 ------------------------------
  `include "../Dvp/vrf_dvp_cov.svh"
endpackage
