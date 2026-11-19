# Phạm vi dùng cùng cú pháp với scripts/check.ps1; thiếu dòng khác với dòng rỗng.
function Get-PromptScope([string]$promptText) {
  $line = [regex]::Match($promptText, '(?m)^Được sửa:[^\r\n]*')
  if (-not $line.Success) { return $null }
  $scope = @([regex]::Matches($line.Value, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') })
  return ,([string[]]$scope)
}

function Get-ScopeConflicts([string]$root, $tasks, [string[]]$scope, [string]$exceptName = '') {
  $conflicts = @()
  $rules = @($scope | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Where-Object { $_ -and $_ -notlike 'context/tasks/*' })
  if (-not $rules.Count) { return ,$conflicts }
  foreach ($task in @($tasks)) {
    if ($task.name -eq $exceptName) { continue }
    if ($null -ne $task.PSObject.Properties['scope']) { $oldScope = @($task.scope) }
    else {
      if (-not $task.worktree) { continue }
      $wt = $task.worktree
      if (-not [IO.Path]::IsPathRooted($wt)) { $wt = Join-Path $root $wt }
      $file = Join-Path $wt '.crew/prompt.md'
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
      $oldScope = Get-PromptScope (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    }
    $oldScope = @($oldScope | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') })
    $pairs = @()
    foreach ($a in $rules) {
      foreach ($b in $oldScope) {
        if (-not $b -or $b -like 'context/tasks/*') { continue }
        $same = $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
        $prefix = ($a.EndsWith('/') -and $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) -or
          ($b.EndsWith('/') -and $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase))
        $wild = ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($a) -and $b -like $a) -or
          ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($b) -and $a -like $b)
        if ($same -or $prefix -or $wild) { $pairs += "$a ~ $b" }
      }
    }
    if ($pairs.Count) { $conflicts += @{ Task = $task.name; Pairs = @($pairs | Select-Object -Unique) } }
  }
  return ,$conflicts
}

# ---------------- task ----------------
# Bản ghi task trong .crew/tasks.json. $review rỗng ⇒ không ghi khóa review (mức lấy theo HOT/config).
function New-TaskRecord([string]$name, [string]$branch, [string]$wt, [int]$worker, [string]$term, [string]$kind, [string]$review) {
  $rec = [ordered]@{ name = $name; branch = $branch; worktree = $wt; worker = $worker; terminal = $term; agent = $kind; created = (Get-Date -Format s); doneTracking = $true }
  if ($review) { $rec.review = $review }
  [pscustomobject]$rec
}

# Hàm thuần: terminal worker đang ở trạng thái nào so với agent theo config.
# Ra @{ Mode = 'dead'|'blocked'|'shell'|'agent'|'wrong'; App }.
function Get-WorkerMode($info, [string]$kind) {
  $plan = Get-SendPlan $info $null
  $app = (Get-TermStatus $info).App
  if ($plan -in 'dead', 'blocked') { return @{ Mode = $plan; App = $app } }
  if (-not $app) { return @{ Mode = 'shell'; App = $null } }
  $want = @{ claude = 'claude-code'; codex = 'codex' }[$kind]
  @{ Mode = $(if ($app -eq $want) { 'agent' } else { 'wrong' }); App = $app }
}

# Hàm thuần: phiên mới đã sẵn sàng sau /clear (claude) hoặc /new (codex)? $screen = chữ màn hình (hc read).
# Mọi hộp thoại trên màn hình (kể cả hộp chọn của /new) ⇒ chưa sẵn sàng, dù marker sẵn sàng cũng có mặt.
# Codex: thấy 'Context 100% left'.
# Claude: idle, có dòng lịch sử '❯ /clear' (lệnh đã chạy) và SAU nó là ô nhập trống '❯'. /clear còn kẹt ở ô nhập thì
# '❯ /clear' là dòng prompt cuối (không có ô trống sau), thường kèm menu gợi ý '/clear  Clear …'.
function Test-SessionReady([string]$kind, $info, [string]$screen) {
  $st = Get-TermStatus $info
  if ($st.State -in 'working', 'blocked') { return $false }
  if (Get-ScreenDialog $screen) { return $false }
  if ($kind -eq 'codex') { return $screen -match 'Context 100% left' }
  $lines = @("$screen" -split '\r?\n')
  $cmd = -1; $empty = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*[❯>]\s*/clear\s*$') { $cmd = $i }
    elseif ($lines[$i] -match '^\s*[❯>]\s*$') { $empty = $i }
  }
  if ($cmd -lt 0 -or $empty -lt $cmd) { return $false }
  return -not (@($lines[$cmd..($lines.Count - 1)]) -match '^\s*/clear\s{2,}\S').Count
}

