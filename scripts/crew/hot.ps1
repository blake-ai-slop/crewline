function Show-CrewUpgradeWarning([string]$root) {
  $file = Join-Path $root 'context/.skeleton-version'
  if (-not (Test-Path -LiteralPath $file)) { return }
  $n = 0
  if ([int]::TryParse(([IO.File]::ReadAllText($file)).Trim(), [ref]$n)) {
    $m = Get-SkeletonVersion
    if ($n -lt $m) { Write-Host "crew: context v$n cũ hơn crew v$m — chạy crew upgrade -DryRun rồi crew upgrade" -ForegroundColor Yellow }
  }
}

# ---------------- hot ----------------
# hc read/get không có màu/thuộc tính ô nhập: chữ gợi ý có thể giống tin thật.
# Chỉ nhận marker hàng đợi của UI ở ô nhập cuối màn hình; không đoán từ chữ sau ❯/›.
# Tin kẹt: chỉ Codex rảnh, chữ nằm trong ô nhập thật. Claude bỏ qua: hc không phân biệt được gợi ý mờ với chữ thật, và Claude tự đọc tin khi xong lượt.
function Get-StuckText([string]$app, [string]$state, [string]$screen) {
  if ($app -ne 'codex' -or $state -notin 'idle', 'done') { return '' }
  $box = Get-InputBox $screen
  if ($box -and $box.Kind -eq 'codex') { return $box.Text }
  ''
}

function Get-PendingInput([string]$app, [string]$state, [string]$screen) {
  if (Get-StuckText $app $state $screen) { return 'stuck' }
  if ($state -ne 'working') { return '' }
  if ($app -in 'claude', 'claude-code') {
    $boxes = [regex]::Matches($screen, '(?m)^\s*─{8,}\s*\r?\n[>❯]\s*Press up to edit queued messages\s*\r?\n\s*─{8,}\s*$')
    if ($boxes.Count -and $screen.Substring($boxes[$boxes.Count - 1].Index + $boxes[$boxes.Count - 1].Length) -notmatch '(?m)^\s*[>❯›]') { return 'queued' }
  }
  if ($app -eq 'codex') {
    $queue = [regex]::Matches($screen, '(?m)^• Queued follow-up inputs\r?\n  ↳ \S[^\r\n]*\r?\n(?:[^\r\n]*\r?\n)*?    shift\+← edit last queued message\s*\r?\n\s*\r?\n› [^\r\n]*\r?\n\s*\r?\n  GPT-')
    if ($queue.Count -and $screen.Substring($queue[$queue.Count - 1].Index + $queue[$queue.Count - 1].Length) -notmatch '(?m)^› ') { return 'queued' }
  }
  return ''
}

function Get-HotWarnings([string]$root, $cfg, $tasks, $terminals, $pending = @{}) {
  foreach ($name in @($pending.Keys | Sort-Object)) {
    if ($pending[$name] -eq 'stuck') { "${name}: tin kẹt ở ô nhập — sang pane ${name}: Enter để gửi hoặc xóa chữ" }
    elseif ($pending[$name] -eq 'queued') { "${name}: có tin chờ, agent đọc khi xong lượt" }
  }
  $status = Invoke-GitQuiet -C $root status --porcelain
  $branch = (Invoke-GitQuiet -C $root branch --show-current).Text
  $merge = Invoke-GitQuiet -C $root rev-parse --git-path MERGE_HEAD
  $mergePath = if ([IO.Path]::IsPathRooted($merge.Text)) { $merge.Text } else { Join-Path $root $merge.Text }
  if (($status.Code -eq 0 -and $status.Text) -or ($merge.Code -eq 0 -and (Test-Path -LiteralPath $mergePath))) {
    "main (nhánh chính ở root: $branch) có thay đổi chưa commit hoặc merge dở."
  }
  $parent = Join-Path $root '.crew/worktrees'
  if (Test-Path -LiteralPath $parent) {
    foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory -Force) {
      if ($dir.Name -notmatch '^w(\d+)$') { continue }
      $workerNumber = [int]$Matches[1]
      if (@($tasks | Where-Object { [int]$_.worker -eq $workerNumber }).Count) { continue }
      $dirty = Invoke-GitQuiet -C $dir.FullName status --porcelain
      if ($dirty.Code -eq 0 -and $dirty.Text) { "$($dir.Name) bẩn mà không có task: $($dir.FullName)" }
    }
  }
  $slug = Get-CrewName $root $cfg
  $crewNames = '^' + [regex]::Escape($slug) + '-(planner|w\d+|rev)$'
  foreach ($term in @($terminals)) {
    # Pane tự mở chạy shell thường không phải agent (hc ls ghi agent = tên chương trình).
    if ($term -and -not $term.name -and "$($term.agent)" -match '^(?i)(pwsh|powershell)(\.exe)?$') { continue }
    if ($term -and $term.cwd -and $null -ne $term.agent -and $term.name -notmatch $crewNames -and (Test-SamePath $term.cwd $root)) {
      "agent ở root trong terminal '$($term.name)' không thuộc crew — có thể có planner thứ hai."
    }
  }
  if (Get-CopySource $root $cfg) { 'project là bản chép (bản sao) của crew còn tồn tại; chạy crew init -Name <tên mới>.' }
  else { $clash = Get-NameConflict $root $cfg; if ($clash) { $clash } }
}

