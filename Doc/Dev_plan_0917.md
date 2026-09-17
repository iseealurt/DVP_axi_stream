# VRF_AXI4L 下一阶段开发计划@20260917

## 背景与现状

0916 计划（库搭建 + DVP2axi_stream 寄存器块接入）已全部完成并验收通过：两个用例 PASSED、功能覆盖率 100%（可达 bin 37/37）、5 种子回归全绿。本计划依据 0917 对 bench 全量代码的审阅结论制定，目标是：**先修缺陷、再收通用性、然后加深验证、最后扩范围**。

## 范围与边界

1. 阶段一~三仍在「AXI4-Lite 寄存器接口」范围内推进，不改 RTL 数据通路。
2. `bench/abandoned/` 不参与任何工作。
3. 阶段四（AXI-Stream / DVP 激励）以 RTL 数据通路实现为前置条件，本计划只定义任务与接口约定，不排定启动条件以外的时间点。
4. 沿用 0916 总体约定：不引入 UVM、命名前缀 vrf_axil_*、组件以 mailbox 串联、完成计数式结束判据。

## 审阅发现的问题清单

### A. 潜在缺陷（须修复）

| # | 位置 | 问题 |
|---|---|---|
| A1 | `bench/lib/Mon/vrf_axil_monitor.svh` main_loop | 复位发生在「AW 已握手、W 未握手」窗口时，`aw_pend/w_pend` 滞留到复位后，新事务的 W 会被错误配对到旧 AW 地址（当前用例未覆盖该窗口，未暴露） |
| A2 | `bench/lib/Seq/vrf_axil_sequencer.svh` run | 三路 mailbox 均空时 `#1ns` 空转轮询，长时间空闲场景空耗时序，且把粒度耦合进 1ns |
| A3 | `bench/lib/Reg/vrf_axil_regmodel.svh` | `mirror` 与 `vrf_axil_wstrb_apply` 硬编码 32 位/4 strb，DWIDTH≠32 时静默失效（slave 模型有 `$fatal`，模型没有） |

### B. DUT 相关假设残留（违背库解耦原则）

| # | 位置 | 问题 |
|---|---|---|
| B1 | `bench/lib/Env/vrf_axil_scoreboard.svh` compare | `obs_id !== '0` 即判失败，"ID 恒 0"是本 DUT 特性，应移入 cfg |
| B2 | `bench/lib/Reg/vrf_axil_regmodel.svh` predict_resp | 恒返回 OKAY、未映射读返回 0，应做成 per-map 可配置 |
| B3 | `bench/lib/Reg/vrf_axil_regmodel.svh` | CTRL 副作用的 7 个偏移（off_ctrl 等）是 DVP2AXI 专属，应按 map 注册 |
| B4 | `bench/lib/Cov/vrf_axil_cov.svh` | SLVERR/DECERR/非 0 ID 的 ignore_bins 与 cp_addr 地址区间写死，接新 DUT 易漏改（README 已自列为风险） |

### C. 工程与组织问题

| # | 位置 | 问题 |
|---|---|---|
| C1 | `bench/lib/Pkg/vrf_axil_txn.svh` | `txn_mst_id`（randc）从未被驱动到总线，是死代码 |
| C2 | `bench/lib/Pkg/vrf_axil_types.svh` | conn_h/ctrl/done_ctrl/direct_lib 全 static，同仿真仅支持单 env 单 DUT |
| C3 | done_ctrl.pending | ++/-- 散布 5 处，scoreboard 内还有 <0 钳位防御，配平脆弱 |
| C4 | `bench/tb/tb_dvp2ax_stream.sv` | 13 个定向 phase 直调 env.submit，与 demo 的 direct_lib 注册机制两套风格并存，无法按名单跑 |
| C5 | `bench/scripts/regression.ps1` | 每个种子重复完整编译；无 vcover merge 累积覆盖率 |
| C6 | `bench/tb/tb_dvp2ax_stream.sv` inject_event | 层次化 force 依赖 RTL 内部信号名，RTL 重构即断 |

## 四阶段落地计划

### 阶段一（P0）：缺陷修复与库通用性收尾

目标：消除 A 类缺陷，剥离 B 类 DUT 假设，库本体对「新 DUT 接入」做到零修改。

