# abandoned —— 已废弃的历史验证代码（非活跃资产）

本目录下的文件**不参与编译，不参与任何验证流程**，仅作历史留档。

| 文件 | 状态说明 |
|---|---|
| `if_axil.sv` | 早期 AXI4-Lite 接口草稿（三视角接口无 modport、`rst` 无驱动方），已被 `bench/lib/IF/vrf_axil_if.sv` 取代 |
| `if_axil_v0.sv` | 早期版本 `bench/IF/if_axil.sv` 的归档，内容已复用并扩展进 `bench/lib/IF/vrf_axil_if.sv` |
| `VRF_AXI4L_v0.sv` | 早期版本 `bench/Pkg/VRF_AXI4L.sv` 的归档，事务类已重构为 `bench/lib/Pkg/vrf_axil_txn.svh` |
| `AXI4-Lite.sv` | 早期 AXI4-Lite 从端参考实现（含已知缺陷：响应比对恒真、超时清理悬挂 ready/valid、零延时死循环等） |
| `tb_DVP2axi_stream.sv` | 早期 DVP2axi_stream 测试平台 v1 |
| `tb_DVP2axi_stream_v_1_0.sv` | 早期 DVP2axi_stream 测试平台 v1.0 |

## 使用约束

1. **不要**把这些文件加入 `bench/scripts/filelist.f`；它们不在编译列表中，当前也不会被编译。
2. 需要复用其中的任何代码片段时，请先修正已知缺陷再迁入 `bench/lib`。
3. 当前活跃的验证资产见 `bench/lib`（库本体）、`bench/tb`（用例）、`bench/scripts`（脚本），
   说明文档见 `Doc/API_VRF_AXI4L.md`、`Doc/Dev_plan_0916.md`、`Doc/Dev_report_0916.md`。

## 演进记录

- 20260915：库本体重构为 `bench/lib` 分层结构，本目录文件随之归档（详见 `Doc/Dev_report_0916.md`）。
