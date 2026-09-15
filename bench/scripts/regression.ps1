<#
  VRF_AXI4L 批量回归脚本

  用法：
    powershell -File bench/scripts/regression.ps1
    powershell -File bench/scripts/regression.ps1 -Test tb_dvp2ax_stream -Seeds 1,2,3,4,5,6,7,8
    powershell -File bench/scripts/regression.ps1 -Nrand 400 -Cover

  说明：
    - 对每个种子调用 run.ps1 完成一次完整编译+仿真，日志隔离到 log/regression/seed_<n>/
    - 解析每轮报告的检查项/失败项，汇总通过率与失败用例清单
    - 失败轮次的随机种子被记录，可直接用 run.ps1 -Seed <n> 复现
#>
param(
  [ValidateSet("tb_vrf_axil_demo", "tb_dvp2ax_stream")]
  [string]  $Test  = "tb_dvp2ax_stream",
  [string]  $Seeds = "1,2,3,4,5",
  [int]     $Nrand = 0,
  [switch]  $Cover
)

$ErrorActionPreference = "Continue"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $root

$regDir = "log/regression"
New-Item -ItemType Directory -Force -Path $regDir | Out-Null

$runScript = Join-Path $PSScriptRoot "run.ps1"
$seedList  = $Seeds -split ',' | ForEach-Object { [int]$_.Trim() }
$rows = @()
$nPass = 0
$nFail = 0
$failSeeds = @()

foreach ($s in $seedList) {
  $rundir = "$regDir/seed_$s"
  New-Item -ItemType Directory -Force -Path $rundir | Out-Null

  Write-Host ""
  Write-Host "########## 回归轮次 seed=$s ##########"
  $runArgs = @{ Test = $Test; Seed = $s; LogDir = $rundir }
  if ($Nrand -gt 0) { $runArgs.Nrand = $Nrand }
  if ($Cover)       { $runArgs.Cover = $true }
  & $runScript @runArgs | Out-Host

  # 解析报告
  $reportFile = "$rundir/$Test`_report.txt"
  $checked = 0
  $fails   = 0
  $astFail = 0
  $verdict = "NO_REPORT"
  if (Test-Path $reportFile) {
    $txt = Get-Content $reportFile -Raw
    if ($txt -match "检查\s+(\d+)\s+项,\s+失败\s+(\d+)\s+项,\s+断言失败\s+(\d+)\s+项") {
      $checked = [int]$Matches[1]
      $fails   = [int]$Matches[2]
      $astFail = [int]$Matches[3]
    }
    if ($txt -match "SIMULATION PASSED") { $verdict = "PASSED" }
    elseif ($txt -match "SIMULATION FAILED") { $verdict = "FAILED" }
  }

  $rows += [pscustomobject]@{
    Seed      = $s
    Checks    = $checked
    Failures  = $fails
    AssertErr = $astFail
    Verdict   = $verdict
  }
  if ($verdict -eq "PASSED" -and $fails -eq 0 -and $astFail -eq 0) { $nPass++ }
  else { $nFail++; $failSeeds += $s }
}

# ------------------------------ 汇总输出 ------------------------------
$totalChecks = ($rows | Measure-Object -Property Checks -Sum).Sum
$summary = @()
$summary += "# VRF_AXI4L 批量回归汇总"
$summary += "# 测试用例 : $Test"
$summary += "# 回归轮次 : $($seedList.Count)"
$summary += "# 随机种子 : $($seedList -join ', ')"
$summary += "# 通过轮次 : $nPass"
$summary += "# 失败轮次 : $nFail"
$summary += "# 累计检查项 : $totalChecks"
$summary += "# ---------------------------------------------------------------"
$summary += ("{0,-8} {1,-10} {2,-10} {3,-12} {4}" -f "Seed", "Checks", "Failures", "AssertErr", "Verdict")
foreach ($r in $rows) {
  $summary += ("{0,-8} {1,-10} {2,-10} {3,-12} {4}" -f $r.Seed, $r.Checks, $r.Failures, $r.AssertErr, $r.Verdict)
}
if ($failSeeds.Count -gt 0) {
  $summary += "# ---------------------------------------------------------------"
  $summary += "# 失败种子（可用 run.ps1 -Seed <n> 复现）: $($failSeeds -join ', ')"
}
$summary += "# ---------------------------------------------------------------"
$summary += "# 结论 : $($(if ($nFail -eq 0) { 'REGRESSION PASSED' } else { 'REGRESSION FAILED' }))"

$summaryFile = "$regDir/summary.txt"
$summary | Set-Content -Encoding UTF8 $summaryFile

Write-Host ""
$summary | ForEach-Object { Write-Host $_ }
exit $(if ($nFail -eq 0) { 0 } else { 1 })
