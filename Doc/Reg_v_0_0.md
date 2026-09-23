# DVP2AXI_Stream IP 寄存器设计方案（草案 v0.0）

## 1. 总体约定

- 寄存器通过 AXI-Lite 从接口访问，数据宽度 32-bit。
- 寄存器基地址 = `AXI_LITE_BASE_ADDR_OFFSET`，以下偏移均为相对该基地址的字节偏移。
- 所有寄存器按 4 字节对齐；未列出的偏移为 `Reserved`，读返回 0，写忽略。
- 写操作支持 `wstrb` 按字节使能；只读寄存器写忽略。
- 中断状态寄存器采用 `W1C`（写 1 清除）方式。
- 复位默认值均为异步复位后的初值，具体可在 RTL 实现时调整。

## 2. 寄存器地址映射总览

| 偏移 | 名称 | 读写 | 复位值 | 功能 |
|---|---:|---:|---:|---|
| 0x00 | CTRL | R/W | 0x0000_0000 | 全局控制 |
| 0x04 | STATUS | RO | 0x0000_0000 | 实时状态 |
| 0x08 | FRAME_CNT | RO | 0x0000_0000 | 完成帧计数 |
| 0x0C | ERR_FLAG | R/W1C | 0x0000_0000 | 错误标志 |
| 0x10 | INT_EN | R/W | 0x0000_0000 | 中断使能 |
| 0x14 | INT_STATUS | R/W1C | 0x0000_0000 | 中断状态 |
| 0x18 | VERSION | RO | 0x0001_0000 | IP 版本 |
| 0x20 | DVP_CTRL | R/W | 0x0000_0000 | DVP 输入控制 |
| 0x24 | IMG_WIDTH | R/W | 0x0000_0780 | 有效图像宽度（像素） |
| 0x28 | IMG_HEIGHT | R/W | 0x0000_0438 | 有效图像高度（行） |
| 0x2C | LINE_TOTAL | R/W | 0x0000_0800 | 每行总 pclk 周期（含消隐） |
| 0x30 | FRAME_TOTAL | R/W | 0x0000_0450 | 每帧总行数（含消隐） |
| 0x40 | AXIS_CTRL | R/W | 0x0000_0001 | AXI-Stream 输出控制 |
| 0x44 | AXIS_TID | R/W | 0x0000_0000 | TID 值（预留） |
| 0x48 | AXIS_TDEST | R/W | 0x0000_0000 | TDEST 值（预留） |
| 0x4C | AXIS_TUSER | R/W | 0x0000_0000 | TUSER 值（预留） |
| 0x60 | FIFO_STATUS | RO | 0x0000_0000 | FIFO 状态 |
| 0x64 | FIFO_THRESHOLD | R/W | 0x0000_0010 | FIFO 高水位阈值 |
| 0x70 | DBG_STATE | RO | 0x0000_0000 | 内部状态机调试 |
| 0x74 | DBG_PIX_CNT | RO | 0x0000_0000 | 当前行像素计数 |
| 0x78 | DBG_LINE_CNT | RO | 0x0000_0000 | 当前帧行计数 |
| 0x7C | DBG_BEAT_CNT | RO | 0x0000_0000 | 当前帧 AXI-Stream beat 计数 |
| 0x80 | SCRATCH | R/W | 0x0000_0000 | 软件自检寄存器 |

## 3. 寄存器位域详细说明

### 3.1 0x00 CTRL —— 全局控制

