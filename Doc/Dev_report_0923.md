# DVP2axis 数据通路与边界处理开发报告@20260923

对应计划：[Doc/Dev_plan_0923.md](Dev_plan_0923.md)（阶段一：数据通路基础 / 阶段二：边界处理与中断 / 阶段三：验证工程化）

---

## 1. 结论总览

**结论：三阶段全部达成，并已完成 `Reg_v_0_0.md` §6.4 登记的「未实现项」全部补齐（见 §8）。`tb_dvp2ax_stream`（寄存器 + 数据通路）1155 项检查 0 失败、28 个数据通路用例 183 拍逐字节比对 0 失败、三个用例各 5 种子回归全绿、功能覆盖率 100%、0 错误 0 告警。**

命令与结果（可复现）：

```powershell
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 1    # PASSED，检查 1155 项 / 失败 0
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo            # PASSED，检查 285 项 / 失败 0
powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_rst_window      # PASSED，检查 12 项 / 失败 0
powershell -File bench/scripts/regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5"
```

### 1.1 阶段一验收清单对账

| 验收项 | 结果 | 证据索引 |
|---|---|---|
| DVP 采集（同步链、像素合并、行/帧计数、主状态机）落地，`occupied` 占位源全部替换 | 达成 | `RTL/DVP2axis.sv` §7.0/§12.1~12.4、§12.12；原 §12「占位」段落与 §4 全部 `occupied` 常量已删除（grep `occupied` 仅剩 `axis_err_event` 一处，见 §6.1） |
| 打包 + 异步 FIFO + AXI-Stream 输出（tvalid/tdata/tstrb/tkeep/tlast）落地 | 达成 | `RTL/DVP2axis.sv` §12.5~12.8；新文件 `RTL/FIFO/axis_async_fifo.sv` |
| AXIS_CTRL 打包相关位纳入 pclk 帧边界更新组（修改现有 CDC 组），握手/读回机制不变 | 达成 | `CDC_FRM_ADDR` 新增 `ADDR_AXIS_CTRL`（`N_CDC_FRM` 7→8）、`cfg_pclk_axis_ctrl` 影子；§7.4/§7.5 握手与 §8 读回未改 |
| 帧级像素比对 tb 通过（正常流，2 种以上分辨率/格式） | 达成 | 正常帧用例 6 个（YUV422/RGB565/RAW8/RAW10/RGB888 × 自动/手动打包 × 端序/TSTRB），179 拍逐字节比对 0 失败（§3.1） |
| 既有回归不回退，0 错误 0 告警 | 达成 | `tb_vrf_axil_demo` 285、`tb_vrf_axil_rst_window` 12、`tb_dvp2ax_stream` 寄存器部分口径不回退（见 §4.1 偏差 7）；编译/仿真 0 错误 0 告警（§7.1） |

### 1.2 阶段二验收清单对账

| 验收项 | 结果 | 证据索引 |
|---|---|---|
| 4 种边界处理落地，行短/行长/帧短/帧长各有定向用例通过 | 达成 | RTL §12.2（`row_out_en`/`pix_in_range`/`frame_lines_now` + 边界事件）、§12.5（行末 hold + 帧末 push）；用例 `line_short_t0/t1`、`line_long_t0/t1`、`frame_short_t0/t1`、`frame_long_t0/t1` 全部通过 |
| ERR_FLAG/INT_STATUS/INT_EN 位扩展 + 文档 §3.4/§3.5/§3.6 更新 | 达成 | RTL §1（位号常量）、§9（掩码 + `INT_EN[6:9]` 门控）；`Doc/Reg_v_0_0.md` §3.4/§3.5/§3.6 已更新并新增 §6 |
| 中断置位/W1C/使能门控用例通过；边界 × TLAST_MODE 组合回归通过 | 达成 | 用例 `int_gate_off`（门控关：`ERR_FLAG` 置位、`INT_STATUS[5]` 不置位）/ W1C 清除 / `int_gate_on`（门控开）；4 类边界各 2 种 TLAST_MODE 共 10 例通过 |
| 既有回归不回退 | 达成 | 同上 §7.2 三用例 5 种子回归全绿 |

### 1.3 阶段三验收清单对账

| 验收项 | 结果 | 证据索引 |
|---|---|---|
| DVP 激励发生器与帧级 scoreboard 入库（`bench/lib/`） | 达成 | `bench/lib/Dvp/vrf_dvp_driver.svh`、`vrf_axis_frame_chk.svh`、`vrf_dvp_pkg.sv`，接口 `bench/lib/IF/vrf_dvp_if.sv` |
| 边界覆盖率组建立并达到目标（可达 bin 100%） | 达成 | `bench/lib/Dvp/vrf_dvp_cov.svh`；`vrf_dvp_cg = 100.00%`（可达 bin 33/33，采样 21 次） |
| 多种子回归全绿；`Dev_report_0923.md` 产出 | 达成 | `log_reg2/regression/*/summary.txt`：tb_dvp2ax_stream 5/5、demo 5/5、rst_window 5/5 全 PASSED（`log_reg/` 为同一套用例在最终代码定稿前的等价跑批）；本文件 |

---

## 2. 交付物清单

### 2.1 新增文件

