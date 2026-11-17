# ---- space herdr live (lớp kiểm cho project chưa vào sổ) ----
# Đọc `herdr-app ls` một lần: @{ Ok; Spaces; Error }. Không có lệnh/lỗi/JSON hỏng ⇒ Ok = $false (người gọi cảnh báo, không chặn).
function Get-HerdrSpaces {
  if (-not (Get-Command herdr-app -ErrorAction SilentlyContinue)) { return @{ Ok = $false; Spaces = @(); Error = 'không có herdr-app' } }
  try {
    # herdr-app.exe là app GUI trên Windows: gán thẳng `$x = herdr-app ls` không chờ (stdout trống); qua pipe thì PowerShell chờ đọc hết.
    $text = & { $ErrorActionPreference = 'Continue'; herdr-app ls 2>$null | Out-String }
    if (-not "$text".Trim()) { return @{ Ok = $false; Spaces = @(); Error = 'herdr-app ls không trả gì' } }
    $j = $text | ConvertFrom-Json
    if ($null -eq $j -or $j.PSObject.Properties.Name -notcontains 'spaces') { return @{ Ok = $false; Spaces = @(); Error = 'herdr-app ls thiếu spaces' } }
    return @{ Ok = $true; Spaces = @($j.spaces | Where-Object { $_ }); Error = '' }
  } catch { return @{ Ok = $false; Spaces = @(); Error = "herdr-app ls không đọc được ($($_.Exception.Message))" } }
}

# Thư mục space thuộc project $root (root hoặc worktree w<N>, như cwd terminal).
function Test-FolderOwner([string]$folder, [string]$root) { Test-TermOwner ([pscustomobject]@{ cwd = $folder }) $root }

# Hàm thuần: space id của crew này (hoặc tab id tbcrew<key>…) đã có trong herdr mà folder thuộc project khác, hoặc terminal
# trong đó có cwd (hc ls, $liveTerms) thuộc project khác ⇒ lý do; '' khi ổn. $ids = Get-Ids; $spaces = (Get-HerdrSpaces).Spaces.
function Get-ForeignSpaceError($ids, [string]$root, $spaces, $liveTerms) {
  $tabIds = @($ids.Planner, $ids.Rev) + @(1..3 | ForEach-Object { & $ids.Workers $_ }) | Where-Object { $_ }
  $byAddr = @{}
  foreach ($t in @($liveTerms)) { if ($t -and $t.address) { $byAddr[[string]$t.address] = $t } }
  foreach ($sp in @($spaces)) {
    if (-not $sp) { continue }
    $hitTabs = @(@($sp.tabs) | Where-Object { $_ -and $tabIds -ccontains [string]$_.id })
    if ([string]$sp.id -cne $ids.Space -and -not $hitTabs.Count) { continue }
    $what = if ([string]$sp.id -ceq $ids.Space) { "space $($sp.id)" } else { "tab $(@($hitTabs | ForEach-Object { $_.id }) -join ', ') trong space $($sp.id)" }
    $hint = "Đặt tên khác: crew init -Name <tên khác> (sinh idKey mới), hoặc sửa `"name`"/`"idKey`" trong .crew/config.json."
    if ($sp.folder -and -not (Test-FolderOwner ([string]$sp.folder) $root)) {
      return "$what của herdr đang thuộc thư mục $($sp.folder), không phải $root — trùng khóa id với crew khác. $hint"
    }
    $tabs = if ([string]$sp.id -ceq $ids.Space) { @($sp.tabs) } else { $hitTabs }
    foreach ($tb in $tabs) {
      foreach ($tm in @($tb.terminals)) {
        $lt = if ($tm) { $byAddr[[string]$tm.terminal] } else { $null }
        if ($lt -and $lt.cwd -and -not (Test-TermOwner $lt $root)) {
          return "$what của herdr có terminal $($lt.name) ($($tm.terminal)) chạy ở $($lt.cwd), không phải $root — trùng khóa id với crew khác. $hint"
        }
      }
    }
  }
  ''
}

