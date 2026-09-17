<#
  VRF_AXI4L 批量回归脚本

  用法：
    powershell -File bench/scripts/regression.ps1
    powershell -File bench/scripts/regression.ps1 -Test tb_dvp2ax_stream -Seeds "1,2,3,4,5,6"
    powershell -File bench/scripts/regression.ps1 -Nrand 400 -Cover -TimeoutSec 600
    powershell -File bench/scripts/regression.ps1 -LogDir log_alt

  说明：
    - 对每个种子调用 run.ps1 完成一次完整编译+仿真，日志按「本次调用」命名空间隔离：
        <LogDir>/regression/run_<时间戳>_<pid>/seed_<n>/
    - 子进程退出码、仿真报告耗时、解析出的检查项/失败项共同决定该轮结论；
      任一环节异常（编译失败/仿真崩溃/超时/启动失败/报告缺失或陈旧/零检查项）都判为失败轮次，
      不再出现「报告缺失但显示 PASSED」这类假绿。
    - 轮次数与请求的种子数不一致（循环中途异常退出）同样判为整体失败，避免残留的
      通过计数被误当成成功。
    - 失败轮次的随机种子被记录，可直接用 run.ps1 -Seed <n> 复现。
#>
param(
  [ValidateSet("tb_vrf_axil_demo", "tb_dvp2ax_stream", "tb_vrf_axil_rst_window")]
  [string] $Test     = "tb_dvp2ax_stream",
  [string] $Seeds    = "1,2,3,4,5",
  [int]    $Nrand    = 0,
  [string] $LogDir   = "log",
  [int]    $TimeoutSec = 900,
  [switch] $Cover
)

$ErrorActionPreference = "Continue"

# ------------------------------ 参数校验 ------------------------------
if ($Nrand -lt 0) { Write-Host "[VRF_AXIL][ERROR] -Nrand 不能为负数，终止。"; exit 2 }
if ($TimeoutSec -lt 0) { Write-Host "[VRF_AXIL][ERROR] -TimeoutSec 不能为负数，终止。"; exit 2 }
# 上限校验：WaitForExit 的毫秒参数是 Int32，超范围会在等待条件里抛错并中断整个回归
if ($TimeoutSec -gt 86400) { Write-Host "[VRF_AXIL][ERROR] -TimeoutSec 过大（上限 86400 秒），终止。"; exit 2 }
# 与 run.ps1 一致：拒绝会破坏 Tcl 花括号引用或子进程参数引用的字符，允许路径含空格
if ([string]::IsNullOrWhiteSpace($LogDir) -or $LogDir -match '[{}"]' -or $LogDir -match '[\r\n]') {
  Write-Host "[VRF_AXIL][ERROR] -LogDir 不能为空，且不能包含花括号 { }、双引号或换行，终止。"
  exit 2
}
# 只有显式传参才向子进程下发 -Nrand（0 亦是有效取值）
$nrandGiven = $PSBoundParameters.ContainsKey('Nrand')

# 种子解析：逐项校验、丢弃空项、去重排序；出现非法项或结果为空则直接终止
$seedList = @()
foreach ($item in ($Seeds -split ',')) {
  $tok = $item.Trim()
  if ($tok -eq '') { continue }
  $n = 0
  if (-not [int]::TryParse($tok, [ref]$n)) {
    Write-Host "[VRF_AXIL][ERROR] 非法种子 '$tok'（须为整数），终止。"
    exit 2
  }
  if ($n -lt 0) {
    Write-Host "[VRF_AXIL][ERROR] 种子不能为负数（'$tok'），终止。"
    exit 2
  }
  $seedList += $n
}
$seedList = @($seedList | Sort-Object -Unique)
if ($seedList.Count -eq 0) {
  Write-Host "[VRF_AXIL][ERROR] 未提供有效种子，终止回归。"
  exit 2
}

