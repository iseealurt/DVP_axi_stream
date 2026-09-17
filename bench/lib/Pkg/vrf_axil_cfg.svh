// =============================================================================
// 验证配置类
//   - 测试标识、随机种子、日志路径
//   - 激励规模与随机范围
//   - 驱动器/从机行为模型参数（含空行为模型：可关闭全部延迟）
//   - 各项检查开关、连通性自检开关、覆盖率开关
//   - 失败用例自动化复现开关
//   - 仿真上限兜底
// =============================================================================
class vrf_axil_cfg;
  // ------------------------------ 测试标识 ------------------------------
  string       test_name = "vrf_axil_demo";
  int unsigned seed      = 0;      // 随机种子，失败复现时按此值回放
  string       log_dir   = ".";    // 日志与报告落盘目录
  bit          verbose   = 1;      // 是否输出逐笔事务日志

  // ------------------------------ 激励规模 ------------------------------
  int    n_rand_txn      = 200;    // 随机事务数
  int    strb_mode       = 0;      // 0=随机 1=全选通 2=单字节
  bit    enable_directed = 1;      // 是否启用定向用例队列
  string directed_case   = "ALL";  // 定向用例名（ALL=全部）

  // ------------------------------ 地址空间 ------------------------------
  int unsigned addr_min           = 32'h00;
  int unsigned addr_max           = 32'h80;
  int unsigned bringup_probe_addr = 32'h80;   // 连通性自检使用的探针寄存器地址
  string       reg_map            = "";  // 寄存器映射名，由用例显式指定（取值与实现在寄存器模型文件内）

  // ------------------------------ 驱动器行为模型（可空） ------------------------------
  int aw_delay_min     = 0,  aw_delay_max     = 3;
  int w_delay_min      = 0,  w_delay_max      = 3;
  int bready_delay_min = 0,  bready_delay_max = 3;
  int rready_delay_min = 0,  rready_delay_max = 3;
  int idle_cycles_min  = 0,  idle_cycles_max  = 2;

  // ------------------------------ 从机参考模型行为参数 ------------------------------
  bit use_slave_model     = 0;    // 1：环境额外启用从机参考模型（SLV 角色）
  int slv_ready_delay_min = 0;
  int slv_ready_delay_max = 2;

  // ------------------------------ 检查开关 ------------------------------
  bit enable_xz_check        = 1;
  bit enable_stability_check = 1;
  bit enable_protocol_check  = 1;
  bit enable_timeout_check   = 1;
  int timeout_cycles         = 200;

  // ------------------------------ 响应 ID 判定（DUT 能力差异不写死在库内） ------------------------------
  bit          exp_id_check = 1;   // 是否检查响应通道的事务 ID
  int unsigned exp_id_value = 0;   // 期望的响应 ID（本 DUT 的 bid/rid 恒为 0）

  // ------------------------------ 连通性自检与覆盖率 ------------------------------
  bit enable_bringup_check = 1;
  bit enable_coverage      = 1;

  // 覆盖率能力开关（本 DUT 能否表现出对应行为）：
  //   异常响应与非 0 ID 的 bin 是否计入覆盖率分母，由**编译期**开关决定
  //   （ModelSim 2020.4 不支持 covergroup 参数端口，运行期 iff 亦在 elaboration 期固化）：
  //     +define+VRF_AXIL_COV_HAS_ERR  —— DUT 会产生 SLVERR/DECERR
  //     +define+VRF_AXIL_COV_HAS_ID   —— DUT 会返回非 0 事务 ID
  //   这里的 cfg 开关是 API 侧声明，构造覆盖率收集器时与编译期开关做一致性校验（不一致即 $fatal）。
  bit          has_err_resp = 0;
  bit          has_id       = 0;
  // 覆盖率地址区间上下限：覆盖点的地址区间按此归一为「四等分 + 顶部寄存器区 + 区间外」，
  // 使 bin 定义与具体 DUT 的地址布局解耦（默认对应 0x00~0x80 的寄存器空间）
  int unsigned cov_addr_lo  = 32'h00;
  int unsigned cov_addr_hi  = 32'h80;

  // ------------------------------ 失败用例自动化复现 ------------------------------
  bit    enable_repro       = 0;
  int    repro_max_attempts = 1;
  string seed_file          = "repro_seed.txt";

  // ------------------------------ 仿真上限兜底 ------------------------------
  int  max_txn      = 20000;
  time max_sim_time = 1ms;

  function new(string name = "vrf_axil_cfg");
    test_name = name;
  endfunction
endclass
