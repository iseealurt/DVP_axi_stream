# AXI4-L 自建验证库开发报告@20260915

对应开发计划：`Doc/Dev_plan_0916.md`
API 文档：`Doc/API_VRF_AXI4L.md`
仿真工具：ModelSim SE-64 2020.4（vlog/vsim/vcover 2020.10）

---

## 1. 结论总览

| 项 | 结果 |
|---|---|
| 库本体 | 已交付，`bench/lib` 下 12 个类/模块 + 3 个接口 + 挂钩宏 |
| 库自测用例 `tb_vrf_axil_demo` | **PASSED**（事务比对 285 项，失败 0） |
| 接入示例 `tb_dvp2ax_stream` | **PASSED**（事务比对 539 项，失败 0，跳过 1） |
| 协议断言 | 两用例分别检查 5238 / 7208 次，失败 0 次 |
| 上电连通性自检 | 21 个总线信号全部通过（0 连接错误、0 X/Z、4 个恒定信号为设计常量） |
| 功能覆盖率 | 100.00%（可达 bin 37/37，539 次采样），coverpoint/cross 明细均可从 UCDB 查看 |
| 批量回归 | 5 个随机种子全部 PASSED，累计检查 2695 项 |
| 失败复现链路 | 已通过故障注入自测验证（失败检测 → 回注复现 → 宽监视 → 错误报告 → 种子落盘） |
| 编译与仿真告警 | **0 错误、0 告警**（编译期与仿真期均为 0） |
| 代码评审 | 已完成四轮外部评审并按意见修正，详见 §10（65 条）、§11（22 条）、§12（20 条）、§13（12 条） |

**验收标准达成情况（对照开发计划）：**

| # | 验收标准 | 结果 |
|---|---|---|
| 1 | 库自带 demo 用例全部 PASS | 达成（285 项，0 失败） |
| 2 | DVP2axi_stream 寄存器块完成度不低于 407 项检查且全部 PASS | 达成（539 项，0 失败；覆盖项逐项对照见 §5.2） |
| 3 | 新增 X/Z、握手稳定性、超时三类协议检查并全部 PASS | 达成（21 条断言属性，失败 0） |
| 4 | 生成功能覆盖率报告与连通性自检报告 | 达成（可达 bin 100.00% + UCDB；21 信号自检） |
| 5 | 回归脚本一键跑出通过率与失败用例清单汇总 | 达成（`regression.ps1`，输出 `summary.txt`） |
| 6 | API 文档齐备，可不改库本体接入新 DUT | 达成（`Doc/API_VRF_AXI4L.md` §18 给出接入步骤） |

---

## 2. 交付物清单

| # | 交付物 | 路径 | 状态 |
|---|---|---|---|
| 1 | 库本体源码 | `bench/lib/`（IF / Pkg / Reg / Seq / Drv / Mon / Slv / Cov / Env / Chk） | 已交付 |
| 2 | API 接口文档 | `Doc/API_VRF_AXI4L.md` | 已交付 |
| 3 | demo 环境与自测用例 | `bench/tb/tb_vrf_axil_demo.sv`（含从机参考模型挂具） | 已交付 |
| 4 | DVP2axi_stream 验证报告 | `log/tb_dvp2ax_stream_report.txt`（本报告 §5 引用其数据） | 已交付 |
| 5 | 自动化脚本 | `bench/scripts/run.ps1`、`regression.ps1`、`sim.do`、`filelist.f`、`Makefile` | 已交付 |

### 2.1 文件规模

| 文件 | 行数 | 职责 |
|---|---:|---|
| `bench/lib/IF/vrf_axil_if.sv` | 273 | 三视角接口 + 通配符自动连接挂钩宏（含驱动/采样约定） |
| `bench/lib/Pkg/vrf_axil_pkg.sv` | 35 | 库顶层 package（汇聚各分片） |
| `bench/lib/Pkg/vrf_axil_types.svh` | 77 | 类型枚举、接口句柄表（含冲突标志）、全局控制类 |
| `bench/lib/Pkg/vrf_axil_txn.svh` | 184 | 事务类与约束 |
| `bench/lib/Pkg/vrf_axil_cfg.svh` | 65 | 配置类 |
| `bench/lib/Reg/vrf_axil_regmodel.svh` | 248 | 轻量寄存器模型（RAL-like） |
| `bench/lib/Seq/vrf_axil_direct_lib.svh` | 50 | 定向用例库（按名注册/挂载） |
| `bench/lib/Seq/vrf_axil_sequence.svh` | 69 | sequence（generator） |
| `bench/lib/Seq/vrf_axil_sequencer.svh` | 64 | sequencer（仲裁 + 一键导入 + 失败重注） |
| `bench/lib/Drv/vrf_axil_driver.svh` | 305 | 驱动器（双流并发、可空行为模型、直读驱动） |
| `bench/lib/Mon/vrf_axil_monitor.svh` | 237 | 监视器（预测 + 日志 + 宽监视） |
| `bench/lib/Slv/vrf_axil_slave.sv` | 306 | 从机参考模型（单进程驱动所有权、按 DWIDTH 派生、ready/valid 随复位当拍撤销） |
| `bench/lib/Cov/vrf_axil_cov.svh` | 137 | 功能覆盖率收集器（含可达口径 ignore_bins） |
| `bench/lib/Env/vrf_axil_scoreboard.svh` | 241 | 计分板（比对 + 报告 + 失败复现触发） |
| `bench/lib/Env/vrf_axil_env.svh` | 279 | 环境类（一键启用 / 细粒度控制） |
| `bench/lib/Chk/vrf_axil_bringup.svh` | 333 | 上电信号连通性自检 |
| `bench/lib/Chk/vrf_axil_chk.sv` | 305 | 协议检查器（AW/W 独立计数、载荷按 valid 门控、门限对齐） |
| `bench/tb/tb_vrf_axil_demo.sv` | 245 | 库自测用例 |
| `bench/tb/tb_dvp2ax_stream.sv` | 456 | DVP2axi_stream 接入示例 |
| `bench/scripts/filelist.f` | 25 | 编译文件列表 |
| `bench/scripts/run.ps1` | 248 | 单用例编译 + 仿真 + 报告（退出码落盘、工具守卫、工作库占用标记、-Clean 白名单） |
| `bench/scripts/regression.ps1` | 301 | 批量回归（超时/陈旧报告/零检查项/轮次数/启动失败防护） |
| `bench/scripts/check_env.ps1` | 129 | 前置条件检查（含项目根目录写权限，探针文件按进程号唯一命名） |
| `bench/scripts/sim.do` | 50 | ModelSim 脚本 |
| `Makefile` | 98 | 统一入口（PWSH 可分离覆盖、check 前置、按 SHELL 选择 clean 命令、regress 转发 OUT/NRAND） |
| `.gitignore` | 49 | 排除仿真生成物、工作库、日志与报告（含被覆写的输出目录） |
| **合计** | **4258** | 库 + 用例 + 脚本（不含文档） |

---

## 3. 目录结构

```
bench/
  lib/
    IF/    vrf_axil_if.sv          # mst/slv/mnt 三视角接口 + VRF_AXIL_HOOK_DECL 挂钩宏
    Pkg/   vrf_axil_pkg.sv         # 顶层 package
           vrf_axil_types.svh      # 类型/接口句柄/全局控制
           vrf_axil_txn.svh        # 事务类
           vrf_axil_cfg.svh        # 配置类
    Reg/   vrf_axil_regmodel.svh   # 轻量寄存器模型
    Seq/   vrf_axil_direct_lib.svh # 定向用例库
           vrf_axil_sequence.svh   # sequence
           vrf_axil_sequencer.svh  # sequencer
    Drv/   vrf_axil_driver.svh     # 驱动器
    Mon/   vrf_axil_monitor.svh    # 监视器
    Slv/   vrf_axil_slave.sv       # 从机参考模型
    Cov/   vrf_axil_cov.svh        # 功能覆盖率
    Env/   vrf_axil_env.svh        # 环境类
           vrf_axil_scoreboard.svh # 计分板
    Chk/   vrf_axil_bringup.svh    # 上电连通性自检
           vrf_axil_chk.sv         # 协议检查器 + bind
  tb/      tb_vrf_axil_demo.sv     # 库自测（env + 从机参考模型）
           tb_dvp2ax_stream.sv     # 接入示例（env + DVP2axi_stream）
  scripts/ filelist.f  run.ps1  regression.ps1  sim.do
  abandoned/ if_axil_v0.sv  VRF_AXI4L_v0.sv     # 旧 IF/Pkg 资产归档（内容已复用扩展进 lib）
Makefile
Doc/       API_VRF_AXI4L.md  Dev_report_0916.md
```

---

## 4. 四阶段落地情况

