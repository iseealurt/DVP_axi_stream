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
  string       reg_map            = "DVP2AXI"; // 寄存器映射：DVP2AXI / REF_SLAVE

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

  // ------------------------------ 连通性自检与覆盖率 ------------------------------
  bit enable_bringup_check = 1;
  bit enable_coverage      = 1;

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
