# VRF_AXI4L 验证库 API 接口文档@20260915

本文件为 AXI4-Lite 自建验证库（VRF_AXI4L）的接口说明，供后续项目直接查阅复用。

---

## 1. 概述

| 项 | 内容 |
|---|---|
| 库名 | VRF_AXI4L |
| 顶层包 | `vrf_axil_pkg` |
| 接口层文件 | `bench/lib/IF/vrf_axil_if.sv`（三视角接口 + 通配符挂钩宏） |
| 默认位宽 | `AWIDTH=32`、`DWIDTH=32`、`IDWIDTH=4`（接口层参数化，类层由 typedef 特化） |
| 依赖 | 无第三方库，纯 SystemVerilog；不依赖 UVM |
| 工具 | ModelSim SE-64 2020.4 |
| 编译要求 | **必须 `-mfcu`**（接口位于 `$unit` 作用域，需与 package 处于同一编译单元） |

### 1.1 编译

```
vlog -mfcu -cuname <test>_cu -sv -work <lib> +define+<BIND_MODE> -f bench/scripts/filelist.f
```

| 项 | 说明 |
|---|---|
| `-mfcu` | **必须**：接口位于 `$unit` 作用域，需与 package 处于同一编译单元 |
| `-cuname` | **建议**：为多文件编译单元命名，保证编译单元作用域的 `bind` 一定参与 elaboration |
| `-work <lib>` | 每个用例独立工作库：`work_demo`（库自测）、`work_dvp2axi`（接入示例），避免不同 `-define` 编译出的同名单元互相覆盖 |

`<BIND_MODE>` 用于选择协议检查器的 bind 目标（避免未实例化目标产生未解析引用）：

| 被测对端 | 宏定义 | 工作库 |
|---|---|---|
| 从机参考模型（库自测） | `+define+VRF_AXIL_BIND_REF` | `work_demo` |
| DVP2axi_stream | `+define+VRF_AXIL_BIND_DVP2AXI` | `work_dvp2axi` |

### 1.2 使用方式

```
import vrf_axil_pkg::*;
```

---

## 2. 接口层

### 2.1 三视角接口

| 接口 | 用途 | 信号方向 |
|---|---|---|
| `vrf_axil_mst_if #(AW, DW, ID)` | 主机视角：驱动器驱动请求、采样响应 | 请求为 output，响应为 input |
| `vrf_axil_slv_if #(AW, DW, ID)` | 从机视角：从机参考模型驱动响应、采样请求 | 响应为 output，请求为 input |
| `vrf_axil_mnt_if #(AW, DW, ID)` | 监视视角：纯观测 | 全部 input |

三者均提供时钟块 `cb`（`@(posedge aclk)`），**cb 只声明 input**，仅用于采样与提供时钟沿事件。

驱动与采样约定（**必须遵守**，否则会在握手当拍取到错误相位）：

| 信号来源 | 读法 | 示例 |
|---|---|---|
| 自己驱动的信号 | 直接读接口变量（本拍前沿值） | `if (mst_vif.awvalid && mst_vif.cb.awready)` |
| 被测/对端驱动的信号 | **必须**用时钟块采样（`#1step` 取前沿值） | `mst_vif.cb.awready` |
| 驱动 | 直接赋值，在 `@(cb)` 唤醒之后执行 | `mst_vif.awvalid <= 1'b1;` |

原因：对端信号经 `assign` 连到接口变量上，**组合型 ready/valid 会在握手当拍被对端更新为后沿值**，
直读接口变量会取到后沿值而漏判握手；时钟块以 `#1step` 采样取到的才是前沿值。

驱动信号归属（接口内不写初值，无多进程驱动）：

| 侧别 | 信号 | 独占者 |
|---|---|---|
| 主机侧 | `awvalid/awaddr/awport/wvalid/wdata/wstrb/bready/arvalid/araddr/arport/rready` | `vrf_axil_bringup`（自检阶段）→ `vrf_axil_driver`（自检之后） |
| 从机侧 | `awready/wready/bvalid/bid/bresp/arready/rvalid/rdata/rresp/rid` | `vrf_axil_slv_ref` |

### 2.2 通配符自动连接挂钩宏