1. 修 A1：monitor main_loop 检测 `!mnt_vif.arstn` 时清空 aw_pend/w_pend/ar_pend 及暂存寄存器；补一个「AW/W 窗口期复位」定向用例复现并回归。
2. 修 A2：sequencer 空转改为 `@(aclk)` 节拍轮询（接口时钟经 conn_h 获取），去除 1ns 粒度耦合。
3. 修 A3：regmodel 参数化数据位宽（`vrf_axil_regmodel #(DWIDTH)`），wstrb_apply 宽度派生；构造时 DWIDTH≠32 且未参数化时 `$fatal`。
4. B1：cfg 增加 `exp_id_check` / `exp_id_value`，scoreboard 改为按 cfg 判定。
5. B2：寄存器描述增加 `unmap_resp` / `unmap_rdata` 字段，predict_resp/predict_read 按 map 配置返回。
6. B3：CTRL 副作用改为回调注册表（`special_cb[offset]`），build_dvp2axi_stream_map 内注册，通用模型本体不含 DUT 偏移。
7. B4：覆盖率 covergroup 增加构造参数（`has_err_resp` / `has_id` / 地址区间上下限），ignore_bins 用 `iff` 条件化；cfg 增加对应能力开关，env 构造 cov 时注入。
8. C1：删除 `txn_mst_id`（或补全驱动，本轮判定为删除——AXI4-Lite 无 ID 请求信号）。
9. C3：done_ctrl 封装 `raise()/drop()` 方法，替换全部散置 ++/--，保留钳位作为断言告警而非静默修正。

#### 阶段一验收清单

缺陷修复与解耦项（逐项验证）：

- [ ] A1：构造「AW 已握手、W 未握手时拉复位」场景，修复前可复现 W 与旧 AW 地址错配（复现记录留存）；修复后新事务正确配对。
- [ ] A1：新增「AW/W 窗口期复位」定向用例 PASSED，并纳入回归种子集。
- [ ] A2：空闲窗口内 sequencer 无 `#1ns` 轮询路径，节拍唤醒仅由 `@(aclk)` 驱动；时钟经 conn_h 获取，无粒度硬编码。
- [ ] A3：`vrf_axil_regmodel #(DWIDTH)` 参数化生效；DWIDTH≠32 且未参数化时构造期 `$fatal`；wstrb_apply 位宽按 DWIDTH 派生并有佐证用例。
- [ ] B1：cfg 新增 `exp_id_check`/`exp_id_value`，scoreboard 判定全部来自 cfg，硬编码 `obs_id !== '0'` 移除。
- [ ] B2：寄存器描述新增 `unmap_resp`/`unmap_rdata` 字段，predict 行为按 map 返回（默认值维持现状：OKAY/0）。
- [ ] B3：CTRL 副作用迁移至 `special_cb[offset]` 回调注册表，由 build_dvp2axi_stream_map 注册；regmodel 本体无 DUT 专属偏移常量。
- [ ] B4：covergroup 构造参数（`has_err_resp`/`has_id`/地址区间上下限）生效，ignore_bins 以 `iff` 条件化；风险 1 的 ModelSim 最小验证用例先行执行并留存结论（支持则 iff 方案，不支持则编译期生成方案并记录）。
- [ ] C1：`txn_mst_id` 删除，全库 grep 无残留引用。
- [ ] C3：done_ctrl 封装 `raise()/drop()`，全库无散置 `pending++/--`；钳位改为断言告警并以注入自测验证一次。

总体门禁：

- [ ] `tb_vrf_axil_demo`、`tb_dvp2ax_stream` PASSED 不回退（比对项数/断言计数允许因机制变化偏移，须在报告中解释原因）。
- [ ] 5 种子回归全绿（含新增复位窗口用例）。
- [ ] 功能覆盖率可达 bin ≥ 37/37（口径未变化时）。
- [ ] grep 确认库本体（IF/Pkg/Drv/Mon/Slv/Cov/Env/Chk）无 "DVP2AXI"/"dvp2axi" 字样（Reg 的 build_dvp2axi_stream_map 与 tb 除外）。
- [ ] 编译与仿真 0 错误 0 告警。

### 阶段二（P1）：寄存器验证深度

