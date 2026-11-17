# ---------------- queue ----------------
# Hàng đợi task: planner xếp sẵn, crew giao khi có worker rảnh (crew clean, crew up, tay crew queue -Run). Không tiến trình nền.
# .crew/queue.json = mảng (giữ thứ tự) @{ name; prompt (.crew/queue/<tên>.md); worker (0 = tự chọn); review; after; size; added; hold }.

function Get-QueueFile([string]$root) { Join-Path $root '.crew/queue.json' }
function Get-QueuePromptPath([string]$root, [string]$name) { Join-Path $root ".crew/queue/$name.md" }

# Luôn trả mảng (như Get-Tasks). File hỏng ⇒ throw (người gọi tay Die, gọi tự động chỉ cảnh báo).
function Get-QueueItems([string]$root) {
  $f = Get-QueueFile $root
  if (-not (Test-Path -LiteralPath $f)) { return , @() }
  $items = Read-CrewState $f -ThrowOnError
  return , @($items | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Save-QueueItems([string]$root, $items) {
  $f = Get-QueueFile $root
  if (Test-Path -LiteralPath $f) { $null = Read-CrewState $f -ThrowOnError }
  $list = @($items | Where-Object { $null -ne $_ })
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  ConvertTo-Json -InputObject $list -Depth 100 | Set-Content -LiteralPath (Get-QueueFile $root) -Encoding utf8
}

function New-QueueItem([string]$name, [string]$prompt, [int]$worker, [string]$review, [string]$after, [string]$size) {
  [pscustomobject][ordered]@{ name = $name; prompt = $prompt; worker = $worker; review = $review; after = $after; size = $size; added = (Get-Date -Format s); hold = '' }
}

# Hàm thuần: mốc limit của agent chặn mục này? $used = % 5h đã dùng ($null = không rõ ⇒ giao). Trả lý do giữ hoặc ''.
function Get-QueueLimitHold([string]$kind, $used, [string]$size) {
  if ($null -eq $used) { return '' }
  $level = Get-LimitLevel ([int]$used)
  if ($level -eq 'dừng') { return "limit $kind $used% (dừng)" }
  if ($level -eq 'hạn chế' -and $size -eq 'L') { return "limit $kind $used% (hạn chế, không giao size L)" }
  ''
}

# Việc chạm ngoài hàm thuần, tiêm được cho test: hỏi limit (% 5h hoặc $null) và chạy `crew task` bằng tiến trình con.
function New-QueueOps {
  @{
    Limit = {
      param($kind)
      $live = if ($kind -eq 'codex') { Get-CodexLiveLimit (New-LimitOps) } elseif ($kind -eq 'claude') { Get-ClaudeLiveLimit (New-LimitOps) } else { $null }
      if ($live) { $live.FiveHour } else { $null }
    }
    Spawn = {
      param($root, [string[]]$argv)
      $exe = (Get-Process -Id $PID).Path
      Push-Location -LiteralPath $root
      try { $out = & { $ErrorActionPreference = 'Continue'; & $exe -NoProfile -File $CrewScriptPath @argv 2>&1 | ForEach-Object { "$_" } }; $code = $LASTEXITCODE }
      finally { Pop-Location }
      @{ Code = $code; Text = (@($out) -join "`n").Trim() }
    }
  }
}

# Lý do lỗi gọn từ output của crew task con: dòng 'crew: LỖI: …' đầu tiên, không có thì dòng cuối.
function Get-QueueSpawnError([string]$text) {
  $lines = @("$text" -split '\r?\n' | Where-Object { $_.Trim() })
  $err = $lines | Where-Object { $_ -match 'crew: LỖI: ' } | Select-Object -First 1
  if ($err) { return ($err -replace '^.*?crew: LỖI: ', '').Trim() }
  if ($lines.Count) { return $lines[-1].Trim() }
  'crew task lỗi, không có thông báo'
}

# Đọc .crew/config.json không Die (gọi tự động từ clean/up không được thoát giữa chừng).
function Read-QueueConfig([string]$root) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path -LiteralPath $f)) { throw "chưa có .crew/config.json" }
  Read-CrewState $f -ThrowOnError
}

