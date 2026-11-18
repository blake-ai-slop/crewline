# ---------------- thay pane của chính lệnh crew ----------------
# Lệnh crew không tắt được pane đang chạy nó: tiến trình nền đợi lệnh xong rồi thay. Hc đặt tiến trình con của pane vào job, kill pane là chết cả job;
# Start-Process và Process.Start đều chết theo (đo trên hc 0.1.17). CreateProcess với CREATE_BREAKAWAY_FROM_JOB sống, kế thừa môi trường và không thành terminal hc.
function Get-SelfPaneFile([string]$root, [string]$ext) { Join-Path $root ".crew/self-pane.$ext" }
function Get-SelfPaneMarker { 'CREW-SELF-PANE:' }
function New-SelfPaneJob([string]$root, [string]$term, [string]$role, [string]$address, [bool]$restart) {
  @{ root = $root; term = $term; role = $role; address = $address; restart = $restart }
}

# Việc cuối của cả lệnh. Con của -All chuyển job lên cha (dòng đánh dấu) vì cha còn phải chạy project khác và in bảng tổng kết.
function Invoke-SelfPaneHandoff($job) {
  if ($env:CREWLINE_UP_ALL_CHILD -eq '1') {
    Write-Host "$(Get-SelfPaneMarker)$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $job -Compress))))"
    return
  }
  Say 'kết quả hàng đợi sẽ ở .crew/queue.log.'
  Say "tab này sắp chuyển thành $($job.term) sau vài giây; chữ đang in sẽ mất. Đừng gõ gì vào tab này cho tới khi đó."
  try { Start-SelfPaneProcess $job }
  catch { Say "cảnh báo: không tạo được tiến trình nền ($($_.Exception.Message)); giữ pane. Mở tab khác rồi chạy lại: crew up$(if ($job.restart) { " -Restart $($job.role)" })" }
}

# Tạo tiến trình ra khỏi job của pane. Job cấm breakaway (vd runner GitHub Actions) thì CreateProcess lỗi 5: ném lỗi, không có đường dự phòng vì tiến trình trong job chết theo pane.
function Start-BreakawayProcess([string]$exe, [string]$commandLine, [string]$cwd) {
  if (-not ('Crew.Detach' -as [type])) {
    Add-Type -Namespace Crew -Name Detach -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct StartupInfo { public int cb; public string reserved; public string desktop; public string title; public int x; public int y; public int xSize; public int ySize; public int xChars; public int yChars; public int fill; public int flags; public short show; public short reserved2; public System.IntPtr reserved3; public System.IntPtr stdIn; public System.IntPtr stdOut; public System.IntPtr stdErr; }
[StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public System.IntPtr process; public System.IntPtr thread; public int processId; public int threadId; }
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool CreateProcess(string app, System.Text.StringBuilder cmd, System.IntPtr pa, System.IntPtr ta, bool inherit, uint flags, System.IntPtr env, string cwd, ref StartupInfo si, out ProcessInfo pi);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@
  }
  $line = [Text.StringBuilder]::new($commandLine)
  $si = New-Object 'Crew.Detach+StartupInfo'; $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
  $proc = New-Object 'Crew.Detach+ProcessInfo'
  # CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
  if (-not [Crew.Detach]::CreateProcess($exe, $line, [IntPtr]::Zero, [IntPtr]::Zero, $false, [uint32]0x09000400, [IntPtr]::Zero, $cwd, [ref]$si, [ref]$proc)) {
    throw "CreateProcess lỗi $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  [void][Crew.Detach]::CloseHandle($proc.process); [void][Crew.Detach]::CloseHandle($proc.thread)
}

function Start-SelfPaneProcess($job) {
  $file = Get-SelfPaneFile $job.root 'json'
  $job.parentPid = $PID
  New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
  [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $job -Depth 100), [Text.UTF8Encoding]::new($false))
  try {
    $found = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $exe = if ($found) { $found.Source } else { (Get-Process -Id $PID).Path }
    Start-BreakawayProcess $exe "`"$exe`" -NoLogo -NoProfile -NonInteractive -File `"$CrewScriptPath`" self-pane-run -Path `"$($job.root)`"" $job.root
  } catch { Remove-Item -LiteralPath $file -ErrorAction Ignore; throw }
}

