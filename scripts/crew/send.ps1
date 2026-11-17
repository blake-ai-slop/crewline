# ---------------- send / review ----------------
# Trạng thái terminal: `hc get --json` trả status = {app; state}, `hc ls` trả chuỗi. Ra @{ App; State }.
function Get-TermStatus($info) {
  $st = if ($info) { $info.status } else { $null }
  if ($st -is [string]) { return @{ App = $null; State = $st } }
  if ($st) { return @{ App = $st.app; State = $st.state } }
  return @{ App = $null; State = $null }
}

# Hàm thuần quyết định bước gửi (không gọi hc). $info = object `hc get`; $result = object `hc send --json`
# ($null = chưa gửi); $turnBefore = turn trước khi gửi (-1 = không rõ).
# Ra: 'dead' | 'blocked' | 'send' (chưa gửi, gửi được) | 'ok' | 'press-enter'.
function Get-SendPlan($info, $result, [int]$turnBefore = -1) {
  if (-not $info -or $info.state -ne 'live') { return 'dead' }
  $st = Get-TermStatus $info
  if ($st.State -eq 'blocked') { return 'blocked' }
  if ($null -eq $result) { return 'send' }
  # shell không báo working/turn: hc send thành công là xong
  if (-not $st.App) { return 'ok' }
  if ($result.started -eq $true -or $st.State -eq 'working') { return 'ok' }
  if ($turnBefore -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turnBefore) { return 'ok' }
  return 'press-enter'
}

function Get-TermInfo([string]$term) {
  $out = & { $ErrorActionPreference = 'Continue'; hc get $term --json 2>$null }
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  try { return (@($out) -join "`n") | ConvertFrom-Json } catch { return $null }
}

# Các lệnh hc thật mà Invoke-SendFlow dùng. Test tiêm bảng giả cùng khóa (Get/Send/Keys/Read/Sleep), không gọi hc.
# Send($term, $text, $raw): $raw = gửi trần, không bọc <hc from=…>.
function New-HcOps {
  @{
    Get   = { param($term) Get-TermInfo $term }
    Send  = {
      param($term, $text, $raw)
      $saved = @{ Id = $env:HC_TERMINAL_ID; Socket = $env:HC_TERMINAL_SOCKET }
      try {
        # gửi từ pane agent thì hc bọc <hc from=…> ⇒ shell ParserError, /clear|/new thành câu chat; $raw ⇒ để trống 2 biến chỉ cho lệnh này
        if ($raw) { $env:HC_TERMINAL_ID = $null; $env:HC_TERMINAL_SOCKET = $null }
        $out = & { $ErrorActionPreference = 'Continue'; hc send $term $text --json 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
      } finally { $env:HC_TERMINAL_ID = $saved.Id; $env:HC_TERMINAL_SOCKET = $saved.Socket }
      @{ Code = $code; Text = (@($out) -join "`n").Trim() }
    }
    Keys  = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term enter 2>&1 } | Out-Null }
    Tab   = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term tab 2>&1 } | Out-Null }
    Read  = { param($term) (@(& { $ErrorActionPreference = 'Continue'; hc read $term --lines 15 2>$null }) -join "`n") }
    Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
  }
}