# Chỉ quan sát terminal vừa bật, tối đa 20s; không gửi hay bấm phím.
function Show-StartupTrust($roles, $ops) {
  $pending = @($roles); $trust = @()
  for ($i = 0; $i -le 10 -and $pending.Count; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $next = @()
    foreach ($role in $pending) {
      $info = & $ops.Get $role.Term
      $dlg = Get-ScreenDialog (& $ops.Read $role.Term)
      if ($dlg -eq 'trust') { $trust += $role; continue }
      if ($dlg) { continue }
      $st = Get-TermStatus $info
      $want = @{ claude = 'claude-code'; codex = 'codex' }[$role.Kind]
      if ($info -and $info.state -eq 'live' -and $st.App -eq $want -and $st.State -eq 'idle') { continue }
      $next += $role
    }
    $pending = $next
  }
  if (-not $trust.Count) { return }
  Say 'Chờ bạn bấm "trust thư mục" (crew không tự bấm):'
  foreach ($role in $trust) {
    $keys = if ($role.Kind -eq 'claude') { 'down enter' } else { 'enter' }
    $hint = if ($role.Kind -eq 'claude') { '↓ rồi Enter' } else { 'Enter' }
    Say ("  {0}  {1,-6}  vào pane: {2,-12} (hoặc: hc keys {0} {3})" -f $role.Term, $role.Kind, $hint, $keys)
  }
  Say 'Trust một lần cho mỗi thư mục; lần sau không hỏi lại.'
}