# Đợi crew thoát rồi xác minh pane. Trả @{ Info; Why }: Why khác rỗng ⇒ giữ pane, không kill. Chỉ đọc.
# Shim chạy crew ngay trong shell của pane nên pid cha có thể là chính shell (không bao giờ thoát): khi đó dấu nhắc trở lại là dấu hiệu crew đã xong.
function Wait-SelfPaneShell($job, $ops, [int]$tries = 120, [int]$settleMs = 3000) {
  $want = if ($job.restart) { 'lost', 'exited' } else { , 'lost' }
  $check = {
    param($info)
    if (-not $info) { return 'không đọc được terminal' }
    if ($info.name -cne $job.term -or $info.address -cne $job.address) { return "terminal đã đổi (tên $($info.name), địa chỉ $($info.address))" }
    if (-not (Test-TermOwner $info $job.root)) { return "terminal không thuộc project (cwd $($info.cwd))" }
    ''
  }
  $parent = [int]$job.parentPid
  $seen = 0; $why = 'chưa thấy dấu nhắc shell, có thể đã có lệnh khác trong pane'
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 500 }
    $info = & $ops.Get $job.term
    $bad = & $check $info
    if ($bad) { return @{ Info = $null; Why = $bad } }
    if ($parent -ne [int]$info.pid -and (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { $seen = 0; $why = 'lệnh crew chưa thoát'; continue }
    if ((Get-TermShellState $info { & $ops.Read $job.term }) -notin $want) { $seen = 0; $why = 'pane không còn là shell trống (có thể bạn đã gõ lệnh khác)'; continue }
    if (++$seen -ge 2) { break }
  }
  if ($seen -lt 2) { return @{ Info = $null; Why = $why } }
  # Cho người dùng kịp đọc, rồi đọc lại lần cuối ngay trước kill.
  & $ops.Sleep $settleMs
  $info = & $ops.Get $job.term
  $bad = & $check $info
  if ($bad) { return @{ Info = $null; Why = $bad } }
  if ((Get-TermShellState $info { & $ops.Read $job.term }) -notin $want) { return @{ Info = $null; Why = 'pane không còn là shell trống ở lần đọc cuối' } }
  @{ Info = $info; Why = '' }
}

# Vai số lẻ đứng trước vai số chẵn trong cùng tab workers; pane vừa bật lại luôn vào cuối tab. Vai không chung tab với ai thì không cần làm gì.
function Restore-SelfPaneOrder([string]$slug, [string]$role, $ids, [string]$focus) {
  if ($role -notmatch '^w(\d+)$' -or [int]$Matches[1] % 2 -eq 0) { return }
  $n = [int]$Matches[1]
  $names = "$slug-w$n", "$slug-w$($n + 1)"
  $tab = & $ids.Workers ([math]::Ceiling($n / 2))
  $read = {
    $hs = Get-HerdrSpaces
    if (-not $hs.Ok) { return @() }
    foreach ($sp in @($hs.Spaces)) { foreach ($tb in @($sp.tabs)) { if ($tb.id -ceq $tab) { return @($tb.terminals) } } }
    @()
  }
  $terms = @(& $read)
  $order = @($terms | Where-Object { $names -ccontains $_.name } | ForEach-Object { $_.name })
  if ($order.Count -lt 2 -or $order[0] -ceq $names[0]) { return }
  $mine = @($terms | Where-Object { $_.name -ceq $names[0] })[0]
  herdr-app do pane.focus --terminal $mine.terminal | Out-Null
  herdr-app do pane.swap --direction left | Out-Null
  $after = @(@(& $read) | Where-Object { $names -ccontains $_.name } | ForEach-Object { $_.name })
  if ($after.Count -ge 2 -and $after[0] -cne $names[0]) { Say "cảnh báo: $($names[0]) chưa về đúng vị trí trong tab workers." }
  herdr-app do space.select --id $ids.Space | Out-Null
  herdr-app do tab.select --id $focus | Out-Null
}

# Giới hạn tổng của self-pane-run, chỗ duy nhất. Biến môi trường để test rút ngắn.
function Get-SelfPaneTimeoutSec {
  $v = 0
  if ([int]::TryParse("$env:CREWLINE_SELF_PANE_TIMEOUT_SEC", [ref]$v) -and $v -gt 0) { return $v }
  600
}

