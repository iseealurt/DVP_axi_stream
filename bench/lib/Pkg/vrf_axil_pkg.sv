`timescale 1ns/1ps
// =============================================================================
// VRF_AXI4L —— AXI4-Lite 自建验证库
//   库本体与具体 DUT 解耦：接口层 / 事务层 / 组件层 / 寄存器模型 / 覆盖率 /
//   检查器 分文件组织，统一由本 package 汇聚，供测试用例 import 使用。
//
//   依赖：接口与挂钩宏位于 bench/lib/IF/vrf_axil_if.sv，
//         需与本文件处于同一编译单元（vlog -mfcu）。
// =============================================================================
package vrf_axil_pkg;
  // ------------------------------ 基础类型与全局控制 ------------------------------
  `include "../Pkg/vrf_axil_types.svh"

  // ------------------------------ 事务与配置 ------------------------------
  `include "../Pkg/vrf_axil_txn.svh"
  `include "../Pkg/vrf_axil_cfg.svh"

  // ------------------------------ 寄存器模型 ------------------------------
  `include "../Reg/vrf_axil_regmodel.svh"

  // ------------------------------ 序列与仲裁 ------------------------------
  `include "../Seq/vrf_axil_direct_lib.svh"
  `include "../Seq/vrf_axil_sequence.svh"
  `include "../Seq/vrf_axil_sequencer.svh"

  // ------------------------------ 覆盖率收集 ------------------------------
  `include "../Cov/vrf_axil_cov.svh"

  // ------------------------------ 组件 ------------------------------
  `include "../Mon/vrf_axil_monitor.svh"
  `include "../Env/vrf_axil_scoreboard.svh"
  `include "../Chk/vrf_axil_bringup.svh"
  `include "../Drv/vrf_axil_driver.svh"
  `include "../Env/vrf_axil_env.svh"
endpackage