# Hàm thuần: ô nhập thường ở cuối màn hình, nhận theo khung đã thấy thật. Không chắc ⇒ $null.
# Claude: ─── / ❯ chữ / ─── rồi chân (bypass permissions on, …). Codex: › chữ (dòng nối thụt 2, có thể thêm ≤3 dòng trống cuối ô), dòng trống, chân GPT-… hoặc Context N% left.
# Ra @{ Kind = 'claude'|'codex'; Text = chữ trong ô ('' nếu trống/placeholder); Lines = các dòng của ô (chỉ Codex); After = các dòng dưới ô chưa rõ là gì }.
function Get-InputBox([string]$screen) {
  $lines = @("$screen" -split '\r?\n' | Where-Object { $_ -notmatch '^\[hc\]' } | ForEach-Object { $_.TrimEnd() })
  $n = $lines.Count - 1
  while ($n -ge 0 -and -not $lines[$n]) { $n-- }
  if ($n -lt 2) { return $null }
  # Codex: dòng phụ dưới chân chỉ nhận các dạng đã thấy
  $f = $n
  if ($lines[$f] -match '^\s*(\? for shortcuts|tab to queue message)') { $f-- }
  if ($f -ge 2 -and $lines[$f] -match '^\s*GPT-\S+\s.*·|·\s*Context \d+% left' -and -not $lines[$f - 1]) {
    # Enter của hc send lúc Codex bận có thể thành xuống dòng trong ô: tối đa 3 dòng trống cuối ô, không tính vào Lines
    $i = $f - 2; $text = @(); $gap = 0
    while ($i -ge 0 -and $gap -lt 3 -and -not $lines[$i]) { $i--; $gap++ }
    while ($i -ge 0 -and $f - $i -le 30 -and $lines[$i] -match '^\s{2,}\S' -and $lines[$i] -notmatch '^\s*›') { $text = @($lines[$i].Trim()) + $text; $i-- }
    if ($i -ge 0 -and $f - $i -le 30 -and $lines[$i] -match '^\s*›(\s|$)' -and $lines[$i] -notmatch '^\s*›\s*\d+\.\s') {
      $rows = @(($lines[$i] -replace '^\s*›\s*', '')) + $text
      $joined = ($rows -join ' ').Trim()
      if ($joined -eq 'Ask Codex to do anything') { $joined = ''; $rows = @() }
      return @{ Kind = 'codex'; Text = $joined; Lines = @($rows); After = '' }
    }
    return $null
  }
  # Claude: đường kẻ đóng trong vài dòng cuối, có chân thật bên dưới, đường kẻ mở phía trên
  for ($c = $n; $c -ge 0 -and $n - $c -le 6; $c--) { if ($lines[$c] -match '^\s*─{8,}$') { break } }
  if ($c -lt 1 -or $n - $c -gt 6 -or $c -eq $n) { return $null }
  $after = @($lines[($c + 1)..$n])
  if (-not (@($after) -match '(accept edits|bypass permissions|auto mode|plan mode) on|shift\+tab to cycle|\? for shortcuts').Count) { return $null }
  for ($o = $c - 1; $o -ge 0 -and $c - $o -le 30; $o--) { if ($lines[$o] -match '^\s*─{8,}$') { break } }
  if ($o -lt 0 -or $c - $o -gt 30 -or $c - $o -lt 2) { return $null }
  if ($lines[$o + 1] -notmatch '^\s*[>❯](\s|$)' -or $lines[$o + 1] -match '^\s*[>❯]\s*\d+\.\s') { return $null }
  $inner = (@($lines[($o + 1)..($c - 1)]) -join ' ') -replace '^\s*[>❯]\s*', ''
  @{ Kind = 'claude'; Text = $inner.Trim(); After = ($after -join "`n") }
}

# Hàm thuần: màn hình đang có hộp thoại? 'codex-new' = ĐÚNG hộp chọn của Codex /new với dòng 1 đang chọn (an toàn để Enter);
# 'trust' = trust thư mục; 'other' = hộp khác (duyệt lệnh/quyền, …) — không bao giờ bấm; '' = không thấy hộp.
# Hộp lạ thắng: chỉ trả 'codex-new' khi bỏ các dòng của hộp chọn đi, phần còn lại KHÔNG còn dấu hiệu hộp nào.
# Cuối màn hình đúng là ô nhập thường (Get-InputBox) ⇒ chữ phía trên là lịch sử, không phải hộp; không chắc ⇒ quét cả màn hình như cũ.
function Get-ScreenDialog([string]$screen) {
  $marks = 'Where should the new conversation run', 'Do you want to', 'Allow command', '(?m)^\s*Allow\b', '\(y/n\)', 'enter select',
    'esc back', 'Esc to cancel', '(?m)^\s*[›❯]\s*\d+\.\s', 'Yes, proceed'
  $hasMark = { param($t) foreach ($m in $marks) { if ($t -match $m) { return $true } } $false }
  $s = "$screen"
  $box = Get-InputBox $s
  if ($box -and -not (& $hasMark $box.After)) { return '' }
  $claudeTrust = $s -match 'Yes, I trust this folder'
  $codexTrust = $s -match 'Trust this folder\?' -and $s -match 'Trust and continue'
  if ($claudeTrust -or $codexTrust) {
    $own = if ($claudeTrust) {
      @('^\s*Quick safety check:.*$', '^\s*[›❯]?\s*No, exit\s*$', '^\s*[›❯]?\s*Yes, I trust this folder\s*$', '^\s*Enter to confirm · Esc to cancel\s*$')
    } else {
      @('^\s*Trust this folder\?.*$', '^\s*[›❯]?\s*1\. Trust and continue\s*$', '^\s*2\. Quit\s*$', '^\s*enter continue · esc quit\s*$')
    }
    $rest = @($s -split '\r?\n' | Where-Object { $l = $_; -not @($own | Where-Object { $l -match $_ }).Count }) -join "`n"
    if (& $hasMark $rest) { return 'other' }
    return 'trust'
  }
  if ($s -match '(?m)^\s*Where should the new conversation run\?\s*$' -and $s -match '(?m)^\s*›\s*1\. Use current Git worktree') {
    $own = '^\s*Where should the new conversation run\?\s*$', '^\s*›\s*1\. Use current Git worktree\b', '^\s+2\. Create new Git worktree\b',
      '^\s*enter select · esc back\s*$'
    $rest = @($s -split '\r?\n' | Where-Object { $l = $_; -not @($own | Where-Object { $l -match $_ }).Count }) -join "`n"
    if (& $hasMark $rest) { return 'other' }
    return 'codex-new'
  }
  if (& $hasMark $s) { return 'other' }
  ''
}

