# ---------------- limits ----------------
# Ngưỡng limit — chỗ DUY NHẤT đặt số. Xếp từ cao xuống; dưới mọi ngưỡng là 'ok'.
function Get-LimitTiers {
  return @(
    @{ Min = 90; Level = 'dừng'; Note = 'dừng' },
    @{ Min = 70; Level = 'hạn chế'; Note = 'hạn chế task L' },
    @{ Min = 50; Level = 'theo dõi'; Note = 'theo dõi' }
  )
}
# % tuần không vào mốc; từ ngưỡng này chỉ cảnh báo (báo chủ dự án trước khi giao), không tự chặn.
function Get-LimitWeekWarn { return 90 }
function Get-LimitLevel([int]$used) {
  foreach ($t in (Get-LimitTiers)) { if ($used -ge $t.Min) { return $t.Level } }
  return 'ok'
}

# Tách % limit đã dùng từ chữ màn hình. Codex: '5h 100% left · weekly 71% left' (dùng = 100 - left).
# Claude (status line riêng của người dùng): '5h 13% · week 24%' (đã là % dùng). Lấy lần xuất hiện cuối (chân màn hình).
function Get-LimitInfo([string]$screen) {
  function Find-Used([string]$text, [string]$label) {
    $ms = [regex]::Matches($text, "(?<![\w])$label\s+(\d{1,3})%(\s+left)?")
    if (-not $ms.Count) { return $null }
    $m = $ms[$ms.Count - 1]; $n = [int]$m.Groups[1].Value
    if ($n -gt 100) { return $null }
    if ($m.Groups[2].Success) { return 100 - $n }
    return $n
  }
  $five = Find-Used "$screen" '5h'
  $week = Find-Used "$screen" '(?:weekly|week)'
  # Mốc chỉ theo 5h; tuần chỉ bật cờ cảnh báo.
  $level = if ($null -eq $five) { 'không rõ' } else { Get-LimitLevel $five }
  $warn = $null -ne $week -and $week -ge (Get-LimitWeekWarn)
  return @{ FiveHour = $five; Week = $week; Level = $level; WeekWarn = $warn }
}

# Limit tính theo tài khoản agent, không theo pane: pane chạy mà đọc không được ('không rõ', vd chân màn hình bị cắt '…')
# lấy số của pane đầu tiên cùng agent đọc được, ghi From = tên pane đó. Hàm thuần, không gọi hc.
# Vào: mỗi dòng @{ Name; Agent; Live; Info } (Info = kết quả Get-LimitInfo, $null nếu tắt). Ra: thêm Shown (Info hiển thị) và From.
function Resolve-LimitRows($rows) {
  $out = @()
  foreach ($r in @($rows)) {
    $row = @{} + $r; $row.From = $null; $row.Shown = $r.Info
    if ($r.Live -and (-not $r.Info -or $r.Info.Level -eq 'không rõ')) {
      $src = @($rows | Where-Object { $_.Agent -eq $r.Agent -and $_.Name -ne $r.Name -and $_.Live -and $_.Info -and $_.Info.Level -ne 'không rõ' }) | Select-Object -First 1
      if ($src) {
        # Mượn nguyên Info (gồm WeekWarn); pane tự đọc được tuần ≥ngưỡng thì vẫn giữ cảnh báo.
        $row.Shown = @{} + $src.Info; $row.From = $src.Name
        if ($r.Info -and $r.Info.WeekWarn) { $row.Shown.WeekWarn = $true }
      }
    }
    $out += $row
  }
  return , $out
}

# ---- số limit trực tiếp từ CLI agent. Phản hồi thô có thể chứa email/gói tài khoản: chỉ giữ % và giờ reset, không in/ghi. ----
# % hợp lệ từ JSON: chỉ nhận kiểu số trong 0–100 (chuỗi, bool, null ⇒ $null). Số lẻ làm tròn.
function ConvertTo-LimitPercent($value) {
  if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) { return $null }
  if ($value -lt 0 -or $value -gt 100) { return $null }
  return [int][math]::Round([double]$value, [MidpointRounding]::AwayFromZero)
}

