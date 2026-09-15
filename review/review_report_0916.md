─── bench/scripts/run.ps1:33-33 ───
[bug · high] Destructive cleanup runs unconditionally right after `Set-Location`. With
`$ErrorActionPreference = "Continue"`, if `Resolve-Path` returns `$null` or `Set-Location $root`
fails (e.g. `$PSScriptRoot` resolution issue, ACL/permission error), execution falls through and
`Remove-Item -Recurse -Force` then deletes `work\_lock` (and `work` under `-Clean`) in whatever the
*current* directory happens to be. Validate `$root` and the working directory before performing any
recursive delete.

+ if (-not $root -or -not (Test-Path -LiteralPath $root)) {
+   Write-Host "[VRF_AXIL] 无法定位项目根目录，终止。"
+   exit 1
+ }
+ Set-Location -LiteralPath $root
+ if ($PWD.Path -ne $root) {
+   Write-Host "[VRF_AXIL] 切换工作目录失败，终止。"
+   exit 1
+ }
+
  Remove-Item -Recurse -Force work\_lock -ErrorAction SilentlyContinue


─── bench/scripts/run.ps1:36-36 ───
[bug · medium] `vlib` is piped to `Out-Null` and its exit code is never checked. If `vlib` is
missing from PATH or the `work` directory is not writable, the failure is silently swallowed and the
script proceeds to `vlog`, producing a confusing compile error (or, worse, compiling into a stale
library). Check `$LASTEXITCODE` right after `vlib` (and keep the `New-Item` for `$LogDir` guarded as
well).

- if (!(Test-Path work)) { vlib work | Out-Null }
+ if (!(Test-Path work)) {
+   vlib work | Out-Null
+   if ($LASTEXITCODE -ne 0) {
+     Write-Host "[VRF_AXIL] 创建库 work 失败（exit=$LASTEXITCODE），终止。"
+     exit 1
+   }
+ }


─── bench/scripts/run.ps1:59-59 ───
[security · medium] `$LogDir` is interpolated verbatim into the ModelSim `do` string, which is
parsed as Tcl. A `$LogDir` containing spaces (e.g. `-LogDir "my logs"`) breaks the `coverage save`
path, and characters such as `;` or `"` will inject additional Tcl commands into the vsim session.
Validate/quote `$LogDir` (reject `;`, quotes, whitespace, or wrap the path in Tcl braces) before
building `$doCmd`.

- if ($Cover) { $doCmd = "coverage save -onexit $LogDir/$Test.ucdb; run -all; quit -f" }
+ if ($LogDir -match '[;\"\s]') {
+   Write-Host "[VRF_AXIL] -LogDir 不能包含空白、分号或引号，终止。"
+   exit 1
+ }
+ if ($Cover) { $doCmd = "coverage save -onexit {$LogDir/$Test.ucdb}; run -all; quit -f" }


─── bench/scripts/run.ps1:69-69 ───
[bug · high] The result of `vsim` is never validated. If `vsim` cannot be launched (not on PATH),
PowerShell only reports a CommandNotFound error and `$LASTEXITCODE` keeps its previous value (0 from
the successful `vlog`), so the final `exit $LASTEXITCODE` reports success even though no simulation
ran. A failed simulation is also not surfaced to the user. Explicitly check the exit code after
`vsim` before summarizing.

  vsim @vsimArgs
+ if ($LASTEXITCODE -ne 0) {
+   Write-Host "[VRF_AXIL] 仿真失败（exit=$LASTEXITCODE），详见 $LogDir/$Test.log"
+   exit $LASTEXITCODE
+ }


─── bench/scripts/run.ps1:63-64 ───
[maintainability · low] Using the sentinel value 0 for `$Seed` means `-Seed 0` is indistinguishable
from "no seed supplied": both omit the `+seed` plusarg, so a run with seed 0 cannot be reproduced
deterministically. Likewise `-Nrand 0` (and any negative value) is silently discarded. Consider a
nullable `$Seed = $null` default (or an explicit `-NoSeed` switch) so that a genuine seed of 0 is
forwarded, and validate `$Nrand` rather than ignoring non-positive input.

- if ($Seed -ne 0)   { $vsimArgs += "+seed=$Seed" }
+ if ($null -ne $Seed) { $vsimArgs += "+seed=$Seed" }
+ if ($Nrand -lt 0) {
+   Write-Host "[VRF_AXIL] -Nrand 不能为负数，终止。"
+   exit 1
+ }
  if ($Nrand -gt 0)  { $vsimArgs += "+n_rand=$Nrand" }


─── bench/scripts/regression.ps1:30-30 ───
[bug · medium] Seed parsing is unvalidated: `[int]$_.Trim()` throws an unhelpful conversion error
for empty/whitespace/non-numeric entries (e.g. `-Seeds ""`, `-Seeds "1,2,"`), and duplicates,
zero/negative values and an empty resulting list are not checked. An empty/failed parse yields an
empty `$seedList`, after which `$nFail` stays 0 and the script exits 0 printing `REGRESSION PASSED`
(and `$totalChecks` becomes `$null`). Validate the input, de-duplicate, and abort explicitly when no
valid seed is supplied.

- $seedList  = $Seeds -split ',' | ForEach-Object { [int]$_.Trim() }
+ $seedList  = @($Seeds -split ',' | ForEach-Object { $_.Trim() } |
+                Where-Object { $_ -ne '' } |
+                ForEach-Object {
+                  $n = 0
+                  if (![int]::TryParse($_, [ref]$n)) { Write-Error "非法种子: '$_'"; exit 2 }
+                  $n
+                } | Sort-Object -Unique)
+ if ($seedList.Count -eq 0) { Write-Error '未提供有效种子，终止回归。'; exit 2 }


─── bench/scripts/regression.ps1:45-45 ───
[bug · high] The child run's exit status is never inspected: `& $runScript @runArgs | Out-Host`
discards `$LASTEXITCODE`/`$?`, and `$ErrorActionPreference = "Continue"` (line 22) swallows
non-terminating errors (e.g. a missing/broken run.ps1). A compile failure or crashed simulation
therefore collapses into `NO_REPORT` with no record of the real cause. Capture the exit code,
include it in the result row, and treat a non-zero exit as a failed round regardless of the parsed
report.

    & $runScript @runArgs | Out-Host
+   $runExit = $LASTEXITCODE
+   if ($runExit -ne 0) { Write-Warning "run.ps1 退出码 $runExit (seed=$s)" }


─── bench/scripts/regression.ps1:48-48 ───
[bug · high] The report path is not regenerated/cleaned per round. If a round aborts before the
testbench writes its report (compile error, crash, hung sim — see the unchecked exit code above), a
report left over from a previous run in the same `seed_<n>` directory is still present, so
`Test-Path` succeeds and the stale file is parsed and can be reported as PASSED — a silent false
green. Delete the expected report before invoking run.ps1 (or verify its `LastWriteTime` is newer
than the round start).

    $reportFile = "$rundir/$Test`_report.txt"
+   Remove-Item -Force $reportFile -ErrorAction SilentlyContinue
+   $roundStart = Get-Date