```
`VRF_AXIL_HOOK_DECL(AW, DW, ID)
```

在**挂具模块**中展开，完成三件事：

1. 声明与 DUT 端口同名的 AXI4-Lite 信号（`awvalid/awaddr/awport/awready/wvalid/wdata/wstrb/wready/bvalid/bready/bid/bresp/arvalid/araddr/arport/arready/rvalid/rready/rdata/rresp/rid`）；
2. 实例化 `vrf_axil_mst_if mst_vif` 与 `vrf_axil_mnt_if mnt_vif` 并按名双向挂钩；
3. 在 0 时刻把接口句柄发布到 `vrf_axil_conn_h`，供环境统一取用。

前置条件：挂具模块内存在 `aclk` 与 `aresetn`。

挂具模板：

```systemverilog
module my_harness (input logic aclk, input logic aresetn);
  import vrf_axil_pkg::*;
  `VRF_AXIL_HOOK_DECL(32, 32, 4)
  MY_DUT u_dut (.*);              // DUT 全部端口按名自动连接
endmodule
```

> 说明：SystemVerilog 的 `bind` 只能观测目标模块内部信号、无法驱动其输入端口，
> 故本库采用「挂具 + 端口按名通配符连接（`.*`）」方案实现自动连接。

### 2.3 全局接口句柄

```
vrf_axil_conn_h #(AW, DW, ID)::mst / ::mnt / ::slv / ::published
```

| 成员 | 说明 |
|---|---|
| `mst` | 主机视角接口句柄 |
| `mnt` | 监视视角接口句柄 |
| `slv` | 从机视角接口句柄（预留） |
| `published` | 挂钩宏是否已完成发布 |
| `clear()` | 清空全部句柄 |

---

## 3. 事务类 `vrf_axil_txn`

```
vrf_axil_txn #(AW=32, DW=32, ID=4)
typedef vrf_axil_txn_t   // 默认特化别名，库内部统一使用
```

| 成员 | 类型 | 说明 |
|---|---|---|
| `txn_dir` | `rand axil_dir_e` | 读写方向（`AXIL_WR`/`AXIL_RD`） |
| `txn_addr` | `rand logic [AW-1:0]` | 地址（约束按数据位宽对齐） |
| `txn_data` | `rand logic [DW-1:0]` | 写数据 |
| `txn_strb` | `rand logic [STRB-1:0]` | 字节选通（写事务非 0） |
| `txn_mst_id` | `randc logic [ID-1:0]` | 主机 ID |
| `addr_min/addr_max` | `logic [AW-1:0]` | 随机地址区间（非随机，由 sequence/config 注入） |
| `strb_mode` | `int unsigned` | 0=随机、1=全选通、2=单字节 |
| `aw_delay/w_delay` | `int` | AW/W 通道到达延迟（-1 表示沿用 config） |
| `force_bready_delay/force_rready_delay` | `int` | B/R 反压延迟覆盖（-1 表示沿用 config） |
| `txn_id` | `int` | 全局唯一事务 ID |
| `txn_name` | `string` | 用例名 |
| `is_directed/is_repro` | `bit` | 定向标记 / 复现重注标记 |
| `check_enable` | `bit` | 0 表示本笔不参与比对 |
| `expect_interrupt` | `bit` | 1 表示预期被复位打断，不计失败 |
| `obs_addr/obs_wdata/obs_strb/obs_rdata/obs_id/obs_resp` | — | 总线观测值（driver/monitor 回填） |
| `obs_interrupted` | `bit` | 传输被复位打断 |
| `exp_rdata/exp_resp` | — | 期望读数据与响应（monitor 依寄存器模型在握手当拍预测） |
| `txn_result` | `vrf_result_e` | 结论（PASS/FAIL/TIMEOUT） |
| `txn_reason` | `string` | 失败原因 |

主要方法：

| 方法 | 说明 |
|---|---|
| `new(string name)` | 构造，分配全局事务 ID |
| `copy(this_type rhs)` / `clone()` | 浅拷贝 / 深拷贝（邮箱传递必须用 `clone()`） |
| `convert2string()` / `convert2string_obs()` | 激励 / 观测的可读字符串 |
| `display(prefix)` | 打印一行 |

