function Get-CrewInstallCommand {
  $bootstrap = 'https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap'
  if ((Get-CrewOS) -eq 'windows') { return "irm $bootstrap.ps1 | iex" }
  "curl -fsSL $bootstrap.sh | sh"
}

# Phiên bản sản phẩm độc lập với skeleton/VERSION.
function Get-CrewVersion {
  $root = Split-Path $CrewScriptsDir -Parent
  $file = Join-Path $root 'VERSION'
  $version = '?'
  try {
    $text = [IO.File]::ReadAllText($file).Trim()
    if ($text -notmatch '\A[1-9][0-9]*(\.[1-9][0-9]*)?\z') { throw 'cần phiên bản dạng N hoặc N.M, gồm các số nguyên dương không có số 0 đứng đầu' }
    $version = $text
  } catch { Write-Warning "Không đọc được VERSION '$file': $($_.Exception.Message)" }
  [pscustomobject]@{ Version = $version; Root = $root }
}

function Invoke-Version {
  $info = Get-CrewVersion
  Write-Host "Crewline v$($info.Version)"
  Write-Host "Cài tại: $($info.Root)"
}

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
  } catch { Die "mẫu đội '$file' không hợp lệ: $($_.Exception.Message)" @("sửa JSON trong '$file'", 'Hoặc cài lại Crewline:', (Get-CrewInstallCommand)) }
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
  } catch { Die "config cá nhân '$file' không hợp lệ: $($_.Exception.Message)" @("mở '$file' sửa giá trị đó", 'Hoặc chọn lại đội:', "crew setup") }
}

# Chọn đội cho init: cờ -Team > planner/workers/rev đủ trong config > team trong config > standard.
function Select-Team($teams, $defaults) {
  if ($InitParameters.ContainsKey('Team')) {
    $name = @($teams.Keys) | Where-Object { $_ -eq $Team } | Select-Object -First 1
    if (-not $name) { Die "-Team phải là: $(@($teams.Keys) -join ', ')" "chạy lại với một tên trên, vd. crew init -Team $(@($teams.Keys)[0])" }
    return $teams[$name]
  }
  if ($defaults.ContainsKey('planner') -and $defaults.ContainsKey('workers') -and $defaults.ContainsKey('rev')) {
    return @{ planner = $defaults.planner; workers = $defaults.workers; rev = $defaults.rev }
  }
  if ($defaults.team -ceq 'custom') { Die "config cá nhân có team 'custom' nhưng thiếu planner/workers/rev (cần đủ cả ba)." @('crew setup', 'Hoặc tạo project với đội standard:', 'crew init -Team standard') }
  if ($defaults.team) { return $teams[$defaults.team] }
  if (-not $teams.Contains('standard')) { Die "scripts/teams.json thiếu mẫu 'standard'." "cài lại Crewline: $(Get-CrewInstallCommand)" }
  return $teams['standard']
}

function Get-SkeletonVersion {
  $v = (Get-Content (Join-Path $Skeleton 'VERSION') -Raw -Encoding utf8).Trim()
  if ($v -notmatch '^[1-9][0-9]*$') { Die 'skeleton/VERSION phải là số nguyên dương.' "cài lại Crewline: $(Get-CrewInstallCommand)" }
  return $v
}