# Giao mọi mục giao được, theo thứ tự. Không Die (lỗi ⇒ throw). $manual: in "hàng đợi trống" khi rỗng. Trả số mục đã giao.
function Invoke-QueueRun([string]$root, [bool]$dryRun = $false, [bool]$manual = $true, $ops = $null) {
  $items = Get-QueueItems $root
  if (-not $items.Count) { if ($manual) { Say 'hàng đợi trống' }; return 0 }
  if (-not $ops) { $ops = New-QueueOps }
  $cfg = Read-QueueConfig $root
  $n = @($cfg.workers).Count
  $tasks = Get-Tasks $root -ThrowOnError
  $limits = @{}
  $keep = @(); $given = 0; $stopped = $false
  for ($ix = 0; $ix -lt $items.Count; $ix++) {
    $item = $items[$ix]
    if ($stopped) { $keep += $item; continue }
    $hold = ''
    $busy = @($tasks | ForEach-Object { [int]$_.worker })
    $queued = @($keep | ForEach-Object { $_.name }) + @($items | Select-Object -Skip ($ix + 1) | ForEach-Object { $_.name })
    $prompt = Get-QueuePromptPath $root $item.name
    if ($item.after -and @($tasks | Where-Object { $_.name -eq $item.after }).Count) { $hold = "chờ task $($item.after) xong" }
    elseif ($item.after -and $queued -contains $item.after) { $hold = "chờ $($item.after) (còn trong hàng đợi)" }
    elseif (-not (Test-Path -LiteralPath $prompt)) { $hold = "thiếu prompt $prompt" }
    if (-not $hold) {
      $clash = @(Get-ScopeConflicts $root $tasks (Get-PromptScope (Get-Content -LiteralPath $prompt -Raw -Encoding utf8)) | Where-Object { $_ -and $_.Task })
      if ($clash.Count) { $hold = 'trùng file với ' + (@($clash | ForEach-Object { "$($_.Task) ($(@($_.Pairs) -join ', '))" }) -join '; ') }
    }
    $pick = 0
    if (-not $hold) {
      $want = [int]$item.worker
      $free = @(1..$n | Where-Object { $busy -notcontains $_ })
      $cands = if ($want) { if ($free -contains $want) { @($want) } else { @() } } else { $free }
      if (-not $cands.Count) { $hold = if ($want) { "w$want đang bận" } else { 'không có worker rảnh' } }
      $why = @()
      foreach ($w in $cands) {
        $kind = [string]@($cfg.workers)[$w - 1]
        # hỏi limit chỉ khi có mục sắp giao, mỗi loại agent tối đa một lần/lần chạy
        if (-not $limits.ContainsKey($kind)) { $limits[$kind] = try { & $ops.Limit $kind } catch { $null } }
        $lh = Get-QueueLimitHold $kind $limits[$kind] ([string]$item.size)
        if ($lh) { $why += "w${w}: $lh"; continue }
        $pick = $w; break
      }
      if (-not $pick -and -not $hold) { $hold = $why -join '; ' }
    }
    if ($hold) {
      Say "$($item.name): giữ: $hold"
      if (-not $dryRun) { $item | Add-Member -NotePropertyName hold -NotePropertyValue $hold -Force }
      $keep += $item; continue
    }
    if ($dryRun) {
      Say "$($item.name): sẽ giao → w$pick"
      # bản ghi giả để mục sau thấy worker bận/After; không có worktree ⇒ không đọc prompt cũ của w<N> khi kiểm trùng file
      $tasks = @($tasks) + [pscustomobject]@{ name = $item.name; worker = $pick; worktree = (Join-Path $root '.crew/queue/dry-run') }
      $keep += $item; continue
    }
    $argv = @('task', $item.name, $prompt, '-Worker', "$pick")
    if ($item.review) { $argv += @('-Review', [string]$item.review) }
    $r = & $ops.Spawn $root $argv
    if ($r.Code -ne 0) {
      $item | Add-Member -NotePropertyName hold -NotePropertyValue "crew task lỗi: $(Get-QueueSpawnError $r.Text)" -Force
      Say "$($item.name): giữ: $($item.hold)"
      $keep += $item; $stopped = $true; continue
    }
    Say "$($item.name): đã giao → w$pick"
    Remove-Item -LiteralPath $prompt -Force -ErrorAction SilentlyContinue
    $given++
    $tasks = Get-Tasks $root -ThrowOnError
  }
  if (-not $dryRun) { Save-QueueItems $root $keep }
  if ($stopped) { Say 'dừng giao tiếp vì crew task lỗi; sửa rồi chạy: crew queue -Run' }
  $given
}