# ------------------------------ 定位项目根目录 ------------------------------
$root = $null
try { $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..") -ErrorAction Stop).Path } catch { $root = $null }
if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
  Write-Host "[VRF_AXIL][ERROR] 无法定位项目根目录，终止。"
  exit 2
}

$runScript = Join-Path $PSScriptRoot "run.ps1"
if (-not (Test-Path -LiteralPath $runScript -PathType Leaf)) {
  Write-Host "[VRF_AXIL][ERROR] 未找到 $runScript，终止。"
  exit 2
}
# 子进程沿用「当前宿主解释器」，而不是写死 powershell：本脚本自身可能运行在 pwsh 下
# （如 make regress PWSH=pwsh），写死 powershell 会在只装 PowerShell 7 的主机上直接失败
$psExePath = $null
try { $psExePath = (Get-Process -Id $PID).Path } catch { $psExePath = $null }
if (-not $psExePath -or -not (Test-Path -LiteralPath $psExePath -PathType Leaf)) {
  foreach ($cand in @("powershell", "pwsh")) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($c) { $psExePath = $c.Source; break }
  }
}
if (-not $psExePath) {
  Write-Host "[VRF_AXIL][ERROR] 未找到可用的 PowerShell 解释器，终止。"
  exit 2
}

# ------------------------------ 输出目录按本次调用隔离 ------------------------------
$prevLoc    = $PWD.Path
$runTag     = "run_{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $PID
# -LogDir 既可能是相对项目根目录的路径，也可能是绝对路径
$logRoot    = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $root $LogDir }
$regDir     = Join-Path $logRoot "regression/$runTag"
$summaryFile = Join-Path $regDir "summary.txt"

$rows       = @()
$nPass      = 0
$nFail      = 0
$failSeeds  = @()
$loopError  = $null