| 位 | 名称 | 访问 | 复位 | 说明 |
|---|---|---|---|---|
| [0] | EN | R/W | 0 | 0：停止采集；1：启动 DVP 采集 |
| [1] | SOFT_RST | R/W1C | 0 | 写 1 复位内部数据通路、FIFO 和计数，配置寄存器不清除。<br>跨域作用：pclk 域主状态机/像素合并/行帧计数/打包寄存器、`DBG_PIX_CNT`、`DBG_LINE_CNT` 一并复位；FIFO 两侧指针成对复位并清 `FIFO_STATUS` 溢出/下溢粘滞位；同时清 `FRAME_CNT`、`ERR_FLAG`、`DBG_BEAT_CNT`、`INT_STATUS`（见 §6.4） |
| [2] | SINGLE_SHOT | R/W | 0 | 0：连续采集；1：只采集一帧后自动停止 |
| [3] | AUTO_RESTART | R/W | 0 | 单帧模式结束后是否自动重新开始 |
| [4] | CLR_CNT | R/W1C | 0 | 写 1 清除 `FRAME_CNT`、`ERR_FLAG`、`DBG_BEAT_CNT` 及 pclk 域的 `DBG_PIX_CNT/DBG_LINE_CNT`（保留 `INT_STATUS`）；**不影响 FIFO 内容与指针** |
| [5] | CLR_FIFO | R/W1C | 0 | 写 1 清空内部 FIFO（两侧指针成对复位）并清 `FIFO_STATUS` 溢出/下溢粘滞位；期间 AXIS 输出暂停 |
| [31:6] | RESERVED | - | 0 | 保留 |

### 3.2 0x04 STATUS —— 实时状态

| 位 | 名称 | 访问 | 说明 |
|---|---|---|---|
| [0] | BUSY | RO | 1：正在采集（pclk 域主状态机处于「帧有效/行有效」） |
| [1] | FRAME_VALID | RO | 1：当前 pvref 有效（极性校正后），正在接收一帧 |
| [2] | LINE_VALID | RO | 1：当前 phref 有效（极性校正后），正在接收一行 |
| [3] | FIFO_FULL | RO | FIFO 满（按读侧水位判定：水位 = 深度；`FIFO_THRESHOLD` 只驱动 `FIFO_STATUS.ALMOST_FULL`，见 §3.16） |
| [4] | FIFO_EMPTY | RO | FIFO 空（读侧） |
| [5] | AXIS_BUSY | RO | 1：FIFO 非空，AXI-Stream 有待发数据 |
| [6] | CFG_PENDING | RO | 1：存在尚未在 `pvref` 帧边界提交的配置（有请求在途或本次写入尚未发起请求） |
| [15:8] | FSM_STATE | RO | 内部主状态机状态（pclk 域，跨域读回）：0=IDLE 1=FRAME 2=LINE 3=DONE |
| [31:16] | RESERVED | RO | 保留 |

> 说明：`[2:0]` 与 `[15:8]` 来自 pclk 域（经格雷码 + 2 级同步读回，存在数个时钟周期的观察延迟），
> `[6:3]` 来自 aclk 域（实时）。复位后空闲态为 `0x0000_0010`（FIFO 空）。
> `[6]` 语义：写任意配置组寄存器（含 `CTRL`）即置 1，该批写入全部在帧边界提交完成后回到 0；
> 软件可用它替代 §6.3 的「按帧数等待」来判断配置是否已生效。

### 3.3 0x08 FRAME_CNT —— 完成帧计数

- RO，32-bit。
- 每成功输出一帧后加 1，`CTRL.CLR_CNT` 清零。

### 3.4 0x0C ERR_FLAG —— 错误标志（粘滞，写 1 清除）

| 位 | 名称 | 说明 |
|---|---|---|
| [0] | FIFO_OVERFLOW | 输入 FIFO 溢出（FIFO 满时仍有 beat 写入被丢弃；DVP 源不可反压，溢出语义为丢数据） |
| [1] | LINE_ERR | 行错误**汇总位**：= LINE_SHORT \| LINE_LONG |
| [2] | FRAME_ERR | 帧错误**汇总位**：= FRAME_SHORT \| FRAME_LONG |
| [3] | AXIS_ERR | AXI-Stream 输出握手异常：`tvalid` 持续有效而 `tready` 连续 8192 个 aclk 未就绪（一次停滞只上报一次，握手恢复后可再次上报） |
| [4] | CFG_ERR | 配置非法：提交的 `DVP_CTRL.PIX_FMT` 超出取值上限（>4） |
| [5] | LINE_SHORT | 行像素数少于 `IMG_WIDTH`（按实际像素数提前结束本行） |
| [6] | LINE_LONG | 行像素数多于 `IMG_WIDTH`（超出部分丢弃，行照常结束） |
| [7] | FRAME_SHORT | 帧行数少于 `IMG_HEIGHT`（按实际行数提前结束本帧） |
| [8] | FRAME_LONG | 帧行数多于 `IMG_HEIGHT`（超出部分的行不输出） |
| [31:9] | RESERVED | 保留 |

