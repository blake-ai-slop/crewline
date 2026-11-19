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
# Tin dài gói nhiều dòng và có dòng trống cuối ô (Enter bị đổi thành xuống dòng) vẫn nhận qua Get-InputBox; khối queued phía trên không ảnh hưởng.
function Send-CodexQueue([string]$term, [string]$text, $ops, [bool]$bare = $false) {
  $unsure = @{ Ok = $true; Unsure = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin có thể nằm lại ô nhập, xem crew hot" }
  if (-not $ops.Read -or -not $ops.Tab) { return $unsure }
  # tin dài: TUI có thể chưa vẽ xong ô nhập ở lần đọc đầu ⇒ đọc lại tối đa 3 lần; MỖI lần kiểm lại trạng thái + hộp thoại, Tab ngay sau lần đọc khớp
  $match = $false
  for ($k = 0; $k -lt 3 -and -not $match; $k++) {
    & $ops.Sleep $(if ($k) { 500 } else { 700 })
    $screen = & $ops.Read $term
    $info = & $ops.Get $term
    $st = Get-TermStatus $info
    if (-not $info -or $info.state -ne 'live' -or $st.App -ne 'codex' -or $st.State -ne 'working' -or (Get-ScreenDialog $screen)) { return $unsure }
    $box = Get-InputBox $screen
    if ($box -and $box.Kind -eq 'codex' -and -not $box.Text) { return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: Codex đang bận đã nhận tin khỏi ô nhập (xem: crew hot)" } }
    $match = $box -and $box.Kind -eq 'codex' -and (Test-SentInput $box.Lines $text $bare)
  }
  if (-not $match) { return $unsure }
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
  $sent = $false
  $fail = { param($m, $n = '') @{ Ok = $false; Unsure = $sent; Message = $m; Next = $n } }
  $info = & $ops.Get $term
  switch (Get-SendPlan $info $null) {
    'dead' { return & $fail "terminal $term không live (hc get không thấy hoặc đã tắt)." @('crew up', 'gửi lại tin bằng crew send') }
    'blocked' { return & $fail "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." "sang pane $term trả lời hộp chờ duyệt (xem: hc read $term --lines 20), rồi gửi lại" }
  }
  $st0 = Get-TermStatus $info
  $bare = $raw -or (-not $st0.App) -or $text.StartsWith('/')
  # agent đang chạy lượt TRƯỚC khi gửi (tin thường): tin nằm chờ trong ô nhập, agent đọc khi xong lượt ⇒ báo rõ, không Enter thêm
  $busy = (-not $session) -and $st0.App -and $st0.State -eq 'working'
  $turn = if ($null -ne $info.turn) { [int]$info.turn } else { -1 }
  $r = & $ops.Send $term $text $bare
  if ($r.Code -ne 0) { return & $fail "hc send tới $term thất bại: $($r.Text)" "kiểm terminal: hc ls (thiếu thì crew up), rồi gửi lại" }
  $sent = $true
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
        # Codex không chạy lượt mà ô nhập còn chữ ⇒ tin chưa đi (vd. phiên chưa sẵn sàng nuốt mất đầu tin): báo kẹt, không Enter
        if (-not $session -and -not $busy -and $s.App -eq 'codex' -and $s.State -ne 'working' -and $ops.Read) {
          $left = Get-InputBox (& $ops.Read $term)
          if ($left -and $left.Kind -eq 'codex' -and $left.Text) { $seen.Text = $left.Text; return & $verdict 'stuck' $info }
        }
        return @{ Ok = $true; Message = "đã gửi -> $term ($(if ($s.App) { $s.State } else { 'shell' }))" }
      }
      'stuck' {
        $shown = if ($seen.Text.Length -gt 200) { $seen.Text.Substring(0, 200) + '…' } else { $seen.Text }
        return & $fail "đã gửi tới $term nhưng ô nhập Codex còn chữ khác tin vừa gửi: $shown — không bấm Enter. Xử lý: sang pane $term, xóa chữ (hoặc Enter nếu đúng), rồi gửi lại." 'xem mục "Tin kẹt ở ô nhập" trong docs/troubleshooting.md (thư mục cài Crewline)'
      }
      'nobox' { return & $fail "đã gửi tới $term nhưng không nhận ra ô nhập Codex để kiểm tin — không bấm Enter; xem: hc read $term --lines 20" }
      'dead' { return & $fail "terminal $term tắt sau khi gửi." 'crew up (bật lại terminal) rồi gửi lại' }
      'blocked' { return & $fail "đã gửi tới $term nhưng nó đang chờ duyệt — chủ dự án xử lý (không bấm Enter)." "sang pane $term trả lời hộp chờ duyệt (xem: hc read $term --lines 20)" }
      'dialog' { return & $fail "$term đang hiện một hộp thoại lạ sau '$text' — không bấm phím; xem: hc read $term --lines 20" }
    }
    $null
  }
  # kế hoạch sau gửi; chế độ phiên mới: 'ok' chỉ khi phiên mới sẵn sàng, agent đang chạy ⇒ 'wait' (không Enter);
  # màn hình đọc lại mỗi lần, hộp thoại xét TRƯỚC mọi kiểm sẵn sàng: hộp lạ ⇒ 'dialog' (dừng, 0 Enter);
  # hộp chọn Codex /new ⇒ 'pick' (1 lần, sau đó 'wait'). Tin thường: chỉ đọc màn hình ngay trước Enter (có $ops.Read).
  # Codex (tin thường): chỉ Enter khi ô nhập có ĐÚNG tin vừa gửi (Test-SentInput); chữ khác ⇒ 'stuck', ô trống ⇒ 'wait', không nhận ra ô ⇒ 'nobox'.
  $picked = 0
  $seen = @{ Text = '' }
  $judge = {
    param($info)
    $plan = Get-SendPlan $info $result $turn
    if (-not $session) {
      if ($plan -eq 'press-enter' -and $ops.Read) {
        $screen = & $ops.Read $term
        if (Get-ScreenDialog $screen) { return 'dialog' }
        if ((Get-TermStatus $info).App -eq 'codex') {
          $box = Get-InputBox $screen
          if (-not $box -or $box.Kind -ne 'codex') { return 'nobox' }
          if (-not $box.Text) { return 'wait' }
          if (-not (Test-SentInput $box.Lines $text $bare)) { $seen.Text = $box.Text; return 'stuck' }
        }
      }
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
    $what = if ($session -eq 'codex') { "phiên Codex mới trống (đầu phiên '>_ OpenAI Codex', ô nhập trống, không còn tin cũ)" } else { "màn hình đã xóa ('❯ /clear' rồi ô nhập trống)" }
    return & $fail "chưa xác nhận được $what sau '$text' tới $term (~$(2 * $tries)s); xem: hc read $term --lines 20"
  }
  & $fail "đã gửi tới $term nhưng agent chưa chạy (vẫn $((Get-TermStatus $info).State)); xem: hc read $term --lines 20"
}