### 阶段一：接口层与自动连接 —— 已完成

- `vrf_axil_mst_if` / `vrf_axil_slv_if` / `vrf_axil_mnt_if` 三视角接口，参数化 `AWIDTH/DWIDTH/IDWIDTH`，默认按 DUT 取 32/32/4；均带时钟块 `cb`，初值上电清零避免 X 态。
- `VRF_AXIL_HOOK_DECL(AW,DW,ID)` 挂钩宏：声明与 DUT 端口同名的 AXI4-Lite 信号、实例化 mst/mnt 接口并按名双向挂钩、发布接口句柄到 `vrf_axil_conn_h`。
- 通配符自动连接：挂具内 `MY_DUT u_dut (.*);` 让 DUT 全部端口（含本轮不验证的 DVP/AXIS 端口）按名自动连接，无需逐根手写端口映射。
- 上电信号连通性自检：空闲态静态检查 → 走线激励 → 探针事务，输出信号级结论表（正常 / 恒定 / 未驱动或含 X/Z / 连接错误），并列出本轮不纳入验证的信号。

### 阶段二：核心组件与寄存器模型 —— 已完成

- 事务类（含随机范围、时序覆盖、观测回填、预期回填）、配置类。
- sequence / sequencer / driver / monitor，全部以 mailbox 串起数据流；驱动器读写双流并发，可空行为模型（空闲/到达延迟/反压延迟可全零退化）。
- 轻量寄存器模型 + 计分板：写预测含 wstrb 字节使能、W1C、自清零、CTRL 的 SOFT_RST/CLR_CNT 副作用；读预测在 AR 握手当拍完成。
- 从机参考模型 `vrf_axil_slv_ref`：独立寄存器语义、可配置反压，作为库自测对端，使库的验证不依赖 DUT 完成度。
- 阶段产物：库自测用例端到端闭环 PASS（285 项）。

### 阶段三：用例、覆盖与随机化 —— 已完成

- 定向用例按名注册/挂载（`vrf_axil_direct_lib`）；环境支持 `submit` / `import_directed_queue` / `run_random`。
- 受约束随机：地址区间对齐、读写均衡、strb 三种模式、AW/W 到达延迟、B/R 反压。
- 覆盖率：7 个 coverpoint + 3 个 cross，UCDB 落盘。
- 阶段产物：demo 与 DVP2axi_stream 用例全部 PASS，覆盖率报告生成。

### 阶段四：断言、失败复现与报告回归 —— 已完成

- 独立 binder 检查器 `vrf_axil_chk`：21 条属性覆盖 X/Z、握手稳定性、通道协议、响应合法性、超时、复位约束；按 `+define+` 选择 bind 目标。
- 失败复现：seed 记录 → 失败事务回注 sequencer 单笔重注 → monitor 宽监视 → 格式化错误报告 + 种子落盘。
- 报告与回归：`report()` 输出统一文本报告；`regression.ps1` 多种子批跑、日志隔离、解析汇总。
- API 文档输出。
- 阶段产物：验收标准全项达成。

---

## 5. 验证结果

### 5.1 库自测用例 `tb_vrf_axil_demo`

被测对端为从机参考模型（不依赖任何 RTL），流程为 `env.run_all()` 一键环境。

| 项 | 结果 |
|---|---|
| 定向用例 | 9 组（复位默认值/RW 回读/wstrb/自清零/只读保护/未映射/反压/AW-W 分离/读写并发），按名 `"ALL"` 挂载 |
| 随机事务 | 250 笔 |
| 发起事务数 | 285 |
| 参与比对检查 | 285 |
| 通过 / 失败 / 跳过 | 285 / 0 / 0 |
| 协议断言检查 / 失败 | 5238 / 0（种子 12345；从机模型的握手/复位处理改动会让随机延迟的抽取次序变化，故与上一轮数值略有差异，结论与检查项数不变） |
| 连通性自检 | 21 信号，连接错误 0、X/Z 0、恒定 4（`bid`/`bresp`/`rresp`/`rid` 为设计常量） |
| 结论 | `SIMULATION PASSED` |

### 5.2 DVP2axi_stream 接入示例 `tb_dvp2ax_stream`

| 项 | 结果 |
|---|---|
| 定向阶段 | 13 个（复位默认值、RW 回读、wstrb、CTRL 自清零与写动作、内部事件注入、W1C、SOFT_RST/CLR_CNT 行为、只读保护、未映射/保留地址、B/R 反压、AW/W 分离、读写并发、复位打断响应） |
| 随机回归 | 400 笔受约束随机事务 |
| 发起事务数 | 540 |
| 参与比对检查 | 539（1 笔为复位打断，预期跳过） |
| 通过 / 失败 / 跳过 | 539 / 0 / 1 |
| 协议断言检查 / 失败 | 7208 / 0（种子 12345） |
| 连通性自检 | 21 信号，连接错误 0、X/Z 0、恒定 4 |
| 功能覆盖率 | 100.00%（可达 bin 37/37，539 次采样） |
| 结论 | `SIMULATION PASSED` |

**与历史仿真报告（`Doc/AXI4_Lite_Sim_Report.md`）17 项覆盖项的逐项对照：**

| 历史覆盖项 | 本库对应实现 |
|---|---|
| 1 复位默认值 | `ph_reset_defaults()`：23 个寄存器逐一回读并与模型比对 |
| 2 全部 R/W 寄存器写入后回读一致 | `ph_rw_readback()`：13 个 R/W 寄存器写后回读 |
| 3 wstrb 按字节更新 SCRATCH | `ph_wstrb()`：5 种选通模式写 + 回读 |
| 4 CTRL 自清零位 | `ph_ctrl_actions()`：bit1/bit4/bit5 写 1 后回读为 0 |
| 5 内部事件脉冲置位计数/错误/中断 | `ph_events()`：层次化 force 6 个事件并同步模型后回读 |
| 6 ERR_FLAG 按位 W1C | `ph_w1c()` |
| 7 INT_STATUS 按位 W1C | `ph_w1c()` |
| 8 SOFT_RST 清计数/错误/中断但保留配置 | `ph_softrst_cmp()` |
| 9 CLR_CNT 清计数/错误但保留 INT_STATUS | `ph_softrst_cmp()` |
| 10 只读寄存器写被忽略 | `ph_ro_protect()`：8 个只读寄存器写后回读 |
| 11 未映射地址写不改、读返回 0 | `ph_unmapped()`：0x100 / 0x1C / 0x34 / 0x50 |
| 12 B 通道反压 | `ph_backpressure()`：`force_bready_delay=10` |
| 13 R 通道反压 | `ph_backpressure()`：`force_rready_delay=10` |
| 14 读写通道并发 | `ph_concurrent()` + 随机回归全程读写双流并发 |
| 15 AW/W 分离握手 | `ph_aw_w_split()`：AW 延迟 0、W 延迟 12 |
| 16 B 通道事务期间异步复位 | `ph_reset_test()`：bvalid 拉高后拉低复位，校验复位后全部默认值 |
| 17 bid/rid=0、bresp/rresp=OKAY | 计分板对每一笔事务检查 ID 与响应编码合法性 |

> 结论：历史覆盖项 100% 对应实现，且事务比对检查项由 407 项提升至 **539 项**；
> 另新增 X/Z、握手稳定性、超时三类协议断言（本用例 7208 次检查），为原有报告未覆盖的维度。

### 5.3 功能覆盖率明细

功能覆盖率只衡量「DUT 能够表现出的行为」，因此结构非法与当前 DUT 不可达的 bin 以 `ignore_bins` 排除，不计入分母（排除清单与复核要求见 `Doc/API_VRF_AXI4L.md` §11）。

| 覆盖点 / 交叉 | 覆盖率 | 排除的不可达 bin |
|---|---:|---|
| `cp_dir`（读写方向） | 100% | — |
| `cp_addr`（5 个地址区间） | 100% | — |
| `cp_strb`（写方向字节选通） | 100% | `4'b0000`（结构非法：写必须至少选通一个字节） |
| `cp_resp`（响应类型） | 100% | `EXOKAY`（AXI4-Lite 不使用）、`SLVERR`/`DECERR`（DUT 不产生错误响应） |
| `cp_id`（主机 ID） | 100% | `[1:15]`（DUT 的 `bid/rid` 恒为 0） |
| `cp_ro`（只读访问） | 100% | — |
| `cp_unmapped`（未映射访问） | 100% | — |
| `cx_dir_addr`（方向×地址区间） | 100% | — |
| `cx_dir_strb`（方向×字节选通） | 100% | 读方向整列（读事务无字节选通语义） |
| `cx_dir_resp`（方向×响应） | 100% | 异常响应列（同 `cp_resp`） |
| **整体** | **100%** | 覆盖 bin 37/37，未命中 0 |