> 置位时机：`[0] [4:8]` 由硬件事件置位（不受 `INT_EN` 门控）；`[1]/[2]` 为汇总位，随 `[5:8]` 一同置位。

### 3.5 0x10 INT_EN —— 中断使能

| 位 | 名称 | 说明 |
|---|---|---|
| [0] | FRAME_DONE_IE | 帧完成中断使能 |
| [1] | ERR_IE | 错误总中断使能（保留：当前未参与门控） |
| [2] | OVERFLOW_IE | FIFO 溢出中断使能（保留：当前未参与门控） |
| [3] | LINE_ERR_IE | 行错误中断使能（保留：当前未参与门控） |
| [4] | FRAME_ERR_IE | 帧错误中断使能（保留：当前未参与门控） |
| [5] | AXIS_ERR_IE | AXI 错误中断使能（保留：当前未参与门控） |
| [6] | LINE_SHORT_IE | `INT_STATUS[5]` 使能（本位上沿新增） |
| [7] | LINE_LONG_IE | `INT_STATUS[6]` 使能 |
| [8] | FRAME_SHORT_IE | `INT_STATUS[7]` 使能 |
| [9] | FRAME_LONG_IE | `INT_STATUS[8]` 使能 |
| [31:10] | RESERVED | 保留 |

> 门控规则：`INT_STATUS[5:8]` 由 `INT_EN[6:9]` 一一门控（`INT_EN` 位号 = `INT_STATUS` 位号 + 1，
> 与既有 `[1:5]` 的对应风格一致）；`INT_STATUS[1:4]` 与 `[0]` 沿用当前「不受门控」的行为。
> `ERR_FLAG` 位不受门控（错误标志始终记录）。

### 3.6 0x14 INT_STATUS —— 中断状态（W1C）

| 位 | 名称 | 说明 |
|---|---|---|
| [0] | FRAME_DONE | 帧完成（帧末 beat 被 AXI-Stream 接收），写 1 清除 |
| [1] | OVERFLOW | FIFO 溢出，写 1 清除 |
| [2] | LINE_ERR | 行错误（汇总），写 1 清除 |
| [3] | FRAME_ERR | 帧错误（汇总），写 1 清除 |
| [4] | AXIS_ERR | AXI 错误，写 1 清除 |
| [5] | LINE_SHORT | 行短（受 `INT_EN[6]` 门控），写 1 清除 |
| [6] | LINE_LONG | 行长（受 `INT_EN[7]` 门控），写 1 清除 |
| [7] | FRAME_SHORT | 帧短（受 `INT_EN[8]` 门控），写 1 清除 |
| [8] | FRAME_LONG | 帧长（受 `INT_EN[9]` 门控），写 1 清除 |
| [31:9] | RESERVED | 保留 |

> 注意：位号含义与 `ERR_FLAG` **不完全相同**（`ERR_FLAG[1]`=行错误汇总、`INT_STATUS[2]`=行错误汇总），
> 与既有寄存器定义的对应关系保持一致。

### 3.7 0x18 VERSION —— 版本

- 建议格式：`[31:16] = 主版本`，`[15:0] = 次版本`。
- 例：`0x0001_0000` 表示 v1.0。

### 3.8 0x20 DVP_CTRL —— DVP 输入控制

| 位 | 名称 | 访问 | 复位 | 说明 |
|---|---|---|---|---|
| [0] | PCLK_INV | R/W | 0 | 0：pclk 上升沿采样；1：下降沿采样（**写入后立即生效**：采样数据取自 negedge pclk 寄存的一拍，再进入输入同步链） |
| [1] | PVREF_POL | R/W | 0 | 帧有效极性：0：pvref 高有效；1：低有效（**写入后立即生效**，见 §6.3） |
| [2] | PHREF_POL | R/W | 0 | 行有效极性：0：phref 高有效；1：低有效（随帧边界提交生效，见 §6.3） |
| [6:4] | PIX_FMT | R/W | 0 | 输入像素格式，决定「每像素占几个 pclk 拍（几个字节）」：<br>0=YUV422 → 2 拍；1=RGB565 → 2 拍；2=RAW8/Bayer8 → 1 拍；<br>3=RAW10/Bayer10 → 2 拍（16bit 容器）；4=RGB888 → 3 拍；<br>取值 >4 视为配置非法：不采集并置 `ERR_FLAG.CFG_ERR` |
| [7] | BYTE_SWAP | R/W | 0 | 0：像素内字节序不变；1：每像素内高低字节交换（在**合并处**生效） |
| [31:8] | RESERVED | - | 0 | 保留 |