# Task/repair không được xóa bản nháp khi reset phiên; kiểm ô nhập thật của cả Claude và Codex.
# hc không phân biệt được chữ gợi ý mờ của Claude: giữ ô có chữ để người dùng xử lý trong pane (không tự xóa/ghi đè).
# Pane Claude bật trước bản tắt gợi ý (Start-Term) có thể hiện gợi ý mờ ⇒ câu báo chỉ cách bật lại.
function Get-WorkerInputError([string]$term, [string]$screen) {
  if (Get-ScreenDialog $screen) { return '' }
  $box = Get-InputBox $screen
  if (-not $box -or -not $box.Text) { return '' }
  $shown = if ($box.Text.Length -gt 200) { $box.Text.Substring(0, 200) + '…' } else { $box.Text }
  $msg = "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại."
  if ($box.Kind -eq 'claude') {
    # vai = phần sau '<crew>-' trong tên terminal
    $role = if ($term -match '-(planner|rev|w\d+)$') { $Matches[1] } else { '<vai>' }
    $msg += "`n  Nếu không ai gõ dòng này, đó là gợi ý mờ của Claude Code (pane bật trước bản sửa) — bật lại: crew up -Restart $role (worker có task cần -Force; xem docs/troubleshooting.md mục Gợi ý của Claude)."
  }
  $msg
}