| 文件 | 行数 | 说明 |
|---|---:|---|
| `RTL/FIFO/axis_async_fifo.sv` | 122 | 参数化行为级异步 FIFO（格雷码指针 CDC、FWFT 读、写满/空读事件、水位输出；深度非 2 的幂时报错） |
| `bench/lib/IF/vrf_dvp_if.sv` | 24 | DVP 输入接口（`pclk` + `pdin/pvref/phref` + 采样时钟块） |
| `bench/lib/Dvp/vrf_dvp_driver.svh` | 118 | DVP 激励发生器：字节串行驱动、边界注入（行长/帧长 ±）、确定性伪随机像素、静默帧 |
| `bench/lib/Dvp/vrf_axis_frame_chk.svh` | 179 | AXIS 帧级参考模型：按驱动计划重建期望 beat（长度/tstrb/tlast/填充/端序）并逐字节比对 |
| `bench/lib/Dvp/vrf_dvp_cov.svh` | 57 | 数据通路覆盖率：边界 × TLAST_MODE 交叉 + PIX_FMT/PACK_MODE/BYTE_SWAP/TSTRB_EN |
| `bench/lib/Dvp/vrf_dvp_pkg.sv` | 19 | DVP 组件独立 package（含虚接口的类不应放进 AXI 库 package，见 §5.10） |
| `Doc/Dev_report_0923.md` | 本文件 | 阶段开发报告 |

### 2.2 修改文件（与 0917 相比的增量）

| 文件 | 行数（前 → 后） | 变更要点 |
|---|---|---|
| `RTL/DVP2axis.sv` | 647 → 1143 | 新增数据通路全链路（§7.0 输入同步链、§12.1~12.12）；`occupied` 占位源替换；AXIS_CTRL 纳入帧边界更新组；位号常量与 INT_EN 门控；`CFG_TAB` 下标常量（规避 vopt 常量折叠，见 §5.1） |
| `bench/lib/Reg/vrf_axil_regmodel.svh` | 291 → 386 | 新增「读预测回调」机制（`vrf_axil_rd_cb` + `reg_rd_cb()`，动态 RO 寄存器空闲稳态期望值）；新增行/帧边界事件注入接口（含 `INT_EN[6:9]` 门控）；`evt_int_en_off` 偏移 |
| `bench/lib/Env/vrf_axil_env.svh` | 248 → 256 | 新增外部检查项计数 `ext_check_num/ext_fail_num`（数据通路帧级比对汇入统一报告与结论） |
| `bench/tb/tb_dvp2ax_stream.sv` | 451 → 841 | 挂具新增 DVP 端口与 `vrf_dvp_if`；`pclk/prst_n` 驱动与 DVP tie-off；阶段三 20 个用例（配置提交时序、帧级比对、寄存器回读、FIFO 溢出）；复位测试补 `prst_n` 脉冲 |
| `bench/scripts/filelist.f` | 26 | 登记 FIFO RTL、DVP 接口、DVP package |
| `bench/lib/Pkg/vrf_axil_pkg.sv` | 30 → 32 | 移除 DVP 组件 include（改由 `vrf_dvp_pkg` 承担） |
| `Doc/Reg_v_0_0.md` | 167 → 252 | §3.2/§3.4/§3.5/§3.6/§3.8/§3.9/§3.10/§3.13/§3.15/§3.16/§3.17 更新；新增 §6「数据通路行为与配置生效时机」（含 §6.4 未实现项） |
| `README.md` | 290 → 325 | 验证结果、目录结构、被测对象（数据通路口径）、数据通路帧级验证用法、已知限制 |

### 2.3 未改动

`bench/lib` 其余组件（IF/Pkg/Seq/Drv/Mon/Slv/Cov/Chk 的既有类）、`bench/scripts/regression.ps1` / `check_env.ps1` / `sim.do`、`Makefile`、`bench/abandoned/`、`RTL/Ref/`。
（`bench/scripts/run.ps1` 本轮新增 `-Wave` 开关，用于导出 WLF 波形，见 §8.7。）

---

## 3. 验证结果

### 3.1 用例统计（`tb_dvp2ax_stream`，种子 1）

| 项 | 数值 |
|---|---:|
| 发起事务数 | 970 |
| 监视观测数 | 969 |
| 参与比对检查 | 1155（总线 969 + 数据通路帧级 186） |
| 通过 / 失败 / 跳过 | 1155 / 0 / 1 |
| 协议断言检查 / 失败 | 55454 / 0 |
| 上电连通性自检 | 21 信号，0 连接错误、0 X/Z（恒定未跳变 4：`bid/bresp/rresp/rid`，与本 DUT 恒 0 响应一致） |
| 帧级比对 | 帧 22，拍 183，失败 0 |
| 功能覆盖率 | `vrf_axil_cg` 100.00%（采样 969）、`vrf_dvp_cg` 100.00%（采样 29） |
| 编译/仿真告警 | 0 错误 0 告警 |

数据通路用例矩阵（28 例，全部通过）：