**修正前的 70.63% 是怎么来的（问题定位记录）：**

ModelSim 的 covergroup 指标是各 coverpoint/cross 百分比的**等权平均**。修正前有 4 个维度含大量不可达 bin：

| 维度 | 修正前 | 原因 |
|---|---:|---|
| `cp_id` | 6.25% | DUT 的 `bid/rid` 硬编码为 0，16 个 ID bin 只能命中 1 个 |
| `cp_resp` | 25% | 仅 OKAY 可达，SLVERR/DECERR/EXOKAY 不可达 |
| `cx_dir_strb` | 50% | 读方向 6 个 bin 不可达；写方向 `none` bin 不可达 |
| `cx_dir_resp` | 25% | 同 `cp_resp` |

代入：`(100×6 + 25 + 6.25 + 50 + 25) / 10 = 70.63%`。

**同时修正了一个真实缺陷**：读事务采样时取观测对象的 `txn_strb`，而监视器构造观测对象时该字段初值为 0，导致读方向的字节选通全被记入 `none` bin（表现为 `rd×none` 反而"被覆盖"）。现改为：监视器对读事务统一置 `obs_strb = '1`，覆盖率按 `obs_strb` 采样，并用 `coverpoint strb iff (dir == WR)` 把该覆盖点限定到写方向。

### 5.4 批量回归

```
# 测试用例 : tb_dvp2ax_stream
# 回归轮次 : 5        随机种子 : 1, 2, 3, 4, 5
# 通过轮次 : 5        失败轮次 : 0        累计检查项 : 2695
Seed     Checks     Failures   AssertErr    Verdict
1        539        0          0            PASSED
2        539        0          0            PASSED
3        539        0          0            PASSED
4        539        0          0            PASSED
5        539        0          0            PASSED
# 结论 : REGRESSION PASSED
```

### 5.5 失败复现与错误报告链路验证（故障注入自测）

以 `+fault_inject=1` 人为破坏寄存器模型镜像，验证失败处理链路：

| 环节 | 观测结果 |
|---|---|
| 失败检测 | `[685000] fault_inject_rd[35] RD addr=0x80 : 读数据不一致：模型预期 0xdeadbeef，总线返回 0x0` |
| 失败回注复现 | `[685000] [REPRO] 失败事务已回注 sequencer 复现，并开启宽监视模式`，并按 `repro_max_attempts` 重注复现 2 次 |
| 宽监视 | 生成 `vrf_axil_demo_wide_trace.txt`（逐拍记录全部总线信号） |
| 格式化错误报告 | `vrf_axil_demo_err.txt` 输出「失败事务 #N / 时间戳 / 激励 / 观测 / 期望读数据 / 期望响应 / 失败原因」 |
| 种子落盘 | `repro_seed.txt` 写入随机种子，可用 `-Seed <n>` 整用例回放 |
| 统计 | 检查 3 项、失败 3 项（原始 1 笔 + 复现 2 笔） |

---

## 6. 关键机制实现说明

### 6.1 通配符自动连接

**方案**：挂具模块 + DUT 端口按名通配符连接。

```
module my_harness (input logic aclk, input logic aresetn);
  import vrf_axil_pkg::*;
  `VRF_AXIL_HOOK_DECL(32, 32, 4)   // 声明同名信号 + 挂接接口 + 发布句柄
  MY_DUT u_dut (.*);               // DUT 全部端口按名自动连接
endmodule
```

**为什么不用 `bind`**：实测确认 SystemVerilog 的 `bind` **只能观测**目标模块内部信号，**无法驱动**其输入端口——被 bind 模块驱动的 DUT 输入端口在仿真中不生效（编译通过但驱动值为 X）。因此库改用挂具方案：DUT 端口仍按名自动连接，接口连接由库提供的挂钩宏一次性完成。

### 6.2 上电信号连通性自检

三步式：空闲态静态检查（X/Z + 两侧取值一致）→ 走线激励（可自由翻转的信号做 0/1 走线）→ 探针事务（一读一写覆盖有效/就绪/响应信号并校验回读）。结论按信号给出「正常 / 恒定未跳变 / 未驱动或含 X/Z / 连接错误」，并在验证报告头输出。

### 6.3 信号驱动状态检查

| 类别 | 实现 |
|---|---|
| X/Z 与复位约束 | `p_no_xz`（21 位总线信号打包检查）、`p_reset_no_resp` |
| 握手稳定性 | `p_aw_stable`/`p_w_stable`/`p_ar_stable`/`p_b_stable`/`p_r_stable`（`$stable` + valid 保持） |
| 通道协议与 resp 合法性 | `p_b_needs_req`/`p_r_needs_req`（挂起计数）、`p_rresp_legal`/`p_bresp_legal` |
| 超时 | 五通道停滞计数器 + `p_*_timeout`，门限由 `cfg.timeout_cycles` 注入 |

断言采用「成功动作计数 + 失败动作计数并 `$error`」的写法，既统计检查次数也定位违例。

### 6.4 失败用例自动化复现

seed 回放 + 失败事务单笔重注：

1. 每轮仿真记录随机种子并写入报告与 `repro_seed.txt`，脚本可 `-Seed <n>` 整用例回放；
2. 计分板判定失败后，克隆该事务、置 `is_repro`、回注 sequencer 的复现队列（优先级最高）；
3. 同时通知 monitor 进入宽监视模式，逐拍记录全部总线信号；
4. 生成格式化错误报告 `<test>_err.txt`。

### 6.5 功能覆盖率

covergroup 定义在 package 作用域，以 `ref` 形参绑定采样变量，由 `vrf_axil_cov` 持有实例并显式 `sample()`；UCDB 由脚本 `coverage save -onexit` 生成。

覆盖率按「可达口径」统计：结构非法（AXI 写事务全零选通、读事务字节选通）与当前 DUT 不可达（EXOKAY、SLVERR/DECERR、非 0 主机 ID）的 bin 以 `ignore_bins` 排除；`report_note()` 会把口径说明写入验证报告，避免指标被误读。

### 6.6 仿真结束机制

`vrf_axil_done_ctrl::pending` 实现 objection 式完成计数：提交事务 +1，计分板比对完成 -1；`env.wait_idle()` 等待归零并留 4 拍收尾，另有 `cfg.max_txn` 与 `cfg.max_sim_time` 上限兜底。

---

## 7. 与开发计划的偏差说明

| # | 计划内容 | 实际实现 | 原因 |
|---|---|---|---|
| 1 | 库文件命名 `vrf_axil_*.sv` | 被 include 进 package 的分片使用 `.svh`，独立编译的接口/检查器/参考模型/用例仍为 `.sv` | 避免分片被误当独立编译单元重复编译 |
| 2 | 通配符自动连接用 `bind` | 改为「挂具模块 + `.*` 按名自动连接 + 挂钩宏」 | 实测 `bind` 无法驱动目标模块输入端口（§6.1） |
| 3 | 驱动类含「虚拟主从机接口」 | 驱动器持有 `slv_vif` 与 `role` 字段，当前仅实现 MST 角色；从机侧由独立的 `vrf_axil_slv_ref` 承担 | 本轮被测对象均为 AXI4-Lite 从设备，从机角色无使用场景，保留为复用扩展点 |
| 4 | 类层参数化位宽 | 接口层与从机参考模型参数化；类层通过 `typedef` 单一特化（`VRF_AW/DW/ID`） | 降低跨类参数化带来的类型匹配风险；改一处 typedef 即可整体切换位宽 |
| 5 | `Makefile` 统一入口 | 已提供，内部调用已验证的 PowerShell 脚本 | 本机未安装 `make`，无法在本机执行验证；采用薄封装避免双份脚本逻辑漂移 |
| 6 | 「复用并扩展现有 `bench/IF` 与 `bench/Pkg`」 | 信号清单、事务字段与约束均已复用并扩展进 `bench/lib/IF`、`bench/lib/Pkg`；原文件归档到 `bench/abandoned/if_axil_v0.sv`、`bench/abandoned/VRF_AXI4L_v0.sv` | 开发计划同期批准了「`bench/lib` 分层」目录结构，原目录不在新结构内；归档以保证单一事实来源 |

---

## 8. 调试过程中定位并解决的问题

以下问题均在开发过程中实际出现并已修复，记录以备后续复用：

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | `bind` 到 DUT 的模块驱动的信号无效 | SystemVerilog `bind` 无法驱动目标模块输入端口 | 改用挂具 + 端口按名通配符连接 + 挂钩宏 |
| 2 | 未实例化的 bind 目标报「未解析引用」 | 只用 demo 用例时 `DVP2axi_stream` 未被实例化 | bind 语句用 `+define+` 按编译模式选择目标 |
| 3 | 同方向事务配对整体错位一笔、并出现重复观测 | 驱动侧在事务驱动完成**后**才向计分板登记，监视器可能先完成观测；另外 `fork ... join_none` 传入循环内类句柄被延迟求值，导致同一观测对象被重复投递 | 驱动侧改为「先登记、后上总线」；监视器改为「采样主循环 + 每方向独立响应等待进程 + 邮箱传递」，消除句柄共享 |
| 4 | 并发同址读写时读数据比对偶发失败 | 从机参考模型的寄存器提交在「同拍读写」下顺序不确定，与 RTL 边沿语义不一致 | 参考模型寄存器提交改为单一 `always` 进程，同拍内先采样读、后提交写（与 DVP2axi_stream 语义一致） |
| 5 | 复位打断响应事务时报「事务 ID 非 0：实际 x」 | 反压延迟期间未感知复位、`obs_id` 未初始化、跳过判据只看驱动侧 | 延迟等待改为逐拍检测复位；事务观测字段统一初始化；跳过判据改为「驱动侧或监视侧任一判定被打断」 |
| 6 | 功能覆盖率恒为 0% | ModelSim 不支持在类内声明内嵌 covergroup 实例变量，也无法对类内 covergroup 采样统计 | covergroup 移至 package 作用域 + `ref` 形参 + 类内实例化 + 显式 `sample()`；`vsim` 增加 `-coverage` |
| 7 | 组合型 `ready` 信号被自检误报为「恒定未跳变」 | 组合型 `ready` 只维持单拍，逐拍采样未必能捕捉 | 探针握手时直接记录 ready 类信号的跳变（以握手观测为准） |
| 8 | 一键流程在复现完成前提前结束 | 复现事务未计入完成计数 | `do_repro` 回注事务时同步 `pending++` |
| 9 | 无失败用例但功能覆盖率仅 70.63% | 覆盖率口径含大量「当前 DUT 不可达」的 bin（异常响应、非 0 ID、读方向字节选通），被 ModelSim 的等权平均拉低 | 按可达口径标定 `ignore_bins`，并用 `iff` 把字节选通覆盖点限定到写方向；详见 §5.3 |
| 10 | 读方向的字节选通被误记入 `none` bin | 采样取观测对象的 `txn_strb`，而监视器构造观测对象时该字段初值为 0 | 监视器对读事务统一置 `obs_strb='1`，覆盖率按 `obs_strb` 采样 |
| 11 | 去掉时钟块输出后，DVP2axi_stream 的首笔读事务报「AR 握手超时」，DUT 的 `rvalid` 长期滞留 | **采样相位取错**：被测信号经 `assign` 连到接口变量，组合型 `ready` 会在握手当拍被对端更新为后沿值；直读接口变量取到的是**后沿值**，而时钟块以 `#1step` 采样取的是**前沿值** | 确立「自身驱动信号直读、被测信号必须用时钟块采样」的统一约定，并写入接口文件头；详见 §10 第 4 条 |