# Gửi tin tới terminal, dùng chung cho crew send/review. Lỗi ⇒ Die (exit 1). Agent bận ⇒ báo tin nằm chờ (exit 0).
# $root khác rỗng ⇒ kiểm chủ project; $ops = $null ⇒ New-HcOps.
function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false, [string]$root = '', $ops = $null, [switch]$PassResult) {
  if (-not $ops) { $ops = New-HcOps }
  if ($root) {
    $why = Get-ForeignTermError $term (& $ops.Get $term) $root
    if ($why) { Die "$why Không gửi." 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
  }
  # tin cũ còn ở ô nhập: gửi nữa sẽ dính vào nó, Enter sẽ gửi cả hai ⇒ để người quyết
  # Codex rảnh: chỉ gửi khi màn hình có ô nhập thật và không có hộp thoại (vừa /new: hộp chọn worktree hoặc phiên chưa vẽ xong
  # ⇒ phím gõ vào hộp, '1' trong '<hc from="t1…' chọn hộ dòng 1). Chờ tối đa ~10s, vẫn chưa ⇒ Die, không gửi.
  $st = Get-TermStatus (& $ops.Get $term)
  for ($w = 0; $ops.Read -and $st.App -eq 'codex' -and $st.State -in 'idle', 'done'; $w++) {
    $screen = & $ops.Read $term
    $dlg = Get-ScreenDialog $screen
    $box = Get-InputBox $screen
    if (-not $dlg -and $box -and $box.Kind -eq 'codex') {
      if ($box.Text) {
        $shown = if ($box.Text.Length -gt 200) { $box.Text.Substring(0, 200) + '…' } else { $box.Text }
        Die "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại." 'xem mục "Tin kẹt ở ô nhập" trong docs/troubleshooting.md (thư mục cài Crewline)'
      }
      break
    }
    if ($w -ge 5) {
      $why = if ($dlg -eq 'codex-new') { "đang mở hộp chọn của /new" } elseif ($dlg) { 'đang hiện hộp thoại' } else { 'chưa hiện ô nhập sẵn sàng' }
      Die "$term $why, chưa gửi (không bấm phím)." "xem: hc read $term --lines 20, xử lý xong rồi gửi lại"
    }
    & $ops.Sleep 2000
    $st = Get-TermStatus (& $ops.Get $term)
  }
  # /new tới Codex, /clear tới Claude: chờ phiên mới như crew task (Test-SessionReady).
  $session = if ($st.App -eq 'codex' -and $text.Trim() -ceq '/new') { 'codex' }
    elseif ($st.App -in 'claude', 'claude-code' -and $text.Trim() -ceq '/clear') { 'claude' } else { '' }
  $r = Invoke-SendFlow $term $text $ops $session $(if ($session) { 10 } else { 6 }) $raw
  if ($PassResult) { return $r }
  if (-not $r.Ok) { Die $r.Message $r.Next }
  Say $r.Message
}

function Invoke-Send {
  if (-not $Name -or -not $PromptFile) { Die 'dùng: crew send <terminal> "<tin>" [-Raw]' @('crew hot', 'crew send <crew>-w1 "tiếp tục"') }
  # gọi trong repo crew và terminal mang tên crew này ⇒ kiểm chủ; tên khác / ngoài repo ⇒ gửi như cũ
  $root = Get-MainRoot (Get-Location).Path
  $guard = ''
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    $cfg = Get-Config $root
    $slug = Get-CrewName $root $cfg
    $roles = @()
    if ($cfg.planner -and $cfg.planner -ne 'none') { $roles += "$slug-planner" }
    for ($i = 1; $i -le @($cfg.workers).Count; $i++) { $roles += "$slug-w$i" }
    if ($cfg.rev -and $cfg.rev -ne 'none') { $roles += "$slug-rev" }
    if ($Name -notin $roles) {
      $target = Get-TermInfo $Name
      if (-not $target -or $target.state -ne 'live') {
        Die "không có terminal $Name trong crew $slug" @("Tên terminal: $($roles -join ', ')", 'crew hot')
      }
    }
    if ($Name -like "$slug-*") { $guard = $root }
    if ($guard) { try { $mv = Get-MoveInfo $root (Get-Config $root) } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint @('crew repair', 'gửi lại tin bằng crew send') } }
  }
  # Chụp người gửi trước khi gửi (-Raw tạm xóa biến HC); không tin tên terminal từ nội dung tin.
  $sender = if ($root -and $env:HC_TERMINAL_ID) { Get-TermInfo $env:HC_TERMINAL_ID } else { $null }
  Send-CrewMessage $Name $PromptFile $Raw.IsPresent $guard
  # Chỉ cập nhật sau khi luồng gửi xác nhận thành công; lỗi gửi không đổi task.
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json')) -and
      $sender -and $sender.state -eq 'live' -and $sender.address -ceq $env:HC_TERMINAL_ID) {
    Update-TaskDone $root $sender.name $Name $PromptFile $Raw.IsPresent (Get-CrewName $root (Get-Config $root))
  }
}