| 类别 | 用例（配置摘要） |
|---|---|
| 正常帧 ×6 | `normal_yuv422_auto_t0`（8×4，自动打包，行 tlast）、`normal_rgb565_2ppb_t1`（12×3，2 像素/拍，帧 tlast，TSTRB）、`normal_raw8_1ppb_t0`（20×2，1 像素/拍）、`normal_rgb888_be_t1`（7×3，自动打包，整 beat 字节反转）、`normal_raw10_4ppb_bswap`（9×4，4 像素/拍，像素内字节交换）、`normal_yuv422_1px`（33×2，PACK_EN=0 单像素/拍） |
| 边界 ×10 | `line_short_t0/t1`（12 行宽送 7）、`line_long_t0/t1`（8 行宽送 14）、`frame_short_t0/t1`（设定 5 行送 3）、`frame_long_t0/t1`（设定 3 行送 6）、`short_combo_t0/t1`（行短且帧短） |
| 中断 ×2 | `int_gate_off`（`INT_EN=0`：`ERR_FLAG` 置位、`INT_STATUS[5]` 不置位、汇总位仍置位）、`int_gate_on`（`INT_EN[6]=1` 后置位）；二者之间执行 W1C 清除并校验清零 |
| 参数生效 ×2 | `cfg_timing`：帧进行中改写 `IMG_WIDTH/IMG_HEIGHT` → 当帧仍用旧值（逐字节比对通过）、下一帧用新值；`pclk_inv_falling_edge`：`DVP_CTRL.PCLK_INV=1` 下按 pclk 下降沿采集，帧级比对通过（§8.3） |
| FIFO 溢出 ×1 | `fifo_ovf`：读侧 `tready=0` 堵塞，1100 拍 > 深度 1024 → `ERR_FLAG.FIFO_OVERFLOW`、`INT_STATUS.OVERFLOW`、`FIFO_STATUS.OVERFLOW` 置位 |
| 补齐项定向 ×7 | `cfg_pending`（`STATUS[6]`）、`cfg_err`（`PIX_FMT=7` → `CFG_ERR` 且 0 拍输出）、`almost_full`（阈值判定 → `FIFO_STATUS[20]`）、`axis_timeout`（tready 堵塞 9000 拍 → `AXIS_ERR`）、`clr_cnt`/`clr_fifo`/`soft_rst`（三种清除动作的跨域一致性与冲刷后无残留拍）（§8.3） |

### 3.2 回归表

| 用例 | 种子 | 每轮检查项 | 失败 | 断言失败 | 结论 |
|---|---|---:|---:|---:|---|
| `tb_dvp2ax_stream` | 1,2,3,4,5 | 1155 | 0 | 0 | **REGRESSION PASSED**（5/5） |
| `tb_vrf_axil_demo` | 1,2,3,4,5 | 285 | 0 | 0 | **REGRESSION PASSED**（5/5） |
| `tb_vrf_axil_rst_window` | 1,2,3,4,5 | 12 | 0 | 0 | **REGRESSION PASSED**（5/5） |

### 3.3 功能覆盖率

| 覆盖组 | 采样 | 覆盖率 | 可达 bin |
|---|---:|---:|---|
| `vrf_axil_cg`（既有口径，未改） | 969 | 100.00% | 37/37 |
| `vrf_dvp_cg`（新增） | 29 | 100.00% | 33/33：`cp_boundary`(6) + `cp_tlast_mode`(2) + `cp_pix_fmt`(5) + `cp_pack_mode`(4) + `cp_bswap`(2) + `cp_tstrb_en`(2) + `cross boundary×tlast`(12) |

`vrf_dvp_cg` 无 `ignore_bins`；交叉项由「4 类边界 ×2 种 TLAST_MODE + 正常帧 ×2 种 TLAST_MODE」定向用例全覆盖。

---

## 4. 与计划的偏差说明

### 4.1 实现偏差（均为「计划留有待定项/风险项」的落地选择）

