# =============================================================================
# VRF_AXI4L 统一入口 Makefile
#
#   为避免脚本逻辑出现两份、产生漂移，本 Makefile 仅作为统一入口，
#   内部调用已验证的 PowerShell 脚本：
#     bench/scripts/run.ps1        单用例编译 + 仿真 + 报告
#     bench/scripts/regression.ps1 多种子批量回归
#     bench/scripts/check_env.ps1  前置条件检查
#
#   常用目标：
#     make check                       # 前置检查（解释器/仿真器/工程文件/目录可写）
#     make demo                        # 库自测用例（从机参考模型）
#     make dvp                         # DVP2axi_stream 接入示例
#     make run TEST=tb_vrf_axil_demo SEED=12345 NRAND=250
#     make cover TEST=tb_dvp2ax_stream # 带功能覆盖率收集
#     make regress SEEDS=1,2,3         # 批量回归
#     make fault                       # 故障注入自测：验证失败复现与错误报告链路
#     make clean                       # 清理生成物（work* 与日志目录）
#
#   可覆盖变量：PWSH / PWSH_FLAGS / TEST / SEED / NRAND / SEEDS / TIMEOUT / OUT
#     PWSH   解释器本身（默认 powershell）；命令行选项请放在 PWSH_FLAGS，不要写进 PWSH
#     SEED / NRAND  只有「命令行或环境显式给出」时才下发对应 plusarg（0 亦是有效取值）；
#                   未显式给出时不下发，交由用例取默认（随机种子 / 用例内置随机事务数）
# =============================================================================

PWSH       ?= powershell
PWSH_FLAGS ?= -NoProfile -ExecutionPolicy Bypass -File

TEST    ?= tb_dvp2ax_stream
SEED    ?= 0
NRAND   ?= 0
SEEDS   ?= 1,2,3,4,5
TIMEOUT ?= 900
OUT     ?= log

# 按「变量来源」而不是按取值判断是否显式覆盖：
#   $(origin X) 取值为 command line / environment / file（由上面的 ?= 赋值）/ default / undefined
# 这样 0 仍是有效取值（make run SEED=0 NRAND=0 会如实下发），未显式给出则完全不下发
OVERRIDDEN = $(filter command line environment,$(origin $(1)))
SEED_ARG   := $(if $(call OVERRIDDEN,SEED),-Seed $(SEED),)
NRAND_ARG  := $(if $(call OVERRIDDEN,NRAND),-Nrand $(NRAND),)

RUN := bench/scripts/run.ps1
REG := bench/scripts/regression.ps1
CHK := bench/scripts/check_env.ps1

# 解释器可用性探测：写成「递归展开」变量，只有引用了它的配方才会真正执行探测，
# 因此 clean / -n 等不需要解释器的目标不会因主机缺少 PowerShell 而失败。
# 探测要求解释器回显哨兵串：只看哨兵、不看退出码与 stderr，
# 避免「解释器能跑但打印了警告/横幅」被误判为不可用（探测本身也不在错误信息里重复展开）。
PWSH_PING = $(shell $(PWSH) -NoProfile -Command "Write-Output VRF_PWSH_OK")
REQUIRE_PWSH = $(if $(filter VRF_PWSH_OK,$(strip $(PWSH_PING))),,$(error 无法执行 '$(PWSH)'：未取到哨兵输出 VRF_PWSH_OK；PWSH 应只写解释器本身、选项放到 PWSH_FLAGS，或用 make PWSH=pwsh 指定其他解释器))

.PHONY: all check demo dvp run cover regress fault clean

all: dvp

# 前置检查：解释器可用性、ModelSim 工具、工程文件、日志目录
check:
	@$(REQUIRE_PWSH)$(PWSH) $(PWSH_FLAGS) "$(CHK)" -LogDir "$(OUT)"

demo: check
	@$(PWSH) $(PWSH_FLAGS) "$(RUN)" -Test "tb_vrf_axil_demo" $(SEED_ARG) $(NRAND_ARG) -LogDir "$(OUT)"

dvp: check
	@$(PWSH) $(PWSH_FLAGS) "$(RUN)" -Test "tb_dvp2ax_stream" $(SEED_ARG) $(NRAND_ARG) -LogDir "$(OUT)"

run: check
	@$(PWSH) $(PWSH_FLAGS) "$(RUN)" -Test "$(TEST)" $(SEED_ARG) $(NRAND_ARG) -LogDir "$(OUT)"

# cover = run + -Cover，同样支持 SEED/NRAND 覆盖，便于复现覆盖率跑批
cover: check
	@$(PWSH) $(PWSH_FLAGS) "$(RUN)" -Test "$(TEST)" $(SEED_ARG) $(NRAND_ARG) -Cover -LogDir "$(OUT)"

regress: check
	@$(PWSH) $(PWSH_FLAGS) "$(REG)" -Test "$(TEST)" -Seeds "$(SEEDS)" -LogDir "$(OUT)" $(NRAND_ARG) -TimeoutSec "$(TIMEOUT)"

# 故障注入自测：只跑定向段（显式下发 -Nrand 0），保证稳定命中注入点
fault: check
	@$(PWSH) $(PWSH_FLAGS) "$(RUN)" -Test "tb_vrf_axil_demo" -Nrand 0 -Fault -LogDir "$(OUT)"

# OUT 只允许相对项目根目录的路径：clean 会对它做递归删除，
# 绝对路径（如 OUT=D:\logs）可能越出工程范围，此时跳过删除该目录，只清理工作库
OUT_REL := $(if $(findstring :,$(OUT)),,$(OUT))

# 删除命令的语法取决于配方实际使用的 shell，而不是主机 OS：
#   MinGW/MSYS2 的 make 在 Windows 上也可能把 SHELL 指到 sh，此时 cmd 专用的
#   if exist / rmdir 会直接报语法错，因此按 $(SHELL) 选择分支。
ifeq ($(findstring sh,$(notdir $(SHELL))),sh)
RM_WORK = rm -rf $(OUT_REL) work work_demo work_dvp2axi
else
RM_WORK = if exist "$(OUT_REL)" rmdir /S /Q "$(OUT_REL)" & if exist "work" rmdir /S /Q "work" & if exist "work_demo" rmdir /S /Q "work_demo" & if exist "work_dvp2axi" rmdir /S /Q "work_dvp2axi"
endif

# 清理生成物：run.ps1 为每个用例创建独立工作库（work_demo / work_dvp2axi），必须一并删除
clean:
	@$(RM_WORK)
	@echo "[VRF_AXIL] 已清理生成物：work* 与 $(OUT)/"
