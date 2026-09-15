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
| 协议断言 | 累计检查 6874 次，失败 0 次 |
| 上电连通性自检 | 21 个总线信号全部通过（0 连接错误、0 X/Z、4 个恒定信号为设计常量） |
| 功能覆盖率 | 70.63%（539 次采样），coverpoint/cross 明细均可从 UCDB 查看 |
| 批量回归 | 5 个随机种子全部 PASSED，累计检查 2695 项 |
| 失败复现链路 | 已通过故障注入自测验证（失败检测 → 回注复现 → 宽监视 → 错误报告 → 种子落盘） |
| 编译告警 | 0 错误；编译期 1 个无害告警（`vlog` 对多维关联数组 `foreach` 的语法提示），仿真期 11 个 `vsim-8441` 提示 |

**验收标准达成情况（对照开发计划）：**

| # | 验收标准 | 结果 |
|---|---|---|
| 1 | 库自带 demo 用例全部 PASS | 达成（285 项，0 失败） |
| 2 | DVP2axi_stream 寄存器块完成度不低于 407 项检查且全部 PASS | 达成（539 项，0 失败；覆盖项逐项对照见 §5.2） |
| 3 | 新增 X/Z、握手稳定性、超时三类协议检查并全部 PASS | 达成（21 条断言属性，失败 0） |
| 4 | 生成功能覆盖率报告与连通性自检报告 | 达成（70.63% + UCDB；21 信号自检） |
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
| `bench/lib/IF/vrf_axil_if.sv` | 281 | 三视角接口 + 通配符自动连接挂钩宏 |
| `bench/lib/Pkg/vrf_axil_pkg.sv` | 35 | 库顶层 package（汇聚各分片） |
| `bench/lib/Pkg/vrf_axil_types.svh` | 75 | 类型枚举、接口句柄表、全局控制类 |
| `bench/lib/Pkg/vrf_axil_txn.svh` | 184 | 事务类与约束 |
| `bench/lib/Pkg/vrf_axil_cfg.svh` | 64 | 配置类 |
| `bench/lib/Reg/vrf_axil_regmodel.svh` | 248 | 轻量寄存器模型（RAL-like） |
| `bench/lib/Seq/vrf_axil_direct_lib.svh` | 50 | 定向用例库（按名注册/挂载） |
| `bench/lib/Seq/vrf_axil_sequence.svh` | 69 | sequence（generator） |
| `bench/lib/Seq/vrf_axil_sequencer.svh` | 64 | sequencer（仲裁 + 一键导入 + 失败重注） |
| `bench/lib/Drv/vrf_axil_driver.svh` | 282 | 驱动器（双流并发、可空行为模型） |
| `bench/lib/Mon/vrf_axil_monitor.svh` | 237 | 监视器（预测 + 日志 + 宽监视） |
| `bench/lib/Slv/vrf_axil_slave.sv` | 220 | 从机参考模型 |
| `bench/lib/Cov/vrf_axil_cov.svh` | 138 | 功能覆盖率收集器 |
| `bench/lib/Env/vrf_axil_scoreboard.svh` | 241 | 计分板（比对 + 报告 + 失败复现触发） |
| `bench/lib/Env/vrf_axil_env.svh` | 276 | 环境类（一键启用 / 细粒度控制） |
| `bench/lib/Chk/vrf_axil_bringup.svh` | 313 | 上电信号连通性自检 |
| `bench/lib/Chk/vrf_axil_chk.sv` | 269 | 协议检查器 + bind 挂接 |
| `bench/tb/tb_vrf_axil_demo.sv` | 240 | 库自测用例 |
| `bench/tb/tb_dvp2ax_stream.sv` | 456 | DVP2axi_stream 接入示例 |
| `bench/scripts/*` + `Makefile` | 302 | 编译、仿真、回归、统一入口 |
| **合计** | **4044** | |

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
| 协议断言检查 / 失败 | 4847 / 0 |
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
| 协议断言检查 / 失败 | 6874 / 0 |
| 连通性自检 | 21 信号，连接错误 0、X/Z 0、恒定 4 |
| 功能覆盖率 | 70.63%（539 次采样） |
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
> 另新增 X/Z、握手稳定性、超时三类协议断言（累计 6874 次检查），为原有报告未覆盖的维度。

### 5.3 功能覆盖率明细

| 覆盖点 | 覆盖率 | 未覆盖说明 |
|---|---:|---|
| `cp_dir`（读写方向） | 100% | — |
| `cp_addr`（5 个地址区间） | 100% | — |
| `cp_strb`（7 类选通组合） | 100% | — |
| `cp_ro`（只读访问） | 100% | — |
| `cp_unmapped`（未映射访问） | 100% | — |
| `cx_dir_addr`（方向×地址区间） | 100% | — |
| `cp_resp`（响应类型） | 25% | 仅 OKAY 命中：当前 DUT 不产生 SLVERR/DECERR/EXOKAY |
| `cp_id`（主机 ID） | 6.25% | 仅 id=0 命中：DUT 的 `bid/rid` 恒为 0 |
| `cx_dir_strb`（方向×选通） | 50% | 读事务 `strb` 恒为全 1，读×非全选通组合不可达 |
| `cx_dir_resp`（方向×响应） | 25% | 同 `cp_resp` |
| **整体** | **70.63%** | 未覆盖 bin 均为「当前 DUT 不可达」，非激励不足 |

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

---

## 9. 已知限制与后续建议

### 9.1 已知限制

1. **验证范围**：本轮仅覆盖 AXI4-Lite 寄存器接口；DVP 输入与 AXI-Stream 输出不纳入验证，也未做 tie-off——报告头会明确标注这 11 个信号为「本轮不纳入验证」，需与真实缺陷区分。当前 RTL 中 `pdin/pvref/phref/axis_tready` 为未使用输入、`axis_tvalid/tdata/tlast` 恒为 0，不存在 X 态向寄存器块传播的风险。
2. **形式化**：断言已按 formal 友好的形式编写（属性独立、含 `disable iff` 门控、无时序依赖的过程语句），但本轮未搭建形式化工具环境，未做有界证明。
3. **代码覆盖率**：`-Cover` 会同时开启代码覆盖率（语句/分支/条件/表达式/FSM/翻转），本报告只统计功能覆盖率；代码覆盖率未纳入验收。
4. **`awport`/`arport`**：为非标准端口，按 DUT 现有定义保留，未纳入标准协议检查（仅做连通性与 X/Z 检查）。
5. **覆盖率未达 100%** 的原因见表 §5.3：均为当前 DUT 不可达的 bin。
6. **Makefile** 未在本机验证（本机未安装 `make`）。

### 9.2 后续建议

1. **权重覆盖**：为 `cp_id`、`cp_resp` 增加 `ignore_bins`，把「DUT 不可达」的 bin 排除，使覆盖率指标可直接用作门禁。
2. **扩展至 AXI-Stream**：按库现有分层新增 `vrf_axis_*` 组件（driver/monitor/检查器），复用接口句柄表、配置类、计分板与报告框架。
3. **形式化接入**：把 `vrf_axil_chk` 的属性集抽出为独立的 formal 属性文件，配合 `assume` 约束做有界证明。
4. **DVP 侧激励**：待 RTL 数据通路实现后，补齐 DVP 时序激励与帧级计分板，实现真正的全链路端到端验证。
5. **CI 集成**：把 `regression.ps1` 接入流水线，以 `summary.txt` 与 UCDB 作为门禁产物。