| # | 计划内容 | 实际实现 | 原因 |
|---|---|---|---|
| 1 | FIFO sideband = `tlast`(1) + 有效字节计数(`clog2(STRB)+1`) | sideband = `{frame_last, tlast, bswap, 有效字节数-1[4:0]}` 共 8 bit（有效字节数改「-1 编码」压进 5 bit，腾出 2 bit 放 `frame_last` 与 `bswap`） | ① `TLAST_MODE=0`（行末 tlast）时无法判定帧完成，需 `frame_last` 独立侧带位（需求澄清结论第 4 项已确认）；② `bswap` 随 beat 携带后，读侧 tstrb 掩码不再依赖跨域配置，避免配置在途时掩码与数据布局错配 |
| 2 | 「行末立即封包并推入 FIFO」 | 行末把已拼满/未满的 beat「暂存一拍」（`beat_line_last`），由下一行首像素或帧末推出 | 行长恰为打包宽度整数倍时，末拍会被 `!fits` 提前推出而丢失行末标记（tlast）；暂存一拍可保证行末拍一定带 tlast（实现细节，语义与计划一致） |
| 3 | `CTRL.EN` 生效时机未明确 | EN 取**帧边界已提交的影子值**（不是「提交当拍即用」） | 一致性优先：与计划「参数在 pvref 帧边界统一生效 / 竞态时本帧用旧值」一致；同时避免寄存器随机回归在无 DVP 活动时把数据通路误激活 |
| 4 | 帧边界提交脉冲取 `pvref_act` 边沿（既有实现） | 改为取**原始 pvref** 的上升/下降沿 | `PVREF_POL` 可被软件随时改写，用校正后的边沿会因极性写入凭空产生「帧边界」，在 pvref 恒定（无 DVP 活动）时把未完成的配置提前提交 |
| 5 | 「pvref/phref 极性按 `cfg_pclk_dvp_ctrl` 校正」 | `PVREF_POL` 立即生效（沿用既有实现）；`PHREF_POL` 走帧边界影子 | `PVREF_POL` 必须先在才能判断 pvref 何时有效（既有注释口径）；`PHREF_POL` 无此约束，按计划走影子 |
| 6 | 计划的边界判定「与影子配置比较」 | 实现为 `line_idx_now/pix_idx_now`（清零拍组合值）后再比较 | 计数器清零在下一拍生效，直接用寄存器值会把行首/帧首那一个像素误判为越界丢弃（调试记录 §5.4） |
| 7 | 既有 `tb_dvp2ax_stream` 口径不回退 | 寄存器部分比对项 539 → 855（+316），原「跳过 1」保留；数据通路新增 179 项帧级比对 | ① 新增数据通路用例带来新的寄存器读回（每例 8 项）；② 动态 RO 寄存器（`STATUS/FIFO_STATUS`）的空闲稳态期望值由新增读预测回调给出（原实现依赖「数据通路未激活故恒 0」的隐式口径，本阶段必须显式建模，见计划风险 4）；③ 比对项总数变化已在 README/报告同步 |
| 8 | `ERR_FLAG[1]/[2]` 的语义（文档为「行/帧错误」） | 实现为**汇总位** = `LINE_SHORT\|LINE_LONG` / `FRAME_SHORT\|FRAME_LONG` | 既保留原文档语义（行像素数过多或过少都算行错误），又与新增 4 个明细位保持一致；细节与门控差异已在 `Reg_v_0_0.md` §3.4 注明 |
| 9 | 计划未提及 FIFO 满判定来源 | `STATUS.FIFO_FULL` / `FIFO_STATUS.FULL` 按「真满（水位 = 深度）」生成；`FIFO_THRESHOLD` 另行驱动 `FIFO_STATUS.ALMOST_FULL`（高水位指示，见 §8.1） | 满/空判定保持「真满/真空」的确定语义（阈值可由软件随机写入，若参与满判定则动态 RO 读值不可预测）；阈值改为驱动独立的「高水位」位，既满足「阈值参与硬件判定」又不干扰满/空语义 |
| 10 | 计划「tstrb 仅在行末按有效字节产生」（风险 2） | `TSTRB_EN=1` 时**每拍**都按有效字节数产生掩码（整拍处掩码即全 1） | 覆盖 `PACK_EN=0/PACK_MODE=1` 等「每拍都是短拍」的配置；语义是计划口径的超集，整拍行为不变 |
| 11 | 计划未指定 tkeep 语义 | `tkeep` 恒全 1（整拍有效性由 `tstrb` 表达） | 需求澄清确认（tkeep 恒全 1、tstrb 受控） |
| 12 | 计划「FIFO 深度初定 1024 beat」 | 保持 1024（`FIFO_DEPTH` 参数，综合前可调） | 按计划；溢出用例据此设计（1100 拍 > 1024） |
| 13 | 计划风险 1「行为级异步 FIFO」 | 已实现 `RTL/FIFO/axis_async_fifo.sv`（格雷码指针 + FWFT），并在 README「已知限制」登记「综合阶段替换为原语」 | 按计划 |
| 14 | 计划风险 5「inject_event 改为激励驱动」 | 行/帧 4 类边界与帧完成事件改为**真实激励产生**；`AXIS_ERR` 亦改为真实激励产生（tready 长时间不就绪，见 §8.1），不再需要层次化 `force` | 补齐 `AXIS_ERR`（tready 超时检测）后，全部事件均可由激励产生；保留的事件注入接口仅用于用例与寄存器模型的期望同步 |

### 4.2 文档与验证工程化偏差

| # | 计划内容 | 实际实现 | 原因 |
|---|---|---|---|
| 15 | 阶段三「多种子回归全绿」+ 既有用例不回退 | 三用例各 5 种子回归全绿；未新增独立性更强的新用例文件（扩展现有 `tb_dvp2ax_stream`） | 需求澄清确认「扩展现有用例」 |
| 16 | 计划未提及验证库改动范围 | 库本体新增两类能力：① `regmodel` 读预测回调（动态 RO 期望值）；② `env` 外部检查项计数 | 数据通路状态寄存器无法用「镜像值 + 事件注入」完整建模，需要 per-map 回调；帧级检查需汇入统一报告口径。均为**按需新增**，未改动既有类接口语义（`demo`/`rst_window` 不回退） |
| 17 | 固定用例在工作库中的组织 | DVP 组件独立为 `vrf_dvp_pkg`（不再挂在 `vrf_axil_pkg` 内） | 含 `virtual vrf_dvp_if` 的类若位于 AXI 库 package 内，会让不驱动 DVP 的用例（`demo`/`rst_window`）在加载期因虚接口无法解析而失败（调试记录 §5.10） |

---

