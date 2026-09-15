# AXI4-L 自建验证库开发计划@20260915
## 需求预览
基于System Verilog语言，实现AXI4-L接口的通用验证平台/库文件搭建。库本体与具体DUT解耦，支持通配符自动连接和信号驱动状态检查，支持对AXI4-L接口进行受约束随机与定向验证测试，并配套可用于形式化的SVA断言，支持计分板和事务监视器，支持失败用例自动化复现和对应的错误报告格式化输出。

## 范围与边界
1. 本轮验证对象仅限AXI4-Lite寄存器接口，DVP输入与AXI-Stream输出通路不纳入本轮验证。
2. 不纳入验证的端口不做tie-off，由连通性自检与报告头统一告警。当前RTL中pdin/pvref/phref/axis_tready为未使用输入，axis_tvalid/tdata/tlast恒为0，不存在X态向寄存器块传播的风险。
3. 本轮不引入UVM标准库，采用精简手写分层：只保留env/config/sequence/sequencer/driver/monitor/scoreboard等必要类与mailbox通信，不做factory、phase、objection等重型机制，由显式run()串起流程。
4. 「形式化验证」本轮落地为仿真为主 + SVA断言，断言按formal-friendly方式编写，后续可直接接入形式化工具，本轮不搭建形式化工具环境。
5. 库定位为通用可复用验证库，另附本项目DVP2axi_stream的接入示例。

## 技术底座与总体约定
1. 命名前缀统一为VRF_AXI4L（如vrf_axil_txn、vrf_axil_driver），文件按vrf_axil_*.sv命名；沿用现有bench/IF与bench/Pkg的命名脉络。
2. 默认参数按DUT设定为AWIDTH=32、DWIDTH=32、IDWIDTH=4，由实例化覆盖以支持其他位宽。
3. 现有if_axil.sv（mst/slv/mnt三视角接口）与VRF_AXI4L.sv（axil_txn）作为库的起点，原地重构并补全监视与断言所需信号，不推倒重写。
4. 预期值来源为自建轻量寄存器模型（RAL-like），维护镜像值与访问属性，计分板据此自动预测。
5. 功能覆盖率用SV内建covergroup采样，仿真结束经UCDB汇总并输出文本报告。
6. 协议断言与检查器写成独立binder模块，通过bind挂到DUT与接口上，不侵入RTL。
7. 仿真终止采用完成计数自动结束（objection式），并由config设最大仿真时间/最大事务数兜底。

## 目录结构
```
bench/
  lib/                              # 库本体，与具体DUT解耦
    IF/    vrf_axil_if.sv           # mst/slv/mnt三视角接口，含自动绑定辅助
    Pkg/   vrf_axil_pkg.sv          # 枚举、axil_txn、配置类等
    Seq/   vrf_axil_sequence.sv     # generator类
           vrf_axil_sequencer.sv    # 序列器类
    Drv/   vrf_axil_driver.sv       # 驱动器类
    Mon/   vrf_axil_monitor.sv      # 监视器类
    Reg/   vrf_axil_regmodel.sv     # RAL-like寄存器模型
    Slv/   vrf_axil_slave.sv        # AXI4-Lite从机参考模型
    Chk/   vrf_axil_chk.sv          # 独立检查器/断言，bind到DUT与接口
    Cov/   vrf_axil_cov.sv          # 功能覆盖率
    Env/   vrf_axil_env.sv          # 环境类
           vrf_axil_scoreboard.sv   # 计分板
  tb/    tb_vrf_axil_demo.sv        # 库自测：env + 从机参考模型
         tb_dvp2ax_stream.sv        # 接入示例：env + DVP2axi_stream
  scripts/  *.do / *.ps1 / Makefile # 编译、仿真、回归、日志解析
Doc/     API_VRF_AXI4L.md           # API接口文档
```

## 组件/结构预览
1. 环境类：存放和封装其他组件，支持使用run()、new()等功能函数一键启用测试环境，支持向sequencer（测试序列）内一键导入定向测试队列，支持自动化仿真；内部维护未完成事务计数，所有事务、断言与检查结束后自动进入报告阶段。
2. config配置类：设置本轮验证的各项参数，包括测试向量的覆盖范围，是否启用定向验证，是否启用失败用例复现，最大仿真时间与最大事务数上限，随机种子与结果落盘路径等功能。
3. sequence（generator）类，根据配置参数，产生测试向量，并通过mailbox发送到sequencer内进行缓存和仲裁；支持按名自动挂载的定向用例队列。
4. sequencer类，接收来自sequence和环境的测试向量组成的队列，同样通过mailbox发送到driver类内，完成测试向量的输入；失败用例复现时接收计分板回传的失败事务并优先单笔重注。
5. driver（驱动器类），包括虚拟主从机接口和对应的可空行为模型，根据测试向量驱动虚拟接口产生对应的激励信号。
6. monitor监视器类，接收来自config类的配置信息，根据测试用例监视总线事务，生成并输出运行日志文件；与计分板通信，在自动化失败用例复现时，扩大和虚化信号监测范围，产生失败用例对应的错误报告。
7. 计分板：统一收集测试结果与预期结果，与寄存器模型比对生成功能覆盖率报告；根据是否启用自动化失败用例复现选项，将失败用例传递到sequencer内实现失败用例的自动化复现的功能。
8. 寄存器模型：维护各寄存器的镜像值、访问属性（R/W、RO、W1C、自清零）、wstrb字节使能与复位默认值，为计分板提供预期值预测。
9. 从机参考模型：实现AXI4-Lite从端行为（含反压、resp返回、未映射地址处理），作为库自测用例的对端，使库的验证不依赖DUT完成度。
10. 检查器（binder）：以独立模块承载AXI4-L协议property/assert，bind到DUT与接口，仿真与形式化共用同一套属性。
11. 覆盖率收集器：用covergroup采样地址区间、读写方向、wstrb组合、resp类型、ID与事务长度等维度，统一汇总输出。