function Get-TaskLine([string]$wt, [string]$branch) {
  "Bạn là worker. Đọc context/roles/worker.md, rồi làm đúng file $([IO.Path]::Combine($wt, '.crew', 'prompt.md')). Thư mục làm việc: $wt (nhánh $branch); mọi lệnh chạy trong thư mục này."
}

# Phần git của crew task trên worktree cố định: kiểm sạch, tạo crew/<tên> từ nhánh chính, chép prompt. Lỗi ⇒ throw.
function Initialize-TaskBranch([string]$root, [int]$n, [string]$main, [string]$name, [string]$promptPath) {
  $wt = Initialize-WorkerTree $root $n $main
  $st = Invoke-GitQuiet -C $wt status --porcelain
  if ($st.Code -ne 0) { throw "không đọc được git status của w$n ($wt): $($st.Text)" }
  if ($st.Text) { throw "w$n còn thay đổi chưa commit: $(Format-DirtyFiles $st.Text) — commit/bỏ thay đổi trong $wt rồi giao lại." }
  Say "git -C $wt switch -c crew/$name $main"
  $r = Invoke-GitQuiet -C $wt switch -q -c "crew/$name" $main
  if ($r.Code -ne 0) { throw "tạo nhánh crew/$name trong w$n thất bại: $($r.Text)" }
  New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
  Copy-Item -LiteralPath $promptPath (Join-Path $wt '.crew/prompt.md') -Force
  $wt
}

# Gửi việc vào terminal worker qua Invoke-SendFlow (luồng an toàn của crew send). Trả @{ Ok; Message }.
# agent ⇒ /clear | /new, chờ phiên mới, rồi dòng giao việc. shell ⇒ bật agent trong worktree với dòng giao việc.
function Send-WorkerTask([string]$term, [string]$kind, [string]$mode, [string]$wt, [string]$line, [string]$access, $ops) {
  if ($mode -eq 'shell') {
    # bật agent thẳng trong shell, không qua Start-Term ⇒ tự tắt gợi ý mờ của Claude Code (xem Start-Term)
    $cmd = "`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; Set-Location -LiteralPath $(Quote $wt); if ((Get-Location).Path -eq $(Quote $wt)) { $(Get-AgentCommand $kind $access $line) } else { Write-Host 'crew: sai thư mục, không bật agent' }"
    return Invoke-SendFlow $term $cmd $ops
  }
  $why = Get-WorkerInputError $term (& $ops.Read $term)
  if ($why) { return @{ Ok = $false; Message = $why } }
  $reset = if ($kind -eq 'codex') { '/new' } else { '/clear' }
  # claude: ~15s để xác nhận /clear; codex: thêm thời gian cho hộp chọn + phiên mới
  $r = Invoke-SendFlow $term $reset $ops $kind $(if ($kind -eq 'codex') { 10 } else { 7 })
  if (-not $r.Ok) { return @{ Ok = $false; Message = "$reset chưa xong, chưa giao việc: $($r.Message)" } }
  # đọc lại màn hình ngay trước khi gửi dòng giao việc: có hộp thoại ⇒ không gửi
  $screen = & $ops.Read $term
  $why = Get-WorkerInputError $term $screen
  if ($why) { return @{ Ok = $false; Message = $why } }
  if (Get-ScreenDialog $screen) {
    return @{ Ok = $false; Message = "$term hiện hộp thoại sau $reset — chưa giao việc, không bấm phím; xem: hc read $term --lines 20" }
  }
  Invoke-SendFlow $term $line $ops
}