## 5. 调试定位与解决的问题

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | `tb_dvp2ax_stream` 首轮即出现 `STATUS` 低 4 位为 X、AXI 总线 X/Z 断言失败 | 仿真器 vopt 把「实参为常量的 `cfg_val` 调用」在 elaboration 期折叠成常量，而 `cfg_reg` 在时刻 0 为 X → 连续赋值恒为 X。受影响者包括既有代码的 `pvref_pol_aclk` **与 CDC 组源 `cdc_frm_src`**（原设计数据通路未使用，故从未暴露） | `CFG_TAB` 旁新增下标常量，固定偏移一律改为 `cfg_reg[CFG_*]` 直接索引；`cfg_val` 仅保留在「实参为变量」的读通路（`Reg_v_0_0` 未涉及）。**这是既有代码的潜在缺陷，建议 RTL 维护者关注** |
| 2 | 帧级比对拍数暴增（期望 4 拍实测 17 拍）、`FRAME_CNT=0`、`DBG_BEAT_CNT` 漂移 | `pack_push` 分支把新 beat 的字节计数写成 `cnt_next`（旧计数 + 本像素），导致累加值持续漂移：beat 提前推出、帧末拍无 `frame_last` → 无帧完成 | 改为 `beat_byte_cnt <= pix_bytes`（新 beat 只含本像素）；由临时 `$display` 打印逐事件确认修复后逐行 16 字节/4 拍/帧末 `flast=1` |
| 3 | `DBG_LINE_CNT` 比实际行数多 1 | 行计数在 `line_end_evt` 与 `frame_end_evt` 都累加，而帧在行间隙结束时两个事件不在同拍 → 多计一行 | 帧末仅在「行进行中结束」时补计（`frame_end_evt && state==LINE`） |
| 4 | RAW8 用例每行首像素被丢弃（39/40 拍） | 行首像素用「尚未清零」的 `pclk_pix_cnt` 判 `pix_in_range` → 行首像素被判越界 | 引入 `pix_idx_now/line_idx_now`（清零拍取 0 的组合值）后再比较 |
| 5 | `STATUS.FRAME_VALID` 在 DVP 输入恒低时读回 1（空闲态与预期不符） | 极性校正方向与 `Reg_v_0_0.md`「0=高有效」相反（既有实现 `pol?raw:~raw`） | 统一为「0=高有效 / 1=低有效」，与寄存器文档一致（并写入文档 §3.8/§6） |
| 6 | 边界标志在正常用例中误置（如正常帧报 `FRAME_SHORT`） | 「静默提交帧」（只翻 pvref、无行）会被判为「0 行帧」并产生 `FRAME_SHORT` | 用例改为两段式：先写 `EN=0` + 2 个静默帧提交，随后 `SOFT_RST` 清标志，再提交配置（此时 EN=0 已生效，静默帧不再被判为帧） |
| 7 | 配置未在当前用例生效（表现为按上一用例的几何/打包工作） | 配置提交握手**每个 pvref 边沿最多推进一次请求**，一次写多笔配置需多个帧边界才能全部提交 | 用例固定「写整批配置 → 5 个静默帧提交 → 写 EN=1 → 1 个热身帧提交 EN → 测量帧」；该规律已写入 `Reg_v_0_0.md` §6.3 提示软件使用 |
| 8 | `PIX_FMT=2/4` 的用例按 2 字节格式工作 | tb 中 `logic'(c.pix_fmt) << 4` 的 `logic'` 是**单比特**强制转换（int 2 被截断为 0），写出的 `DVP_CTRL.PIX_FMT` 恒为 0/1 | 改为 `(c.pix_fmt << 4)`（int 移位后截断） |
| 9 | 参数生效用例挂死（仿真不结束） | `fork ... join_none` 后使用 `wait fork`，而同一进程内还挂着「永不结束」的 AXIS 监视进程 → 死等 | 改为 `fork ... join`（两个分支都结束才继续），不再使用 `wait fork` |
| 10 | `tb_vrf_axil_demo` / `tb_vrf_axil_rst_window` 加载期 Fatal（虚接口无法解析） | 含 `virtual vrf_dvp_if` 的驱动器类放在了 `vrf_axil_pkg` 内，未实例化 DVP 接口的用例无法解析该虚接口类型 | DVP 组件独立为 `vrf_dvp_pkg`，由需要的用例 `import` |
| 11 | 溢出用例读回 `FIFO_STATUS` 与模型不符 | 动态 RO 读预测回调覆盖了用例显式置入的镜像值 | 回调改为「镜像非 0 时以镜像为准」，使用例可断言非空闲稳态 |
| 12 | 溢出用例未产生溢出事件 | 用例缺少「提交 EN=1」的热身帧 → 测量帧未被采集 | 补热身帧（与其它用例一致的提交时序） |
| 13 | 溢出用例的 `DVP_CTRL` 被写死为 0 | 用例中该寄存器写的是常量 0 而非 `PIX_FMT` 字段 | 改为 `(c.pix_fmt << 4)` |

---

## 6. 已知限制与遗留风险

1. **原「数据通路未实现项」已全部补齐**（`Reg_v_0_0.md` §6.4 已改写为「实现状态」；实现口径与验证见 §8）：
   `ERR_FLAG.AXIS_ERR`（tready 超时检测）、`DVP_CTRL.PCLK_INV`（下降沿采样）、
   `CTRL.SOFT_RST/CLR_CNT/CLR_FIFO` 的跨域清除（含 `DBG_PIX_CNT/DBG_LINE_CNT` 与 `FIFO_STATUS` 粘滞位）、
   `FIFO_THRESHOLD`（驱动 `FIFO_STATUS.ALMOST_FULL`）、配置握手在途状态（引出为 `STATUS.CFG_PENDING`）。
2. **DVP 输入位宽**：仅支持 `DVP_DWIDTH=8` 字节串行（其他取值 elaboration 期报错）。
3. **FIFO 原语**：`axis_async_fifo` 为行为级实现，综合阶段需按接口替换为厂商异步 FIFO 原语（深度 1024、宽度 264 bit）。
4. **跨域事件合并**：pclk→aclk 事件用「翻转位 + 2 级同步 + 边沿检测」，同型事件间隔小于 2 个 aclk 周期时可能被合并（错误标志为粘滞位，合并只影响事件计数不影响置位语义）；用例中 aclk(10ns) 快于 pclk(20ns)。
5. **数据通路用例的诊断开关**：数据通路阶段关闭「失败回注 + 宽监视」（`cfg.enable_repro=0`），避免长帧逐拍宽监视使日志爆炸；帧级失败由 `vrf_axis_frame_chk` 给出逐拍明细，寄存器阶段保持开启。（偏差登记）
6. **异步 FIFO 两侧复位需成对施加**：读侧随冲刷窗口、写侧随「冲刷请求」跨域后的 pclk 清除电平（`CLR_CNT` 不参与，见 §8.4）；若只复位一侧会产生指针失配的幻影数据（已在 README 已知限制登记）。
7. **数据通路用例的仿真规模**：单种子 `tb_dvp2ax_stream` 仿真约 466 µs（含 9000 拍 tready 超时用例与 1100 拍溢出用例），单轮墙钟时间约 5 s（含编译）。
8. **未做形式化与代码覆盖率**：沿用 0916/0917 的口径（断言按 formal-friendly 编写但未做有界证明；`-Cover` 只统计功能覆盖率）。
9. **未覆盖路径**：`FIFO_STATUS.UNDERFLOW`（读侧空读）在正常时序下不可达，未构造定向用例
   （`CFG_ERR` 原先仅有代码路径，现已补 `cfg_err` 定向用例，见 §8.3）。