function Invoke-Hot {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  Show-CrewUpgradeWarning $root
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Write-Host "crew: CẢNH BÁO: $($mv.Hint)" -ForegroundColor Yellow }
  Write-Host "== crew:$slug  review=$($cfg.review) access=$($cfg.access) planner=$($cfg.planner) workers=$($cfg.workers -join ',') rev=$($cfg.rev)"
  Write-Host "== git worktree list"; git -C $root worktree list
  Write-Host "== terminal"
  $terminals = try { @(Get-LiveTerminals) } catch { Write-Host "crew: CẢNH BÁO: $($_.Exception.Message) — không liệt kê được terminal." -ForegroundColor Yellow; @() }
  try {
    . (Join-Path $CrewScriptsDir 'lint.ps1')
    $lint = @(Get-ContextLint $root)
    if ($lint.Count) { Write-Host "crew: context: $($lint.Count) cảnh báo — chạy crew lint" -ForegroundColor Yellow }
  } catch { }
  $roleKinds = @{ "$slug-planner" = @{ Kind = $cfg.planner; Role = 'planner' }; "$slug-rev" = @{ Kind = $cfg.rev; Role = 'rev' } }
  $roleIndex = 0
  foreach ($kind in @($cfg.workers)) { $roleIndex++; $roleKinds["$slug-w$roleIndex"] = @{ Kind = $kind; Role = "w$roleIndex" } }
  $foreign = @(); $pending = @{}; $wrongAgents = @()
  $terminals | Where-Object { $_.name -like "$slug-*" } |
    ForEach-Object {
      $why = Get-ForeignTermError $_.name $_ $root
      if ($why) { $foreign += $why; return ("{0,-18} {1,-5} {2,-9} {3}" -f $_.name, $_.address, 'KHÁC PROJECT', $_.cwd) }
      $role = $roleKinds[$_.name]
      if ($_.state -eq 'live' -and $role) {
        $mode = Get-WorkerMode $_ $role.Kind
        if ($mode.Mode -eq 'wrong') { $wrongAgents += "crew: CẢNH BÁO: $($_.name) đang chạy $($mode.App), config là $($role.Kind) — crew up -Restart $($role.Role)" }
      }
      $st = Get-TermStatus $_
      $status = if ($_.status) { $_.status } else { '-' }
      $app = if ($st.App) { $st.App } else { $_.agent }
      if ($_.state -eq 'live' -and $app -in 'claude', 'claude-code', 'codex') {
        $screen = & (New-HcOps).Read $_.name
        $dialog = Get-ScreenDialog $screen
        if ($dialog -eq 'trust' -and $st.State -in 'idle', 'blocked') { $status = 'chờ trust' }
        elseif (-not $dialog) {
          # Chỉ marker UI đang chạy, không lấy lời kể về lệnh nền trong hội thoại.
          $background = if ($app -eq 'codex') {
            $screen -match '(?m)^\s*• (?:Waiting for background terminal(?:[^\r\n]*)|Working[^\r\n]*· [1-9]\d* background terminals? running(?:[^\r\n]*))\r?$' -or
              $screen -match '(?m)^\s*[1-9]\d* background terminals? running · /ps to view(?:[^\r\n]*)\r?$'
          } else {
            $screen -match '(?m)^\s*(?:⏵⏵|⏸)[^\r\n]*permissions on[^\r\n]*· [1-9]\d* (?:background tasks?|shells?|bash)(?: ·[^\r\n]*)?\s*$' -or
              $screen -match '(?m)^\s*[↓·] [1-9]\d* background tasks? running(?:\s*·[^\r\n]*)?\s*$'
          }
          if ($background -and $st.State -in 'idle', 'done', 'working') { $status = 'working (nền)' }
          $inputState = Get-PendingInput $app $(if ($background) { 'working' } else { $st.State }) $screen
          if ($inputState) {
            $pending[$_.name] = $inputState
            if (-not $background) { $status = if ($inputState -eq 'queued') { 'tin chờ' } else { 'tin kẹt' } }
          }
        }
      }
      "{0,-18} {1,-5} {2,-9} {3}" -f $_.name, $_.address, $status, $_.agent
    } | Write-Host
  foreach ($w in $wrongAgents) { Write-Host $w -ForegroundColor Yellow }
  foreach ($w in $foreign) { Write-Host "crew: CẢNH BÁO: $w" -ForegroundColor Yellow }
  $tasks = Get-Tasks $root
  Write-Host "== worker (worktree cố định)"
  $wi = 0
  foreach ($kind in @($cfg.workers)) {
    $wi++; $wt = Get-WorkerTree $root $wi
    $at = if (-not (Test-Path -LiteralPath $wt)) { '(chưa có — crew up/task sẽ tạo)' } else {
      $b = (Invoke-GitQuiet -C $wt branch --show-current).Text
      if ($b) { $b } else { "(detached $((Invoke-GitQuiet -C $wt rev-parse --short HEAD).Text))" }
    }
    $tn = @($tasks | Where-Object { [int]$_.worker -eq $wi } | ForEach-Object { $_.name }) -join ','
    "{0,-4} {1,-6} {2} {3} task={4}" -f "w$wi", $kind, $wt, $at, $(if ($tn) { $tn } else { '-' }) | Write-Host
  }
  Write-Host "== task"
  if (-not $tasks.Count) { Write-Host '(không có)' } else {
    $hotMain = (Invoke-GitQuiet -C $root branch --show-current).Text
    foreach ($t in $tasks) {
      $ahead = (Invoke-GitQuiet -C $root rev-list --count "HEAD..$($t.branch)").Text
      $rv = if ($t.review) { " review=$($t.review)" } else { '' }
      $doneMark = if (-not $t.reviewSentAt -and (Test-TaskFinished $t (Get-TaskGitFacts $root $t $hotMain))) { ' — đã xong, chờ planner' } else { '' }
      ("{0,-20} w{1} {2,-6} {3} (+{4} commit) {5}" -f $t.name, $t.worker, $t.agent, $t.branch, $ahead, $t.worktree) + $rv + $doneMark | Write-Host
    }
  }
  # Mỗi cặp chỉ báo một lần, theo thứ tự trong tasks.json.
  for ($i = 0; $i -lt $tasks.Count - 1; $i++) {
    $t = $tasks[$i]
    if (-not $t.worktree) { continue }
    $wt = $t.worktree
    if (-not [IO.Path]::IsPathRooted($wt)) { $wt = Join-Path $root $wt }
    $prompt = Join-Path $wt '.crew/prompt.md'
    if (-not (Test-Path -LiteralPath $prompt -PathType Leaf)) { continue }
    $scope = Get-PromptScope (Get-Content -LiteralPath $prompt -Raw -Encoding UTF8)
    foreach ($conflict in (Get-ScopeConflicts $root $tasks[($i + 1)..($tasks.Count - 1)] $scope $t.name)) {
      Write-Host "crew: CẢNH BÁO: task $($t.name) và $($conflict.Task) trùng file: $($conflict.Pairs -join ', ')" -ForegroundColor Yellow
    }
  }
  $warnings = @(Get-HotWarnings $root $cfg $tasks $terminals $pending)
  if ($warnings.Count) {
    Write-Host '== Cảnh báo' -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "- $warning" -ForegroundColor Yellow }
  }
  $queue = try { Get-QueueItems $root } catch { @() }
  if ($queue.Count) { Write-Host "== hàng đợi: $($queue.Count) ($(@($queue | ForEach-Object { $_.name }) -join ', '))" }
}
