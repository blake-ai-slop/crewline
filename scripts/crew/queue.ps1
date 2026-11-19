# ---------------- queue ----------------
# Hàng đợi task: planner xếp sẵn, crew giao khi có worker rảnh (crew clean, crew up, tay crew queue -Run). Không tiến trình nền.
# .crew/queue.json = mảng (giữ thứ tự) @{ name; prompt (.crew/queue/<tên>.md); worker (0 = tự chọn); review; after; size; added; hold; source }.
# source = đường dẫn tuyệt đối file prompt gốc lúc xếp (mục cũ không có): `crew queue` cảnh báo khi file gốc mới hơn bản chép.

function Get-QueueFile([string]$root) { Join-Path $root '.crew/queue.json' }
function Get-QueuePromptPath([string]$root, [string]$name) { Join-Path $root ".crew/queue/$name.md" }

# Lỗi ghi log chỉ cảnh báo, không thay kết quả giao hay mã thoát của lệnh chính.
function Write-QueueLog([string]$root, [string[]]$lines) {
  try {
    $file = Join-Path $root '.crew/queue.log'
    $old = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Encoding utf8 })
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $block = @($lines | ForEach-Object { $_ -split '\r?\n' })
    # Giữ tiêu đề lượt mới nhất cả khi chỉ riêng lượt đó vượt 200 dòng.
    if ($block.Count -gt 200) { $block = @($block[0]) + @($block | Select-Object -Last 199) }
    @(@($old) + $block | Select-Object -Last 200) | Set-Content -LiteralPath $file -Encoding utf8
  } catch { Write-Host "crew: CẢNH BÁO: không ghi được .crew/queue.log: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Luôn trả mảng (như Get-Tasks). File hỏng ⇒ throw (người gọi tay Die, gọi tự động chỉ cảnh báo).
function Get-QueueItems([string]$root) {
  $f = Get-QueueFile $root
  if (-not (Test-Path -LiteralPath $f)) { return , @() }
  $items = Read-CrewState $f -ThrowOnError
  return , @($items | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

# Ghi nguyên tử, dưới khóa root. Chuỗi đọc-sửa-ghi dùng Update-QueueItems.
function Save-QueueItems([string]$root, $items) {
  $f = Get-QueueFile $root
  Use-CrewStateLock $root {
    if (Test-Path -LiteralPath $f) { $null = Read-CrewState $f -ThrowOnError }
    $list = @($items | Where-Object { $null -ne $_ })
    Write-CrewStateFile $f ((ConvertTo-Json -InputObject $list -Depth 100) + [Environment]::NewLine)
  }
}

# Đọc-sửa-ghi queue.json dưới khóa root (như Update-Tasks). Lỗi ⇒ throw, không ghi. Trả danh sách đã ghi.
function Update-QueueItems([string]$root, [scriptblock]$change, [int]$TimeoutMs = 10000) {
  Use-CrewStateLock $root {
    $current = Get-QueueItems $root
    $next = @(& $change $current | Where-Object { $null -ne $_ })
    Save-QueueItems $root $next
    , $next
  } $TimeoutMs
}

function New-QueueItem([string]$name, [string]$prompt, [int]$worker, [string]$review, [string]$after, [string]$size, [string]$source = '') {
  [pscustomobject][ordered]@{ name = $name; prompt = $prompt; worker = $worker; review = $review; after = $after; size = $size; added = (Get-Date -Format s); hold = ''; source = $source }
}

# Hàm thuần: file prompt gốc của mục đã sửa sau khi chép? Mục cũ không có source, thiếu file gốc/bản chép ⇒ $false.
function Test-QueueSourceNewer([string]$root, $item) {
  $src = [string]$item.source
  if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { return $false }
  $copy = Get-QueuePromptPath $root $item.name
  if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) { return $false }
  if ((Get-Item -LiteralPath $src).LastWriteTimeUtc -le (Get-Item -LiteralPath $copy).LastWriteTimeUtc) { return $false }
  # chỉ chạm (touch) mà nội dung y hệt thì không cảnh báo
  [IO.File]::ReadAllText($src) -cne [IO.File]::ReadAllText($copy)
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
function Invoke-QueueRun([string]$root, [bool]$dryRun = $false, [bool]$manual = $true, $ops = $null, [string]$source = 'run') {
  $log = [Collections.Generic.List[string]]::new()
  $log.Add("== $(Get-Date -Format s) ($source)")
  try {
    $items = Get-QueueItems $root
    if (-not $items.Count) { if ($manual) { Say 'hàng đợi trống' }; return 0 }
    if (-not $ops) { $ops = New-QueueOps }
    $cfg = Read-QueueConfig $root
    $n = @($cfg.workers).Count
    $tasks = Get-Tasks $root -ThrowOnError
    $limits = @{}
    $keep = @(); $given = 0; $stopped = $false; $sent = [Collections.Generic.HashSet[string]]::new()
    for ($ix = 0; $ix -lt $items.Count; $ix++) {
      $item = $items[$ix]
      if ($stopped) {
        $reason = 'dừng giao tiếp vì crew task lỗi'
        $log.Add("$($item.name): giữ: $reason")
        $item | Add-Member -NotePropertyName hold -NotePropertyValue $reason -Force
        $keep += $item; continue
      }
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
        $log.Add("$($item.name): giữ: $hold")
        Say "$($item.name): giữ: $hold"
        if (-not $dryRun) { $item | Add-Member -NotePropertyName hold -NotePropertyValue $hold -Force }
        $keep += $item; continue
      }
      if ($dryRun) {
        Say "$($item.name): sẽ giao → w$pick"
        # Bản ghi giả mang scope của prompt sắp giao, tránh đọc prompt cũ của worker.
        $tasks = @($tasks) + [pscustomobject]@{ name = $item.name; worker = $pick; scope = (Get-PromptScope (Get-Content -LiteralPath $prompt -Raw -Encoding utf8)) }
        $keep += $item; continue
      }
      $argv = @('task', $item.name, $prompt, '-Worker', "$pick")
      if ($item.review) { $argv += @('-Review', [string]$item.review) }
      $r = & $ops.Spawn $root $argv
      if ($r.Code -ne 0) {
        $item | Add-Member -NotePropertyName hold -NotePropertyValue "crew task lỗi: $(Get-QueueSpawnError $r.Text)" -Force
        $log.Add("$($item.name): giữ: $($item.hold)")
        Say "$($item.name): giữ: $($item.hold)"
        $keep += $item; $stopped = $true; continue
      }
      $log.Add("$($item.name): đã giao → w$pick")
      Say "$($item.name): đã giao → w$pick"
      Remove-Item -LiteralPath $prompt -Force -ErrorAction SilentlyContinue
      $given++; $null = $sent.Add([string]$item.name)
      $tasks = Get-Tasks $root -ThrowOnError
    }
    if (-not $dryRun) {
      # Không giữ khóa suốt lượt (crew task con cần khóa): gộp vào bản hiện tại — bỏ mục đã giao, cập nhật hold mục giữ,
      # giữ mục lệnh khác vừa thêm, mục vừa bị bỏ thì không thêm lại.
      $kept = @{}; foreach ($k in $keep) { $kept[[string]$k.name] = $k }
      $null = Update-QueueItems $root {
        param($current)
        foreach ($c in $current) { if ($kept.ContainsKey([string]$c.name)) { $kept[[string]$c.name] } elseif (-not $sent.Contains([string]$c.name)) { $c } }
      }
    }
    if ($stopped) { Say 'dừng giao tiếp vì crew task lỗi; sửa rồi chạy: crew queue -Run' }
    $given
  } catch {
    $log.Add("lỗi: $($_.Exception.Message)")
    throw
  } finally { if (-not $dryRun) { Write-QueueLog $root $log.ToArray() } }
}

# Gọi tự động cuối crew clean / crew up: không -DryRun, im lặng khi trống, lỗi chỉ cảnh báo, không đổi exit code lệnh chính.
# $where = thư mục trong repo (root hoặc worktree); giao theo repo chính.
function Invoke-QueueAuto([string]$where, [string]$source = 'clean') {
  $savedExitCode = $global:LASTEXITCODE
  try {
    $at = Resolve-Path -LiteralPath $where -ErrorAction SilentlyContinue
    if (-not $at) { return }
    $root = Get-MainRoot $at.Path
    if (-not $root -or -not (Test-Path -LiteralPath (Get-QueueFile $root))) { return }
    Invoke-QueueRun $root $false $false $null $source | Out-Null
  } catch { Write-Host "crew: CẢNH BÁO: hàng đợi: $($_.Exception.Message)" -ForegroundColor Yellow }
  finally { $global:LASTEXITCODE = $savedExitCode }
}

function Show-Queue([string]$root) {
  $items = Get-QueueItems $root
  $file = Join-Path $root '.crew/queue.log'
  if (Test-Path -LiteralPath $file) {
    $last = @(Get-Content -LiteralPath $file -Encoding utf8 | Where-Object { $_ -match '^== \d{4}-.* \(.*\)$' } | Select-Object -Last 1)
    if ($last.Count) { Say "lần chạy gần nhất: $($last[0].Substring(3)) — xem .crew/queue.log" }
  }
  if (-not $items.Count) { Say 'hàng đợi trống'; return }
  $fmt = '{0,-24} {1,-6} {2,-4} {3,-20} {4}'
  Write-Host ($fmt -f 'tên', 'worker', 'size', 'after', 'đang giữ (lần chạy gần nhất)')
  foreach ($i in $items) {
    $w = if ([int]$i.worker) { "w$($i.worker)" } else { '-' }
    Write-Host ($fmt -f $i.name, $w, $i.size, $(if ($i.after) { $i.after } else { '-' }), $(if ($i.hold) { $i.hold } else { '-' }))
  }
  foreach ($i in $items) {
    if (Test-QueueSourceNewer $root $i) {
      Write-Host "crew: CẢNH BÁO: $($i.source) mới hơn bản chép của $($i.name) — chạy lại: crew queue $($i.name) <file-prompt> để cập nhật." -ForegroundColor Yellow
    }
  }
}

function Invoke-Queue {
  $root = Get-MainRoot (Get-Location).Path
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) { Die 'không ở trong project crew' @('cd <project>', 'crew init') }
  if ($Run) {
    if ($Name -or $PromptFile -or $Remove) { Die "dùng: crew queue -Run [-DryRun] (không kèm tên)." 'crew queue -Run' }
    try { Invoke-QueueRun $root ([bool]$DryRun) $true | Out-Null } catch { Die $_.Exception.Message 'xem lỗi ở trên; kiểm .crew/queue.json và quyền đọc/ghi .crew/, sửa xong chạy lại: crew queue' }
    return
  }
  if (-not $Name) {
    if ($Remove) { Die "thiếu tên mục cần bỏ." @('crew queue', 'crew queue <tên> -Remove') }
    try { Show-Queue $root } catch { Die $_.Exception.Message 'xem lỗi ở trên; kiểm .crew/queue.json và quyền đọc/ghi .crew/, sửa xong chạy lại: crew queue' }
    return
  }
  try { $items = Get-QueueItems $root } catch { Die $_.Exception.Message 'xem lỗi ở trên; kiểm .crew/queue.json và quyền đọc/ghi .crew/, sửa xong chạy lại: crew queue' }
  if ($Remove) {
    try {
      $null = Update-QueueItems $root {
        param($current)
        if (-not @($current | Where-Object { $_.name -eq $Name }).Count) { throw "không có task tên $Name trong hàng đợi." }
        $current | Where-Object { $_.name -ne $Name }
      }
    } catch { Die $_.Exception.Message 'xem tên trong hàng đợi: crew queue' }
    Remove-Item -LiteralPath (Get-QueuePromptPath $root $Name) -Force -ErrorAction SilentlyContinue
    Say "đã bỏ $Name khỏi hàng đợi."
    return
  }
  if (-not $PromptFile) { Die "thiếu file prompt." "crew queue <tên> <file-prompt> [-Worker N] [-Review x] [-After <task>] [-Size S|M|L]" }
  if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Die "tên task chỉ gồm a-z 0-9 -, tối đa 31 ký tự." "đặt lại tên, vd. crew queue fix-login $PromptFile" }
  if (-not (Test-Path -LiteralPath $PromptFile)) { Die "không thấy file prompt $PromptFile" "kiểm đường dẫn (tính từ $((Get-Location).Path)) rồi chạy lại crew queue $Name <file-prompt>" }
  $cfg = Get-Config $root; $tasks = Get-Tasks $root
  if ($tasks | Where-Object { $_.name -eq $Name }) { Die "đã có task tên $Name." @("đặt tên khác hoặc đợi task $Name xong", "crew clean $Name", "crew queue $Name $PromptFile") }
  $n = @($cfg.workers).Count
  if ($Worker -and ($Worker -lt 1 -or $Worker -gt $n)) { Die "-Worker phải từ 1 tới $n." "bỏ -Worker (giao worker rảnh) hoặc dùng -Worker 1..$n" }
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/crew/$Name").Code -eq 0) { Die "nhánh crew/$Name đã có — đặt tên khác hoặc xóa nhánh cũ." @("git -C '$root' log --oneline -3 crew/$Name", "Chỉ xóa nếu chắc chắn bỏ nhánh:", "git -C '$root' branch -D crew/$Name") }
  if ($After -and $After -eq $Name) { Die "-After không được là chính nó." @('bỏ -After hoặc chọn task khác', 'crew hot', 'crew queue') }
  if ($After -and -not @($tasks | Where-Object { $_.name -eq $After }).Count -and -not @($items | Where-Object { $_.name -eq $After }).Count) {
    Die "không có task tên $After đang chạy hay trong hàng đợi — kiểm lại tên." @('crew hot', 'crew queue')
  }
  $dest = Get-QueuePromptPath $root $Name
  $source = (Resolve-Path -LiteralPath $PromptFile).Path
  $rv = if ($InitParameters.ContainsKey('Review')) { $Review } else { '' }
  $item = New-QueueItem $Name ".crew/queue/$Name.md" $Worker $rv $After $Size $source
  $upd = @{ At = 0 }
  try {
    $items = Update-QueueItems $root {
      param($current)
      New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
      # Tên đã trong hàng đợi (kiểm dưới khóa) ⇒ cập nhật bản chép tại chỗ, giữ vị trí; chỉ đổi cờ được truyền.
      $old = @($current | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
      if ($old) {
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($dest)) { Copy-Item -LiteralPath $source $dest -Force }
        $old | Add-Member -NotePropertyName source -NotePropertyValue $source -Force
        if ($InitParameters.ContainsKey('Worker')) { $old | Add-Member -NotePropertyName worker -NotePropertyValue $Worker -Force }
        if ($InitParameters.ContainsKey('Review')) { $old | Add-Member -NotePropertyName review -NotePropertyValue $Review -Force }
        if ($InitParameters.ContainsKey('After')) { $old | Add-Member -NotePropertyName after -NotePropertyValue $After -Force }
        if ($InitParameters.ContainsKey('Size')) { $old | Add-Member -NotePropertyName size -NotePropertyValue $Size -Force }
        $upd.At = [array]::IndexOf(@($current), $old) + 1
        return @($current)
      }
      Copy-Item -LiteralPath $source $dest -Force
      @($current) + $item
    }
  } catch { Die $_.Exception.Message 'xem lỗi ở trên; kiểm .crew/queue.json và quyền đọc/ghi .crew/, sửa xong chạy lại: crew queue' }
  if ($upd.At) {
    Say "đã cập nhật $Name trong hàng đợi (vị trí $($upd.At), prompt chép lại từ $source)."
    return
  }
  Say "đã xếp $Name vào hàng đợi (vị trí $($items.Count)). Giao khi có worker rảnh: crew clean, crew up, hoặc crew queue -Run."
}