# Codex đang working: Enter của hc send có lúc bị nuốt, tin nằm ở ô nhập dù hc báo started:true (đo thật 2026-11-02, codex-cli 0.166).
# Hàm thuần: ô nhập có ĐÚNG và CHỈ tin vừa gửi? Chỉ bỏ qua khoảng trắng tại chỗ xuống dòng của TUI, phân biệt hoa thường.
# $bare = tin gửi trần ⇒ không chấp nhận vỏ <hc from=…>; tin thường có thể có hoặc không có vỏ (hc chỉ bọc khi gửi từ pane agent), vỏ chỉ bỏ một lớp bọc kín cả ô.
function Test-SentInput([string[]]$lines, [string]$text, [bool]$bare = $false) {
  $want = "$text".Trim()
  if (-not $want -or -not @($lines).Count) { return $false }
  $same = {
    param($part)
    $want -cmatch ('^' + (@($part -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*') + '$')
  }
  $raw = @($lines) -join "`n"
  if (& $same $raw) { return $true }
  if ($bare) { return $false }
  $m = [regex]::Match($raw, '^<hc\s+from="[^"]*">(.*)</hc>$', 'Singleline')
  $m.Success -and (& $same $m.Groups[1].Value)
}

# Ô nhập đúng và chỉ có tin vừa gửi (Test-SentInput) ⇒ Tab 1 lần để vào hàng đợi thật của Codex: Tab gửi cả ô, nên chữ thêm, chữ sửa, bản nháp cùng đầu tin ⇒ không bấm.
# Đọc lại màn hình + trạng thái ngay trước phím; không live, không phải Codex, hết working, blocked, hộp thoại ⇒ không bấm.
function Send-CodexQueue([string]$term, [string]$text, $ops, [bool]$bare = $false) {
  $unsure = @{ Ok = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin có thể nằm lại ô nhập, xem crew hot" }
  if (-not $ops.Read -or -not $ops.Tab) { return $unsure }
  & $ops.Sleep 700
  $screen = & $ops.Read $term
  $info = & $ops.Get $term
  $st = Get-TermStatus $info
  if (-not $info -or $info.state -ne 'live' -or $st.App -ne 'codex' -or $st.State -ne 'working' -or (Get-ScreenDialog $screen)) { return $unsure }
  $box = Get-InputBox $screen
  if (-not $box -or $box.Kind -ne 'codex') { return $unsure }
  if (-not $box.Text) { return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: Codex đang bận đã nhận tin khỏi ô nhập (xem: crew hot)" } }
  if (-not (Test-SentInput $box.Lines $text $bare)) { return $unsure }
  & $ops.Tab $term
  for ($i = 0; $i -lt 3; $i++) {
    & $ops.Sleep 500
    $after = Get-InputBox (& $ops.Read $term)
    if ($after -and $after.Kind -eq 'codex' -and -not $after.Text) {
      return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: tin vào hàng đợi của Codex, chạy khi xong lượt (xem: crew hot)" }
    }
  }
  $unsure
}

# Điều phối gửi tin (không Die, không in): trả @{ Ok; Message }.
# Đọc lại hc get NGAY SAU send và NGAY TRƯỚC MỖI lần Enter; blocked/dead ⇒ dừng, không Enter (Enter có thể duyệt hộ hộp duyệt).
# $session = 'claude'|'codex' khi gửi /clear|/new: chỉ coi là xong khi Test-SessionReady (đọc màn hình qua $ops.Read);
# agent đang chạy lệnh thì chờ, không Enter. Màn hình có hộp thoại: ĐÚNG hộp chọn Codex /new ⇒ Enter 1 lần (chọn worktree
# hiện tại), hộp khác ⇒ dừng, không Enter. $tries = số vòng chờ ~2s.
# Gửi trần (không bọc <hc from>) khi: terminal là shell, tin là lệnh slash ('/…'), hoặc $raw.
function Invoke-SendFlow([string]$term, [string]$text, $ops, [string]$session = '', [int]$tries = 6, [bool]$raw = $false) {
  $fail = { param($m) @{ Ok = $false; Message = $m } }
  $info = & $ops.Get $term
  switch (Get-SendPlan $info $null) {
    'dead' { return & $fail "terminal $term không live (hc get không thấy hoặc đã tắt)." }
    'blocked' { return & $fail "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." }
  }
  $st0 = Get-TermStatus $info
  $bare = $raw -or (-not $st0.App) -or $text.StartsWith('/')
  # agent đang chạy lượt TRƯỚC khi gửi (tin thường): tin nằm chờ trong ô nhập, agent đọc khi xong lượt ⇒ báo rõ, không Enter thêm
  $busy = (-not $session) -and $st0.App -and $st0.State -eq 'working'
  $turn = if ($null -ne $info.turn) { [int]$info.turn } else { -1 }
  $r = & $ops.Send $term $text $bare
  if ($r.Code -ne 0) { return & $fail "hc send tới $term thất bại: $($r.Text)" }
  $result = try { $r.Text | ConvertFrom-Json } catch { [pscustomobject]@{ started = $null } }
  $verdict = {
    param($plan, $info)
    switch ($plan) {
      'ok' {
        $s = Get-TermStatus $info
        # chỉ còn chờ khi vẫn working cùng lượt và chưa bấm Enter; turn tăng/đã Enter/hết working ⇒ agent đã nhận hoặc rảnh, báo như cũ
        $newTurn = $turn -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turn
        if ($busy -and $s.State -eq 'working' -and $enter -eq 0 -and -not $newTurn) {
          if ($s.App -eq 'codex') { return Send-CodexQueue $term $text $ops $bare }
          return @{ Ok = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin nằm chờ, agent đọc khi xong lượt (xem: crew hot)" }
        }
        return @{ Ok = $true; Message = "đã gửi -> $term ($(if ($s.App) { $s.State } else { 'shell' }))" }
      }
      'dead' { return & $fail "terminal $term tắt sau khi gửi." }
      'blocked' { return & $fail "đã gửi tới $term nhưng nó đang chờ duyệt — chủ dự án xử lý (không bấm Enter)." }
      'dialog' { return & $fail "$term đang hiện một hộp thoại lạ sau '$text' — không bấm phím; xem: hc read $term --lines 20" }
    }
    $null
  }
  # kế hoạch sau gửi; chế độ phiên mới: 'ok' chỉ khi phiên mới sẵn sàng, agent đang chạy ⇒ 'wait' (không Enter);
  # màn hình đọc lại mỗi lần, hộp thoại xét TRƯỚC mọi kiểm sẵn sàng: hộp lạ ⇒ 'dialog' (dừng, 0 Enter);
  # hộp chọn Codex /new ⇒ 'pick' (1 lần, sau đó 'wait'). Tin thường: chỉ đọc màn hình ngay trước Enter (có $ops.Read).
  $picked = 0
  $judge = {
    param($info)
    $plan = Get-SendPlan $info $result $turn
    if (-not $session) {
      if ($plan -eq 'press-enter' -and $ops.Read -and (Get-ScreenDialog (& $ops.Read $term))) { return 'dialog' }
      return $plan
    }
    if ($plan -notin 'ok', 'press-enter') { return $plan }
    $screen = & $ops.Read $term
    $dlg = Get-ScreenDialog $screen
    if ($dlg -eq 'codex-new' -and $session -eq 'codex') { if ($picked -ge 1) { return 'wait' } return 'pick' }
    if ($dlg) { return 'dialog' }
    if (Test-SessionReady $session $info $screen) { return 'ok' }
    if ($result.started -eq $true -or (Get-TermStatus $info).State -eq 'working') { return 'wait' }
    'press-enter'
  }
  # tin kẹt ở ô nhập ⇒ Enter (tối đa 2 lần); tổng ≤ ~15s (mặc định 6 vòng)
  $enter = 0
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -eq 'wait' -or ($plan -eq 'press-enter' -and $enter -ge 2)) { continue }
    $want = $plan
    & $ops.Sleep 700
    # đọc lại trạng thái + màn hình NGAY TRƯỚC phím: vẫn đúng kế hoạch cũ mới bấm
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -ne $want) { continue }
    & $ops.Keys $term
    if ($plan -eq 'pick') { $picked++; continue }
    $enter++
    $result = [pscustomobject]@{ started = $false }
  }
  if ($session) {
    $what = if ($session -eq 'codex') { "phiên mới ('Context 100% left')" } else { "màn hình đã xóa ('❯ /clear' rồi ô nhập trống)" }
    return & $fail "chưa xác nhận được $what sau '$text' tới $term (~$(2 * $tries)s); xem: hc read $term --lines 20"
  }
  & $fail "đã gửi tới $term nhưng agent chưa chạy (vẫn $((Get-TermStatus $info).State)); xem: hc read $term --lines 20"
}

# Gửi tin tới terminal, dùng chung cho crew send/review. Lỗi ⇒ Die (exit 1). Agent bận ⇒ in báo tin nằm chờ (exit 0).
# $root khác rỗng ⇒ terminal live phải thuộc project đó (Get-ForeignTermError), sai chủ ⇒ Die trước khi gửi.
# $ops: bảng hc (test tiêm bảng giả); $null ⇒ New-HcOps.
function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false, [string]$root = '', $ops = $null) {
  if (-not $ops) { $ops = New-HcOps }
  if ($root) {
    $why = Get-ForeignTermError $term (& $ops.Get $term) $root
    if ($why) { Die "$why Không gửi." }
  }
  # tin cũ còn ở ô nhập: gửi nữa sẽ dính vào nó, Enter sẽ gửi cả hai ⇒ để người quyết
  $st = Get-TermStatus (& $ops.Get $term)
  if ($ops.Read -and $st.App -eq 'codex' -and $st.State -in 'idle', 'done') {
    $stuck = Get-StuckText $st.App $st.State (& $ops.Read $term)
    if ($stuck) {
      $shown = if ($stuck.Length -gt 200) { $stuck.Substring(0, 200) + '…' } else { $stuck }
      Die "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại."
    }
  }
  $r = Invoke-SendFlow $term $text $ops '' 6 $raw
  if (-not $r.Ok) { Die $r.Message }
  Say $r.Message
}

function Invoke-Send {
  if (-not $Name -or -not $PromptFile) { Die 'dùng: crew send <terminal> "<tin>" [-Raw]' }
  # gọi trong repo crew và terminal mang tên crew này ⇒ kiểm chủ; tên khác / ngoài repo ⇒ gửi như cũ
  $root = Get-MainRoot (Get-Location).Path
  $guard = ''
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    if ($Name -like "$(Get-CrewName $root (Get-Config $root))-*") { $guard = $root }
    if ($guard) { try { $mv = Get-MoveInfo $root (Get-Config $root) } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint } }
  }
  Send-CrewMessage $Name $PromptFile $Raw.IsPresent $guard
}

