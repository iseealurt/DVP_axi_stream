# DVP2AXI_Stream 与 VRF_AXI4L 验证库

基于 SystemVerilog 的 **AXI4-Lite 通用验证库（VRF_AXI4L）**，以及它在 `DVP2axi_stream` IP 寄存器块上的完整接入示例。

库本体与具体 DUT 完全解耦：通过「挂具模块 + 端口按名通配符自动连接」接入新 DUT，**接入新 DUT 时无需修改库本体**。

- 仿真工具：ModelSim SE-64 2020.4（vlog / vsim / vcover 2020.10）
- 纯 SystemVerilog 实现，**不依赖 UVM**，也不依赖任何第三方库
- 运行环境：Windows + PowerShell（`run.ps1` / `regression.ps1` / `check_env.ps1`）

---

## 目录

- [特性概览](#特性概览)
- [验证结果](#验证结果)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [库使用方式](#库使用方式)
- [被测对象：DVP2axi_stream](#被测对象dvp2axi_stream)
- [关键机制](#关键机制)
- [文档](#文档)
- [已知限制](#已知限制)

---

## 特性概览

| 能力 | 说明 |
|---|---|
| 通配符自动连接 | 挂具模块内 `MY_DUT u_dut (.*);` 即可按名连接 DUT 全部端口，配合挂钩宏 `` `VRF_AXIL_HOOK_DECL `` 一次性完成接口实例化与句柄发布 |
| 三视角接口 | `mst` / `slv` / `mnt` 三个参数化接口（`AWIDTH` / `DWIDTH` / `IDWIDTH`），含明确驱动与采样约定，避免握手当拍取错相位 |
| 上电连通性自检 | 空闲态静态检查 → 走线激励 → 探针事务，按信号输出「正常 / 恒定 / 未驱动或含 X/Z / 连接错误」结论表 |
| 轻量寄存器模型 | RAL-like 模型维护镜像值与访问属性（R/W、RO、W1C、自清零），支持 `wstrb` 字节使能、`SOFT_RST` / `CLR_CNT` 副作用与内部事件注入 |
| 分层组件 | cfg / sequence / sequencer / driver / monitor / scoreboard / coverage，全部以 mailbox 串起数据流，无 factory/phase/objection 等重型机制 |
| 定向 + 受约束随机 | 定向用例按名注册与一键挂载（`"ALL"` 挂载全部）；随机事务支持地址区间、读写均衡、strb 模式、AW/W 延迟、B/R 反压约束 |
| 协议检查器 | 独立 binder 模块 `vrf_axil_chk`，21 条 SVA 属性覆盖 X/Z、握手稳定性、通道协议、resp 合法性、超时、复位约束，按 formal-friendly 方式编写 |
| 功能覆盖率 | 7 个 coverpoint + 3 个 cross，UCDB 落盘，并按「可达口径」用 `ignore_bins` 排除不可达 bin |
| 失败自动复现 | seed 回放 → 失败事务回注 sequencer 单笔重注 → monitor 宽监视逐拍记录 → 格式化错误报告 + 种子落盘 |
| 脚本与回归 | 单用例一键编译仿真、多种子批量回归（超时保护、陈旧报告校验、工作库所有权保护）、前置条件检查，另提供 `Makefile` 统一入口 |

---

## 验证结果

| 项 | 结果 |
|---|---|
| 库自测用例 `tb_vrf_axil_demo` | **PASSED**：事务比对 285 项，失败 0；协议断言 5238 次，失败 0 |
| 接入示例 `tb_dvp2ax_stream` | **PASSED**：事务比对 539 项（跳过 1），失败 0；协议断言 7208 次，失败 0 |
| 上电连通性自检 | 两个用例均 21 个总线信号全部通过（0 连接错误、0 X/Z） |
| 功能覆盖率 | **100.00%**（可达 bin 37/37） |
| 批量回归 | 5 个随机种子全部 PASSED，累计检查 2695 项 |
| 编译与仿真告警 | **0 错误、0 告警** |
| 失败复现链路 | 已通过故障注入自测（失败检测 → 回注复现 → 宽监视 → 错误报告 → 种子落盘） |

批量回归汇总示例：

```
# 测试用例 : tb_dvp2ax_stream      # 回归轮次 : 5 / 5
Seed     Exit   Checks     Failures   AssertErr   Verdict
1        0      539        0          0           PASSED
2        0      539        0          0           PASSED
3        0      539        0          0           PASSED
4        0      539        0          0           PASSED
5        0      539        0          0           PASSED
# 结论 : REGRESSION PASSED
```

---

## 目录结构

```
.
├── RTL/
│   └── DVP2axi_stream.v          # DVP → AXI-Stream IP（本轮验证其 AXI4-Lite 寄存器块）
├── bench/
│   ├── lib/                      # VRF_AXI4L 库本体（与具体 DUT 解耦）
│   │   ├── IF/   vrf_axil_if.sv          # mst/slv/mnt 三视角接口 + 挂钩宏
│   │   ├── Pkg/  vrf_axil_pkg.sv         # 顶层 package
│   │   │         vrf_axil_types.svh      # 类型枚举 / 接口句柄表 / 全局控制类
│   │   │         vrf_axil_txn.svh        # 事务类与约束
│   │   │         vrf_axil_cfg.svh        # 配置类
│   │   ├── Reg/  vrf_axil_regmodel.svh   # 轻量寄存器模型（RAL-like）
│   │   ├── Seq/  vrf_axil_direct_lib.svh # 定向用例库
│   │   │         vrf_axil_sequence.svh   # sequence（generator）
│   │   │         vrf_axil_sequencer.svh  # sequencer（仲裁 + 失败重注）
│   │   ├── Drv/  vrf_axil_driver.svh     # 驱动器（读写双流并发）
│   │   ├── Mon/  vrf_axil_monitor.svh    # 监视器（预测 + 宽监视）
│   │   ├── Slv/  vrf_axil_slave.sv       # AXI4-Lite 从机参考模型
│   │   ├── Cov/  vrf_axil_cov.svh        # 功能覆盖率收集器
│   │   ├── Env/  vrf_axil_env.svh        # 环境类（一键启用 / 细粒度控制）
│   │   │         vrf_axil_scoreboard.svh # 计分板
│   │   ├── Chk/  vrf_axil_bringup.svh    # 上电连通性自检
│   │   │         vrf_axil_chk.sv         # 协议检查器 + bind
│   ├── tb/
│   │   ├── tb_vrf_axil_demo.sv   # 库自测用例（对端：从机参考模型，不依赖 RTL）
│   │   └── tb_dvp2ax_stream.sv   # 接入示例（对端：DVP2axi_stream）
│   ├── scripts/
│   │   ├── filelist.f            # 编译文件列表（顺序固定，须配合 -mfcu）
│   │   ├── check_env.ps1         # 前置条件检查
│   │   ├── run.ps1               # 单用例编译 + 仿真 + 报告
│   │   ├── regression.ps1        # 多种子批量回归
│   │   └── sim.do                # ModelSim 脚本
│   └── abandoned/                # 已废弃的历史验证代码（不参与编译）
├── Doc/
│   ├── API_VRF_AXI4L.md          # 库 API 接口文档
│   ├── Dev_plan_0916.md          # 开发计划
│   ├── Dev_report_0916.md        # 开发报告（含四轮评审修正记录）
│   ├── Reg_v_0_0.md              # DVP2AXI_Stream 寄存器设计说明
│   └── AXI4_Lite_Sim_Report.md   # 历史基线仿真报告
├── Makefile                      # 统一入口（内部调用上述 PowerShell 脚本）
└── .gitignore                    # 排除仿真生成物、工作库、日志与报告
```

---

## 快速开始

### 前置条件

- ModelSim SE-64 2020.4 或兼容版本（`vlib` / `vlog` / `vsim`，`vcover` 可选，用于覆盖率报告）
- PowerShell（Windows PowerShell 5.1 或 PowerShell 7）

```powershell
# 前置条件检查：解释器、ModelSim 工具、工程文件、目录可写
powershell -File bench/scripts/check_env.ps1
```

### 常用命令

```powershell
# 库自测（对端：从机参考模型，不依赖 RTL）
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo

# DVP2axi_stream 接入示例
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream

# 指定种子复现
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 12345

# 带功能覆盖率（生成 UCDB）
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Cover

# 故障注入自测：验证「失败检测 → 回注复现 → 错误报告」链路
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo -Nrand 0 -Fault

# 批量回归（-TimeoutSec 为单轮超时，默认 900 秒）
powershell -File bench/scripts/regression.ps1 -Seeds "1,2,3,4,5" -TimeoutSec 900
```

### Makefile 入口

```bash
make check                        # 前置检查
make demo                         # 库自测用例
make dvp                          # DVP2axi_stream 接入示例
make run TEST=tb_vrf_axil_demo SEED=12345 NRAND=250
make cover TEST=tb_dvp2ax_stream  # 带功能覆盖率
make regress SEEDS=1,2,3,4,5      # 批量回归
make fault                        # 故障注入自测
make clean                        # 清理 work* 与日志目录
```

> `-Seed` / `-Nrand` 只有**显式传参**才会下发对应 plusarg，因此 `-Seed 0`、`-Nrand 0` 均为有效取值。

### 输出文件

| 文件 | 内容 |
|---|---|
| `<log_dir>/<test>_report.txt` | 验证报告（连通性自检报告头、统计、覆盖率、结论） |
| `<log_dir>/<test>_log.txt` | 逐笔事务运行日志 |
| `<log_dir>/<test>_err.txt` | 失败用例格式化错误报告 |
| `<log_dir>/<test>_wide_trace.txt` | 失败复现时的逐拍宽监视文本 |
| `<log_dir>/<test>.ucdb` | 覆盖率数据库（`-Cover` 时生成） |
| `<log_dir>/<test>.exit` | `run.ps1` 退出码（供回归脚本稳定读取） |
| `<log_dir>/regression/run_<时间戳>_<pid>/summary.txt` | 批量回归汇总 |

`run.ps1` 退出码：`0` 成功；`2` 参数/环境错误；`3` 工作库被占用或创建失败；`4` 编译失败；`5` 未找到 ModelSim 工具；`6` 未生成报告。

---

## 库使用方式

### 1. 编译要求

```
vlog -mfcu -cuname <test>_cu -sv -work <lib> +define+<BIND_MODE> -f bench/scripts/filelist.f
```

- `-mfcu` **必须**：接口位于 `$unit` 作用域，需与 package 处于同一编译单元
- `-cuname` 建议：保证编译单元作用域的 `bind` 一定参与 elaboration
- 每个用例使用独立工作库（`work_demo` / `work_dvp2axi`），避免不同 `-define` 编译出的同名单元互相覆盖

`<BIND_MODE>` 选择协议检查器的 bind 目标：

| 被测对端 | 宏定义 | 工作库 |
|---|---|---|
| 从机参考模型（库自测） | `+define+VRF_AXIL_BIND_REF` | `work_demo` |
| DVP2axi_stream | `+define+VRF_AXIL_BIND_DVP2AXI` | `work_dvp2axi` |

### 2. 写挂具模块

```systemverilog
module my_harness (input logic aclk, input logic aresetn);
  import vrf_axil_pkg::*;
  `VRF_AXIL_HOOK_DECL(32, 32, 4)   // 声明同名信号 + 挂接接口 + 发布句柄
  MY_DUT u_dut (.*);               // DUT 全部端口按名自动连接
endmodule
```

### 3. 两种典型用法

**用法一：一键流程**（适合快速回归）

```systemverilog
env = new(cfg);
vrf_axil_direct_lib_t::reg_case("my_case", txn);
env.run_all();                 // connect + start + run + report
```

**用法二：细粒度控制**（适合分层定向测试）

```systemverilog
env = new(cfg);
env.connect();
env.start();                   // 含上电连通性自检
env.submit(mk_rd("dir", 32'h80));
env.wait_idle();
env.model.set_mirror(32'h80, 32'hDEAD_BEEF);   // 需要时同步模型
env.run_random(400);
env.wait_idle();
env.stop();
env.report();
```

### 4. 接入新 DUT 的步骤

1. 写挂具模块（挂具内声明本轮不验证的端口占位，供 `.*` 按名连接）；
2. 在 `bench/lib/Chk/vrf_axil_chk.sv` 中按 `+define+` 增加一条 `bind MY_DUT vrf_axil_chk ...`，并在 `run.ps1` 的 `switch` 中登记编译模式；
3. 在 `vrf_axil_regmodel` 中新增 `build_xxx_map()`，并设置 `cfg.reg_map`；
4. 复制 `bench/tb/tb_dvp2ax_stream.sv`，替换挂具与寄存器偏移常量；
5. 在 `bench/scripts/filelist.f` 末尾追加挂具与用例文件。

> 库本体（`bench/lib`）无需修改。详细 API 见 [Doc/API_VRF_AXI4L.md](Doc/API_VRF_AXI4L.md)。

---

## 被测对象：DVP2axi_stream

`RTL/DVP2axi_stream.v` 是一个 DVP 视频输入 → AXI-Stream 输出的 IP，通过 AXI4-Lite 从接口暴露寄存器配置空间。

| 参数 | 默认 | 说明 |
|---|---|---|
| `DVP_DWIDTH` / `PIX_WIDTH` | 8 / 16 | DVP 输入位宽与像素位宽 |
| `AXI_STREAM_DWIDTH` | 256 | AXI-Stream 数据位宽 |
| `AXI_LITE_DWIDTH` / `AXI_LITE_AWIDTH` | 32 / 32 | AXI4-Lite 数据/地址位宽 |
| `AXI_ID_WIDTH` | 4 | `bid` / `rid` 位宽 |

寄存器映射（共 23 个寄存器，详见 [Doc/Reg_v_0_0.md](Doc/Reg_v_0_0.md)）：

| 偏移 | 名称 | 访问 | 说明 |
|---|---|---|---|
| 0x00 | CTRL | R/W | 全局控制（含 SOFT_RST / CLR_CNT / CLR_FIFO 自清零位） |
| 0x04 | STATUS | RO | 实时状态 |
| 0x08 | FRAME_CNT | RO | 完成帧计数 |
| 0x0C | ERR_FLAG | R/W1C | 错误标志（粘滞，写 1 清除） |
| 0x10 | INT_EN | R/W | 中断使能 |
| 0x14 | INT_STATUS | R/W1C | 中断状态 |
| 0x18 | VERSION | RO | IP 版本（复位值 0x0001_0000） |
| 0x20 | DVP_CTRL | R/W | DVP 输入控制（极性 / 像素格式 / 字节交换） |
| 0x24 | IMG_WIDTH | R/W | 有效图像宽度 |
| 0x28 | IMG_HEIGHT | R/W | 有效图像高度 |
| 0x2C | LINE_TOTAL | R/W | 每行总 pclk 周期 |
| 0x30 | FRAME_TOTAL | R/W | 每帧总行数 |
| 0x40 | AXIS_CTRL | R/W | AXI-Stream 输出控制（打包 / 字节序 / tlast 模式） |
| 0x44 / 0x48 / 0x4C | AXIS_TID / TDEST / TUSER | R/W | 预留字段 |
| 0x60 | FIFO_STATUS | RO | FIFO 状态 |
| 0x64 | FIFO_THRESHOLD | R/W | FIFO 高水位阈值 |
| 0x70 ~ 0x7C | DBG_STATE / PIX_CNT / LINE_CNT / BEAT_CNT | RO | 调试寄存器 |
| 0x80 | SCRATCH | R/W | 软件自检寄存器 |

> 当前 RTL 的数据通路仍为 tie-off，本轮仅验证 AXI4-Lite 寄存器块。

---

## 关键机制

### 通配符自动连接

SystemVerilog 的 `bind` **只能观测**目标模块内部信号，**无法驱动**其输入端口（实测被 bind 模块驱动的 DUT 输入端口仿真中不生效）。因此本库采用「挂具模块 + 端口按名通配符连接 + 挂钩宏」方案：DUT 端口仍按名自动连接，接口连接由 `` `VRF_AXIL_HOOK_DECL `` 一次性完成。

### 驱动与采样约定

对端信号经 `assign` 连到接口变量上，**组合型 ready/valid 会在握手当拍被对端更新为后沿值**。因此：

| 信号来源 | 读法 |
|---|---|
| 自己驱动的信号 | 直接读接口变量（本拍前沿值） |
| 被测/对端驱动的信号 | **必须**用时钟块采样（`#1step` 取前沿值） |

### 失败自动复现

1. 每轮仿真记录随机种子并落盘 `repro_seed.txt`，可 `-Seed <n>` 整用例回放；
2. 计分板判定失败后，克隆该事务并回注 sequencer 的复现队列（优先级最高）；
3. 同时通知 monitor 进入宽监视模式，逐拍记录全部总线信号；
4. 生成格式化错误报告 `<test>_err.txt`。

### 功能覆盖率口径

功能覆盖率只衡量「DUT 能够表现出的行为」，因此以 `ignore_bins` 排除：AXI4-Lite 不使用的 `EXOKAY`、当前 DUT 不产生的 `SLVERR`/`DECERR`、恒为 0 的非 0 主机 ID、结构非法的全零写选通、以及读方向的字节选通列。

> **接入新 DUT 时须复核**：若新 DUT 会返回 `SLVERR`/`DECERR` 或使用非 0 的 `bid`/`rid`，必须移除对应 `ignore_bins`，否则会掩盖真实覆盖漏洞。

### 仿真结束机制

`vrf_axil_done_ctrl::pending` 实现 objection 式完成计数：提交事务 +1，计分板比对完成 -1；`env.wait_idle()` 等待归零并留 4 拍收尾，另有 `cfg.max_txn` 与 `cfg.max_sim_time` 上限兜底。

---

## 文档

| 文档 | 内容 |
|---|---|
| [Doc/API_VRF_AXI4L.md](Doc/API_VRF_AXI4L.md) | 库 API 接口文档：每个类/方法的功能、入参出参、调用时序与接入步骤 |
| [Doc/Dev_plan_0916.md](Doc/Dev_plan_0916.md) | 开发计划：范围边界、总体约定、四阶段落地计划与验收标准 |
| [Doc/Dev_report_0916.md](Doc/Dev_report_0916.md) | 开发报告：验证结果、关键机制实现、四轮代码评审修正记录 |
| [Doc/Reg_v_0_0.md](Doc/Reg_v_0_0.md) | DVP2AXI_Stream 寄存器设计方案 |
| [Doc/AXI4_Lite_Sim_Report.md](Doc/AXI4_Lite_Sim_Report.md) | 历史基线仿真报告（17 项覆盖项，已全部被本库覆盖并扩展） |
| [bench/abandoned/README.md](bench/abandoned/README.md) | 已废弃历史代码清单与已知缺陷说明 |

---

## 已知限制

1. **验证范围**：仅覆盖 AXI4-Lite 寄存器接口；DVP 输入与 AXI-Stream 输出不纳入验证，也未做 tie-off，连通性自检报告头会明确标注为「本轮不纳入验证」。
2. **数据通路**：RTL 中 `pdin` / `pvref` / `phref` / `axis_tready` 为未使用输入，`axis_tvalid` / `tdata` / `tlast` 恒为 0，数据通路尚未实现。
3. **形式化**：断言已按 formal-friendly 方式编写（属性独立、含 `disable iff` 门控、无时序依赖的过程语句），但未搭建形式化工具环境，未做有界证明。
4. **代码覆盖率**：`-Cover` 会同时开启代码覆盖率，但当前只统计功能覆盖率，代码覆盖率未纳入验收。
5. **非标准端口**：`awport` / `arport` 为非标准端口，仅做连通性与 X/Z 检查，不纳入标准协议检查。
6. **Makefile**：本机未安装 `make`，未做实机验证；内部调用的 PowerShell 脚本均已验证。
7. **并发运行**：工作库名固定（`work_demo` / `work_dvp2axi`），不支持同一用例的真正并发运行。`run.ps1` 会在工程根目录写占用标记（原子创建、记录 PID），被存活进程占用时以退出码 3 拒绝，陈旧标记会被接管。

---

## 后续建议

- **覆盖率口径固化**：在 `vrf_axil_cov` 中引入能力开关（如 `cov_has_err_resp` / `cov_has_id`），由 DUT 配置驱动排除项，避免接入新 DUT 时漏改。
- **扩展至 AXI-Stream**：按现有分层新增 `vrf_axis_*` 组件，复用接口句柄表、配置类、计分板与报告框架。
- **形式化接入**：把 `vrf_axil_chk` 的属性集抽出为独立 formal 属性文件，配合 `assume` 约束做有界证明。
- **DVP 侧激励**：待 RTL 数据通路实现后，补齐 DVP 时序激励与帧级计分板，实现全链路端到端验证。
- **CI 集成**：把 `regression.ps1` 接入流水线，以 `summary.txt` 与 UCDB 作为门禁产物。