─── bench/scripts/regression.ps1:71-71 ───
[bug · medium] A round is accepted as passing whenever the verdict string is `PASSED`, even if the
statistics regex (line 55) failed to match — in that case `$checked` remains 0 while
`$fails`/`$astFail` are also 0, so a reformatted, truncated, or encoding-mangled report silently
counts as a pass. Require a successfully parsed, non-zero check count for a green round (and mark
the round as a parse error otherwise).

-   if ($verdict -eq "PASSED" -and $fails -eq 0 -and $astFail -eq 0) { $nPass++ }
+   if ($verdict -eq "PASSED" -and $checked -gt 0 -and $fails -eq 0 -and $astFail -eq 0) { $nPass++ }


─── bench/scripts/regression.ps1:24-24 ───
[maintainability · low] Global state handling is fragile: `Set-Location $root` permanently mutates
the caller's working directory (never restored, no try/finally), the fixed `log/regression` tree is
reused without cleanup or locking so concurrent runs can overwrite each other's reports, and the
loop waits synchronously on run.ps1 with no timeout, so one hung compile/simulation blocks the whole
regression indefinitely. Consider restoring the previous location, running each round under a
timeout/cancellable child process, and namespacing the output directory per invocation.



─── bench/abandoned/if_axil.sv:9-10 ───
[bug · high] `rst` is declared as an interface variable and listed as `input` in **all three**
modports (MASTER/SLAVE/MONITOR) of every channel. Because no modport exposes `rst` as an output, no
module connected through these modports can drive it — the reset must come from a hierarchical
reference, otherwise it stays at `X` (4-state `logic` with no initializer) and the whole bus is held
in reset/X. In addition, `rst` is deliberately outside every clocking block, so it is not sampled or
synchronized in any way; reset assertion/deassertion can race with the clocked handshake signals.
Please provide an explicit reset driver (e.g. a dedicated modport/`output rst` or an initializer)
and state whether reset is intended to be sampled in the clocking blocks.



─── bench/abandoned/if_axil.sv:11-11 ───
[bug · medium] The AW/AR ID (`axif_awport`/`axif_arport`) is hard-coded to 3 bits, while the R/B
channels parameterize their IDs with `IDWIDTH` (default 4). For the AXI write/read address IDs to be
consistent with the response IDs, these should use the same `IDWIDTH` parameter; as written,
selecting `IDWIDTH != 3` silently creates mismatched ID widths on the same bus and can cause
truncated/incorrect ID matching in the scoreboard. Consider adding an `IDWIDTH` parameter to
`if_axil_aw`/`if_axil_ar` and declaring `logic [IDWIDTH-1:0] axif_awport;`.



─── bench/abandoned/if_axil.sv:87-87 ───
[bug · medium] `DWIDTH/8` is integer division, so a data width that is not a multiple of 8 (or < 8)
silently truncates the write strobe instead of erroring: e.g. DW 12 yields a 1-bit wstrb while the
DUT names a byte-wide strobe, and the wildcard `.*` connection then mismatches widths with no
diagnostic. Guard it, e.g. add `localparam int STRBWIDTH = DW/8;` plus `initial if (DW % 8)
$fatal(1, "DW must be a byte multiple");`, or derive the strobe width from a single shared constant
used by both the interface and the hook.



─── bench/abandoned/if_axil.sv:13-14 ───
[bug · low] No `default input/output skew` is declared on the driving clocking blocks, so the LRM
defaults apply (`#1step` for inputs, `#0` for outputs). With the clocking blocks triggered on the
same `posedge clk` that the DUT samples, drives are applied in the same time step, so the
sampled-vs-driven relationship is implicit and tool-dependent; in `if_axil` this also creates a
systematic one-cycle sampling offset/race between master_cb and slave_cb. Declare explicit,
complementary skews so the intended drive/sample edge relationship is unambiguous rather than
tool-default dependent.



─── bench/abandoned/VRF_AXI4L_v0.sv:79-82 ───
[bug · high] The transaction is born with `txn_resp = OKAY` / `txn_result = PASS` (and
`post_randomize()` restores the same defaults). Because the monitor/scoreboard only *overwrites*
these fields, any transaction that is dropped, never sampled, or whose driver silently fails to
issue it stays PASS/OKAY and will be counted as a pass — a false-negative that hides real
DUT/topology bugs. Use a clearly "not yet evaluated" state instead (e.g. add a
`txn_checked`/`txn_valid` flag or a `UNINIT` value) and have the reporting stage treat an
un-back-filled transaction as an error.

-       txn_name   = name;
-       txn_resp   = OKAY;
-       txn_result = PASS;
-       txn_reason = "";
+       txn_name    = name;
+       txn_resp    = OKAY;
+       txn_result  = FAIL;      // 未回填前不得默认为 PASS
+       txn_reason  = "not evaluated";
+       txn_checked = 1'b0;      // 由 monitor/scoreboard 置位


─── bench/abandoned/VRF_AXI4L_v0.sv:108-111 ───
[bug · medium] `clone()` calls `new(txn_name)`, which increments the static `id_cnt`, but the
following `copy(this)` overwrites `txn_id` with the source ID. Result: every clone duplicates the
source `txn_id` (breaking the "ID for reproduction" contract) while burning a counter value, so IDs
are non-contiguous. Either assign a fresh ID to the clone (call `new()` and keep it), or stop
copying `txn_id` in `copy()`.

      virtual function this_type clone();
-       clone = new(txn_name);
+       clone = new(txn_name);   // 新对象已获得唯一 txn_id
        clone.copy(this);
+       clone.txn_id = this.txn_id; // 如需溯源到源事务，另用 src_id 字段，不要覆盖 txn_id
+       return clone;
      endfunction


─── bench/abandoned/VRF_AXI4L_v0.sv:54-54 ───
[maintainability · medium] `id_cnt` is never reset, so transaction IDs grow monotonically across
sequentially run tests and are not reproducible between simulation runs; moreover, for a
parameterized class each specialization (e.g. 32/64-bit) gets its own independent counter, so IDs
are not globally unique if more than one specialization is used. Consider an explicit reset/seed API
(e.g. `static function void reset_id_cnt()`) called at test start, and/or a globally unique ID
scheme (name + per-instance index).



─── bench/abandoned/VRF_AXI4L_v0.sv:70-74 ───
[bug · medium] `txn_data` is randomized completely independently of `txn_strb`, so bytes not
selected by `txn_strb` carry arbitrary values. If the checker compares the full data word (or the
reference model/scoreboard does not explicitly mask by `txn_strb`), this produces false mismatches
on randomly-strobed writes, or conversely masks real DUT errors when the mask is applied sloppily.
Either constrain the non-selected bytes to a known value (e.g. 0) or document/enforce masking in the
comparison.



─── bench/abandoned/VRF_AXI4L_v0.sv:63-65 ───
[maintainability · low] Forcing `txn_addr % STRBWIDTH == 0` removes all unaligned-address coverage;
AXI4-Lite explicitly permits unaligned addresses (byte lane steering on the data bus), and many DUT
bugs live exactly in the unaligned/narrow path. If the intent was only to keep `txn_strb` consistent
with the address, prefer a constraint tying `txn_strb` to the low address bits and keep a
distribution that still exercises unaligned accesses. Also note the modulo (rather than a bit-mask
on the low bits) is relatively expensive for the solver and only cheap here because `STRBWIDTH`
happens to be a power of two.