# Chỉ crew send đổi tín hiệu worker xong; review dùng reviewSentAt riêng.
function Update-TaskDone([string]$root, [string]$sender, [string]$target, [string]$text, [bool]$raw, [string]$slug) {
  if (-not $sender) { return }
  $done = $text -match '^XONG'
  $reopen = $sender -ceq "$slug-planner" -and -not $raw -and $text -notmatch '^/'
  if (-not $done -and -not $reopen) { return }
  $current = Get-Tasks $root
  $candidate = @($current | Where-Object { ($done -and $_.terminal -and $sender -ceq $_.terminal) -or ($reopen -and $_.terminal -and $target -ceq $_.terminal -and $_.doneAt) })
  if (-not $candidate.Count) { return }
  Update-Tasks $root { param($tasks)
    foreach ($t in $tasks) {
      if ($done -and $t.terminal -and $sender -ceq $t.terminal) {
        $t | Add-Member -NotePropertyName doneAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
      }
      elseif ($reopen -and $t.terminal -and $target -ceq $t.terminal -and $t.doneAt) {
        $t.PSObject.Properties.Remove('doneAt')
      }
    }
    $tasks
  } | Out-Null
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
  if (-not $names.Count) { Die 'dùng: crew review <task>[,<task2>…] [-DryRun|-Sent]' @('crew hot', 'crew review fix-login') }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die 'chạy trong repo của crew.' @('cd <project>', 'crew init') }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $sel = @(foreach ($n in $names) {
    $t = $tasks | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $t) { Die "không có task tên $n." 'xem tên task đang có: crew hot' }
    $t
  })
  if ($Sent -and $DryRun) { Die '-Sent không đi với -DryRun.' 'chạy: crew review <task> -Sent' }
  $r = $null
  if (-not $Sent) {
    $main = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
    if (-not $main) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD)." @("git -C '$root' switch <nhánh chính>", "crew review <task>") }
    $rl = Get-ReviewLine $root $main $sel $cfg.review
    if ($rl.Error) { Die $rl.Error $rl.Next }
    $revTerm = "$slug-rev"
    $revInfo = if ($cfg.rev -and $cfg.rev -ne 'none') { Get-TermInfo $revTerm } else { $null }
    $why = Get-RevGuard $cfg $revTerm $revInfo { & (New-HcOps).Read $revTerm }
    if ($DryRun) {
      Write-Host $rl.Msg
      if ($why) { Say "cảnh báo: $why" }
      return
    }
    if ($why) { Die "$why Không gửi." "xử lý theo lỗi ở trên rồi chạy lại: crew review $($names -join ',')" }
    $r = Send-CrewMessage $revTerm $rl.Msg $false $root -PassResult
    if ($r -and -not $r.Ok -and -not $r.Unsure) { Die $r.Message $r.Next }
  }
  # gửi được ⇒ đánh dấu chờ review (crew repair giao lại khi Rev bị đóng giữa chừng); +i ms giữ thứ tự gửi
  $now = [DateTime]::UtcNow
  for ($i = 0; $i -lt $sel.Count; $i++) {
    $sel[$i] | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $now.AddMilliseconds($i).ToString('o') -Force
  }
  Update-Tasks $root { param($current)
    foreach ($item in $sel) {
      $found = $current | Where-Object { $_.name -eq $item.name }
      if ($found) {
        $found | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $item.reviewSentAt -Force
        if ($r -and $r.Unsure) { $found | Add-Member -NotePropertyName reviewUnsure -NotePropertyValue $true -Force }
        else { $found.PSObject.Properties.Remove('reviewUnsure') }
      }
    }
    $current
  } | Out-Null
  if ($r -and $r.Unsure) {
    Die "$($r.Message) — chưa chắc Rev đã nhận review $($names -join ',')." @("hc read $revTerm --lines 20", "nếu tin còn nằm ô nhập thì bấm Enter tay rồi: crew review $($names -join ',') -Sent")
  }
  if ($r) { Say $r.Message }
}