---

## 7. 复验结果

### 7.1 单用例复验（最终版本，一次编译 + 仿真）

| 命令 | 结果 |
|---|---|
| `run.ps1 -Test tb_dvp2ax_stream -Seed 1` | **PASSED**：检查 1155 项（总线 969 + 帧级 186），失败 0，断言失败 0；`vrf_axil_cg` 100.00%、`vrf_dvp_cg` 100.00%；编译/仿真 0 错误 0 告警 |
| `run.ps1 -Test tb_vrf_axil_demo` | **PASSED**：检查 285 项，失败 0（与 0917 基线一致，不回退） |
| `run.ps1 -Test tb_vrf_axil_rst_window` | **PASSED**：检查 12 项，失败 0 |

### 7.2 回归复验

| 命令 | 结果 |
|---|---|
| `regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5"` | 5/5 PASSED（每轮 1155 项检查、0 失败、0 断言失败） |
| `regression.ps1 -Test tb_vrf_axil_demo -Seeds "1,2,3,4,5"` | 5/5 PASSED（每轮 285 项） |
| `regression.ps1 -Test tb_vrf_axil_rst_window -Seeds "1,2,3,4,5"` | 5/5 PASSED（每轮 12 项） |

### 7.3 一致性声明

- 本报告全部数据取自上述命令的输出与 `<log>/..._report.txt`，未手工填写。
- 报告结论与最后一次仿真一致：`SIMULATION PASSED`（三用例）+ `REGRESSION PASSED`（三轮回归）。
- 计划验收清单 12 项全部达成，无「带偏差达成」项；§4 记录的是**实现选择与计划留白处的落地口径**（计划中标注为「初定/待定/风险」的部分），以及为满足验收而必需的既有代码缺陷修复。

---

## 8. 未实现项补齐（第二轮增量）

对应工作：把 `Doc/Reg_v_0_0.md` §6.4 登记为「未实现 / 残留项」的 5 项全部实现，并补定向用例与文档。

### 8.1 RTL 补齐内容（`RTL/DVP2axis.sv`）

| # | 项 | 实现口径 | 位置 |
|---|---|---|---|
| 1 | `DVP_CTRL.PCLK_INV`（采样沿可选） | `negedge pclk` 另寄存一组 `pdin/phref/pvref`（`din_neg/href_neg/vref_neg`），按 `PCLK_INV` 选择进入 4 级同步链的源；该位取 **aclk 侧寄存器**（不随帧边界提交），经 2 级同步后在 pclk 域生效 | §7.0 |
| 2 | 清除类写动作的跨域一致（`SOFT_RST/CLR_CNT/CLR_FIFO`） | 沿用「翻转式请求/确认电平」握手，新增**冲刷标志随请求同拍登记**（`clr_req_flush`）并同步到 pclk（`clr_flush_s2`）：pclk 域主状态机、像素合并（`pix_sr/pix_tap_idx`）、行/帧计数、打包寄存器（`beat_sr/beat_byte_cnt/beat_line_last`）、`DBG_PIX_CNT/DBG_LINE_CNT` 在清除电平期间一并复位；`SOFT_RST/CLR_FIFO` 额外把 FIFO **两侧指针成对复位** | §7.7、§12.1~12.5 |
| 3 | `STATUS[6] CFG_PENDING`（配置在途） | `cfg_pending = cfg_busy \| cfg_dirty`（有请求在途，或已写入但请求尚未发起），引出到 `STATUS[6]` | §9 |
| 4 | `FIFO_THRESHOLD` 参与硬件判定 | 新增 `FIFO_STATUS[20] ALMOST_FULL = (阈值 ≠ 0) && (读侧水位 ≥ 阈值)`；阈值 0 关闭该指示。`STATUS/FIFO_STATUS.FULL` 仍按「真满」生成，满/空语义不变 | §12.9 |
| 5 | `ERR_FLAG.AXIS_ERR`（tready 超时） | `axis_stall = tvalid && !tready` 持续计数，达 8192 个 aclk 置位并锁存（一次停滞只上报一次，握手恢复即解锁）；`INT_STATUS[4]` 同拍置位 | §12.9 |
| 6 | 冲刷窗口内输出暂停 + 粘滞位清除 | `SOFT_RST/CLR_FIFO` 的冲刷窗口内 `tvalid` 拉低（避免指针复位期间送出幻影 beat）；同时清 `FIFO_STATUS` 的 OVERFLOW/UNDERFLOW 粘滞位 | §7.7、§12.9 |

> 至此 `RTL/DVP2axis.sv` 中不再有 `occupied` 占位（`axis_err_event` 已改为真实超时检测，相关注释已同步清理）。
> 仍有一处不引出到寄存器的内部信号：`cfg_ack_timeout`（配置握手等待计数饱和标志，仅内部使用），已登记为遗留限制。

### 8.2 验证库补齐（`bench/lib/Reg/vrf_axil_regmodel.svh`）