─── bench/abandoned/VRF_AXI4L_v0.sv:86-86 ───
[bug · medium] `post_randomize()` is not declared `virtual`. The class already exposes virtual hooks
(copy/clone) and is designed to be extended; a derived transaction class that redefines
`post_randomize()` will not have it invoked by `randomize()` because the call is not dispatched
virtually. Declare it `virtual function void post_randomize();` (same for any future
`pre_randomize()`).



─── bench/abandoned/if_axil_v0.sv:33-34 ───
[maintainability · low] `arstn` is declared/sampled only through the clocking block and is never
used by any logic: in `if_axil_v0` it is listed as a clocking-block input (sampled only at `posedge
aclk`, and the sampled value is dead), and in `vrf_axil_if` no logic uses it at all, so a
mid-simulation reset is not reflected on the driven outputs and the stated "reset input" contract is
not honoured. Sample reset from the raw interface port for reset logic and drop it from the clocking
blocks, apply the reset inside the interface (e.g. an `always_ff @(posedge aclk or negedge arstn)`
branch), or document explicitly that reset is owned by the driver.

    clocking cb @(posedge aclk);
-   input arstn;
+   // do not sample arstn here; use the asynchronous interface port directly


─── bench/abandoned/if_axil_v0.sv:40-40 ───
[maintainability · medium] `mst_if_axil`, `slv_if_axil`, and `mnt_if_axil` are three near-duplicated
copies of the same 21 signals with hand-mirrored clocking directions, and none of them declares a
`modport`. Directions are therefore only enforced when a component happens to use the clocking
block: any raw access to `slv_if_axil.wready` (etc.) compiles fine and can create an accidental
double-driver (X in simulation) that is silent until debug time. Consider one parameterized
interface plus `modport mst/slv/mnt` (and/or `default clocking cb`) so all three views share a
single source of truth and direction errors are caught at compile time.



─── bench/lib/Chk/vrf_axil_chk.sv:57-57 ───
[bug · high] AXI4-Lite AW and W are independent channels, but both the checker (`wr_inc = awvalid &&
awready && wvalid && wready`) and the slave reference model (`wr_task` waits for `awvalid && wvalid`
in the same cycle) require them to handshake simultaneously. Any legal master that splits the
address and data phases therefore never satisfies the condition: `wr_pend` never increments (then
underflows), false "B without request" failures fire while genuine errors are masked, and the slave
never raises awready/wready so the master hangs. Track AW-accepted and W-accepted separately
(aw_pend/w_pend or aw_done/w_done), latch awaddr on AW and wdata/wstrb on W, and only emit B once
both have completed.

-   assign wr_inc = awvalid && awready && wvalid && wready;
+   // AW/W 握手可发生在不同周期，必须分别累计
+   int  aw_pend = 0, w_pend = 0;
+   bit  aw_inc, w_inc;
+   assign aw_inc = awvalid && awready;
+   assign w_inc  = wvalid  && wready;


─── bench/lib/Chk/vrf_axil_chk.sv:68-68 ───
[bug · high] Unguarded decrement: `wr_pend`/`rd_pend` are decremented without a lower bound, so a
B/R response observed while the counter is 0 drives it negative. Once negative, the `wr_pend > 0` /
`rd_pend > 0` checks stay broken for several subsequent legal transactions (real violations are then
silently missed), and the assertion reports the wrong error. Saturate at 0 so a spurious response is
reported once, at the moment it occurs, without corrupting later checks.

-       else if (!wr_inc && wr_dec) wr_pend <= wr_pend - 1;
+       else if (!wr_inc && wr_dec) wr_pend <= (wr_pend > 0) ? wr_pend - 1 : 0;


─── bench/lib/Chk/vrf_axil_chk.sv:108-108 ───
[bug · medium] `p_no_xz` requires every payload signal (`awaddr`, `wdata`, `wstrb`, `bresp`, `bid`,
`araddr`, `rdata`, `rresp`, `rid`, ...) to be known on **every** cycle, including cycles where the
corresponding `valid` is deasserted. Legal AXI4-Lite implementations are free to leave the payload
undefined (or X from an uninitialized register) while idle, so this produces false failures. Keep
the unconditional X/Z check for the handshake/control signals only, and gate the payload checks by
the matching `valid`.

+     // 握手/控制信号任何时刻不得为 X/Z
      !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready,
+                  arvalid, arready, rvalid, rready})
+     // 载荷仅在对应 valid 有效时才要求已知
+     && (!awvalid || !$isunknown({awaddr, awport}))
+     && (!wvalid  || !$isunknown({wdata, wstrb}))
+     && (!bvalid  || !$isunknown({bresp, bid}))
+     && (!arvalid || !$isunknown({araddr, arport}))
+     && (!rvalid  || !$isunknown({rdata, rresp, rid}))


─── bench/lib/Chk/vrf_axil_chk.sv:213-213 ───
[bug · low] Off-by-one / misleading diagnostic in the timeout checks. `aw_stuck` (and the other
stuck counters) is a registered value updated on the same edge the property samples it, so the
property observes the count *before* the current cycle is added. Consequence: the assertion fires on
the (timeout_cycles+1)-th consecutive stalled cycle, and `$error` prints `aw_stuck` which is one
less than the real stall length. Either align the reported/compared value with the real stall count
(e.g. evaluate `aw_stuck + 1` or print `aw_stuck + 1`), or document that the effective threshold is
`timeout_cycles + 1` cycles so the semantics match the intent. The same applies to all five
`p_*_timeout` properties.



─── bench/lib/Chk/vrf_axil_chk.sv:48-48 ───
[bug · low] The `*_stuck` counters keep incrementing while `gating` is active (they are only cleared
by `!aresetn`), and nothing clears them when checks are re-enabled. A handshake that is stalled
while `bringup_active` is set or `checks_enable` is 0 therefore leaves a stale non-zero count, and
the very first sample after gating is released can report a false timeout (both the `$error` and the
fail count). Clear the stuck counters (and/or `wr_pend`/`rd_pend`) whenever `gating` is asserted, or
hold them at 0 while gated, so a resumed check starts from a known state.

    wire gating = vrf_axil_ctrl::bringup_active || !vrf_axil_ctrl::checks_enable;
+   // 挂起期间冻结/清零停滞计数，避免恢复检查后立刻误报超时
+   always @(posedge aclk or negedge aresetn) begin
+     if (!aresetn || gating) begin
+       aw_stuck <= 0; w_stuck <= 0; ar_stuck <= 0; b_stuck <= 0; r_stuck <= 0;
+     end
+   end


─── bench/lib/Slv/vrf_axil_slave.sv:204-209 ───
[bug · medium] rst_task and wr_task/rd_task are separate parallel processes that all write the same
clocking-block outputs (slv.cb.awready/wready/bvalid/arready/rvalid). Driving one clockvar from
multiple processes is a race with last-write-wins semantics and no ordering guarantee, so the reset
clear performed here can be lost against a concurrent assignment in wr_task/rd_task. Moreover,
wr_task/rd_task only test aresetn at the top of their loops: a reset asserted during `repeat (d)
@(slv.cb)` (or during the B/R response waits) does not abort the in-flight transaction, so after
reset the tasks can still raise awready/wready/arready and even assert bvalid/rvalid for a request
that never existed, which contradicts the stated intent of releasing all drivers during reset.
Either have the wr/rd tasks re-check aresetn before every drive and abandon the transaction, or
drive the outputs from a single process.