# Repo chính, kể cả khi gọi từ trong worktree: thư mục cha của git common dir.
function Get-MainRoot([string]$p) {
  $r = Invoke-GitQuiet -C $p rev-parse --path-format=absolute --git-common-dir
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  return (Resolve-Path (Split-Path $r.Text -Parent)).Path
}

# Mức review (chữ Việt) của task: review của task > dòng đầu HOT > config.review > Gọn.
function Get-ReviewLevel($task, [string]$hotText, [string]$cfgReview) {
  $vi = @{ fast = 'Nhanh'; lean = 'Gọn'; full = 'Đủ' }
  if ($task -and $task.review -and $vi.ContainsKey([string]$task.review)) { return $vi[[string]$task.review] }
  if ($hotText -match 'Chế độ review: \*\*(Gọn|Nhanh|Đủ)\*\*') { return $Matches[1] }
  if ($cfgReview -and $vi.ContainsKey($cfgReview)) { return $vi[$cfgReview] }
  return 'Gọn'
}

# Hàm thuần soạn tin giao Rev. $items: mảng @{ Name; Branch; Commits } theo thứ tự merge.
function Format-ReviewMessage([string]$level, $items) {
  $items = @($items)
  $merge = ($items | ForEach-Object { "$($_.Branch) ($(@($_.Commits) -join ','))" }) -join ' rồi '
  $notes = ($items | ForEach-Object { "context/tasks/$($_.Name).md" }) -join ', '
  $clean = ($items | ForEach-Object { "crew clean $($_.Name)" }) -join ', '
  $multi = $items.Count -gt 1
  $order = if ($multi) { ' (đúng thứ tự này)' } else { '' }
  $each = if ($multi) { ' của từng task' } else { '' }
  "Rev ${level}: merge $merge$order. Đọc $notes$each. Full test, $clean, báo planner. Không push."
}