约束：`c_dir_dist`（读写均衡）、`c_addr_align`（地址对齐）、`c_addr_range`（地址区间）、`c_strb_legal`（写 strb 非 0、读 strb 全 1）。

---

## 4. 配置类 `vrf_axil_cfg`

| 成员 | 默认 | 说明 |
|---|---|---|
| `test_name` | — | 测试名，决定日志与报告文件名 |
| `seed` | 0 | 随机种子（失败复现依据） |
| `log_dir` | "." | 日志与报告目录 |
| `verbose` | 1 | 是否逐笔记录运行日志 |
| `n_rand_txn` | 200 | `env.run()` 一键流程产生的随机事务数 |
| `strb_mode` | 0 | 随机 strb 模式 |
| `enable_directed` / `directed_case` | 1 / "ALL" | 是否挂载定向队列 / 用例名（ALL=全部） |
| `addr_min` / `addr_max` | 0x00 / 0x80 | 随机地址区间 |
| `bringup_probe_addr` | 0x80 | 连通性自检探针寄存器地址 |
| `aw_delay_min/max`、`w_delay_min/max` | 0..3 | 请求通道到达延迟范围 |
| `bready_delay_min/max`、`rready_delay_min/max` | 0..3 | 响应通道反压延迟范围 |
| `idle_cycles_min/max` | 0..2 | 事务间空闲周期 |
| `enable_xz_check` 等 4 个检查开关 | 1 | 协议检查分类开关 |
| `timeout_cycles` | 200 | 握手超时门限 |
| `enable_bringup_check` | 1 | 是否执行上电连通性自检 |
| `enable_coverage` | 1 | 是否启用功能覆盖率 |
| `enable_repro` / `repro_max_attempts` / `seed_file` | 0 / 1 / — | 失败自动化复现开关、最大重注次数、种子落盘文件 |
| `max_txn` / `max_sim_time` | 20000 / 1ms | 仿真上限兜底 |
| `reg_map` | "DVP2AXI" | 寄存器映射选择：`DVP2AXI` / `REF_SLAVE` |

---

## 5. 寄存器模型 `vrf_axil_regmodel`

轻量 RAL-like 模型：维护镜像值与访问属性，为计分板提供预期值预测。

| 方法 | 说明 |
|---|---|
| `add_reg(name, offset, access, reset_val, selfclear_mask, special, dynamic)` | 添加寄存器描述（访问属性：`ACC_RW`/`ACC_RO`/`ACC_W1C`） |
| `build_dvp2axi_stream_map()` | 按 `Doc/Reg_v_0_0.md` 建立 DVP2axi_stream 寄存器映射（23 个寄存器） |
| `build_ref_slave_map()` | 建立从机参考模型映射（7 个寄存器） |
| `find(offset)` / `is_mapped(offset)` / `is_ro(offset)` | 查询 |
| `reset()` | 全部镜像恢复复位默认值 |
| `set_mirror(offset,val)` / `get_mirror(offset)` | 直接读写镜像（供定向用例同步） |
| `predict_write(offset,data,strb)` | 写预测：wstrb 字节使能、W1C、自清零、CTRL 的 SOFT_RST/CLR_CNT 副作用；未映射地址与只读寄存器写被忽略 |
| `predict_read(offset)` | 读预测：返回镜像值；未映射地址返回 0 |
| `predict_resp(dir,offset)` | 响应预测（当前 DUT 未映射地址同样返回 OKAY） |
| `event_frame_done()` / `event_fifo_overflow()` / `event_line_err()` / `event_frame_err()` / `event_axis_err()` / `event_cfg_err()` | 内部事件注入接口：定向用例层次化 force 事件后调用，保持模型与 DUT 同步 |

可重设的寄存器偏移：`off_ctrl`、`off_frame_cnt`、`off_err_flag`、`off_int_status`、`off_dbg_pix/line/beat`、`ctrl_side_effect`。

---

## 6. 定向用例库 `vrf_axil_direct_lib`