> 说明：`DVP_DWIDTH` 固定按字节串行为 8（其他取值在 elaboration 期报错）；
> 像素位宽由 `PIX_FMT` 决定（`PIX_WIDTH` 参数作为合并寄存器宽度的下限）。

### 3.9 0x24 IMG_WIDTH —— 有效图像宽度

- R/W，单位：像素。
- 表示每行有效像素数：行内**超过**该值的像素直接丢弃（不打包、不进 FIFO）并置 `ERR_FLAG.LINE_LONG`；
  行内**不足**该值时按实际像素数结束本行（不填充）并置 `ERR_FLAG.LINE_SHORT`。
- 输出行长恒等于该值（输入更长）或实际值（输入更短）。

### 3.10 0x28 IMG_HEIGHT —— 有效图像高度

- R/W，单位：行。
- 表示每帧有效行数：**超过**该值的行不输出并置 `ERR_FLAG.FRAME_LONG`；
  **不足**该值时按实际行数结束本帧（不填充）并置 `ERR_FLAG.FRAME_SHORT`。

### 3.11 0x2C LINE_TOTAL —— 每行总周期数

- R/W，单位：pclk。
- 表示从行同步开始到下一行同步开始的总周期数，包含行消隐。
- 可用于产生更精确的行时序统计/超时检测；如果不需要可以删除。

### 3.12 0x30 FRAME_TOTAL —— 每帧总行数

- R/W，单位：行。
- 表示从帧同步开始到下一帧同步开始的总行数，包含帧消隐。
- 用于帧超时/完整性判断。

### 3.13 0x40 AXIS_CTRL —— AXI-Stream 输出控制

| 位 | 名称 | 访问 | 复位 | 说明 |
|---|---|---|---|---|
| [0] | PACK_EN | R/W | 1 | 1：按 `AXI_STREAM_DWIDTH` 打包多像素；0：每个 beat 只放一个像素（低位对齐） |
| [1] | BYTE_SWAP | R/W | 0 | 0：小端输出（首像素在 beat 低字节）；1：大端输出 —— **整 beat 字节反转**（byte i ↔ byte STRB-1-i，有效字节落到 beat 高字节） |
| [2] | TLAST_MODE | R/W | 0 | 0：每行最后一个 beat 拉高 tlast；1：每帧最后一个 beat 拉高 tlast |
| [3] | TSTRB_EN | R/W | 0 | 0：tstrb 恒为全 1；1：按拍内有效字节位置产生 tstrb（大端输出时掩码位于高字节） |
| [5:4] | PACK_MODE | R/W | 0 | 手动打包模式：<br>0=自动计算（= 「整拍可容纳的最大像素数」，见下）；1=1 像素/拍；2=2 像素/拍；3=4 像素/拍 |
| [7:6] | RESERVED | - | 0 | 保留 |
| [31:8] | RESERVED | - | 0 | 保留 |

- 「整拍可容纳的最大像素数」按每像素字节数计算：1 字节→32 像素/拍、2 字节→16 像素/拍、3 字节→10 像素/拍。
- `PACK_MODE != 0` 时忽略 `PACK_EN`（手动模式优先）。
- `PACK_EN/PACK_MODE/BYTE_SWAP/TLAST_MODE` 作用于 pclk 域打包，故**随帧边界提交生效**（见 §6.3）；
  `TSTRB_EN` 只在 aclk 侧由 sideband 字节计数生成 tstrb 时使用，写入后立即作用于输出。
- `tkeep` 恒为全 1（整拍有效性由 `tstrb` 表达）。
- 行末不足一拍时该拍有效字节数 = 行内剩余字节数，其余字节填充 0；**像素不会跨 beat 拆分**。

### 3.14 0x44 / 0x48 / 0x4C —— TID / TDEST / TUSER

