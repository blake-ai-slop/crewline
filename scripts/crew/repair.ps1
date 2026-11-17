# ---------------- repair ----------------
# Metadata worktree từ `git worktree list --porcelain`: đường dẫn chuẩn hóa -> @{ Branch; Prunable }.
function Get-WorktreeMeta([string]$root) {
  $norm = { param($p) [IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
  $map = @{}; $cur = $null
  foreach ($l in @((Invoke-GitQuiet -C $root worktree list --porcelain).Text -split '\r?\n')) {
    if ($l -like 'worktree *') { $cur = @{ Branch = ''; Prunable = $false }; $map[(& $norm $l.Substring(9))] = $cur }
    elseif ($cur -and $l -like 'branch *') { $cur.Branch = $l.Substring(7) -replace '^refs/heads/', '' }
    elseif ($cur -and $l -like 'prunable*') { $cur.Prunable = $true }
  }
  $map
}

function Get-ResumeLine([string]$name, [string]$wt, [string]$branch) {
  "Bạn là worker. Tiếp tục task $name (bị gián đoạn): đọc context/roles/worker.md, file $([IO.Path]::Combine($wt, '.crew', 'prompt.md')), context/tasks/$name.md nếu có, xem git log và git status; làm tiếp phần còn lại. Thư mục làm việc: $wt (nhánh $branch)."
}

# Dữ liệu git để xét task đã xong (chỉ đọc). Đọc lỗi hoặc worktree không ở nhánh task ⇒ điều kiện đó coi như chưa đạt.
function Get-TaskGitFacts([string]$root, $t, [string]$main) {
  $f = @{ Ahead = 0; Clean = $false; HasNote = $false }
  if (-not $main -or -not $t.branch) { return $f }
  $r = Invoke-GitQuiet -C $root rev-list --count "$main..$($t.branch)"
  if ($r.Code -eq 0) { $f.Ahead = [int]$r.Text }
  $f.HasNote = (Invoke-GitQuiet -C $root cat-file -e "$($t.branch):context/tasks/$($t.name).md").Code -eq 0
  if ($t.worktree -and (Test-Path -LiteralPath $t.worktree)) {
    $on = Invoke-GitQuiet -C $t.worktree branch --show-current
    $st = Invoke-GitQuiet -C $t.worktree status --porcelain
    $f.Clean = $on.Code -eq 0 -and $on.Text -ceq $t.branch -and $st.Code -eq 0 -and -not $st.Text
  }
  $f
}

# Worker xong thì commit cả task note và để worktree sạch (roles/worker.md). Áp dụng cả task đã giao Rev: việc của Rev giao lại riêng qua Get-PendingReview.
# Task đã giao Rev được phép hết commit mới so với main, vì Rev có thể đã merge mà chưa crew clean. Hàm thuần.
function Test-TaskFinished($t, $facts) {
  ([int]$facts.Ahead -ge 1 -or [bool]$t.reviewSentAt) -and $facts.Clean -eq $true -and [bool]$facts.HasNote
}

function Format-TaskFinished([string]$name, [string]$term) {
  "task $name có vẻ đã xong, không giao lại; còn việc thì: crew send $term `"<việc còn lại>`""
}

# Điều kiện giao lại task cho worker vừa bật lại (chỉ đọc, dùng chung DryRun + chạy thật).
# $assumeBranch: nhánh worktree sẽ có sau các bước tạo lại/switch của chính lần repair này (DryRun); rỗng ⇒ đọc git.
# Trả @{ Human = '' | lý do cần người; Line; Pm; Src = prompt nguồn sẽ chép ('' nếu không chép) }.
function Get-ResumeCheck([string]$root, $t, $role, [string]$assumeBranch) {
  $wt = $t.worktree; $line = Get-ResumeLine $t.name $wt $t.branch
  $res = @{ Human = ''; Line = $line; Pm = (Join-Path $wt '.crew/prompt.md'); Src = '' }
  $b = if ($assumeBranch) { $assumeBranch } elseif (Test-Path -LiteralPath $wt) { (Invoke-GitQuiet -C $wt branch --show-current).Text } else { '' }
  if ($b -ne $t.branch) { $res.Human = "$($role.Term) vừa bật lại nhưng $wt không ở $($t.branch) — chưa giao lại task $($t.name)."; return $res }
  $src = Join-Path $root ".crew/prompts/$($t.name).md"
  if (-not (Test-Path -LiteralPath $res.Pm)) {
    if (Test-Path -LiteralPath $src) { $res.Src = $src }
    else { $res.Human = "$wt thiếu .crew/prompt.md — chép prompt của task $($t.name) vào đó rồi: crew send $($role.Term) `"$line`"" }
  }
  $res
}

# Trạng thái một worktree (chỉ đọc): @{ Path; State = 'có'|'mất'|'hỏng'|'lạ'; Branch; Dirty (≤5 file); DirtyCount }.
function Get-TreeState([string]$root, [string]$wt, $meta) {
  $key = [IO.Path]::GetFullPath($wt).TrimEnd('\', '/')
  $m = $meta[$key]; $dir = Test-Path -LiteralPath $wt
  $s = @{ Path = $wt; State = 'có'; Branch = ''; Dirty = @(); DirtyCount = 0 }
  if ($m -and ($m.Prunable -or -not $dir)) { $s.State = 'hỏng'; return $s }
  if (-not $m) { $s.State = $(if ($dir) { 'lạ' } else { 'mất' }); return $s }
  $b = (Invoke-GitQuiet -C $wt branch --show-current).Text
  $s.Branch = if ($b) { $b } else { "(detached $((Invoke-GitQuiet -C $wt rev-parse --short HEAD).Text))" }
  $st = Invoke-GitQuiet -C $wt status --porcelain
  $files = @(if ($st.Text) { (Format-DirtyFiles $st.Text) -split ', ' })
  $s.DirtyCount = $files.Count; $s.Dirty = @($files | Select-Object -First 5)
  $s
}

# Chờ worker vừa bật sẵn sàng nhận tin: agent đúng loại, không working, không hộp thoại. Trả '' khi sẵn sàng, ngược lại lý do.
# Phiên mở lại không có lượt đầu nên hc có thể chưa báo app ⇒ nhận thêm theo chân màn hình TUI (Test-AgentScreen).
function Wait-WorkerReady([string]$term, [string]$kind, $ops, [int]$tries = 30) {
  $why = 'agent chưa sẵn sàng'
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $info = & $ops.Get $term
    $m = Get-WorkerMode $info $kind
    if ($m.Mode -eq 'wrong') { return "$term đang chạy $($m.App), config là $kind" }
    $screen = & $ops.Read $term
    $dlg = Get-ScreenDialog $screen
    if ($dlg -eq 'trust') {
      $hint = if ($kind -eq 'claude') { '↓ rồi Enter' } else { 'Enter' }
      $keys = if ($kind -eq 'claude') { 'down enter' } else { 'enter' }
      return "$term đang chờ trust thư mục — bấm trong pane: $hint (hoặc: hc keys $term $keys)"
    }
    if ($m.Mode -eq 'blocked') { return "$term đang chờ duyệt" }
    if ($dlg) { return "$term đang hiện hộp thoại" }
    if ($m.Mode -eq 'agent' -and (Get-TermStatus $info).State -ne 'working') { return '' }
    if ($m.Mode -eq 'shell' -and (Test-AgentScreen $kind $screen)) { return '' }
    if ($m.Mode -eq 'dead') { $why = "$term không live" }
  }
  $why
}

# Dòng giao Rev (dùng chung crew review + repair): mức review + commit từng nhánh theo đúng thứ tự $tasks.
# Trả @{ Msg; Error } (không Die). $strict = $false (repair): nhánh không còn commit mới so với $main (Rev đã merge
# trước khi bị gián đoạn) ⇒ ghi '(đã merge)' thay cho commit, không coi là lỗi.
function Get-ReviewLine([string]$root, [string]$main, $tasks, [string]$cfgReview, [bool]$strict = $true) {
  $hotFile = Join-Path $root 'context/HOT.md'
  $hot = if (Test-Path $hotFile) { (Get-Content $hotFile -TotalCount 1 -Encoding utf8) -join '' } else { '' }
  $items = @(); $levels = @()
  foreach ($t in @($tasks)) {
    $r = Invoke-GitQuiet -C $root log --format=%h "$main..$($t.branch)"
    if ($r.Code -ne 0) { return @{ Msg = ''; Error = "không đọc được commit của $($t.branch): $($r.Text)" } }
    $commits = @($r.Text -split '\r?\n' | Where-Object { $_ })
    if (-not $commits.Count) {
      if ($strict) { return @{ Msg = ''; Error = "nhánh $($t.branch) không có commit mới so với $main." } }
      $commits = @('đã merge')
    }
    $items += @{ Name = $t.name; Branch = $t.branch; Commits = $commits }
    $levels += Get-ReviewLevel $t $hot $cfgReview
  }
  # các task khác mức ⇒ lấy mức cao nhất (Đủ > Gọn > Nhanh)
  $level = @('Đủ', 'Gọn', 'Nhanh') | Where-Object { $levels -contains $_ } | Select-Object -First 1
  @{ Msg = (Format-ReviewMessage $level $items); Error = '' }
}

# Thao tác git dở trên repo chính (chỉ đọc): @{ Kind = '' | 'merge' | 'rebase' | 'cherry-pick' | 'giải xung đột'; Files (≤5); Count }.
function Get-MainOp([string]$root) {
  $res = @{ Kind = ''; Files = @(); Count = 0 }
  $gd = (Invoke-GitQuiet -C $root rev-parse --absolute-git-dir).Text
  if ($gd -and (Test-Path -LiteralPath $gd)) {
    if (Test-Path -LiteralPath (Join-Path $gd 'MERGE_HEAD')) { $res.Kind = 'merge' }
    elseif ((Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply'))) { $res.Kind = 'rebase' }
    elseif (Test-Path -LiteralPath (Join-Path $gd 'CHERRY_PICK_HEAD')) { $res.Kind = 'cherry-pick' }
  }
  $st = (Invoke-GitQuiet -C $root status --porcelain).Text
  $un = @(@($st -split '\r?\n') | Where-Object { $_ -match '^(DD|AU|UD|UA|DU|AA|UU) ' } | ForEach-Object { $_.Substring(3) })
  if ($un.Count -and -not $res.Kind) { $res.Kind = 'giải xung đột' }
  $res.Count = $un.Count; $res.Files = @($un | Select-Object -First 5)
  $res
}

# Task đang chờ review = còn trong tasks.json, có reviewSentAt, nhánh còn. Thứ tự = thứ tự gửi (reviewSentAt, rồi vị trí).
function Get-PendingReview([string]$root, $tasks) {
  $i = 0
  $list = foreach ($t in @($tasks)) {
    $i++
    if (-not $t.reviewSentAt) { continue }
    if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$($t.branch)").Code -ne 0) { continue }
    [pscustomobject]@{ T = $t; At = [datetime]$t.reviewSentAt; I = $i }
  }
  , @(@($list) | Sort-Object At, I | ForEach-Object { $_.T })
}