# Lõi crew task (không Die, lỗi ⇒ throw): kiểm terminal TRƯỚC khi đụng git, tạo nhánh + prompt, ghi tasks.json, gửi việc.
# $tasks = danh sách task đã gồm bản ghi mới. Trả @{ Ok; Message; Line } của bước gửi.
function Start-WorkerTask([string]$root, [string]$main, [int]$n, [string]$kind, [string]$access, [string]$term, [string]$name, [string]$promptPath, $tasks, $ops) {
  $info = & $ops.Get $term
  $foreign = Get-ForeignTermError $term $info $root
  if ($foreign) { throw "$foreign Chưa giao việc." }
  $m = Get-WorkerMode $info $kind
  switch ($m.Mode) {
    'dead' { throw "không thấy terminal $term đang chạy — chạy 'crew up' trước." }
    'blocked' { throw "$term đang chờ duyệt — chủ dự án xử lý trước, không giao việc." }
    'wrong' { throw "$term đang chạy $($m.App), config w$n là $kind — chạy 'crew up -Restart w$n' để bật lại đúng agent." }
  }
  # Phiên vừa mở lại chưa có lượt mới thì hc có thể chưa báo app: đừng gõ lệnh shell vào ô nhập của agent.
  $mode = $m.Mode
  if ($mode -eq 'shell' -and (Test-AgentScreen $kind (& $ops.Read $term))) { $mode = 'agent' }
  if ($mode -eq 'agent') {
    $why = Get-WorkerInputError $term (& $ops.Read $term)
    if ($why) { throw $why }
  }
  $wt = Initialize-TaskBranch $root $n $main $name $promptPath
  # Thêm bản ghi vào tasks.json hiện tại dưới khóa (không ghi đè bằng danh sách đọc từ trước — lệnh song song có thể vừa đổi).
  $rec = @($tasks | Where-Object { $_ -and $_.name -eq $name })[-1]
  $null = Update-Tasks $root {
    param($current)
    $taken = @($current | Where-Object { $_.name -eq $name -or [int]$_.worker -eq [int]$rec.worker })
    if ($taken.Count) { throw "vừa có task $($taken[0].name) (w$($taken[0].worker)) do lệnh khác giao — chưa giao $name; nhánh crew/$name đã tạo trong $wt." }
    @($current) + $rec
  }
  $line = Get-TaskLine $wt "crew/$name"
  if ($mode -eq 'shell') { Say "bật $kind trong $term" } else { Say "phiên mới cho $kind trong $term" }
  $r = Send-WorkerTask $term $kind $mode $wt $line $access $ops
  @{ Ok = $r.Ok; Message = $r.Message; Line = $line }
}

