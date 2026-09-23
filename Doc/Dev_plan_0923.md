# DVP2axis 数据通路与边界处理开发计划@20260923

## 背景与现状

1. `RTL/DVP2axis.sv` 当前状态：
   - AXI4-Lite 寄存器块（slv_if_axil 从机视角）完整，5 种子回归全绿（540 事务/539 比对/6910 断言，覆盖率 100%，0 错误 0 告警）；
   - 跨时钟域已就位：配置参数 aclk→pclk（格雷码 + 2 级同步 + 整组 4 相握手 + 帧边界提交 + ack 超时），状态/计数 pclk→aclk（格雷码 + 2 级同步）；
   - DVP 采集 / AXI-Stream 数据通路为占位（`axis_m` 占位输出，pclk 域状态/计数源为 `occupied` 占位常量）。
2. 参考模块 `RTL/Ref/DVP_AXI_v_2_0.v`（私有 AXI4 写内存版）的数据通路结构可作为参考：
   - DVP 输入 4 级移位同步（din/href/vref 同链）、像素多拍合并（8bit 串行 → PIXEL_DATA_WIDTH）；
   - 列计数 `col_cnt` 驱动的打包移位寄存（`burst_data_reg`）与"每 128 拍写一次 afifo / 每 16 拍写一次 dfifo"的突发拆分；
   - 数据/地址双异步 FIFO 跨 pclk→axi_clk，三段状态机（IDLE/ADDR_SEND/DATA_SEND/END）驱动 AXI 写通道。
3. 参考模块与本设计的差异（不继承项）：
   - 参考模块要求行有效像素数整除打包位宽（注释明确不支持 960×540），本设计必须消除该限制；
   - 参考模块输出为私有 AXI4 突发写内存，本设计输出保持 AXI-Stream；
   - 参考模块的分辨率/帧使能为编译期参数 + `FRAME_EN_VALUE` 延迟，本设计一律走 AXI-Lite 寄存器（pclk 域经现有 CDC 影子配置生效）。

## 需求澄清结论（2026-09-23 确认）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 输出接口方向 | **保持 AXI-Stream 输出**（mst_if_axis），仅参考 DVP_AXI 的采集/合并/打包/双FIFO 结构 |
| 2 | 边界问题的中断/标志位 | **新增 4 个独立 W1C 标志位**：ERR_FLAG/INT_STATUS 的 [5]=LINE_SHORT、[6]=LINE_LONG、[7]=FRAME_SHORT、[8]=FRAME_LONG，INT_EN 增加 [6:9] 对应使能位 |
| 3 | 输入不足（行短/帧短） | **不填充**：按实际像素数/行数提前结束——行短则 phref 有效结束时按实际像素数产生本行末拍并拉 tlast（受 AXIS_CTRL.TLAST_MODE 控制），帧短则 pvref 有效结束时按实际行数结束帧 |
| 4 | 输入超出（行长/帧长） | **丢弃多余部分**：超过 IMG_WIDTH 的像素不打包不进 FIFO，行照常结束；超过 IMG_HEIGHT 的行不输出；输出尺寸恒等于设定值 |

## 范围与边界

1. 本期覆盖：DVP 采集→像素合并→打包→异步 FIFO→AXI-Stream 输出 的完整数据通路，及上述 4 种边界处理与中断扩展。
2. 不在本期：私有 AXI4 写内存接口（参考模块仅供结构参考）、FIFO 原语替换（见风险 1）、SOFT_RST/CLR_FIFO 跨域脉冲通路（已登记 `occupied`）、INT 输出引脚（中断只体现在 INT_STATUS，是否引出顶层另行决定）。
3. 既有不动项：`bench/lib/` 通用库本体结构、filelist 顺序约定（接口文件在 DUT 之前）、`tb_dvp2ax_stream` 既有回归口径不回退。
4. 约定沿用：命名前缀、分节注释、`occupied` 占位标记、`always_ff/always_comb`、声明先于使用。

## 数据通路设计约定（阶段一）

### 像素链路（pclk 域）

