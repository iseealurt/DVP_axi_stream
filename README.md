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
| 轻量寄存器模型 | RAL-like 模型维护镜像值与访问属性（R/W、RO、W1C、自清零），按数据位宽参数化；支持 `wstrb` 字节使能、按偏移注册的写副作用回调（如 `SOFT_RST` / `CLR_CNT`）、可配置的未映射访问行为与内部事件注入 |
| 分层组件 | cfg / sequence / sequencer / driver / monitor / scoreboard / coverage，全部以 mailbox 串起数据流，无 factory/phase/objection 等重型机制 |
| 定向 + 受约束随机 | 定向用例按名注册与一键挂载（`"ALL"` 挂载全部）；随机事务支持地址区间、读写均衡、strb 模式、AW/W 延迟、B/R 反压约束 |
| 协议检查器 | 独立 binder 模块 `vrf_axil_chk`，21 条 SVA 属性覆盖 X/Z、握手稳定性、通道协议、resp 合法性、超时、复位约束，按 formal-friendly 方式编写；bind 由用例给出，库本体不含 DUT 名 |
| 功能覆盖率 | 7 个 coverpoint + 3 个 cross，UCDB 落盘；地址区间按 cfg 归一为区间码（与 DUT 布局解耦），异常响应/非 0 ID 的 bin 由能力开关控制 |
| 复位窗口专项用例 | `tb_vrf_axil_rst_window`：直接驱动监视视角接口，复现并回归「AW 已握手、W 未握手期间拉复位」下的配对正确性与半笔写上报 |
| 失败自动复现 | seed 回放 → 失败事务回注 sequencer 单笔重注 → monitor 宽监视逐拍记录 → 格式化错误报告 + 种子落盘 |
| 脚本与回归 | 单用例一键编译仿真、多种子批量回归（超时保护、陈旧报告校验、工作库所有权保护）、前置条件检查，另提供 `Makefile` 统一入口 |

---

## 验证结果

| 项 | 结果 |
|---|---|
| 库自测用例 `tb_vrf_axil_demo` | **PASSED**：事务比对 285 项，失败 0；协议断言 5238 次，失败 0 |
| 接入示例 `tb_dvp2ax_stream`（寄存器 + 数据通路） | **PASSED**：参与比对 1155 项（总线 969 + 数据通路帧级 186），失败 0；协议断言 55454 次，失败 0 |
| 数据通路帧级比对 | 28 个 DVP 用例（正常帧 ×6 / 边界 ×10 / 中断 ×2 / 参数生效 ×2 / FIFO 溢出 ×1 / 补齐项定向 ×7），183 拍逐字节比对，失败 0 |
| 复位窗口定向用例 `tb_vrf_axil_rst_window` | **PASSED**：12 项检查，失败 0（修复前可稳定复现 AW/W 窗口期复位的地址错配） |
| 上电连通性自检 | 三个用例均 21 个总线信号全部通过（0 连接错误、0 X/Z） |
| 功能覆盖率 | **100.00%**：`vrf_axil_cg` 37/37、`vrf_dvp_cg` 33/33（边界 × TLAST_MODE 交叉全覆盖） |
| 批量回归 | 三个用例各 5 个随机种子全部 PASSED |
| 编译与仿真告警 | **0 错误、0 告警** |
| 失败复现链路 | 已通过故障注入自测（失败检测 → 回注复现 → 宽监视 → 错误报告 → 种子落盘） |

批量回归汇总示例：

```
# 测试用例 : tb_dvp2ax_stream      # 回归轮次 : 5 / 5
Seed     Exit   Checks     Failures   AssertErr   Verdict
1        0      1155       0          0           PASSED
2        0      1155       0          0           PASSED
3        0      1155       0          0           PASSED
4        0      1155       0          0           PASSED
5        0      1155       0          0           PASSED
# 结论 : REGRESSION PASSED
```

---

## 目录结构