| 方法 | 说明 |
|---|---|
| `reg_case(case_name, txn)` | 把一笔事务注册到指定用例名（自动置 `is_directed`） |
| `load(case_name, ref q[$])` | 按名挂载到队列；`"ALL"` 挂载全部用例 |
| `has(case_name)` / `total()` / `clear()` | 查询与清空 |

---

## 7. sequence 与 sequencer

### 7.1 `vrf_axil_sequence`

| 成员 / 方法 | 说明 |
|---|---|
| `new(cfg, seq_mbx)` | 绑定配置与目标邮箱 |
| `add_directed(txn)` | 直接追加一笔定向事务 |
| `load_directed_by_name(case_name)` | 按名从定向用例库挂载 |
| `body()` | 产生测试向量：先发定向队列、再发 `cfg.n_rand_txn` 笔随机事务；每笔 `pending++`；结束时置 `seq_done` |

### 7.2 `vrf_axil_sequencer`

| 成员 / 方法 | 说明 |
|---|---|
| `from_seq` / `from_env` / `repro_mbx` / `to_drv` | 四条邮箱 |
| `import_directed_queue(q[$])` | 一键导入定向测试队列 |
| `inject_repro(txn)` | 失败用例单笔重注 |
| `run()` | 仲裁：复现事务 > 环境定向队列 > sequence 队列，送往 driver |

---

## 8. driver（驱动器）

```
vrf_axil_driver #(AW, DW, ID)
new(cfg, mst_vif, slv_vif, req_mbx, done_mbx)
```

| 方法 | 说明 |
|---|---|
| `run()` | 派生「分发 + 写流 + 读流」三个进程：读写各自串行、彼此并发 |
| `role` | 驱动器角色（`VRF_ROLE_MST` 已实现；`VRF_ROLE_SLV` 与 `slv_vif` 预留复用） |

行为模型（可由 `cfg` 或事务覆盖，全部置零即退化为无延迟直连驱动）：事务间空闲周期、AW/W 到达延迟（可制造分离握手）、B/R 反压延迟。

超时与复位：任一等待阶段超时或检测到复位，均写入 `txn_result`/`txn_reason`/`obs_interrupted` 并随事务回传计分板。

> 注意：驱动器**先向计分板登记已发起事务、再上总线**，保证监视器在握手当拍即可完成配对，避免同方向事务配对错位。

---

## 9. monitor（监视器）

```
vrf_axil_monitor #(AW, DW, ID)
new(cfg, mnt_vif, model, obs_mbx)
```

| 方法 | 说明 |
|---|---|
| `run()` | 派生「采样主循环 + 写响应等待 + 读响应等待 + 宽监视」四个进程 |
| `open_log()` / `close_log()` | 打开/关闭运行日志文件 |
| `set_wide_mode(bit)` | 失败复现时开启宽监视：逐拍记录全部总线信号到 `*_wide_trace.txt` |

关键语义：

- 采样主循环逐拍读取总线，**同一拍内先做读预测、后做写提交**，与 RTL 边沿语义一致；
- 读预测在 AR 握手当拍完成，写提交在读预测之后，保证并发同址读写时预期值正确；
- 观测事务只在 `vrf_axil_ctrl::mon_enable` 为 1 时产生（上电自检期间不采样）。

---

## 10. 从机参考模型 `vrf_axil_slv_ref`

```
vrf_axil_slv_ref #(AW=32, DW=32, ID=4, RDY_DLY_MIN=0, RDY_DLY_MAX=2)
```

- 标准 AXI4-Lite 从端端口名，可被协议检查器 `bind (.*)` 挂接；
- 内部以 `vrf_axil_slv_if` 从机视角接口承载协议行为（握手、反压、响应）；
- 寄存器提交放在单一 `always` 进程内，**同拍先采样读、后提交写**，保证并发同址读写语义确定；
- 每个从侧信号只有一个写者：`wr_task` / `rd_task` 各管一半，驱动用直接赋值，不使用时钟块输出；
- 握手 ready 脉冲与响应等待都监听 `aresetn` 的下降沿：复位一旦拉低，当拍即撤销 ready/valid，
  不会把有效握手残留到复位期间（自检 `p_reset_no_resp` 在复位期间采样沿前值，残留响应会被判为协议违例）；
