<#
  VRF_AXI4L 一键编译与仿真脚本（ModelSim）

  用法：
    powershell -File bench/scripts/run.ps1 -Test tb_vrf_axil_demo
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Seed 12345
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Cover
    powershell -File bench/scripts/run.ps1 -Test tb_dvp2ax_stream -Clean

  说明：
    - 库自测 demo 与 DVP2axi_stream 接入示例的 bind 目标不同，
      脚本按 -Test 自动选择编译模式（VRF_AXIL_BIND_REF / VRF_AXIL_BIND_DVP2AXI），
      并为每个用例使用独立工作库（work_demo / work_dvp2axi），
      避免不同 -define 编译出的同名单元互相覆盖。
    - 仿真日志与报告输出到 -LogDir（默认 log/）。
      -LogDir 只拒绝会破坏 Tcl 花括号引用或子进程参数引用的字符（{ }、双引号、换行），
      允许含空格的路径（工程位于 "C:\Users\John Doe\..." 这类目录时依然可用）。
    - 只按显式传参决定是否下发 +seed/+n_rand，因此 -Seed 0、-Nrand 0 均为有效取值。
    - 退出码同时写入 <LogDir>/<Test>.exit，供回归脚本稳定读取
      （PowerShell 的 Start-Process -PassThru 取 ExitCode 不可靠）。
    - 工作库固定在项目根目录（work_demo / work_dvp2axi）。为避免并发运行同一用例时
      互相覆盖库、互删库锁，脚本在**工程根目录**写一个占用标记（记录 PID）并与工作库同名对应：
      标记对应进程仍在运行时**直接以退出码 3 拒绝**，进程已结束的陈旧标记会被接管；
      抢占使用原子创建（CreateNew），避免两个进程同时通过检查。
      标记放在根目录（而非库内）是为了不提前创建库目录——库目录必须由 vlib 创建。
    - -Clean 只删除本脚本创建的工作库（work / work_demo / work_dvp2axi），
      且会先确认这三个库都没有被其他存活运行占用，不动其他目录。
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

# 工作库所有权标记：登记后由 Exit-With 负责释放
$script:ownerTag = $null

# 统一退出路径：先释放工作库所有权，再落盘退出码，最后退出
function Exit-With([int]$code) {
  try {
    if ($script:ownerTag) { Remove-Item -Force -LiteralPath $script:ownerTag -ErrorAction SilentlyContinue }
  } catch { }
  try {
    if ($LogDir -and (Test-Path -LiteralPath $LogDir -PathType Container)) {
      Set-Content -LiteralPath (Join-Path $LogDir "$Test.exit") -Value $code -Encoding ASCII -ErrorAction SilentlyContinue
    }
  } catch { }
  exit $code
}

# ------------------------------ 定位并校验项目根目录 ------------------------------
# 任何递归删除/写入之前必须确认工作目录正确，避免在错误目录下误删
$root = $null
try { $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..") -ErrorAction Stop).Path } catch { $root = $null }
if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
  Write-Host "[VRF_AXIL] 无法定位项目根目录，终止。"
  Exit-With 2
}
Set-Location -LiteralPath $root
if ($PWD.Path -ne $root) {
  Write-Host "[VRF_AXIL] 切换工作目录失败（当前 $($PWD.Path)），终止。"
  Exit-With 2
}
if (-not (Test-Path -LiteralPath "bench/scripts/filelist.f" -PathType Leaf)) {
  Write-Host "[VRF_AXIL] 未找到 bench/scripts/filelist.f，终止。"
  Exit-With 2
}

# ------------------------------ 参数校验 ------------------------------
# $LogDir 会被拼进 ModelSim 的 do 字符串；其中只有覆盖率保存路径使用「花括号引用」，
# 花括号内的 Tcl 不做变量/命令替换，因此空白、分号都是安全的，
# 少数会破坏它的字符必须拒绝：
#   { }  — 提前结束花括号组，其余内容会被当作 Tcl 命令解析
#   "    — 调用方（如 regression.ps1）会把它作为参数传给子进程，会破坏参数引用
#   换行 — 会把一条 do 命令拆成多条
# 放行空白是为了支持工程位于含空格的目录（如 C:\Users\John Doe\...）。
if ([string]::IsNullOrWhiteSpace($LogDir) -or $LogDir -match '[{}"]' -or $LogDir -match '[\r\n]') {
  Write-Host "[VRF_AXIL] -LogDir 不能为空，且不能包含花括号 { }、双引号或换行，终止。"
  Exit-With 2
}
if ($Nrand -lt 0) {
  Write-Host "[VRF_AXIL] -Nrand 不能为负数，终止。"
  Exit-With 2
}
# 用例按无符号种子解释，负值会回绕成很大的数，报告里的种子将无法再用来复现
if ($Seed -lt 0) {
  Write-Host "[VRF_AXIL] -Seed 不能为负数，终止。"
  Exit-With 2
}