## 关键机制定义
### 通配符自动连接
1. DUT端口→interface按名自动绑定：依据DUT端口名与interface信号名的模式匹配（如*aw*、*rvalid*、*axis_*）自动建立绑定，并推断方向与位宽。
2. 信号连通性自检：在自动化验证开始前执行一次基础信号激励测试，监测本轮验证所驱动的信号是否完整连接无纰漏，识别未驱动、恒定与位宽不匹配的信号，并在仿真报告头反馈。
3. 定向用例/序列按名自动注册并挂载到环境的定向队列，无需手动逐个add。

### 信号驱动状态检查
1. X/Z未知态与复位期间约束：总线信号不得出现X/Z；复位期间valid必须为0。
2. 握手稳定性检查：valid拉高后在其对应ready到来前，addr/data/strb保持不变；ready拉高后不得随意撤销。
3. 通道协议与resp合法性：AW/W可乱序到达但必须都到齐才响应；R/B不得在无请求时拉高；resp只能取合法编码（OKAY/SLVERR/DECERR）。
4. 超时检测：请求发出后限定周期内未收到响应，或ready长期为低的超时检测，超时归入FAIL/TIMEOUT并输出报告。

### 失败用例自动化复现
1. 每轮仿真记录随机种子与事务ID，失败时先用相同种子回放整个用例，保证失败可重现。
2. 定位到具体事务后，将失败事务对象单独重新注入sequencer做定向重放，同时由monitor扩大并虚化信号监测范围，产生该用例对应的错误报告。
3. 复现过程与报告由config中的复现开关统一控制，默认关闭。

### 功能覆盖率
1. 用SV内建covergroup采样，仿真结束经UCDB汇总，并输出文本报告。
2. 覆盖维度至少包含：地址区间、读写方向、wstrb组合、resp类型、ID取值、事务并发情形。

## 四阶段开发计划
### 阶段一：接口层与自动连接
1. 以现有if_axil.sv为基础重构vrf_axil_if.sv，默认参数改为AWIDTH=32、DWIDTH=32、IDWIDTH=4，补全监视与断言所需信号。
2. 实现DUT端口→interface的按名通配符自动绑定，含方向与位宽推断。
3. 实现信号连通性自检与报告头输出。
4. 阶段产物：对DVP2axi_stream与从机参考模型均能完成自动绑定，并输出连通性自检报告。

### 阶段二：核心组件与寄存器模型
1. 重构事务类与配置类，补全复现与结果回填字段。
2. 实现sequence/sequencer、driver、monitor，以mailbox串起数据流。
3. 实现RAL-like寄存器模型与计分板，完成读写比对与结果收集。
4. 阶段产物：单写单读端到端闭环PASS，寄存器模型可预测全部寄存器行为。

### 阶段三：用例、覆盖与随机化
1. 实现定向用例队列一键导入与受约束随机用例。
2. 实现地址/方向/strb/resp分布约束与covergroup采样、UCDB汇总。
3. 阶段产物：库自测用例与DVP2axi_stream用例全部PASS，完成度不低于现有407项检查，覆盖率报告生成。

### 阶段四：断言、失败复现与报告回归
1. 实现独立检查器模块并bind到DUT与接口，覆盖握手稳定性、X/Z、通道协议、resp合法性与超时。
2. 实现seed回放与失败事务单笔重注的失败复现流程。
3. 实现错误报告格式化输出、回归脚本批量执行与日志解析汇总。
4. 输出API接口文档。
5. 阶段产物：验收标准全项达成。

## 交付物清单
1. 库本体源码：三视角接口、事务与配置类、sequence/sequencer、driver、monitor、计分板、寄存器模型、从机参考模型、覆盖率收集器、断言绑定模块。
2. API接口文档：每个类/方法/任务的功能、入参出参、调用时序与典型用法，供后续项目直接查阅复用。
3. demo环境与自测用例：演示如何把库接入一个新DUT，并作为库自身的回归入口。
4. 对DVP2axi_stream寄存器块的实际验证报告：含覆盖率结果与连通性自检结果，形式对标现有AXI4_Lite_Sim_Report.md。
5. 自动化脚本：ModelSim .do脚本、PowerShell一键脚本、Makefile统一入口、批量回归与日志解析脚本。

## 验收标准
1. 库自带demo用例全部PASS。
2. 对DVP2axi_stream寄存器块的验证完成度不低于现有407项检查，且全部PASS。
3. 新增X/Z未知态、握手稳定性、超时三类协议检查并全部PASS。
4. 生成功能覆盖率报告与信号连通性自检报告。
5. 回归脚本可一键跑出通过率与失败用例清单汇总。
6. API接口文档齐备，可据此在不改动库本体的前提下接入新DUT。

## 风险与待定项
1. DVP输入与AXIS输出本轮不做tie-off，连通性自检会持续报告未驱动告警，需在报告头中明确标注为「本轮不验证」，避免与真实缺陷混淆。
2. 寄存器模型中W1C、自清零、只读保护等行为的语义需与Doc/Reg_v_0_0.md保持一致，RTL调整时须同步更新模型。
3. 位宽不匹配（现有接口默认64-bit与DUT的32-bit）需在自动绑定阶段显式校验并报错。
4. AXI-Lite协议中的awport/arport为非标准端口，本轮按DUT现有定义保留，不纳入标准协议检查。
