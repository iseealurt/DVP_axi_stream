# =============================================================================
# VRF_AXI4L 统一入口 Makefile
#
#   为避免脚本逻辑出现两份、产生漂移，本 Makefile 仅作为统一入口，
#   内部调用已验证的 PowerShell 脚本 bench/scripts/run.ps1 与 regression.ps1。
#
#   常用目标：
#     make demo                      # 库自测用例（从机参考模型）
#     make dvp                       # DVP2axi_stream 接入示例
#     make run TEST=tb_vrf_axil_demo SEED=12345
#     make cover                     # 带覆盖率收集运行
#     make regress                   # 批量回归（多种子）
#     make fault                     # 故障注入自测：验证失败复现与错误报告链路
#     make clean                     # 清理库、日志与报告
# =============================================================================

PWSH   ?= powershell -ExecutionPolicy Bypass -File
RUN    := bench/scripts/run.ps1
REG    := bench/scripts/regression.ps1

TEST   ?= tb_dvp2ax_stream
SEED   ?= 0
NRAND  ?= 0

.PHONY: all demo dvp run cover regress fault clean

all: dvp

demo:
	$(PWSH) $(RUN) -Test tb_vrf_axil_demo

dvp:
	$(PWSH) $(RUN) -Test tb_dvp2ax_stream

run:
	$(PWSH) $(RUN) -Test $(TEST) -Seed $(SEED) -Nrand $(NRAND)

cover:
	$(PWSH) $(RUN) -Test tb_dvp2ax_stream -Cover

regress:
	$(PWSH) $(REG) -Test tb_dvp2ax_stream -Seeds 1,2,3,4,5

fault:
	$(PWSH) $(RUN) -Test tb_vrf_axil_demo -Nrand 0 -Fault

clean:
	-rmdir /S /Q work log 2>NUL