─── bench/lib/Slv/vrf_axil_slave.sv:85-86 ───
[bug · medium] The DWIDTH parameter is not honoured by the data path: `store` and `rd_cap` are
hard-coded `logic [31:0]` while `rdata` is `[DWIDTH-1:0]`, so any instantiation with DWIDTH != 32
silently truncates (DWIDTH>32) or leaves rd_cap wider than the bus (DWIDTH<32); the reset statement
`rd_cap <= {DWIDTH{1'b0}};` is likewise a width mismatch against the 32-bit declaration. In the same
way `do_write(input logic [3:0] strb)` hard-codes a 4-bit strobe even though `wstrb` is
`[DWIDTH/8-1:0]` and STRBWIDTH was already computed for that purpose, so the upper bytes of a wide
strobe are dropped. Derive all of these widths from DWIDTH, or add an elaboration-time assertion
that DWIDTH == 32.

-   logic [31:0] store[int unsigned];
-   logic [31:0] rd_cap;          // 读采样值：在 AR 握手拍锁存
+   // 数据通路宽度应与 DWIDTH 一致（或断言 DWIDTH == 32）
+   logic [DWIDTH-1:0] store[int unsigned];
+   logic [DWIDTH-1:0] rd_cap;          // 读采样值：在 AR 握手拍锁存


─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · high] Tautological response check on both the write and read paths: `b_resp`/`r_resp` are
initialized from `p.resp` (the value the slave itself drives) and never re-sampled from
`vif_slv_axil_wb.bresp` / `vif_slv_axil_dr.rresp`, so `b_resp != p.resp_expect` / `r_resp !=
p.resp_expect` degenerates into `p.resp != p.resp_expect` — a comparison of two testbench constants
— and a wrong DUT response is never detected. Declare the local without an initializer and capture
the real bus value during the handshake (e.g. `b_resp = vif_slv_axil_wb.bresp;` in the `wait (bvalid
&& bready)` block before deasserting bvalid, and `r_resp = vif_slv_axil_dr.rresp;` when rvalid &&
rready).

-       axil_resp_e b_resp = p.resp;
+       axil_resp_e b_resp;


─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · high] Thread-cleanup hazard on both the write and read paths: when the `timeout_monitor`
branch wins `join_any`, `disable slv_write_respond_fork` / `disable slv_read_respond_fork` kills the
aw/dw/wb (ar/r) threads before their deassert statements execute, leaving
`awready`/`wready`/`bvalid` (or `arready`/`rvalid`) stuck high. The leaked ready/valid can then
handshake a later transaction prematurely and corrupt subsequent results. Explicitly drive all slave
outputs inactive before disabling the fork (a `final`/`always` cleanup or the sequence below).

+       vif_slv_axil_aw.awready <= 1'b0;
+       vif_slv_axil_dw.wready  <= 1'b0;
+       vif_slv_axil_wb.bvalid  <= 1'b0;
        disable slv_write_respond_fork; //事务完成或超时，回收所有线程


─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · medium] `dly_lo`/`dly_hi` default to 0, so in random mode (default state, before any directed
configuration) every delay constraint reduces to `inside {[0:0]}` and all AW/W/AR/R delays are
forced to zero — random mode silently cannot exercise delay. Give them sensible non-zero defaults
(e.g. `int dly_lo = 0; int dly_hi = 10;`) and note that if a user sets `dly_lo > dly_hi` the
constraint becomes unsatisfiable (the `randomize()` call elsewhere is not checked in this file).



─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · medium] Off-by-one in the legality check: the timeout monitor waits exactly
`max_timeout_cycle` clocking-block cycles, so a directed delay equal to `max_timeout_cycle` asserts
the slave ready in the same cycle the timeout fires — a guaranteed race/always-TIMEOUT. The
constraint side uses the stricter `aw_dly < max_timeout_cycle`, so the check should also be `>=`
(negative delays are likewise accepted). The identical check in `axil_mst_param::set_directed` needs
the same fix.

-       if(aw_dly_dir > max_timeout_cycle || w_dly_dir > max_timeout_cycle ||
+       if(aw_dly_dir >= max_timeout_cycle || w_dly_dir >= max_timeout_cycle ||


─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · medium] Uninitialized locals produce X / non-deterministic results: `rcv_addr`/`rcv_data`
have no default and are only assigned in the aw_rcv/dw_rcv branches, so on the timeout path
`result.txn_addr = rcv_addr;` (and the data assignment) latch X before the `txn_result == TIMEOUT`
early return; likewise `wb_result` (and `r_result`) is uninitialized and only assigned inside the
wb_test/r_test branch, so if that branch is killed by `disable` the later `wb_result !=
p.resp_expect` comparison evaluates X. Initialize the locals to a defined sentinel and/or only
compare when the response branch (not the timeout monitor) set them.



─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · medium] `txn_result_e` hard-codes 32/128/16-bit fields while all drivers are parameterized on
`ADDR_W`/`DATA_W`. Any instantiation other than ADDR_W=32 / DATA_W=128 silently truncates
(`result.txn_addr = p.addr;`) or zero-extends the recorded address/data/strb, so PASS/FAIL records
and any scoreboard using them are wrong. Make the struct generic (e.g. `typedef struct #(int
ADDR_W=32, int DATA_W=128)` / `logic [ADDR_W-1:0] txn_addr;`) or assert the parameter values.



─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · high] Infinite zero-time loop: `receive()` has an empty body (`task receive(txn_result_e
drv_txn_result); endtask`), so this `forever` never consumes simulation time and will hang the
simulator as soon as `run()` is started. It must block on the monitor clocking block (e.g.
`@(vif_mnt_axil_aw.mnt_cb);`) or on an event before each iteration. Additionally, `receive` takes
its argument by value (implicit `input`), so even when implemented it can never return a transaction
to `run()` — declare it `output`/`ref`.



─── bench/abandoned/AXI4-Lite.sv:0-0 ───
[bug · low] `result.txn_strb` is never assigned on read transactions (here and in
`slv_read_respond`), so callers that log or compare the full `txn_result_e` see an X on every read.
Assign a defined value (e.g. `result.txn_strb = '0;`) or clear the struct at task entry.



─── bench/lib/IF/vrf_axil_if.sv:278-278 ───
[bug · medium] The hook publishes the interface handles into `static` class members without any
clearing or conflict check, so the scheme is "last writer wins". If two fixtures are elaborated with
the same `(AW, DW, ID)` specialization in one simulation (both `tb_vrf_axil_demo.sv` and
`tb_dvp2ax_stream.sv` use 32/32/4), the two `initial` blocks race at time 0 and the
environment/driver/monitor silently bind to whichever fixture executed last — deterministic only by
accident of tool elaboration order. Stale handles also survive across tests because nothing clears
them. Recommend clearing/validating before publishing, e.g. report an error when `published` is
already set, or key the table by instance so each fixture keeps its own handles.