# Hàm thuần: Rev có nhận được tin review không. $info = `hc get` của terminal Rev (đọc 1 lần, 0 phím). Ra lý do, '' = gửi được.
# Không live/chờ duyệt Send-CrewMessage cũng chặn; ở đây thêm gợi ý cách xử lý và áp được cho -DryRun.
# $readScreen: scriptblock trả màn hình Rev, chỉ gọi khi hc báo shell (Rev mở lại phiên chưa báo app ⇒ nhận theo màn hình, như Start-WorkerTask).
function Get-RevGuard($cfg, [string]$term, $info, [scriptblock]$readScreen = $null) {
  if (-not $cfg.rev -or $cfg.rev -eq 'none') { return 'config Rev=none nên không có pane rev để gửi review. Dùng mức review fast (planner tự merge) hoặc đặt rev trong config rồi crew up.' }
  $m = Get-WorkerMode $info $cfg.rev
  switch ($m.Mode) {
    'dead' { return "$term không chạy — chạy crew up rồi gửi lại." }
    'blocked' { return "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." }
    'wrong' { return "rev đang chạy $($m.App), config là $($cfg.rev) — crew up -Restart rev" }
    'shell' { if (-not ($readScreen -and (Test-AgentScreen $cfg.rev (& $readScreen)))) { return 'rev chỉ còn shell — crew up -Restart rev' } }
  }
  ''
}

function Invoke-Review {
  $names = @($NameList)
  if (-not $names.Count) { Die 'dùng: crew review <task>[,<task2>…] [-DryRun]' }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die 'chạy trong repo của crew.' }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $main = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
  if (-not $main) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD)." }
  $sel = @(foreach ($n in $names) {
    $t = $tasks | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $t) { Die "task $n không có trong .crew/tasks.json." }
    $t
  })
  $rl = Get-ReviewLine $root $main $sel $cfg.review
  if ($rl.Error) { Die $rl.Error }
  $revTerm = "$slug-rev"
  $revInfo = if ($cfg.rev -and $cfg.rev -ne 'none') { Get-TermInfo $revTerm } else { $null }
  $why = Get-RevGuard $cfg $revTerm $revInfo { & (New-HcOps).Read $revTerm }
  if ($DryRun) {
    Write-Host $rl.Msg
    if ($why) { Say "cảnh báo: $why" }
    return
  }
  if ($why) { Die "$why Không gửi." }
  Send-CrewMessage $revTerm $rl.Msg $false $root
  # gửi được ⇒ đánh dấu chờ review (crew repair giao lại khi Rev bị đóng giữa chừng); +i ms giữ thứ tự gửi
  $now = [DateTime]::UtcNow
  for ($i = 0; $i -lt $sel.Count; $i++) {
    $sel[$i] | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $now.AddMilliseconds($i).ToString('o') -Force
  }
  Save-Tasks $root $tasks
}
