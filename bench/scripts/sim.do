# =============================================================================
# VRF_AXI4L ModelSim 脚本
#   用法（交互式或命令行）：
#     vsim -c -do "do bench/scripts/sim.do"            ;# 使用下方默认参数
#     vsim -c -do "set TEST tb_vrf_axil_demo; do bench/scripts/sim.do"
#   说明：必须使用 -mfcu 编译（接口位于 $unit 作用域，需与 package 同编译单元）
# =============================================================================

# ------------------------------ 可覆盖参数 ------------------------------
if {![info exists TEST]}  { set TEST  "tb_dvp2ax_stream" }
if {![info exists SEED]}  { set SEED  0 }
if {![info exists NRAND]} { set NRAND 0 }
if {![info exists COVER]} { set COVER 0 }
# ------------------------------------------------------------------------

# 按测试选择协议检查器 bind 目标与独立工作库
if {$TEST eq "tb_vrf_axil_demo"} {
  set BIND_DEF "+define+VRF_AXIL_BIND_REF"
  set LIB_NAME "work_demo"
} else {
  set BIND_DEF "+define+VRF_AXIL_BIND_DVP2AXI"
  set LIB_NAME "work_dvp2axi"
}

file mkdir log
foreach {d} [glob -nocomplain -type d work*] { catch { file delete -force $d/_lock } }
if {[file exists $LIB_NAME] == 0} { vlib $LIB_NAME }

set VLOG_OPTS [list -mfcu -cuname ${TEST}_cu -sv -work $LIB_NAME $BIND_DEF]
if {$COVER} { set VLOG_OPTS [concat $VLOG_OPTS [list -cover bcesft]] }
set VLOG_OPTS [concat $VLOG_OPTS [list -f bench/scripts/filelist.f]]

echo "\[VRF_AXIL\] compile : $TEST  ($BIND_DEF)"
eval vlog $VLOG_OPTS

set VSIM_OPTS [list -c -l log/$TEST.log $LIB_NAME.$TEST]
if {$COVER}      { set VSIM_OPTS [concat [list -coverage] $VSIM_OPTS] }
if {$SEED  != 0} { set VSIM_OPTS [concat $VSIM_OPTS [list +seed=$SEED]] }
if {$NRAND != 0} { set VSIM_OPTS [concat $VSIM_OPTS [list +n_rand=$NRAND]] }
set VSIM_OPTS [concat $VSIM_OPTS [list +log_dir=log]]

set DO_CMD "run -all; quit -f"
if {$COVER} { set DO_CMD "coverage save -onexit log/$TEST.ucdb; run -all; quit -f" }
set VSIM_OPTS [concat [list -do $DO_CMD] $VSIM_OPTS]

echo "\[VRF_AXIL\] simulate : $TEST  seed=$SEED"
eval vsim $VSIM_OPTS

echo "\[VRF_AXIL\] report : log/$TEST\_report.txt"
echo "\[VRF_AXIL\] ucdb   : log/$TEST.ucdb (generated when COVER=1, view with: vcover report -detail)"