- R/W。
- 当前模块端口没有引出 `axis_tid / axis_tdest / axis_tuser`，但参数中已有对应位宽定义。
- 建议先在寄存器中保留这些字段，后续若需要扩展端口，可直接使用：
  - `AXIS_TID[AXI_ID_WIDTH-1:0]`
  - `AXIS_TDEST[AXI_STREAM_TDEST_WIDTH-1:0]`
  - `AXIS_TUSER[AXI_STREAM_USER_WIDTH-1:0]`

### 3.15 0x60 FIFO_STATUS —— FIFO 状态

| 位 | 名称 | 访问 | 说明 |
|---|---|---|---|
| [15:0] | LEVEL | RO | 当前 FIFO 中的 beat 数（读侧水位 = 同步后的写指针 − 读指针） |
| [16] | FULL | RO | FIFO 满（水位 = 深度 1024） |
| [17] | EMPTY | RO | FIFO 空 |
| [18] | OVERFLOW | RO | 溢出事件粘滞位（自最近一次复位以来发生过满时写入被丢弃；不受 W1C 清除，随 `CTRL.SOFT_RST/CLR_FIFO` 或复位清除） |
| [19] | UNDERFLOW | RO | 下溢事件粘滞位（自最近一次复位以来发生过空读；正常流程不会出现；同上随冲刷/复位清除） |
| [20] | ALMOST_FULL | RO | 高水位指示：读侧水位 ≥ `FIFO_THRESHOLD`（`FIFO_THRESHOLD=0` 时该指示关闭，恒 0） |
| [31:21] | RESERVED | RO | 保留 |

> 复位后空闲态为 `0x0002_0000`（EMPTY=1）。

### 3.16 0x64 FIFO_THRESHOLD —— FIFO 高水位阈值

- R/W，复位值 0x10。
- **仅用于生成高水位指示** `FIFO_STATUS.ALMOST_FULL`（读侧水位 ≥ 阈值时置 1）；写 0 表示关闭该指示。
- 该阈值在 **aclk 侧读回后立即生效**（不经过帧边界提交）；不参与 `STATUS.FIFO_FULL`/`FIFO_STATUS.FULL`
  的判定（两者按「真满：水位 = 深度」生成）；DVP 源不可反压，阈值也不用于反压。

### 3.17 0x70 ~ 0x7C —— 调试寄存器

| 偏移 | 名称 | 访问 | 说明 |
|---|---|---|---|
| 0x70 | DBG_STATE | RO | 内部状态机编码（0=IDLE 1=FRAME 2=LINE 3=DONE，pclk 域跨域读回） |
| 0x74 | DBG_PIX_CNT | RO | 当前（最后）行已接收像素数（含被越界丢弃的像素；每行有效沿开始时清零） |
| 0x78 | DBG_LINE_CNT | RO | 当前（最后）帧已接收行数（含被丢弃的行；每帧开始时清零） |
| 0x7C | DBG_BEAT_CNT | RO | 最近一帧已输出 AXI-Stream beat 数（帧首 beat 从 1 起计数，帧结束后保持该帧总数） |

> pclk 域计数经格雷码 + 2 级同步读回，存在数个时钟周期的观察延迟；
> `DBG_PIX_CNT/DBG_LINE_CNT` 的清零由 `CTRL.CLR_CNT/SOFT_RST` 经跨域握手在 pclk 域完成
> （清零生效时刻与 aclk 侧写动作之间有几个时钟周期的传播延迟，见 §6.4）。

### 3.18 0x80 SCRATCH —— 软件自检

- R/W，复位 0。
- 用于驱动读写自检，不参与硬件逻辑。

## 4. AXI-Lite 解码建议

- 地址偏移：`offset = awaddr/araddr - AXI_LITE_BASE_ADDR_OFFSET`。
- 地址对齐：建议忽略低 2 位，只解码 `offset[15:2]` 等。
- 写操作：`awvalid && wvalid && awready && wready` 同时有效时写入。
- 读操作：可用组合逻辑输出 `rdata`，或寄存一拍；`rvalid` 与 `arready` 按 AXI-Lite 时序处理。
- `bid/rid` 可固定为 0；`bresp/rresp` 返回 `OKAY`；未映射地址可返回 `DECERR`（也可简化返回 0）。
- 当前 `rresp` 端口宽度在代码里写成了 `AXI_LITE_STRB_WIDTH`，实际 AXI-Lite 标准应为 2 bit，后续实现时建议修正为 `[1:0]`。

