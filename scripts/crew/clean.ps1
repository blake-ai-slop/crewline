# ---------------- clean ----------------

function Test-WorktreeListed([string]$root, [string]$wt) {
  $norm = { param($p) [IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
  $want = & $norm $wt
  foreach ($l in @(git -C $root worktree list --porcelain)) {
    if ($l -like 'worktree *' -and (& $norm $l.Substring(9)) -eq $want) { return $true }
  }
  $false
}

# Phần git của crew clean. Bước git lỗi ⇒ ném lỗi (người gọi giữ bản ghi task). Trả danh sách cảnh báo (vẫn xóa bản ghi).
# Chạy lại an toàn: worktree/nhánh đã mất thì bỏ qua bước đó.
function Remove-TaskGit([string]$root, $task, [bool]$force) {
  $warn = @()
  $wt = $task.worktree
  if (Test-WorktreeListed $root $wt) {
    if (-not (Test-Path $wt)) {
      Say "worktree $wt đã mất thư mục — git worktree prune"
      $r = Invoke-GitQuiet -C $root worktree prune
      if ($r.Code -ne 0) { throw "bước 'git worktree prune' lỗi: $($r.Text)" }
    } else {
      Say "git worktree remove $wt"
      $r = if ($force) { Invoke-GitQuiet -C $root worktree remove --force $wt } else { Invoke-GitQuiet -C $root worktree remove $wt }
      if ($r.Code -ne 0 -and (Test-WorktreeListed $root $wt)) {
        $hint = if ($force) { "sửa nguyên nhân rồi chạy lại crew clean $($task.name) -Force." } else { "commit/bỏ thay đổi trong worktree, hoặc chạy lại crew clean $($task.name) -Force nếu chắc chắn bỏ." }
        throw "bước 'git worktree remove' lỗi: $($r.Text)`n  Cách xử lý: $hint"
      }
    }
  } else { Say "worktree $wt không còn trong git — bỏ qua." }
  if (Test-Path $wt) {
    # chỉ xóa thư mục rỗng; còn file hoặc bị khóa ⇒ cảnh báo, không đụng tiến trình nào
    $empty = -not (Get-ChildItem -LiteralPath $wt -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($empty) { try { Remove-Item -LiteralPath $wt -Force -ErrorAction Stop } catch { } }
    if (Test-Path $wt) { $warn += "thư mục worktree còn sót: $wt (thường do shell/agent đang đứng trong đó giữ khóa). Đóng shell/agent đang đứng trong thư mục đó rồi xóa tay." }
  }
  Remove-TaskBranch $root $task $force
  , $warn
}

# Xóa nhánh crew/<tên> (-d, hoặc -D khi force). Nhánh đã mất ⇒ bỏ qua. Lỗi ⇒ throw.
function Remove-TaskBranch([string]$root, $task, [bool]$force) {
  $b = $task.branch
  $r = Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$b"
  if ($r.Code -ne 0) { Say "nhánh $b không còn — bỏ qua."; return }
  if ((Invoke-GitQuiet -C $root merge-base --is-ancestor $b HEAD).Code -eq 0) {
    $head = Invoke-GitQuiet -C $root rev-parse --short $b
    if ($head.Code -ne 0) { throw "không đọc được HEAD của nhánh $b`: $($head.Text)" }
    Save-DoneTask $root $task.name $head.Text
  }
  Say "git branch $(if ($force) { '-D' } else { '-d' }) $b"
  $r = if ($force) { Invoke-GitQuiet -C $root branch -D $b } else { Invoke-GitQuiet -C $root branch -d $b }
  if ($r.Code -ne 0) { throw "bước 'git branch' lỗi: $($r.Text)`n  Cách xử lý: merge nhánh $b rồi chạy lại crew clean $($task.name), hoặc thêm -Force nếu chắc chắn bỏ." }
}

# Task chạy trên worktree cố định của worker (bản mới) hay worktree riêng .crew/worktrees/<tên-task> (bản cũ)?
function Test-KeepTask([string]$root, $task) {
  if (-not $task.worktree -or -not $task.worker) { return $false }
  $norm = { param($p) [IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
  (& $norm $task.worktree) -eq (& $norm (Get-WorkerTree $root ([int]$task.worker)))
}

# Phần git của crew clean bản mới: KHÔNG xóa thư mục, KHÔNG kill agent. Worktree về detached nhánh chính rồi xóa nhánh.
# Bẩn ⇒ throw (trừ khi force ⇒ switch --discard-changes). Trả danh sách cảnh báo.
function Reset-WorkerTree([string]$root, $task, [string]$main, [bool]$force) {
  $warn = @()
  $wt = $task.worktree
  if (-not (Test-Path -LiteralPath $wt) -or -not (Test-WorktreeListed $root $wt)) {
    $warn += "worktree $wt không còn — bỏ qua bước đưa về $main (crew up/task sẽ tạo lại)."
  } else {
    $st = Invoke-GitQuiet -C $wt status --porcelain
    if ($st.Code -ne 0) { throw "bước 'git status' trong $wt lỗi: $($st.Text)" }
    if ($st.Text -and -not $force) {
      throw "w$($task.worker) còn thay đổi chưa commit: $(Format-DirtyFiles $st.Text)`n  Cách xử lý: commit/bỏ thay đổi trong $wt, hoặc chạy lại crew clean $($task.name) -Force nếu chắc chắn bỏ."
    }
    Say "git -C $wt switch --detach $main$(if ($force) { ' --discard-changes' })"
    $r = if ($force) { Invoke-GitQuiet -C $wt switch -q --detach --discard-changes $main } else { Invoke-GitQuiet -C $wt switch -q --detach $main }
    if ($r.Code -ne 0) { throw "bước 'git switch --detach $main' trong $wt lỗi: $($r.Text)" }
  }
  Remove-TaskBranch $root $task $force
  , $warn
}

function Invoke-Clean {
  if (-not $Name) { Die "thiếu tên task cần dọn." "crew clean <tên> [-Force]" }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die "chạy trong repo của crew." @('cd <project>', 'crew init') }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
  $tasks = Get-Tasks $root; $t = $tasks | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $t) { Die "không có task tên $Name — không dọn." 'xem tên task đang có: crew hot' }

  # kiểm git trước (nhánh đã xóa ở lần chạy trước thì bỏ qua)
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$($t.branch)").Code -eq 0) {
    if ((Invoke-GitQuiet -C $root merge-base --is-ancestor $t.branch HEAD).Code -ne 0 -and -not $Force) { Die "nhánh $($t.branch) chưa merge vào HEAD." @("Merge nhánh trước hoặc chỉ bỏ task nếu chắc chắn:", "crew clean $Name -Force") }
  }

  if (Test-KeepTask $root $t) {
    # bản mới: agent giữ phiên, thư mục giữ nguyên; chỉ đưa worktree về nhánh chính và xóa nhánh task
    $main = Get-MainBranch $root
    try { $warn = Reset-WorkerTree $root $t $main ([bool]$Force) }
    catch { Die "$($_.Exception.Message)" @("Task $Name vẫn được giữ; sửa lỗi ở trên.", "crew clean $Name") }
  } else {
    # bản cũ (worktree riêng theo task): gỡ worktree như trước
    if (-not $Force -and (Test-Path $t.worktree) -and (Test-WorktreeListed $root $t.worktree)) {
      $st = Invoke-GitQuiet -C $t.worktree status --porcelain
      if ($st.Code -eq 0 -and $st.Text) { Die "worktree $($t.worktree) còn thay đổi chưa commit." @("Commit thay đổi hoặc chỉ bỏ task nếu chắc chắn:", "crew clean $Name -Force") }
    }
    # agent cũ còn đứng trong worktree của task (giữ khóa thư mục) ⇒ kill rồi bật lại worker theo kiểu mới
    $info = Get-TermInfo $t.terminal
    $cwd = if ($info -and $info.foreground -and $info.foreground.cwd) { $info.foreground.cwd } elseif ($info) { $info.cwd } else { $null }
    $sep = [IO.Path]::DirectorySeparatorChar
    $old = [IO.Path]::GetFullPath($t.worktree).TrimEnd('\', '/')
    if ($info -and $info.state -eq 'live' -and $cwd -and ([IO.Path]::GetFullPath($cwd).TrimEnd('\', '/') + $sep).StartsWith("$old$sep", [StringComparison]::OrdinalIgnoreCase)) {
      Say "dừng $($t.terminal) ($($info.address)) đang đứng trong $old, bật lại worker trong worktree cố định."
      Stop-Term $info.address
      Start-WorkerTerm $root $cfg $ids $slug ([int]$t.worker) (Get-MainBranch $root) | Out-Null
    }
    try { $warn = Remove-TaskGit $root $t ([bool]$Force) }
    catch { Die "$($_.Exception.Message)" @("Task $Name vẫn được giữ; sửa lỗi ở trên.", "crew clean $Name") }
  }
  $null = Update-Tasks $root { param($current) $current | Where-Object { $_.name -ne $Name } }
  foreach ($w in $warn) { Write-Host "crew: CẢNH BÁO: $w" -ForegroundColor Yellow }
  Say "đã dọn task $Name."
  Invoke-QueueAuto $root
}