目标：从「证明功能正常」推进到「证明异常可检」。

1. 负面激励：slave 参考模型与 regmodel 支持 SLVERR 注入（按 map 配置未映射地址返回 SLVERR），新增定向用例验证 DUT 错误响应路径；覆盖率移除对应 ignore_bins 并确认新 bin 命中。
2. 压力场景：新增 back-to-back 模式（delay_min=max=0）与 AW/W 大跨度乱序扫频（aw_delay/w_delay 0~20 随机），加入回归种子集。
3. C4：tb_dvp2ax_stream 的 13 个定向 phase 迁移到 direct_lib 注册机制，支持 `cfg.directed_case` 按名单跑；建立 smoke（复位默认+RW 回读+wstrb）/ nightly（全部）两级用例表。
4. C6：inject_event 改为 bind 注入口或 RTL 侧 `` `ifdef VRF_TESTPOINT `` 测试点，消除对内部信号名的硬依赖（与 RTL 维护者约定命名后落地）。

#### 阶段二验收清单

- [ ] 负面激励：slave 参考模型与 regmodel 支持按 map 配置未映射地址返回 SLVERR；新增定向用例验证 DUT 错误响应路径被正确检出与比对（含失败报告链路触发）。
- [ ] 负面激励：覆盖率移除 SLVERR ignore_bins 后新 bin 命中（UCDB 可查），新口径与可达 bin 总数在报告中记录。
- [ ] 压力场景：back-to-back（delay_min=max=0）与 AW/W 大跨度乱序扫频（aw_delay/w_delay 0~20 随机）加入回归种子集，5 种子 PASSED。
- [ ] C4：13 个定向 phase 全部迁移 direct_lib 注册机制，tb 内不再直调 env.submit；`+directed_case=smoke` 单独可跑、默认跑 nightly 全量，名单外用例可按名追加。
- [ ] C4：smoke（复位默认 + RW 回读 + wstrb）/ nightly（全部）两级用例表建立并写入文档。
- [ ] C6：inject_event 改为 bind 注入口或 `` `ifdef VRF_TESTPOINT `` 测试点，tb 不再依赖 RTL 内部信号层次路径；若 RTL 冻结保留 force，须在报告「已知限制」登记。
- [ ] 两用例不回退，功能覆盖率在新口径下 100%（可达 bin），0 错误 0 告警。

### 阶段三（P2）：回归与覆盖率工程化

1. C5：regression.ps1 重构为「一次编译 + 多种子 vsim」，编译产物复用；每轮结束 `vcover merge` 累积 UCDB，summary.txt 追加累积覆盖率行。
2. 代码覆盖率纳入门禁：解析 UCDB 的 statement/branch 覆盖率写入 summary，设初始阈值（建议 statement≥95%、branch≥90%），未达标判回归失败。
3. Makefile 实机验证（本机无 make 的历史遗留项），或提供等价的 pwsh 单入口脚本并互验。
4. CI 集成：regression.ps1 接入流水线，summary.txt 与合并 UCDB 作为门禁产物上传。

#### 阶段三验收清单

- [ ] regression.ps1 重构为「一次编译 + 多种子 vsim」，编译产物复用；报告中给出阶段前后回归总耗时对比数据。
- [ ] 每轮结束 `vcover merge` 累积 UCDB，summary.txt 追加累积覆盖率行，多轮合并值 ≥ 单轮值。
- [ ] 代码覆盖率纳入门禁：summary.txt 输出 statement/branch 覆盖率，阈值 statement≥95%、branch≥90% 落地；未达标判回归失败，并有构造触发一次的验证记录。
- [ ] 既有回归防护不回退：退出码校验、陈旧报告、零检查项、超时、轮次数判定均正常。
- [ ] Makefile 实机验证逐目标通过；或提供等价 pwsh 单入口脚本并与 Makefile 互验一致（结论写入报告）。
- [ ] CI 接入：regression.ps1 在流水线跑通，summary.txt 与合并 UCDB 作为门禁产物上传，门禁绿留痕（无流水线环境时以本地模拟 CI 步骤 + 产物检查替代并登记为待办）。

### 阶段四（P3）：验证范围扩展（前置：RTL 数据通路实现）