## 5. 后续实现时可裁剪/调整的点

1. 如果 IP 只做固定 1080p/720p，`IMG_WIDTH/IMG_HEIGHT` 可改为只读或删掉。
2. 如果不需要中断，可以去掉 `INT_EN/INT_STATUS`。
3. 如果不需要调试，可去掉 `DBG_*` 寄存器。
4. 如果最终不打算引出 `tuser/tid/tdest`，对应寄存器可暂不实现。
5. 若 DVP 输入格式固定，`DVP_CTRL.PIX_FMT` 可改为只读状态或完全去掉。
6. `LINE_TOTAL / FRAME_TOTAL` 如果仅用于调试，也可合并到 `DBG_*` 区域。

## 6. 数据通路行为与配置生效时机（v1.0 实现口径）

### 6.1 结构

```
pdin/pvref/phref ──4 级同步链──┬─ 像素合并（按 PIX_FMT 定每像素字节数）
                              ├─ 行/帧计数与边界判定（LINE/FRAME SHORT/LONG）
                              └─ beat 打包（PACK_EN/PACK_MODE/BYTE_SWAP/TLAST_MODE）
                                        │  sideband：{frame_last, tlast, bswap, 有效字节数-1}
                                  异步 FIFO（pclk 写 / aclk 读，深度 1024 beat）
                                        │
                              AXI-Stream 输出（tvalid/tdata/tstrb/tkeep/tlast，aclk）
```

- 行/帧口径：行长 = `phref` 有效期间接收的像素数；帧长 = `pvref` 有效期间接收的行数。
- 行内像素**不跨 beat 拆分**；每行独立打包（一行的 beat 不会跨到下一行）。
- 短包：行短/帧短时按实际长度结束，最后一拍按实际字节数产生 `tstrb`（`TSTRB_EN=1` 时），
  帧末拍在 `TLAST_MODE=0/1` 两种模式下都拉高 `tlast`（行末即帧末）。
- 溢出：FIFO 满时仍到达的 beat 被丢弃并置 `ERR_FLAG.FIFO_OVERFLOW`（DVP 源不可反压）。

### 6.2 字节序与像素排列（重要）

| 环节 | 口径 |
|---|---|
| DVP 合并 | 每像素 N 拍、**首个拍为像素最高字节**（N = `PIX_FMT` 决定的字节数） |
| `DVP_CTRL.BYTE_SWAP=1` | 合并处交换像素内高低字节 |
| beat 内排列 | 小端：第 k 个像素占 `[k*N +: N]` 字节，首个像素在 beat 低字节；行末有效字节自低字节连续 |
| `AXIS_CTRL.BYTE_SWAP=1` | **整 beat 字节反转**（byte i ↔ byte STRB-1-i）：首像素落到高字节、有效字节位于 beat 高字节 |
| `tstrb` | `TSTRB_EN=1` 时按有效字节位置产生掩码（大端时为高位掩码）；`TSTRB_EN=0` 时恒全 1 |
| 填充 | 未使用字节为 0 |

### 6.3 配置生效时机（软件必须遵守）

- **pclk 域使用的参数统一在 `pvref` 帧边界（原始 pvref 的上升/下降沿）提交**：
  `CTRL`（EN/SINGLE_SHOT/AUTO_RESTART）、`DVP_CTRL`（PIX_FMT/PHREF_POL/BYTE_SWAP）、
  `IMG_WIDTH/IMG_HEIGHT`、`AXIS_CTRL`（作用于打包/tlast 的位）、`LINE_TOTAL/FRAME_TOTAL`。
  提交采用「整组握手」：写入后由 aclk 侧发起请求（数据冻结 + 格雷码跨域），pclk 侧在帧边界整组加载并回 ack。
  **每个 pvref 边沿最多推进一次请求**，因此一次写入多笔配置后，需要若干个帧边界（≈ 寄存器笔数/2 个帧）
  才能全部生效；对时序敏感的软件应「写配置 → 等待若干帧 → 再开始采集」，或轮询 `STATUS.CFG_PENDING` 直到归 0。