1. **输入同步**：pdin/pvref/phref 经移位链同步后使用；pvref/phref 的有效极性按 `cfg_pclk_dvp_ctrl` 的 PVREF_POL/PHREF_POL 校正（复用第 7 节已实现的 pvref_act；phref 同理新增 phref_act）。
2. **像素合并**：按 `cfg_pclk_dvp_ctrl.PIX_FMT` 与参数 PIX_WIDTH 将 DVP 串行拍合并为像素（参考模块为 2 拍/16bit，本设计按格式推广到 N 拍），BYTE_SWAP 在合并处生效。
3. **行/帧计数**：行内有效像素计数（替换 `pclk_pix_cnt` 占位）、帧内有效行计数（替换 `pclk_line_cnt` 占位）、采集主状态机编码（替换 `pclk_fsm_state` 占位），读回走既有 CDC 通路。
4. **打包**：在 pclk 域把像素按 AXI_STREAM_DWIDTH 拼成 beat（行末不足一拍时记录有效字节数，作为 sideband 随数据进 FIFO）；**AXIS_CTRL 中作用于打包/tlast 的位（PACK_EN/PACK_MODE/TLAST_MODE/BYTE_SWAP）须纳入 pclk 帧边界更新组（修改现有 CDC 组 `CDC_FRM_ADDR`）**；TSTRB_EN 只在 aclk 侧由 sideband 字节计数生成 tstrb 时使用，不跨域。
5. **tlast 语义**：AXIS_CTRL.TLAST_MODE=0 时行末 beat 拉高，=1 时帧末 beat 拉高；tlast 以 sideband 位随 beat 过 FIFO；行短/帧短时按"实际行/帧的最后一个有效 beat"拉高。

### 跨域与输出（pclk → aclk）

1. 异步 FIFO：pclk 写 / aclk 读，宽度 = AXI_STREAM_DWIDTH + sideband（tlast 1 bit + 有效字节计数 clog2(STRB_WIDTH)+1 bit），深度初定 1024 beat（综合前定）；FIFO 满且 DVP 仍在输入时报 `fifo_overflow_event`（ERR_FLAG[0] 已有）——DVP 源不可反压，FIFO 溢出的语义是丢数据而不是反压。
2. AXIS 输出（aclk 域）：FIFO 非空即 tvalid，`axis_m.tready` 反压只作用于读侧；`DBG_BEAT_CNT` 在此更新。
3. `frame_done_event` 在帧末 beat 被接收后产生，驱动 FRAME_CNT/INT_STATUS[0]。

### 寄存器与 CDC 复用

- 阶段一落地时把第 4.2 节的 `occupied` 占位源替换为真实信号；CDC 机制（影子配置、握手、读回）不动。
- INT_EN[6:9] / ERR_FLAG[5:8] / INT_STATUS[5:8] 的位定义在阶段二扩展（机制复用 err_event_mask/int_event_mask，位号常量集中在第 1 节）。

## 边界处理设计约定（阶段二）

1. **判定基准**：行长 = phref 有效期间的有效像素数；帧长 = pvref 有效期间的有效行数；均以 phref_act/pvref_act 有效沿结束点计数，与影子配置 `cfg_pclk_img_width` / `cfg_pclk_img_height` 比较。
2. **LINE_SHORT**（行像素 < IMG_WIDTH）：phref 有效结束时，若本行计数不足，本行末拍立即按实际像素数封包并拉 tlast（TLAST_MODE=0 时）；不产生错误数据；置 LINE_SHORT。
3. **LINE_LONG**（行像素 > IMG_WIDTH）：第 IMG_WIDTH 个像素之后的数据直接丢弃（不打包、不进 FIFO），phref 有效结束时行照常结束；置 LINE_LONG。
4. **FRAME_SHORT**（行数 < IMG_HEIGHT）：pvref 有效结束时按实际行数结束帧（TLAST_MODE=1 时帧末 beat 已在最后一行产生）；置 FRAME_SHORT。
5. **FRAME_LONG**（行数 > IMG_HEIGHT）：第 IMG_HEIGHT 行之后的行不输出（不进 FIFO）；置 FRAME_LONG。
6. **与参数生效时机的关系**：参数在 pvref 帧边界统一生效（现有握手机制），边界判定使用 pclk 域影子值；配置写入与帧边界竞态时按"本帧用旧值"处理，文档须写明。
7. **中断**：4 个事件各自 W1C 粘滞置位 ERR_FLAG/INT_STATUS 对应位；INT_EN[6:9] 为使能门控（与现有一个 INT_EN 对应一个 INT_STATUS 位的风格一致）。

## 验证方案（阶段三）