- 请求判定使用 `=== 1'b1` 全等比较：采样到的 `awvalid`/`wvalid`/`arvalid` 为 X 时不会被当作有效请求
  （4 态 `&&`/`!` 会得到 X，被 `while` 当成「假」从而误接受不存在的请求）；
- 寄存器映射见 `vrf_axil_regmodel::build_ref_slave_map()`；
- 未映射/保留地址：读返回 0，写被忽略。

---

## 11. 覆盖率收集器 `vrf_axil_cov`

| 方法 | 说明 |
|---|---|
| `new(cfg)` | `cfg.enable_coverage` 为 1 时构造 covergroup 实例 |
| `sample(txn, is_ro, is_unmapped)` | 采样一笔已完成比对的事务 |
| `get_coverage()` | 返回 covergroup 覆盖率 |
| `report_string()` | 返回报告文本（覆盖率 + 采样次数） |
| `report_note()` | 返回覆盖率口径说明（逐条列出被 ignore_bins 排除的 bin 及原因） |

覆盖点：`cp_dir`、`cp_addr`（5 个地址区间）、`cp_strb`（写方向 6 类选通组合）、`cp_resp`、`cp_id`、`cp_ro`、`cp_unmapped`；交叉：`cx_dir_addr`、`cx_dir_strb`、`cx_dir_resp`。

### 覆盖率口径（重要）

功能覆盖率只应衡量「DUT 能够表现出的行为」，因此以下 bin 以 `ignore_bins` 排除，不计入分母：

| 排除项 | 原因 |
|---|---|
| `cp_resp` 的 `EXOKAY` | AXI4-Lite 协议不使用 EXOKAY |
| `cp_resp` 的 `SLVERR` / `DECERR` | 当前被测从端 `bresp/rresp` 固定返回 OKAY，不产生错误响应 |
| `cp_id` 的 `[1:15]` | 当前被测从端 `bid/rid` 恒为 0 |
| `cp_strb` 的 `4'b0000` | 结构非法：AXI 写事务必须至少选通一个字节，且写激励约束已禁止全零选通 |
| `cx_dir_strb` 的读方向列 | 读事务无字节选通语义（`cp_strb` 已用 `coverpoint ... iff (dir == WR)` 限定为写方向） |
| `cx_dir_resp` 的异常响应列 | 与 `cp_resp` 的排除项保持一致 |

> **接入新 DUT 时须复核**：若新 DUT 会返回 SLVERR/DECERR、或使用非 0 的 `bid/rid`，
> 必须从 `vrf_axil_cov.svh` 中移除对应的 `ignore_bins`，否则会掩盖真实覆盖漏洞。

UCDB 由脚本 `coverage save -onexit <file>.ucdb` 生成，可用 `vcover report -detail <file>.ucdb` 查看明细。

---

## 12. 计分板 `vrf_axil_scoreboard`

```
new(cfg, model, cov, from_drv, from_mon)
sb.repro_seqr = seqr;   // 失败复现通道
sb.mon_h      = mon;    // 宽监视通道
```

| 统计量 | 说明 |
|---|---|
| `n_issued` / `n_checked` / `n_pass` / `n_fail` / `n_skip` / `n_repro` | 发起数 / 参与比对 / 通过 / 失败 / 跳过 / 复现重注 |
| `fail_q` | 失败事务清单 |

比对维度：地址一致性、写数据与字节选通一致性、读数据一致性（对模型预期）、响应合法性、事务 ID。

配对方式：按方向分离队列（写/读各一条），驱动侧保证同方向单笔未完成，故可确定性配对。

失败处理：输出格式化错误报告到 `<test>_err.txt`；若 `cfg.enable_repro` 为 1，则回注失败事务到 sequencer 复现、通知 monitor 进入宽监视模式、并把随机种子写入 `cfg.seed_file`。

---

## 13. 连通性自检 `vrf_axil_bringup`

```
new(cfg, mst_vif, mnt_vif, model)
bringup.run()
bringup.report_header()   // 返回格式化报告头字符串
bringup.is_pass()         // 无连接错误且无 X/Z 即通过
bringup.n_checked         // 自检信号数（21）
```

自检三步：

