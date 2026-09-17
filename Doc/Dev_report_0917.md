# VRF_AXI4L 开发报告（0917 阶段一：缺陷修复与库通用性收尾）@20260917

对应开发计划：`Doc/Dev_plan_0917.md`（阶段一 P0，验收清单见该文件 §阶段一）
API 文档：`Doc/API_VRF_AXI4L.md`
仿真工具：ModelSim SE-64 2020.4（vlog/vsim/vcover 2020.10），PowerShell 5.1

---

## 1. 结论总览

**结论：阶段一验收清单全部达成（A 类缺陷 3 项已修并复现验证，B 类 DUT 假设 4 项已剥离，C 类工程问题中 C1/C3 已完成），两个既有用例与新增用例全部 PASSED、5 种子回归全绿、功能覆盖率 100.00%、编译与仿真 0 错误 0 告警、库本体已无任何 DUT 名。**

其中 **B4（覆盖率参数化）按计划风险 1 的预案降级落地**：实测 ModelSim 2020.4 不支持 covergroup 参数端口与运行期 `iff`，故改为「编译期能力开关生成不同 bin 定义 + cfg 声明一致性校验（不一致即 `$fatal`）」，并把地址区间改为按 cfg 归一为区间码；**A1 的定向用例为监视器级白盒用例**（原因见 §4 偏差 1）。

### 1.1 验收清单逐项对账

**缺陷修复与解耦项：**

| # | 验收项 | 结果 | 证据 |
|---|---|---|---|
| A1-1 | 构造「AW 已握手、W 未握手时拉复位」场景，修复前可复现地址错配（复现记录留存） | **达成** | §3.1 修复前记录：`写观测数…实际 1` FAIL + `第 1 笔写观测不得携带复位后新事务的写数据…` FAIL，结论 `SIMULATION FAILED`（`log_stage1_repro/`） |
| A1-2 | 新增「AW/W 窗口期复位」定向用例 PASSED，并纳入回归种子集 | **达成**（白盒，见 §4 偏差 1） | §3.2：12 / 12 检查 PASSED；§3.4：该用例 5 种子全绿 |
| A2 | 空闲窗口无 `#1ns` 轮询路径，节拍唤醒仅由 `@(aclk)` 驱动，时钟经连接表获取 | **达成** | `vrf_axil_sequencer.svh`：`clk_vif`（env 注入 + conn_h 兜底）+ `@(clk_vif.cb)`；grep 库内无 `#1ns`（仅 `env.connect()` 的「等待句柄发布」启动等待保留） |
| A3 | `vrf_axil_regmodel #(DWIDTH)` 生效；DWIDTH≠32 构造期 `$fatal`；wstrb_apply 按 DWIDTH 派生并有佐证 | **达成** | §3.3 探针：`WSTRB64` PASS（8 位选通作用于 64 位数据）、`PROBE_DW_GUARD` 如期 `$fatal`；`vrf_axil_wstrb_apply` 包级 32 位硬编码函数已并入类内静态方法 |
| B1 | cfg 新增 `exp_id_check`/`exp_id_value`，scoreboard 判定全部来自 cfg | **达成** | `vrf_axil_scoreboard.svh` 比对函数；硬编码 `obs_id !== '0` 已移除；grep 无残留 |
| B2 | 未映射访问行为按 map 可配（`unmap_resp`/`unmap_rdata`） | **达成**（建在 map 级字段而非寄存器描述，见 §4 偏差 4） | `build_dvp2axi_stream_map()` / `build_ref_slave_map()` 内显式设置；`predict_read`/`predict_resp` 按其返回 |
| B3 | CTRL 副作用迁移到 `special_cb[offset]` 回调注册表，DVP 偏移由 map 注册 | **达成** | `vrf_axil_wr_cb` 基类 + `vrf_axil_dvp2axi_ctrl_cb` + `reg_special_cb()`；原 7 个 `off_*` 字段与 `ctrl_side_effect` 已删除；DVP 用例的 `ph_ctrl_actions`/`ph_softrst_cmp` 全部通过 |
| B4 | covergroup 参数化 + `ignore_bins` 条件化；先写最小验证用例确认工具支持度 | **带偏差达成**（工具不支持 → 走计划风险 1 预案） | §3.3 探针给出三项工具限制证据；落地方案见 §4 偏差 5；覆盖率仍 100.00% |
| C1 | `txn_mst_id` 删除，全库无残留引用 | **达成** | grep `bench/lib`、`bench/tb`、`bench/scripts` 均无命中（`bench/abandoned/` 为历史留档，不参与编译） |
| C3 | done_ctrl 封装 `raise()/drop()`，钳位改为断言告警并以注入自测验证 | **达成** | 全库仅 `vrf_axil_types.svh` 内 `raise()/drop()` 修改 `pending`；探针 `PROBE_UNDERFLOW`/`PROBE_BALANCE` PASS |

