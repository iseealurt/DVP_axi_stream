<#
  VRF_AXI4L 一键编译与仿真脚本（ModelSim）

  用法：
    powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 12345
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Cover
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Clean

  说明：
    - 库自测 demo 与 DVP2axi_stream 接入示例的 bind 目标不同，
      脚本按 -Test 自动选择编译模式（VRF_AXIL_BIND_REF / VRF_AXIL_BIND_DVP2AXI）。
    - 仿真日志与报告输出到 log/ 目录。
#>
param(
  [ValidateSet("tb_vrf_axil_demo", "tb_dvp2ax_stream")]
  [string] $Test = "tb_dvp2ax_stream",
  [int]    $Seed = 0,
  [int]    $Nrand = 0,
  [string] $LogDir = "log",
  [switch] $Fault,
  [switch] $Cover,
  [switch] $Clean
)

$ErrorActionPreference = "Continue"

# 切到项目根目录（脚本位于 bench/scripts 下）
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $root

# 清理上一次异常退出残留的库锁
Remove-Item -Recurse -Force work\_lock -ErrorAction SilentlyContinue

if ($Clean) { Remove-Item -Recurse -Force work -ErrorAction SilentlyContinue }
if (!(Test-Path work)) { vlib work | Out-Null }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ------------------------------ 按测试选择 bind 目标 ------------------------------
switch ($Test) {
  "tb_vrf_axil_demo" { $bindDef = "+define+VRF_AXIL_BIND_REF" }
  "tb_dvp2ax_stream" { $bindDef = "+define+VRF_AXIL_BIND_DVP2AXI" }
}

# ------------------------------ 编译 ------------------------------
$vlogArgs = @("-mfcu", "-sv", "-work", "work", $bindDef)
if ($Cover) { $vlogArgs += @("-cover", "bcesft") }
$vlogArgs += @("-f", "bench/scripts/filelist.f")

Write-Host "[VRF_AXIL] 编译 : $Test  ($bindDef)"
vlog @vlogArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host "[VRF_AXIL] 编译失败，终止。"
  exit 1
}

# ------------------------------ 仿真 ------------------------------
$doCmd = "run -all; quit -f"
if ($Cover) { $doCmd = "coverage save -onexit $LogDir/$Test.ucdb; run -all; quit -f" }

$vsimArgs = @("-c", "-do", $doCmd, "-l", "$LogDir/$Test.log", "work.$Test")
if ($Cover)        { $vsimArgs += "-coverage" }
if ($Seed -ne 0)   { $vsimArgs += "+seed=$Seed" }
if ($Nrand -gt 0)  { $vsimArgs += "+n_rand=$Nrand" }
if ($Fault)        { $vsimArgs += "+fault_inject=1" }
$vsimArgs += "+log_dir=$LogDir"

Write-Host "[VRF_AXIL] 仿真 : $Test  seed=$Seed"
vsim @vsimArgs

# ------------------------------ 汇总 ------------------------------
$reportFile = "$LogDir/$Test`_report.txt"
if (Test-Path $reportFile) {
  Write-Host "[VRF_AXIL] 报告 : $reportFile"
}
exit $LASTEXITCODE