- **写入与帧边界竞态时按「本帧用旧值」处理**：即在某个帧边界提交的配置，从**下一个**帧开始生效，
  当帧的采集/打包/边界判定仍使用提交前的影子值。
- `DVP_CTRL.PVREF_POL` / `DVP_CTRL.PCLK_INV` 例外：**写入后立即生效**（前者必须先可用才能判断 pvref 何时有效，
  后者只影响采样沿选择）。`FIFO_THRESHOLD` 亦为 aclk 侧立即生效（只用于生成 `FIFO_STATUS.ALMOST_FULL`）。
- `CTRL.EN` 亦随帧边界提交（不是立即生效）：写 `EN=1` 后，下一个 `pvref` 边沿提交，
  再下一个帧开始采集；`SINGLE_SHOT=1 且 AUTO_RESTART=0` 时单帧采集完成后进入 DONE 状态，
  需重新写 `EN=0` 再写 `EN=1` 重新武装。
- aclk 侧即时生效项：`INT_EN`、`AXIS_CTRL.TSTRB_EN`、`CTRL` 的 SOFT_RST/CLR_CNT 等写动作。

### 6.4 实现状态（v1.0 补齐结果）

原先在本文档登记为「未实现/残留」的项已全部补齐，实现口径如下：

| 项 | 实现口径 |
|---|---|
| `ERR_FLAG.AXIS_ERR` | 检测 `tvalid && !tready` 持续计数；达到 8192 个 aclk 即置位（一次停滞只上报一次，握手恢复后重新武装）；`INT_STATUS[4]` 同拍置位 |
| `DVP_CTRL.PCLK_INV` | 采样沿可选：`=1` 时输入取自 `negedge pclk` 寄存的一拍再进 4 级同步链；**写入后立即生效**（不随帧边界提交） |
| `CTRL.SOFT_RST / CLR_CNT / CLR_FIFO` 跨域清除 | 三者的清除作用经「翻转式请求/确认电平」跨到 pclk 域：pclk 域主状态机、像素合并、行/帧计数、打包寄存器、`DBG_PIX_CNT/DBG_LINE_CNT` 一并复位；`SOFT_RST/CLR_FIFO` 额外冲刷 FIFO（两侧指针成对复位，写侧仅冲刷类动作复位，`CLR_CNT` 不动 FIFO 指针）并清 `FIFO_STATUS` 溢出/下溢粘滞位；`SOFT_RST` 额外清 `INT_STATUS` |
| `FIFO_THRESHOLD` | 生成高水位指示 `FIFO_STATUS[20] ALMOST_FULL`（水位 ≥ 阈值），写 0 关闭；aclk 侧立即生效 |
| 配置握手在途状态 | 引出为 `STATUS[6] CFG_PENDING`：写配置组任一寄存器置 1，该批配置在帧边界全部提交后清 0 |

仍存在的限制：

| 项 | 现状 | 影响 |
|---|---|---|
| DVP 输入位宽 | 仅支持 `DVP_DWIDTH=8`（字节串行），其他取值 elaboration 期报错 | 并口/多字节每拍输入需扩展合并逻辑 |
| 配置握手 ack 超时 | 内部有 `cfg_ack_timeout`（pclk 侧长时间不确认时使等待计数饱和），但**未引出到寄存器** | 正常时序下不会触发（pclk 域始终会确认）；异常时软件只能通过 `STATUS.CFG_PENDING` 长期为 1 间接察觉 |
| `AXIS_TID/TDEST/TUSER` | 寄存器可读写，但未引出到模块端口 | 需要时按 §3.14 的位宽定义加端口即可 |
| 清除动作的传播延迟 | 跨域握手需要数个 pclk/aclk 周期；写入返回后立即回读可能仍读到清除前的值 | 软件应等待若干时钟周期（或轮询 `STATUS.CFG_PENDING`）再回读计数类寄存器 |
| 冲刷窗口内的输出 | `SOFT_RST/CLR_FIFO` 期间 AXIS 输出暂停（tvalid 拉低）约「握手往返 + 3 aclk」 | 下游需容忍该短暂停顿 |

> 上述项与 `Doc/Dev_report_0923.md`「已知限制」保持一致。