# Khóa id đang bị space herdr của project khác dùng (space spcrew<key> có folder không thuộc $root). Hàm thuần.
function Get-TakenIdKeys($spaces, [string]$root) {
  @(foreach ($sp in @($spaces)) {
      if ($sp -and [string]$sp.id -cmatch '^spcrew([a-z0-9]+)$' -and $sp.folder -and -not (Test-FolderOwner ([string]$sp.folder) $root)) { $Matches[1] }
    })
}

# Ghi $n -> @{ $root; $idKey } vào sổ (bỏ tên cũ của cùng root). Sổ hỏng ⇒ cảnh báo, không ghi đè.
# Tên hoặc idKey đang thuộc root khác còn tồn tại ⇒ giữ chủ cũ, không ghi, cảnh báo. Trả $true khi đã ghi.
function Register-CrewName([string]$n, [string]$root, [string]$idKey) {
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Say "cảnh báo: $($reg.Error) — không ghi sổ; sửa hoặc xóa file đó rồi chạy lại crew init."; return $false }
  $map = $reg.Map
  $other = Get-NameOwner $map $n $root
  if (-not $other) { $other = Get-IdKeyOwner $map $idKey $root }
  if ($other) { Say "cảnh báo: tên '$n'/idKey '$idKey' đã thuộc project $other trong sổ — giữ nguyên chủ cũ, không ghi sổ. Đổi tên: crew init -Name <tên>."; return $false }
  foreach ($k in @($map.Keys)) { if ($k -ne $n -and (Test-SamePath ([string]$map[$k].Root) $root)) { $map.Remove($k) } }
  $map[$n] = @{ Root = (ConvertTo-RootKey $root); IdKey = $idKey }
  Save-ProjectRegistry $map
  $true
}

# Tên crew hoặc khóa id của project đã thuộc root khác còn tồn tại trong sổ (vd chép nguyên thư mục,
# hoặc project cũ trùng khóa cũ my-app/myapp) ⇒ lý do; '' khi ổn. Không tự đổi gì.
function Get-NameConflict([string]$root, $cfg) {
  if (-not $cfg) { return '' }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { return '' }
  $hasName = $cfg.PSObject.Properties.Name -contains 'name' -and $cfg.name
  if ($hasName) {
    $other = Get-NameOwner $reg.Map ([string]$cfg.name) $root
    if ($other) { return "tên crew '$($cfg.name)' (.crew/config.json) đã thuộc project $other (sổ $(Get-ProjectsFile)) — có thể do chép nguyên thư mục. Đổi tên: crew init -Name <tên> (hoặc sửa `"name`" trong config)." }
  }
  $n = if ($hasName) { [string]$cfg.name } else { Get-LegacySlug $root }
  if (-not $n -and -not ($cfg.PSObject.Properties.Name -contains 'idKey')) { return '' }
  $k = Get-CrewIdKey $root $cfg
  $other = Get-IdKeyOwner $reg.Map $k $root
  if ($other) { return "khóa id herdr '$k' (space spcrew$k) của project này trùng project $other (sổ $(Get-ProjectsFile)) — hai crew sẽ dùng chung space/tab. Đổi tên: crew init -Name <tên> (sinh idKey mới), hoặc sửa `"name`"/`"idKey`" trong .crew/config.json." }
  ''
}

function Get-CrewStateSchema { 1 }

# Mảng tasks/queue giữ nguyên định dạng cũ; schema chỉ nằm ở object config/sessions.
function Read-CrewState([string]$file, [switch]$ThrowOnError) {
  try {
    $raw = [IO.File]::ReadAllText($file)
    $leaf = [IO.Path]::GetFileName($file)
    if (-not $raw.Trim().Trim([char]0xFEFF).Trim()) {
      if ($leaf -in 'tasks.json', 'queue.json') {
        $kind = if ($leaf -eq 'tasks.json') { 'task' } else { 'mục hàng đợi' }
        Write-Host "crew: CẢNH BÁO: $file trống — coi như không có $kind." -ForegroundColor Yellow
        return , @()
      }
      throw 'JSON trống'
    }
    try {
      $j = ConvertFrom-Json -InputObject $raw -NoEnumerate -ErrorAction Stop
      if ($null -eq $j -or ($j -isnot [array] -and $j.GetType() -ne [System.Management.Automation.PSCustomObject])) { throw 'cần object hoặc mảng' }
    } catch { throw "$file hỏng — sửa JSON hoặc khôi phục bản sao, không ghi đè file: $($_.Exception.Message)" }
    if ($j -is [pscustomobject] -and $j.PSObject.Properties.Name -contains 'schema') {
      if ($j.schema -isnot [int] -and $j.schema -isnot [long]) { throw "$file hỏng — schema phải là số nguyên; sửa JSON hoặc khôi phục bản sao." }
      if ($j.schema -gt (Get-CrewStateSchema)) { throw "$file`: dữ liệu do bản crew mới hơn ghi — cập nhật crew" }
    }
    if ($leaf -in 'config.json', 'sessions.json' -and $j.GetType() -ne [System.Management.Automation.PSCustomObject]) { throw "$file hỏng — cần object; sửa JSON hoặc khôi phục bản sao." }
    return ,$j
  } catch {
    $message = $_.Exception.Message
    if (-not $message.StartsWith($file, [StringComparison]::Ordinal)) { $message = "$file hỏng — sửa JSON hoặc khôi phục bản sao, không ghi đè file: $message" }
    if ($ThrowOnError) { throw $message }
    Die $message
  }
}

function Get-Config([string]$root) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path $f)) { Die "chưa có .crew/config.json — chạy 'crew init' trước." }
  $config = Read-CrewState $f
  if ($config.GetType() -ne [System.Management.Automation.PSCustomObject]) { Die "$f hỏng — config phải là object; sửa JSON hoặc khôi phục bản sao." }
  return $config
}