function Say($msg) { Write-Host "crew: $msg" }
function Get-CrewCommandSuggestion([string]$command, [string[]]$choices) {
  $best = 2
  $matches = @()
  foreach ($choice in $choices) {
    $previous = @(0..$choice.Length)
    for ($i = 1; $i -le $command.Length; $i++) {
      $row = @($i)
      for ($j = 1; $j -le $choice.Length; $j++) {
        $cost = if ([char]::ToLowerInvariant($command[$i - 1]) -eq $choice[$j - 1]) { 0 } else { 1 }
        $row += [Math]::Min([Math]::Min($previous[$j] + 1, $row[$j - 1] + 1), $previous[$j - 1] + $cost)
      }
      $previous = $row
    }
    $distance = $previous[$choice.Length]
    if ($distance -lt $best) { $best = $distance; $matches = @($choice) }
    elseif ($distance -eq $best) { $matches += $choice }
  }
  if ($best -le 1 -and $matches.Count -eq 1) { $matches[0] }
}
# $next: bước tiếp theo (lệnh chép chạy được hoặc chỗ cần sửa); rỗng ⇒ chỉ in lỗi như cũ.
function Die($msg, $next = '') {
  Write-Host "crew: LỖI: $msg" -ForegroundColor Red
  if ($next) {
    Write-Host '  → Làm tiếp:'
    foreach ($step in $next) {
      foreach ($line in ($step -split '\r?\n')) {
        if ($line.Trim()) { Write-Host "    $line" }
      }
    }
  }
  exit 1
}