try {
  New-Item -ItemType Directory -Force -Path $regDir | Out-Null
  Set-Location -LiteralPath $root

  foreach ($s in $seedList) {
    $rundir = Join-Path $regDir "seed_$s"
    New-Item -ItemType Directory -Force -Path $rundir | Out-Null

    Write-Host ""
    Write-Host ("#" * 20 + " 回归轮次 seed=$s " + "#" * 20)

    # 轮次开始前删除目标报告与退出码文件，避免上一轮遗留被误判为通过
    $reportFile = Join-Path $rundir "$Test`_report.txt"
    $exitFile   = Join-Path $rundir "$Test.exit"
    Remove-Item -Force -LiteralPath $reportFile -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath $exitFile   -ErrorAction SilentlyContinue
    $roundStart = Get-Date

    # 构造子进程参数（-Seed 显式传参，保证 seed=0 也可复现）
    # Start-Process -ArgumentList 只做空格拼接、不自动加引号，
    # 因此含空格的路径必须自带引号，否则会被拆成多个参数
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$runScript`"",
                 "-Test", $Test, "-Seed", "$s", "-LogDir", "`"$rundir`"")
    if ($nrandGiven)  { $argList += @("-Nrand", "$Nrand") }
    if ($Cover)       { $argList += "-Cover" }

    $timedOut  = $false
    $runExit   = $null
    $launchOk  = $true
    $launchErr = ""
    $proc = $null
    try {
      $proc = Start-Process -FilePath $psExePath -ArgumentList $argList -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
      # 必须在 catch 内取出错误信息：离开 catch 后 $_ 不再是该错误
      $launchOk  = $false
      $launchErr = $_.Exception.Message
    }
    if (-not $launchOk -or -not $proc) {
      # 启动失败是非终止错误，若不显式处理，后续 $proc.WaitForExit() 会终止整个回归
      Write-Host "[VRF_AXIL][ERROR] seed=$s 子进程启动失败（$launchErr），判为失败轮次。"
      $runExit = -1
    } elseif ($TimeoutSec -gt 0 -and -not $proc.WaitForExit($TimeoutSec * 1000)) {
      $timedOut = $true
      # vsim 是包装进程的子进程，必须整树终止，否则残留进程会占住工作库锁、拖垮后续轮次。
      # taskkill 仅 Windows 可用，其他平台用 pkill 按父进程 PID 终止子进程。
      if (Get-Command taskkill -ErrorAction SilentlyContinue) {
        try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
      } elseif (Get-Command pkill -ErrorAction SilentlyContinue) {
        try { & pkill -TERM -P $proc.Id 2>$null | Out-Null } catch { }
      }
      try { $proc.Kill() } catch { }
      Write-Host "[VRF_AXIL][WARN] seed=$s 超过 $TimeoutSec 秒未结束，已终止该轮次。"
    } else {
      # 无参 WaitForExit 确保退出信息完整，之后 ExitCode 才可靠
      try { $proc.WaitForExit() } catch { }
      try { $runExit = $proc.ExitCode } catch { $runExit = $null }
    }

    # run.ps1 会把退出码写入 <LogDir>/<Test>.exit，优先采用该文件（更可靠）
    if (-not $timedOut -and (Test-Path -LiteralPath $exitFile -PathType Leaf)) {
      $exitTxt = $null
      try { $exitTxt = Get-Content -LiteralPath $exitFile -Raw -ErrorAction Stop } catch { $exitTxt = $null }
      $exitNum = 0
      if ($null -ne $exitTxt -and [int]::TryParse($exitTxt.Trim(), [ref]$exitNum)) {
        $runExit = $exitNum
      } else {
        # 文件存在但读不出/不可解析：不能沿用包装进程的退出码，按失败处理
        Write-Host "[VRF_AXIL][WARN] seed=$s 退出码文件不可解析，判为失败轮次。"
        $runExit = -1
      }
    }

    # ------------------------------ 解析报告 ------------------------------
    $checked = 0
    $fails   = 0
    $astFail = 0
    $verdict = "NO_REPORT"
    $note    = ""

    if (-not (Test-Path -LiteralPath $reportFile -PathType Leaf)) {
      $note = "报告缺失"
    } else {
      $rpt = Get-Item -LiteralPath $reportFile
      if ($rpt.LastWriteTime -lt $roundStart.AddSeconds(-5)) {
        # 报告早于本轮开始 => 陈旧文件，不作为证据
        # 保留 5 秒容差：网络盘或时间戳粒度较粗的文件系统上，刚写出的报告时间可能略早于本机时钟
        $verdict = "STALE_REPORT"
        $note    = "报告陈旧（早于本轮开始）"
      } else {
        $txt = Get-Content -LiteralPath $reportFile -Raw
        if ($txt -match "检查\s+(\d+)\s+项,\s+失败\s+(\d+)\s+项,\s+断言失败\s+(\d+)\s+项") {
          $checked = [int]$Matches[1]
          $fails   = [int]$Matches[2]
          $astFail = [int]$Matches[3]
          if ($txt -match "SIMULATION PASSED")      { $verdict = "PASSED" }
          elseif ($txt -match "SIMULATION FAILED")  { $verdict = "FAILED" }
          else                                      { $verdict = "NO_VERDICT" }
        } else {
          $verdict = "PARSE_ERROR"
          $note    = "统计字段解析失败"
        }
        # 已发起但未比对的残缺报告（检查项为 0）同样不可作为通过依据
        if ($verdict -eq "PASSED" -and $checked -le 0) {
          $verdict = "EMPTY_STATS"
          $note    = "报告无有效检查项"
        }
      }
    }

    if (-not $launchOk) {
      $verdict = "RUN_ERROR"; $note = "子进程启动失败"
    } elseif ($timedOut) {
      $verdict = "TIMEOUT"; $note = "子进程超时"
    } elseif ($null -ne $runExit -and $runExit -ne 0) {
      if ($verdict -eq "PASSED") { $note = "报告通过但子进程退出码非 0" }
      $verdict = "RUN_ERROR"
    } elseif ($null -eq $runExit) {
      $note = "子进程退出码不可得，结论仅依据报告"
    }

    $isPass = ($verdict -eq "PASSED" -and $checked -gt 0 -and $fails -eq 0 -and $astFail -eq 0)

    $rows += [pscustomobject]@{
      Seed     = $s
      Exit     = $(if ($null -eq $runExit) { "n/a" } else { $runExit })
      Checks   = $checked
      Failures = $fails
      AssertErr= $astFail
      Verdict  = $verdict
      Note     = $note
    }
    if ($isPass) { $nPass++ } else { $nFail++; $failSeeds += $s }
  }
}
catch {
  # 循环中若出现终止性错误（脚本级异常），记录后仍走完汇总流程：
  # 这样既留下证据，也由「轮次数不符」把整体判为失败，而不是直接中断、无总结无结论
  $loopError = $_
}
finally {
  # 无论成败都恢复调用者的工作目录
  Set-Location -LiteralPath $prevLoc -ErrorAction SilentlyContinue
}

