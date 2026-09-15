<#
  VRF_AXI4L 环境与前置条件检查

  用法：
    powershell -File bench/scripts/check_env.ps1
    powershell -File bench/scripts/check_env.ps1 -LogDir log

  检查项：
    1) PowerShell 版本
    2) ModelSim 工具链（vlib / vlog / vsim，vcover 可选）
    3) 工程文件与脚本是否齐备
    4) 目录可写（日志目录 + 项目根目录，后者用于创建工作库）
  任一项失败即以非 0 退出，并打印明确的失败原因。
#>
param(
  [string] $LogDir = "log"
)

$ErrorActionPreference = "Continue"

$fail = 0
function Report([string]$level, [string]$msg) {
  $tag = switch ($level) { "OK" { "[ OK ]" } "WARN" { "[WARN]" } default { "[FAIL]" } }
  Write-Host "$tag $msg"
}

Write-Host "================ VRF_AXIL 前置条件检查 ================"

# ------------------------------ 1) PowerShell ------------------------------
if ($PSVersionTable.PSVersion.Major -ge 5) {
  # PSEdition 在 PowerShell 5.0 上不存在，直接取会打印空括号
  $edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
  Report "OK" "PowerShell $($PSVersionTable.PSVersion) ($edition)"
} else {
  Report "FAIL" "PowerShell 版本过低（$($PSVersionTable.PSVersion)），需要 5.0 及以上"
  $fail++
}

# ------------------------------ 2) 仿真工具链 ------------------------------
$tools = @(
  @{ Name = "vlib";  Required = $true  },
  @{ Name = "vlog";  Required = $true  },
  @{ Name = "vsim";  Required = $true  },
  @{ Name = "vcover"; Required = $false }
)
foreach ($t in $tools) {
  $c = Get-Command $t.Name -ErrorAction SilentlyContinue
  if ($c) {
    Report "OK" "$($t.Name) => $($c.Source)"
  } elseif ($t.Required) {
    Report "FAIL" "未找到 $($t.Name)（请确认 ModelSim 环境变量/PATH）"
    $fail++
  } else {
    Report "WARN" "未找到 $($t.Name)（仅查看覆盖率明细时需要，不影响仿真）"
  }
}

# ------------------------------ 3) 工程文件 ------------------------------
$root = $null
try { $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..") -ErrorAction Stop).Path } catch { $root = $null }
if (-not $root) {
  Report "FAIL" "无法定位项目根目录"
  exit 1
}
Report "OK" "项目根目录 => $root"

$requiredFiles = @(
  "RTL/DVP2axi_stream.v",
  "bench/scripts/filelist.f",
  "bench/scripts/run.ps1",
  "bench/scripts/regression.ps1",
  "bench/scripts/check_env.ps1",
  "bench/scripts/sim.do",
  "bench/lib/IF/vrf_axil_if.sv",
  "bench/lib/Pkg/vrf_axil_pkg.sv",
  "bench/lib/Slv/vrf_axil_slave.sv",
  "bench/lib/Chk/vrf_axil_chk.sv",
  "bench/tb/tb_vrf_axil_demo.sv",
  "bench/tb/tb_dvp2ax_stream.sv"
)
foreach ($f in $requiredFiles) {
  $p = Join-Path $root $f
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Report "OK" "存在 $f"
  } else {
    Report "FAIL" "缺少文件 $f"
    $fail++
  }
}

# ------------------------------ 4) 目录可写 ------------------------------
# run.ps1 会写日志目录，也会在项目根目录创建/删除 ModelSim 工作库（vlib work_demo、work_dvp2axi）
# 并清理 _lock，因此两处都必须可写，否则前置检查「通过」后每个用例仍会以退出码 3 失败
if ([string]::IsNullOrWhiteSpace($LogDir) -or $LogDir -match '[{}"]' -or $LogDir -match '[\r\n]') {
  Report "FAIL" "-LogDir 不能为空，且不能包含花括号 { }、双引号或换行（会被拼入 ModelSim do 字符串）"
  $fail++
} else {
  # -LogDir 既可能是相对项目根目录的路径，也可能是绝对路径（如 make check OUT=D:\logs）
  $logPath = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $root $LogDir }
  $probes = @(
    @{ Name = "日志目录";   Path = $logPath },
    @{ Name = "项目根目录"; Path = $root }
  )
  foreach ($p in $probes) {
    # 探针文件按进程号命名，避免并发检查互相踩踏；无论成败都确保清理，不在源码树里留残留
    $probe = Join-Path $p.Path ".vrf_axil_write_probe_$PID"
    try {
      # 用 .NET 的 CreateDirectory 按字面路径创建（New-Item 的 -Path 会解析通配字符，
      # 而 New-Item 没有 -LiteralPath），避免 log[1] 之类取值被解析成别的目录
      [System.IO.Directory]::CreateDirectory($p.Path) | Out-Null
      "probe" | Set-Content -LiteralPath $probe -ErrorAction Stop
      Remove-Item -Force -LiteralPath $probe -ErrorAction SilentlyContinue
      Report "OK" "$($p.Name)可写 => $($p.Path)"
    } catch {
      Remove-Item -Force -LiteralPath $probe -ErrorAction SilentlyContinue
      Report "FAIL" "$($p.Name)不可写 => $($p.Path)（$($_.Exception.Message)）"
      $fail++
    }
  }
}

Write-Host "======================================================"
if ($fail -eq 0) {
  Write-Host "[VRF_AXIL] 前置条件检查通过。"
  exit 0
} else {
  Write-Host "[VRF_AXIL] 前置条件检查失败：$fail 项未通过。"
  exit 1
}
