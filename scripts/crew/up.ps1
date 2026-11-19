# ---------------- up ----------------
# Hàm thuần: -Restart (không -Force) có tắt nhầm planner/Rev đang làm không. $plannerMode = Get-WorkerMode(...).Mode của
# terminal planner ('' = không live/không đọc). Ra lý do chặn, '' = được tắt.
function Get-RestartGuard([string[]]$targets, $tasks, [string]$plannerMode) {
  if (@($targets) -contains 'planner' -and $plannerMode -eq 'agent') {
    return 'planner đang chạy — bật lại sẽ mất hội thoại điều phối; thêm -Force nếu chắc chắn.'
  }
  if (@($targets) -contains 'rev') {
    $busy = @(@($tasks) | Where-Object { $_ -and $_.reviewSentAt } | ForEach-Object { $_.name })
    if ($busy.Count) { return "rev đang review/merge task $($busy -join ', ') — bật lại sẽ mất phiên đang làm. Đợi Rev xong + crew clean, hoặc thêm -Force nếu chắc chắn." }
  }
  ''
}

function Invoke-Up {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." "project mới: chạy crew init trong thư mục này trước" }
  # Invoke-Recover đã gọi trước khi gọi tới đây; project cũ được ghi tên vào config + sổ, tên terminal và space/tab giữ nguyên
  if (-not $script:FromRepair) { Update-ConfigName $root $false }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
  $clash = Get-NameConflict $root $cfg
  if ($clash) { Die $clash 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint 'xem hướng dẫn chuyển thư mục ở trên; kiểm metadata: crew repair' }
  # Agent sẽ commit về sau. Đường qua Invoke-Recover và tiến trình nền (FromRepair) không hỏi ở đây.
  if (-not $script:FromRepair) { Confirm-GitIdentity $root $false $false }
  $main = Get-MainBranch $root
  try { $liveTerms = @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) } catch { Die "$($_.Exception.Message) — không kiểm được terminal đang chạy nên không bật/kill gì." 'kiểm hc: hc ls; sửa lỗi rồi chạy lại crew up' }
  # terminal cùng tên mà thuộc project khác ⇒ dừng trước mọi kill/bật/gửi
  $mine = @(if ($cfg.planner -ne 'none') { "$slug-planner" }) + @(for ($i = 1; $i -le @($cfg.workers).Count; $i++) { "$slug-w$i" }) + @(if ($cfg.rev -ne 'none') { "$slug-rev" })
  $foreign = @($liveTerms | Where-Object { $mine -contains $_.name } | ForEach-Object { Get-ForeignTermError $_.name $_ $root } | Where-Object { $_ })
  if ($foreign.Count) { Die ($foreign -join "`n  ") 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
  # space/tab id của crew này đã thuộc project khác (kể cả project chưa vào sổ) ⇒ dừng trước mọi kill/bật/rename/move
  $hs = Get-HerdrSpaces
  if (-not $hs.Ok) { Say "cảnh báo: $($hs.Error) — không kiểm được space herdr trùng khóa id; chỉ kiểm terminal cùng tên." }
  else {
    $why = Get-ForeignSpaceError $ids $root $hs.Spaces $liveTerms
    if ($why) { Die $why 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
  }
  $live = @($liveTerms | ForEach-Object { $_.name })
  # Pane đang chạy lệnh này không bao giờ bị tắt ở đây: tắt là crew chết giữa chừng. Thay nếu có là việc cuối, do tiến trình nền làm.
  $self = Get-SelfTerm $liveTerms $mine
  $selfState = if ($self) { Get-SelfPaneState (Get-TermInfo $self.name) } else { '' }
  $selfJob = $null
  $made = [Collections.Generic.List[string]]::new(); $started = [Collections.Generic.List[object]]::new()
  $targets = @(); $lostTerms = @()
  $book = Read-SessionBook $root
  if ($book.Warning) { Say "cảnh báo: $($book.Warning)" }

  # -Restart: kill đúng terminal đó (đã chạy thì) rồi để vòng dưới bật lại theo config hiện tại
  if ($Restart) {
    try { $targets = Get-RestartTargets $Restart @($cfg.workers).Count ($cfg.planner -ne 'none') ($cfg.rev -ne 'none') } catch { Die $_.Exception.Message 'vd. crew up -Restart w1, hoặc crew up -Restart all' }
    $tasks = Get-Tasks $root
    foreach ($tg in $targets) {
      if ($tg -notlike 'w*' -or $Force) { continue }
      $busy = @($tasks | Where-Object { "w$([int]$_.worker)" -eq $tg } | ForEach-Object { $_.name })
      if ($busy.Count) { Die "$tg đang có task $($busy -join ', ') — bật lại sẽ mất phiên đang làm." "đợi xong + crew clean, hoặc crew up -Restart $Restart -Force nếu chắc chắn" }
    }
    $selfRestart = $self -and $targets -contains $self.name.Substring($slug.Length + 1)
    if ($selfRestart -and -not $selfState) { Die "$($self.name) là pane đang chạy lệnh này và agent trong đó có thể còn sống, crew không tự tắt. Không tắt vai nào." "mở tab khác rồi chạy lại: crew up -Restart $Restart" }
    # planner/Rev đang làm: chặn trước mọi Stop-Term và job thay pane. Pane của chính lệnh này do chặn self-pane ở trên xử lý.
    if (-not $Force) {
      $pn = "$slug-planner"; $plannerMode = ''
      if ($targets -contains 'planner' -and $live -contains $pn -and -not ($self -and $self.name -ceq $pn)) {
        $plannerMode = (Get-WorkerMode (Get-TermInfo $pn) $cfg.planner).Mode
      }
      $why = Get-RestartGuard $targets $tasks $plannerMode
      if ($why) { Die $why "đợi planner/Rev xong; hoặc crew up -Restart $Restart -Force nếu chắc chắn" }
    }
    if ($selfRestart) {
      $selfRole = $self.name.Substring($slug.Length + 1)
      if ($IsWindows -eq $false) { Say "$($self.name) là pane đang chạy lệnh này; chưa xác minh shell trên hệ này nên crew không tự thay. Mở tab khác rồi chạy: crew up -Restart $selfRole" }
      else { $selfJob = New-SelfPaneJob $root $self.name $selfRole $self.address $true }
    }
    foreach ($tg in $targets) {
      $n = "$slug-$tg"
      if ($self -and $n -ceq $self.name) { continue }
      $term = $liveTerms | Where-Object { $_.name -eq $n } | Select-Object -First 1
      if ($term) { Say "dừng $n ($($term.address)) để bật lại."; Stop-Term $term.address }
      $live = @($live | Where-Object { $_ -ne $n })
    }
  }

  # Sau reboot/crash core hoặc agent thoát, terminal chỉ còn shell trống ⇒ bật lại agent, mở lại hội thoại cũ nếu sổ phiên cho phép.
  $shellOps = New-HcOps
  foreach ($n in @($mine | Where-Object { $live -contains $_ })) {
    if ($self -and $n -ceq $self.name) {
      continue
    }
    try {
      $info = & $shellOps.Get $n
      if (-not $info) { throw 'hc get không trả terminal' }
      $shell = Get-TermShellState $info { & $shellOps.Read $n }
      if ($shell -in 'lost', 'exited') {
        # Đọc lại ngay trước kill: tên/address/chủ và dấu hiệu shell phải còn đúng.
        $fresh = & $shellOps.Get $n
        if (-not $info.address -or $info.name -cne $n -or
            -not (Test-TermOwner $fresh $root) -or $fresh.address -cne $info.address -or $fresh.name -cne $info.name -or
            (Get-TermShellState $fresh { & $shellOps.Read $n }) -ne $shell) {
          throw 'không xác minh được chủ, tên/địa chỉ hoặc shell trống ở lần đọc mới'
        }
        Stop-Term $fresh.address
        $live = @($live | Where-Object { $_ -ne $n })
        $lostTerms += $n
        Say "$n chỉ còn shell trống (máy khởi động lại hoặc agent đã thoát), bật lại agent."
      }
    } catch {
      Say "cảnh báo: không tắt $n — $($_.Exception.Message); giữ pane, không bật agent chồng lên."
      continue
    }
  }

  # Chỗ duy nhất trong crew up bật agent của một vai; lệnh theo $plan.Session.
  $launch = {
    param([string]$role, $plan)
    $n = "$slug-$role"
    switch ($role) {
      'planner' { Start-Term $n $root $ids.Space $ids.Planner (Get-AgentCommand $cfg.planner $cfg.access 'Bạn là planner của crew này. Đọc context/README.md rồi context/roles/planner.md; làm đúng vai trò đó và chờ chủ dự án giao việc.' $plan.Session) }
      'rev' { Start-Term $n $root $ids.Space $ids.Rev (Get-AgentCommand $cfg.rev $cfg.access 'Bạn là rev của crew này. Đọc context/README.md rồi context/roles/rev.md; làm đúng vai trò đó và chờ planner giao việc.' $plan.Session) }
      default { Start-WorkerTerm $root $cfg $ids $slug ([int]$role.Substring(1)) $main $plan.Session }
    }
  }
  # Hội thoại mới: báo + ghi sổ ngay, để vai bật sau lỗi vẫn còn ghi nhận.
  $noteNew = {
    param([string]$role, [string]$kind, $plan)
    Say "$(if ($plan.Warn) { 'cảnh báo: ' })$slug-${role}: $(Format-SessionPlan $plan)"
    Set-SessionRecord $book $root $cfg $role $kind $plan.Session
    Save-SessionBook $root $book
    $started.Add(@{ Term = "$slug-$role"; Kind = $kind })
  }
  $resuming = [Collections.Generic.List[object]]::new()
  $startRole = {
    param([string]$role, [string]$kind, [string]$suffix = '')
    $n = "$slug-$role"
    # Chỉ pane shell trống và terminal thiếu khi không có -Restart mới được khôi phục.
    $blocked = if ($lostTerms -contains $n) { '' } elseif ($targets -contains $role) { 'bật lại bằng -Restart' } elseif ($Restart) { 'crew up -Restart không khôi phục terminal thiếu' } else { '' }
    $plan = Get-SessionPlan $book $root $cfg $role $kind $blocked
    $r = & $launch $role $plan
    $made.Add("$n=$($r.address)$suffix")
    if ($plan.Resume) { $resuming.Add(@{ Term = $n; Role = $role; Kind = $kind; Plan = $plan; Address = $r.address }) }
    else { & $noteNew $role $kind $plan }
  }

  $skipLive = {
    param([string]$n)
    if ($self -and $n -ceq $self.name) { Say "$n là pane đang chạy lệnh này, chưa đụng tới." } else { Say "$n đã chạy, bỏ qua." }
  }
  if ($cfg.planner -ne 'none') {
    $n = "$slug-planner"
    if ($live -contains $n) { & $skipLive $n } else { & $startRole 'planner' $cfg.planner }
  }
  $wi = 0
  foreach ($kind in $cfg.workers) {
    $wi++; $n = "$slug-w$wi"
    $wt = Initialize-WorkerTree $root $wi $main
    if ($live -contains $n) { & $skipLive $n; continue }
    & $startRole "w$wi" $kind " ($kind trong $wt)"
  }
  if ($cfg.rev -ne 'none') {
    $n = "$slug-rev"
    if ($live -contains $n) { & $skipLive $n } else { & $startRole 'rev' $cfg.rev }
  }

  # Mở lại phiên: lệnh không kèm prompt nên chỉ quan sát, không gửi hay bấm phím. CLI thoát ⇒ hội thoại mới đúng một lần, không lặp.
  if ($resuming.Count) {
    $resumeOps = New-HcOps
    $states = Wait-ResumeStates @($resuming) $resumeOps
    foreach ($item in $resuming) {
      $n = $item.Term
      switch ($states[$n]) {
        'ready' {
          # Codex không báo lỗi khi thư mục chưa có phiên: mở phiên trống (nhận như sau /new, Test-SessionReady).
          if ($item.Kind -eq 'codex' -and (Test-SessionReady 'codex' (& $resumeOps.Get $n) (& $resumeOps.Read $n))) { Say "cảnh báo: ${n}: hội thoại mới (Codex không có phiên cũ để mở lại)" }
          else { Say "${n}: $(Format-SessionPlan $item.Plan)" }
        }
        'exited' {
          $fresh = & $resumeOps.Get $n
          if (-not $fresh -or $fresh.address -cne $item.Address -or -not (Test-TermOwner $fresh $root) -or
              ($fresh.state -eq 'live' -and (Get-TermShellState $fresh { & $resumeOps.Read $n }) -ne 'exited')) {
            Say "cảnh báo: ${n}: không mở lại được hội thoại nhưng không xác minh được pane ở lần đọc mới; giữ pane, không bật chồng."
            break
          }
          Stop-Term $fresh.address
          $plan = Get-NewSessionPlan $item.Role $item.Kind 'không mở lại được hội thoại cũ, CLI đã thoát' $true
          $r = & $launch $item.Role $plan
          $made.Add("$n=$($r.address)")
          & $noteNew $item.Role $item.Kind $plan
        }
        'dialog' {
          Say "cảnh báo: ${n}: đang mở lại hội thoại nhưng pane hiện hộp thoại hoặc chờ duyệt; crew không bấm, xem: hc read $n --lines 20"
          $started.Add(@{ Term = $n; Kind = $item.Kind })
        }
        default {
          Say "cảnh báo: ${n}: chưa xác nhận được đã mở lại hội thoại (~30s); giữ pane, không bật chồng. Xem: hc read $n --lines 20"
          $started.Add(@{ Term = $n; Kind = $item.Kind })
        }
      }
    }
  }

  # đặt tên space/tab, focus planner
  if (Wait-Tab ($(if ($cfg.planner -ne 'none') { $ids.Planner } else { & $ids.Workers 1 }))) {
    herdr-app do space.rename --id $ids.Space --name "crew:$slug" | Out-Null
    if ($cfg.planner -ne 'none') { herdr-app do tab.rename --id $ids.Planner --name planner | Out-Null }
    $tabs = [math]::Ceiling(@($cfg.workers).Count / 2)
    for ($i = 1; $i -le $tabs; $i++) {
      $id = & $ids.Workers $i; Wait-Tab $id | Out-Null
      $label = if ($tabs -eq 1) { 'workers' } else { "workers$i" }
      herdr-app do tab.rename --id $id --name $label | Out-Null
    }
    if ($cfg.rev -ne 'none') { Wait-Tab $ids.Rev | Out-Null; herdr-app do tab.rename --id $ids.Rev --name rev | Out-Null }
    # herdr chèn tab mới sau tab đang active; xếp lại: planner, workers…, rev (tab.move đếm từ 1)
    $order = @()
    if ($cfg.planner -ne 'none') { $order += $ids.Planner }
    for ($i = 1; $i -le $tabs; $i++) { $order += (& $ids.Workers $i) }
    if ($cfg.rev -ne 'none') { $order += $ids.Rev }
    for ($i = 0; $i -lt $order.Count; $i++) { herdr-app do tab.move --id $order[$i] --index ($i + 1) | Out-Null }
    $focus = if ($cfg.planner -ne 'none') { $ids.Planner } else { & $ids.Workers 1 }
    herdr-app do space.select --id $ids.Space | Out-Null
    herdr-app do tab.select --id $focus | Out-Null
  } else { Say "cảnh báo: herdr-app chưa hiện space (app có đang mở?)." }

  if ($made.Count) { Say "đã bật: $($made -join '; ')" }
  Say "space 'crew:$slug' sẵn sàng."
  if ($started.Count) { Show-StartupTrust @($started) (New-HcOps) }
  if ($selfJob) { Invoke-SelfPaneHandoff $selfJob }
}