| 项 | 说明 |
|---|---|
| 读预测回调新增两个通知钩子 | `vrf_axil_rd_cb.on_group_write()`（有配置组写入）/ `on_commit()`（配置已提交），默认空实现；模型新增 `notify_commit()` 供用例在「驱动足够帧边界」后调用，使 `STATUS.CFG_PENDING` 预期值回到 0 |
| 动态 RO 期望值扩展 | `vrf_axil_dvp2axi_dyn_ro_rd_cb`：`STATUS` 空闲稳态 `0x10 \| CFG_PENDING<<6 \| FRAME_VALID`；`FIFO_STATUS` 空闲稳态 `0x0002_0000`（EMPTY），用例可用 `set_mirror()` 覆盖非空闲稳态（镜像非 0 优先） |
| CTRL 副作用回调重构 | `vrf_axil_dvp2axi_ctrl_cb` 合并「配置组写入通知」与「SOFT_RST/CLR_CNT/CLR_FIFO 副作用」两种职责：`SOFT_RST` 清 `FRAME_CNT/ERR_FLAG/DBG_*/INT_STATUS` 与 `FIFO_STATUS`；`CLR_CNT` 清 `FRAME_CNT/ERR_FLAG/DBG_*`（保留 `INT_STATUS`）；`CLR_FIFO` 清 `FIFO_STATUS`。类声明移到 `dyn_ro` 回调之后（owner 字段不允许前向引用） |
| 组写入回调 | 新增 `vrf_axil_dvp2axi_group_wr_cb`：组内无副作用寄存器（`DVP_CTRL/IMG_*/LINE_TOTAL/FRAME_TOTAL/AXIS_CTRL/FIFO_THRESHOLD`）的写入只置「配置在途」 |

### 8.3 新增定向用例（`bench/tb/tb_dvp2ax_stream.sv`，扩展现有用例，未新建 tb）

新增公共提交序列 `dvp_setup()`（关采集 → SOFT_RST → 写整批配置 → 5 静默帧提交 → 可选 EN=1 + 热身帧）与 8 个用例：

| 用例 | 覆盖点 | 结果 |
|---|---|---|
| `pclk_inv_falling_edge` | `PCLK_INV=1` 下降沿采样下整帧逐字节比对 | 期望 2 拍 / 观测 2 拍 / 通过 |
| `cfg_pending` | `STATUS` 0x10（空闲）→ 0x50（写配置后 `CFG_PENDING=1`）→ 0x10（帧边界提交后归 0） | 通过 |
| `cfg_err` | `PIX_FMT=7`（>4 非法）：`ERR_FLAG.CFG_ERR` 置位、`FRAME_CNT=0`、本帧 0 拍输出 | 通过 |
| `almost_full` | `FIFO_THRESHOLD=2`、读侧堵塞使水位=2 → `FIFO_STATUS[20] ALMOST_FULL` | 通过 |
| `axis_timeout` | `tready=0` 持续 9000 aclk（> 8192）→ `ERR_FLAG[3] AXIS_ERR` + `INT_STATUS[4]`；`FRAME_CNT` 保持 0（帧末拍未被接收） | 通过 |
| `clr_cnt` | 采集一帧后 `CLR_CNT`：`FRAME_CNT/ERR_FLAG/DBG_PIX/DBG_LINE/DBG_BEAT` 跨域清零，`INT_STATUS` 保留；清除后 FIFO 无残留拍 | 通过 |
| `clr_fifo` | 读侧堵塞造 2 拍堆积 → `CLR_FIFO`：`FIFO_STATUS` 回到 EMPTY、冲刷后观测 0 拍 | 通过 |
| `soft_rst` | 同上，`SOFT_RST` 路径（额外清 `INT_STATUS`） | 通过 |

新增用例同时把 `vrf_dvp_cg` 采样次数从 21 提升到 29（覆盖率仍 100%）。

### 8.4 过程中定位并修复的缺陷

| # | 现象 | 根因 | 解决 |
|---|---|---|---|
| 1 | `CLR_CNT` 后 `DBG_BEAT_CNT` 由 2 跳到 41、`FRAME_CNT` 从 1 不清零（且用例只驱动了 2 拍） | `fifo_wr_rst_n` 对**三种清除动作用同一个 pclk 清除电平**复位 FIFO 写侧，而读侧只在冲刷窗口（`SOFT_RST/CLR_FIFO`）复位 → `CLR_CNT` 时**单侧复位**，格雷码写指针归零而读指针不动，水位/空标志失配 → 持续送出幻影 beat（幻影 beat 携带的 sideband 又使 `FRAME_CNT` 被再次累加） | 新增 `clr_req_flush`（随请求同拍登记）同步到 pclk，写侧复位改为 `prst_n & ~(clr_pclk_level & clr_flush_s2)`：仅冲刷类动作复位写侧，与读侧成对；`CLR_CNT` 只清计数不动 FIFO |
| 2 | 首轮补齐后出现 86 项总线比对失败（`FRAME_CNT/ERR_FLAG/DBG_*` 镜像只增不清） | 模型中 `reg_special_cb(32'h00, grp_wr_cb)` **覆盖**了同一偏移的 CTRL 副作用回调（同一偏移仅一个回调槽位），`SOFT_RST/CLR_CNT` 的清零副作用整体丢失 | 把「配置组写入通知」并入 CTRL 副作用回调（`vrf_axil_dvp2axi_ctrl_cb`），CTRL 偏移只注册一次；组写入改用独立回调注册其余偏移 |
| 3 | `cfg_err` 用例 `ERR_FLAG` 期望 `0x10` 实测 `0x94` | 该用例在 `EN=1` 下驱动「静默帧」（只翻 pvref、无 phref），被判为 **0 行帧** → 置 `FRAME_SHORT` 与 `FRAME_ERR` 汇总位 | 用例改为 `EN=0` 提交非法配置（此时不采集、无边界事件），再提交 `EN=1`；非法配置下主状态机不进入采集，仅产生一次 `CFG_ERR`（持续非法不重复上报） |
| 4 | `clr_pre_fifo` 期望 `0x2` 实测 `0x100002` | 前一个 `almost_full` 用例把 `FIFO_THRESHOLD` 写成 2 且未恢复 → 清除类用例中水位=2 ≥ 阈值，`ALMOST_FULL` 被置位 | `dvp_setup()` 统一把 `FIFO_THRESHOLD` 写回 0（关闭该指示），使各用例从确定状态开始 |
| 5 | `clr_pre_dbg_beat` / `clr_cnt_frame` 比对失败 | ① `DBG_BEAT_CNT` 为动态 RO，用例未给期望镜像；② `clr_cnt` 用例漏调 `build_expect()`，沿用了上一个用例的期望 beat | 用例补 `set_mirror(ADDR_DBG_BEAT_CNT, 期望 beat 数)` 与逐字节期望重建 |