**总体门禁：**

| # | 门禁 | 结果 | 证据 |
|---|---|---|---|
| 1 | 两个既有用例 PASSED 不回退 | **达成** | `tb_vrf_axil_demo` 285/285（与基线一致）；`tb_dvp2ax_stream` 539/539（跳过 1）；断言计数 7208 → 7214（原因见 §4 偏差 6） |
| 2 | 5 种子回归全绿（含新增用例） | **达成** | §3.4：三个用例各 5/5 PASSED |
| 3 | 功能覆盖率可达 bin ≥ 37/37 | **达成** | §3.3：UCDB 明细 40 个 bin 全命中、0 missing，覆盖率 100.00% |
| 4 | grep 库本体（IF/Pkg/Drv/Mon/Slv/Cov/Env/Chk）无 "DVP2AXI"/"dvp2axi" | **达成** | §3.5：命中 0 条（原 Pkg/Env/Slv/Chk 的 4 处已按 §4 偏差 7 处理） |
| 5 | 编译与仿真 0 错误 0 告警 | **达成** | 三个用例的 `Errors: 0, Warnings: 0`（编译期 + 仿真期） |

---

## 2. 交付物清单

### 2.1 新增

| # | 文件 | 说明 |
|---|---|---|
| 1 | `bench/tb/tb_vrf_axil_rst_window.sv`（246 行） | 「AW/W 窗口期复位」监视器靶向定向用例：直接驱动监视视角接口构造窗口，检查复位后的配对与半笔写上报 |
| 2 | `Doc/Dev_report_0917.md` | 本报告 |

### 2.2 修改（相对 0916 交付物）