---

## 9. 已知限制与后续建议

### 9.1 已知限制

1. **验证范围**：本轮仅覆盖 AXI4-Lite 寄存器接口；DVP 输入与 AXI-Stream 输出不纳入验证，也未做 tie-off——报告头会明确标注这 11 个信号为「本轮不纳入验证」，需与真实缺陷区分。当前 RTL 中 `pdin/pvref/phref/axis_tready` 为未使用输入、`axis_tvalid/tdata/tlast` 恒为 0，不存在 X 态向寄存器块传播的风险。
2. **形式化**：断言已按 formal 友好的形式编写（属性独立、含 `disable iff` 门控、无时序依赖的过程语句），但本轮未搭建形式化工具环境，未做有界证明。
3. **代码覆盖率**：`-Cover` 会同时开启代码覆盖率（语句/分支/条件/表达式/FSM/翻转），本报告只统计功能覆盖率；代码覆盖率未纳入验收。
4. **`awport`/`arport`**：为非标准端口，按 DUT 现有定义保留，未纳入标准协议检查（仅做连通性与 X/Z 检查）。
5. **覆盖率口径**：功能覆盖率采用「可达口径」（不可达 bin 以 `ignore_bins` 排除），当前为 100.00%。排除清单与复核要求见 §5.3 与 `Doc/API_VRF_AXI4L.md` §11；接入新 DUT 时须复核其有效性。
6. **Makefile** 未在本机验证（本机未安装 `make`）。
7. **并发运行**：工作库名固定为 `work_demo` / `work_dvp2axi`，同一个用例的两次并发运行会共用同一个库。`run.ps1` 在工程根目录写占用标记 `.vrf_axil_owner_<lib>`（原子创建、记录 PID）：被存活的同用例运行占用时**直接以退出码 3 拒绝**，`-Clean` 也会先检查三个工作库的占用情况；进程已结束的陈旧标记会被接管。仍不支持真正并发的同一用例运行（见 §13.2）。

### 9.2 后续建议

1. **覆盖率口径固化**：当前 `ignore_bins` 依据本项目两台从端的实际能力手工标定；建议在 `vrf_axil_cov` 中引入能力开关（如 `cov_has_err_resp`、`cov_has_id`），由 DUT 配置驱动排除项，避免接入新 DUT 时漏改。
2. **扩展至 AXI-Stream**：按库现有分层新增 `vrf_axis_*` 组件（driver/monitor/检查器），复用接口句柄表、配置类、计分板与报告框架。
3. **形式化接入**：把 `vrf_axil_chk` 的属性集抽出为独立的 formal 属性文件，配合 `assume` 约束做有界证明。
4. **DVP 侧激励**：待 RTL 数据通路实现后，补齐 DVP 时序激励与帧级计分板，实现真正的全链路端到端验证。
5. **CI 集成**：把 `regression.ps1` 接入流水线，以 `summary.txt` 与 UCDB 作为门禁产物。

---

## 10. 代码评审问题修正记录

本轮已完成一轮外部代码评审（`review/review_report_0916.md`，65 条意见），逐条修正并重新验证如下。

### 10.1 结果传播链路（评审头号问题：可能静默误报 PASS）

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| `run.ps1` 未校验 `vlib`（管道到 `Out-Null`） | 检查 `$LASTEXITCODE`，失败即以 3 退出 | 人为使库不可写时脚本以 3 终止 |
| `run.ps1` 未校验 `vsim`，沿用上一次 `$LASTEXITCODE` | 先 `Get-Command vsim` 确认真实存在，再检查退出码 | — |
| `run.ps1` 的 `Remove-Item -Recurse -Force` 在未确认工作目录时执行 | 先校验 `$root` 存在、`Set-Location` 生效、`filelist.f` 存在，再执行任何递归删除 | 从错误目录调用时以 2 终止 |
| `$LogDir` 直接拼进 ModelSim 的 Tcl `do` 字符串（注入面） | 拒绝危险取值，并用 Tcl 花括号 `{...}` 引用路径；第二轮进一步把过滤规则收敛为「只拒绝 `{`/`}` 与换行」（空白在花括号内本就安全），见 §11.2 | `-LogDir "a b"` 现可正常使用 |
| `-Seed 0` 与「未提供种子」不可区分；`-Nrand <= 0` 被静默丢弃 | 改为按 `$PSBoundParameters` 判断是否显式传参，0 亦会下发 | `-Seed 0` 可复现 |
| `regression.ps1` 丢弃子进程退出码 | 采集退出码；`run.ps1` 另行把退出码写入 `<LogDir>/<Test>.exit`（PowerShell 取 `Start-Process -PassThru` 的 `ExitCode` 不可靠），回归优先读该文件 | 汇总表 `Exit` 列全部为 0 |
| 回归轮次可能解析到上一轮遗留报告（陈旧证据） | 轮次开始前删除报告与退出码文件，并校验报告 `LastWriteTime` 晚于本轮开始 | 删除报告后该轮判为 `NO_REPORT` |
| 只要报告字符串为 `PASSED` 即算通过（零检查项也算） | 要求「报告新鲜 + 统计字段解析成功 + 检查项 > 0 + 失败/断言失败为 0 + 退出码为 0」才判通过 | 报告缺字段时判 `PARSE_ERROR` |
| 回归脚本无超时、不恢复工作目录、输出目录复用 | 新增 `-TimeoutSec`（默认 900s，超时杀子进程并判 `TIMEOUT`）、`try/finally` 恢复原目录、输出目录按「时间戳+PID」命名空间隔离 | 5 轮回归输出到独立目录 |

### 10.2 库代码缺陷