1. 新增 `vrf_axis_*` 组件（if/txn/driver/monitor/cov），复用 conn_h 句柄表、cfg、scoreboard、报告框架；命名与分层对齐 vrf_axil_*。
2. DVP 侧时序激励发生器（pclk 域、vsync/href/pdin 帧格式可配），与 AXI-Stream monitor 做帧级端到端比对（像素重构 scoreboard）。
3. 跨时钟域检查：pclk/aclk 异步约束、CDC 相关断言纳入 chk。
4. 形式化：vrf_axil_chk 属性集抽出独立 formal 包，以 slave 参考模型 + assume 主机约束跑 SymbiYosys 有界证明；产出证明深度与覆盖率报告。

#### 阶段四验收清单

- [ ] `vrf_axis_*` 组件（if/txn/driver/monitor/cov）落地，命名与分层对齐 vrf_axil_*；conn_h 句柄表、cfg、scoreboard、报告框架为复用而非复制。
- [ ] DVP 激励发生器：pclk 域、vsync/href/pdin 帧格式可配，帧尺寸/行宽/行数可随机。
- [ ] 像素重构 scoreboard 帧级端到端比对 PASSED，含随机帧尺寸多种子回归。
- [ ] CDC：pclk/aclk 异步约束落地，相关断言纳入 chk 且回归 0 失败。
- [ ] formal：vrf_axil_chk 属性集抽出独立 formal 包，SymbiYosys 有界证明跑通，产出证明深度与覆盖率报告；指定界内无反例。

## 开发报告内容要求

每阶段结束后产出 `Doc/Dev_report_<MMDD>.md`，结构对齐 `Doc/Dev_report_0916.md`，以下为必备章节与要求：

1. **结论总览**：一句话结论 + 验收清单逐项对账表（验收项 / 结果（达成 / 带偏差达成 / 未达成）/ 证据索引）。计划验收清单中每一项必须出现，不得遗漏或合并。
2. **交付物清单**：本轮新增 / 修改 / 删除文件及路径，与上一报告做增量对照；含文件规模统计。
3. **验证结果**：用例统计（发起 / 比对 / 通过 / 失败 / 跳过、断言计数、连通性自检）、回归表（种子 / 检查数 / 失败数 / 判定）、功能覆盖率表（含可达口径与 ignore_bins 清单）。数据一律取自日志与 UCDB，不手填。
4. **与计划的偏差说明**：逐项列出「计划内容 / 实际实现 / 原因」，含未采纳的备选方案与理由；无偏差须显式写明「无」。
5. **调试定位与解决的问题**：过程中实际出现并修复的问题（现象 / 根因 / 解决），供后续复用。
6. **已知限制与遗留风险**：本轮未覆盖范围、登记的脆弱点、对后续阶段的影响。
7. **复验结果**：全部修正与评审意见落地后的最终复验表（命令 + 结果），报告结论必须与最后一次仿真一致。

通用要求：

- 每个「PASSED」结论附可复现命令（脚本 + 参数 + 种子）。
- 存在未达成或带偏差项时，报告整体标注「带偏差通过」，偏差项转入下一阶段计划或风险清单，不得静默遗留。
- 报告完成时，若本轮涉及 cfg / API 变更，同步修订 `Doc/API_VRF_AXI4L.md` 与 README（与「文档与同步」联动）。

## 风险与依赖

1. 阶段一第 7 项（covergroup 参数化 iff）依赖 ModelSim 2020.4 对 covergroup 参数的支持度，落地前先写最小验证用例确认；不支持则退化为「按能力开关生成不同 covergroup 定义」的编译期方案。
2. 阶段二第 4 项依赖 RTL 侧配合加测试点，若 RTL 冻结则保留 force 方案并登记为已知脆弱点。
3. 阶段四启动取决于 RTL 数据通路完成度，启动前需重审本阶段任务拆分。

## 文档与同步

1. 阶段一完成后同步修订 `Doc/API_VRF_AXI4L.md`（cfg 新字段、regmodel 参数化、覆盖率能力开关）与 README「库使用方式」「已知限制」两节。
2. 每阶段结束在 `Doc/` 追加 `Dev_report_<MMDD>.md`，章节结构与内容要求见「开发报告内容要求」，并按该阶段验收清单逐项对账。