| # | 文件 | 行数 | 修改内容 |
|---|---|---:|---|
| 1 | `bench/lib/Reg/vrf_axil_regmodel.svh` | 291 | A3（按 DWIDTH 参数化、wstrb_apply 入类、DWIDTH≠32 `$fatal`）、B2（`unmap_resp`/`unmap_rdata`）、B3（`vrf_axil_wr_cb` 基类 + DVP 回调 + `reg_special_cb` 注册表 + 事件偏移 map 化 + `build_map(name)`） |
| 2 | `bench/lib/Cov/vrf_axil_cov.svh` | 198 | B4：地址区间码归一（`region_of` + cfg 上下限）、能力开关（编译期 bin 生成 + cfg 一致性 `$fatal`）、口径说明随能力动态生成 |
| 3 | `bench/lib/Mon/vrf_axil_monitor.svh` | 244 | A1：复位清空挂起状态与暂存寄存器，并把「半笔写」作为被打断观测上报；暂存寄存器给初值；模型句柄按 DWIDTH 特化 |
| 4 | `bench/lib/Seq/vrf_axil_sequencer.svh` | 69 | A2：`clk_vif` + 按接口时钟节拍轮询（删除 `#1ns` 空转） |
| 5 | `bench/lib/Pkg/vrf_axil_cfg.svh` | 70 | B1（`exp_id_check`/`exp_id_value`）、B4（`has_err_resp`/`has_id`/`cov_addr_lo/hi`）、`reg_map` 默认改为空串并要求显式指定 |
| 6 | `bench/lib/Pkg/vrf_axil_types.svh` | 86 | 删除 `vrf_special_e`；C3：done_ctrl 增加 `raise()/drop()` 与下溢告警 |
| 7 | `bench/lib/Pkg/vrf_axil_txn.svh` | 160 | C1：删除 `txn_mst_id` |
| 8 | `bench/lib/Env/vrf_axil_scoreboard.svh` | 213 | B1（ID 判定按 cfg）、C3（改调 `drop()`）、模型句柄按 DWIDTH 特化 |
| 9 | `bench/lib/Env/vrf_axil_env.svh` | 248 | C3（`raise()`）、sequencer 时钟注入、`model.build_map(cfg.reg_map)` |
| 10 | `bench/lib/Seq/vrf_axil_sequence.svh` | 60 | C3（`raise()`） |
| 11 | `bench/lib/Chk/vrf_axil_bringup.svh` | 305 | 模型句柄按 DWIDTH 特化 |
| 12 | `bench/lib/Chk/vrf_axil_chk.sv` | 271 | bind 语句移出库本体（改由用例给出），库内不再出现 DUT 名 |
| 13 | `bench/tb/tb_vrf_axil_demo.sv` | 294 | 加入本用例的 bind（`VRF_AXIL_BIND_REF`） |
| 14 | `bench/tb/tb_dvp2ax_stream.sv` | 417 | 加入本用例的 bind（`VRF_AXIL_BIND_DVP2AXI`） |
| 15 | `bench/scripts/filelist.f` | 20 | 追加新用例文件 |
| 16 | `bench/scripts/run.ps1` | 228 | 新用例的工作库 `work_rstw` 与「不传 bind 目标」分支（`-Clean` 白名单同步） |
| 17 | `bench/scripts/regression.ps1` | 274 | `-Test` 白名单加入新用例 |
| 18 | `Doc/API_VRF_AXI4L.md` | 514 | 按 §文档与同步：cfg 新字段、regmodel 参数化与回调注册、覆盖率能力开关与区间码、bind 位置、新版接入步骤、新增用例命令 |
| 19 | `README.md` | 290 | 「库使用方式」「关键机制（覆盖率口径 / 仿真结束机制）」「已知限制」「目录结构 / 文档索引 / 验证结果」同步 |

### 2.3 删除

无（`bench/abandoned/` 与历史文档不动）。

---

## 3. 验证结果

> 以下数据取自各轮仿真日志与 UCDB（命令与种子随行给出），未手工填写。

### 3.1 A1 缺陷复现（修复前，证据留存）

```
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_rst_window -Clean -Seed 12345 -LogDir log_stage1_repro
```

```
[305000][CHECK-FAIL] 写观测数应为 2（窗口期被打断的半笔 + 复位后完整一笔），实际 1
[305000][CHECK-PASS] 第 1 笔写观测地址应为窗口期地址 0x8，实际 0x8
[305000][CHECK-FAIL] 第 1 笔写观测不得携带复位后新事务的写数据 0x33334444（地址与数据来自不同事务即为错配），实际 0x33334444
===============================================================
 监视器复位窗口用例结论 : FAILED
 检查 7 项, 通过 5 项, 失败 2 项
SIMULATION FAILED: 检查 7 项, 失败 2 项, 断言失败 0 项
```

复现机理：复位前 AW 已握手（地址 0x08）、W 未握手；复位后主循环未清空 `aw_pend`/`aw_addr`，
复位后的新写事务（地址 0x10、数据 0x33334444）的 W 与**旧地址 0x08** 配成一笔，
导致该笔观测既地址错配、又吞掉了复位后新事务（写观测数 1 < 2）。

### 3.2 A1 修复后复验

```
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_rst_window -Clean -Cover -Seed 12345 -LogDir log_stage1
```

```
[305000][CHECK-PASS] 写观测数应为 2（窗口期被打断的半笔 + 复位后完整一笔），实际 2
[305000][CHECK-PASS] 第 1 笔写观测不得携带复位后新事务的写数据 0x33334444（…），实际 0x00
[305000][CHECK-PASS] 第 1 笔写观测应标记为「被复位打断」（窗口期半笔写不得静默丢弃）
[305000][CHECK-PASS] 第 2 笔写观测地址应为复位后新地址 0x10，实际 0x10
[305000][CHECK-PASS] 第 2 笔写观测数据应为 0x33334444，实际 0x33334444
[305000][CHECK-PASS] 第 2 笔写观测字节选通应为 0101，实际 0101
===============================================================
 监视器复位窗口用例结论 : PASSED
 检查 12 项, 通过 12 项, 失败 0 项
SIMULATION PASSED: 检查 12 项, 失败 0 项, 断言失败 0 项
```