| 评审意见 | 修正 |
|---|---|
| 检查器要求 AW/W 同拍握手（合法的主机分离握手会被误判、计数下溢） | 改为 `aw_cnt`/`w_cnt`/`ar_cnt` 独立计数，B 响应要求 `aw_cnt>0 && w_cnt>0` |
| 计数器无下界，非法响应会把计数打成负数后连续漏检 | 全部递减改为饱和在 0；并在复位或检查挂起时清零 |
| `p_no_xz` 要求载荷在 valid 无效时也已知（合法实现可留 X） | 握手/控制信号常检；载荷按对应 valid 门控 |
| 超时门限差一、诊断值偏小 | 统一按「停滞长度 = 计数 + 1」比较与报错，门限语义与诊断值一致 |
| 挂起期间停滞计数不清零，恢复检查后可能立刻误报超时 | `gating` 有效时清零全部停滞计数 |
| 从机参考模型 `rst_task` 与读写任务并发驱动同一组时钟块输出；复位期间不中断在途传输 | 删除 `rst_task`，改为 `wr_task`/`rd_task` 各独占一半信号，并在反压/握手/响应每个阶段检查复位后放弃传输 |
| 从机参考模型把 `store`/`rd_cap`/`strb` 硬编码为 32 位/4 位 | 全部按 `DWIDTH` 派生（含 wstrb 合并函数），并加 `initial $fatal` 断言 `DWIDTH==32`（寄存器映射本身按 32 位定义） |
| 接口同时用时钟块输出与 `initial` 直写同一变量（多进程驱动） | 时钟块只保留 input；删除接口内 `initial`；驱动改为直接赋值，主机侧由自检→驱动器顺序独占、从机侧由参考模型独占 |
| 挂具发布静态句柄「后写覆盖」且无检测 | 发布前检测 `published`，冲突时置 `conflict` 并报错；环境检测到冲突即终止（不静默用错句柄） |
| `vlog-2650`：编译单元作用域的 bind 未指定 `-cuname`，可能不参与 elaboration | 编译命令加 `-cuname <test>_cu`；并以断言计数非零确认检查器确实被 elaboration 并生效 |
| `vlog-13233`：同名单元被不同编译选项覆盖 | 每个用例使用独立工作库（`work_demo` / `work_dvp2axi`），彻底消除互相覆盖 |

### 10.3 RTL 修正（`RTL/DVP2axi_stream.v`）

| 评审意见 | 修正 |
|---|---|
| 同拍硬件事件会被随后的 W1C/SOFT_RST/CLR_CNT 整向量赋值静默丢弃 | 引入 `err_event_mask`/`int_event_mask`，把同拍事件合并进清除结果（W1C 与 SOFT_RST/CLR_CNT 三处） |
| `ctrl_new` 为模块级 `reg` 且在时序块内阻塞赋值，综合会推断出非预期的寄存器组 | 改为组合 `wire ctrl_new_w`（`apply_wstrb` + 自清零掩码），时序块只保留 `reg_ctrl` |
| 自清零位无条件清零，未考虑 `wstrb[0]` | 自清零掩码改为 `wstrb[0] ? 32'h32 : 32'h0`，与写动作的字节选通条件一致 |
| `bresp/rresp` 恒为 OKAY，未映射地址与只读寄存器写被静默忽略 | 按评审给出的替代方案**显式文档化**：注释说明「当前实现所有访问返回 OKAY，如需错误上报可返回 SLVERR/DECERR」 |
| 数据通路仍为 tie-off | 属项目已知状态（开发计划已界定数据通路不在本轮范围），未改动；保留 RTL 内 TODO 与文档说明 |

> 寄存器模型的预测语义与上述 RTL 修正保持一致；「同拍事件 + 清除写」的合并语义未被定向用例覆盖（用例不在同拍注入事件），已在模型注释中标注。

### 10.4 生成物与死代码

| 评审意见 | 修正 |
|---|---|
| `work/`、`work_probe3/`、`bench/work/`、`transcript`、`bench/transcript` 等仿真生成物入库（含机器绝对路径、厂商横幅、过期索引） | 工作区文件删除；新增 `.gitignore` 排除 `work*/`、`_info`、`_vmake`、`*.qdb/*.qpg/*.qtl`、`transcript`、`log/`、波形与覆盖率库、`repro_seed.txt`；第二轮把索引中残留的 134 个已跟踪生成物一并移出版本控制（`git rm --cached`），修正后 `git ls-files` 中生成物为 0（见 §11.6） |
| 生成物记录的编译选项与真实脚本可能漂移 | 保留 `bench/scripts/filelist.f` 与脚本作为唯一事实来源；生成物不再入库 |
| `bench/abandoned/` 下 4 个历史文件（含响应比对恒真、超时清理悬挂 ready/valid、零延时死循环等缺陷）可能被误接入 | 新增 `bench/abandoned/README.md` 明确标注为「不参与编译、不参与验证流程」的历史留档，并列出各文件已知缺陷；这些文件不在 `filelist.f` 中，无法被编译 |
| `bench/transcript` 中烟测 `_tmp_cfg_smoke`、`cfg` 静态初始化、零仿真时间等缺陷 | 对应的烟测脚本未在本轮交付物中，transcript 已删除；相关问题随之消失 |

### 10.5 未采纳项与说明

| 评审意见 | 处理 | 理由 |
|---|---|---|
| `Makefile` 的 `PWSH` 应拆分为解释器 + 参数 | 已拆分（`PWSH` / `PWSH_FLAGS`），并新增解析期解释器可用性校验 | 采纳 |
| `Makefile` 的 `clean` 不可移植、吞掉失败 | 已改为按 `OS` 条件选择 `rmdir`/`rm -rf`，并去掉前导 `-` | 采纳（`make` 本机未安装，仍未实机验证，见 §9.1） |
| 删除历史验证代码而不是标注 | 未删除，仅标注为死代码 | 历史留档由项目保留；如需彻底移除，可由维护者执行删除 |
| 让数据通路（DVP/AXIS）落地 | 未采纳（超出本轮范围） | 开发计划已明确本轮仅覆盖 AXI4-Lite 寄存器接口 |

### 10.6 修正后的复验结果

| 项 | 结果 |
|---|---|
| `tb_vrf_axil_demo` | PASSED：事务比对 285 + 协议断言 5238 + 连通性自检 21；**编译 0 错误 0 告警，仿真 0 错误 0 告警** |
| `tb_dvp2ax_stream` | PASSED：事务比对 539 + 协议断言 7208 + 连通性自检 21；**编译 0 错误 0 告警，仿真 0 错误 0 告警** |
| 功能覆盖率 | 两个用例均 100.00%（可达口径），UCDB 正常落盘 |
| 批量回归 | 5 轮全部 PASSED（`Exit=0`、每条 539 项、0 失败、0 断言失败），累计 2695 项 |
| 故障注入自测 | 失败检测/回注复现（2 次）/宽监视/错误报告/种子落盘链路全部生效 |
| 前置条件检查 | `check_env.ps1` 全部通过 |

---

## 11. 第二轮代码评审修正记录

第二轮评审基于第一轮修正后的代码（`review/review_r2.json`：9 个文件、22 条意见），逐条处理并重新验证如下。

### 11.1 回归脚本 `regression.ps1`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| `Start-Process -ArgumentList` 只做空格拼接、不自动加引号，路径含空格时参数被拆开 | 给 `-File` / `-LogDir` 的路径值显式加引号 | 回归全程使用项目绝对路径，5 轮全部正常启动 |
| 两处 `Remove-Item` 用可通配的 `-Path`，与文件内其他路径操作不一致 | 统一改为 `-LiteralPath` | 报告/退出码文件按预期删除 |
| 超时只杀包装进程，`vsim` 孙进程仍占库锁、继续烧 CPU | 超时改用 `taskkill /PID <id> /T /F` 整树终止，并保留 `Kill()` 兜底 | 代码审查确认；正常路径不受影响 |
| 退出码文件读取无容错（空文件使 `.Trim()` 抛异常、残留旧值） | 读取包在 `try/catch` 中并判 `$null`；不可解析即按失败处理（不沿用包装进程退出码） | 5 轮 `Exit` 列均为 0，判定仍正确 |
| 结论只依赖 `$nFail`，循环中途异常退出会「假绿」 | 增加轮次数校验：实际轮次 ≠ 请求种子数即整体判失败，汇总与 `exit` 同步采用该判据 | 汇总新增「回归轮次 : N / M」列，本次 5 / 5 |
| `-Nrand 0` 仍被当作哨兵丢弃（与 `run.ps1` 的语义不一致） | 改为 `$PSBoundParameters.ContainsKey('Nrand')` 判定，显式 0 会转发 | 代码审查确认（默认路径不再强制下发 `+n_rand`） |
| `Start-Process` 失败只报非终止错误，后续 `$proc.WaitForExit()` 会终止整个回归 | 捕获启动异常并显式判该轮失败（`RUN_ERROR`/「子进程启动失败」），不再中断整个回归 | 代码审查确认 |

