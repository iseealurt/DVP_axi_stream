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
vlog -mfcu -sv -work work +define+<BIND_MODE> -f bench/scripts/filelist.f
```

`<BIND_MODE>` 用于选择协议检查器的 bind 目标（避免未实例化目标产生未解析引用）：

| 被测对端 | 宏定义 |
|---|---|
| 从机参考模型（库自测） | `+define+VRF_AXIL_BIND_REF` |
| DVP2axi_stream | `+define+VRF_AXIL_BIND_DVP2AXI` |

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

三者均提供时钟块 `cb`（`@(posedge aclk)`），用法：

```
@(mst_vif.cb);                       // 等待一个时钟沿
mst_vif.cb.awvalid <= 1'b1;          // 驱动请求（时钟块输出，无竞争）
if (mst_vif.cb.awready) ...          // 采样响应（时钟块输入，1step 前采样）
```

端口：`aclk`、`arstn`。

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

覆盖点：`cp_dir`、`cp_addr`（5 个地址区间）、`cp_strb`（7 类选通组合）、`cp_resp`、`cp_id`、`cp_ro`、`cp_unmapped`；交叉：`cx_dir_addr`、`cx_dir_strb`、`cx_dir_resp`。

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
| `bench/scripts/run.ps1` | 一键编译 + 仿真 + 报告定位 |
| `bench/scripts/sim.do` | ModelSim 脚本（可在交互模式 `do` 执行） |
| `bench/scripts/regression.ps1` | 批量回归：多种子、日志隔离、报告解析、通过率汇总 |
| `Makefile` | 统一入口（内部调用 PowerShell 脚本，避免双份逻辑漂移） |

### 17.2 常用命令

```powershell
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

# 批量回归
powershell -File bench/scripts/regression.ps1 -Seeds "1,2,3,4,5"
```

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