1. **空闲态静态检查**：复位释放后全部总线信号无 X/Z，且主机侧与 DUT 侧取值一致；
2. **走线激励**：对允许自由翻转的信号（地址/数据/选通/端口/ready）做 0/1 走线，确认 TB 驱动可达 DUT；
3. **探针事务**：一读一写覆盖全部有效/就绪/响应信号，并校验探针寄存器回读，随后恢复原值。

报告头按信号给出「正常 / 恒定未跳变 / 未驱动或含 X/Z / 连接错误」结论，并列出本轮不纳入验证的 DVP/AXIS 信号。

---

## 14. 环境类 `vrf_axil_env`

### 14.1 成员

| 成员 | 说明 |
|---|---|
| `cfg` / `model` / `cov` | 配置、寄存器模型、覆盖率 |
| `seqr` / `seq` / `drv` / `mon` / `sb` / `bringup` | 各组件 |
| `mst_vif` / `mnt_vif` / `slv_vif` | 接口句柄 |
| `bringup_hdr` / `bringup_ok` | 连通性自检报告头与结论 |

### 14.2 API

| 方法 | 说明 |
|---|---|
| `new(cfg)` | 建立配置、寄存器模型（按 `cfg.reg_map`）、覆盖率实例，复位全局计数 |
| `connect()` | 等待挂钩宏发布接口句柄并组装全部组件与邮箱 |
| `start()` | 执行上电连通性自检 → 打开日志与错误报告 → 派生 driver/monitor/sequencer/scoreboard 进程 |
| `submit(txn)` | 提交单笔定向事务（计入完成计数） |
| `import_directed_queue(q[$])` | 一键导入定向测试队列 |
| `run_random(n)` | 批量提交随机事务 |
| `wait_idle()` | 等待完成计数归零（objection 式结束判据），并留 4 拍收尾 |
| `stop()` | 结束全部组件进程并关闭日志 |
| `report()` | 输出文本报告到 `<test>_report.txt` 并打印结论 |
| `is_pass()` | 无失败事务、无断言失败、连通性自检通过 |
| `total_checks()` | 事务比对 + 协议断言 + 连通性自检的检查项总数 |
| `run()` | 一键流程：派生 sequence → 等待完成 → 停止 → 报告 |
| `run_all()` | `connect()` + `start()` + `run()` 全自动流程 |

### 14.3 两种典型用法

**用法一：一键流程（适合库自测、快速回归）**

```systemverilog
env = new(cfg);
vrf_axil_direct_lib_t::reg_case("my_case", txn);
env.run_all();
```

**用法二：细粒度控制（适合分层定向测试）**

```systemverilog
env = new(cfg);
env.connect();
env.start();                 // 含上电连通性自检
env.submit(mk_rd("dir", 32'h80));
env.wait_idle();
env.model.set_mirror(32'h80, 32'hDEAD_BEEF);   // 需要时同步模型
env.run_random(400);
env.wait_idle();
env.stop();
env.report();
```

---

## 15. 协议检查器 `vrf_axil_chk`

独立 binder 模块，端口名与被测模块的 AXI4-Lite 端口一致、全部为输入。

检查项：

| 编号 | 属性 | 说明 |
|---|---|---|
| 1 | `p_reset_no_resp` | 复位期间不得有 B/R 响应 |
| 2 | `p_no_xz` | 总线信号不得出现 X/Z |
| 3 | `p_aw_stable` / `p_w_stable` / `p_ar_stable` / `p_b_stable` / `p_r_stable` | 握手稳定性：valid 拉高后载荷保持不变，valid 不得提前撤销 |
| 4 | `p_b_needs_req` / `p_r_needs_req` | 无请求不得有响应 |
| 5 | `p_rresp_legal` / `p_bresp_legal` | 响应只能取 OKAY/SLVERR/DECERR |
| 6 | `p_aw_timeout` / `p_w_timeout` / `p_ar_timeout` / `p_b_timeout` / `p_r_timeout` | 握手停滞超时 |

挂接方式（编译期由 `+define+` 选择目标）：

```systemverilog
`ifdef VRF_AXIL_BIND_DVP2AXI
  bind DVP2axi_stream vrf_axil_chk u_vrf_axil_chk (. *);