### 11.2 `run.ps1` 与 `check_env.ps1`

| 评审意见 | 修正 |
|---|---|
| `vsim` 有 `Get-Command` 守卫，`vlib`/`vlog` 没有；命令缺失时 `$LASTEXITCODE` 不刷新，会把上一次的 0 当成成功、在过期库上继续 elaborate | 三个工具（`vlib`/`vlog`/`vsim`）统一在编译前逐个校验，缺失即以 5 终止 |
| `-LogDir` 过滤规则未拒绝 `{`/`}`,而该值被拼进 Tcl 花括号引用 | 过滤规则收敛为「非空 + 不含 `{`/`}` + 不含换行」；同时说明空白/分号/引号在花括号内本就安全 |
| 该规则在 `check_env.ps1` 中重复且需同步 | 两处规则统一为同一表述 |
| `run.ps1` 清理「所有 `work*` 目录」的 `_lock`，会删掉其他并发运行正在使用的库锁 | 收敛为只清理本用例工作库（`$libName`）的 `_lock`；`-Clean` 仍是显式全清 |
| `$PSVersionTable.PSEdition` 在 PowerShell 5.0 不存在，会打印空括号 | 取值前判空，缺失时回退为 `Desktop` |
| 写权限探针只覆盖日志目录，而 `run.ps1` 还需要项目根目录可写（创建工作库、清理 `_lock`） | 探针扩展为「日志目录 + 项目根目录」两项，与前脚本的真实需求一致 |

### 11.3 `Makefile`

| 评审意见 | 修正 |
|---|---|
| `clean` 仍只删 `work`，而 `run.ps1` 实际创建 `work_demo`/`work_dvp2axi`，生成物残留但提示称已清理 | 三个工作库（`work` / `work_demo` / `work_dvp2axi`）在 Windows 与 POSIX 两条分支都删除，提示文案同步为 `work*` |
| `OUT` 文档化为全局可覆盖，但 `regress` 既不转发、脚本也不支持 | `regression.ps1` 新增 `-LogDir`（默认 `log`，回归输出落在 `<LogDir>/regression/...`），`regress` 目标转发 `$(OUT)` |
| `NRAND` 在 `regress` 中被静默忽略，与 `run` 行为不一致 | `regress` 转发 `$(NRAND)`；`NRAND=0` 表示「不显式下发」（避免与「显式 0 是有效取值」冲突），已在头部注释中说明 |
| 解析期解释器探测硬编码选项、且对 `clean`/`-n` 也生效，导致无 PowerShell 的主机无法清理 | 探测改为「递归展开变量」，只在引用它的配方（`check` 目标）中执行；探测仍用最简调用，错误提示同时说明 `PWSH` 应为解释器本体、选项放到 `PWSH_FLAGS` |

### 11.4 从机参考模型 `vrf_axil_slv_ref`

| 评审意见 | 修正 |
|---|---|
| 删除 `rst_task` 后响应 valid 没有异步撤销路径：复位在 `bvalid`/`rvalid` 有效期间拉低时，valid 会保持到下一个时钟沿，使自检 `p_reset_no_resp` 误报（任何在事务中拉复位的 REF_SLAVE 用例都会触发） | 响应等待改为 `fork … join_any`：一支等对端 ready，一支监听 `aresetn` 下降沿；复位沿当拍即撤销 valid，随后 `disable fork` 结束等待。保留「一个信号只有一个写者」的约定（不引入寄存进程作为第二个写者） |
| 请求接受判据用 4 态 `&&`/`!`，采样到 X 时条件为 X 被 `while` 当成假，会把不存在的请求当作已接受（接口去掉 `initial` 初值后，复位释放到 `init_outputs()` 之间确实存在 X 窗口） | 请求判据全部改为 `=== 1'b1` 全等比较：只有确定采样到 1 才认为收到请求 |

### 11.5 RTL `RTL/DVP2axi_stream.v`

| 评审意见 | 修正 |
|---|---|
| `ctrl_new_w`（第 152 行）调用了声明在后的 `apply_wstrb`，违反「函数先声明后使用」，宽松仿真器可过、严格工具可能编译/综合失败 | 把 `apply_wstrb` / `w1c_mask` 两个函数整体上移到寄存器声明之后、所有调用点之前，并在注释中说明该约束 |

### 11.6 `.gitignore` 与索引清理

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 忽略规则只对未跟踪文件生效，旧布局的生成物仍在版本控制中（目标「只保留源码/脚本/文档」未达成） | 把索引中残留的 134 个已跟踪生成物（`work/`、`work_probe3/`、`bench/work/`、`bench/transcript`、`log/`、工作库文件）用 `git rm --cached` 移出版本控制 | `git ls-files` 中匹配生成物规则的条目为 0 |
| `vlib` 会在工作目录生成 `modelsim.ini`，裸奔为未跟踪文件 | 加入忽略清单 | `git status` 无该条目 |
| 生成物规则只覆盖默认 `log/`；`-LogDir`/`OUT` 覆写后，`<Test>.exit`、`<Test>_report.txt` 等成为未跟踪噪声 | 补充 `*.exit`、`*_report.txt`、`*_err.txt`、`*_log.txt`、`*_wide_trace.txt`、`summary.txt` | `-LogDir log_alt` 的回归输出在 `git status` 中不产生任何条目 |

### 11.7 未采纳项与说明

| 评审意见 | 处理 | 理由 |
|---|---|---|
| 工作库名固定（`work_demo`/`work_dvp2axi`），并发运行共用同一库、可能互删库锁；建议按运行标签派生库名或串行化 | **部分采纳**：已把库锁清理收敛到本用例工作库（不再动别人的锁），并在 `run.ps1` 头部与 API 文档中明确「同一用例并发运行需错开」；未引入按标签派生的动态库名 | 动态库名会破坏 `clean` 目标的模式化清理（`make` 本机未安装、无法实测通配删除），且当前工作流为单次运行；若后续确需并发，建议连同 `clean` 一起改为按运行标签管理 |
| 响应 valid 改用带异步复位的寄存进程驱动 | 采用等效方案（任务内 `aresetn` 下降沿监听） | 引入寄存进程会给 `bvalid`/`rvalid` 增加第二个写者，且其复位值依赖异步复位路径在 0 时刻是否产生事件；现方案在保持单写者的同时同样做到「复位沿当拍撤销 valid」 |

### 11.8 第二轮修正后的复验结果

| 项 | 命令 | 结果 |
|---|---|---|
| 库自测用例 | `run.ps1 -Test tb_vrf_axil_demo -Seed 12345` | PASSED：285 比对 + 5142 断言 + 21 自检；编译/仿真 **0 错误 0 告警**（断言计数在 §12 的从机模型改动后为 5238，见 §12.8） |
| DUT 接入示例 | `run.ps1 -Test tb_dvp2ax_stream -Seed 12345` | PASSED：539 比对 + 7208 断言 + 21 自检；编译/仿真 **0 错误 0 告警** |
| 功能覆盖率 + 含空格日志目录 | `run.ps1 -Test tb_dvp2ax_stream -Cover -Seed 12345 -LogDir "log space"` | 100.00%，UCDB 正常落盘（验证了 `-LogDir` 过滤规则放宽与 Tcl 花括号引用） |
| 批量回归 | `regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5"` | 5 / 5 PASSED，累计 2695 项，`exit=0` |
| 回归日志基目录转发 | `regression.ps1 -Test tb_vrf_axil_demo -Seeds "7" -LogDir log_alt` | PASSED，输出落在 `log_alt/regression/run_<时间戳>_<pid>/` |
| 故障注入自测 | `run.ps1 -Test tb_vrf_axil_demo -Nrand 0 -Fault` | 失败检测 → 回注复现（2 次）→ 宽监视 → `_err.txt` 错误报告链路全部生效 |
| 前置条件检查 | `check_env.ps1 -LogDir log` | 全部通过（新增「项目根目录可写」项） |
| 版本控制 | `git status` / `git ls-files` | 生成物条目 0；工作区无生成物噪声 |

---

## 12. 第三轮代码评审修正记录

第三轮评审基于第二轮修正后的代码（`review/review_r3.json`：9 个文件、20 条意见）。评审首次执行时会话文件被本机沙箱拦截而中断，但已产出 15 条意见（记为 r3-a）；调整为把工具主目录重定向到临时目录后重跑，得到完整结果（记为 r3-b，20 条、180 次工具调用、0 失败）。两次结果合并后逐条处理如下（r3-b 未重复、但 r3-a 提出的 3 条同样成立，一并采纳）。