# Tiến trình nền: không còn pane để in nên mọi chữ vào log; xong êm thì xóa log, còn log nghĩa là có chuyện để crew up lần sau nhắc.
function Set-SelfPaneLogging([string]$log) {
  $script:SelfPaneLog = $log
  # Tên trùng cmdlet: hàm thắng, nên Say/Die và mọi báo cáo của repair đều vào log.
  function script:Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, [switch]$NoNewline) Add-Content -LiteralPath $script:SelfPaneLog -Value "$(Get-Date -Format s) $(@($Object) -join ' ')" -Encoding utf8 }
}

# Giám sát: lệnh con treo thì không ngắt được từ trong cùng tiến trình, nên việc thật chạy ở self-pane-work; quá hạn thì kill cả cây, ghi log, nhả lock.
function Invoke-SelfPaneRun {
  $root = (Resolve-Path $Path).Path
  $file = Get-SelfPaneFile $root 'json'; $killMark = Get-SelfPaneFile $root 'killed'
  Set-SelfPaneLogging (Get-SelfPaneFile $root 'log')
  try { $lock = [IO.File]::Open((Get-SelfPaneFile $root 'lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { exit 0 }  # đã có tiến trình khác đang thay
  try {
    Remove-Item -LiteralPath $killMark -ErrorAction Ignore
    $limit = Get-SelfPaneTimeoutSec
    $found = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $psi = [Diagnostics.ProcessStartInfo]::new($(if ($found) { $found.Source } else { (Get-Process -Id $PID).Path }))
    foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $CrewScriptPath, 'self-pane-work', '-Path', $root) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $root
    $p = [Diagnostics.Process]::Start($psi)
    if ($p.WaitForExit($limit * 1000)) { exit $p.ExitCode }
    $stopped = try { $p.Kill($true); $p.WaitForExit(10000) } catch { $false }
    if (-not $stopped) { Say "cảnh báo: chưa dừng được tiến trình nền pid $($p.Id)." }
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    if (Test-Path -LiteralPath $killMark) { Say "quá hạn $limit giây, đã dừng thay pane; pane có thể đã tắt. Chạy crew up để bật vai thiếu." }
    else { Say "quá hạn $limit giây, đã dừng thay pane; pane chưa bị tắt, giữ nguyên. Muốn thay thì chạy lại crew up trong pane đó." }
    exit 1
  } catch {
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    Say "lỗi: $($_.Exception.Message). Chạy crew up để bật vai thiếu."
    exit 1
  } finally {
    Remove-Item -LiteralPath $killMark -ErrorAction Ignore
    $lock.Dispose()
  }
}

function Invoke-SelfPaneWork {
  $root = (Resolve-Path $Path).Path
  $log = Get-SelfPaneFile $root 'log'; $file = Get-SelfPaneFile $root 'json'
  Set-SelfPaneLogging $log
  try {
    foreach ($v in 'HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET', 'HC_SCOPE', 'CREWLINE_UP_ALL_CHILD') { Remove-Item "Env:$v" -ErrorAction Ignore }
    Say 'bắt đầu thay pane.'
    $job = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    $ops = New-RepairOps
    $seen = Wait-SelfPaneShell $job $ops
    if ($seen.Why) { Say "giữ pane $($job.term), không tắt: $($seen.Why). Muốn thay thì chạy lại crew up trong pane đó."; exit 0 }
    [IO.File]::WriteAllText((Get-SelfPaneFile $root 'killed'), $job.term)  # giám sát cần biết pane đã có thể mất khi quá hạn
    Stop-Term $seen.Info.address
    if ((Get-WorkerMode (& $ops.Get $job.term) 'claude').Mode -ne 'dead') { Say "$($job.term) vẫn live sau kill; không bật chồng."; exit 1 }
    $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
    $script:Path = $root; $script:FromRepair = $true
    $problems = @()
    if ($job.restart) { $script:Restart = $job.role; $script:Force = $true; Invoke-Up }
    else {
      $res = Invoke-RepairCore $root $cfg $slug (Get-MainBranch $root) $false $ops
      $problems = @($res.Human)
      foreach ($f in $res.Finished) { Say $f }
    }
    foreach ($h in $problems) { Say "CẦN NGƯỜI QUYẾT: $h" }
    $focus = if ($cfg.planner -ne 'none') { $ids.Planner } else { & $ids.Workers 1 }
    Restore-SelfPaneOrder $slug $job.role $ids $focus
    if ((Get-WorkerMode (& $ops.Get $job.term) 'claude').Mode -eq 'dead') { Say "$($job.term) chưa live sau khi bật lại. Chạy crew up để bật vai thiếu."; exit 1 }
    if (-not $problems.Count) { Remove-Item -LiteralPath $log -ErrorAction Ignore }
    exit 0
  } catch { Say "lỗi: $($_.Exception.Message). Chạy crew up để bật vai thiếu."; exit 1 }
}

# Lần thay pane trước có chuyện: nhắc một lần. Tiến trình nền còn giữ khóa thì log chưa xong, không đụng.
function Show-SelfPaneLog([string]$root, [bool]$dry) {
  $log = Get-SelfPaneFile $root 'log'; $lock = Get-SelfPaneFile $root 'lock'
  if (-not (Test-Path -LiteralPath $log)) { return }
  if (Test-Path -LiteralPath $lock) { try { ([IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')).Dispose() } catch { return } }
  $kept = "$log.old"
  Say "lần thay pane trước có chuyện cần xem, log: $(if ($dry) { $log } else { $kept })"
  if (-not $dry) { Move-Item -LiteralPath $log -Destination $kept -Force }
}

# Bảng hc/herdr THẬT cho crew repair: New-HcOps + Up + (cho project đã chuyển) terminal live, space herdr, kill, đóng space.
# List ném lỗi khi hc ls lỗi (Get-LiveTerminals) — repair coi lỗi là dừng, không Kill/Close/Up/Send.
function New-RepairOps {
  $ops = New-HcOps; $ops.Up = { $script:FromRepair = $true; Invoke-Up }
  # cho Get-MoveInfo + sửa project đã chuyển: terminal live, space herdr, kill, đóng space cũ
  $ops.List = { @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) }
  $ops.Spaces = { Get-HerdrSpaces }
  $ops.Kill = { param($address) Stop-Term $address }
  $ops.CloseSpace = {
    param($id)
    $out = & { $ErrorActionPreference = 'Continue'; herdr-app do space.close --id $id --confirmed true 2>&1 | Out-String }
    @{ Code = $LASTEXITCODE; Text = "$out".Trim() }
  }
  $ops
}

# Khôi phục một project — dùng chung cho crew up (không -Restart) và crew repair; dựng terminal thiếu qua $ops.Up = Invoke-Up.
# $stopOnClash: crew up giữ chốt chặn cũ, tên/khóa id đã thuộc project khác còn tồn tại thì dừng trước khi đụng gì.
function Invoke-Recover([bool]$stopOnClash) {
  $p = (Resolve-Path $Path).Path
  $root = Get-MainRoot $p
  if ($stopOnClash -and $env:CREWLINE_UP_ALL_CHILD -ne '1' -and
    (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json')))) {
    if ($root -and -not (Test-SamePath (Get-Root $p) $root)) {
      Die "repo chính $root chưa init; đang ở worktree phụ nên không tạo gì. Chạy crew up tại repo chính."
    }
    $initRoot = if ($root) { $root } else { $p }
    $needsGit = -not $root -or (Invoke-GitQuiet -C $root rev-parse --verify -q HEAD).Code -ne 0
    if ($needsGit -and ((Test-SamePath $initRoot $HOME) -or (Test-SamePath $initRoot ([IO.Path]::GetPathRoot($initRoot))))) {
      Die "không init tại HOME hoặc gốc hệ thống tệp ($initRoot) khi chưa có commit; hãy chọn thư mục project con."
    }
    if ($DryRun) { Say 'project chưa init, crew up sẽ hỏi tạo'; exit 0 }
    $answer = $null
    if ($env:CREWLINE_DEFAULTS -ne '1') {
      . (Join-Path $CrewScriptsDir 'ui.ps1')
      $title = "Project $initRoot chưa init. Tạo context/, CLAUDE.md, AGENTS.md, .crew/, sửa .gitignore và commit?"
      if ($needsGit) { $title += ' Sẽ git init (nếu cần) và commit TẤT CẢ file đang có.' }
      $options = @((New-Option 'yes' 'Có' -Alias 'y', 'yes'), (New-Option 'no' 'Thôi' -Alias 'n', 'no'))
      $answer = Read-Choice $title $options $(if ($needsGit) { 'no' } else { 'yes' }) -NoStep -NullOnEof
    }
    if ($null -eq $answer) { Die "project chưa init; không hỏi được nên không tạo gì. Chạy crew init tại $initRoot." }
    if ($answer -ne 'yes') { Say 'thôi, không tạo gì.'; exit 1 }
    # Phạm vi cục bộ: bỏ câu hỏi git của init, giữ nguyên ưu tiên đội/cờ dòng lệnh.
    $GitInit = [bool]$needsGit
    Invoke-Init
    $root = Get-MainRoot $p
  }
  if (-not $root) { Die "không phải repo git. Project mới: chạy 'crew init' trong thư mục này trước." }
  # Kiểm schema/JSON trước bước nâng metadata tên (bước đó có thể ghi config).
  $null = Get-Config $root
  Update-ConfigName $root ([bool]$DryRun)
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg
  if ($stopOnClash) { $clash = Get-NameConflict $root $cfg; if ($clash) { Die $clash } }
  Confirm-GitIdentity $root $false ([bool]$DryRun)
  $main = Get-MainBranch $root
  $script:Path = $root  # crew up dựng theo repo chính, kể cả khi gọi từ worktree
  Show-SelfPaneLog $root ([bool]$DryRun)
  $ops = New-RepairOps
  $res = Invoke-RepairCore $root $cfg $slug $main ([bool]$DryRun) $ops
  Write-Host "== kết luận$(if ($DryRun) { ' (DryRun: không ghi git, không bật, không gửi)' })"
  if ($res.Done.Count) { foreach ($d in $res.Done) { Write-Host "  đã làm: $d" } } else { Write-Host '  không có gì phải sửa.' }
  foreach ($f in $res.Finished) { Write-Host "  $f" }
  foreach ($h in $res.Human) { Write-Host "  CẦN NGƯỜI QUYẾT: $h" -ForegroundColor Yellow }
  if ($res.Self) {
    $s = $res.Self
    if ($s.Self -eq 'unix-shell') { Write-Host "  $($s.Term) là pane hiện tại, shell trống; chưa xác minh shell trên hệ này nên crew không tự thay. Mở tab khác rồi chạy lại: crew up" }
    elseif (-not $stopOnClash) { Write-Host "  $($s.Term) là pane hiện tại, shell trống; crew repair không tự thay. Thay bằng: crew up" }
    elseif ($DryRun) { Write-Host "  (sẽ làm) thay pane hiện tại thành $($s.Term), sau cùng: $(Format-SessionPlan (Get-SessionPlan (Read-SessionBook $root) $root $cfg $s.Role $s.Kind))" }
    else { Invoke-SelfPaneHandoff (New-SelfPaneJob $root $s.Term $s.Role $env:HC_TERMINAL_ID $false) }
  }
  if ($res.Human.Count) { exit 1 }
  exit 0
}

# Danh sách project cho crew up -All (hàm thuần trừ kiểm thư mục): mục sổ theo thứ tự sổ, cộng $current (root đã init) nếu chưa có trong sổ.
# Trả mảng @{ Name; Root; Skip } — Skip khác rỗng ⇒ bỏ qua, nêu lý do; không tạo/xóa gì.
function Get-UpAllPlan($map, [string]$current) {
  $plan = @(foreach ($n in @($map.Keys)) {
      $r = [string]$map[$n].Root
      $skip = if (-not (Test-Path -LiteralPath $r -PathType Container)) { 'thư mục không còn' }
      elseif (-not (Test-Path -LiteralPath (Join-Path $r '.crew/config.json') -PathType Leaf)) { 'không còn .crew/config.json' }
      else { '' }
      @{ Name = [string]$n; Root = $r; Skip = $skip }
    })
  if ($current -and -not @($plan | Where-Object { Test-SamePath $_.Root $current }).Count) {
    $plan += @{ Name = (Split-Path $current -Leaf); Root = $current; Skip = '' }
  }
  , @($plan)
}

# Kết quả một project từ exit code + output tiến trình con. crew up trả exit 1 cho cả hai trường hợp, chỉ dòng kết luận phân biệt được.
function Get-UpChildResult([int]$code, [string]$text) {
  if ($code -eq 0) { return 'ok' }
  if ($text -match '(?m)^\s*CẦN NGƯỜI QUYẾT:') { return 'cần người quyết' }
  'lỗi'
}

# Bảng tổng kết crew up -All. $rows: @{ Name; Root; Result; Note }. Trả các dòng.
function Format-UpAllSummary($rows) {
  $rows = @($rows)
  $nw = (@('tên') + @($rows | ForEach-Object { $_.Name }) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
  $pw = (@('đường dẫn') + @($rows | ForEach-Object { $_.Root }) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
  $line = { param($a, $b, $c) ("{0}  {1}  {2}" -f "$a".PadRight($nw), "$b".PadRight($pw), $c) }
  @(& $line 'tên' 'đường dẫn' 'kết quả') + @($rows | ForEach-Object {
      & $line $_.Name $_.Root "$($_.Result)$(if ($_.Note) { ": $($_.Note)" })"
    })
}

# Một tiến trình pwsh riêng cho mỗi project: Invoke-Recover và Die gọi exit, lại dùng $script:Path/$script:FromRepair.
# In output của con khi nó chạy, trả @{ Code; Text }; không chạy được pwsh ⇒ Code = 1.
function Invoke-UpChild([string]$root, [bool]$dry) {
  $ErrorActionPreference = 'Continue'
  # Get-Command trước: pwsh bản Store chỉ chạy được qua alias trong PATH, không qua đường dẫn của tiến trình
  $exe = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $shell = if ($exe) { $exe.Source } else { (Get-Process -Id $PID).Path }
  $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $CrewScriptPath, 'up', '-Path', $root)
  if ($dry) { $argv += '-DryRun' }
  $lines = [Collections.Generic.List[string]]::new()
  $selfJob = $null
  $marker = Get-SelfPaneMarker
  $savedUpAllChild = $env:CREWLINE_UP_ALL_CHILD
  try {
    $env:CREWLINE_UP_ALL_CHILD = '1'
    & $shell @argv 2>&1 | ForEach-Object {
      $l = "$_" -replace "\x1b\[[0-9;]*m", ''
      if ($l.StartsWith($marker)) { $selfJob = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($l.Substring($marker.Length))) | ConvertFrom-Json -AsHashtable; return }
      $lines.Add($l); Write-Host "  $l"
    }
    $code = $LASTEXITCODE
  } catch { $lines.Add("không chạy được pwsh ($shell): $($_.Exception.Message)"); $code = 1 }
  finally { $env:CREWLINE_UP_ALL_CHILD = $savedUpAllChild }
  @{ Code = [int]$code; Text = ($lines -join "`n"); SelfJob = $selfJob }
}

function Invoke-UpAll {
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Die "$($reg.Error) — không khôi phục, không ghi đè sổ. Sửa hoặc xóa file đó rồi chạy lại." }
  $current = try { Get-MainRoot (Resolve-Path $Path).Path } catch { $null }
  if ($current -and -not (Test-Path -LiteralPath (Join-Path $current '.crew/config.json') -PathType Leaf)) { $current = $null }
  $plan = Get-UpAllPlan $reg.Map $current
  if (-not $plan.Count) { Say 'sổ chưa có project nào, thư mục hiện tại cũng chưa init: không có gì để khôi phục.'; exit 0 }
  # Hỏi một lần ở đây vì tiến trình con không đọc được stdin; lưu toàn máy nên đủ cho mọi project.
  $noIdentity = @($plan | Where-Object { -not $_.Skip -and (Get-GitIdentityError $_.Root) } | Select-Object -First 1)
  if ($noIdentity.Count) { Confirm-GitIdentity $noIdentity[0].Root $false ([bool]$DryRun) }
  $selfJob = $null
  $rows = @(foreach ($p in $plan) {
      if ($p.Skip) { @{ Name = $p.Name; Root = $p.Root; Result = 'bỏ qua'; Note = $p.Skip }; continue }
      Write-Host "== $($p.Name) ($($p.Root))"
      $r = Invoke-UpChild $p.Root ([bool]$DryRun)
      if ($r.SelfJob) { $selfJob = $r.SelfJob }
      $result = Get-UpChildResult $r.Code $r.Text
      $note = if ($result -eq 'lỗi') { "exit $($r.Code), xem output ở trên" } else { '' }
      @{ Name = $p.Name; Root = $p.Root; Result = $result; Note = $note }
    })
  Write-Host "== tổng kết crew up -All$(if ($DryRun) { ' (DryRun: không ghi, không bật, không gửi)' })"
  Format-UpAllSummary $rows | ForEach-Object { Write-Host "  $_" }
  if ($selfJob) { Invoke-SelfPaneHandoff $selfJob }
  if (@($rows | Where-Object { $_.Result -in 'lỗi', 'cần người quyết' }).Count) { exit 1 }
  exit 0
}