`endif
```

通过/失败次数累计到 `vrf_axil_ctrl::assert_chk_cnt` / `assert_fail_cnt`。

补充说明：

- 超时门限统一取自 `vrf_axil_ctrl::timeout_cycles`（由 `cfg.timeout_cycles` 注入，与 driver/bringup/monitor 同源），
  检查器本身不提供兜底参数；`0` 表示「第一个停滞周期即报错」，语义与其他组件一致。
- 请求/响应计数（`aw_cnt` / `w_cnt` / `ar_cnt`）只在复位时清零：它描述的是**总线状态**，
  若在检查挂起（`gating`）期间清零，恢复检查后到达的响应会被误判为「无请求的响应」。
  握手停滞计数则在复位或挂起时清零（挂起会引入非真实停滞，恢复后不应立刻误报超时）。

---

## 16. 全局控制类

### `vrf_axil_ctrl`

| 静态成员 | 说明 |
|---|---|
| `bringup_active` | 上电自检阶段标志（自检期间挂起断言与监视采样） |
| `mon_enable` | 监视器采样使能 |
| `checks_enable` | 协议检查总开关 |
| `timeout_cycles` | 超时门限（由 `cfg` 注入） |
| `assert_chk_cnt` / `assert_fail_cnt` | 断言检查/失败计数 |
| `reset()` | 复位全部标志与计数 |

### `vrf_axil_done_ctrl`

| 静态成员 | 说明 |
|---|---|
| `pending` | 未完成事务计数（提交 +1、比对完成 -1） |
| `seq_done` | sequence 是否已产生完全部测试向量 |
| `all_done` | 全部完成标志 |
| `reset()` | 清零 |

---

## 17. 编译、仿真与回归

### 17.1 脚本

| 文件 | 用途 |
|---|---|
| `bench/scripts/filelist.f` | 编译文件列表（顺序固定，必须配合 `-mfcu`） |
| `bench/scripts/check_env.ps1` | 前置条件检查：PowerShell 版本、ModelSim 工具（vlib/vlog/vsim，vcover 可选）、工程文件、目录可写（日志目录 + 项目根目录） |
| `bench/scripts/run.ps1` | 一键编译 + 仿真 + 报告定位；退出码同时落盘到 `<LogDir>/<Test>.exit` |
| `bench/scripts/sim.do` | ModelSim 脚本（可在交互模式 `do` 执行） |
| `bench/scripts/regression.ps1` | 批量回归：多种子、日志隔离、超时保护、报告解析、通过率汇总 |
| `Makefile` | 统一入口（内部调用 PowerShell 脚本，避免双份逻辑漂移） |
| `.gitignore` | 排除仿真生成物与日志 |

### 17.2 常用命令

```powershell
# 前置条件检查
powershell -File bench/scripts/check_env.ps1

# 库自测（从机参考模型）
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo

# DVP2axi_stream 接入示例
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream

# 指定种子复现
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 12345

# 带功能覆盖率（生成 UCDB）
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Cover

# 故障注入自测（验证失败复现与错误报告链路）
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo -Nrand 0 -Fault

# 批量回归（可选 -TimeoutSec 单轮超时，默认 900 秒）
powershell -File bench/scripts/regression.ps1 -Seeds "1,2,3,4,5" -TimeoutSec 900

# 指定日志基目录（回归输出落在 <LogDir>/regression/run_<时间戳>_<pid>/）
powershell -File bench/scripts/regression.ps1 -Seeds "1,2,3" -LogDir log_alt
```