### 12.1 `Makefile`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| `run`/`fault` 恒把 `-Seed 0`/`-Nrand 0` 下发给 `run.ps1`，而脚本对「显式传参」会如实下发 `+seed=0 +n_rand=0`，于是 `make run` 会静默退化为 0 笔随机事务 + 固定种子（与 `demo`/`dvp`、`regress` 的行为不一致） | 引入 `SEED_ARG` / `NRAND_ARG`，用 `$(origin X)` 判断变量是否来自「命令行/环境」：只有显式覆盖才下发，`0` 仍是有效取值 | `make run SEED=0 NRAND=0` 会如实下发（见 12.8 说明） |
| `NRAND_ARG` 用取值 `0` 当哨兵，`make regress NRAND=0` 会被丢弃（与「显式 0 有效」的契约矛盾），且 `00` 之类写法会绕过 | 同上：改为按来源判断，不再按取值过滤 | 代码审查确认 |
| `cover` 是唯一不转发 `SEED`/`NRAND` 的运行类目标，覆盖率跑批无法复现 | `cover`（以及 `demo`/`dvp`）统一转发 `SEED_ARG`/`NRAND_ARG` | 代码审查确认 |
| 解释器探测把 stderr 并入 stdout 且「有任何输出即失败」，会因解释器打印警告而误判；失败路径还会重复展开探测 | 改为回显哨兵串 `VRF_PWSH_OK`，只认哨兵；错误信息不再重复展开探测 | 代码审查确认 |
| `clean` 按 `$(OS)` 选命令，但 make 在 Windows 上也可能用 sh（MinGW/MSYS2），此时 cmd 专用语法报错、且去掉 `-` 后整个目标中止 | 改为按 `$(SHELL)` 选择分支：sh 用 `rm -rf`，否则用 `if exist … rmdir` | 代码审查确认（本机无 `make`，见 §9.1） |

### 12.2 `run.ps1`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| `-Clean` 递归删除项目根下所有 `work*` 目录，`workspace/`、`work_notes/` 之类会被误删（数据丢失），且比构建系统的清理范围更宽 | 收敛为白名单 `work` / `work_demo` / `work_dvp2axi` | 代码审查确认 |
| 工作库无所有权检查，同一用例并发运行会互相覆盖库、互删库锁，且只是注释里警告 | 新增工作库所有权标记（记录 PID）：标记进程仍存活则直接以退出码 3 拒绝，陈旧标记接管；标记由 `Exit-With` 统一清除 | 合成用例实测：存活 PID → 退出码 3 且不编译；陈旧 PID → 正常接管并通过；运行结束后标记已删除 |
| 文件清单守卫用反斜杠路径（`bench\scripts\filelist.f`），与其余位置的正斜杠写法不一致，在非 Windows 分隔符环境下会误判为缺失 | 统一为正斜杠 | 正常运行（本机 Windows 下两种写法均可，改动为一致性） |

### 12.3 `regression.ps1`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 子进程写死 `powershell`，只装 PowerShell 7 的主机上 `make regress PWSH=pwsh` 会失败；且未加 `-NoProfile` | 子进程改用「当前宿主解释器」（取不到时回退 `powershell`/`pwsh`），并统一加 `-NoProfile` | 5 轮回归正常启动并全部通过 |
| `-TimeoutSec` 只判下限，`×1000` 溢出 Int32 会在等待条件里抛错并中断整个回归 | 增加上限校验（86400 秒） | 代码审查确认 |
| 启动失败的诊断信息用了已离开 `catch` 的 `$_`，错误原因可能为空或串到别的错误 | 在 `catch` 内取出并保存 `$launchErr`，在失败分支引用 | 代码审查确认 |
| 陈旧报告判定用报告时间与父进程时钟直接比较，网络盘/粗粒度时间戳会把有效轮次误判为 `STALE_REPORT` | 保留 5 秒容差 | 5 轮均为 `PASSED`（未出现 `STALE_REPORT`） |
| `$aborted` 守卫实际不可达（`try` 只有 `finally`，终止性错误会直接中断脚本，走不到汇总） | 增加 `catch` 记录循环异常，仍走完汇总并把整体判为失败，同时在汇总中打印异常原因 | 代码审查确认 |
| `Verdict` 列宽 11 而 `STALE_REPORT` 为 12 字符，会顶掉 Note 列 | 列宽改为 12 | 汇总表对齐正常 |
| `-LogDir` 校验放行了双引号，而该值会被手工加引号后传给子进程，可提前闭合引号并注入额外参数 | 三个脚本统一把 `"` 列入拒绝字符 | 代码审查确认（Windows 路径本身不允许 `"`） |

### 12.4 `check_env.ps1`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 写权限探针固定使用 `.write_probe`，脚本被中断会在源码树留下残留文件，并发检查还会互相踩踏 | 探针文件名加入进程号（`.vrf_axil_write_probe_<PID>`），成功/失败两条路径都确保清理，并在 `.gitignore` 中兜底忽略 | 检查通过后工作区无任何探针残留（已实测） |
| 绝对 `-LogDir` 会被 `Join-Path` 盲目拼接成非法路径，探针因此误报「不可写」 | 绝对路径按原样使用，相对路径才以项目根为基准 | `check_env.ps1 -LogDir <绝对路径>` 实测通过 |

### 12.5 库代码（从机参考模型 / 检查器 / 接口）

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 只有响应 valid 有复位沿监听，握手 `ready` 脉冲没有：复位落在 ready 窗口内时 ready 会保持到下一个时钟沿，与文件头「不会遗留有效 ready/valid」的承诺不符 | `awready/wready` 与 `arready` 的脉冲等待同样改为 `fork … join_any`（一支等时钟沿、一支等复位下降沿），复位沿当拍撤销 ready | 两个用例回归通过；`ph_reset_test` 复位打断场景断言 0 失败 |
| 请求/响应计数在 `gating` 期间被清零：挂起前已接受的请求，其响应在恢复检查后会被判为「无请求的响应」；挂起窗口内的非法响应又被静默遗忘 | 请求/响应计数只在 `!aresetn` 时清零（它是总线状态）；握手停滞计数仍保持「复位或挂起时清零」 | 两个用例断言 0 失败（自检阶段结束后计数自然回 0） |
| `TIMEOUT_CYCLES_DEFAULT` 参数不可达（`timeout_cycles` 恒 >0，且 0 在其它组件里表示「首拍即超时」，语义冲突），文件头「未配置时用本模块参数」不成立 | 删除该参数与兜底分支，超时门限统一取自 `vrf_axil_ctrl::timeout_cycles`（与 driver/bringup/monitor 同源），并更新文件头与 API 文档 | 编译 0 错误 0 告警；断言 0 失败 |
| 重复挂具的诊断文本说「句柄将被覆盖」，而实现是保留先发布者、丢弃后一个 | 修正为「后一个实例的接口句柄被丢弃，仍保留最先发布的句柄」 | — |

### 12.6 RTL `RTL/DVP2axi_stream.v`

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 自清零掩码 `32'h0000_0032` 与 CTRL 位语义在两处手写，位定义变更时可能失步 | 提为具名 `localparam CTRL_SELFCLR_MASK` 并注明位含义 | 定向用例 `ph_ctrl_actions` 通过 |
| 事件 → 位 的映射在三处重复（掩码拼接、粘滞置位链、寄存器文档），未来增删事件位只改一处就会让 W1C/SOFT_RST 的事件保留静默失效 | 提为 `ERR_BIT_*` / `INT_BIT_*` 具名 `localparam`，掩码改为按位左移构造、置位链按常量索引，实现单一来源 | 编译 0 错误 0 告警；`ph_events` / `ph_w1c` / `ph_softrst_cmp` 全部通过，回归 5/5 通过 |

### 12.7 未采纳项与说明

| 评审意见 | 处理 | 理由 |
|---|---|---|
| 工作库按运行标签命名（如 `work_<lib>_<pid>`）以获得真正的并发隔离 | **改采另一方案**：保留固定库名 + 所有权标记 fail-fast（12.2） | 动态库名会让 `clean` 依赖通配删除（本机无 `make`、无法实测），且当前工作流为单次运行；fail-fast 已消除「静默互相破坏」这一主要风险 |
| 三个脚本中重复的 `-LogDir` 校验规则应抽成公共脚本 | 未采纳（保持三份并同步更新） | 规则只有一行正则、三处错误处理各不相同；为它引入新的被依赖脚本会增加「脚本缺失」这一新的失败模式。已改为在 API 文档中单点说明该规则，本次改动也同步更新了三处 |
| RTL 事件位映射「从单一 `always_comb` 生成」以彻底消除重复 | 部分采纳（12.6：单一常量定义） | 完全改为由一个进程同时驱动置位与掩码属于结构性重构，超出本库（验证侧）对 DUT 的最小改动边界；具名常量已消除失步风险 |

### 12.8 第三轮修正后的复验结果