# 只有显式传参才下发对应 plusarg（0 亦是有效值）
$seedGiven  = $PSBoundParameters.ContainsKey('Seed')
$nrandGiven = $PSBoundParameters.ContainsKey('Nrand')

# ------------------------------ 按测试选择 bind 目标与独立工作库 ------------------------------
switch ($Test) {
  "tb_vrf_axil_demo" { $bindDef = "+define+VRF_AXIL_BIND_REF";     $libName = "work_demo" }
  "tb_dvp2ax_stream" { $bindDef = "+define+VRF_AXIL_BIND_DVP2AXI"; $libName = "work_dvp2axi" }
}

# ------------------------------ 仿真工具可用性 ------------------------------
# 逐项确认命令存在：命令缺失在 PowerShell 中是非终止错误且不会刷新 $LASTEXITCODE，
# 会把上一条命令遗留的 0 误判为成功，从而在过期的库上继续 elaboration
foreach ($tool in @("vlib", "vlog", "vsim")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Host "[VRF_AXIL] 未找到 $tool，请确认 ModelSim 环境变量/路径，终止。"
    Exit-With 5
  }
}

# ------------------------------ 工作库所有权与目录准备 ------------------------------
$libDir   = Join-Path $root $libName
# 占用标记放在工程根目录，而不是工作库内：
#   1) 不污染 ModelSim 工作库目录；
#   2) 更重要的是不必为了写标记而提前创建库目录——库目录必须由 vlib 创建，
#      提前建出空目录会让后面的 vlib 判定失效、库未被初始化。
$ownerTag = Join-Path $root ".vrf_axil_owner_$libName"
$allLibs  = @("work", "work_demo", "work_dvp2axi")

# 读取某工作库的占用者 PID：无标记 / 标记不可解析 / 进程已退出 / 就是本进程，都算「无占用」
function Get-LibOwner([string]$lib) {
  $tag = Join-Path $root ".vrf_axil_owner_$lib"
  if (-not (Test-Path -LiteralPath $tag -PathType Leaf)) { return 0 }
  $txt = $null
  try { $txt = Get-Content -LiteralPath $tag -Raw -ErrorAction Stop } catch { return 0 }
  $n = 0
  if ($null -eq $txt -or -not [int]::TryParse($txt.Trim(), [ref]$n)) { return 0 }
  if ($n -le 0 -or $n -eq $PID) { return 0 }
  if (Get-Process -Id $n -ErrorAction SilentlyContinue) { return $n }
  return 0
}