# Epoch giây ⇒ giờ địa phương gọn: cùng ngày 'HH:mm', khác ngày 'dd/MM HH:mm'. Sai kiểu/ngoài khoảng ⇒ $null.
function Format-LimitEpoch($epoch, [datetime]$now = (Get-Date)) {
  if ($epoch -isnot [int] -and $epoch -isnot [long]) { return $null }
  if ($epoch -le 0) { return $null }
  try { $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToLocalTime().DateTime } catch { return $null }
  $fmt = if ($at.Date -eq $now.Date) { 'HH:mm' } else { 'dd/MM HH:mm' }
  return $at.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
}

# Bước hội thoại JSON-RPC của `codex app-server`, thuần. Chỉ gửi initialize / initialized / account/rateLimits/read; không thread/turn nên không gọi model.
function Get-CodexLimitHello { '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"crew_limits","title":"crew","version":"0"}}}' }
function Get-CodexLimitStep([string]$line) {
  $msg = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { return @{ Write = @(); Done = $false } }
  # Bỏ qua thông báo và request từ server (có method), kể cả khi trùng id.
  if ($msg -isnot [pscustomobject] -or $msg.PSObject.Properties.Name -contains 'method' -or $msg.PSObject.Properties.Name -notcontains 'id') { return @{ Write = @(); Done = $false } }
  if ($msg.id -eq 1) {
    if ($msg.PSObject.Properties.Name -contains 'error') { return @{ Write = @(); Done = $true } }
    return @{ Write = @('{"method":"initialized"}', '{"method":"account/rateLimits/read","id":2}'); Done = $false }
  }
  if ($msg.id -eq 2) { return @{ Write = @(); Done = $true } }
  return @{ Write = @(); Done = $false }
}

# Tách phản hồi id=2 của Codex, thuần. Lấy cửa sổ theo windowDurationMins (300 = 5h, 10080 = tuần), không đoán theo primary/secondary.
function ConvertFrom-CodexLimitReply([string[]]$lines, [datetime]$now = (Get-Date)) {
  foreach ($line in @($lines)) {
    $msg = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    if ($msg -isnot [pscustomobject]) { continue }
    $names = $msg.PSObject.Properties.Name
    if ($names -notcontains 'id' -or $msg.id -ne 2 -or $names -contains 'method') { continue }
    if ($names -contains 'error' -or $names -notcontains 'result') { return $null }
    $result = $msg.result
    if ($result -isnot [pscustomobject]) { return $null }
    $limits = $result.rateLimits
    if ($limits -isnot [pscustomobject]) { return $null }
    $five = $null; $week = $null
    foreach ($w in @($limits.primary, $limits.secondary)) {
      if ($w -isnot [pscustomobject]) { return $null }
      if ($w.windowDurationMins -eq 300) { $five = $w } elseif ($w.windowDurationMins -eq 10080) { $week = $w }
    }
    if (-not $five -or -not $week) { return $null }
    $fiveUsed = ConvertTo-LimitPercent $five.usedPercent
    $weekUsed = ConvertTo-LimitPercent $week.usedPercent
    if ($null -eq $fiveUsed -or $null -eq $weekUsed) { return $null }
    return @{ FiveHour = $fiveUsed; Week = $weekUsed; FiveHourReset = (Format-LimitEpoch $five.resetsAt $now); WeekReset = (Format-LimitEpoch $week.resetsAt $now) }
  }
  return $null
}

# Tách văn bản /usage của Claude, thuần. Mỗi nhãn phải đúng một dòng khớp từ đầu dòng; không phụ thuộc ký tự '·' (console có thể làm hỏng).
# Giờ reset giữ như CLI in, bỏ múi giờ; có thể thiếu khi cửa sổ chưa bắt đầu. Thiếu số ⇒ $null.
function ConvertFrom-ClaudeUsageText([string]$text) {
  function Find-Window([string[]]$lines, [string]$label) {
    $hits = @($lines | ForEach-Object { [regex]::Match($_, "^\s*$label\s*:\s*(\d{1,3})\s*%\s*used\b(.*)$") } | Where-Object { $_.Success })
    if ($hits.Count -ne 1) { return $null }
    $used = [int]$hits[0].Groups[1].Value
    if ($used -gt 100) { return $null }
    $reset = $null
    $m = [regex]::Match($hits[0].Groups[2].Value, '\bresets\s+(.+?)\s*$')
    if ($m.Success) {
      $t = ($m.Groups[1].Value -replace '\s*\([^)]*\)\s*$', '').Trim()
      # Chỉ giữ thứ trông như giờ; chuỗi lạ không vào bảng.
      if ($t.Length -le 24 -and $t -match '\d' -and $t -notmatch '@') { $reset = $t }
    }
    return @{ Used = $used; Reset = $reset }
  }
  $lines = @("$text" -split '\r?\n')
  $five = Find-Window $lines 'Current session'
  $week = Find-Window $lines 'Current week\s*\(all models\)'
  if (-not $five -or -not $week) { return $null }
  return @{ FiveHour = $five.Used; Week = $week.Used; FiveHourReset = $five.Reset; WeekReset = $week.Reset }
}

