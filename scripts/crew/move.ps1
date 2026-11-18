# ---- project đã đổi tên / chuyển thư mục ----
# Chỗ DUY NHẤT nhận diện (repair sửa; up/task/send/hot chỉ báo). Đã chuyển khi có root cũ R ≠ $root mà R KHÔNG còn
# .crew/config.json (mất hẳn / không còn là project), lấy từ: sổ ghi chính tên này (cùng idKey) cho R; hoặc terminal
# <tên>-planner|-w<N>|-rev nằm trong space spcrew<idKey> có cwd thuộc R. Luôn cần khớp TÊN: trùng idKey thuần (space
# spcrew<idKey> của project khác, kể cả đã xóa) không phải chuyển. Space cũ chỉ được kê khi folder thuộc R đã xác nhận.
# R còn .crew/config.json ⇒ bản chép (việc của crew-copy), KHÔNG coi là chuyển. Không dùng Get-NameConflict (gộp cả trùng idKey).
# $liveTerms/$spaces: $null ⇒ tự đọc hc ls / herdr-app ls; đọc lỗi ⇒ bỏ lớp đó (sổ vẫn kiểm).
# Trả @{ Moved; OldRoot; OldRoots; Terms (terminal live của crew ở root cũ); Spaces (space của crew ở root cũ); Hint }.
# up/task/send/hot gọi trong try: kiểm này chỉ để gợi ý crew repair, lỗi khi kiểm không chặn lệnh.
function Get-MoveInfo([string]$root, $cfg, $liveTerms = $null, $spaces = $null) {
  $name = Get-CrewName $root $cfg; $key = Get-CrewIdKey $root $cfg; $sid = (Get-Ids $key).Space
  # root project của một cwd/folder: <R>/.crew/worktrees/w<N> ⇒ R, ngược lại chính nó
  $rootOf = {
    param($p)
    $k = ConvertTo-RootKey $p; $wts = Split-Path $k -Parent; $crew = Split-Path $wts -Parent
    if ((Split-Path $k -Leaf) -match '^w\d+$' -and (Split-Path $wts -Leaf) -eq 'worktrees' -and (Split-Path $crew -Leaf) -eq '.crew') { return (Split-Path $crew -Parent) }
    $k
  }
  $gone = { param($r) $r -and -not (Test-SamePath $r $root) -and -not (Test-Path -LiteralPath (Join-Path $r '.crew/config.json')) }
  $old = [Collections.Generic.List[string]]::new()
  $isOld = { param($r) [bool]@($old | Where-Object { Test-SamePath $_ $r }).Count }
  $add = { param($r) if ((& $gone $r) -and -not (& $isOld $r)) { $old.Add((ConvertTo-RootKey $r)) } }

  $reg = Read-ProjectRegistry
  if ($reg.Ok -and $reg.Map.Contains($name) -and $reg.Map[$name].IdKey -ceq $key) { & $add ([string]$reg.Map[$name].Root) }
  if ($null -eq $liveTerms) { $liveTerms = try { @(Get-LiveTerminals) } catch { @() } }
  if ($null -eq $spaces) { $spaces = try { $h = Get-HerdrSpaces; if ($h.Ok) { @($h.Spaces) } else { @() } } catch { @() } }
  $mine = @($spaces | Where-Object { $_ -and [string]$_.id -ceq $sid })
  $inSpace = @(foreach ($sp in $mine) { foreach ($tb in @($sp.tabs)) { foreach ($tm in @($tb.terminals)) { if ($tm) { [string]$tm.terminal } } } })
  $named = @($liveTerms | Where-Object { $_ -and $_.state -eq 'live' -and $_.cwd -and [string]$_.name -cmatch "^$([regex]::Escape($name))-(planner|rev|w\d+)$" })
  foreach ($t in $named) { if ($inSpace -contains [string]$t.address) { & $add (& $rootOf ([string]$t.cwd)) } }

  $terms = @($named | Where-Object { & $isOld (& $rootOf ([string]$_.cwd)) })
  $oldSpaces = @($mine | Where-Object { $_.folder -and (& $isOld (& $rootOf ([string]$_.folder))) })
  $first = if ($old.Count) { $old[0] } else { '' }
  @{ Moved = [bool]$old.Count; OldRoot = $first; OldRoots = @($old); Terms = $terms; Spaces = $oldSpaces
    Hint = $(if ($first) { "project đã chuyển từ $first, chạy crew repair" } else { '' }) }
}