─── bench/lib/IF/vrf_axil_if.sv:69-70 ───
[bug · medium] These variables (`awvalid`, `awaddr`, `awport`, `wvalid`, `wdata`, `wstrb`, `bready`,
`arvalid`, `araddr`, `arport`, `rready`) are exactly the signals declared as clocking-block
*outputs* of `cb`, and the driver does drive them through `mst_vif.cb.*` (see
`vrf_axil_driver.svh`). Mixing a direct power-on `initial` write with clocking-block drives means
the same variable has two procedural drivers: simulators flag this as multiple drivers, and any
future direct write to these signals (e.g. a bring-up stimulus or an added reset branch) will race
with the clocking-block update instead of being observed deterministically. Keep a single writer —
initialize through the clocking block, or reset the signals asynchronously from `arstn` and drop the
clocking-block outputs for these signals. The identical pattern exists in `vrf_axil_slv_if`
(`awready/wready/bvalid/bid/bresp/arready/rvalid/rdata/rresp/rid`).



─── bench/lib/IF/vrf_axil_if.sv:0-0 ───
[maintainability · medium] The fixture drives interface `logic` variables through module-scope
continuous assignments (the reverse direction of the same pattern). It works only because the hook
is expanded exactly once and nothing else drives those members: a variable may have only one
continuous driver, and continuous + procedural writes to the same variable resolve to X. Any second
hook expansion, or an interface-side `initial`/`always` that also touches `awready/rvalid/...`, will
silently corrupt the monitor samples. Consider driving the DUT-observed members from inside the
interface (e.g. through the clocking block or a small `always_comb`/assign inside the interface)
rather than from the hook module, so the ownership of each signal is unambiguous.



─── RTL/DVP2axi_stream.v:389-391 ───
[bug · high] Sticky-event loss due to assignment precedence: the hardware event pulses
(frame_done/fifo_overflow/line_err/frame_err/axis_err) set bits of `reg_err_flag`/`reg_int_status`
earlier in this same clocked block, but the W1C write below (and the SOFT_RST/CLR_CNT clears further
down) assigns the *whole* vector later in the block, so the later non-blocking assignment wins and
an event that occurs in the same cycle as a W1C (or a SOFT_RST/CLR_CNT write) is silently dropped.
Merge the set-side events into the clear result instead of relying on statement order, e.g. clear
only the written bits and OR the event flags back in.

              if (axi_wr && wr_hit && wr_addr == ADDR_ERR_FLAG) begin