### 3.3 单用例与查证结果

| 用例 / 查证 | 命令 | 结果 |
|---|---|---|
| 库自测 | `run.ps1 -Test tb_vrf_axil_demo -Clean -Cover -Seed 12345` | PASSED：事务比对 285（285 通过 / 0 失败 / 0 跳过）+ 协议断言 5238（0 失败）+ 连通性自检 21；覆盖率 100.00%（采样 285）；编译与仿真 **0 错误 0 告警** |
| 接入示例 | `run.ps1 -Test tb_dvp2ax_stream -Clean -Cover -Seed 12345` | PASSED：事务比对 539（539 通过 / 0 失败 / 1 跳过）+ 协议断言 7214（0 失败）+ 连通性自检 21；覆盖率 100.00%（采样 539）；编译与仿真 **0 错误 0 告警** |
| 复位窗口用例 | `run.ps1 -Test tb_vrf_axil_rst_window -Clean -Seed 12345` | PASSED：12 / 12 检查；编译与仿真 **0 错误 0 告警** |
| 覆盖率明细（UCDB） | `vcover report -cvg -details log_stage1/tb_dvp2ax_stream.ucdb` | 覆盖组 `vrf_axil_cg`：**40 个 bin 全命中、0 missing、100.00%**；明细见下表 |
| 前端自检 | `check_env.ps1 -LogDir log` | 全部通过 |

**功能覆盖率明细（取自 UCDB）与排除清单：**

| 覆盖点 / 交叉 | 覆盖 bin 数（命中/总） | 覆盖率 | 排除的 bin（ignore_bins） |
|---|---|---:|---|
| `cp_dir`（读写方向） | 2 / 2 | 100.00% | — |
| `cp_addr`（地址区间码 0~5） | 6 / 6 | 100.00% | — |
| `cp_strb`（写方向字节选通） | 6 / 6 | 100.00% | `4'b0000`（结构非法） |
| `cp_resp`（响应类型） | 1 / 1 | 100.00% | `EXOKAY`（AXI4-Lite 不使用）；`SLVERR`/`DECERR`（能力开关关闭时排除） |
| `cp_id`（主机 ID） | 1 / 1 | 100.00% | `[1:15]`（能力开关关闭时排除） |
| `cp_ro`（只读访问） | 2 / 2 | 100.00% | — |
| `cp_unmapped`（未映射访问） | 2 / 2 | 100.00% | — |
| `cx_dir_addr` | 12 / 12 | 100.00% | — |
| `cx_dir_strb` | 6 / 6 | 100.00% | 读方向整列（读事务无字节选通语义） |
| `cx_dir_resp` | 2 / 2 | 100.00% | 异常响应列（同 `cp_resp`） |
| **合计** | **40 / 40** | **100.00%** | 0 missing |

> 计数口径说明：UCDB 展开后的覆盖 bin 数为 40（0916 报告中的「37」为其自身的记账口径），
> 本轮以 UCDB 实际明细为准：**40 个可达 bin 全命中、0 missing、覆盖率 100.00%**，满足「可达 bin ≥ 37/37」的门禁。
>
> 代码覆盖率（`-Cover` 同时开启）本轮仍不纳入门禁（属阶段三范围），本次测量值供阶段三设阈值参考：
> statement 100%、branch 86.20%、condition 59.25%、toggle（DUT 侧）8.93%、assertion 87.50%。

**编译期/运行期守卫的注入查证（临时探针用例，不纳入交付物）：**

探针源文件为临时文件（本机 `%TEMP%\vrf_covtest\tb_vrf_axil_probe.sv`，库内编译，不属于交付物；
同目录另有 `cov_param_probe.sv` / `cov_iff_probe.sv` / `cov_iff2_probe.sv` / `cov_wrap_probe.sv` 四个工具支持度探针）：