> 注意：`-Seed` / `-Nrand` 只有**显式传参**才会下发对应 plusarg，因此 `-Seed 0`、`-Nrand 0` 均为有效取值；
> 该规则在 `regression.ps1` 中同样成立（它仅在自身收到 `-Nrand` 时才转发给每一轮），
> Makefile 侧同样按「命令行/环境是否显式给出」决定是否转发。两者均不接受负数。
>
> 注意：`-LogDir` 只拒绝会破坏 Tcl 花括号引用或子进程参数引用的字符（`{ }`、双引号、换行），
> **允许含空格的路径**（工程位于 `C:\Users\John Doe\...` 这类目录时仍可用）；
> 相对路径以项目根目录为基准，绝对路径按原样使用；目录按字面路径创建（通配字符如 `log[1]` 不会
> 被展开成别的目录）。
>
> 注意：工作库固定在项目根目录（`work_demo` / `work_dvp2axi`）。为避免并发运行同一用例时
> 互相覆盖库、互删库锁，`run.ps1` 会在**工程根目录**写一个占用标记 `.vrf_axil_owner_<lib>`
> （记录 PID，原子创建）：
> - 标记对应进程仍在运行时**直接以退出码 3 拒绝**；进程已结束的陈旧标记会被接管；
> - `-Clean` 会先确认 `work` / `work_demo` / `work_dvp2axi` 都没有被其他存活运行占用，再执行删除。
>
> 工作库是否已初始化以 vlib 生成的 `<lib>/_info` 为准，空目录不会被当成有效库。

### 17.3 仿真参数（plusargs）

| 参数 | 说明 |
|---|---|
| `+seed=<n>` | 指定随机种子（失败复现） |
| `+n_rand=<n>` | 覆盖随机事务数 |
| `+log_dir=<path>` | 日志与报告目录 |
| `+fault_inject=1` | 故障注入模式（仅 demo 用例） |

### 17.4 输出文件

| 文件 | 内容 |
|---|---|
| `<log_dir>/<test>_report.txt` | 验证报告（含连通性自检报告头、统计、覆盖率、结论） |
| `<log_dir>/<test>_log.txt` | 逐笔事务运行日志 |
| `<log_dir>/<test>_err.txt` | 失败用例格式化错误报告 |
| `<log_dir>/<test>_wide_trace.txt` | 失败复现时的逐拍宽监视波形文本 |
| `<log_dir>/<test>.ucdb` | 覆盖率数据库（`-Cover` 时生成） |
| `<log_dir>/<test>.log` | 仿真器转录日志 |
| `<log_dir>/<test>.exit` | run.ps1 的退出码（供回归脚本稳定读取） |
| `<log_dir>/regression/run_<时间戳>_<pid>/summary.txt` | 批量回归汇总（含每轮退出码、检查项、失败项、结论） |

> `<log_dir>` 可被 `-LogDir`（脚本）或 `OUT=`（Makefile）覆写，回归的基目录同样跟随该参数。
> `run.ps1` 退出码：0 成功；2 参数/环境错误；3 工作库被其他运行占用 / 工作库或日志目录创建失败；
> 4 编译失败；5 未找到 ModelSim 工具（vlib/vlog/vsim）；6 未生成报告。仿真结论以报告中的
> `SIMULATION PASSED/FAILED` 为准（回归脚本同时校验退出码与报告）。
>
> 回归为每一轮启动的子进程会沿用**当前宿主解释器**（如父进程跑在 `pwsh` 下就用 `pwsh`），
> 并统一加 `-NoProfile`，避免用户 profile 影响子进程。

---

## 18. 接入新 DUT 的步骤

1. **写挂具模块**：
   ```systemverilog
   module my_harness (input logic aclk, input logic aresetn);
     import vrf_axil_pkg::*;
     `VRF_AXIL_HOOK_DECL(32, 32, 4)
     // 本轮不验证的端口占位声明（供 `.*` 按名连接）
     wire ...;
     MY_DUT u_dut (.*);
   endmodule
   ```
2. **加 bind 目标**：在 `bench/lib/Chk/vrf_axil_chk.sv` 中按 `+define+` 增加一条 `bind MY_DUT vrf_axil_chk ...`，并在 `run.ps1` 的 `switch` 中登记编译模式。
3. **加寄存器映射**：在 `vrf_axil_regmodel` 中新增 `build_xxx_map()`，并在 `run.ps1`/用例里设置 `cfg.reg_map`。
4. **写测试用例**：复制 `bench/tb/tb_dvp2ax_stream.sv`，替换挂具与寄存器偏移常量。
5. **加入文件列表**：在 `filelist.f` 末尾追加挂具与用例文件。

> 库本体（`bench/lib`）在接入新 DUT 时无需修改。