### 8.5 文档同步

| 文件 | 变更 |
|---|---|
| `Doc/Reg_v_0_0.md` | §3.1 `CTRL` 三个写动作补跨域作用说明；§3.2 新增 `STATUS[6] CFG_PENDING`；§3.4 `AXIS_ERR` 改为已实现；§3.8 `PCLK_INV` 改为「已实现 + 立即生效」；§3.15 新增 `FIFO_STATUS[20] ALMOST_FULL`；§3.16 `FIFO_THRESHOLD` 改为「参与生成 ALMOST_FULL」；§3.17 `DBG_*` 清零说明更新；§6.3 生效时机补 `PCLK_INV/FIFO_THRESHOLD` 例外与 `CFG_PENDING` 轮询；§6.4 由「未实现 / 残留项」改写为「实现状态（补齐结果）+ 仍存在的限制」 |
| `Doc/Dev_report_0923.md` | 本文件：§1/§3/§4.9/§4.14/§6/§7 数据与结论同步；新增本章 §8 |
| `README.md` | 已知限制中「未实现项」条目同步为已实现（见 §6 说明） |

### 8.6 补齐后的验证结果（可复现）

```powershell
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 1        # PASSED
powershell -File bench/scripts/regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5"
powershell -File bench/scripts/regression.ps1 -Test tb_vrf_axil_demo -Seeds "1,2,3,4,5"
powershell -File bench/scripts/regression.ps1 -Test tb_vrf_axil_rst_window -Seeds "1,2,3,4,5"
```

| 项 | 结果 |
|---|---|
| `tb_dvp2ax_stream -Seed 1` | **PASSED**：检查 1155 项（总线 969 + 帧级 186），失败 0，断言 55454/0；数据通路用例 28 个、帧级比对 22 帧 / 183 拍 / 0 失败；`vrf_axil_cg` 100.00%、`vrf_dvp_cg` 100.00% |
| 编译 | 0 错误 0 告警（`vlog -sv` 单编译单元） |
| 三用例 ×5 种子回归 | `tb_dvp2ax_stream` 5/5、`tb_vrf_axil_demo` 5/5、`tb_vrf_axil_rst_window` 5/5，全部 `REGRESSION PASSED`（既有用例无回退） |
| 文件规模 | `RTL/DVP2axis.sv` 1143 → 1287；`vrf_axil_regmodel.svh` 386 → 456；`tb_dvp2ax_stream.sv` 841 → 1078；`Doc/Reg_v_0_0.md` 252 → 264（非空行口径，与 §2.2 一致） |

### 8.7 波形/日志导出（验收留档）

`bench/scripts/run.ps1` 新增 `-Wave` 开关：以 `-voptargs="+acc"` 重新优化（保留内部信号可见性），
在 `run` 之前执行 `log -r /*` 记录整设计信号，波形增量写入 `<LogDir>/<Test>.wlf` 并在仿真结束后保留。

```powershell
powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 1 -Wave -LogDir Temp/0923
```

本次验收留档目录 `Temp/0923/`（已在 `.gitignore` 覆盖范围内，不入库）：

| 文件 | 大小 | 说明 |
|---|---:|---|
| `tb_dvp2ax_stream.wlf` | 1.7 MB | 波形数据库（整设计信号，465.185 µs / 22 帧 / 28 用例），可用 `vsim -view <file>` 或 GUI 打开 |
| `tb_dvp2ax_stream.log` | 8.5 KB | `vsim -l` 仿真转录（含结论 `SIMULATION PASSED`） |
| `tb_dvp2ax_stream_log.txt` | 75.6 KB | 用例级格式化日志（每个用例的期望/观测拍数、逐拍比对明细） |
| `tb_dvp2ax_stream_report.txt` | 2.9 KB | 验证结论报告（检查项、覆盖率、失败清单） |
| `tb_dvp2ax_stream_err.txt` | 0.2 KB | 失败用例格式化明细（本次为空） |
| `tb_dvp2ax_stream.exit` | 0 | 退出码（0 = PASSED，供脚本/CI 稳定读取） |

导出结果：**PASSED**——检查 1155 项（总线 969 + 帧级 186）失败 0，断言 55454/0，
数据通路 28 个用例 / 22 帧 / 183 拍逐字节 0 失败，`vrf_axil_cg` 与 `vrf_dvp_cg` 均 100.00%，0 错误 0 告警。