```
vlog -mfcu -cuname probe_cu -sv -work work_probe +define+VRF_AXIL_COV_HAS_ERR +define+VRF_AXIL_COV_HAS_ID \
     -f bench/scripts/filelist.f <临时探针 tb>
vsim -c -do "run -all; quit -f" work_probe.tb_vrf_axil_probe "+probe=1|2|3"
```

| 探针 | 期望 | 实测 |
|---|---|---|
| `+probe=1`：wstrb_apply 位宽派生 | 64 位数据 / 8 位选通独立成立 | `PROBE_WSTRB64 result=0xdeadbeef00005678 … PASS`；`PROBE_WSTRB32 result=0xaa22cc44 … PASS` |
| `+probe=1`：完成计数下溢告警（C3） | `drop()` 在 `pending=0` 时告警并计入断言失败 | `PROBE_UNDERFLOW pending=0 assert_fail_cnt=0→1 : PASS`（伴随 `[ERROR] 完成计数下溢…` 打印） |
| `+probe=1`：raise/drop 配平 | 计数归零且 `all_done` 置位 | `PROBE_BALANCE pending=0 all_done=1 : PASS` |
| `+probe=2`：regmodel 位宽守卫（A3） | DWIDTH≠32 构造期 `$fatal` | `** Fatal: [VRF_AXIL] vrf_axil_regmodel：内置寄存器映射按 32 位字定义，DWIDTH=64 未适配…` |
| `+probe=3`：能力开关生效与一致性守卫（B4） | 能力开时异常/非 0 ID bin 计入分母（覆盖率 < 100%）；cfg 与编译期开关不一致时 `$fatal` | `PROBE_CAP_ON_COV=27.50 (能力开、仅命中 okay/id0，期望 <100)`；随后 `** Fatal: [VRF_AXIL] 覆盖率能力开关不一致：cfg.has_err_resp=0，编译期 VRF_AXIL_COV_HAS_ERR=1…` |

**工具支持度最小验证（计划风险 1 的前置确认）：**

| 机制 | 实测结论 |
|---|---|
| `covergroup cg #(parameter bit X = 0) (…)` | **不支持**：`** Error: (vlog-13069) near "#": syntax error, unexpected '#', expecting ';'` |
| 类内声明 covergroup 类型并实例化 | **不支持**：`** Error: Variables of embedded Covergroup type 'cg_t' cannot be created.` |
| `ignore_bins … iff (<运行期静态开关>)` | 语法可编译，但条件在 elaboration 期固化（构造后再改开关不生效），且被排除的 bin 报 `** Warning: (vsim-8549) … converged to empty list` |

### 3.4 批量回归（三个用例 × 5 种子）

```
powershell -File bench/scripts/regression.ps1 -Test <用例> -Seeds "1,2,3,4,5" -LogDir log_stage1
```

| 用例 | 1 | 2 | 3 | 4 | 5 | 轮次 | 结论 |
|---|---|---|---|---|---|---|---|
| `tb_vrf_axil_demo` | 285/0/0 PASSED | 285/0/0 PASSED | 285/0/0 PASSED | 285/0/0 PASSED | 285/0/0 PASSED | 5 / 5 | REGRESSION PASSED |
| `tb_dvp2ax_stream` | 539/0/0 PASSED | 539/0/0 PASSED | 539/0/0 PASSED | 539/0/0 PASSED | 539/0/0 PASSED | 5 / 5 | REGRESSION PASSED |
| `tb_vrf_axil_rst_window` | 12/0/0 PASSED | 12/0/0 PASSED | 12/0/0 PASSED | 12/0/0 PASSED | 12/0/0 PASSED | 5 / 5 | REGRESSION PASSED |

（每格为 `检查项/失败项/断言失败项`；`Exit` 列全为 0。）

### 3.5 库本体解耦核对（grep）