# 原子抢占标记：CreateNew 语义保证同一时刻只有一个进程能创建成功
function New-LibOwnerTag([string]$tag) {
  try {
    $fs = [System.IO.File]::Open($tag,
                                 [System.IO.FileMode]::CreateNew,
                                 [System.IO.FileAccess]::Write,
                                 [System.IO.FileShare]::None)
    try {
      $bytes = [System.Text.Encoding]::ASCII.GetBytes("$PID")
      $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    return $true
  } catch { return $false }
}

# -Clean 会删除全部三个工作库，因此必须先确认它们都没有被其他存活运行占用
if ($Clean) {
  foreach ($lib in $allLibs) {
    $other = Get-LibOwner $lib
    if ($other -gt 0) {
      Write-Host "[VRF_AXIL] 工作库 $lib 正被进程 $other 使用，-Clean 会破坏该运行，终止。"
      Exit-With 3
    }
    Remove-Item -Recurse -Force -LiteralPath (Join-Path $root $lib) -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath (Join-Path $root ".vrf_axil_owner_$lib") -ErrorAction SilentlyContinue
  }
}

# 抢占本用例工作库：同一用例并发运行会互相覆盖库、互删库锁，因此显式拒绝后者
if (-not (New-LibOwnerTag $ownerTag)) {
  $other = Get-LibOwner $libName
  if ($other -gt 0) {
    Write-Host "[VRF_AXIL] 工作库 $libName 正被进程 $other 使用（同一用例不能并发运行），终止。"
    Exit-With 3
  }
  # 陈旧标记：删除后重抢一次（仍是原子创建，只有一个进程能成功）
  Remove-Item -Force -LiteralPath $ownerTag -ErrorAction SilentlyContinue
  if (-not (New-LibOwnerTag $ownerTag)) {
    Write-Host "[VRF_AXIL] 工作库 $libName 的占用标记被其他运行抢占，终止。"
    Exit-With 3
  }
}
$script:ownerTag = $ownerTag

# 清理本用例工作库的残留锁（上一次异常退出可能遗留；只处理本库，不动其他库）
Remove-Item -Recurse -Force -LiteralPath (Join-Path $libDir "_lock") -ErrorAction SilentlyContinue

# 建日志目录：New-Item 的 -Path 会把通配字符当模式解析（New-Item 没有 -LiteralPath），
# 因此用 .NET 的 CreateDirectory，按字面路径创建，且已存在时为空操作
$logPath = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $root $LogDir }
[System.IO.Directory]::CreateDirectory($logPath) | Out-Null
if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
  Write-Host "[VRF_AXIL] 无法创建日志目录 $LogDir，终止。"
  Exit-With 3
}

# ------------------------------ 编译 ------------------------------
# 工作库按用例创建，创建失败即终止（不吞退出码）。
# 判定依据是 vlib 生成的库标记文件 <lib>/_info，而不是「目录是否存在」：
# 空目录不是有效 ModelSim 库，只有 vlib 初始化后 vlog -work 才能使用。
# 调用顺序上，库目录由 vlib 创建（本脚本不会提前建库目录，占用标记放在工程根目录）。
if (-not (Test-Path -LiteralPath (Join-Path $libDir "_info") -PathType Leaf)) {
  vlib $libName | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[VRF_AXIL] 创建库 $libName 失败（exit=$LASTEXITCODE），终止。"
    Exit-With 3
  }
}

# -cuname：显式为多文件编译单元命名，保证编译单元作用域的 bind 一定参与 elaboration
$vlogArgs = @("-mfcu", "-cuname", "${Test}_cu", "-sv", "-work", $libName, $bindDef)
if ($Cover) { $vlogArgs += @("-cover", "bcesft") }
$vlogArgs += @("-f", "bench/scripts/filelist.f")

Write-Host "[VRF_AXIL] 编译 : $Test  ($bindDef, lib=$libName)"
vlog @vlogArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host "[VRF_AXIL] 编译失败（exit=$LASTEXITCODE），终止。"
  Exit-With 4
}

# ------------------------------ 仿真 ------------------------------
# 路径用 Tcl 花括号引用，避免路径中的特殊字符被 Tcl 解析
$doCmd = "run -all; quit -f"
if ($Cover) { $doCmd = "coverage save -onexit {$LogDir/$Test.ucdb}; run -all; quit -f" }

$vsimArgs = @("-c", "-do", $doCmd, "-l", "$LogDir/$Test.log", "$libName.$Test")
if ($Cover)      { $vsimArgs += "-coverage" }
if ($seedGiven)  { $vsimArgs += "+seed=$Seed" }
if ($nrandGiven) { $vsimArgs += "+n_rand=$Nrand" }
if ($Fault)      { $vsimArgs += "+fault_inject=1" }
$vsimArgs += "+log_dir=$LogDir"

Write-Host "[VRF_AXIL] 仿真 : $Test  seed=$(if ($seedGiven) { $Seed } else { '(随机)' })"
vsim @vsimArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host "[VRF_AXIL] 仿真失败（exit=$LASTEXITCODE），详见 $LogDir/$Test.log"
  Exit-With $LASTEXITCODE
}

# ------------------------------ 汇总 ------------------------------
$reportFile = "$LogDir/$Test`_report.txt"
if (Test-Path -LiteralPath $reportFile -PathType Leaf) {
  Write-Host "[VRF_AXIL] 报告 : $reportFile"
} else {
  Write-Host "[VRF_AXIL] 警告：未生成报告 $reportFile，请检查 $LogDir/$Test.log"
  Exit-With 6
}
Exit-With 0