| 项 | 命令 | 结果 |
|---|---|---|
| 库自测用例 | `run.ps1 -Test tb_vrf_axil_demo -Clean -Seed 12345` | PASSED：285 比对 + 5238 断言 + 21 自检；编译/仿真 **0 错误 0 告警** |
| DUT 接入示例 + 覆盖率 + 含空格日志目录 | `run.ps1 -Test tb_dvp2ax_stream -Clean -Cover -Seed 12345 -LogDir "log space"` | PASSED：539 比对 + 7208 断言 + 21 自检；功能覆盖率 100.00%；**0 错误 0 告警** |
| 批量回归 | `regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5" -TimeoutSec 600` | 5 / 5 PASSED，累计 2695 项，`exit=0`；子进程沿用宿主解释器并带 `-NoProfile` |
| 工作库并发保护（合成用例） | 标记写入存活 PID / 陈旧 PID 各跑一次 | 存活 → 退出码 3 且不编译；陈旧 → 接管并通过；运行结束标记已清除 |
| 故障注入自测 | `run.ps1 -Test tb_vrf_axil_demo -Nrand 0 -Fault` | 失败检测 → 回注复现（3 次）→ 宽监视 → 错误报告链路全部生效 |
| 前置条件检查 | `check_env.ps1 -LogDir log`（另测相对/绝对/含 `{` 三种取值） | 全部通过；绝对路径可用；含 `{` 被拒；工作区无探针残留 |
| 版本控制 | `git status` / `git ls-files` | 生成物条目 0；工作区无生成物噪声 |

> 说明：从机模型的握手/复位改动会让 `$urandom_range` 的抽取次序发生变化，因此 `tb_vrf_axil_demo` 的断言检查次数由 5142 变为 5238（事务数与比对结论不变）；`tb_dvp2ax_stream` 使用 RTL 从端、不经参考模型，断言次数保持 7208 不变。

---

## 13. 第四轮代码评审修正记录

第四轮评审（`review/review_r4.json`：9 个文件、12 条意见）针对的是第三轮修正后的代码，其中 1 条为严重问题、4 条为中等、7 条为较低等级。

> 说明：本轮评审还暴露了一个流程问题——第三轮对从机参考模型「握手 ready 脉冲监听复位沿」的修改**当时并未真正落到文件里**（编辑被后续写入覆盖），而当时只按「代码审查确认」记录、没有复读文件核实。第四轮评审再次指出同一问题后已重新落地并复验（见 13.4）。此后所有 SV/RTL 改动均在编辑后复读文件确认。

### 13.1 严重问题：工作库未被初始化（`run.ps1`）

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 第三轮为写「库内占用标记」而提前 `New-Item` 建出了工作库目录，导致后面的 `if (-not Test-Path <lib> -PathType Container) { vlib }` 永远为真、`vlib` 不再执行；空目录不是有效的 ModelSim 库 | **占用标记移到工程根目录**（`.vrf_axil_owner_<lib>`），脚本不再提前创建库目录；库是否已初始化改为检查 vlib 生成的标记文件 `<lib>/_info`，而不是「目录是否存在」 | `-Clean` 全新建库后 `work_demo/_info` 存在、编译 0 错误；`-Clean` 运行两个用例均通过 |

### 13.2 中等与较低等级问题

| 评审意见 | 修正 | 验证方式 |
|---|---|---|
| 占用标记是「先检查后写入」的非原子序列，两个进程可同时通过检查 | 改为 `FileMode::CreateNew` 原子创建；已存在时先判别「存活则拒绝 / 陈旧则删除后重抢」，重抢仍为原子创建 | 合成用例：存活 PID → 退出码 3；陈旧 PID → 接管并通过；运行结束标记被清除 |
| `-Clean` 在占用检查之前执行，会删掉**另一个**正在运行用例的工作库 | 先对三个工作库逐一做占用检查（任一被存活进程占用即拒绝），再执行删除 | 合成用例：`work_dvp2axi` 标记为存活 PID 时，`-Clean` 被拒绝（退出码 3） |
| `taskkill` 仅 Windows 可用，非 Windows 上异常被空 `catch` 吞掉，`vsim` 孤儿进程会占住库锁 | 先用 `Get-Command` 探测 `taskkill`，不可用时退回 `pkill -TERM -P`，最后仍保留 `Kill()` 兜底 | 代码审查确认（本机为 Windows，走 `taskkill` 分支） |
| `rm -rf "$(OUT)"` 在 `OUT` 为绝对路径时会删除工程外的目录树 | 引入 `OUT_REL`：仅当 `OUT` 不含 `:` 时才纳入删除（绝对路径跳过目录删除，只清工作库） | 代码审查确认（本机无 `make`） |
| `run.ps1` 校验了 `-Nrand` 却未校验 `-Seed`，负值会回绕成无符号大数，报告里的种子无法再复现 | 增加 `-Seed` 非负校验 | `run.ps1 -Seed -5` 以退出码 2 终止 |
| `New-Item -Path` 会把通配字符当模式解析（`New-Item` 无 `-LiteralPath`），`-LogDir 'log[1]'` 会落到别的目录并报「无法创建日志目录」 | `run.ps1` / `check_env.ps1` 都改用 .NET `Directory::CreateDirectory` 按字面路径创建（已存在时为空操作） | `check_env.ps1 -LogDir "log[1]"` 通过且确实创建了字面目录 `log[1]` |
| 从机模型复位判定混用 4 态取反与全等比较，`aresetn` 为 X 时 `... || !aresetn` 得 X 被当成「假」，会把未知复位状态当正常放行 | 两个任务中的复位判定统一改为 `(aresetn !== 1'b1)`（0 与 X 都算处于复位） | 两个用例断言 0 失败；复位打断定向用例通过 |
| RTL：CTRL 自清零掩码仍是字面量，与写动作块里的 `wdata[1]/[4]/[5]` 是两处独立编码 | 提为 `CTRL_BIT_SOFT_RST/CLR_CNT/CLR_FIFO` 具名常量，掩码由常量移位构造、写动作块按常量索引，单一定义 | 编译 0 错误；`ph_ctrl_actions` 通过 |
| RTL：事件 → 位 的成员关系在「粘滞置位链」与「同拍事件掩码」两处重复，只改一处会让同拍事件保留静默失效 | 用掩码作为唯一定义：置位改为 `reg_err_flag <= reg_err_flag \| err_event_mask`（`int` 同理），与第 2/3 节的 W1C / SOFT_RST / CLR_CNT 共用同一掩码，粘滞置位链不再单独写位映射 | 编译 0 错误 0 告警；`ph_events` / `ph_w1c` / `ph_softrst_cmp` 全通过；断言计数与修改前完全一致（7208） |

### 13.3 未采纳项与说明

| 评审意见 | 处理 | 理由 |
|---|---|---|
| 三个脚本中重复的 `-LogDir` 校验规则应抽成公共脚本 | 仍未采纳 | 理由同 §12.7（一行正则、三处错误处理不同；引入被依赖脚本会新增「脚本缺失」失败模式），本次改动已同步更新三处 |
| RTL 事件掩码「由单一 `always_comb` 同时驱动置位与掩码」 | 已用等价方式达成（13.2 末行：掩码即唯一定义） | 不再存在两处编码，无需再引入额外进程 |

### 13.4 第四轮修正后的复验结果

| 项 | 命令 | 结果 |
|---|---|---|
| 库自测用例 | `run.ps1 -Test tb_vrf_axil_demo -Clean -Seed 12345` | PASSED：285 比对 + 5238 断言 + 21 自检；`work_demo/_info` 存在（vlib 已执行）；**0 错误 0 告警** |
| DUT 接入示例 + 覆盖率 | `run.ps1 -Test tb_dvp2ax_stream -Clean -Cover -Seed 12345` | PASSED：539 比对 + 7208 断言 + 21 自检；覆盖率 100.00%；**0 错误 0 告警** |
| 批量回归 | `regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5" -TimeoutSec 600` | 5 / 5 PASSED，累计 2695 项，`exit=0` |
| 占用标记（存活 / 陈旧） | 合成标记各跑一次 | 存活 → 退出码 3 且不编译；陈旧 → 接管并通过；无残留标记 |
| `-Clean` 与占用保护 | `work_dvp2axi` 标记为存活进程后执行 `-Clean` | 退出码 3，未删除他人工作库 |
| 日志目录字面路径 | `check_env.ps1 -LogDir "log[1]"` | 通过，且确实创建字面目录 `log[1]`；无探针残留 |
| 故障注入自测 | `run.ps1 -Test tb_vrf_axil_demo -Nrand 0 -Fault` | 失败检测 → 回注复现（3 次）→ 宽监视 → 错误报告链路全部生效 |
| 非法参数 | `run.ps1 -Seed -5` | 退出码 2 |