| 检查 | 命令 | 结果 |
|---|---|---|
| 库本体无 DUT 名 | `Select-String -Path bench/lib/{IF,Pkg,Drv,Mon,Slv,Cov,Env,Chk,Seq}/* -Pattern dvp2axi,DVP2AXI,DVP2axi` | 命中 **0** 条（`Reg` 内 `build_dvp2axi_stream_map` 与回调类名按计划豁免） |
| 无 ID 死代码残留 | `Select-String -Path bench/lib/*/*,bench/tb/*,bench/scripts/* -Pattern txn_mst_id` | 命中 **0** 条 |
| 无散置完成计数 | `Select-String -Path bench/lib/*/*,bench/tb/* -Pattern "pending\s*(\+\+\|--\|\+=\|-=)"` | 仅 `vrf_axil_types.svh` 内 `raise()`/`drop()` 两处（封装点） |
| 无 1ns 粒度空转 | grep `#1ns` | 库内仅 `env.connect()` 等待句柄发布的启动等待（非仲裁空转路径） |

### 3.6 复验结果（全部改动落地后的最终一次）

| 项 | 命令 | 结果 |
|---|---|---|
| 库自测用例 | `run.ps1 -Test tb_vrf_axil_demo -Clean -Cover -Seed 12345 -LogDir log_stage1` | PASSED：285 比对 + 5238 断言 + 21 自检；覆盖率 100.00%；**0 错误 0 告警** |
| 接入示例 | `run.ps1 -Test tb_dvp2ax_stream -Clean -Cover -Seed 12345 -LogDir log_stage1` | PASSED：539 比对（跳过 1）+ 7214 断言 + 21 自检；覆盖率 100.00%；**0 错误 0 告警** |
| 复位窗口用例 | `run.ps1 -Test tb_vrf_axil_rst_window -Clean -Seed 12345 -LogDir log_stage1` | PASSED：12 / 12；**0 错误 0 告警** |
| 批量回归 | 三个用例各 `-Seeds "1,2,3,4,5"` | 15 / 15 轮次 PASSED，`exit=0` |
| 守卫注入查证 | 临时探针 `+probe=1|2|3` | 五项全部如期（见 §3.3） |
| 前端自检 | `check_env.ps1 -LogDir log` | 全部通过 |

---

## 4. 与计划的偏差说明