# Luôn trả mảng (0/1/nhiều phần tử): dấu phẩy chặn PowerShell bóc mảng khi trả về. Gán `$t = Get-Tasks`, không bọc `@(Get-Tasks)`.
function Get-Tasks([string]$root, [switch]$ThrowOnError) {
  $f = Join-Path $root '.crew/tasks.json'
  if (-not (Test-Path $f)) { return , @() }
  return , @((Read-CrewState $f -ThrowOnError:$ThrowOnError) | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Save-Tasks([string]$root, $tasks) {
  $file = Join-Path $root '.crew/tasks.json'
  if (Test-Path -LiteralPath $file) { $null = Read-CrewState $file }
  $list = @($tasks | Where-Object { $null -ne $_ })
  ConvertTo-Json -InputObject $list -Depth 100 | Set-Content (Join-Path $root '.crew/tasks.json') -Encoding utf8
}

function Get-Flags([string]$kind, [string]$access) {
  if ($kind -eq 'claude') {
    if ($access -eq 'wide') { return '--permission-mode bypassPermissions' }
    return '--permission-mode acceptEdits'
  }
  if ($access -eq 'wide') { return '--no-daemon --sandbox danger-full-access --ask-for-approval never' }
  return '--no-daemon --sandbox workspace-write --ask-for-approval on-request'
}

function Quote([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# dòng lệnh bật agent dùng chung cho planner, worker, Rev; cờ quyền theo access (codex đã có --no-daemon trong Get-Flags).
# Một đường cho mọi hệ: lệnh chạy trong pwsh (Start-Term); pwsh tự tìm claude/codex trên PATH (npm shim .cmd/.ps1 trên Windows, file thực thi trên Unix).
# $session (Get-SessionPlan): resume-id / continue / resume-last mở lại phiên, KHÔNG kèm prompt để agent không tự chạy; new-id = hội thoại mới có id do crew đặt.
function Get-AgentCommand([string]$kind, [string]$access, [string]$line, $session = $null) {
  $exe = if ($kind -eq 'codex') { 'codex' } else { 'claude' }
  $flags = Get-Flags $kind $access
  switch ($(if ($session) { $session.Mode } else { '' })) {
    'resume-id' { return "$exe $flags --resume $($session.Id)" }
    'continue' { return "$exe $flags --continue" }
    'resume-last' { return "$exe resume --last $flags" }
    'new-id' { return "$exe $flags --session-id $($session.Id) $(Quote $line)" }
  }
  "$exe $flags $(Quote $line)"
}