1. **DVP 激励发生器**（`bench/lib/Dvp/` 新增）：pclk 时钟产生、pvref/phref/pdin 帧格式驱动；可配分辨率、行/帧数（含等于/多于/少于设定三类）、像素格式；支持"行内插入"和"帧内插入"两种越界注入。
2. **AXIS monitor + 帧级像素比对**：按 TLAST_MODE/TSTRB_EN 重构帧，与激励源图像做像素级端到端比对（替换现有占位式连通性自检）。
3. **定向用例**（边界矩阵）：
   - 正常帧（行=宽、行数=高）多分辨率扫频；
   - LINE_SHORT / LINE_LONG / FRAME_SHORT / FRAME_LONG 各 1 例 + 组合（行短且帧短）；
   - 中断：置位 → INT_STATUS 读出 → W1C 清除 → 使能门控；
   - 参数帧边界生效（写配置后当帧不变、下一帧生效）+ 握手 ack 观测。
4. **回归**：新增种子集；既有 `tb_dvp2ax_stream` / `tb_vrf_axil_demo` 不回退（详见风险 4）。
5. **覆盖率**：新增 covergroup 覆盖 边界类型 × TLAST_MODE × PIX_FMT 组合；既有 `vrf_axil_cg` 口径不变。

## 阶段划分与验收清单

### 阶段一：数据通路基础（正常流）

- [ ] DVP 采集（同步链、像素合并、行/帧计数、主状态机）落地，`occupied` 占位源全部替换；
- [ ] 打包 + 异步 FIFO + AXI-Stream 输出（tvalid/tdata/tstrb/tkeep/tlast）落地；
- [ ] AXIS_CTRL 打包相关位纳入 pclk 帧边界更新组（修改现有 CDC 组），握手/读回机制不变；
- [ ] 帧级像素比对 tb 通过（正常流，2 种以上分辨率/格式）；
- [ ] 既有回归不回退，0 错误 0 告警。

### 阶段二：边界处理与中断

- [ ] 4 种边界处理落地，行短/行长/帧短/帧长各有定向用例通过；
- [ ] ERR_FLAG/INT_STATUS/INT_EN 位扩展 + 文档 §3.4/§3.5/§3.6 更新；
- [ ] 中断置位/W1C/使能门控用例通过；边界 × TLAST_MODE 组合回归通过；
- [ ] 既有回归不回退。

### 阶段三：验证工程化

- [ ] DVP 激励发生器与帧级 scoreboard 入库（`bench/lib/`）；
- [ ] 边界覆盖率组建立并达到目标（可达 bin 100%）；
- [ ] 多种子回归全绿；`Dev_report_0923.md` 产出。

## 风险与依赖

1. **FIFO 原语**：参考模块使用 Pango 原语（fifo_256b6d/fifo_24b6d），仿真环境不可用——需先实现一个参数化行为级异步 FIFO（`RTL/` 下），综合阶段再替换为原语；写侧 pclk/读侧 aclk 的格雷码指针 CDC 用既有 gray 函数复用。
2. **多格式合并的字节对齐**：PIX_FMT 多拍合并在行末可能产生不足一像素的余数（参考模块因此只支持整除）——打包层必须按像素计数而非按拍数截断，且 tstrb 仅在行末按有效字节产生；此为本期最容易出错的点，需专项定向用例。
3. **参数生效时机**：配置经握手在帧边界生效，"写配置后当帧即变"不成立；文档与寄存器说明须显式注明，避免软件误用。
4. **既有回归的隐式口径**：现有 tb 不驱动 pclk，数据通路激活后必须保证"不驱动 pclk 时 STATUS/DBG 读回 0"（复位后所有计数/状态源为 0）才不回退；若做不到，需调整 regmodel 对 dynamic RO 寄存器的预测口径并在报告中说明。
5. **事件注入方式**：tb 现有 inject_event 依赖内部信号名（0917 计划 C6），数据通路落地后内部事件将改为真实产生，注入用例需同步改造为"激励驱动产生事件"。

## 文档与同步

1. 阶段一：更新 `Doc/Reg_v_0_0.md`（占位字段 → 真实行为定义）、README。
2. 阶段二：更新 `Doc/Reg_v_0_0.md` §3.4/§3.5/§3.6（新 4 位）、`Doc/API_VRF_AXI4L.md`（如 tb API 变化）。
3. 每阶段结束产出 `Doc/Dev_report_0923.md`，结构与 `Dev_report_0916.md` 对齐：结论总览 / 交付物清单 / 验证结果 / 偏差说明 / 调试定位 / 已知限制 / 复验结果。