| # | 计划内容 | 实际实现 | 原因 |
|---|---|---|---|
| 1 | 「补一个 AW/W 窗口期复位定向用例复现并回归」 | 新增 `bench/tb/tb_vrf_axil_rst_window.sv`，为**监视器级白盒用例**：直接驱动监视视角接口构造窗口，不实例化 DUT，不使用 env/driver | 现有两台对端（`DVP2axi_stream` RTL 与 `vrf_axil_slv_ref`）都只在 `awvalid & wvalid` 同时有效时拉高 `awready/wready`（联合握手），因此「AW 已握手、W 未握手」这一协议合法窗口在全系统激励下不可达；缺陷本体位于监视器，白盒靶向可精确复现（§3.1）并回归。该用例已登记进 `filelist.f` / `run.ps1` / `regression.ps1`，纳入回归种子集 |
| 2 | A1「检测 `!arstn` 时清空 aw_pend/w_pend/ar_pend 及暂存寄存器」 | 清空之外，另把「仅 AW 或仅 W 握手的半笔写」作为 `obs_interrupted=1` 的观测上交计分板 | 只清空会让该笔事务不产生任何观测：完成计数无法配平（`wait_idle` 会空等到 `max_txn` 上限并告警），且总线活动被静默丢弃。上报后由计分板按 `expect_interrupt` 判为跳过，行为与既有复位用例一致 |
| 3 | A3「DWIDTH≠32 且未参数化时 `$fatal`」 | 统一为 **DWIDTH≠32 一律 `$fatal`**（内置 map 按 32 位字定义） | 「是否参数化」在类内不可判定；统一口径与从机参考模型既有的 32 位断言一致，且能覆盖「参数化了但没有改 map」的情形。另把包级 32 位硬编码函数 `vrf_axil_wstrb_apply` 并入类内静态方法（按 DWIDTH 派生） |
| 4 | B2「寄存器描述增加 `unmap_resp`/`unmap_rdata` 字段」 | 建在**模型（map 级）字段**上，由各 map 设置；`predict_read`/`predict_resp` 按其返回 | 未映射地址没有对应的寄存器描述对象（`find()` 返回 null），字段建在 desc 上无法被查到；map 级字段同样满足「per-map 可配置」的目标，且为阶段二的 SLVERR 注入留好配置点 |
| 5 | B4「covergroup 增加构造参数（has_err_resp/has_id/地址区间上下限），ignore_bins 用 `iff` 条件化」 | 走计划风险 1 的**编译期预案**：`+define+VRF_AXIL_COV_HAS_ERR` / `VRF_AXIL_COV_HAS_ID` 生成不同 bin 定义，`cfg.has_err_resp`/`cfg.has_id` 为 API 侧声明并做一致性校验（不一致 `$fatal`）；地址区间改为「区间码归一」（`cfg.cov_addr_lo/hi`，运行期生效，covergroup 不再写死区间） | 实测 ModelSim 2020.4 三项限制（§3.3）：covergroup 参数端口 `vlog-13069` 语法错误、类内 covergroup 实例不可创建、`ignore_bins` 的运行期 `iff` 在 elaboration 期固化并产生 `vsim-8549` 告警。地址区间改走区间码后无需参数化 bin，故区间上下限仍是运行期配置 |
| 6 | 既有用例「不回退」（比对项数/断言计数允许偏移，须解释） | `tb_dvp2ax_stream` 断言计数 7208 → **7214**（+6），比对项与结论不变 | A2 把 sequencer 空转由 1ns 轮询改为接口时钟沿轮询：事务经仲裁送 driver 相对原先最多晚一拍，空闲/事务交错的拍数分布随之略变，而逐拍协议断言按拍累计，故计数小幅变化。事务比对 539/0 与覆盖率 100% 不变；`tb_vrf_axil_demo` 断言计数 5238 完全不变（该用例的随机抽取序列未受影响） |
| 7 | 计划外增补（为满足「库本体无 DUT 名」验收）：把 bind 语句移出库本体、map 选择收敛进 Reg、`reg_map` 默认改为空串 | ①`vrf_axil_chk.sv` 只保留检查器，bind 由用例文件给出；②`model.build_map(cfg.reg_map)`，DUT 名与实现的对应关系收敛在 `vrf_axil_regmodel.svh`；③`cfg.reg_map` 默认 `""`，未显式指定即 `$fatal` | 原实现中 `Pkg`（cfg 默认值/注释）、`Env`（map 分派）、`Slv`（注释）、`Chk`（bind 目标）均含 DUT 名，无法通过验收口径；改后接入新 DUT 确实无需修改库本体，且 `reg_map` 的显式化消除了「静默用错默认映射」的风险 |
| 8 | 计划外增补：新增 `-Clean` 白名单与工作库 `work_rstw` | `run.ps1` 增加新用例分支（不传 bind 目标）与 `work_rstw`；`-Clean` 白名单同步 | 新用例需要独立工作库；缺 bind 目标时 `vlog` 会收到空参数，故改为条件拼接 `+define+` |

未采纳项：无（计划清单内各项均已落地或按预案降级落地）。

---

## 5. 调试定位与解决的问题

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | 覆盖率参数化方案在 `covergroup cg #(parameter …)` 处直接编译失败 | ModelSim SE-64 2020.4 不支持 covergroup 参数端口（vlog-13069） | 先做最小验证确认三项工具限制，再改走编译期能力开关方案（§4 偏差 5） |
| 2 | 类内声明 covergroup 类型后实例化报 `Variables of embedded Covergroup type 'cg_t' cannot be created` | 该版本不支持类内 covergroup 实例 | 维持「package 作用域 covergroup + ref 形参 + 类内持有实例」的既有写法 |
| 3 | `ignore_bins … iff (…)` 编译通过但开关切换无效，且报 `vsim-8549` 告警 | `iff` 条件在 elaboration 期固化，被排除的 bin 值域收敛为空并触发告警 | 放弃运行期条件化，改用编译期开关 + cfg 一致性校验；同时避免 `iff` 以保证「0 告警」 |
| 4 | 新用例加载时报 `vsim-8451 Virtual interface resolution cannot find a matching instance` | 库内组件声明了 `mst/slv/mnt` 三种虚拟接口，ModelSim 在加载期要求这三类接口都有实例存在（且未被优化掉） | 用例内声明三种接口，并用虚拟接口句柄引用它们（与真实用例的用法一致），避免实例被优化掉 |
| 5 | 修复 A1 后若只清空挂起状态，复位窗口用例会因「无观测」而不收敛 | 半笔写不产生观测 → 计分板无机会 `drop()` → `wait_idle` 空转到上限 | 清空的同时把半笔写作为 `obs_interrupted=1` 的观测上报（由计分板按 `expect_interrupt` 跳过） |
| 6 | 半笔写观测里出现 `0xx`（X） | 监视器的暂存寄存器（`w_data`/`aw_addr` 等）构造后未初始化，半笔写时取的仍是 X | `new()` 中给全部暂存寄存器初值；复位分支同时清空 |
| 7 | 探针用例中 wstrb_apply 的 32 位自检「FAIL」 | 探针的期望值算错（`strb=4'b0101` 时 byte0/byte2 取自新值，结果应为 `0xAA22CC44`） | 修正探针期望值后 PASS（被测函数本身无误） |

