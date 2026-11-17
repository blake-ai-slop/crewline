function Get-CrewBlock {
  return @'
<!-- crew -->
## Context dùng chung (crew)
Đọc `context/README.md` trước (thứ tự: PROJECT → HOT → PITFALLS → DECISIONS).
- Làm trong worktree/nhánh được giao. Worker chỉ ghi `context/tasks/<tên>.md` của mình; file context dùng chung do Rev/planner ghi.
- Không push (chỉ planner push khi chủ dự án cho phép). Mặc định chế độ gọn: worker chạy test của phần mình, không tự review.
- Bản đồ code: context/MAP.md.
<!-- /crew -->
'@
}

# Kiểm một vai (planner/rev/workers) và trả giá trị đã chuẩn hóa; sai thì ném lỗi nêu khóa và giá trị cho phép.
function Test-Role([string]$key, $value) {
  $agents = @('claude', 'codex', 'none')
  if ($key -eq 'workers') {
    $items = @($value)
    if ($value -isnot [array] -or $items.Count -lt 1 -or $items.Count -gt 6 -or
      @($items | Where-Object { $_ -isnot [string] -or @('claude', 'codex') -cnotcontains $_ }).Count) {
      throw "giá trị 'workers' phải là mảng 1–6 phần tử, mỗi phần tử là: claude, codex"
    }
    return , [string[]]$items
  }
  if ($value -isnot [string] -or $agents -cnotcontains $value) { throw "giá trị '$key' phải là: $($agents -join ', ')" }
  return $value
}

# Mẫu đội từ scripts/teams.json (nguồn duy nhất, setup.ps1 cũng đọc). Trả [ordered] tên -> @{ planner; workers; rev }.
function Get-Teams {
  $file = Join-Path $CrewScriptsDir 'teams.json'
  try {
    $json = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    if ($null -eq $json -or $json -isnot [pscustomobject]) { throw 'cần một JSON object' }
    $teams = [ordered]@{}
    foreach ($p in $json.PSObject.Properties) {
      if ($p.Name -ceq 'custom' -or $p.Value -isnot [pscustomobject]) { throw "mẫu '$($p.Name)' không hợp lệ" }
      $teams[$p.Name] = @{}
      foreach ($key in 'planner', 'workers', 'rev') { $teams[$p.Name][$key] = Test-Role $key $p.Value.$key }
    }
    if (-not $teams.Count) { throw 'chưa có mẫu đội nào' }
    return $teams
  } catch { Die "mẫu đội '$file' không hợp lệ: $($_.Exception.Message)" }
}

function Get-UserDefaults($teams) {
  $file = if ($env:CREWLINE_USER_CONFIG) { $env:CREWLINE_USER_CONFIG } else { Join-Path $HOME '.crewline/config.json' }
  if (-not (Test-Path -LiteralPath $file)) { return @{} }
  try {
    $config = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    if ($null -eq $config -or $config -isnot [pscustomobject]) { throw 'cần một JSON object' }
    $allowed = @{ team = @($teams.Keys) + 'custom'; review = @('lean', 'fast', 'full'); access = @('work', 'wide') }
    $result = @{}
    foreach ($key in $allowed.Keys) {
      if ($config.PSObject.Properties.Name -contains $key) {
        if ($config.$key -isnot [string] -or $allowed[$key] -cnotcontains $config.$key) { throw "giá trị '$key' phải là: $($allowed[$key] -join ', ')" }
        $result[$key] = $config.$key
      }
    }
    foreach ($key in 'planner', 'workers', 'rev') {
      if ($config.PSObject.Properties.Name -contains $key) { $result[$key] = Test-Role $key $config.$key }
    }
    return $result
  } catch { Die "config cá nhân '$file' không hợp lệ: $($_.Exception.Message)" }
}

# Chọn đội cho init: cờ -Team > planner/workers/rev đủ trong config > team trong config > standard.
function Select-Team($teams, $defaults) {
  if ($InitParameters.ContainsKey('Team')) {
    $name = @($teams.Keys) | Where-Object { $_ -eq $Team } | Select-Object -First 1
    if (-not $name) { Die "-Team phải là: $(@($teams.Keys) -join ', ')" }
    return $teams[$name]
  }
  if ($defaults.ContainsKey('planner') -and $defaults.ContainsKey('workers') -and $defaults.ContainsKey('rev')) {
    return @{ planner = $defaults.planner; workers = $defaults.workers; rev = $defaults.rev }
  }
  if ($defaults.team -ceq 'custom') { Die "config cá nhân có team 'custom' nhưng thiếu planner/workers/rev (cần đủ cả ba)." }
  if ($defaults.team) { return $teams[$defaults.team] }
  if (-not $teams.Contains('standard')) { Die "scripts/teams.json thiếu mẫu 'standard'." }
  return $teams['standard']
}

function Get-SkeletonVersion {
  $v = (Get-Content (Join-Path $Skeleton 'VERSION') -Raw -Encoding utf8).Trim()
  if ($v -notmatch '^[1-9][0-9]*$') { Die 'skeleton/VERSION phải là số nguyên dương.' }
  return $v
}

function Say($msg) { Write-Host "crew: $msg" }
function Die($msg) { Write-Host "crew: LỖI: $msg" -ForegroundColor Red; exit 1 }

# Chạy git, gom stdout+stderr thành chuỗi; không ném lỗi khi git ghi stderr (PS 5.1 + EAP Stop).
function Invoke-GitQuiet {
  $ErrorActionPreference = 'Continue'
  $out = & git @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n").Trim() }
}

# Như Invoke-GitQuiet nhưng lỗi thì Die kèm output của git.
function Invoke-GitOrDie([string]$what) {
  $r = Invoke-GitQuiet @args
  if ($r.Code -ne 0) { Die "$what thất bại: $($r.Text)" }
  $r
}

function Get-Root([string]$p) {
  $r = Invoke-GitQuiet -C $p rev-parse --show-toplevel
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  return (Resolve-Path $r.Text).Path
}

# Hỏi có tạo repo/commit đầu không (giống crew setup). Trả 'yes' / 'no', hoặc $null khi không hỏi được.
function Read-GitInitChoice([string]$title, [string]$label) {
  if ($env:CREWLINE_DEFAULTS -eq '1') { return $null }
  . (Join-Path $CrewScriptsDir 'ui.ps1')
  $options = @((New-Option 'yes' $label -Alias 'y', 'yes'), (New-Option 'no' 'Thôi' -Alias 'n', 'no'))
  Read-Choice $title $options 'yes' -NoStep -NullOnEof
}