# Tách stdout JSON của `claude -p /usage --output-format json`, thuần. Báo lỗi hoặc đã có lượt model (num_turns > 0) ⇒ $null: chữ model viết không phải số thật.
function ConvertFrom-ClaudeUsageReply([string[]]$lines) {
  $msg = try { (@($lines) -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { $null }
  if ($msg -isnot [pscustomobject]) { return $null }
  $names = $msg.PSObject.Properties.Name
  if ($names -notcontains 'result' -or $msg.result -isnot [string]) { return $null }
  if ($names -contains 'is_error' -and $msg.is_error -ne $false) { return $null }
  if ($names -contains 'num_turns' -and $msg.num_turns -ne 0) { return $null }
  return ConvertFrom-ClaudeUsageText $msg.result
}

# Dựng lệnh gọi CLI, thuần. Shim npm trên Windows (.ps1/.cmd/.bat) phải chạy qua pwsh; còn lại gọi thẳng (Unix chạy shebang).
function Get-LimitCliInvocation([string]$source, [string[]]$cliArgs, [string]$os = (Get-CrewOS), [string]$shell = ((Get-Process -Id $PID).Path)) {
  if ($os -ne 'windows' -or [IO.Path]::GetExtension($source) -notin '.ps1', '.cmd', '.bat') { return @{ File = $source; ArgList = @($cliArgs) } }
  $call = "[Console]::InputEncoding=[Console]::OutputEncoding=`$OutputEncoding=[Text.UTF8Encoding]::new(`$false); & '$($source.Replace("'", "''"))'"
  foreach ($a in @($cliArgs)) { $call += " '$($a.Replace("'", "''"))'" }
  return @{ File = $shell; ArgList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $call) }
}

# Tìm CLI trên PATH hiện tại; chỉ nhận file thực thi, không nhận alias/hàm. Thiếu ⇒ $null.
function Find-LimitCli([string]$name) {
  $c = Get-Command $name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# Thư mục làm việc rỗng, CỐ ĐỊNH và của riêng user. Không dùng thư mục tạm mới mỗi lần: Claude tạo một thư mục trong ~/.claude/projects cho mỗi cwd (đã đo),
# gọi nhiều sẽ tích rác. Không dùng tên cố định trong /tmp chung: user khác có thể đặt sẵn file cấu hình.
function Get-LimitCwd { Join-Path $HOME '.crewline/limits-cwd' }

# Chạy CLI trong $Cwd, đọc stdout bằng UTF-8, không quá hạn và luôn kill cả cây tiến trình khi xong.
# $OnLine (nếu có) nhận từng dòng, trả @{ Write; Done }. Stdin đóng ngay khi không có $OnLine. Ra: @{ Started; TimedOut; Killed; ExitCode; Lines }. Không ném lỗi.
function Invoke-LimitProcess($invocation, [string[]]$send = @(), [scriptblock]$OnLine = $null, [string]$Cwd, [int]$TimeoutMs = 12000) {
  $res = @{ Started = $false; TimedOut = $false; Killed = $false; ExitCode = $null; Lines = @() }
  $p = $null
  $lines = [Collections.Generic.List[string]]::new()
  try {
    $null = New-Item -ItemType Directory -Path $Cwd -Force -ErrorAction Stop
    $psi = [Diagnostics.ProcessStartInfo]::new($invocation.File)
    foreach ($a in @($invocation.ArgList)) { $psi.ArgumentList.Add([string]$a) }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $Cwd
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = $utf8; $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    # Không để tiến trình con kế thừa phiên agent/pane đang gọi crew.
    foreach ($v in 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN', 'HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET', 'HC_SCOPE') { $null = $psi.Environment.Remove($v) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $res.Started = $true
    $null = $p.StandardError.ReadToEndAsync()  # xả stderr để không kẹt pipe; không dùng nội dung
    foreach ($l in @($send)) { $p.StandardInput.WriteLine($l) }
    $p.StandardInput.Flush()
    if (-not $OnLine) { $p.StandardInput.Close() }
    $read = $null; $done = $false
    while (-not $done) {
      $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
      if ($left -le 0) { $res.TimedOut = $true; break }
      if (-not $read) { $read = $p.StandardOutput.ReadLineAsync() }
      if (-not $read.Wait([math]::Min($left, 200))) { continue }
      $line = $read.Result; $read = $null
      if ($null -eq $line) { break }
      $lines.Add($line)
      if ($OnLine) {
        $step = & $OnLine $line
        foreach ($l in @($step.Write)) { $p.StandardInput.WriteLine($l) }
        $p.StandardInput.Flush()
        if ($step.Done) { $done = $true }
      }
    }
    if (-not $done -and -not $res.TimedOut) {
      $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
      if ($left -le 0 -or -not $p.WaitForExit($left)) { $res.TimedOut = $true } else { $res.ExitCode = $p.ExitCode }
    }
  }
  catch { $res.ExitCode = $null }
  finally {
    if ($p) {
      try { if (-not $p.HasExited) { $p.Kill($true); $res.Killed = $true; $null = $p.WaitForExit(2000) } } catch {}
    }
  }
  $res.Lines = $lines.ToArray()
  return $res
}

# Việc chạm ngoài hàm thuần, tiêm được cho test: tìm CLI + chạy tiến trình.
function New-LimitOps {
  return @{
    Find = { param($name) Find-LimitCli $name }
    Run = { param($invocation, $send, $onLine) Invoke-LimitProcess $invocation $send $onLine (Get-LimitCwd) }
  }
}

function Get-CodexLiveLimit($Ops) {
  try {
    $src = & $Ops.Find 'codex'
    if (-not $src) { return $null }
    $inv = Get-LimitCliInvocation $src @('app-server')
    $r = & $Ops.Run $inv @(Get-CodexLimitHello) { param($line) Get-CodexLimitStep $line }
    if (-not $r -or $r.TimedOut) { return $null }
    return ConvertFrom-CodexLimitReply $r.Lines
  }
  catch { return $null }
}

function Get-ClaudeLiveLimit($Ops) {
  try {
    $src = & $Ops.Find 'claude'
    if (-not $src) { return $null }
    $inv = Get-LimitCliInvocation $src @('-p', '/usage', '--output-format', 'json', '--no-session-persistence')
    $r = & $Ops.Run $inv @() $null
    if (-not $r -or $r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    return ConvertFrom-ClaudeUsageReply $r.Lines
  }
  catch { return $null }
}

# Số trực tiếp ⇒ cùng dạng Info của Get-LimitInfo, thêm giờ reset. Mốc và cảnh báo tuần dùng chung ngưỡng.
function ConvertTo-LimitInfo($liveLimit) {
  return @{
    FiveHour = $liveLimit.FiveHour; Week = $liveLimit.Week; FiveHourReset = $liveLimit.FiveHourReset; WeekReset = $liveLimit.WeekReset
    Level = (Get-LimitLevel $liveLimit.FiveHour); WeekWarn = ($liveLimit.Week -ge (Get-LimitWeekWarn))
  }
}

function Invoke-Limits($Ops = (New-LimitOps)) {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $rows = @()
  if ($cfg.planner -ne 'none') { $rows += @{ Name = "$slug-planner"; Agent = $cfg.planner } }
  $wi = 0
  foreach ($kind in @($cfg.workers)) { $wi++; $rows += @{ Name = "$slug-w$wi"; Agent = $kind } }
  if ($cfg.rev -ne 'none') { $rows += @{ Name = "$slug-rev"; Agent = $cfg.rev } }
  $liveTerms = try { @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) } catch { Say "cảnh báo: $($_.Exception.Message) — không đọc được terminal nào."; @() }
  $foreign = @()
  foreach ($r in $rows) {
    $term = $liveTerms | Where-Object { $_.name -eq $r.Name } | Select-Object -First 1
    $r.Live = $null -ne $term
    $why = if ($r.Live) { Get-ForeignTermError $r.Name $term $root } else { '' }
    if ($why) { $foreign += $why; $r.Live = $false }
    $r.Different = $false
    if ($r.Live) {
      $app = (Get-TermStatus $term).App
      if (-not $app) { $app = $term.agent }
      $actual = if ($app -eq 'claude-code') { 'claude' } elseif ($app -eq 'codex') { 'codex' } else { $null }
      if ($actual -and $actual -ne $r.Agent) { $r.Agent = $actual; $r.Different = $true }
    }
  }
  # Mỗi loại agent thực tế chỉ hỏi một lần; pane tắt dùng config.
  $liveByAgent = @{}
  foreach ($agent in @($rows | ForEach-Object { $_.Agent } | Select-Object -Unique)) {
    if ($agent -eq 'codex') { $liveByAgent[$agent] = Get-CodexLiveLimit $Ops }
    elseif ($agent -eq 'claude') { $liveByAgent[$agent] = Get-ClaudeLiveLimit $Ops }
  }
  foreach ($r in $rows) {
    $direct = $liveByAgent[$r.Agent]
    $r.Direct = [bool]$direct
    $r.Info = if (-not $r.Live) { $null }
    elseif ($direct) { ConvertTo-LimitInfo $direct }
    else { Get-LimitInfo ((hc read $r.Name --lines 6 2>$null) -join "`n") }
  }
  $fmt = '{0,-18} {1,-7} {2,-8} {3,-10} {4,-9} {5,-15} {6}'
  $marks = @((Get-LimitTiers) | Sort-Object { $_.Min } | ForEach-Object { "$($_.Min)% $($_.Note)" }) -join ' · '
  Write-Host "== limits crew:$slug  (mốc 5h: $marks; tuần ≥$(Get-LimitWeekWarn)% cảnh báo)"
  $warned = @()
  Write-Host ($fmt -f 'terminal', 'agent', '5h dùng', 'tuần dùng', 'mốc', 'reset 5h', 'task')
  foreach ($r in (Resolve-LimitRows $rows)) {
    $task = ($tasks | Where-Object { $_.terminal -eq $r.Name } | ForEach-Object { $_.name }) -join ','
    if (-not $task) { $task = '-' }
    if (-not $r.Live) { Write-Host ($fmt -f $r.Name, $r.Agent, '-', '-', 'tắt', '-', $task); continue }
    $i = $r.Shown
    $p5 = if ($i -and $null -ne $i.FiveHour) { "$($i.FiveHour)%" } else { '?' }
    $pw = if ($i -and $null -ne $i.Week) { "$($i.Week)%" } else { '?' }
    $lv = if ($i) { $i.Level } else { 'không rõ' }
    $reset = if ($i -and $i.FiveHourReset) { $i.FiveHourReset } else { '-' }
    $note = ''
    if (-not $r.Direct) {
      $hasNumber = $i -and ($null -ne $i.FiveHour -or $null -ne $i.Week)
      $note = if ($hasNumber) { ' (màn hình, có thể cũ)' } else { ' (không hỏi được, màn hình không có số)' }
      if ($r.From) { $note += " (theo $($r.From))" }
    }
    if ($i -and $i.WeekWarn) { $lv = "$lv ⚠"; $warned += "$($r.Name) ($($r.Agent)): tuần $pw" }
    $agentLabel = if ($r.Different) { "$($r.Agent)*" } else { $r.Agent }
    $line = ($fmt -f $r.Name, $agentLabel, $p5, $pw, $lv, $reset, $task) + $note
    if ($i -and $i.WeekWarn) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
  }
  if (@($rows | Where-Object { $_.Different }).Count) { Write-Host '* khác config' }
  foreach ($w in $warned) { Write-Host "⚠ tuần ≥$(Get-LimitWeekWarn)%: $w — báo chủ dự án trước khi giao cho agent này." -ForegroundColor Yellow }
  $failed = @($liveByAgent.Keys | Where-Object { -not $liveByAgent[$_] } | Sort-Object)
  if ($failed.Count) { Write-Host "Không hỏi được số trực tiếp từ: $($failed -join ', ') (thiếu CLI, chưa đăng nhập, hoặc đổi format)." }
  Write-Host 'Số hỏi trực tiếp từ Codex/Claude, không tốn token; không hỏi được thì lấy từ màn hình, có thể cũ. Limit tính theo tài khoản: mọi pane cùng agent dùng chung số. Mốc chỉ theo 5h; tuần chỉ cảnh báo.'
  foreach ($w in $foreign) { Write-Host "crew: CẢNH BÁO: $w (hiện 'tắt', không đọc số)" -ForegroundColor Yellow }
}