---

## 6. 已知限制与遗留风险

1. **覆盖率能力开关为编译期开关**：异常响应与非 0 ID 的 bin 定义由 `+define+VRF_AXIL_COV_HAS_ERR` / `+define+VRF_AXIL_COV_HAS_ID` 决定，须与 `cfg.has_err_resp` / `cfg.has_id` 一致（不一致即 `$fatal`）。这是 ModelSim 2020.4 的限制所致（§3.3）；阶段二引入 SLVERR 注入时，需要在对应用例的编译模式中补上该 `+define+`。
2. **复位窗口用例是白盒用例**：只覆盖监视器 + 寄存器模型的交互，不经 driver/env/协议检查器；窗口本身在全系统用例中不可达（原因见 §4 偏差 1），因此「驱动侧在半笔写窗口内被复位打断」的组合行为仅在既有 `ph_reset_test`（B 通道复位）中覆盖。
3. **`ar_pend` 仍存在两个写者**：主循环（复位清空）与读响应等待进程（完成后清空）都会写 `ar_pend`。沿用既有结构未重构：读写在本平台内是串行的，复位时旧读的等待进程会在同一拍内完成清空，实测无冲突；若后续引入乱序或多笔在途读，建议按「单写者」收敛。
4. **事件注入的位映射语义仍在模型内**：`event_*()` 的寄存器偏移已 map 化（`evt_*_off`），但「事件 → 位」的对应关系仍写在通用模型的方法体里；若后续 DUT 的事件语义不同，需要按需注册化（本阶段计划未要求）。
5. **代码覆盖率未纳入门禁**：`-Cover` 会同时开启代码覆盖率，本轮仅记录测量值（statement 100% / branch 86.20% / condition 59.25% / toggle 8.93%（DUT 侧）/ assertion 87.50%），阈值设定与门禁化属阶段三。
6. **`Makefile` 仍未实机验证**（本机未安装 `make`），属阶段三 C5 范围。
7. **`inject_event` 仍依赖 RTL 内部信号名**（层次化 force），属阶段二 C6 范围，暂未改动。

---

## 7. 文档与同步

| 文档 | 同步内容 |
|---|---|
| `Doc/API_VRF_AXI4L.md` | cfg 新字段（`exp_id_check`/`exp_id_value`、`has_err_resp`/`has_id`、`cov_addr_lo/hi`、`reg_map` 默认空串）；regmodel 位宽参数化与回调注册表、`build_map`、`unmap_resp`/`unmap_rdata`；monitor 复位语义；覆盖率能力开关与区间码；bind 位置与接入新 DUT 步骤；`done_ctrl` 的 `raise()/drop()`；新增用例命令与工作库；txn 删除 `txn_mst_id` |
| `README.md` | 「库使用方式」（工作库/能力开关/接入步骤）、「关键机制」（覆盖率口径、仿真结束机制）、「已知限制」（新增第 8/9 条）、「验证结果 / 目录结构 / 文档索引」 |
| `Doc/Dev_report_0917.md` | 本报告 |

> 阶段一未涉及 RTL 改动（`RTL/DVP2axi_stream.v` 本轮未修改）。