-                 reg_err_flag <= reg_err_flag & ~w1c_mask(wdata, wstrb);
+                 // keep bits that event in the same cycle while clearing the W1C bits
+                 reg_err_flag <= (reg_err_flag & ~w1c_mask(wdata, wstrb)) |
+                                 {27'h0, axis_err_event, frame_err_event, line_err_event, fifo_overflow_event};
+             end else begin
+                 // event-only updates handled above (unchanged)
              end


─── RTL/DVP2axi_stream.v:148-148 ───
[maintainability · medium] `ctrl_new` is a module-level `reg` written with a blocking assignment
inside the clocked `always` block, and only under the `ADDR_CTRL` branch. Synthesis will infer an
unintended 32-bit register bank with an enable (extra flops that are never reset and whose value is
only needed combinationally), i.e. a simulation/synthesis style mismatch. Compute the byte-strobed
next value in a combinational expression (e.g. a `wire` / function call) and assign it to `reg_ctrl`
directly.

-     reg [31:0] ctrl_new;
+     wire [31:0] ctrl_new_w = apply_wstrb(reg_ctrl, wdata, wstrb) & ~32'h0000_0032; // bits 1/4/5 self-clearing


─── RTL/DVP2axi_stream.v:427-427 ───
[bug · low] The self-clearing CTRL bits are forced to 0 unconditionally, whereas the matching write
action in section 3 is guarded by `wstrb[0]`. Today `reg_ctrl[1]/[4]/[5]` can never read back as 1,
so this is benign, but a partial write that does not strobe byte 0 (wstrb[0]==0) still modifies
control bits the master did not address. Guard the clearing with `wstrb[0]` to keep it consistent
with the action logic and robust if these bits ever become readable/read-modify-write fields.

+                         if (wstrb[0]) begin
-                         ctrl_new[1] = 1'b0;
+                             ctrl_new[1] = 1'b0;
+                             ctrl_new[4] = 1'b0;
+                             ctrl_new[5] = 1'b0;
+                         end


─── RTL/DVP2axi_stream.v:194-194 ───
[bug · low] `bresp`/`rresp` are hardwired to OKAY, so writes/reads to unmapped offsets (any address
failing `wr_hit`/`rd_hit`, plus writes to read-only registers such as STATUS/VERSION/FIFO_STATUS)
are silently ignored yet reported as successful. If the system relies on error reporting, decode
misses should return SLVERR (2'b10); otherwise document explicitly that all accesses complete OKAY.

-     assign bresp   = 2'b00;
+     assign bresp   = 2'b00; // NOTE: decode misses also return OKAY - return 2'b10 (SLVERR) if error reporting is required


─── RTL/DVP2axi_stream.v:478-479 ───
[documentation · low] The capture/streaming datapath is still a tie-off: the DVP inputs (`pclk`,
`prst_n`, `pdin`, `pvref`, `phref`), `axis_tready` and the `AXI_STREAM_TID/USER_WIDTH/TDEST_WIDTH`
parameters are unused, `axis_tvalid`/`axis_tlast` are tied low and `axis_tdata` is all-zero, while
all status/event placeholders are constants. The module therefore does not perform its stated
function and STATUS/FIFO_STATUS reads are constant (the constant-conditional event logic will also
be optimized away). This is acceptable only as an unconnected placeholder - please ensure the
datapath (and the resulting `pclk` -> `aclk` CDC on status/event paths) is implemented before this
block is instantiated in a system.



─── bench/work/_vmake:1-4 ───
[maintainability · medium] These `_vmake` files (`bench/work/_vmake`, `work/_vmake`,
`work_probe3/_vmake`) are not source code: they are generated simulator work-library artifacts
containing only stray tokens such as `m255`, `K4`, `z0`, and the vendor banner `cModel Technology`.
Committing them bloats the repo, creates churn/merge conflicts, and cannot be reviewed for
correctness, error handling, concurrency, or security. Delete them and other generated work-library
files, and add patterns such as `work*/`, `_vmake`, `_info`, and `*.qtl` to `.gitignore`; regenerate
the library locally from real sources instead.



─── work_probe3/_vmake:4-4 ───
[security · medium] `cModel Technology` is a vendor banner from a third-party/proprietary simulation
tool (the same string appears in `_info` and in `_lib4_0.qtl`). Before keeping any of these files in
the repository, confirm that redistribution of the tool's generated output/banner is permitted by
the licence — and note that the adjacent `_info` file also embeds a developer's absolute local path
(`dE:/SV_prj/DVP_axi_stream`), which should not be published. Unless there is a deliberate need to
version them, drop these artifacts from the repo.



─── work/_info:11-11 ───
[maintainability · high] These `_info` files (e.g. `work/_info`, `work_probe3/_info`,
`bench/work/_info`) are QuestaSim-generated library indexes, not source. They embed machine-specific
absolute paths such as `E:/SV_prj/DVP_axi_stream` and per-machine hash/job tokens, so a committed
copy is valid only on the original developer's machine and silently mis-resolves sources on CI or
another checkout; it also creates churn and merge conflicts. Exclude the build libraries from
version control (e.g. add `work/` and `bench/work/` to `.gitignore`), regenerate them locally for
each environment, and never hand-edit these encoded records.



─── work_probe3/_info:23-23 ───
[bug · medium] The per-unit timestamps in these generated `_info` indexes are inconsistent
(library-level `!s110` later than unit-level `!s110`/`!s108` entries), indicating a partially
recompiled library whose index no longer matches the compiled objects. This makes
incremental-build/staleness detection unreliable and can cause mismatched elaboration. Do not patch
the encoded values; regenerate the whole library atomically from a clean build so the internal
records are self-consistent.



─── work/_info:59-59 ───
[maintainability · medium] The recorded compile options (`-cover bcesft`, `-mfcu`,
`+define+VRF_AXIL_BIND_REF`, imported libraries `-L mtiAvm ... -L infact`) determine elaboration and
bind behavior, but they are stored in this generated `_info` as an opaque, unreviewable blob that
can drift from the real build script. Keep the checked-in build script/filelist as the single source
of truth for options/defines, and treat this cached record as derived data so builds and simulation
results are reproducible across hosts.



─── bench/work/_info:16-16 ───
[bug · high] This generated `bench/work/_info` library index is polluted with the throwaway
smoke-test unit/source `_tmp_cfg_smoke` and mixes stale/duplicated source entries (absolute machine
paths plus `IF/../IF/...`), so consumers would inherit a smoke-test configuration and silent stale
bindings. Regenerate the library from the real configuration and drive the compile source
set/include paths from a checked-in build script or project file rather than this cached index.



─── transcript:23-23 ───
[bug · high] vlog-13233: `DVP2axi_stream_v_unit` is recompiled/replaced by a version built with a
*different set of options*. This silently overrides a previously compiled unit/package, so the
elaborated design may differ from the source you intended (e.g. different defines or `-mfcu`
grouping), producing results that cannot be trusted. Compile each variant into its own library
(`-work`) or use distinct compilation-unit names to guarantee the unit that gets elaborated is the
one you expect.



─── transcript:34-34 ───
[bug · high] vlog-2650: the `bind` statement was found in compilation-unit scope (`-mfcu` was used)
and will NOT be elaborated unless `-cuname` is supplied. In this testbench the bind is what hooks up
the reference/checker (`VRF_AXIL_BIND_REF`) via `vrf_axil_harness_ref`, so the checker may be
silently absent while the run still reports no errors — a false pass. Add `-cuname` to the vlog
command (or move the `bind` into a module/package scope) and assert that the harness/checker is
actually instantiated.



─── transcript:31-31 ───
[maintainability · medium] Two top-level modules are reported (`tb_vrf_axil_demo` and
`tb_dvp2ax_stream`). Which one is actually simulated is determined solely by the launch command
(`work.tb_vrf_axil_demo` below / the `TEST` variable in `bench/scripts/sim.do`), so a mis-set `TEST`
silently exercises the wrong benchmark. Consider building separate libraries per testbench or
asserting the selected top explicitly, and verify `TEST`/top match in the run script.



─── transcript:41-41 ───
[bug · medium] The transcript stops right after the simulation launch line: there is no `run -all`
output, no pass/fail verdict, no `$finish`/exit status and no summary of assertion/UVM errors for
the actual run. A truncated log like this cannot be distinguished from a run that hung, crashed or
aborted, so it cannot be used as evidence that the test passed. Capture the full simulator output
(including exit code and error summary) and, if the run is expected to be short, confirm the process
terminated normally.



─── transcript:11-11 ───
[maintainability · low] These committed simulator transcripts/logs are generated output (hardcoded
`seed=0`, absolute paths, and a reference to a temporary local source such as `_tmp_cfg_smoke.sv`
that is not in the repository), so they cannot be reproduced by other developers/CI and go stale
immediately. Keep generated logs out of version control (e.g. write to `log/` and add it to
`.gitignore`) and check in the actual smoke-test source under a stable, non-`_tmp` name if the test
is meant to be repeatable.



─── Makefile:17-17 ───
[maintainability · medium] `PWSH` bundles the interpreter name together with its flags, so callers
cannot override only the executable (e.g. `make PWSH=pwsh` is impossible — the appended
`-ExecutionPolicy Bypass -File` would be lost/misordered) and the policy is impossible to tighten.
Bundling also means the `powershell` command is hardcoded, so the file is not usable on hosts where
only `pwsh` (PowerShell 7) exists, contradicting the "unified entry" intent. Split the variable into
interpreter + flags and let recipes compose them.

- PWSH   ?= powershell -ExecutionPolicy Bypass -File
+ PWSH       ?= powershell
+ PWSH_FLAGS ?= -ExecutionPolicy Bypass -File        # 所有配方改为 $(PWSH) $(PWSH_FLAGS) ...


─── Makefile:36-36 ───
[security · medium] Unquoted user-supplied variables (`TEST`, `SEED`, `NRAND`) are expanded straight
into the command line. A value containing spaces or shell metacharacters (e.g. `make run
TEST="tb_dvp2ax_stream; del x"` or `SEED="1 -Cover"`) alters the invocation or injects extra
arguments/flags into the PowerShell call; on Windows make the metacharacters are interpreted by
cmd.exe. Quote `TEST` and validate that `SEED`/`NRAND` are plain integers before use.

-       $(PWSH) $(RUN) -Test $(TEST) -Seed $(SEED) -Nrand $(NRAND)
+       $(PWSH) $(RUN) -Test "$(TEST)" -Seed "$(SEED)" -Nrand "$(NRAND)"


─── Makefile:39-39 ───
[bug · medium] `cover` and `regress` hardcode `tb_dvp2ax_stream` and ignore `TEST` (and `regress`
also hardcodes seeds `1,2,3,4,5`), so `make cover TEST=tb_vrf_axil_demo` or a narrowed regression
silently runs the wrong test. Use the `TEST` variable as the other targets do, expose the regression
seeds via a variable (reusing `SEED`/`NRAND` or a new `SEEDS`), and pass them through to
`regression.ps1`.

-       $(PWSH) $(RUN) -Test tb_dvp2ax_stream -Cover
+       $(PWSH) $(RUN) -Test $(TEST) -Cover


─── Makefile:48-48 ───
[bug · high] `clean` is not portable and fails silently: `rmdir /S /Q ... 2>NUL` is cmd.exe syntax
(on Linux/macOS it errors out and, worse, `2>NUL` creates a file literally named `NUL`), while the
leading `-` discards the exit status so a failure to delete `work`/`log` goes unnoticed. The paths
are also relative to the invoking directory, unlike every `run.ps1` target which first
`Set-Location`s to the project root, so running make from a different CWD can delete unrelated
`work`/`log` directories. Use an OS-conditional recipe and drop the silent `-`.

-       -rmdir /S /Q work log 2>NUL
+ ifeq ($(OS),Windows_NT)
+       -rmdir /S /Q work log
+ else
+       rm -rf work log
+ endif


─── Makefile:30-30 ───
[maintainability · low] No target verifies prerequisites before delegating: if `powershell` is
absent or `bench/scripts/run.ps1`/`regression.ps1` are missing, the failure surfaces as an opaque
interpreter error rather than a clear message. Add a lightweight guard (or a shared `check`
prerequisite) that validates the interpreter and script paths.

+       @command -v $(PWSH) >/dev/null 2>&1 || { echo "ERROR: '$(PWSH)' not found; override with PWSH=<interpreter>"; exit 1; }
+       @test -f $(RUN) || { echo "ERROR: missing script $(RUN)"; exit 1; }
        $(PWSH) $(RUN) -Test tb_vrf_axil_demo


─── bench/transcript:4-4 ───
[bug · medium] The logged build of the smoke test emits `vopt-2244`: the module-scope variable `cfg`
is **implicitly static** while being initialized in its declaration. This is not just a cosmetic
warning:
- the initializer is executed only once at elaboration time, so the object is shared across every
invocation of the checking routine (the transcript shows the same `cfg` reused for the 5
positive/negative cases) and any state that is not fully re-assigned inside the case leaks into the
next case;
- with `run -all`, a warning does not stop the run, so a genuinely broken config setup can still be
reported as `SMOKE PASS`.
Make the intent explicit (declare the variable `automatic`/`static`, or leave the declaration
uninitialized and assign inside the `initial` block) and treat warnings as failures in the smoke run
so a non-clean compile cannot silently pass.



─── bench/transcript:31-31 ───
[test · medium] The dumped config advertises `txn_num=100 seed=0 scenario=SCEN_RANDOM` with
`en_scoreboard=1`, but the transcript ends with `$finish` at `Time: 0 ps  Iteration: 0` — i.e. **not
a single transaction was driven** and the scoreboard was never exercised. The whole run only
evaluates `check_legal()` in zero simulation time, so this transcript cannot catch integration
defects (driver/monitor wiring, reset sequencing, address decode, back-pressure). Either rename the
test to reflect that it is a pure config-legality unit check, or extend it to actually run `txn_num`
transactions and report a short result.



─── bench/transcript:60-60 ───
[test · medium] Negative coverage of `check_legal` is limited to 4 scenarios (vif unset, aw_delay
min>max, prob=101/clk_period=0, en_reg_model=1) and the positive case only checks the default
config. Boundary values that are most likely to expose off-by-one comparisons are untested:
- `prob == 0` and `prob == 100` must be legal, `prob == -1` and `prob == 101` illegal;
- `clk_period` negative (only `== 0` is checked here);
- `aw_delay_min == aw_delay_max` and all delay ranges equal (valid boundary of the min>max rule);
- ID checks: `exp_bid`/`exp_rid` outside the `IDWIDTH=4` range and `id_chk_mode` other than
`ID_EXPECT_CONST`;
- mutually exclusive feature flags (`en_coverage`/`en_scoreboard`/`en_reg_model` combinations).
Please add these cases so the legal/illegal decision table is actually covered at its edges.



─── bench/transcript:78-78 ───
[test · medium] Only the rw/ro/w1c queue invariants are asserted, plus two spot checks
(`reg_map[VERSION]`, `rst_val_tab[IMG_WIDTH]`). The dump prints `未映射=5` but there is no
corresponding PASS/FAIL assertion, and the per-register `offset`/`rst_val` values (23 registers) are
never verified programmatically — a drifted address map or reset value would only be noticed by
visually diffing this log. Add explicit checks that `RW+RO+W1C+unmapped` equals the address-space
size and compare the full `reg_map`/`rst_val_tab` against an expected table instead of two
hand-picked entries.




──────── Project Summary ────────

# Project Review Summary

Scope: 65 comments across 18 files. Comment distribution is heavily skewed toward (a) generated/committed simulator artifacts, (b) the PowerShell bench orchestration scripts, and (c) abandoned verification code — with a small but serious cluster in the live RTL and checker.

---

### Top Issues

1. **End-to-end result propagation is broken — the regression harness can silently report false PASS.**
   `bench/scripts/run.ps1` never validates `vlib` (piped to `Out-Null`) or `vsim` (uses a stale `$LASTEXITCODE` from the preceding `vlog`), so a missing tool or failed compile exits 0. `bench/scripts/regression.ps1` compounds this: `& $runScript @runArgs | Out-Host` discards the child exit status, stale reports from prior rounds are never cleaned, and a round is accepted as passing if the verdict string reads `PASSED` even when the stats regex matched nothing (`$checked == 0`). A reformatted, truncated, or encoding-mangled report silently counts as a pass. This is the single most consequential cluster: the harness cannot distinguish compile failure, crash, hang, and success.

2. **Generated simulator artifacts are committed as source, making builds non-reproducible.**
   `work/_info`, `work_probe3/_info`, `bench/work/_info`, `bench/work/_vmake`, `work_probe3/_vmake`, and the `transcript` / `bench/transcript` logs are QuestaSim/ModelSim output, not source. They embed machine-specific absolute paths (`E:/SV_prj/DVP_axi_stream`), vendor banners (`cModel Technology`), per-machine hash/job tokens, and a throwaway `_tmp_cfg_smoke` unit. The `work_probe3/_info` timestamps are internally inconsistent (partially recompiled library), so incremental builds are already stale. This pollutes the repo and, for the vendor banner, may raise redistribution questions.

3. **The AXI4-Lite checker cannot actually fail on the paths it claims to check.**
   In `bench/abandoned/AXI4-Lite.sv`, `b_resp`/`r_resp` are initialized from `p.resp` (the value the slave itself drives) and never re-sampled from the interface, so the response checks are tautological. In `bench/abandoned/VRF_AXI4L_v0.sv`, transactions are *born* `txn_resp = OKAY` / `txn_result = PASS`, and the monitor only overwrites — any dropped or unsampled transaction stays PASS. Together these mean write/read response and completion semantics are effectively unverified.

4. **The checker may not be elaborated at all in the current build.**
   `transcript`: `vlog-2650` warns the `bind` statement was found in compilation-unit scope (`-mfcu` used) and will **not** be elaborated without `-cuname`. The bind is what hooks up `VRF_AXIL_BIND_REF` / `vrf_axil_harness_ref`. Meanwhile `vlog-13233` reports `DVP2axi_stream_v_unit` silently replaced by a version built with different options, and the transcript ends at `Time: 0 ps` with **zero transactions driven** despite a config advertising `txn_num=100`. The committed "passing" evidence supports neither hook-up nor execution.

5. **RTL register block loses sticky events and hides decode errors.**
   `RTL/DVP2axi_stream.v`: hardware event pulses set bits of `reg_err_flag`/`reg_int_status` earlier in the same clocked block, but the W1C write and SOFT_RST/CLR_CNT clears later in the block overwrite them — an event coincident with a clear is silently lost. `bresp`/`rresp` are hardwired `OKAY` for unmapped offsets and read-only register writes, so decode errors are reported as successful writes. `ctrl_new` is a module-level `reg` written with a blocking assignment inside the clocked block, synthesizing an unintended 32-bit flop bank. The capture/streaming datapath is still tied off (`axis_tvalid`/`axis_tlast` low, `axis_tdata` zero, DVP inputs unused).

6. **Multiple-driver and thread-cleanup races in the bench infrastructure.**
   `bench/lib/Slv/vrf_axil_slave.sv`: `rst_task` and `wr_task`/`rd_task` are parallel processes writing the same clocking-block outputs (`awready`/`wready`/`bvalid`/`arready`/`rvalid`) — last-write-wins with no ordering guarantee. `bench/abandoned/AXI4-Lite.sv`: when the `timeout_monitor` branch wins `join_any`, `disable ..._fork` kills the driver threads before their deassert statements, leaving ready/valid signals stuck asserted.

7. **Parameters are hardcoded instead of honored across both RTL-adjacent and bench code.**
   `bench/lib/Slv/vrf_axil_slave.sv` hardcodes `store`/`rd_cap` to `[31:0]` while `rdata` is `[DWIDTH-1:0]`; `bench/abandoned/if_axil.sv` hardcodes AW/AR IDs to 3 bits against an `IDWIDTH`-parameterized R/B channel and uses integer `DWIDTH/8` for `wstrb`; `bench/abandoned/AXI4-Lite.sv` hardcodes the `txn_result_e` fields to 32/128/16 bits while all drivers are parameterized. Any non-default instantiation silently truncates or misaligns.

8. **Interface/modport contracts are absent, so directions and skew are unenforced.**
   `bench/abandoned/if_axil.sv` declares `rst` as an `input` on all three modports of every channel — no modport can drive it, so reset must come from a hierarchical reference. `bench/abandoned/if_axil_v0.sv` has no modports at all, and `arstn` is declared but never used. Driving clocking blocks lack `default input/output skew`, so drive/sample lands in the same time step as the DUT. `bench/lib/IF/vrf_axil_if.sv` both drives interface variables via clocking-block outputs and via module-scope continuous assigns, and publishes interface handles into `static` class members with last-writer-wins semantics.

---

### Module Hotspots

- **`bench/abandoned/` — 20 comments across 4 files** (`if_axil.sv`, `if_axil_v0.sv`, `VRF_AXI4L_v0.sv`, `AXI4-Lite.sv`): highest severity density in the repo. Includes an infinite zero-time loop (`receive()` empty body inside `forever`), tautological checks, and uninitialized locals producing X. Either excise these files or mark them clearly dead — they currently look loadable and can be accidentally wired in.
- **Generated artifacts — 11 comments across 6 paths** (`work/_info`, `work_probe3/_info`, `bench/work/_info`, `bench/work/_vmake`, `work_probe3/_vmake`, `transcript`, `bench/transcript`). Not code, but the largest single block of comments.
- **`bench/scripts/` — 10 comments across 2 files** (`run.ps1`, `regression.ps1`): control flow, destructive cleanup, injection surface, and exit-status handling.
- **`bench/lib/` — 10 comments across 3 files** (`Chk/vrf_axil_chk.sv`, `Slv/vrf_axil_slave.sv`, `IF/vrf_axil_if.sv`): live checker has correctness bugs (AW/W simultaneity requirement, unguarded `wr_pend`/`rd_pend` decrement, over-strict `p_no_xz`, stale `*_stuck` counters, off-by-one diagnostics).
- **`RTL/DVP2axi_stream.v` — 5 comments in one file**: register/CSR block semantics.
- **`Makefile` — 5 comments**: build front-end ergonomics and portability.

---

### Cross-Cutting Concerns

- **Unchecked exit codes / silent failure swallowing.** `run.ps1` (`vlib | Out-Null`, `vsim`), `regression.ps1` (`| Out-Host`), `Makefile` (`-rmdir`, no prerequisite guard). `$ErrorActionPreference = "Continue"` in both PS scripts turns fatal conditions into warnings that scroll past.
- **Default-pass / permissive sentinel values.** `VRF_AXI4L_v0.sv` (`txn_resp = OKAY`, `txn_result = PASS` at construction and in `post_randomize()`), `AXI4-Lite.sv` (resp sampled from `p.resp`), `regression.ps1` (`PASSED` accepted with `$checked == 0`), `DVP2axi_stream.v` (`bresp`/`rresp` always `OKAY`). Same failure mode: the "negative" outcome is unrepresentable.
- **Hardcoded widths vs. parameters.** `vrf_axil_slave.sv`, `if_axil.sv`, `AXI4-Lite.sv` (`txn_result_e`). Silently truncates only at non-default parameterizations, so it survives the default smoke test.
- **Concurrency races in SystemVerilog.** Multiple processes driving the same clockvars (`vrf_axil_slave.sv`), `disable` of forked driver threads leaving signals asserted (`AXI4-Lite.sv`), reset task racing data path.
- **Coverage gaps that hide bugs by construction.** `AXI4-Lite.sv` `dly_lo`/`dly_hi` default to 0 (random mode cannot exercise delay), `VRF_AXI4L_v0.sv` forbids unaligned addresses, `run.ps1` uses 0 as "no seed" sentinel so `-Seed 0` is irreproducible and `-Nrand <= 0` is dropped, `bench/transcript` shows `check_legal` negative coverage limited to 4 scenarios with no boundary values (`prob == 0/100/101`, `clk_period == 0/1`, min/max delays).
- **Reproducibility of evidence.** Committed transcripts and `_info` indexes are machine- and seed-specific (`seed=0`, `E:/...` paths), truncated before any `run -all` output, and reference a source (`_tmp_cfg_smoke.sv`) not in the repo. A truncated log cannot be distinguished from a hung or crashed run.

---

### Quick Wins

- **Delete generated artifacts and add ignores.** Remove `work/`, `work_probe3/`, `bench/work/`, `transcript`, `bench/transcript` and add `.gitignore` entries (`_info`, `_vmake`, `transcript`, `work*`). Highest ratio of comment volume to effort.
- **Add `$LASTEXITCODE` checks** after `vlib`, `vlog`, `vsim` in `bench/scripts/run.ps1` and after the child invocation in `bench/scripts/regression.ps1`; fail fast on non-zero.
- **Clean the report file at the top of each regression round** and require a non-zero `$checked` count before accepting `PASSED` (`regression.ps1`).
- **Validate/sanitize before destructive or interpolated operations**: guard the `Remove-Item` in `run.ps1` on a successful `Set-Location` (or wrap in `try`/`finally` to restore cwd), and reject/escape `$LogDir` values containing spaces, `;`, or `"` before generating the ModelSim `do` string.
- **Quote `TEST`/`SEED`/`NRAND` and split `PWSH`** into `PWSH` + `PWSH_FLAGS` in `Makefile`; make `cover` and `regress` honor `TEST` (and expose regression seeds as a variable).
- **Replace trivially hardcoded widths with parameters**: `store`/`rd_cap` in `vrf_axil_slave.sv`, AW/AR ID width and `wstrb` sizing in `if_axil.sv`.
- **Mark `post_randomize()` virtual** in `VRF_AXI4L_v0.sv` and **assign `result.txn_strb = '0;`** on read transactions in `AXI4-Lite.sv` — both one-line fixes that unblock subclassing and read-side logging.
- **Add a `check` prerequisite** in the `Makefile` that verifies `powershell`/`pwsh` and the script paths exist before delegating, so failures surface as a clear message rather than an interpreter error.