# Ghi nguyên tử file state: $text ghi đúng byte (UTF-8 không BOM, người gọi tự thêm xuống dòng cuối như trước) vào file tạm
# cùng thư mục rồi đổi tên đè lên. Lỗi ⇒ xóa file tạm, file cũ còn nguyên, ném lỗi. Đổi tên thử lại ~2 giây vì trên Windows
# người đọc không khóa (Get-Tasks) đang mở file thì đè tạm thời bị từ chối.
function Write-CrewStateFile([string]$file, [string]$text) {
  $dir = Split-Path -Parent $file
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $tmp = Join-Path $dir ('.{0}.{1}.{2}.tmp' -f [IO.Path]::GetFileName($file), $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    Set-Content -LiteralPath $tmp -Value $text -NoNewline -Encoding utf8NoBOM -ErrorAction Stop
    for ($try = 1; ; $try++) {
      try { [IO.File]::Move($tmp, $file, $true); break }
      catch {
        if ($try -ge 50) {
          $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
          throw "không ghi được $file ($why) — file cũ giữ nguyên"
        }
        Start-Sleep -Milliseconds 40
      }
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

# Khóa chuỗi đọc-sửa-ghi tasks.json/queue.json theo root: .crew/state.lock mở FileShare.None (tiến trình khác chờ).
# Lồng nhau trong cùng tiến trình thì chạy thẳng. Chờ quá $timeoutMs ⇒ ném lỗi, không chạy $body. Nhả trong finally (cả khi Die/exit).
# Không giữ khóa qua tiến trình con crew (queue gọi crew task) — con cũng cần khóa này.
function Use-CrewStateLock([string]$root, [scriptblock]$body, [int]$timeoutMs = 10000) {
  $lockFile = [IO.Path]::GetFullPath((Join-Path $root '.crew/state.lock'))
  if ($null -eq $script:CrewStateLocks) { $script:CrewStateLocks = @{} }
  if ($script:CrewStateLocks.ContainsKey($lockFile)) { return & $body }
  $dir = Split-Path -Parent $lockFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $fs = $null
  while (-not $fs) {
    try { $fs = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch {
      if ($sw.ElapsedMilliseconds -ge $timeoutMs) {
        throw "$lockFile đang bị lệnh crew khác giữ quá $([math]::Round($timeoutMs / 1000, 1)) giây — chưa ghi gì; đợi lệnh kia xong rồi chạy lại (lệnh treo thì tắt nó)."
      }
      Start-Sleep -Milliseconds 50
    }
  }
  $script:CrewStateLocks[$lockFile] = $fs
  try { & $body }
  finally { $script:CrewStateLocks.Remove($lockFile); $fs.Dispose() }
}

# Chạy git, gom stdout+stderr thành chuỗi; không ném lỗi khi git ghi stderr (PS 5.1 + EAP Stop).
function Invoke-GitQuiet {
  $ErrorActionPreference = 'Continue'
  $out = & git @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n").Trim() }
}

# Như Invoke-GitQuiet nhưng lỗi thì Die kèm output của git.
# Bước tiếp theo: `-Next '<việc>'` đứng ngay sau $what (không truyền cho git); thiếu ⇒ trỏ git status của thư mục -C.
function Invoke-GitOrDie([string]$what) {
  $gitArgs = @($args); $next = ''
  if ($gitArgs.Count -ge 2 -and "$($gitArgs[0])" -eq '-Next') { $next = [string]$gitArgs[1]; $gitArgs = @($gitArgs | Select-Object -Skip 2) }
  $r = Invoke-GitQuiet @gitArgs
  if ($r.Code -ne 0) {
    if (-not $next) {
      $at = [array]::IndexOf([object[]]$gitArgs, '-C')
      $dir = if ($at -ge 0 -and $at + 1 -lt $gitArgs.Count) { " -C '$($gitArgs[$at + 1])'" } else { '' }
      $next = "đọc lỗi git ở trên, kiểm: git$dir status — sửa xong chạy lại lệnh crew vừa gõ"
    }
    Die "$what thất bại: $($r.Text)" $next
  }
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

# ---------------- gợi ý Claude (config "suggestions") ----------------
# .crew/config.json "suggestions": "off" (mặc định: mọi pane tắt gợi ý câu kế tiếp của Claude Code) | "planner" (pane planner bật) | "all".
# Hàm thuần: giá trị config ⇒ chế độ; thiếu ⇒ 'off', sai ⇒ 'off' (crew hot cảnh báo giá trị sai).
function Get-SuggestionMode($value) {
  $v = "$value".Trim().ToLowerInvariant()
  if ($v -in 'off', 'planner', 'all') { return $v }
  'off'
}

# Hàm thuần: vai ('planner' | 'rev' | 'w<N>') có bật gợi ý Claude không, theo giá trị config.
function Test-SuggestionsOn($value, [string]$role) {
  $m = Get-SuggestionMode $value
  $m -eq 'all' -or ($m -eq 'planner' -and $role -eq 'planner')
}

# Pane hc tên '<crew>-<vai>' chạy ở $cwd (root hoặc worktree w<N>) có bật gợi ý không: đọc .crew/config.json của repo chính.
# Không Die: thiếu config/JSON hỏng/không phải git ⇒ $false (tắt như cũ).
function Test-PaneSuggestions([string]$name, [string]$cwd) {
  if ($name -notmatch '-(planner|rev|w\d+)$') { return $false }
  $role = $Matches[1]
  try {
    $r = Invoke-GitQuiet -C $cwd rev-parse --path-format=absolute --git-common-dir
    if ($r.Code -ne 0 -or -not $r.Text) { return $false }
    $file = Join-Path (Split-Path $r.Text -Parent) '.crew/config.json'
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $cfg = Read-CrewState $file -ThrowOnError
    return [bool](Test-SuggestionsOn $cfg.suggestions $role)
  } catch { return $false }
}

# Đoạn lệnh pwsh đặt đầu lệnh bật agent (Start-Term, task.ps1 bật agent trong shell): chỗ DUY NHẤT dựng biến gợi ý.
# Tắt: CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false (gợi ý mờ nằm trong ô nhập, hc read không có màu ⇒ giống tin kẹt).
# Bật: xóa biến (pane crew cha có thể đã truyền 'false'). Chỉ trong pwsh của pane; crew không sửa ~/.claude/settings.json.
function Get-SuggestionEnvLine([bool]$on) {
  if ($on) { return "Remove-Item Env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION -ErrorAction Ignore; " }
  "`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; "
}

# ---------------- planner hỗ trợ khi crew không chắc (config "assist", v16 screen-assist) ----------------
# .crew/config.json "assist": "off" (như cũ: không in khối) | "ask" (mặc định: in khối "CẦN PLANNER XEM",
# planner đề xuất, chờ chủ dự án) | "auto" (planner tự quyết rồi báo chủ dự án 1 dòng). Hàm thuần: thiếu/sai ⇒ 'ask' (crew hot cảnh báo sai).
function Get-AssistMode($value) {
  $v = "$value".Trim().ToLowerInvariant()
  if ($v -in 'off', 'ask', 'auto') { return $v }
  'ask'
}