function Invoke-Task {
  $root = Get-MainRoot (Get-Location).Path
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) { Die 'không ở trong project crew' @('cd <project>', 'crew init') }
  if (-not $Name -or -not $PromptFile) { Die "dùng: crew task <tên> <file-prompt> [-Worker N]" 'ghi prompt vào một file rồi chạy, vd. crew task fix-login prompt.md' }
  if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Die "tên task chỉ gồm a-z 0-9 -, tối đa 31 ký tự." "đặt lại tên, vd. crew task fix-login $PromptFile" }
  if (-not (Test-Path $PromptFile)) { Die "không thấy file prompt $PromptFile" "kiểm đường dẫn (tính từ $((Get-Location).Path)) rồi chạy lại crew task $Name <file-prompt>" }
  $promptPath = (Resolve-Path $PromptFile).Path
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint @("crew repair", "crew task $Name $PromptFile") }
  if ($tasks | Where-Object { $_.name -eq $Name }) { Die "đã có task tên $Name." @("đặt tên khác hoặc dọn task cũ khi xong", "crew clean $Name") }

  $n = @($cfg.workers).Count
  $busy = @($tasks | ForEach-Object { [int]$_.worker })
  if ($Worker -eq 0) { $Worker = (1..$n | Where-Object { $busy -notcontains $_ } | Select-Object -First 1) }
  if (-not $Worker) { Die "mọi worker đang bận (số task song song ≤ $n)." @("Dọn task đã xong:", "crew clean <tên>", "Hoặc xếp hàng chờ:", "crew queue $Name $PromptFile") }
  if ($Worker -lt 1 -or $Worker -gt $n) { Die "-Worker phải từ 1 tới $n." "bỏ -Worker (giao worker rảnh) hoặc dùng -Worker 1..$n" }
  if ($busy -contains $Worker) { Die "worker $Worker đang có task." @("Bỏ -Worker để giao worker rảnh hoặc xếp hàng chờ:", "crew queue $Name $PromptFile -Worker $Worker") }
  $kind = @($cfg.workers)[$Worker - 1]; $term = "$slug-w$Worker"
  $wt = Get-WorkerTree $root $Worker; $branch = "crew/$Name"
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$branch").Code -eq 0) { Die "nhánh $branch đã có — đặt tên khác hoặc xóa nhánh cũ." @("git -C '$root' log --oneline -3 $branch", "Chỉ xóa nếu chắc chắn bỏ nhánh:", "git -C '$root' branch -D $branch") }
  $main = Get-MainBranch $root
  $rv = if ($InitParameters.ContainsKey('Review')) { $Review } else { '' }
  $scope = Get-PromptScope (Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8)
  if ($null -eq $scope) { Say 'CẢNH BÁO: prompt không có Được sửa: — không kiểm được trùng file.' }
  $conflicts = Get-ScopeConflicts $root $tasks $scope
  if ($conflicts.Count) {
    $details = @($conflicts | ForEach-Object { "task $($_.Task): $($_.Pairs -join ', ')" }) -join '; '
    if (-not $Force) { Die "trùng file với $details." "đợi task đó xong, hoặc vẫn giao: crew task $Name $PromptFile -Force" }
    Say "CẢNH BÁO: trùng file với $details (-Force vẫn giao)."
  }
  $tasks = @($tasks) + (New-TaskRecord $Name $branch $wt $Worker $term $kind $rv)

  try { $r = Start-WorkerTask $root $main $Worker $kind $cfg.access $term $Name $promptPath $tasks (New-HcOps) }
  catch { Die $_.Exception.Message @('crew hot', 'sửa theo lỗi ở trên', "crew task $Name $PromptFile") }
  if (-not $r.Ok) {
    Die "$($r.Message)`n  Task $Name đã ghi (nhánh $branch, prompt đã chép)." @("Xử lý terminal rồi gửi lại:", "crew send $term `"$($r.Line)`"", "Hoặc bỏ task nếu chắc chắn:", "crew clean $Name -Force")
  }
  Say $r.Message
  Say "task $Name -> $term ($kind), nhánh $branch từ $main trong $wt. Theo dõi: hc wait $term / hc read $term --lines 60"
}