# Đường dẫn $p nằm trong root cũ $old ⇒ cùng vị trí dưới $root mới; ngoài ⇒ giữ nguyên. Hàm thuần.
function Get-MovedPath([string]$p, [string]$old, [string]$root) {
  if (-not $p) { return $p }
  $k = ConvertTo-RootKey $p; $o = ConvertTo-RootKey $old
  if (Test-SamePath $k $o) { return (ConvertTo-RootKey $root) }
  $cmp = if ($IsWindows -or $PSVersionTable.PSEdition -ne 'Core') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  foreach ($sep in '\', '/') {
    if ($k.StartsWith($o.TrimEnd('\', '/') + $sep, $cmp)) { return [IO.Path]::GetFullPath((Join-Path $root $k.Substring($o.TrimEnd('\', '/').Length + 1))) }
  }
  $p
}

# Lõi crew repair (không Die). $ops = bảng hc như New-HcOps + Up (bật terminal thiếu = logic crew up).
# Trả @{ Done; Human; Sent; Self; Finished } — Human rỗng ⇒ không còn gì cần người quyết; Finished = task đã xong nên không giao lại, chỉ để in.
# Không bao giờ: xóa nhánh, bỏ thay đổi chưa commit, xóa bản ghi task, kill terminal live — trừ terminal của crew này
# đang chạy ở root cũ khi project đã chuyển (Get-MoveInfo): kill rồi bật lại ở root mới, giao lại task dở.
function Invoke-RepairCore([string]$root, $cfg, [string]$slug, [string]$main, [bool]$dry, $ops) {
  $done = [Collections.Generic.List[string]]::new(); $human = [Collections.Generic.List[string]]::new(); $sent = @()
  $will = { param($m) if ($dry) { $done.Add("(sẽ làm) $m") } else { $done.Add($m) } }
  $tasks = Get-Tasks $root
  $workers = @($cfg.workers)

  # --- chẩn đoán chuyển thư mục (Get-MoveInfo; $ops.List/Spaces thiếu ⇒ chỉ kiểm sổ) ---
  $listErr = ''
  $lt = if ($ops.List) { try { @(& $ops.List) } catch { $listErr = "hc ls lỗi ($($_.Exception.Message))"; @() } } else { @() }
  $hs = if ($ops.Spaces) { & $ops.Spaces } else { @{ Ok = $true; Spaces = @() } }
  if ($listErr) { return @{ Done = @(); Human = @("$listErr — không biết terminal nào đang chạy; repair dừng, không kill/đóng space/bật lại/gửi. Kiểm hc (hc ls) rồi chạy lại crew repair."); Sent = @() } }
  $mv = Get-MoveInfo $root $cfg $lt @($hs.Spaces)
  # đọc lại hc ls (địa chỉ terminal live): lỗi ⇒ $null (không rõ ai còn live)
  $readLive = { if (-not $ops.List) { return $null }; try { , @(@(& $ops.List) | Where-Object { $_ -and $_.state -eq 'live' } | ForEach-Object { [string]$_.address }) } catch { $null } }
  $killNames = @($mv.Terms | ForEach-Object { [string]$_.name })
  if ($mv.Moved) {
    Write-Host "== chuyển thư mục"
    Write-Host "project đã chuyển: $($mv.OldRoots -join ', ') -> $root"
    if (-not $hs.Ok) { Write-Host "cảnh báo: $($hs.Error) — không kiểm được space herdr ở root cũ." }
    foreach ($t in $mv.Terms) { Write-Host "terminal $($t.name) ($($t.address)) cwd $($t.cwd) — root cũ" }
    foreach ($sp in $mv.Spaces) { Write-Host "space $($sp.id) folder $($sp.folder) — root cũ" }
    # tasks.json trỏ root cũ ⇒ sửa trong bộ nhớ (chẩn đoán dưới dùng đường dẫn mới cho cả DryRun); chạy thật mới ghi file
    $movedTasks = @(); $movedNames = @()
    foreach ($t in $tasks) {
      $nw = [string]$t.worktree
      foreach ($o in $mv.OldRoots) { $nw = Get-MovedPath $nw $o $root }
      if ($nw -ne [string]$t.worktree) { $movedTasks += "$($t.name): $($t.worktree) -> $nw"; $movedNames += [string]$t.name; $t.worktree = $nw }
    }
  }

  # --- chẩn đoán terminal ---
  $roles = @()
  if ($cfg.planner -ne 'none') { $roles += @{ Role = 'planner'; Kind = $cfg.planner } }
  for ($i = 1; $i -le $workers.Count; $i++) { $roles += @{ Role = "w$i"; Kind = $workers[$i - 1]; N = $i } }
  if ($cfg.rev -ne 'none') { $roles += @{ Role = 'rev'; Kind = $cfg.rev } }
  Write-Host "== terminal"
  $foreign = @(); $selfRole = $null
  foreach ($r in $roles) {
    $r.Term = "$slug-$($r.Role)"
    # live ở root cũ ⇒ sẽ kill rồi bật lại như terminal thiếu (DryRun và chạy thật như nhau)
    if ($killNames -contains $r.Term) { $r.Mode = 'dead'; $r.Live = $false; Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, 'live ở root cũ — kill, bật lại'); continue }
    $ti = & $ops.Get $r.Term
    $why = Get-ForeignTermError $r.Term $ti $root
    if ($why) { $foreign += $why; Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, "KHÁC PROJECT (cwd $($ti.cwd))"); continue }
    $r.Mode = (Get-WorkerMode $ti $r.Kind).Mode
    # Pane đang chạy lệnh này: màn hình đang in nên không đọc dấu nhắc được; không bao giờ tính là terminal thiếu.
    if ($ti -and $env:HC_TERMINAL_ID -and $ti.address -ceq $env:HC_TERMINAL_ID) {
      $selfState = Get-SelfPaneState $ti
      if ($selfState -in 'lost', 'exited', 'unix-shell') {
        $r.Mode = 'self'; $r.Live = $true; $r.Self = $selfState; $selfRole = $r
        Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, 'pane hiện tại, shell trống')
        continue
      }
    }
    # shell trống sau reboot hoặc agent thoát ⇒ xử lý như terminal thiếu: crew up bật lại, task dở được giao lại ở dưới
    if ($r.Mode -eq 'shell') {
      $shellState = Get-TermShellState $ti { & $ops.Read $r.Term }
      if ($shellState -in 'lost', 'exited') { $r.Mode = 'lost' }
      # crew bật pane này, màn hình chưa về dấu nhắc shell ⇒ agent chưa báo status, không phải đã thoát (crew up chạy lại ngay sau khi bật)
      elseif (-not $shellState -and @($ti.argv) -contains '-EncodedCommand') { $r.Mode = 'starting' }
    }
    $r.Live = $r.Mode -notin 'dead', 'lost'
    $note = @{ dead = 'thiếu'; lost = 'shell trống — bật lại'; agent = 'live, đúng agent'; starting = 'live, agent đang khởi động'; wrong = 'live, SAI agent'; shell = 'live, shell (agent đã thoát)'; blocked = 'live, chờ duyệt' }[$r.Mode]
    Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, $note)
  }
  # trùng tên với project khác ⇒ không sửa, không bật, không gửi gì
  if ($foreign.Count) { return @{ Done = @(); Human = @($foreign | ForEach-Object { "$_ Repair dừng, không sửa gì." }); Sent = @() } }

  # --- sửa: project đã chuyển (trước prune: prune sẽ xóa metadata worktree đang trỏ đường dẫn cũ) ---
  # Thứ tự an toàn: git worktree repair (bước CHẶN, xác nhận đủ w<N> ở root mới) → tasks.json → sổ → kill → xác nhận chết
  # → đọc lại herdr-app ls + hc ls → đóng space cũ → (sau) prune/crew up. Không xóa nhánh/thay đổi/bản ghi task.
  $blockUp = ''
  if ($mv.Moved) {
    $wts = @(@(for ($i = 1; $i -le $workers.Count; $i++) { Get-WorkerTree $root $i }) + @($tasks | ForEach-Object { [string]$_.worktree }) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { ConvertTo-RootKey $_ } | Select-Object -Unique)
    if ($wts.Count) {
      & $will "git worktree repair $($wts -join ' ')"
      if (-not $dry) {
        $r = Invoke-GitQuiet -C $root worktree repair @wts
        $after = Get-WorktreeMeta $root
        $bad = @($wts | Where-Object { $m = $after[[IO.Path]::GetFullPath($_).TrimEnd('\', '/')]; -not $m -or $m.Prunable })
        if ($r.Code -ne 0 -or $bad.Count) {
          $why = if ($r.Code -ne 0) { "lỗi (mã $($r.Code)): $($r.Text)" } else { "xong nhưng git worktree list chưa thấy ở root mới: $($bad -join ', ')" }
          $quoted = @($wts | ForEach-Object { Quote $_ }) -join ' '
          $human.Add("git worktree repair $why — repair dừng: không prune, không sửa tasks.json/sổ, không kill/đóng space/bật lại. Tự xử lý: git -C $(Quote $root) worktree repair $quoted; kiểm git -C $(Quote $root) worktree list (KHÔNG chạy git worktree prune trước khi w<N> hiện ở root mới), rồi chạy lại crew repair.")
          return @{ Done = @($done); Human = @($human); Sent = @() }
        }
      }
    }
    if ($movedTasks.Count) {
      & $will "tasks.json: worktree $($movedTasks -join '; ')"
      if (-not $dry) {
        $movedRecords = @($tasks | Where-Object { $_.name -in $movedNames })
        Update-Tasks $root { param($current) foreach ($record in $movedRecords) { $existing = @($current | Where-Object { $_.name -eq $record.name }); if ($existing.Count) { foreach ($item in $existing) { $item.worktree = $record.worktree } } else { $current += $record } }; $current } | Out-Null
      }
    }
    $key = Get-CrewIdKey $root $cfg
    & $will "sổ $(Get-ProjectsFile): $slug -> $root (giữ tên, idKey $key)"
    if (-not $dry -and -not (Register-CrewName $slug $root $key)) { $human.Add("chưa cập nhật được sổ tên crew cho $root — xem cảnh báo ở trên.") }
    $killAddr = @($mv.Terms | ForEach-Object { [string]$_.address })
    foreach ($t in $mv.Terms) {
      & $will "kill $($t.name) ($($t.address)) đang ở root cũ $($t.cwd) — bật lại ở $root"
      if (-not $dry) {
        try { & $ops.Kill ([string]$t.address) } catch { $human.Add("kill $($t.name) lỗi: $($_.Exception.Message)"); $blockUp = "$($t.name) chưa kill được" }
      }
    }
    if (-not $dry -and $killAddr.Count) {
      $nowLive = & $readLive
      if ($null -eq $nowLive) { $human.Add('không đọc lại được hc ls sau kill — không xác nhận được terminal root cũ đã tắt.'); $blockUp = 'chưa xác nhận terminal root cũ đã tắt' }
      else {
        $still = @($killAddr | Where-Object { $nowLive -contains $_ })
        if ($still.Count) { $human.Add("terminal root cũ vẫn live sau kill: $($still -join ', ') — xem tay (hc kill <địa chỉ>)."); $blockUp = 'terminal root cũ vẫn live' }
      }
    }
    $liveAddr = @($lt | Where-Object { $_.state -eq 'live' } | ForEach-Object { [string]$_.address })
    $termsOf = { param($sp) @(foreach ($tb in @($sp.tabs)) { foreach ($tm in @($tb.terminals)) { if ($tm) { [string]$tm.terminal } } }) }
    $atOld = { param($f) $f -and @($mv.OldRoots | Where-Object { (Get-MovedPath ([string]$f) $_ $root) -ne [string]$f }).Count }
    $noClose = { param($sp, $why) $human.Add("space $($sp.id) (folder cũ $($sp.folder)) $why — không đóng, không bật lại; đóng tay (herdr-app do space.close --id $($sp.id)) rồi chạy lại crew repair."); Set-Variable blockUp "space $($sp.id) còn ở root cũ" -Scope 1 }
    foreach ($sp in $mv.Spaces) {
      # kiểm theo ảnh chụp đầu (dùng chung DryRun + chạy thật)
      $others = @(& $termsOf $sp | Where-Object { $killAddr -notcontains $_ -and ($listErr -or $liveAddr -contains $_) })
      if ($others.Count) { & $noClose $sp $(if ($listErr) { "$listErr — không biết terminal nào trong space còn live" } else { "còn terminal khác $($others -join ', ')" }); continue }
      & $will "đóng space $($sp.id) (folder cũ $($sp.folder)); crew up tạo lại ở $root"
      if ($dry) { continue }
      if ($blockUp) { & $noClose $sp "chưa đóng vì $blockUp"; continue }
      # chạy thật: đọc lại NGAY TRƯỚC Close — space vẫn ở root cũ, không terminal nào trong đó còn live
      $now = & $ops.Spaces
      if (-not $now.Ok) { & $noClose $sp "không đọc lại được herdr-app ls ($($now.Error))"; continue }
      $cur = @($now.Spaces | Where-Object { $_ -and [string]$_.id -ceq [string]$sp.id }) | Select-Object -First 1
      if (-not $cur) { continue }  # herdr đã tự bỏ space rỗng
      if (-not (& $atOld $cur.folder)) { & $noClose $sp "giờ có folder $($cur.folder), không còn là root cũ"; continue }
      $nowLive = & $readLive
      if ($null -eq $nowLive) { & $noClose $sp 'không đọc lại được hc ls'; continue }
      $liveIn = @(& $termsOf $cur | Where-Object { $nowLive -contains $_ })
      if ($liveIn.Count) { & $noClose $sp "còn terminal live $($liveIn -join ', ')"; continue }
      $r = & $ops.CloseSpace ([string]$sp.id)
      if ($r.Code -ne 0) { $human.Add("đóng space $($sp.id) lỗi: $($r.Text)"); $blockUp = "space $($sp.id) còn ở root cũ" }
    }
  }

  # --- chẩn đoán worktree ---
  $meta = Get-WorktreeMeta $root
  $norm = { param($p) [IO.Path]::GetFullPath($p).TrimEnd('\', '/') }
  # DryRun khi đã chuyển: chưa chạy git worktree repair nên git -C <w mới> chưa đọc được ⇒ dựng metadata như sau repair
  # (đường dẫn mới, nhánh lấy từ worktree list); trạng thái bẩn chỉ đọc được sau repair.
  $sim = $dry -and $mv.Moved
  if ($sim) {
    $m2 = @{}
    foreach ($k in @($meta.Keys)) {
      $nk = $k; foreach ($o in $mv.OldRoots) { $nk = Get-MovedPath $nk $o $root }
      $m2[(& $norm $nk)] = @{ Branch = $meta[$k].Branch; Prunable = ($meta[$k].Prunable -and $nk -eq $k) -or -not (Test-Path -LiteralPath $nk) }
    }
    $meta = $m2
  }
  $trees = @{}
  $planned = @{}  # DryRun: w<N> -> nhánh worktree sẽ có sau các bước sửa của chính lần repair này
  Write-Host "== worktree"
  for ($i = 1; $i -le $workers.Count; $i++) {
    $wt = Get-WorkerTree $root $i; $m = $meta[(& $norm $wt)]
    if ($sim -and $m -and -not $m.Prunable) {
      $s = @{ Path = $wt; State = 'có'; Branch = $(if ($m.Branch) { $m.Branch } else { '(detached)' }); Dirty = @(); DirtyCount = 0 }
      if ($m.Branch) { $planned[$i] = $m.Branch }
    } else { $s = Get-TreeState $root $wt $meta }
    $trees[$i] = $s
    $dirty = if ($s.DirtyCount) { "bẩn ($($s.DirtyCount)): $($s.Dirty -join ', ')$(if ($s.DirtyCount -gt 5) { ', …' })" } elseif ($sim -and $s.State -eq 'có') { '(bẩn/sạch: đọc sau git worktree repair)' } elseif ($s.State -eq 'có') { 'sạch' } else { '' }
    Write-Host ("{0,-4} {1,-5} {2} {3} {4}" -f "w$i", $s.State, $s.Path, $s.Branch, $dirty)
  }

  # --- chẩn đoán task ---
  Write-Host "== task"
  $info = @{}
  foreach ($t in $tasks) {
    $hasBranch = (Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$($t.branch)").Code -eq 0
    $ahead = if ($hasBranch) { (Invoke-GitQuiet -C $root rev-list --count "$main..$($t.branch)").Text } else { '-' }
    $role = $roles | Where-Object { $_.N -eq [int]$t.worker } | Select-Object -First 1
    $wtb = if ($sim) { $tr = $trees[[int]$t.worker]; if ($tr -and $tr.State -eq 'có' -and (Test-KeepTask $root $t)) { $tr.Branch } else { '' } }
    elseif (Test-Path -LiteralPath $t.worktree) { (Invoke-GitQuiet -C $t.worktree branch --show-current).Text } else { '' }
    $info[$t.name] = @{ HasBranch = $hasBranch; Role = $role }
    Write-Host ("{0,-20} w{1} {2} {3} (+{4} commit) worker {5}, worktree {6}" -f $t.name, $t.worker, $t.branch,
      $(if ($hasBranch) { 'còn' } else { 'MẤT' }), $ahead, $(if ($role -and $role.Live) { 'live' } else { 'thiếu' }),
      $(if ($wtb -eq $t.branch) { 'đúng nhánh' } elseif ($wtb) { "ở $wtb" } else { 'chưa đúng nhánh' }))
    if (-not $hasBranch) { $human.Add("task $($t.name): nhánh $($t.branch) đã mất — không sửa; bỏ bản ghi bằng: crew clean $($t.name) -Force") }
  }
  if (-not $tasks.Count) { Write-Host '(không có)' }

  # --- chẩn đoán repo chính: thao tác dở + task chờ review ---
  Write-Host "== main"
  $op = Get-MainOp $root
  if ($op.Kind) { Write-Host "$root đang $($op.Kind) dở$(if ($op.Count) { "; xung đột ($($op.Count)): $($op.Files -join ', ')$(if ($op.Count -gt 5) { ', …' })" })" }
  else { Write-Host "$root không có thao tác dở" }
  $pending = Get-PendingReview $root $tasks
  if ($pending.Count) { Write-Host "chờ review: $(@($pending | ForEach-Object { $_.name }) -join ', ')" }

  # --- sửa: prune + tạo lại w<N> ---
  if (@($trees.Values | Where-Object { $_.State -eq 'hỏng' }).Count -or @($meta.Values | Where-Object { $_.Prunable }).Count) {
    & $will 'git worktree prune (metadata hỏng)'
    if (-not $dry) {
      $r = Invoke-GitQuiet -C $root worktree prune
      if ($r.Code -ne 0) { $human.Add("git worktree prune lỗi: $($r.Text)") }
    }
  }
  $stray = $false
  foreach ($i in @($trees.Keys | Sort-Object)) {
    $s = $trees[$i]
    $task = $tasks | Where-Object { [int]$_.worker -eq $i -and (Test-KeepTask $root $_) } | Select-Object -First 1
    if ($s.State -eq 'lạ') {
      $stray = $true
      $human.Add("w${i}: thư mục $($s.Path) có nhưng không phải worktree git — xem tay (không xóa).")
      continue
    }
    if ($s.State -in 'mất', 'hỏng') {
      & $will "tạo lại w$i ($($s.Path)) detached tại $main"
      if (-not $dry) {
        try { Initialize-WorkerTree $root $i $main | Out-Null } catch { $human.Add("tạo lại w$i lỗi: $($_.Exception.Message)"); continue }
      }
      if ($task -and $info[$task.name].HasBranch) {
        & $will "git -C $($s.Path) switch $($task.branch)"
        if ($dry) { $planned[$i] = $task.branch }
        else {
          $r = Invoke-GitQuiet -C $s.Path switch -q $task.branch
          if ($r.Code -ne 0) { $human.Add("w${i}: switch $($task.branch) lỗi: $($r.Text)") }
        }
      }
    } elseif ($s.DirtyCount -and -not $task) {
      $human.Add("w${i} bẩn mà không có task ($($s.Dirty -join ', ')) — không đụng; commit, hoặc git -C $($s.Path) stash, hoặc xem tay.")
    }
  }

  # --- sửa: bật terminal thiếu (logic crew up) ---
  $dead = @($roles | Where-Object { -not $_.Live })
  $started = @()
  if ($dead.Count) {
    if ($stray) { $human.Add("chưa bật terminal thiếu ($(@($dead | ForEach-Object { $_.Term }) -join ', ')): còn thư mục w<N> lạ, crew up sẽ lỗi.") }
    elseif ($blockUp) { $human.Add("chưa bật terminal thiếu ($(@($dead | ForEach-Object { $_.Term }) -join ', ')): $blockUp, crew up sẽ lỗi.") }
    elseif (-not $dry -and $ops.List -and $null -eq (& $readLive)) { $human.Add("chưa bật terminal thiếu ($(@($dead | ForEach-Object { $_.Term }) -join ', ')): không đọc lại được hc ls ngay trước crew up.") }
    else {
      & $will "bật terminal thiếu qua crew up: $(@($dead | ForEach-Object { $_.Term }) -join ', ')"
      if ($dry) {
        $started = $dead  # DryRun: coi như bật được, không gọi Up
        $book = Read-SessionBook $root
        if ($book.Warning) { Write-Host "cảnh báo: $($book.Warning)" }
        foreach ($r in $dead) { & $will "$($r.Term): $(Format-SessionPlan (Get-SessionPlan $book $root $cfg $r.Role $r.Kind))" }
      }
      else {
        & $ops.Up
        foreach ($r in $dead) {
          if ((Get-WorkerMode (& $ops.Get $r.Term) $r.Kind).Mode -ne 'dead') { $started += $r } else { $human.Add("$($r.Term) vẫn chưa live sau crew up.") }
        }
      }
    }
  }

  # --- giao lại task dở (chỉ worker vừa bật lại) + việc cần người với worker live ---
  $finished = [Collections.Generic.List[string]]::new()
  # DryRun xem trước đúng kết luận của chạy thật: worktree sẽ tạo lại thì sạch; project đã chuyển thì chưa đọc được bẩn/sạch trước git worktree repair ($null).
  $factsOf = {
    param($t)
    $f = Get-TaskGitFacts $root $t $main
    $tree = $trees[[int]$t.worker]
    if ($dry -and $tree -and (Test-KeepTask $root $t)) {
      if ($tree.State -in 'mất', 'hỏng') { $f.Clean = $true }
      elseif ($sim) { $f.Clean = $null }
    }
    $f
  }
  foreach ($t in $tasks) {
    $role = $info[$t.name].Role
    if (-not $role -or -not $info[$t.name].HasBranch) { continue }
    if ($role.Live -and $role.Mode -eq 'agent') {
      $why = Get-WorkerInputError $role.Term (& $ops.Read $role.Term)
      if ($why) {
        $human.Add($(if ($dry) { "sẽ chặn: tin kẹt ở $($role.Term)" } else { $why }))
        continue
      }
    }
    if ($role.Live) {
      switch ($role.Mode) {
        'blocked' { $human.Add("$($role.Term) (task $($t.name)) đang chờ duyệt — chủ dự án xử lý.") }
        'wrong' { $human.Add("$($role.Term) (task $($t.name)) chạy sai agent — xem tay; crew up -Restart $($role.Role) -Force sẽ mất phiên.") }
        'shell' {
          if (Test-TaskFinished $t (& $factsOf $t)) { $human.Add("$($role.Term) (task $($t.name)) là shell (agent đã thoát); task có vẻ đã xong, không cần giao lại — bật lại khi cần: crew up -Restart $($role.Role) -Force") }
          else { $human.Add("$($role.Term) (task $($t.name)) là shell (agent đã thoát) — gửi lại: crew send $($role.Term) `"$(Get-ResumeLine $t.name $t.worktree $t.branch)`"") }
        }
        # Tiến trình nền sẽ quyết cùng kết luận sau khi thay pane; báo trước vì chữ đó không còn pane nào để in.
        'self' { if ((Test-KeepTask $root $t) -and (Test-TaskFinished $t (& $factsOf $t))) { $finished.Add((Format-TaskFinished $t.name $role.Term)) } }
      }
      continue
    }
    if ($started -notcontains $role -or -not (Test-KeepTask $root $t)) { continue }
    $facts = & $factsOf $t
    if (Test-TaskFinished $t $facts) { $finished.Add((Format-TaskFinished $t.name $role.Term)); continue }
    $chk = Get-ResumeCheck $root $t $role $(if ($dry) { [string]$planned[[int]$t.worker] } else { '' })
    if ($chk.Human) { $human.Add($chk.Human); continue }
    $line = $chk.Line
    if ($chk.Src) {
      & $will "chép lại prompt $($chk.Src) -> $($chk.Pm)"
      if (-not $dry) { New-Item -ItemType Directory -Force (Split-Path $chk.Pm) | Out-Null; Copy-Item -LiteralPath $chk.Src $chk.Pm }
    }
    if ($dry) {
      $unknown = $null -eq $facts.Clean -and (Test-TaskFinished $t @{ Ahead = $facts.Ahead; Clean = $true; HasNote = $facts.HasNote })
      & $will "giao lại task $($t.name) -> $($role.Term)$(if ($unknown) { ' nếu worktree bẩn (bẩn/sạch đọc sau git worktree repair; sạch thì task đã xong, không giao lại)' })"
      continue
    }
    $why = Wait-WorkerReady $role.Term $role.Kind $ops
    if ($why) { $human.Add("$why — chưa giao lại task $($t.name), không bấm phím; sau đó: crew send $($role.Term) `"$line`""); continue }
    $why = Get-WorkerInputError $role.Term (& $ops.Read $role.Term)
    if ($why) { $human.Add($why); continue }
    $r = Invoke-SendFlow $role.Term $line $ops
    if ($r.Ok) { $done.Add("giao lại task $($t.name) -> $($role.Term)"); $sent += $t.name }
    else { $human.Add("giao lại task $($t.name) chưa xong: $($r.Message)") }
  }

  # --- giao lại review (chỉ Rev vừa bật lại) + việc cần người khi main có thao tác dở ---
  # Không bao giờ: merge --abort/reset/checkout repo chính, xóa reviewSentAt.
  $rev = $roles | Where-Object { $_.Role -eq 'rev' } | Select-Object -First 1
  $opWhat = "main đang $($op.Kind) dở"
  if (-not $rev) {
    if ($op.Kind) { $human.Add("$opWhat — không có Rev trong config; xem git status trên $root.") }
  } elseif ($started -contains $rev -and $pending.Count) {
    $names = @($pending | ForEach-Object { $_.name }) -join ','
    $rl = Get-ReviewLine $root $main $pending $cfg.review $false
    if ($rl.Error) { $human.Add("chưa soạn lại được dòng review ($names): $($rl.Error)") }
    else {
      $line = $rl.Msg
      if ($op.Kind) { $line += " Lưu ý: bạn bị gián đoạn; repo chính đang $($op.Kind) dở — xem git status, làm tiếp hoặc tự hủy (git merge --abort …) rồi làm lại." }
      if ($dry) { & $will "giao lại review $names -> $($rev.Term)" }
      else {
        $why = Wait-WorkerReady $rev.Term $rev.Kind $ops
        if ($why) { $human.Add("$why — chưa giao lại review $names, không bấm phím; sau đó: crew send $($rev.Term) `"$line`"") }
        else {
          $r = Invoke-SendFlow $rev.Term $line $ops
          if ($r.Ok) { $done.Add("giao lại review $names -> $($rev.Term)"); $sent += @($pending | ForEach-Object { $_.name }) }
          else { $human.Add("giao lại review $names chưa xong: $($r.Message)") }
        }
      }
    }
  } elseif ($op.Kind) {
    $human.Add("$opWhat — hỏi Rev ($($rev.Term)) hoặc xem git status")
  }
  foreach ($r in $roles | Where-Object { $_.Live -and $_.Role -notlike 'w*' -and $_.Mode -in 'wrong', 'shell', 'blocked' }) {
    $human.Add("$($r.Term): $(@{ wrong = 'sai agent'; shell = 'agent đã thoát'; blocked = 'chờ duyệt' }[$r.Mode]) — xem tay (crew up -Restart $($r.Role) để bật lại).")
  }
  # Không bật được vai khác vì lý do ở trên thì tiến trình nền cũng sẽ không bật được vai này: giữ pane.
  if ($selfRole -and ($stray -or $blockUp)) {
    $human.Add("chưa thay pane hiện tại ($($selfRole.Term)): $(if ($stray) { 'còn thư mục w<N> lạ' } else { $blockUp }).")
    $selfRole = $null
  }
  @{ Done = @($done); Human = @($human); Sent = $sent; Self = $selfRole; Finished = @($finished) }
}