```
.
├── RTL/
│   ├── DVP2axis.sv               # DVP → AXI-Stream IP（寄存器块 + 采集/合并/打包/异步 FIFO 输出）
│   ├── IF/ if_axil.sv if_axis.sv # AXI4-Lite / AXI-Stream 接口
│   ├── FIFO/axis_async_fifo.sv   # 参数化行为级异步 FIFO（格雷码指针 CDC，FWFT 读）
│   └── Ref/DVP_AXI_v_2_0.v       # 参考模块（私有 AXI4 写内存版，仅供结构参考）
├── bench/
│   ├── lib/                      # VRF_AXI4L 库本体
│   │   ├── IF/   vrf_axil_if.sv          # mst/slv/mnt 三视角接口 + 挂钩宏
│   │   │         vrf_dvp_if.sv           # DVP 输入接口（pdin/pvref/phref）
│   │   ├── Pkg/  vrf_axil_pkg.sv         # 顶层 package
│   │   │         vrf_axil_types.svh      # 类型枚举 / 接口句柄表 / 全局控制类
│   │   │         vrf_axil_txn.svh        # 事务类与约束
│   │   │         vrf_axil_cfg.svh        # 配置类
│   │   ├── Reg/  vrf_axil_regmodel.svh   # 轻量寄存器模型（RAL-like，含读预测回调）
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
│   │   │         vrf_axil_chk.sv         # 协议检查器（bind 语句由用例给出）
│   │   └── Dvp/  vrf_dvp_driver.svh      # DVP 激励发生器（帧/边界注入）
│   │             vrf_axis_frame_chk.svh  # AXIS 帧级参考模型与逐拍比对
│   │             vrf_dvp_cov.svh         # 数据通路覆盖率（边界 × TLAST_MODE × PIX_FMT）
│   ├── tb/
│   │   ├── tb_vrf_axil_demo.sv   # 库自测用例（对端：从机参考模型，不依赖 RTL）
│   │   ├── tb_dvp2ax_stream.sv   # 接入示例（寄存器 + DVP 数据通路/边界/中断用例）
│   │   └── tb_vrf_axil_rst_window.sv  # 复位窗口定向用例（直接驱动监视视角接口）
│   ├── scripts/
│   │   ├── filelist.f            # 编译文件列表（顺序固定，须配合 -mfcu）
│   │   ├── check_env.ps1         # 前置条件检查
│   │   ├── run.ps1               # 单用例编译 + 仿真 + 报告
│   │   ├── regression.ps1        # 多种子批量回归
│   │   └── sim.do                # ModelSim 脚本
│   └── abandoned/                # 已废弃的历史验证代码（不参与编译）
├── Doc/
│   ├── API_VRF_AXI4L.md          # 库 API 接口文档
│   ├── Dev_plan_0916.md          # 开发计划（库搭建 + 寄存器块接入）
│   ├── Dev_report_0916.md        # 开发报告（含四轮评审修正记录）
│   ├── Dev_plan_0917.md          # 开发计划（缺陷修复 / 验证深度 / 工程化 / 范围扩展）
│   ├── Dev_report_0917.md        # 开发报告（阶段一：缺陷修复与库通用性收尾）
│   ├── Dev_plan_0923.md          # 开发计划（数据通路 + 边界处理 + 验证工程化）
│   ├── Dev_report_0923.md        # 开发报告（数据通路/边界/中断与帧级验证）
│   ├── Reg_v_0_0.md              # DVP2AXI_Stream 寄存器设计说明（含数据通路实现口径）
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

# 复位窗口定向用例（AW 已握手、W 未握手期间拉复位）
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_rst_window

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
- 每个用例使用独立工作库（`work_demo` / `work_dvp2axi` / `work_rstw`），避免不同 `-define` 编译出的同名单元互相覆盖

`<BIND_MODE>` 选择协议检查器的 bind 目标（bind 语句写在**用例文件**里，库本体不含 DUT 名）：

| 被测对端 | 宏定义 | 工作库 |
|---|---|---|
| 从机参考模型（库自测） | `+define+VRF_AXIL_BIND_REF` | `work_demo` |
| DVP2axi_stream | `+define+VRF_AXIL_BIND_DVP2AXI` | `work_dvp2axi` |
| 监视视角接口（无 DUT，不需 bind） | 不传 | `work_rstw` |

DUT 会产生错误响应或非 0 事务 ID 时，另需定义覆盖率能力开关
（`+define+VRF_AXIL_COV_HAS_ERR` / `+define+VRF_AXIL_COV_HAS_ID`），且与 `cfg.has_err_resp`/`cfg.has_id` 一致。

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
2. 在**自己的用例文件**中加 bind（库本体不含 DUT 名），并在 `run.ps1` / `regression.ps1` 中登记 `+define+` 与工作库名；
3. 在 `vrf_axil_regmodel` 中新增 `build_xxx_map()` 并在 `build_map()` 中登记，用例里设置 `cfg.reg_map`（未设置即 `$fatal`）；
   写副作用用 `reg_special_cb()` 注册回调，未映射访问行为用 map 内的 `unmap_resp` / `unmap_rdata` 配置；
4. 按 DUT 能力设置 `cfg.exp_id_check`/`cfg.exp_id_value`、`cfg.has_err_resp`/`cfg.has_id`（编译期开关同步定义）、`cfg.cov_addr_lo`/`cfg.cov_addr_hi`；
5. 复制 `bench/tb/tb_dvp2ax_stream.sv`，替换挂具与寄存器偏移常量；
6. 在 `bench/scripts/filelist.f` 末尾追加挂具与用例文件。

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

> 数据通路（v1.0 已实现）：`pdin/pvref/phref`（4 级同步）→ 像素合并（按 `PIX_FMT` 决定每像素字节数）
> → beat 打包（`PACK_EN/PACK_MODE/BYTE_SWAP/TLAST_MODE`）→ 异步 FIFO（1024 beat）→ AXI-Stream 输出；
> 行长/帧长恒等于 `IMG_WIDTH/IMG_HEIGHT`（输入更短则提前结束、更长则丢弃多余部分）；
> 详细口径见 [Doc/Reg_v_0_0.md](Doc/Reg_v_0_0.md) §6（含配置生效时机与实现状态）。
> `FIFO_THRESHOLD` 驱动 `FIFO_STATUS.ALMOST_FULL`（高水位指示）；`STATUS[6] CFG_PENDING` 可轮询配置是否已在帧边界提交。

### 数据通路帧级验证

`tb_dvp2ax_stream.sv` 在寄存器用例之后追加数据通路用例（阶段三），可复用的库组件：

| 组件 | 作用 |
|---|---|
| `vrf_dvp_driver` | pclk 域 DVP 激励：按 `PIX_FMT` 字节串行发送像素，支持每行像素数/每帧行数注入（行短/行长/帧短/帧长）、确定性伪随机像素 |
| `vrf_axis_frame_chk` | 依据驱动计划 + 打包配置重建期望 beat 序列（有效字节数/tstrb/tlast/填充/字节序），与 AXIS 每拍观测逐字节比对 |
| `vrf_dvp_cov` | 覆盖率：边界类型 × TLAST_MODE 交叉 + PIX_FMT/PACK_MODE/BYTE_SWAP/TSTRB_EN 取值 |

用例矩阵：正常帧 ×6（YUV422/RGB565/RAW8/RAW10/RGB888，自动与手动打包、大小端、TSTRB 开关）、
边界 ×10（LINE_SHORT/LINE_LONG/FRAME_SHORT/FRAME_LONG 各 2 种 TLAST_MODE + 行短且帧短组合）、
中断 ×2（门控关/开 + W1C 清除）、参数生效 ×2（帧边界生效 + `PCLK_INV` 下降沿采样）、FIFO 溢出 ×1、
补齐项定向 ×7（`CFG_PENDING` / `CFG_ERR` / `ALMOST_FULL` / `AXIS_ERR` 超时 / `CLR_CNT` / `CLR_FIFO` / `SOFT_RST`）。

> 数据通路用例通过 `env.ext_check_num/ext_fail_num`（库新增的外部检查项计数）汇入统一报告与结论口径。

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

其中与 DUT 能力相关的两类（异常响应、非 0 ID）由**编译期能力开关**控制：
`+define+VRF_AXIL_COV_HAS_ERR` / `+define+VRF_AXIL_COV_HAS_ID` 决定对应 bin 是否参与统计，
`cfg.has_err_resp` / `cfg.has_id` 是 API 侧声明，两者不一致时构造覆盖率收集器即 `$fatal`。
地址区间不再写死：covergroup 只对「区间码」采样，区间码由 `cfg.cov_addr_lo/hi` 归一（区间内四等分 + 顶部寄存器区 + 区间外）。

> **为什么是编译期开关**：ModelSim 2020.4 不支持 covergroup 参数端口，且 `ignore_bins` 上的运行期 `iff` 条件在 elaboration 期即固化（实测构造后修改不生效并产生告警）。

### 仿真结束机制

`vrf_axil_done_ctrl` 实现 objection 式完成计数：提交事务时 `raise()`，计分板完成比对时 `drop()`（计数只从这两个方法修改）；`env.wait_idle()` 等待归零并留 4 拍收尾，另有 `cfg.max_txn` 与 `cfg.max_sim_time` 上限兜底。计数下溢按断言告警处理（计入 `assert_fail_cnt`），不做静默钳位。

---

## 文档

| 文档 | 内容 |
|---|---|
| [Doc/API_VRF_AXI4L.md](Doc/API_VRF_AXI4L.md) | 库 API 接口文档：每个类/方法的功能、入参出参、调用时序与接入步骤 |
| [Doc/Dev_plan_0916.md](Doc/Dev_plan_0916.md) | 开发计划：范围边界、总体约定、四阶段落地计划与验收标准 |
| [Doc/Dev_report_0916.md](Doc/Dev_report_0916.md) | 开发报告：验证结果、关键机制实现、四轮代码评审修正记录 |
| [Doc/Dev_plan_0917.md](Doc/Dev_plan_0917.md) | 开发计划（0917）：审阅问题清单、四阶段任务与验收清单、开发报告内容要求 |
| [Doc/Dev_report_0917.md](Doc/Dev_report_0917.md) | 开发报告（0917 阶段一）：缺陷修复、库通用性收尾与验收对账 |
| [Doc/Reg_v_0_0.md](Doc/Reg_v_0_0.md) | DVP2AXI_Stream 寄存器设计方案 |
| [Doc/AXI4_Lite_Sim_Report.md](Doc/AXI4_Lite_Sim_Report.md) | 历史基线仿真报告（17 项覆盖项，已全部被本库覆盖并扩展） |
| [bench/abandoned/README.md](bench/abandoned/README.md) | 已废弃历史代码清单与已知缺陷说明 |

---

## 已知限制

1. **DVP 数据通路未实现项已全部补齐**（原 §6.4 登记项）：
   `ERR_FLAG.AXIS_ERR`（tready 超时检测，门限 8192 aclk）、`DVP_CTRL.PCLK_INV`（下降沿采样，写入后立即生效）、
   `CTRL.SOFT_RST/CLR_CNT/CLR_FIFO` 的跨域清除（pclk 域计数/打包/状态机与 `FIFO_STATUS` 粘滞位一并复位；
   `CLR_CNT` 只清计数、不动 FIFO）、`FIFO_THRESHOLD`（驱动 `FIFO_STATUS.ALMOST_FULL`）、
   配置握手在途状态（引出为 `STATUS.CFG_PENDING`）。详见 [Doc/Reg_v_0_0.md](Doc/Reg_v_0_0.md) §6.4。
   仍存限制：清除类动作有数个时钟周期的跨域传播延迟，写后应立即回读计数寄存器时需先等待/轮询 `CFG_PENDING`。
2. **DVP 输入位宽**：仅支持 `DVP_DWIDTH=8` 字节串行输入（其他取值 elaboration 期报错）；
   多字节每拍输入需扩展合并逻辑。
3. **配置生效时机**：pclk 域参数（含 `CTRL.EN`）在 `pvref` 帧边界整组提交，且每个帧边沿只推进一次请求，
   多笔配置需若干帧才能全部生效；写入与帧边界竞态按「本帧用旧值」处理（见 §6.3）。
4. **FIFO 原语**：`axis_async_fifo` 为行为级实现（仿真用），综合阶段需按接口替换为厂商异步 FIFO 原语。
5. **形式化**：断言已按 formal-friendly 方式编写，但未搭建形式化工具环境，未做有界证明。
6. **代码覆盖率**：`-Cover` 会同时开启代码覆盖率，但当前只统计功能覆盖率，代码覆盖率未纳入验收。
7. **非标准端口**：`awport` / `arport` 为非标准端口，仅做连通性与 X/Z 检查，不纳入标准协议检查。
8. **Makefile**：本机未安装 `make`，未做实机验证；内部调用的 PowerShell 脚本均已验证。
9. **并发运行**：工作库名固定（`work_demo` / `work_dvp2axi` / `work_rstw`），不支持同一用例的真正并发运行。
10. **覆盖率能力开关**：异常响应与非 0 ID 的 bin 由**编译期**开关决定（ModelSim 2020.4 不支持 covergroup 参数端口）。
11. **复位窗口用例为白盒**：`tb_vrf_axil_rst_window` 直接驱动监视视角接口（该协议合法窗口在全系统激励下不可达）。
12. **数据通路阶段的诊断开关**：数据通路用例期间关闭「失败回注 + 宽监视」（`cfg.enable_repro=0`），
    避免长帧下逐拍宽监视使日志爆炸；帧级失败由 `vrf_axis_frame_chk` 给出逐拍明细，寄存器阶段仍保持开启。
13. **异步 FIFO 两侧复位必须成对**：RTL 侧只对 `SOFT_RST/CLR_FIFO` 这类冲刷动作成对复位写侧/读侧指针
    （`CLR_CNT` 只清计数、不动 FIFO）；用例在拉 `aresetn` 时同时脉冲 `prst_n`。任一侧单独复位会造成
    格雷码指针失配并持续送出幻影 beat。

---

## 后续建议

- **覆盖率口径固化**：在 `vrf_axil_cov` 中引入能力开关（如 `cov_has_err_resp` / `cov_has_id`），由 DUT 配置驱动排除项，避免接入新 DUT 时漏改。
- **扩展至 AXI-Stream**：按现有分层新增 `vrf_axis_*` 组件，复用接口句柄表、配置类、计分板与报告框架。
- **形式化接入**：把 `vrf_axil_chk` 的属性集抽出为独立 formal 属性文件，配合 `assume` 约束做有界证明。
- **DVP 侧激励**：待 RTL 数据通路实现后，补齐 DVP 时序激励与帧级计分板，实现全链路端到端验证。
- **CI 集成**：把 `regression.ps1` 接入流水线，以 `summary.txt` 与 UCDB 作为门禁产物。