# Gọi tự động cuối crew clean / crew up: không -DryRun, im lặng khi trống, lỗi chỉ cảnh báo, không đổi exit code lệnh chính.
# $where = thư mục trong repo (root hoặc worktree); giao theo repo chính.
function Invoke-QueueAuto([string]$where) {
  $savedExitCode = $global:LASTEXITCODE
  try {
    $at = Resolve-Path -LiteralPath $where -ErrorAction SilentlyContinue
    if (-not $at) { return }
    $root = Get-MainRoot $at.Path
    if (-not $root -or -not (Test-Path -LiteralPath (Get-QueueFile $root))) { return }
    Invoke-QueueRun $root $false $false | Out-Null
  } catch { Write-Host "crew: CẢNH BÁO: hàng đợi: $($_.Exception.Message)" -ForegroundColor Yellow }
  finally { $global:LASTEXITCODE = $savedExitCode }
}

function Show-Queue([string]$root) {
  $items = Get-QueueItems $root
  if (-not $items.Count) { Say 'hàng đợi trống'; return }
  $fmt = '{0,-24} {1,-6} {2,-4} {3,-20} {4}'
  Write-Host ($fmt -f 'tên', 'worker', 'size', 'after', 'đang giữ (lần chạy gần nhất)')
  foreach ($i in $items) {
    $w = if ([int]$i.worker) { "w$($i.worker)" } else { '-' }
    Write-Host ($fmt -f $i.name, $w, $i.size, $(if ($i.after) { $i.after } else { '-' }), $(if ($i.hold) { $i.hold } else { '-' }))
  }
}

function Invoke-Queue {
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die "chạy trong repo của crew." }
  if ($Run) {
    if ($Name -or $PromptFile -or $Remove) { Die "dùng: crew queue -Run [-DryRun] (không kèm tên)." }
    try { Invoke-QueueRun $root ([bool]$DryRun) $true | Out-Null } catch { Die $_.Exception.Message }
    return
  }
  if (-not $Name) {
    if ($Remove) { Die "dùng: crew queue <tên> -Remove" }
    try { Show-Queue $root } catch { Die $_.Exception.Message }
    return
  }
  try { $items = Get-QueueItems $root } catch { Die $_.Exception.Message }
  if ($Remove) {
    if (-not @($items | Where-Object { $_.name -eq $Name }).Count) { Die "không có $Name trong hàng đợi." }
    Save-QueueItems $root @($items | Where-Object { $_.name -ne $Name })
    Remove-Item -LiteralPath (Get-QueuePromptPath $root $Name) -Force -ErrorAction SilentlyContinue
    Say "đã bỏ $Name khỏi hàng đợi."
    return
  }
  if (-not $PromptFile) { Die "dùng: crew queue <tên> <file-prompt> [-Worker N] [-Review x] [-After <task>] [-Size S|M|L]" }
  if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Die "tên task chỉ gồm a-z 0-9 -, tối đa 31 ký tự." }
  if (-not (Test-Path -LiteralPath $PromptFile)) { Die "không thấy file prompt $PromptFile" }
  $cfg = Get-Config $root; $tasks = Get-Tasks $root
  if ($tasks | Where-Object { $_.name -eq $Name }) { Die "task $Name đã có trong .crew/tasks.json." }
  if ($items | Where-Object { $_.name -eq $Name }) { Die "$Name đã có trong hàng đợi." }
  $n = @($cfg.workers).Count
  if ($Worker -and ($Worker -lt 1 -or $Worker -gt $n)) { Die "-Worker phải từ 1 tới $n." }
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/crew/$Name").Code -eq 0) { Die "nhánh crew/$Name đã có — đặt tên khác hoặc xóa nhánh cũ." }
  if ($After -and $After -eq $Name) { Die "-After không được là chính nó." }
  if ($After -and -not @($tasks | Where-Object { $_.name -eq $After }).Count -and -not @($items | Where-Object { $_.name -eq $After }).Count) {
    Die "-After $After không phải task đang chạy (.crew/tasks.json) hay mục trong hàng đợi — kiểm lại tên."
  }
  $dest = Get-QueuePromptPath $root $Name
  New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
  Copy-Item -LiteralPath (Resolve-Path -LiteralPath $PromptFile).Path $dest -Force
  $rv = if ($InitParameters.ContainsKey('Review')) { $Review } else { '' }
  Save-QueueItems $root (@($items) + (New-QueueItem $Name ".crew/queue/$Name.md" $Worker $rv $After $Size))
  Say "đã xếp $Name vào hàng đợi (vị trí $($items.Count + 1)). Giao khi có worker rảnh: crew clean, crew up, hoặc crew queue -Run."
}