# ------------------------------ 汇总输出 ------------------------------
$totalChecks = 0
foreach ($r in $rows) { $totalChecks += [int]$r.Checks }

# 轮次数必须与请求的种子数一致：不一致说明循环中途异常退出，
# 此时残留的通过计数不能作为成功依据，整体一律判失败
$roundsExpected = $seedList.Count
$roundsRun      = $rows.Count
$aborted        = ($roundsRun -ne $roundsExpected)
$overallFailed  = ($aborted -or $nFail -gt 0)

$summary = @()
$summary += "# VRF_AXI4L 批量回归汇总"
$summary += "# 测试用例 : $Test"
$summary += "# 输出目录 : $regDir"
$summary += "# 回归轮次 : $roundsRun / $roundsExpected"
$summary += "# 随机种子 : $($seedList -join ', ')"
$summary += "# 单轮超时 : $(if ($TimeoutSec -gt 0) { "$TimeoutSec 秒" } else { '未启用' })"
$summary += "# 通过轮次 : $nPass"
$summary += "# 失败轮次 : $nFail"
$summary += "# 累计检查项 : $totalChecks"
if ($aborted) {
  $summary += "# ---------------------------------------------------------------"
  $summary += "# 异常 : 实际执行 $roundsRun 轮，少于请求的 $roundsExpected 轮（回归被中断），结论判失败"
}
if ($loopError) {
  $summary += "# 异常 : 回归循环异常中断（$($loopError.Exception.Message)）"
}
$summary += "# ---------------------------------------------------------------"
$summary += ("{0,-8} {1,-6} {2,-10} {3,-10} {4,-11} {5,-12} {6}" -f "Seed","Exit","Checks","Failures","AssertErr","Verdict","Note")
foreach ($r in $rows) {
  $summary += ("{0,-8} {1,-6} {2,-10} {3,-10} {4,-11} {5,-12} {6}" -f `
               $r.Seed, $r.Exit, $r.Checks, $r.Failures, $r.AssertErr, $r.Verdict, $r.Note)
}
if ($failSeeds.Count -gt 0) {
  $summary += "# ---------------------------------------------------------------"
  $summary += "# 失败种子（可用 run.ps1 -Seed <n> 复现）: $($failSeeds -join ', ')"
}
$summary += "# ---------------------------------------------------------------"
$summary += "# 结论 : $(if ($overallFailed) { 'REGRESSION FAILED' } else { 'REGRESSION PASSED' })"

$summary | Set-Content -Encoding UTF8 -LiteralPath $summaryFile

Write-Host ""
$summary | ForEach-Object { Write-Host $_ }
Write-Host "[VRF_AXIL] 汇总文件 : $summaryFile"

exit $(if ($overallFailed) { 1 } else { 0 })
