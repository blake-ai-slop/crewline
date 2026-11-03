<#
crew (Crewline) - dựng và điều khiển "đội agent" trong herdr-app + hc (Windows, Linux, macOS; pwsh 7).

  Dùng hằng ngày
  crew up                  dựng đội, khôi phục nếu mất (project mới: hỏi tạo)
  crew up -All             như trên, cho mọi project (sau khi khởi động lại máy)
  crew status [-Path .]     đội đang làm gì

  Rồi sang tab planner và nói việc muốn làm.

  Khi cần
  crew up -Restart <vai>    bật lại agent (sau khi đổi agent hoặc quyền)
  crew setup               đổi đội mặc định cho project mới
  crew doctor              máy có thiếu gì không
  crew upgrade             cập nhật khung context của project
  crew init                tạo project với tùy chọn riêng (tên, đội)

  Chi tiết: crew help <lệnh>   ·   Lệnh agent dùng: crew help agent
  Tên cũ vẫn dùng được: crew hot [-Path .] = crew status.
Khung context lấy từ <Crewline>/skeleton.
#>
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string[]]$Name,
  [Parameter(Position = 2)][string]$PromptFile,
  [string]$Path = '.',
  [string]$Team,
  [ValidateSet('lean', 'fast', 'full')][string]$Review = 'lean',
  [ValidateSet('work', 'wide')][string]$Access = 'work',
  [int]$Worker = 0,
  [string]$Restart,
  [switch]$GitInit,
  [switch]$NoCommit,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$Raw,
  [switch]$All
)

# Chốt chặn: crew cần pwsh 7. Gọi bằng Windows PowerShell 5.1 (powershell.exe) thì chạy lại chính file này bằng pwsh.
# Chỉ Windows tới được nhánh này (Linux/macOS chỉ có pwsh 7) nên thông báo winget đúng hệ.
# Phần này phải chạy được trên 5.1: ở 5.1 + EAP Stop, stderr của lệnh native thành lỗi chặn (NativeCommandError).
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not $pwshCmd) {
    Write-Host 'crew: LỖI: crew cần PowerShell 7 (pwsh), máy chưa có. Cài từ https://aka.ms/powershell (hoặc winget install Microsoft.PowerShell), mở terminal mới rồi chạy lại.' -ForegroundColor Red
    exit 1
  }
  $argv = @()
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argv += "-$k" } }
    elseif ($v -is [array]) { $argv += "-$k"; $argv += ($v -join ',') }
    else { $argv += "-$k"; $argv += "$v" }
  }
  try { & $pwshCmd.Source -NoLogo -NoProfile -File $PSCommandPath @argv }
  catch { Write-Host "crew: LỖI: không chạy được pwsh ($($pwshCmd.Source)): $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
  exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'platform.ps1')
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Skeleton = Join-Path (Split-Path $PSScriptRoot -Parent) 'skeleton'
$Today = Get-Date -Format 'yyyyMMdd'
$InitParameters = $PSBoundParameters

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
  $file = Join-Path $PSScriptRoot 'teams.json'
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
  . (Join-Path $PSScriptRoot 'ui.ps1')
  $options = @((New-Option 'yes' $label -Alias 'y', 'yes'), (New-Option 'no' 'Thôi' -Alias 'n', 'no'))
  Read-Choice $title $options 'yes' -NoStep -NullOnEof
}

# ---------------- tên crew ----------------
# Slug kiểu cũ (trước khi config có `name`): giữ Y HỆT để project cũ không đổi tên terminal đang chạy. Chỉ Get-CrewName/upgrade gọi.
function Get-LegacySlug([string]$root) {
  $s = (Split-Path $root -Leaf).ToLower() -replace '[^a-z0-9]+', '-'
  $s = $s.Trim('-')
  if ($s.Length -gt 12) { $s = $s.Substring(0, 12).TrimEnd('-') }
  return $s
}

# Sinh tên cho project mới: bỏ dấu (FormD, bỏ NonSpacingMark, đ→d), lowercase, ký tự lạ → '-', ≤12 ký tự; rỗng ⇒ crew-<6 hex từ hash root>.
function Get-Slug([string]$root) {
  $leaf = (Split-Path $root -Leaf).Normalize([Text.NormalizationForm]::FormD)
  $plain = -join @($leaf.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
  $s = $plain.Replace('đ', 'd').Replace('Đ', 'D').ToLowerInvariant() -creplace '[^a-z0-9]+', '-'
  $s = $s.Trim('-')
  if ($s.Length -gt 12) { $s = $s.Substring(0, 12).TrimEnd('-') }
  if (-not $s) {
    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-RootKey $root).ToLowerInvariant()))
    $s = 'crew-' + (-join @($bytes[0..2] | ForEach-Object { $_.ToString('x2') }))
  }
  return $s
}

# Tên crew hợp lệ: a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'.
function Test-CrewName([string]$n) { $n -cmatch '^[a-z0-9](?:[a-z0-9-]{0,10}[a-z0-9])?$' }

# Tên crew của project — chỗ DUY NHẤT mọi lệnh lấy tên (terminal <tên>-planner|-w<N>|-rev, space spcrew<tên>).
# Config có `name` ⇒ dùng; chưa có (project cũ) ⇒ slug cũ y hệt.
function Get-CrewName([string]$root, $cfg) {
  if ($cfg -and $cfg.PSObject.Properties.Name -contains 'name' -and $null -ne $cfg.name) {
    $n = [string]$cfg.name
    if (-not (Test-CrewName $n)) { Die "tên crew '$n' trong .crew/config.json không hợp lệ (a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'). Sửa `"name`" hoặc chạy: crew init -Name <tên>" }
    return $n
  }
  $s = Get-LegacySlug $root
  if (-not $s) { Die "không suy ra được tên crew từ thư mục '$(Split-Path $root -Leaf)'. Chạy 'crew upgrade' (tự ghi name) hoặc 'crew init -Name <tên>'." }
  return $s
}

# Đường dẫn chuẩn hóa để so: tuyệt đối, bỏ dấu tách cuối, '/' và '\' như nhau trên Windows.
function ConvertTo-RootKey([string]$p) {
  $f = [IO.Path]::GetFullPath($p)
  if ($f.Length -gt 3 -or -not $IsWindows) { $f = $f.TrimEnd('\', '/') }
  if (-not $f) { $f = '/' }
  return $f
}

# So hai đường dẫn đã chuẩn hóa; Windows không phân biệt hoa thường.
function Test-SamePath([string]$a, [string]$b) {
  $cmp = if ($IsWindows -or $PSVersionTable.PSEdition -ne 'Core') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  [string]::Equals((ConvertTo-RootKey $a), (ConvertTo-RootKey $b), $cmp)
}

# Terminal (object `hc ls --json` / `hc get --json`) thuộc project $root: cwd là root hoặc <root>/.crew/worktrees/w<N>.
function Test-TermOwner($term, [string]$root) {
  $cwd = if ($term -and $term.cwd) { [string]$term.cwd } else { '' }
  if (-not $cwd) { return $false }
  if (Test-SamePath $cwd $root) { return $true }
  $key = ConvertTo-RootKey $cwd
  (Split-Path $key -Leaf) -match '^w\d+$' -and (Test-SamePath (Split-Path $key -Parent) (Join-Path $root '.crew/worktrees'))
}

# Lý do chặn khi terminal $name đang live mà thuộc project khác; '' khi của mình, không live, hoặc hc không báo cwd (không kiểm được).
function Get-ForeignTermError([string]$name, $term, [string]$root) {
  if (-not $term -or $term.state -ne 'live' -or -not $term.cwd) { return '' }
  if (Test-TermOwner $term $root) { return '' }
  "terminal $name đang chạy ở project khác (cwd $($term.cwd)), không phải $root — trùng tên crew. Đặt tên khác: crew init -Name <tên> trong project này, hoặc sửa `"name`" trong .crew/config.json."
}

# Khóa id herdr (space/tab) của crew: mã hóa đơn ánh từ tên [a-z0-9-]: 'z'→'zz', '-'→'zd' (my-app→myzdapp, myapp→myapp).
function ConvertTo-IdKey([string]$n) { $n.Replace('z', 'zz').Replace('-', 'zd') }
# Khóa kiểu cũ (trước idKey): tên bỏ '-' — chỉ để giữ space/tab của project cũ.
function Get-LegacyIdKey([string]$n) { $n -replace '-', '' }
function Test-IdKey([string]$k) { $k -cmatch '^[a-z0-9]{1,24}$' }

# Khóa id của project — chỗ DUY NHẤT: config có idKey ⇒ dùng; thiếu (project cũ) ⇒ khóa cũ từ tên như trước.
function Get-CrewIdKey([string]$root, $cfg) {
  if ($cfg -and $cfg.PSObject.Properties.Name -contains 'idKey' -and $null -ne $cfg.idKey) {
    $k = [string]$cfg.idKey
    if (-not (Test-IdKey $k)) { Die "idKey '$k' trong .crew/config.json không hợp lệ (a-z 0-9, 1–24 ký tự). Sửa `"idKey`" hoặc chạy: crew init -Name <tên>" }
    return $k
  }
  Get-LegacyIdKey (Get-CrewName $root $cfg)
}

# Sổ tên crew toàn máy: ~/.crewline/projects.json = { "<tên>": { "root": "<root tuyệt đối>", "idKey": "<khóa>" } }.
# Bản đầu ghi { "<tên>": "<root>" } — vẫn đọc được, idKey coi như khóa cũ (tên bỏ '-').
function Get-ProjectsFile { Join-Path $HOME '.crewline/projects.json' }

# Đọc sổ: @{ Ok; Map (tên -> @{ Root; IdKey }); Error }. Hỏng ⇒ Ok = $false (người gọi cảnh báo, không chặn).
function Read-ProjectRegistry {
  $f = Get-ProjectsFile
  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $f)) { return @{ Ok = $true; Map = $map; Error = '' } }
  try {
    $text = [IO.File]::ReadAllText($f)
    if (-not $text.Trim()) { return @{ Ok = $true; Map = $map; Error = '' } }
    $j = $text | ConvertFrom-Json
    if ($j -isnot [pscustomobject]) { throw 'cần một JSON object' }
    foreach ($p in $j.PSObject.Properties) {
      $v = $p.Value
      if ($v -is [string] -and $v) { $map[$p.Name] = @{ Root = $v; IdKey = (Get-LegacyIdKey $p.Name) }; continue }
      if ($v -isnot [pscustomobject] -or $v.root -isnot [string] -or -not $v.root) { throw "mục '$($p.Name)' cần root là đường dẫn" }
      $k = if ($v.idKey -is [string] -and $v.idKey) { $v.idKey } else { Get-LegacyIdKey $p.Name }
      $map[$p.Name] = @{ Root = $v.root; IdKey = $k }
    }
    return @{ Ok = $true; Map = $map; Error = '' }
  } catch { return @{ Ok = $false; Map = [ordered]@{}; Error = "sổ tên crew $f hỏng ($($_.Exception.Message))" } }
}

function Save-ProjectRegistry($map) {
  $f = Get-ProjectsFile
  New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $o = [ordered]@{}
  foreach ($k in @($map.Keys | Sort-Object)) { $o[$k] = [ordered]@{ root = $map[$k].Root; idKey = $map[$k].IdKey } }
  [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
}

# Mục sổ thuộc root khác còn tồn tại (có .crew/config.json)?
function Test-OtherAlive($entry, [string]$root) {
  $other = [string]$entry.Root
  -not (Test-SamePath $other $root) -and (Test-Path -LiteralPath (Join-Path $other '.crew/config.json'))
}

# Root khác đang giữ tên $n trong sổ (còn .crew/config.json); '' khi trống, của chính $root, hoặc root cũ không còn.
function Get-NameOwner($map, [string]$n, [string]$root) {
  if (-not $map.Contains($n)) { return '' }
  if (Test-OtherAlive $map[$n] $root) { return [string]$map[$n].Root }
  ''
}

# Root khác còn tồn tại đang dùng khóa id $k (space/tab herdr); ''.
function Get-IdKeyOwner($map, [string]$k, [string]$root) {
  foreach ($n in @($map.Keys)) {
    if ($map[$n].IdKey -ceq $k -and (Test-OtherAlive $map[$n] $root)) { return [string]$map[$n].Root }
  }
  ''
}

# Tên trống gần nhất: $base, rồi $base-2, -3… (cắt phần gốc để ≤12 ký tự). Trống = tên chưa ai giữ và idKey mới của nó chưa ai dùng.
# $takenKeys: khóa id đang bị space herdr live của project khác dùng (Get-TakenIdKeys), kể cả project chưa vào sổ.
function Resolve-CrewName([string]$base, [string]$root, $map, [string[]]$takenKeys = @()) {
  $free = { param($c) $k = ConvertTo-IdKey $c; -not (Get-NameOwner $map $c $root) -and -not (Get-IdKeyOwner $map $k $root) -and $takenKeys -cnotcontains $k }
  if (& $free $base) { return $base }
  for ($i = 2; $i -lt 1000; $i++) {
    $suffix = "-$i"; $b = $base
    if ($b.Length + $suffix.Length -gt 12) { $b = $b.Substring(0, 12 - $suffix.Length).TrimEnd('-') }
    $c = "$b$suffix"
    if (& $free $c) { return $c }
  }
  Die "không tìm được tên crew trống từ '$base' — chạy: crew init -Name <tên>"
}

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

function Get-Config([string]$root) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path $f)) { Die "chưa có .crew/config.json — chạy 'crew init' trước." }
  return Get-Content $f -Raw | ConvertFrom-Json
}

# Luôn trả mảng (0/1/nhiều phần tử): dấu phẩy chặn PowerShell bóc mảng khi trả về. Gán `$t = Get-Tasks`, không bọc `@(Get-Tasks)`.
function Get-Tasks([string]$root) {
  $f = Join-Path $root '.crew/tasks.json'
  if (-not (Test-Path $f)) { return , @() }
  return , @(Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Save-Tasks([string]$root, $tasks) {
  $list = @($tasks | Where-Object { $null -ne $_ })
  ConvertTo-Json -InputObject $list -Depth 5 | Set-Content (Join-Path $root '.crew/tasks.json') -Encoding utf8
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

# ---------------- sổ phiên (.crew/sessions.json) ----------------
# Chỉ ghi điều crew tự biết: vai, loại agent, root, UUID crew tạo. KHÔNG đọc file sessions/history của agent.
# roles.<vai> = { agent; root; sessionId? }. codexRootRoles = các vai đã chạy Codex ở gốc từ lần cuối gốc chỉ có một vai Codex:
# `resume --last` lấy phiên mới nhất theo thư mục, nên còn dấu vết vai khác là không phân biệt được.
function Get-SessionsFile([string]$root) { Join-Path $root '.crew/sessions.json' }
function New-SessionBook { @{ Roles = @{}; CodexRootRoles = @(); Warning = '' } }
function Test-SessionId($id) { $id -is [string] -and $id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }

# Không throw: thiếu file ⇒ sổ trống; hỏng ⇒ sổ trống + Warning. Mục sai dạng ⇒ coi như chưa ghi nhận.
function Read-SessionBook([string]$root) {
  $book = New-SessionBook
  $file = Get-SessionsFile $root
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $book }
  try {
    $j = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    if ($j -isnot [pscustomobject] -or $j.roles -isnot [pscustomobject]) { throw 'thiếu roles' }
    foreach ($p in $j.roles.PSObject.Properties) {
      $v = $p.Value
      if ($v -isnot [pscustomobject] -or $v.agent -isnot [string] -or $v.root -isnot [string]) { continue }
      $book.Roles[$p.Name] = @{ agent = $v.agent; root = $v.root; sessionId = $v.sessionId }
    }
    $book.CodexRootRoles = @($j.codexRootRoles | Where-Object { $_ -is [string] })
  } catch {
    $book = New-SessionBook
    $book.Warning = "sổ phiên $file hỏng, coi như chưa có ghi nhận ($($_.Exception.Message))."
  }
  $book
}

# Ghi nguyên tử; lỗi ⇒ chỉ cảnh báo (mất ghi nhận thì lần sau mở hội thoại mới, không hỏng gì).
function Save-SessionBook([string]$root, $book) {
  $file = Get-SessionsFile $root
  try {
    New-Item -ItemType Directory -Force (Split-Path $file) -ErrorAction Stop | Out-Null
    $roles = [ordered]@{}
    foreach ($k in @($book.Roles.Keys | Sort-Object)) {
      $r = $book.Roles[$k]
      $o = [ordered]@{ agent = $r.agent; root = $r.root }
      if ($r.sessionId) { $o.sessionId = $r.sessionId }
      $roles[$k] = $o
    }
    $text = ConvertTo-Json -InputObject ([ordered]@{ version = 1; roles = $roles; codexRootRoles = @($book.CodexRootRoles) }) -Depth 5
    $tmp = "$file.tmp"
    [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $file -Force -ErrorAction Stop
  } catch { Say "cảnh báo: không ghi được sổ phiên $file ($($_.Exception.Message)); lần khôi phục sau sẽ mở hội thoại mới." }
}

# Vai vừa bật hội thoại mới. Hội thoại mới của vai Codex duy nhất ở gốc là phiên mới nhất ở đó nên xóa được dấu vết vai cũ.
function Set-SessionRecord($book, [string]$root, $cfg, [string]$role, [string]$kind, $session) {
  $rec = @{ agent = $kind; root = $root }
  if ($session -and $session.Id) { $rec.sessionId = $session.Id }
  $book.Roles[$role] = $rec
  if ($role -notlike 'w*' -and $kind -eq 'codex') {
    $count = @(@($cfg.planner, $cfg.rev) | Where-Object { $_ -eq 'codex' }).Count
    $book.CodexRootRoles = if ($count -le 1) { @($role) } else { @(@($book.CodexRootRoles) + $role | Select-Object -Unique) }
  }
}

function Get-NewSessionPlan([string]$role, [string]$kind, [string]$reason, [bool]$warn = $false) {
  $session = if ($role -notlike 'w*' -and $kind -eq 'claude') { @{ Mode = 'new-id'; Id = [guid]::NewGuid().ToString() } } else { $null }
  @{ Resume = $false; Session = $session; Reason = $reason; Warn = $warn }
}

# Chọn phiên cho một vai sắp bật. $blocked khác rỗng ⇒ tình huống không khôi phục (-Restart), là lý do. Không ghi gì (DryRun dùng chung).
function Get-SessionPlan($book, [string]$root, $cfg, [string]$role, [string]$kind, [string]$blocked = '') {
  if ($blocked) { return Get-NewSessionPlan $role $kind $blocked }
  $rec = $book.Roles[$role]
  if (-not $rec) { return Get-NewSessionPlan $role $kind 'chưa có ghi nhận phiên' }
  if ($rec.agent -cne $kind) { return Get-NewSessionPlan $role $kind "đã đổi agent $($rec.agent) sang $kind" }
  if (-not (Test-SamePath $rec.root $root)) { return Get-NewSessionPlan $role $kind "sổ ghi root khác ($($rec.root))" }
  $resume = { param($mode, $id, $why) @{ Resume = $true; Session = @{ Mode = $mode; Id = $id }; Reason = $why; Warn = $false } }
  if ($role -like 'w*') {
    if ($kind -eq 'codex') { return & $resume 'resume-last' $null 'phiên Codex mới nhất của worktree' }
    return & $resume 'continue' $null 'phiên Claude mới nhất của worktree'
  }
  if ($kind -eq 'claude') {
    if (Test-SessionId $rec.sessionId) { return & $resume 'resume-id' $rec.sessionId "phiên $($rec.sessionId)" }
    return Get-NewSessionPlan $role $kind 'sổ không có id phiên hợp lệ' $true
  }
  $count = @(@($cfg.planner, $cfg.rev) | Where-Object { $_ -eq 'codex' }).Count
  if ($count -gt 1) { return Get-NewSessionPlan $role $kind 'hai vai Codex cùng chạy ở thư mục gốc, không phân biệt được phiên' $true }
  $others = @(@($book.CodexRootRoles) | Where-Object { $_ -cne $role })
  if ($others.Count -or @($book.CodexRootRoles) -cnotcontains $role) { return Get-NewSessionPlan $role $kind 'thư mục gốc từng có vai Codex khác, không phân biệt được phiên' $true }
  & $resume 'resume-last' $null 'vai Codex duy nhất ở thư mục gốc'
}

function Format-SessionPlan($plan) { "$(if ($plan.Resume) { 'mở lại hội thoại' } else { 'hội thoại mới' }) ($($plan.Reason))" }

# Màn hình đang là TUI của agent? Sau khi mở lại phiên mà chưa có lượt mới, hc có thể chưa báo status.app.
# Chân màn hình chỉ agent mới có; dòng cuối là dấu nhắc shell thì agent đã thoát dù chữ cũ còn trên màn hình.
function Test-AgentScreen([string]$kind, [string]$screen) {
  $last = @("$screen" -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\[hc\]' }) | Select-Object -Last 1
  if ("$last" -match '(^\s*PS .*>|[$#])\s*$') { return $false }
  if ($kind -eq 'codex') { return "$screen" -match 'Context \d+% left' }
  "$screen" -match '(accept edits|bypass permissions|auto mode|plan mode) on|shift\+tab to cycle'
}

# Trạng thái pane vừa mở lại phiên: 'ready' | 'exited' (CLI thoát, về shell) | 'dialog' (hộp thoại/chờ duyệt, không bấm) | '' (chưa rõ).
function Get-ResumeState([string]$term, [string]$kind, $ops) {
  $info = & $ops.Get $term
  if (-not $info) { return '' }
  if ($info.state -ne 'live') { return 'exited' }
  $screen = & $ops.Read $term
  if ((Get-TermStatus $info).State -eq 'blocked' -or (Get-ScreenDialog $screen)) { return 'dialog' }
  if ((Get-TermShellState $info { $screen }) -eq 'exited') { return 'exited' }
  $mode = (Get-WorkerMode $info $kind).Mode
  if ($mode -eq 'agent' -or ($mode -eq 'shell' -and (Test-AgentScreen $kind $screen))) { return 'ready' }
  ''
}

# Chờ các pane vừa mở lại phiên, tối đa ~30s, không gửi hay bấm phím. Trả map Term -> trạng thái cuối.
function Wait-ResumeStates($roles, $ops, [int]$tries = 15) {
  $out = @{}; $pending = @($roles)
  for ($i = 0; $i -lt $tries -and $pending.Count; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $next = @()
    foreach ($role in $pending) {
      $s = Get-ResumeState $role.Term $role.Kind $ops
      $out[$role.Term] = $s
      if (-not $s) { $next += $role }
    }
    $pending = $next
  }
  $out
}

# Terminal từ `hc ls --json`. Thành công rỗng (terminals: []) ⇒ @(); exit≠0, JSON hỏng hoặc thiếu mảng 'terminals' ⇒ throw
# (không bao giờ trả [] khi lỗi). Chỗ ra quyết định (up, repair) coi lỗi là dừng; chỗ hiển thị (hot, limits, gợi ý chuyển) chỉ cảnh báo.
function Get-LiveTerminals {
  $out = & { $ErrorActionPreference = 'Continue'; hc ls --json 2>$null }
  $code = $LASTEXITCODE
  if ($code -ne 0) { throw "hc ls --json lỗi (exit $code)" }
  $text = (@($out) -join "`n").Trim()
  try { $j = $text | ConvertFrom-Json } catch { throw "hc ls --json trả JSON hỏng (exit $code): $($_.Exception.Message)" }
  if ($null -eq $j -or $j -isnot [pscustomobject] -or $j.PSObject.Properties.Name -notcontains 'terminals') { throw "hc ls --json thiếu mảng 'terminals' (exit $code)" }
  # terminals phải là mảng JSON; từng phần tử phải có address/state (chuỗi khác rỗng) + name (chuỗi, null nếu chưa đặt tên).
  # Sai shape ⇒ ném lỗi, KHÔNG lọc thành rỗng (rỗng = "0 terminal" ⇒ repair sẽ đóng space còn terminal lạ).
  $arr = $j.terminals
  if ($arr -isnot [array]) { $kind = if ($null -eq $arr) { 'null' } else { $arr.GetType().Name }; throw "hc ls --json: 'terminals' không phải mảng ($kind, exit $code)" }
  for ($i = 0; $i -lt $arr.Count; $i++) {
    $t = $arr[$i]
    if ($t -isnot [pscustomobject]) { throw "hc ls --json: terminals[$i] không phải object (exit $code)" }
    $p = $t.PSObject.Properties.Name
    foreach ($k in 'address', 'state') { if ($p -notcontains $k -or $t.$k -isnot [string] -or -not $t.$k) { throw "hc ls --json: terminals[$i] thiếu/sai '$k' (exit $code)" } }
    # hc bỏ hẳn khóa name với terminal chưa đặt tên (mọi pane người dùng tự mở trong herdr) ⇒ coi như name = null.
    if ($p -notcontains 'name') { $t | Add-Member -NotePropertyName name -NotePropertyValue $null }
    elseif ($null -ne $t.name -and $t.name -isnot [string]) { throw "hc ls --json: terminals[$i] thiếu/sai 'name' (exit $code)" }
  }
  return @($arr)
}

# Terminal cùng tên còn live nhưng agent không còn trong đó? $info = object `hc get`; $read = scriptblock trả chữ màn hình (chỉ gọi khi cần).
# 'lost'   = shell PowerShell do core tạo lại, có marker __hc_prompt và không còn -EncodedCommand.
# 'exited' = crew bật nhưng agent đã thoát, pane còn shell của -NoExit.
# ''       = còn agent hoặc không chắc. status null KHÔNG đủ: Claude chưa qua lượt đầu cũng null, nên phải thấy dấu nhắc shell ở dòng cuối.
function Get-TermShellState($info, [scriptblock]$read) {
  if (-not $info -or $info.state -ne 'live') { return '' }
  $st = Get-TermStatus $info
  if ($st.App -or $st.State -eq 'blocked') { return '' }
  $argv = @($info.argv | Where-Object { $_ })
  if (-not $argv.Count) { return '' }
  # Chỉ tin shell PowerShell đã xác minh; foreground khác shell có thể là agent chưa báo status.
  $shellName = { param($exe) (([string]$exe -split '[\\/]')[-1] -replace '(?i)\.exe$', '') -in 'pwsh', 'powershell' }
  $foreground = @($info.foreground.argv | Where-Object { $_ })
  if ($foreground.Count -and -not (& $shellName $foreground[0])) { return '' }
  $encoded = $argv -contains '-EncodedCommand'
  # Chưa xác minh shell core sau reboot trên Linux/macOS: không tự tắt ở các hệ đó.
  if (-not $encoded -and $IsWindows -eq $false) { return '' }
  if (-not $encoded -and (-not (& $shellName $argv[0]) -or ($argv -join ' ') -notmatch '__hc_prompt')) { return '' }
  $last = @("$(& $read)" -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\[hc\]' }) | Select-Object -Last 1
  if ("$last" -notmatch '(^\s*PS .*>|[$#])\s*$') { return '' }
  if ($encoded) { return 'exited' }
  if ("$last" -notmatch '^\s*PS .*>\s*$') { return '' }
  'lost'
}

# Terminal của một vai đang chạy chính lệnh crew này (HC_TERMINAL_ID kế thừa qua shim và tiến trình con của -All). Không có biến/không khớp ⇒ $null.
function Get-SelfTerm($liveTerms, [string[]]$names) {
  if (-not $env:HC_TERMINAL_ID) { return $null }
  @($liveTerms | Where-Object { $_.address -ceq $env:HC_TERMINAL_ID -and $names -ccontains $_.name }) | Select-Object -First 1
}

# Pane đang chạy crew là gì, không đòi dòng cuối là dấu nhắc vì crew đang in. $info = object `hc get`.
# 'lost' = shell core (cùng argv với Get-TermShellState) | 'exited' = crew bật, agent đã thoát | 'unix-shell' = shell chưa xác minh trên Linux/macOS | '' = còn agent hoặc không chắc.
function Get-SelfPaneState($info, [bool]$windows = ($IsWindows -ne $false)) {
  if (-not $info -or $info.state -ne 'live') { return '' }
  $st = Get-TermStatus $info
  if ($st.App -or $st.State -in 'blocked', 'working') { return '' }
  $argv = @($info.argv | Where-Object { $_ })
  if (-not $argv.Count) { return '' }
  $exe = { param($x) ([string]$x -split '[\\/]')[-1] -replace '(?i)\.exe$', '' }
  # Crew đang chạy nên foreground có thể là shell hoặc chính các lệnh crew gọi; thứ khác có thể là agent chưa báo status.
  $foreground = @($info.foreground.argv | Where-Object { $_ })
  if ($foreground.Count -and (& $exe $foreground[0]) -notin 'pwsh', 'powershell', 'hc', 'git', 'herdr-app', 'bash', 'sh', 'zsh', 'fish') { return '' }
  if ($argv -contains '-EncodedCommand') { return 'exited' }
  if (-not $windows) { return 'unix-shell' }
  if ((& $exe $argv[0]) -in 'pwsh', 'powershell' -and ($argv -join ' ') -match '__hc_prompt') { return 'lost' }
  ''
}

# Id herdr của crew từ khóa id (Get-CrewIdKey) — không tự bỏ ký tự nào nữa.
function Get-Ids([string]$k) {
  return @{ Space = "spcrew$k"; Planner = "tbcrew${k}planner"; Rev = "tbcrew${k}rev"; Workers = { param($n) "tbcrew${k}workers$n" }.GetNewClosure() }
}

# Chạy một chương trình trong pwsh (giữ shell khi chương trình thoát) thành terminal hc có tên, gắn vào tab herdr.
function Start-Term([string]$name, [string]$cwd, [string]$space, [string]$tab, [string]$cmdline) {
  $argv = @('run', '--bg', '--json', '--name', $name, '--keep', '--outlive-parent', '--no-parent', '--no-notify',
    '--cwd', $cwd, '--label', "herdr.space=$space", '--label', "herdr.tab=$tab", '--', 'pwsh', '-NoLogo')
  if ($cmdline) {
    # crew up chạy từ pane agent có thể truyền biến phiên cha; Claude thấy CLAUDE_CODE_CHILD_SESSION thì không lưu transcript nên không resume được.
    $clean = "foreach (`$v in 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN') { Remove-Item `"Env:`$v`" -ErrorAction Ignore }; "
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clean + $cmdline))
    $argv += @('-NoExit', '-EncodedCommand', $enc)
  }
  $out = hc @argv
  if ($LASTEXITCODE -ne 0) { Die "không bật được $name : $out" }
  $r = $out | ConvertFrom-Json
  # chờ herdr-app nhận terminal để tab/pane hiện đúng thứ tự
  for ($i = 0; $i -lt 40; $i++) {
    $ls = herdr-app ls | ConvertFrom-Json
    if ($ls.spaces.tabs.terminals.terminal -contains $r.address) { break }
    Start-Sleep -Milliseconds 250
  }
  return $r
}

function Wait-Tab([string]$tab) {
  for ($i = 0; $i -lt 40; $i++) {
    $ls = herdr-app ls | ConvertFrom-Json
    foreach ($sp in $ls.spaces) { foreach ($t in $sp.tabs) { if ($t.id -eq $tab) { return $true } } }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

# ---------------- worker giữ phiên ----------------
# Worktree cố định của worker N — chỗ DUY NHẤT dựng đường dẫn này (up/task/clean/hot đều gọi).
function Get-WorkerTree([string]$root, [int]$n) {
  [IO.Path]::GetFullPath((Join-Path $root ".crew/worktrees/w$n"))
}

# Nhánh chính = nhánh hiện tại của repo chính. Detached HEAD ⇒ Die.
function Get-MainBranch([string]$root) {
  $b = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
  if (-not $b) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD) — checkout nhánh chính trước." }
  $b
}

# Đảm bảo worktree của worker N tồn tại (tạo detached tại nhánh chính khi thiếu). Trả đường dẫn.
function Initialize-WorkerTree([string]$root, [int]$n, [string]$main) {
  $wt = Get-WorkerTree $root $n
  $listed = Test-WorktreeListed $root $wt
  if ($listed -and (Test-Path -LiteralPath $wt)) { return $wt }
  if ($listed) { Invoke-GitOrDie 'git worktree prune' -C $root worktree prune | Out-Null }
  Say "git worktree add --detach $wt $main"
  Invoke-GitOrDie "tạo worktree w$n" -C $root worktree add -q --detach $wt $main | Out-Null
  $wt
}

# Kill + gỡ một terminal hc (để bật lại cùng tên).
function Stop-Term([string]$address) {
  hc kill $address | Out-Null
  & { $ErrorActionPreference = 'Continue'; hc rm $address 2>&1 } | Out-Null
}

# Hàm thuần: giá trị -Restart ⇒ danh sách vai ('planner' | 'rev' | 'w<N>'). Sai ⇒ throw nêu giá trị cho phép.
function Get-RestartTargets([string]$value, [int]$workers, [bool]$planner, [bool]$rev) {
  $all = @()
  if ($planner) { $all += 'planner' }
  $all += @(1..$workers | ForEach-Object { "w$_" })
  if ($rev) { $all += 'rev' }
  $v = "$value".Trim().ToLower()
  if ($v -eq 'all') { return $all }
  if ($all -cnotcontains $v) { throw "-Restart phải là: $(($all + 'all') -join ', ') (nhận '$value')." }
  $v
}

# Danh sách file từ `git status --porcelain` (Invoke-GitQuiet đã Trim nên dòng đầu có thể mất khoảng trắng đầu).
function Format-DirtyFiles([string]$porcelain) {
  @($porcelain -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_ -replace '^\s*\S{1,2}\s+', '' }) -join ', '
}

function Get-WorkerStartLine([int]$n) {
  "Bạn là worker w$n của crew này. Đọc context/README.md rồi context/roles/worker.md; chờ planner giao task."
}

# Bật agent của worker N ngay trong worktree cố định (cờ quyền theo access).
function Start-WorkerTerm([string]$root, $cfg, $ids, [string]$slug, [int]$n, [string]$main, $session = $null) {
  $kind = @($cfg.workers)[$n - 1]
  $wt = Initialize-WorkerTree $root $n $main
  $tab = & $ids.Workers ([math]::Ceiling($n / 2))
  Start-Term "$slug-w$n" $wt $ids.Space $tab (Get-AgentCommand $kind $cfg.access (Get-WorkerStartLine $n) $session)
}

function Add-Block([string]$file, [string]$block) {
  if (Test-Path $file) {
    if ((Get-Content $file -Raw) -match '<!-- crew -->') { Say "$(Split-Path $file -Leaf) đã có khối crew, bỏ qua."; return }
    Copy-Item $file "$file.bak-$Today"
    Say "sao lưu $(Split-Path $file -Leaf) -> $(Split-Path $file -Leaf).bak-$Today, nối khối crew."
    Add-Content $file "`n$block" -Encoding utf8
  } else {
    Say "tạo $(Split-Path $file -Leaf) với khối crew."
    Set-Content $file $block -Encoding utf8
  }
}

# ---------------- doctor ----------------
# Thêm dòng vào .gitignore của project nếu chưa có (so nguyên dòng sau trim). Trả $true nếu đã thêm.
function Add-GitIgnoreLine([string]$root, [string]$line, [string[]]$same = @()) {
  $gi = Join-Path $root '.gitignore'
  $text = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
  $have = @($text -split '\r?\n+' | ForEach-Object { $_.Trim() })
  foreach ($l in @($line) + $same) { if ($have -ccontains $l) { return $false } }
  $sep = if ($text -and -not $text.EndsWith("`n")) { "`n" } else { '' }
  [IO.File]::AppendAllText($gi, "$sep$line`n", [Text.UTF8Encoding]::new($false))
  Say "thêm $line vào .gitignore."
  return $true
}

# File sao lưu .bak-* là bản an toàn cục bộ, không commit.
function Test-BakPath([string]$p) { (Split-Path $p -Leaf) -like '*.bak-*' }

function Invoke-Doctor {
  $script:bad = 0
  function Check([string]$label, [bool]$ok, [string]$fix) {
    if ($ok) { Write-Host "  OK    $label" -ForegroundColor Green }
    else { Write-Host "  THIẾU $label  -> $fix" -ForegroundColor Yellow; $script:bad++ }
  }
  Write-Host "Môi trường"
  Check "trong pane herdr (HC_TERMINAL_ID=$env:HC_TERMINAL_ID)" ([bool]$env:HC_TERMINAL_ID) 'mở herdr-app và chạy trong một pane của nó'
  # Bảng phần mềm từ scripts/prereq.ps1; claude/codex chỉ cần khi đội (project > cá nhân > standard) dùng tới.
  . (Join-Path $PSScriptRoot 'prereq.ps1')
  $root = Get-Root $Path
  $userCfg = if ($env:CREWLINE_USER_CONFIG) { $env:CREWLINE_USER_CONFIG } else { Join-Path $HOME '.crewline/config.json' }
  $files = @(if ($root) { Join-Path $root '.crew/config.json' }) + @($userCfg)
  $need = Get-TeamAgents (Get-PrereqTeam $files (Join-Path $PSScriptRoot 'teams.json'))
  foreach ($p in Get-Prereqs) {
    if ($p.Group -eq 'team' -and $need -notcontains $p.Name) {
      Write-Host "  --    $($p.Label) (không dùng trong đội)" -ForegroundColor DarkGray
      continue
    }
    Check $p.Label (Test-Prereq $p) (Get-PrereqFix $p)
  }
  $gitCfg = { param($k) $r = Invoke-GitQuiet config --global $k; if ($r.Code -eq 0) { $r.Text } }
  $n = & $gitCfg user.name; $e = & $gitCfg user.email
  Check "git identity ($n <$e>)" ([bool]($n -and $e)) 'git config --global user.name/user.email'
  $tdir = Get-HcTemplateDir
  $tpl = @(Get-ChildItem $tdir -Filter 'crew-*.md' -ErrorAction SilentlyContinue).Count
  Check "template hc ($tpl trong $tdir)" ($tpl -ge 4) 'chạy install.ps1'
  Check "khung context ($Skeleton)" (Test-Path (Join-Path $Skeleton 'context/roles/planner.md')) 'repo Crewline thiếu skeleton/'
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    $pcfg = Get-Config $root
    $clash = Get-NameConflict $root $pcfg
    Check "tên crew '$(Get-CrewName $root $pcfg)' chỉ thuộc project này" (-not $clash) $clash
  }
  if (Get-Command hc -ErrorAction SilentlyContinue) {
    & { $ErrorActionPreference = 'Continue'; hc server status *> $null }
    Check 'herdr-core đang chạy' ($LASTEXITCODE -eq 0) 'mở herdr-app'
  }
  Write-Host "Nhắc: agent phải đã đăng nhập, crew không tự đăng nhập: $(($need | ForEach-Object { "$_ ($(Get-AgentLogin $_))" }) -join ', ')."
  if ($script:bad) { exit 1 }
}

# ---------------- init ----------------
# Tên crew + khóa id cho init: -Name > `name` đã có trong config > slug cũ (config cũ chưa có name) > Get-Slug; tên tự sinh mà trùng ⇒ -2, -3…
# idKey: giữ khóa đang dùng khi tên không đổi (project cũ ⇒ khóa cũ, không đổi space/tab); tên mới ⇒ ConvertTo-IdKey. Trả @{ Name; IdKey }.
function Select-InitName([string]$root, [string]$cfgFile) {
  $prev = $null
  if (Test-Path -LiteralPath $cfgFile) { try { $prev = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json } catch { $prev = $null } }
  $prevName = ''; $prevKey = ''
  if ($prev) {
    $prevName = if ($prev.PSObject.Properties.Name -contains 'name' -and (Test-CrewName ([string]$prev.name))) { [string]$prev.name } else { Get-LegacySlug $root }
    $prevKey = if ($prev.PSObject.Properties.Name -contains 'idKey' -and (Test-IdKey ([string]$prev.idKey))) { [string]$prev.idKey } elseif ($prevName) { Get-LegacyIdKey $prevName } else { '' }
  }
  $keyFor = { param($n) if ($prevName -and $n -ceq $prevName -and $prevKey) { $prevKey } else { ConvertTo-IdKey $n } }
  if ($Name) { return @{ Name = $Name; IdKey = (& $keyFor $Name) } }
  if ($prev -and $prev.PSObject.Properties.Name -contains 'name' -and $prevName -ceq [string]$prev.name) {
    $clash = Get-NameConflict $root $prev
    if ($clash) { Say "cảnh báo: $clash" }
    return @{ Name = $prevName; IdKey = $prevKey }
  }
  $base = if ($prevName) { $prevName } else { Get-Slug $root }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Say "cảnh báo: $($reg.Error) — không kiểm được tên trùng với project khác (crew up vẫn kiểm cwd terminal)." }
  $hs = Get-HerdrSpaces
  $taken = if ($hs.Ok) { Get-TakenIdKeys $hs.Spaces $root } else { @() }
  $chosen = Resolve-CrewName $base $root $reg.Map $taken
  if ($chosen -ne $base) {
    $who = Get-NameOwner $reg.Map $base $root
    if (-not $who) { $who = Get-IdKeyOwner $reg.Map (ConvertTo-IdKey $base) $root }
    if (-not $who) { $who = "(space herdr spcrew$(ConvertTo-IdKey $base) đang chạy)" }
    Say "tên '$base' (hoặc khóa id của nó) đã thuộc project $who — dùng tên '$chosen'."
  }
  @{ Name = $chosen; IdKey = (& $keyFor $chosen) }
}

# Trùng idKey không chứng minh bản chép: chỉ tên trong sổ thuộc root khác còn sống.
function Get-CopySource([string]$root, $cfg) {
  if (-not $cfg -or -not $cfg.name) { return '' }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { return '' }
  Get-NameOwner $reg.Map ([string]$cfg.name) $root
}

# Chỉ dọn trạng thái mang theo từ root khác còn tồn tại; không sửa metadata git.
function Clear-CopiedCrewState([string]$root, $cfg) {
  if (-not (Get-CopySource $root $cfg)) { return }
  $listed = Invoke-GitOrDie 'đọc worktree trước khi dọn bản chép' -C $root worktree list --porcelain
  $paths = @($listed.Text -split "`n" | Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9).TrimEnd("`r") })
  $parent = Join-Path (ConvertTo-RootKey $root) '.crew/worktrees'
  foreach ($path in @((Join-Path $root '.crew'), $parent, (Join-Path $root '.crew/config.json'))) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Die "không dọn tự động đường dẫn liên kết: $path"
    }
  }
  $remove = @()
  if (Test-Path -LiteralPath $parent) {
    foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory -Force) {
      if ($dir.Name -notmatch '^w\d+$') { continue }
      if (@($paths | Where-Object { Test-SamePath $_ $dir.FullName }).Count) { Say "giữ worktree git đã đăng ký: $($dir.FullName)"; continue }
      # Kiểm đường dẫn tuyệt đối trước xóa đệ quy; không đi theo junction/symlink.
      if (-not (Test-SamePath (Split-Path $dir.FullName -Parent) $parent) -or
          ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
          @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        Die "không dọn tự động đường dẫn liên kết/ngoài phạm vi: $($dir.FullName)"
      }
      $remove += $dir.FullName
    }
  }
  foreach ($dir in $remove) {
    Remove-Item -LiteralPath $dir -Recurse -Force
    Say "đã dọn worktree chép theo (không đăng ký trong git bản chép): $dir"
  }
  $tasksFile = Join-Path $root '.crew/tasks.json'
  if (Test-Path -LiteralPath $tasksFile) { Remove-Item -LiteralPath $tasksFile -Force; Say 'đã dọn .crew/tasks.json của bản gốc.' }
  $cfg.PSObject.Properties.Remove('name')
  $cfg.PSObject.Properties.Remove('idKey')
  $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.crew/config.json') -Encoding utf8
  Say 'đã bỏ name/idKey của bản gốc; khởi tạo crew mới cho bản chép.'
}

function Invoke-Init {
  $teams = Get-Teams
  $defaults = Get-UserDefaults $teams
  $t = Select-Team $teams $defaults
  foreach ($key in 'Review', 'Access') {
    if (-not $InitParameters.ContainsKey($key) -and $defaults.ContainsKey($key.ToLower())) {
      Set-Variable -Name $key -Value $defaults[$key.ToLower()]
    }
  }
  $p = (Resolve-Path $Path).Path
  $root = Get-Root $p
  $copyRoot = if ($root) { $root } else { $p }
  $copyConfig = Join-Path $copyRoot '.crew/config.json'
  $copied = $null
  if (Test-Path -LiteralPath $copyConfig) {
    $previous = Get-Content -LiteralPath $copyConfig -Raw | ConvertFrom-Json
    if (Get-CopySource $copyRoot $previous) {
      if (-not $Name) { Die 'project là bản chép (bản sao) của crew còn tồn tại; chạy crew init -Name <tên mới> để dọn trạng thái chép theo và tạo crew riêng.' }
      $copied = $previous
    }
  }
  # -Name kiểm ngay, trước khi đụng git
  if ($Name) {
    if (-not (Test-CrewName $Name)) { Die "-Name '$Name' không hợp lệ: chỉ a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'." }
    $reg = Read-ProjectRegistry
    $here = if ($root) { $root } else { $p }
    $other = if ($reg.Ok) { Get-NameOwner $reg.Map $Name $here } else { '' }
    if ($other) { Die "tên crew '$Name' đã thuộc project $other — chọn tên khác." }
    $other = if ($reg.Ok) { Get-IdKeyOwner $reg.Map (ConvertTo-IdKey $Name) $here } else { '' }
    if ($other) { Die "khóa id herdr của tên '$Name' ($(ConvertTo-IdKey $Name)) đã thuộc project $other — chọn tên khác." }
    $hs = Get-HerdrSpaces
    if ($hs.Ok -and (Get-TakenIdKeys $hs.Spaces $here) -ccontains (ConvertTo-IdKey $Name)) { Die "space herdr spcrew$(ConvertTo-IdKey $Name) đang thuộc project khác — chọn tên khác cho -Name." }
  }
  $hasHead = [bool]$root -and (Invoke-GitQuiet -C $root rev-parse --verify -q HEAD).Code -eq 0
  if (-not $hasHead -and -not $GitInit) {
    if ($root) {
      $fail = 'repo chưa có commit nào. Chạy lại với -GitInit để tạo commit đầu.'
      $answer = Read-GitInitChoice "Repo $root chưa có commit nào." 'Tạo commit đầu với các file đang có'
    } else {
      $fail = "$p không phải repo git. Chạy lại với -GitInit để git init + commit đầu."
      $answer = Read-GitInitChoice "Thư mục $p chưa là repo git." 'Tạo repo git mới ở đây (git init + commit đầu)'
    }
    if ($null -eq $answer) { Die $fail }
    if ($answer -ne 'yes') { Say 'thôi, không tạo gì.'; exit 1 }
  }
  if (-not $root) {
    Say "git init $p"
    Invoke-GitOrDie 'git init' -C $p init -q -b main | Out-Null
    $root = (Resolve-Path $p).Path
  }
  if (-not $hasHead) {
    if ($copied) { Clear-CopiedCrewState $root $copied; $copied = $null }
    Say "tạo commit đầu với các file đang có."
    Invoke-GitOrDie 'git add' -C $root add -A | Out-Null
    Invoke-GitOrDie 'commit đầu' -C $root commit -q --allow-empty -m 'chore: initial commit' | Out-Null
    $hasHead = $true
  }

  if ($copied) { Clear-CopiedCrewState $root $copied }
  # không có Rev thì không ai review ⇒ ép chế độ nhanh
  $rv = $Review; if ($t.rev -eq 'none') { $rv = 'fast' }
  $reviewVi = @{ fast = 'Nhanh'; lean = 'Gọn'; full = 'Đủ' }[$rv]
  $accessVi = @{ work = 'Làm việc'; wide = 'Mở rộng' }[$Access]
  $hotLine = "Chế độ review: **$reviewVi**. Quyền agent: $accessVi."

  # khung context: chép file chưa có
  $src = Join-Path $Skeleton 'context'
  Get-ChildItem $src -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
    $dst = Join-Path $root "context/$rel"
    if (Test-Path $dst) { return }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $_.FullName $dst
  }
  $hot = Join-Path $root 'context/HOT.md'
  $hotText = Get-Content $hot -Raw
  if ($hotText -match '__HOTLINE__') {
    Set-Content $hot ($hotText -replace '__HOTLINE__', $hotLine) -Encoding utf8 -NoNewline
  } elseif (-not ($hotText -match '^Chế độ review')) {
    Copy-Item $hot "$hot.bak-$Today"
    Set-Content $hot "$hotLine`n`n$hotText" -Encoding utf8 -NoNewline
  }
  Say "khung context/ sẵn sàng (giữ nguyên file đã có)."
  Set-Content (Join-Path $root 'context/.skeleton-version') (Get-SkeletonVersion) -Encoding utf8

  $block = Get-CrewBlock
  Add-Block (Join-Path $root 'CLAUDE.md') $block
  Add-Block (Join-Path $root 'AGENTS.md') $block

  Add-GitIgnoreLine $root '.crew/' @('.crew') | Out-Null
  Add-GitIgnoreLine $root '*.bak-*' | Out-Null

  New-Item -ItemType Directory -Force (Join-Path $root '.crew/prompts') | Out-Null
  $cfgFile = Join-Path $root '.crew/config.json'
  $sel = Select-InitName $root $cfgFile; $crewName = $sel.Name
  $cfg = [ordered]@{ name = $crewName; idKey = $sel.IdKey; planner = $t.planner; workers = @($t.workers); rev = $t.rev; review = $rv; access = $Access }
  $cfg | ConvertTo-Json | Set-Content $cfgFile -Encoding utf8
  Say "ghi .crew/config.json: $(($cfg | ConvertTo-Json -Compress))"
  Register-CrewName $crewName $root $sel.IdKey | Out-Null
  Say "tên crew: $crewName (terminal $crewName-planner, $crewName-w<N>, $crewName-rev; đổi: crew init -Name <tên>)"

  if ($NoCommit) { Say "bỏ qua commit (-NoCommit)."; return }
  Invoke-GitQuiet -C $root add context CLAUDE.md AGENTS.md .gitignore | Out-Null
  if ((Invoke-GitQuiet -C $root diff --cached --quiet).Code -eq 0) { Say "không có gì mới để commit."; return }
  Invoke-GitOrDie 'commit khung context' -C $root commit -q -m 'chore: crew context skeleton' | Out-Null
  Say "commit: $(git -C $root log -1 --format='%h %s')"
}

# ---------------- upgrade ----------------
# Project cũ thiếu `name`/`idKey` ⇒ ghi name = slug cũ và idKey = khóa cũ (tên bỏ '-') vào .crew/config.json (gitignore,
# không commit) để KHÔNG đổi tên terminal và space/tab đang chạy; ghi sổ nếu tên/khóa còn trống (trùng ⇒ giữ chủ cũ, cảnh báo).
# Slug cũ rỗng ⇒ sinh tên mới + idKey mã hóa mới. Đủ cả hai ⇒ chỉ cảnh báo khi trùng project khác. $dry ⇒ chỉ in.
function Update-ConfigName([string]$root, [bool]$dry) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $cfg = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
  $names = @($cfg.PSObject.Properties.Name)
  $hasName = $names -contains 'name' -and $cfg.name
  $hasKey = $names -contains 'idKey' -and $cfg.idKey
  if ($hasName -and $hasKey) {
    $clash = Get-NameConflict $root $cfg
    if ($clash) { Say "cảnh báo: $clash" }
    return
  }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Say "cảnh báo: $($reg.Error) — không ghi sổ." }
  $n = if ($hasName) { Get-CrewName $root $cfg } else { Get-LegacySlug $root }
  $fresh = $false
  if (-not $n) { $n = Resolve-CrewName (Get-Slug $root) $root $reg.Map; $fresh = $true }
  $k = if ($hasKey) { Get-CrewIdKey $root $cfg } elseif ($fresh) { ConvertTo-IdKey $n } else { Get-LegacyIdKey $n }
  $what = @(if (-not $hasName) { "name '$n'" }) + @(if (-not $hasKey) { "idKey '$k'" }) -join ' + '
  if ($dry) {
    Say "sẽ ghi $what vào $f (giữ tên terminal và space/tab hiện có) + sổ tên crew nếu còn trống."
    $clash = Get-NameConflict $root ([pscustomobject]@{ name = $n; idKey = $k })
    if ($clash) { Say "cảnh báo: $clash" }
    return
  }
  $o = [ordered]@{ name = $n; idKey = $k }
  foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -notin 'name', 'idKey') { $o[$p.Name] = $p.Value } }
  $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f -Encoding utf8
  Say "ghi $what vào $f (giữ tên terminal và space/tab hiện có)."
  # Sổ còn ghi đúng tên + khóa này ở root cũ đã mất ⇒ project đã chuyển: giữ mục sổ làm dấu vết cho Get-MoveInfo, crew up/repair sẽ cập nhật.
  $moved = $reg.Ok -and $reg.Map.Contains($n) -and $reg.Map[$n].IdKey -ceq $k -and -not (Test-SamePath ([string]$reg.Map[$n].Root) $root) -and -not (Test-Path -LiteralPath (Join-Path ([string]$reg.Map[$n].Root) '.crew/config.json'))
  if ($moved) { Say "sổ còn ghi '$n' ở $($reg.Map[$n].Root) (không còn) — chưa ghi sổ, crew up sẽ xử lý chuyển thư mục." }
  elseif ($reg.Ok) { Register-CrewName $n $root $k | Out-Null }
}

function Invoke-Upgrade {
  $root = Get-Root (Resolve-Path $Path).Path
  if (-not $root) { Die 'không phải repo git.' }
  $context = Join-Path $root 'context'
  if (-not (Test-Path $context -PathType Container)) { Die "chưa có context/ — chạy 'crew init' trước." }
  $st = Invoke-GitQuiet -C $root status --porcelain --untracked-files=all -- context
  if ($st.Code -ne 0) { Die 'không kiểm tra được trạng thái context/.' }
  # Bỏ qua file .bak-* (kể cả khi project chưa ignore chúng).
  $dirty = @($st.Text -split '\r?\n+' | Where-Object { $_ -and -not (Test-BakPath ($_.Substring(3).Trim('"'))) })
  if ($dirty.Count -and -not $Force) { Die 'context/ có thay đổi chưa commit; commit trước hoặc dùng -Force.' }
  $version = Get-SkeletonVersion
  $old = '0'
  $versionFile = Join-Path $context '.skeleton-version'
  if (Test-Path $versionFile) { $old = (Get-Content $versionFile -Raw -Encoding utf8).Trim() }
  Say "upgrade context v$old -> v$version"
  $changed = [Collections.Generic.List[string]]::new()
  function Write-UpgradeFile([string]$file, [string]$content, [bool]$backup = $false) {
    if ((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -ceq $content) { return }
    Say "$(if ($backup) { 'sao lưu + cập nhật' } else { 'ghi' }) $file"
    if ($DryRun) { return }
    if ($backup) {
      $bak = "$file.bak-$Today"
      $n = 1
      while (Test-Path -LiteralPath $bak) { $bak = "$file.bak-$Today-$n"; $n++ }
      Copy-Item -LiteralPath $file -Destination $bak
      Say "  bản sao lưu (không commit): $bak"
    }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($false))
    $changed.Add($file)
  }
  $src = Join-Path $Skeleton 'context'
  foreach ($item in Get-ChildItem $src -Recurse -File -Force) {
    $rel = $item.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
    $dst = Join-Path $context $rel
    $exists = Test-Path -LiteralPath $dst
    # tasks/archive và file riêng của dự án luôn được giữ nguyên, kể cả khi thiếu.
    if ($rel -match '^(tasks|archive)/') { continue }
    if (-not $exists) { Write-UpgradeFile $dst ([IO.File]::ReadAllText($item.FullName)); continue }
    if ($rel -eq 'README.md' -or $rel -match '^roles/[^/]+\.md$') {
      Write-UpgradeFile $dst ([IO.File]::ReadAllText($item.FullName)) $true
    } elseif ($rel -eq 'PITFALLS.md') {
      $text = [IO.File]::ReadAllText($dst)
      $lines = @($text -split '\r?\n' | ForEach-Object { $_.Trim() })
      $add = @()
      foreach ($line in Get-Content $item.FullName -Encoding utf8) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('- ') -and $lines -cnotcontains $trimmed) { $add += $trimmed; $lines += $trimmed }
      }
      if ($add.Count) { Write-UpgradeFile $dst ($text + $(if ($text.EndsWith("`n")) { '' } else { "`n" }) + ($add -join "`n") + "`n") }
    }
  }
  foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
    $file = Join-Path $root $name
    $text = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    $block = Get-CrewBlock
    # Bản mới có marker kết thúc; bản init cũ gồm heading, dòng đọc context và các bullet.
    $pattern = '(?s)<!-- crew -->.*?<!-- /crew -->'
    if ($text -notmatch $pattern) { $pattern = '<!-- crew -->\r?\n## [^\r\n]*\r?\n[^\r\n]*(?:\r?\n- [^\r\n]*)*' }
    if ($text -match $pattern) { $next = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1) }
    elseif ($text.Contains('<!-- crew -->')) { Die "khối crew trong $name không nhận diện được; cần marker <!-- /crew -->." }
    else { $next = $text + $(if ($text) { "`n" } else { '' }) + $block + "`n" }
    Write-UpgradeFile $file $next
  }
  Write-UpgradeFile $versionFile "$version`n"
  Update-ConfigName $root ([bool]$DryRun)
  if ($DryRun) {
    $gi = Join-Path $root '.gitignore'
    $ignoreText = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
    $ignoreLines = @($ignoreText -split '\r?\n+' | ForEach-Object { $_.Trim() })
    if ($ignoreLines -cnotcontains '*.bak-*') { Say 'sẽ thêm *.bak-* vào .gitignore.' }
    Say 'DryRun: không ghi file, không commit.'; return
  }
  if (Add-GitIgnoreLine $root '*.bak-*') {
    $changed.Add((Join-Path $root '.gitignore'))
    if ($NoCommit) { Say 'đã thêm *.bak-* vào .gitignore (chưa commit)' }
  }
  if ($NoCommit) { Say 'bỏ qua commit (-NoCommit).'; return }
  # Phòng thủ: không bao giờ add file .bak-* hay file bị git ignore (chưa track).
  $files = @($changed.ToArray() | Where-Object {
      -not (Test-BakPath $_) -and (Invoke-GitQuiet -C $root check-ignore -q -- $_).Code -ne 0 })
  if (-not $files.Count) { Say 'không có gì mới để commit.'; return }
  Invoke-GitOrDie 'git add' -C $root add -- @files | Out-Null
  # Chỉ commit file upgrade, không kéo theo các file đã stage ngoài phạm vi.
  Invoke-GitOrDie 'commit upgrade' -C $root commit -q --only -m "chore: crew upgrade context -> v$version" -- @files | Out-Null
}

# ---------------- up ----------------
function Invoke-Up {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git. Project mới: chạy 'crew init' trong thư mục này trước." }
  # Invoke-Recover đã gọi trước khi gọi tới đây; project cũ được ghi tên vào config + sổ, tên terminal và space/tab giữ nguyên
  if (-not $script:FromRepair) { Update-ConfigName $root $false }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
  $clash = Get-NameConflict $root $cfg
  if ($clash) { Die $clash }
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint }
  $main = Get-MainBranch $root
  try { $liveTerms = @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) } catch { Die "$($_.Exception.Message) — không kiểm được terminal đang chạy nên không bật/kill gì. Kiểm hc (hc ls) rồi chạy lại." }
  # terminal cùng tên mà thuộc project khác ⇒ dừng trước mọi kill/bật/gửi
  $mine = @(if ($cfg.planner -ne 'none') { "$slug-planner" }) + @(for ($i = 1; $i -le @($cfg.workers).Count; $i++) { "$slug-w$i" }) + @(if ($cfg.rev -ne 'none') { "$slug-rev" })
  $foreign = @($liveTerms | Where-Object { $mine -contains $_.name } | ForEach-Object { Get-ForeignTermError $_.name $_ $root } | Where-Object { $_ })
  if ($foreign.Count) { Die ($foreign -join "`n  ") }
  # space/tab id của crew này đã thuộc project khác (kể cả project chưa vào sổ) ⇒ dừng trước mọi kill/bật/rename/move
  $hs = Get-HerdrSpaces
  if (-not $hs.Ok) { Say "cảnh báo: $($hs.Error) — không kiểm được space herdr trùng khóa id; chỉ kiểm terminal cùng tên." }
  else {
    $why = Get-ForeignSpaceError $ids $root $hs.Spaces $liveTerms
    if ($why) { Die $why }
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
    try { $targets = Get-RestartTargets $Restart @($cfg.workers).Count ($cfg.planner -ne 'none') ($cfg.rev -ne 'none') } catch { Die $_.Exception.Message }
    $tasks = Get-Tasks $root
    foreach ($tg in $targets) {
      if ($tg -notlike 'w*' -or $Force) { continue }
      $busy = @($tasks | Where-Object { "w$([int]$_.worker)" -eq $tg } | ForEach-Object { $_.name })
      if ($busy.Count) { Die "$tg đang có task $($busy -join ', ') — bật lại sẽ mất phiên đang làm. Đợi xong + crew clean, hoặc thêm -Force nếu chắc chắn." }
    }
    if ($self -and $targets -contains $self.name.Substring($slug.Length + 1)) {
      $selfRole = $self.name.Substring($slug.Length + 1)
      if (-not $selfState) { Die "$($self.name) là pane đang chạy lệnh này và agent trong đó có thể còn sống, crew không tự tắt. Không tắt vai nào. Mở tab khác rồi chạy lại: crew up -Restart $Restart" }
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

  # Sau reboot/crash core giữ tên terminal nhưng chỉ còn shell trống ⇒ bật lại agent, mở lại hội thoại cũ nếu sổ phiên cho phép.
  $shellOps = New-HcOps
  foreach ($n in @($mine | Where-Object { $live -contains $_ })) {
    if ($self -and $n -ceq $self.name) {
      if ($selfState -eq 'exited' -and -not $selfJob) { Say "cảnh báo: agent của $n đã thoát, pane chỉ còn shell. Bật lại: crew up -Restart $($n.Substring($slug.Length + 1))" }
      continue
    }
    try {
      $info = & $shellOps.Get $n
      if (-not $info) { throw 'hc get không trả terminal' }
      $shell = Get-TermShellState $info { & $shellOps.Read $n }
      if ($shell -eq 'lost') {
        # Đọc lại ngay trước kill: tên/address/chủ và dấu hiệu shell phải còn đúng.
        $fresh = & $shellOps.Get $n
        if (-not $info.address -or $info.name -cne $n -or
            -not (Test-TermOwner $fresh $root) -or $fresh.address -cne $info.address -or $fresh.name -cne $info.name -or
            (Get-TermShellState $fresh { & $shellOps.Read $n }) -ne 'lost') {
          throw 'không xác minh được chủ, tên/địa chỉ hoặc shell trống ở lần đọc mới'
        }
        Stop-Term $fresh.address
        $live = @($live | Where-Object { $_ -ne $n })
        $lostTerms += $n
        Say "$n chỉ còn shell trống (máy khởi động lại hoặc core mất chương trình), bật lại agent."
      }
    } catch {
      Say "cảnh báo: không tắt $n — $($_.Exception.Message); giữ pane, không bật agent chồng lên."
      continue
    }
    if ($shell -eq 'exited') {
      Say "cảnh báo: agent của $n đã thoát, pane chỉ còn shell. Bật lại: crew up -Restart $($n.Substring($slug.Length + 1))"
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
          # Codex không báo lỗi khi thư mục chưa có phiên: mở phiên trống, thấy 'Context 100% left'.
          if ($item.Kind -eq 'codex' -and (& $resumeOps.Read $n) -match 'Context 100% left') { Say "cảnh báo: ${n}: hội thoại mới (Codex không có phiên cũ để mở lại)" }
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

# ---------------- task ----------------
# Bản ghi task trong .crew/tasks.json. $review rỗng ⇒ không ghi khóa review (mức lấy theo HOT/config).
function New-TaskRecord([string]$name, [string]$branch, [string]$wt, [int]$worker, [string]$term, [string]$kind, [string]$review) {
  $rec = [ordered]@{ name = $name; branch = $branch; worktree = $wt; worker = $worker; terminal = $term; agent = $kind; created = (Get-Date -Format s) }
  if ($review) { $rec.review = $review }
  [pscustomobject]$rec
}

# Hàm thuần: terminal worker đang ở trạng thái nào so với agent theo config.
# Ra @{ Mode = 'dead'|'blocked'|'shell'|'agent'|'wrong'; App }.
function Get-WorkerMode($info, [string]$kind) {
  $plan = Get-SendPlan $info $null
  $app = (Get-TermStatus $info).App
  if ($plan -in 'dead', 'blocked') { return @{ Mode = $plan; App = $app } }
  if (-not $app) { return @{ Mode = 'shell'; App = $null } }
  $want = @{ claude = 'claude-code'; codex = 'codex' }[$kind]
  @{ Mode = $(if ($app -eq $want) { 'agent' } else { 'wrong' }); App = $app }
}

# Hàm thuần: phiên mới đã sẵn sàng sau /clear (claude) hoặc /new (codex)? $screen = chữ màn hình (hc read).
# Mọi hộp thoại trên màn hình (kể cả hộp chọn của /new) ⇒ chưa sẵn sàng, dù marker sẵn sàng cũng có mặt.
# Codex: thấy 'Context 100% left'.
# Claude: idle, có dòng lịch sử '❯ /clear' (lệnh đã chạy) và SAU nó là ô nhập trống '❯'. /clear còn kẹt ở ô nhập thì
# '❯ /clear' là dòng prompt cuối (không có ô trống sau), thường kèm menu gợi ý '/clear  Clear …'.
function Test-SessionReady([string]$kind, $info, [string]$screen) {
  $st = Get-TermStatus $info
  if ($st.State -in 'working', 'blocked') { return $false }
  if (Get-ScreenDialog $screen) { return $false }
  if ($kind -eq 'codex') { return $screen -match 'Context 100% left' }
  $lines = @("$screen" -split '\r?\n')
  $cmd = -1; $empty = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*[❯>]\s*/clear\s*$') { $cmd = $i }
    elseif ($lines[$i] -match '^\s*[❯>]\s*$') { $empty = $i }
  }
  if ($cmd -lt 0 -or $empty -lt $cmd) { return $false }
  return -not (@($lines[$cmd..($lines.Count - 1)]) -match '^\s*/clear\s{2,}\S').Count
}

# Chỉ quan sát terminal vừa bật, tối đa 20s; không gửi hay bấm phím.
function Show-StartupTrust($roles, $ops) {
  $pending = @($roles); $trust = @()
  for ($i = 0; $i -le 10 -and $pending.Count; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $next = @()
    foreach ($role in $pending) {
      $info = & $ops.Get $role.Term
      $dlg = Get-ScreenDialog (& $ops.Read $role.Term)
      if ($dlg -eq 'trust') { $trust += $role; continue }
      if ($dlg) { continue }
      $st = Get-TermStatus $info
      $want = @{ claude = 'claude-code'; codex = 'codex' }[$role.Kind]
      if ($info -and $info.state -eq 'live' -and $st.App -eq $want -and $st.State -eq 'idle') { continue }
      $next += $role
    }
    $pending = $next
  }
  if (-not $trust.Count) { return }
  Say 'Chờ bạn bấm "trust thư mục" (crew không tự bấm):'
  foreach ($role in $trust) {
    $keys = if ($role.Kind -eq 'claude') { 'down enter' } else { 'enter' }
    $hint = if ($role.Kind -eq 'claude') { '↓ rồi Enter' } else { 'Enter' }
    Say ("  {0}  {1,-6}  vào pane: {2,-12} (hoặc: hc keys {0} {3})" -f $role.Term, $role.Kind, $hint, $keys)
  }
  Say 'Trust một lần cho mỗi thư mục; lần sau không hỏi lại.'
}

# Hàm thuần: ô nhập thường ở cuối màn hình, nhận theo khung đã thấy thật. Không chắc ⇒ $null.
# Claude: ─── / ❯ chữ / ─── rồi chân (bypass permissions on, …). Codex: › chữ (dòng nối thụt 2), dòng trống, chân GPT-… hoặc Context N% left.
# Ra @{ Kind = 'claude'|'codex'; Text = chữ trong ô ('' nếu trống/placeholder); Lines = các dòng của ô (chỉ Codex); After = các dòng dưới ô chưa rõ là gì }.
function Get-InputBox([string]$screen) {
  $lines = @("$screen" -split '\r?\n' | Where-Object { $_ -notmatch '^\[hc\]' } | ForEach-Object { $_.TrimEnd() })
  $n = $lines.Count - 1
  while ($n -ge 0 -and -not $lines[$n]) { $n-- }
  if ($n -lt 2) { return $null }
  # Codex: dòng phụ dưới chân chỉ nhận các dạng đã thấy
  $f = $n
  if ($lines[$f] -match '^\s*(\? for shortcuts|tab to queue message)') { $f-- }
  if ($f -ge 2 -and $lines[$f] -match '^\s*GPT-\S+\s.*·|·\s*Context \d+% left' -and -not $lines[$f - 1]) {
    $i = $f - 2; $text = @()
    while ($i -ge 0 -and $f - $i -le 30 -and $lines[$i] -match '^\s{2,}\S' -and $lines[$i] -notmatch '^\s*›') { $text = @($lines[$i].Trim()) + $text; $i-- }
    if ($i -ge 0 -and $f - $i -le 30 -and $lines[$i] -match '^\s*›(\s|$)' -and $lines[$i] -notmatch '^\s*›\s*\d+\.\s') {
      $rows = @(($lines[$i] -replace '^\s*›\s*', '')) + $text
      $joined = ($rows -join ' ').Trim()
      if ($joined -eq 'Ask Codex to do anything') { $joined = ''; $rows = @() }
      return @{ Kind = 'codex'; Text = $joined; Lines = @($rows); After = '' }
    }
    return $null
  }
  # Claude: đường kẻ đóng trong vài dòng cuối, có chân thật bên dưới, đường kẻ mở phía trên
  for ($c = $n; $c -ge 0 -and $n - $c -le 6; $c--) { if ($lines[$c] -match '^\s*─{8,}$') { break } }
  if ($c -lt 1 -or $n - $c -gt 6 -or $c -eq $n) { return $null }
  $after = @($lines[($c + 1)..$n])
  if (-not (@($after) -match '(accept edits|bypass permissions|auto mode|plan mode) on|shift\+tab to cycle|\? for shortcuts').Count) { return $null }
  for ($o = $c - 1; $o -ge 0 -and $c - $o -le 30; $o--) { if ($lines[$o] -match '^\s*─{8,}$') { break } }
  if ($o -lt 0 -or $c - $o -gt 30 -or $c - $o -lt 2) { return $null }
  if ($lines[$o + 1] -notmatch '^\s*[>❯](\s|$)' -or $lines[$o + 1] -match '^\s*[>❯]\s*\d+\.\s') { return $null }
  $inner = (@($lines[($o + 1)..($c - 1)]) -join ' ') -replace '^\s*[>❯]\s*', ''
  @{ Kind = 'claude'; Text = $inner.Trim(); After = ($after -join "`n") }
}

# Hàm thuần: màn hình đang có hộp thoại? 'codex-new' = ĐÚNG hộp chọn của Codex /new với dòng 1 đang chọn (an toàn để Enter);
# 'trust' = trust thư mục; 'other' = hộp khác (duyệt lệnh/quyền, …) — không bao giờ bấm; '' = không thấy hộp.
# Hộp lạ thắng: chỉ trả 'codex-new' khi bỏ các dòng của hộp chọn đi, phần còn lại KHÔNG còn dấu hiệu hộp nào.
# Cuối màn hình đúng là ô nhập thường (Get-InputBox) ⇒ chữ phía trên là lịch sử, không phải hộp; không chắc ⇒ quét cả màn hình như cũ.
function Get-ScreenDialog([string]$screen) {
  $marks = 'Where should the new conversation run', 'Do you want to', 'Allow command', '(?m)^\s*Allow\b', '\(y/n\)', 'enter select',
    'esc back', 'Esc to cancel', '(?m)^\s*[›❯]\s*\d+\.\s', 'Yes, proceed'
  $hasMark = { param($t) foreach ($m in $marks) { if ($t -match $m) { return $true } } $false }
  $s = "$screen"
  $box = Get-InputBox $s
  if ($box -and -not (& $hasMark $box.After)) { return '' }
  $claudeTrust = $s -match 'Yes, I trust this folder'
  $codexTrust = $s -match 'Trust this folder\?' -and $s -match 'Trust and continue'
  if ($claudeTrust -or $codexTrust) {
    $own = if ($claudeTrust) {
      @('^\s*Quick safety check:.*$', '^\s*[›❯]?\s*No, exit\s*$', '^\s*[›❯]?\s*Yes, I trust this folder\s*$', '^\s*Enter to confirm · Esc to cancel\s*$')
    } else {
      @('^\s*Trust this folder\?.*$', '^\s*[›❯]?\s*1\. Trust and continue\s*$', '^\s*2\. Quit\s*$', '^\s*enter continue · esc quit\s*$')
    }
    $rest = @($s -split '\r?\n' | Where-Object { $l = $_; -not @($own | Where-Object { $l -match $_ }).Count }) -join "`n"
    if (& $hasMark $rest) { return 'other' }
    return 'trust'
  }
  if ($s -match '(?m)^\s*Where should the new conversation run\?\s*$' -and $s -match '(?m)^\s*›\s*1\. Use current Git worktree') {
    $own = '^\s*Where should the new conversation run\?\s*$', '^\s*›\s*1\. Use current Git worktree\b', '^\s+2\. Create new Git worktree\b',
      '^\s*enter select · esc back\s*$'
    $rest = @($s -split '\r?\n' | Where-Object { $l = $_; -not @($own | Where-Object { $l -match $_ }).Count }) -join "`n"
    if (& $hasMark $rest) { return 'other' }
    return 'codex-new'
  }
  if (& $hasMark $s) { return 'other' }
  ''
}

function Get-TaskLine([string]$wt, [string]$branch) {
  "Bạn là worker. Đọc context/roles/worker.md, rồi làm đúng file $([IO.Path]::Combine($wt, '.crew', 'prompt.md')). Thư mục làm việc: $wt (nhánh $branch); mọi lệnh chạy trong thư mục này."
}

# Phần git của crew task trên worktree cố định: kiểm sạch, tạo crew/<tên> từ nhánh chính, chép prompt. Lỗi ⇒ throw.
function Initialize-TaskBranch([string]$root, [int]$n, [string]$main, [string]$name, [string]$promptPath) {
  $wt = Initialize-WorkerTree $root $n $main
  $st = Invoke-GitQuiet -C $wt status --porcelain
  if ($st.Code -ne 0) { throw "không đọc được git status của w$n ($wt): $($st.Text)" }
  if ($st.Text) { throw "w$n còn thay đổi chưa commit: $(Format-DirtyFiles $st.Text) — commit/bỏ thay đổi trong $wt rồi giao lại." }
  Say "git -C $wt switch -c crew/$name $main"
  $r = Invoke-GitQuiet -C $wt switch -q -c "crew/$name" $main
  if ($r.Code -ne 0) { throw "tạo nhánh crew/$name trong w$n thất bại: $($r.Text)" }
  New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
  Copy-Item -LiteralPath $promptPath (Join-Path $wt '.crew/prompt.md') -Force
  $wt
}

# Gửi việc vào terminal worker qua Invoke-SendFlow (luồng an toàn của crew send). Trả @{ Ok; Message }.
# agent ⇒ /clear | /new, chờ phiên mới, rồi dòng giao việc. shell ⇒ bật agent trong worktree với dòng giao việc.
function Send-WorkerTask([string]$term, [string]$kind, [string]$mode, [string]$wt, [string]$line, [string]$access, $ops) {
  if ($mode -eq 'shell') {
    $cmd = "Set-Location -LiteralPath $(Quote $wt); if ((Get-Location).Path -eq $(Quote $wt)) { $(Get-AgentCommand $kind $access $line) } else { Write-Host 'crew: sai thư mục, không bật agent' }"
    return Invoke-SendFlow $term $cmd $ops
  }
  $reset = if ($kind -eq 'codex') { '/new' } else { '/clear' }
  # claude: ~15s để xác nhận /clear; codex: thêm thời gian cho hộp chọn + phiên mới
  $r = Invoke-SendFlow $term $reset $ops $kind $(if ($kind -eq 'codex') { 10 } else { 7 })
  if (-not $r.Ok) { return @{ Ok = $false; Message = "$reset chưa xong, chưa giao việc: $($r.Message)" } }
  # đọc lại màn hình ngay trước khi gửi dòng giao việc: có hộp thoại ⇒ không gửi
  if (Get-ScreenDialog (& $ops.Read $term)) {
    return @{ Ok = $false; Message = "$term hiện hộp thoại sau $reset — chưa giao việc, không bấm phím; xem: hc read $term --lines 20" }
  }
  Invoke-SendFlow $term $line $ops
}

# Lõi crew task (không Die, lỗi ⇒ throw): kiểm terminal TRƯỚC khi đụng git, tạo nhánh + prompt, ghi tasks.json, gửi việc.
# $tasks = danh sách task đã gồm bản ghi mới. Trả @{ Ok; Message; Line } của bước gửi.
function Start-WorkerTask([string]$root, [string]$main, [int]$n, [string]$kind, [string]$access, [string]$term, [string]$name, [string]$promptPath, $tasks, $ops) {
  $info = & $ops.Get $term
  $foreign = Get-ForeignTermError $term $info $root
  if ($foreign) { throw "$foreign Chưa giao việc." }
  $m = Get-WorkerMode $info $kind
  switch ($m.Mode) {
    'dead' { throw "không thấy terminal $term đang chạy — chạy 'crew up' trước." }
    'blocked' { throw "$term đang chờ duyệt — chủ dự án xử lý trước, không giao việc." }
    'wrong' { throw "$term đang chạy $($m.App), config w$n là $kind — chạy 'crew up -Restart w$n' để bật lại đúng agent." }
  }
  # Phiên vừa mở lại chưa có lượt mới thì hc có thể chưa báo app: đừng gõ lệnh shell vào ô nhập của agent.
  $mode = $m.Mode
  if ($mode -eq 'shell' -and (Test-AgentScreen $kind (& $ops.Read $term))) { $mode = 'agent' }
  $wt = Initialize-TaskBranch $root $n $main $name $promptPath
  Save-Tasks $root $tasks
  $line = Get-TaskLine $wt "crew/$name"
  if ($mode -eq 'shell') { Say "bật $kind trong $term" } else { Say "phiên mới cho $kind trong $term" }
  $r = Send-WorkerTask $term $kind $mode $wt $line $access $ops
  @{ Ok = $r.Ok; Message = $r.Message; Line = $line }
}

function Invoke-Task {
  if (-not $Name -or -not $PromptFile) { Die "dùng: crew task <tên> <file-prompt> [-Worker N]" }
  if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Die "tên task chỉ gồm a-z 0-9 -, tối đa 31 ký tự." }
  if (-not (Test-Path $PromptFile)) { Die "không thấy file prompt $PromptFile" }
  $promptPath = (Resolve-Path $PromptFile).Path
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die "chạy trong repo của crew." }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint }
  if ($tasks | Where-Object { $_.name -eq $Name }) { Die "task $Name đã có trong .crew/tasks.json." }

  $n = @($cfg.workers).Count
  $busy = @($tasks | ForEach-Object { [int]$_.worker })
  if ($Worker -eq 0) { $Worker = (1..$n | Where-Object { $busy -notcontains $_ } | Select-Object -First 1) }
  if (-not $Worker) { Die "mọi worker đang bận (số task song song ≤ $n). Dọn task xong bằng 'crew clean <tên>'." }
  if ($Worker -lt 1 -or $Worker -gt $n) { Die "-Worker phải từ 1 tới $n." }
  if ($busy -contains $Worker) { Die "worker $Worker đang có task." }
  $kind = @($cfg.workers)[$Worker - 1]; $term = "$slug-w$Worker"
  $wt = Get-WorkerTree $root $Worker; $branch = "crew/$Name"
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$branch").Code -eq 0) { Die "nhánh $branch đã có — đặt tên khác hoặc xóa nhánh cũ." }
  $main = Get-MainBranch $root
  $rv = if ($InitParameters.ContainsKey('Review')) { $Review } else { '' }
  $tasks = @($tasks) + (New-TaskRecord $Name $branch $wt $Worker $term $kind $rv)

  try { $r = Start-WorkerTask $root $main $Worker $kind $cfg.access $term $Name $promptPath $tasks (New-HcOps) }
  catch { Die $_.Exception.Message }
  if (-not $r.Ok) {
    Die "$($r.Message)`n  Task $Name đã ghi (nhánh $branch, prompt đã chép). Xử lý terminal rồi gửi lại: crew send $term `"$($r.Line)`" — hoặc bỏ: crew clean $Name -Force"
  }
  Say $r.Message
  Say "task $Name -> $term ($kind), nhánh $branch từ $main trong $wt. Theo dõi: hc wait $term / hc read $term --lines 60"
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
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg
  try { $mv = Get-MoveInfo $root $cfg } catch { $mv = $null }; if ($mv -and $mv.Moved) { Write-Host "crew: CẢNH BÁO: $($mv.Hint)" -ForegroundColor Yellow }
  Write-Host "== crew:$slug  review=$($cfg.review) access=$($cfg.access) planner=$($cfg.planner) workers=$($cfg.workers -join ',') rev=$($cfg.rev)"
  Write-Host "== git worktree list"; git -C $root worktree list
  Write-Host "== terminal"
  $terminals = try { @(Get-LiveTerminals) } catch { Write-Host "crew: CẢNH BÁO: $($_.Exception.Message) — không liệt kê được terminal." -ForegroundColor Yellow; @() }
  $foreign = @(); $pending = @{}
  $terminals | Where-Object { $_.name -like "$slug-*" } |
    ForEach-Object {
      $why = Get-ForeignTermError $_.name $_ $root
      if ($why) { $foreign += $why; return ("{0,-18} {1,-5} {2,-9} {3}" -f $_.name, $_.address, 'KHÁC PROJECT', $_.cwd) }
      $st = Get-TermStatus $_
      $status = if ($_.status) { $_.status } else { '-' }
      $app = if ($st.App) { $st.App } else { $_.agent }
      if ($_.state -eq 'live' -and $app -in 'claude', 'claude-code', 'codex') {
        $screen = & (New-HcOps).Read $_.name
        $dialog = Get-ScreenDialog $screen
        if ($dialog -eq 'trust' -and $st.State -in 'idle', 'blocked') { $status = 'chờ trust' }
        elseif (-not $dialog) {
          $inputState = Get-PendingInput $app $st.State $screen
          if ($inputState) {
            $pending[$_.name] = $inputState
            $status = if ($inputState -eq 'queued') { 'tin chờ' } else { 'tin kẹt' }
          }
        }
      }
      "{0,-18} {1,-5} {2,-9} {3}" -f $_.name, $_.address, $status, $_.agent
    } | Write-Host
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
  $warnings = @(Get-HotWarnings $root $cfg $tasks $terminals $pending)
  if ($warnings.Count) {
    Write-Host '== Cảnh báo' -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "- $warning" -ForegroundColor Yellow }
  }
}

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
    $movedTasks = @()
    foreach ($t in $tasks) {
      $nw = [string]$t.worktree
      foreach ($o in $mv.OldRoots) { $nw = Get-MovedPath $nw $o $root }
      if ($nw -ne [string]$t.worktree) { $movedTasks += "$($t.name): $($t.worktree) -> $nw"; $t.worktree = $nw }
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
      if ($selfState -in 'lost', 'unix-shell') {
        $r.Mode = 'self'; $r.Live = $true; $r.Self = $selfState; $selfRole = $r
        Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, 'pane hiện tại, shell trống')
        continue
      }
      if ($selfState -eq 'exited') {
        $r.Live = $true
        Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, 'live, shell (agent đã thoát)')
        continue
      }
    }
    # shell trống sau reboot ⇒ xử lý như terminal thiếu: crew up bật lại, task dở được giao lại ở dưới
    if ($r.Mode -eq 'shell') {
      $shellState = Get-TermShellState $ti { & $ops.Read $r.Term }
      if ($shellState -eq 'lost') { $r.Mode = 'lost' }
      # crew bật pane này, màn hình chưa về dấu nhắc shell ⇒ agent chưa báo status, không phải đã thoát (crew up chạy lại ngay sau khi bật)
      elseif (-not $shellState -and @($ti.argv) -contains '-EncodedCommand') { $r.Mode = 'starting' }
    }
    $r.Live = $r.Mode -notin 'dead', 'lost'
    $note = @{ dead = 'thiếu'; lost = 'shell trống sau reboot — bật lại'; agent = 'live, đúng agent'; starting = 'live, agent đang khởi động'; wrong = 'live, SAI agent'; shell = 'live, shell (agent đã thoát)'; blocked = 'live, chờ duyệt' }[$r.Mode]
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
      if (-not $dry) { Save-Tasks $root $tasks }
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

# ---------------- thay pane của chính lệnh crew ----------------
# Lệnh crew không tắt được pane đang chạy nó: tiến trình nền đợi lệnh xong rồi thay. Hc đặt tiến trình con của pane vào job, kill pane là chết cả job;
# Start-Process và Process.Start đều chết theo (đo trên hc 0.1.17). CreateProcess với CREATE_BREAKAWAY_FROM_JOB sống, kế thừa môi trường và không thành terminal hc.
function Get-SelfPaneFile([string]$root, [string]$ext) { Join-Path $root ".crew/self-pane.$ext" }
function Get-SelfPaneMarker { 'CREW-SELF-PANE:' }
function New-SelfPaneJob([string]$root, [string]$term, [string]$role, [string]$address, [bool]$restart) {
  @{ root = $root; term = $term; role = $role; address = $address; restart = $restart }
}

# Việc cuối của cả lệnh. Con của -All chuyển job lên cha (dòng đánh dấu) vì cha còn phải chạy project khác và in bảng tổng kết.
function Invoke-SelfPaneHandoff($job) {
  if ($env:CREWLINE_UP_ALL_CHILD -eq '1') {
    Write-Host "$(Get-SelfPaneMarker)$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $job -Compress))))"
    return
  }
  Say "tab này sắp chuyển thành $($job.term) sau vài giây; chữ đang in sẽ mất. Đừng gõ gì vào tab này cho tới khi đó."
  try { Start-SelfPaneProcess $job }
  catch { Say "cảnh báo: không tạo được tiến trình nền ($($_.Exception.Message)); giữ pane. Mở tab khác rồi chạy lại: crew up$(if ($job.restart) { " -Restart $($job.role)" })" }
}

# Tạo tiến trình ra khỏi job của pane. Job cấm breakaway (vd runner GitHub Actions) thì CreateProcess lỗi 5: ném lỗi, không có đường dự phòng vì tiến trình trong job chết theo pane.
function Start-BreakawayProcess([string]$exe, [string]$commandLine, [string]$cwd) {
  if (-not ('Crew.Detach' -as [type])) {
    Add-Type -Namespace Crew -Name Detach -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct StartupInfo { public int cb; public string reserved; public string desktop; public string title; public int x; public int y; public int xSize; public int ySize; public int xChars; public int yChars; public int fill; public int flags; public short show; public short reserved2; public System.IntPtr reserved3; public System.IntPtr stdIn; public System.IntPtr stdOut; public System.IntPtr stdErr; }
[StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public System.IntPtr process; public System.IntPtr thread; public int processId; public int threadId; }
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool CreateProcess(string app, System.Text.StringBuilder cmd, System.IntPtr pa, System.IntPtr ta, bool inherit, uint flags, System.IntPtr env, string cwd, ref StartupInfo si, out ProcessInfo pi);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@
  }
  $line = [Text.StringBuilder]::new($commandLine)
  $si = New-Object 'Crew.Detach+StartupInfo'; $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
  $proc = New-Object 'Crew.Detach+ProcessInfo'
  # CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
  if (-not [Crew.Detach]::CreateProcess($exe, $line, [IntPtr]::Zero, [IntPtr]::Zero, $false, [uint32]0x09000400, [IntPtr]::Zero, $cwd, [ref]$si, [ref]$proc)) {
    throw "CreateProcess lỗi $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  [void][Crew.Detach]::CloseHandle($proc.process); [void][Crew.Detach]::CloseHandle($proc.thread)
}

function Start-SelfPaneProcess($job) {
  $file = Get-SelfPaneFile $job.root 'json'
  $job.parentPid = $PID
  New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
  [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $job), [Text.UTF8Encoding]::new($false))
  try {
    $found = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $exe = if ($found) { $found.Source } else { (Get-Process -Id $PID).Path }
    Start-BreakawayProcess $exe "`"$exe`" -NoLogo -NoProfile -NonInteractive -File `"$PSCommandPath`" self-pane-run -Path `"$($job.root)`"" $job.root
  } catch { Remove-Item -LiteralPath $file -ErrorAction Ignore; throw }
}

# Đợi crew thoát rồi xác minh pane. Trả @{ Info; Why }: Why khác rỗng ⇒ giữ pane, không kill. Chỉ đọc.
# Shim chạy crew ngay trong shell của pane nên pid cha có thể là chính shell (không bao giờ thoát): khi đó dấu nhắc trở lại là dấu hiệu crew đã xong.
function Wait-SelfPaneShell($job, $ops, [int]$tries = 120, [int]$settleMs = 3000) {
  $want = if ($job.restart) { 'lost', 'exited' } else { , 'lost' }
  $check = {
    param($info)
    if (-not $info) { return 'không đọc được terminal' }
    if ($info.name -cne $job.term -or $info.address -cne $job.address) { return "terminal đã đổi (tên $($info.name), địa chỉ $($info.address))" }
    if (-not (Test-TermOwner $info $job.root)) { return "terminal không thuộc project (cwd $($info.cwd))" }
    ''
  }
  $parent = [int]$job.parentPid
  $seen = 0; $why = 'chưa thấy dấu nhắc shell, có thể đã có lệnh khác trong pane'
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 500 }
    $info = & $ops.Get $job.term
    $bad = & $check $info
    if ($bad) { return @{ Info = $null; Why = $bad } }
    if ($parent -ne [int]$info.pid -and (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { $seen = 0; $why = 'lệnh crew chưa thoát'; continue }
    if ((Get-TermShellState $info { & $ops.Read $job.term }) -notin $want) { $seen = 0; $why = 'pane không còn là shell trống (có thể bạn đã gõ lệnh khác)'; continue }
    if (++$seen -ge 2) { break }
  }
  if ($seen -lt 2) { return @{ Info = $null; Why = $why } }
  # Cho người dùng kịp đọc, rồi đọc lại lần cuối ngay trước kill.
  & $ops.Sleep $settleMs
  $info = & $ops.Get $job.term
  $bad = & $check $info
  if ($bad) { return @{ Info = $null; Why = $bad } }
  if ((Get-TermShellState $info { & $ops.Read $job.term }) -notin $want) { return @{ Info = $null; Why = 'pane không còn là shell trống ở lần đọc cuối' } }
  @{ Info = $info; Why = '' }
}

# Vai số lẻ đứng trước vai số chẵn trong cùng tab workers; pane vừa bật lại luôn vào cuối tab. Vai không chung tab với ai thì không cần làm gì.
function Restore-SelfPaneOrder([string]$slug, [string]$role, $ids, [string]$focus) {
  if ($role -notmatch '^w(\d+)$' -or [int]$Matches[1] % 2 -eq 0) { return }
  $n = [int]$Matches[1]
  $names = "$slug-w$n", "$slug-w$($n + 1)"
  $tab = & $ids.Workers ([math]::Ceiling($n / 2))
  $read = {
    $hs = Get-HerdrSpaces
    if (-not $hs.Ok) { return @() }
    foreach ($sp in @($hs.Spaces)) { foreach ($tb in @($sp.tabs)) { if ($tb.id -ceq $tab) { return @($tb.terminals) } } }
    @()
  }
  $terms = @(& $read)
  $order = @($terms | Where-Object { $names -ccontains $_.name } | ForEach-Object { $_.name })
  if ($order.Count -lt 2 -or $order[0] -ceq $names[0]) { return }
  $mine = @($terms | Where-Object { $_.name -ceq $names[0] })[0]
  herdr-app do pane.focus --terminal $mine.terminal | Out-Null
  herdr-app do pane.swap --direction left | Out-Null
  $after = @(@(& $read) | Where-Object { $names -ccontains $_.name } | ForEach-Object { $_.name })
  if ($after.Count -ge 2 -and $after[0] -cne $names[0]) { Say "cảnh báo: $($names[0]) chưa về đúng vị trí trong tab workers." }
  herdr-app do space.select --id $ids.Space | Out-Null
  herdr-app do tab.select --id $focus | Out-Null
}

# Giới hạn tổng của self-pane-run, chỗ duy nhất. Biến môi trường để test rút ngắn.
function Get-SelfPaneTimeoutSec {
  $v = 0
  if ([int]::TryParse("$env:CREWLINE_SELF_PANE_TIMEOUT_SEC", [ref]$v) -and $v -gt 0) { return $v }
  600
}

# Tiến trình nền: không còn pane để in nên mọi chữ vào log; xong êm thì xóa log, còn log nghĩa là có chuyện để crew up lần sau nhắc.
function Set-SelfPaneLogging([string]$log) {
  $script:SelfPaneLog = $log
  # Tên trùng cmdlet: hàm thắng, nên Say/Die và mọi báo cáo của repair đều vào log.
  function script:Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, [switch]$NoNewline) Add-Content -LiteralPath $script:SelfPaneLog -Value "$(Get-Date -Format s) $(@($Object) -join ' ')" -Encoding utf8 }
}

# Giám sát: lệnh con treo thì không ngắt được từ trong cùng tiến trình, nên việc thật chạy ở self-pane-work; quá hạn thì kill cả cây, ghi log, nhả lock.
function Invoke-SelfPaneRun {
  $root = (Resolve-Path $Path).Path
  $file = Get-SelfPaneFile $root 'json'; $killMark = Get-SelfPaneFile $root 'killed'
  Set-SelfPaneLogging (Get-SelfPaneFile $root 'log')
  try { $lock = [IO.File]::Open((Get-SelfPaneFile $root 'lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { exit 0 }  # đã có tiến trình khác đang thay
  try {
    Remove-Item -LiteralPath $killMark -ErrorAction Ignore
    $limit = Get-SelfPaneTimeoutSec
    $found = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $psi = [Diagnostics.ProcessStartInfo]::new($(if ($found) { $found.Source } else { (Get-Process -Id $PID).Path }))
    foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, 'self-pane-work', '-Path', $root) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $root
    $p = [Diagnostics.Process]::Start($psi)
    if ($p.WaitForExit($limit * 1000)) { exit $p.ExitCode }
    $stopped = try { $p.Kill($true); $p.WaitForExit(10000) } catch { $false }
    if (-not $stopped) { Say "cảnh báo: chưa dừng được tiến trình nền pid $($p.Id)." }
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    if (Test-Path -LiteralPath $killMark) { Say "quá hạn $limit giây, đã dừng thay pane; pane có thể đã tắt. Chạy crew up để bật vai thiếu." }
    else { Say "quá hạn $limit giây, đã dừng thay pane; pane chưa bị tắt, giữ nguyên. Muốn thay thì chạy lại crew up trong pane đó." }
    exit 1
  } catch {
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    Say "lỗi: $($_.Exception.Message). Chạy crew up để bật vai thiếu."
    exit 1
  } finally {
    Remove-Item -LiteralPath $killMark -ErrorAction Ignore
    $lock.Dispose()
  }
}

function Invoke-SelfPaneWork {
  $root = (Resolve-Path $Path).Path
  $log = Get-SelfPaneFile $root 'log'; $file = Get-SelfPaneFile $root 'json'
  Set-SelfPaneLogging $log
  try {
    foreach ($v in 'HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET', 'HC_SCOPE', 'CREWLINE_UP_ALL_CHILD') { Remove-Item "Env:$v" -ErrorAction Ignore }
    Say 'bắt đầu thay pane.'
    $job = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    Remove-Item -LiteralPath $file -ErrorAction Ignore
    $ops = New-RepairOps
    $seen = Wait-SelfPaneShell $job $ops
    if ($seen.Why) { Say "giữ pane $($job.term), không tắt: $($seen.Why). Muốn thay thì chạy lại crew up trong pane đó."; exit 0 }
    [IO.File]::WriteAllText((Get-SelfPaneFile $root 'killed'), $job.term)  # giám sát cần biết pane đã có thể mất khi quá hạn
    Stop-Term $seen.Info.address
    if ((Get-WorkerMode (& $ops.Get $job.term) 'claude').Mode -ne 'dead') { Say "$($job.term) vẫn live sau kill; không bật chồng."; exit 1 }
    $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
    $script:Path = $root; $script:FromRepair = $true
    $problems = @()
    if ($job.restart) { $script:Restart = $job.role; $script:Force = $true; Invoke-Up }
    else {
      $res = Invoke-RepairCore $root $cfg $slug (Get-MainBranch $root) $false $ops
      $problems = @($res.Human)
      foreach ($f in $res.Finished) { Say $f }
    }
    foreach ($h in $problems) { Say "CẦN NGƯỜI QUYẾT: $h" }
    $focus = if ($cfg.planner -ne 'none') { $ids.Planner } else { & $ids.Workers 1 }
    Restore-SelfPaneOrder $slug $job.role $ids $focus
    if ((Get-WorkerMode (& $ops.Get $job.term) 'claude').Mode -eq 'dead') { Say "$($job.term) chưa live sau khi bật lại. Chạy crew up để bật vai thiếu."; exit 1 }
    if (-not $problems.Count) { Remove-Item -LiteralPath $log -ErrorAction Ignore }
    exit 0
  } catch { Say "lỗi: $($_.Exception.Message). Chạy crew up để bật vai thiếu."; exit 1 }
}

# Lần thay pane trước có chuyện: nhắc một lần. Tiến trình nền còn giữ khóa thì log chưa xong, không đụng.
function Show-SelfPaneLog([string]$root, [bool]$dry) {
  $log = Get-SelfPaneFile $root 'log'; $lock = Get-SelfPaneFile $root 'lock'
  if (-not (Test-Path -LiteralPath $log)) { return }
  if (Test-Path -LiteralPath $lock) { try { ([IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')).Dispose() } catch { return } }
  $kept = "$log.old"
  Say "lần thay pane trước có chuyện cần xem, log: $(if ($dry) { $log } else { $kept })"
  if (-not $dry) { Move-Item -LiteralPath $log -Destination $kept -Force }
}

# Bảng hc/herdr THẬT cho crew repair: New-HcOps + Up + (cho project đã chuyển) terminal live, space herdr, kill, đóng space.
# List ném lỗi khi hc ls lỗi (Get-LiveTerminals) — repair coi lỗi là dừng, không Kill/Close/Up/Send.
function New-RepairOps {
  $ops = New-HcOps; $ops.Up = { $script:FromRepair = $true; Invoke-Up }
  # cho Get-MoveInfo + sửa project đã chuyển: terminal live, space herdr, kill, đóng space cũ
  $ops.List = { @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) }
  $ops.Spaces = { Get-HerdrSpaces }
  $ops.Kill = { param($address) Stop-Term $address }
  $ops.CloseSpace = {
    param($id)
    $out = & { $ErrorActionPreference = 'Continue'; herdr-app do space.close --id $id --confirmed true 2>&1 | Out-String }
    @{ Code = $LASTEXITCODE; Text = "$out".Trim() }
  }
  $ops
}

# Khôi phục một project — dùng chung cho crew up (không -Restart) và crew repair; dựng terminal thiếu qua $ops.Up = Invoke-Up.
# $stopOnClash: crew up giữ chốt chặn cũ, tên/khóa id đã thuộc project khác còn tồn tại thì dừng trước khi đụng gì.
function Invoke-Recover([bool]$stopOnClash) {
  $p = (Resolve-Path $Path).Path
  $root = Get-MainRoot $p
  if ($stopOnClash -and $env:CREWLINE_UP_ALL_CHILD -ne '1' -and
    (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json')))) {
    if ($root -and -not (Test-SamePath (Get-Root $p) $root)) {
      Die "repo chính $root chưa init; đang ở worktree phụ nên không tạo gì. Chạy crew up tại repo chính."
    }
    $initRoot = if ($root) { $root } else { $p }
    $needsGit = -not $root -or (Invoke-GitQuiet -C $root rev-parse --verify -q HEAD).Code -ne 0
    if ($needsGit -and ((Test-SamePath $initRoot $HOME) -or (Test-SamePath $initRoot ([IO.Path]::GetPathRoot($initRoot))))) {
      Die "không init tại HOME hoặc gốc hệ thống tệp ($initRoot) khi chưa có commit; hãy chọn thư mục project con."
    }
    if ($DryRun) { Say 'project chưa init, crew up sẽ hỏi tạo'; exit 0 }
    $answer = $null
    if ($env:CREWLINE_DEFAULTS -ne '1') {
      . (Join-Path $PSScriptRoot 'ui.ps1')
      $title = "Project $initRoot chưa init. Tạo context/, CLAUDE.md, AGENTS.md, .crew/, sửa .gitignore và commit?"
      if ($needsGit) { $title += ' Sẽ git init (nếu cần) và commit TẤT CẢ file đang có.' }
      $options = @((New-Option 'yes' 'Có' -Alias 'y', 'yes'), (New-Option 'no' 'Thôi' -Alias 'n', 'no'))
      $answer = Read-Choice $title $options $(if ($needsGit) { 'no' } else { 'yes' }) -NoStep -NullOnEof
    }
    if ($null -eq $answer) { Die "project chưa init; không hỏi được nên không tạo gì. Chạy crew init tại $initRoot." }
    if ($answer -ne 'yes') { Say 'thôi, không tạo gì.'; exit 1 }
    # Phạm vi cục bộ: bỏ câu hỏi git của init, giữ nguyên ưu tiên đội/cờ dòng lệnh.
    $GitInit = [bool]$needsGit
    Invoke-Init
    $root = Get-MainRoot $p
  }
  if (-not $root) { Die "không phải repo git. Project mới: chạy 'crew init' trong thư mục này trước." }
  Update-ConfigName $root ([bool]$DryRun)
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg
  if ($stopOnClash) { $clash = Get-NameConflict $root $cfg; if ($clash) { Die $clash } }
  $main = Get-MainBranch $root
  $script:Path = $root  # crew up dựng theo repo chính, kể cả khi gọi từ worktree
  Show-SelfPaneLog $root ([bool]$DryRun)
  $ops = New-RepairOps
  $res = Invoke-RepairCore $root $cfg $slug $main ([bool]$DryRun) $ops
  Write-Host "== kết luận$(if ($DryRun) { ' (DryRun: không ghi git, không bật, không gửi)' })"
  if ($res.Done.Count) { foreach ($d in $res.Done) { Write-Host "  đã làm: $d" } } else { Write-Host '  không có gì phải sửa.' }
  foreach ($f in $res.Finished) { Write-Host "  $f" }
  foreach ($h in $res.Human) { Write-Host "  CẦN NGƯỜI QUYẾT: $h" -ForegroundColor Yellow }
  if ($res.Self) {
    $s = $res.Self
    if ($s.Self -eq 'unix-shell') { Write-Host "  $($s.Term) là pane hiện tại, shell trống; chưa xác minh shell trên hệ này nên crew không tự thay. Mở tab khác rồi chạy lại: crew up" }
    elseif (-not $stopOnClash) { Write-Host "  $($s.Term) là pane hiện tại, shell trống; crew repair không tự thay. Thay bằng: crew up" }
    elseif ($DryRun) { Write-Host "  (sẽ làm) thay pane hiện tại thành $($s.Term), sau cùng: $(Format-SessionPlan (Get-SessionPlan (Read-SessionBook $root) $root $cfg $s.Role $s.Kind))" }
    else { Invoke-SelfPaneHandoff (New-SelfPaneJob $root $s.Term $s.Role $env:HC_TERMINAL_ID $false) }
  }
  if ($res.Human.Count) { exit 1 }
  exit 0
}

# Danh sách project cho crew up -All (hàm thuần trừ kiểm thư mục): mục sổ theo thứ tự sổ, cộng $current (root đã init) nếu chưa có trong sổ.
# Trả mảng @{ Name; Root; Skip } — Skip khác rỗng ⇒ bỏ qua, nêu lý do; không tạo/xóa gì.
function Get-UpAllPlan($map, [string]$current) {
  $plan = @(foreach ($n in @($map.Keys)) {
      $r = [string]$map[$n].Root
      $skip = if (-not (Test-Path -LiteralPath $r -PathType Container)) { 'thư mục không còn' }
      elseif (-not (Test-Path -LiteralPath (Join-Path $r '.crew/config.json') -PathType Leaf)) { 'không còn .crew/config.json' }
      else { '' }
      @{ Name = [string]$n; Root = $r; Skip = $skip }
    })
  if ($current -and -not @($plan | Where-Object { Test-SamePath $_.Root $current }).Count) {
    $plan += @{ Name = (Split-Path $current -Leaf); Root = $current; Skip = '' }
  }
  , @($plan)
}

# Kết quả một project từ exit code + output tiến trình con. crew up trả exit 1 cho cả hai trường hợp, chỉ dòng kết luận phân biệt được.
function Get-UpChildResult([int]$code, [string]$text) {
  if ($code -eq 0) { return 'ok' }
  if ($text -match '(?m)^\s*CẦN NGƯỜI QUYẾT:') { return 'cần người quyết' }
  'lỗi'
}

# Bảng tổng kết crew up -All. $rows: @{ Name; Root; Result; Note }. Trả các dòng.
function Format-UpAllSummary($rows) {
  $rows = @($rows)
  $nw = (@('tên') + @($rows | ForEach-Object { $_.Name }) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
  $pw = (@('đường dẫn') + @($rows | ForEach-Object { $_.Root }) | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
  $line = { param($a, $b, $c) ("{0}  {1}  {2}" -f "$a".PadRight($nw), "$b".PadRight($pw), $c) }
  @(& $line 'tên' 'đường dẫn' 'kết quả') + @($rows | ForEach-Object {
      & $line $_.Name $_.Root "$($_.Result)$(if ($_.Note) { ": $($_.Note)" })"
    })
}

# Một tiến trình pwsh riêng cho mỗi project: Invoke-Recover và Die gọi exit, lại dùng $script:Path/$script:FromRepair.
# In output của con khi nó chạy, trả @{ Code; Text }; không chạy được pwsh ⇒ Code = 1.
function Invoke-UpChild([string]$root, [bool]$dry) {
  $ErrorActionPreference = 'Continue'
  # Get-Command trước: pwsh bản Store chỉ chạy được qua alias trong PATH, không qua đường dẫn của tiến trình
  $exe = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $shell = if ($exe) { $exe.Source } else { (Get-Process -Id $PID).Path }
  $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, 'up', '-Path', $root)
  if ($dry) { $argv += '-DryRun' }
  $lines = [Collections.Generic.List[string]]::new()
  $selfJob = $null
  $marker = Get-SelfPaneMarker
  $savedUpAllChild = $env:CREWLINE_UP_ALL_CHILD
  try {
    $env:CREWLINE_UP_ALL_CHILD = '1'
    & $shell @argv 2>&1 | ForEach-Object {
      $l = "$_" -replace "\x1b\[[0-9;]*m", ''
      if ($l.StartsWith($marker)) { $selfJob = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($l.Substring($marker.Length))) | ConvertFrom-Json -AsHashtable; return }
      $lines.Add($l); Write-Host "  $l"
    }
    $code = $LASTEXITCODE
  } catch { $lines.Add("không chạy được pwsh ($shell): $($_.Exception.Message)"); $code = 1 }
  finally { $env:CREWLINE_UP_ALL_CHILD = $savedUpAllChild }
  @{ Code = [int]$code; Text = ($lines -join "`n"); SelfJob = $selfJob }
}

function Invoke-UpAll {
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Die "$($reg.Error) — không khôi phục, không ghi đè sổ. Sửa hoặc xóa file đó rồi chạy lại." }
  $current = try { Get-MainRoot (Resolve-Path $Path).Path } catch { $null }
  if ($current -and -not (Test-Path -LiteralPath (Join-Path $current '.crew/config.json') -PathType Leaf)) { $current = $null }
  $plan = Get-UpAllPlan $reg.Map $current
  if (-not $plan.Count) { Say 'sổ chưa có project nào, thư mục hiện tại cũng chưa init: không có gì để khôi phục.'; exit 0 }
  $selfJob = $null
  $rows = @(foreach ($p in $plan) {
      if ($p.Skip) { @{ Name = $p.Name; Root = $p.Root; Result = 'bỏ qua'; Note = $p.Skip }; continue }
      Write-Host "== $($p.Name) ($($p.Root))"
      $r = Invoke-UpChild $p.Root ([bool]$DryRun)
      if ($r.SelfJob) { $selfJob = $r.SelfJob }
      $result = Get-UpChildResult $r.Code $r.Text
      $note = if ($result -eq 'lỗi') { "exit $($r.Code), xem output ở trên" } else { '' }
      @{ Name = $p.Name; Root = $p.Root; Result = $result; Note = $note }
    })
  Write-Host "== tổng kết crew up -All$(if ($DryRun) { ' (DryRun: không ghi, không bật, không gửi)' })"
  Format-UpAllSummary $rows | ForEach-Object { Write-Host "  $_" }
  if ($selfJob) { Invoke-SelfPaneHandoff $selfJob }
  if (@($rows | Where-Object { $_.Result -in 'lỗi', 'cần người quyết' }).Count) { exit 1 }
  exit 0
}

# ---------------- limits ----------------
# Ngưỡng limit — chỗ DUY NHẤT đặt số. Xếp từ cao xuống; dưới mọi ngưỡng là 'ok'.
function Get-LimitTiers {
  return @(
    @{ Min = 90; Level = 'dừng'; Note = 'dừng' },
    @{ Min = 70; Level = 'hạn chế'; Note = 'hạn chế task L' },
    @{ Min = 50; Level = 'theo dõi'; Note = 'theo dõi' }
  )
}
# % tuần không vào mốc; từ ngưỡng này chỉ cảnh báo (báo chủ dự án trước khi giao), không tự chặn.
function Get-LimitWeekWarn { return 90 }
function Get-LimitLevel([int]$used) {
  foreach ($t in (Get-LimitTiers)) { if ($used -ge $t.Min) { return $t.Level } }
  return 'ok'
}

# Tách % limit đã dùng từ chữ màn hình. Codex: '5h 100% left · weekly 71% left' (dùng = 100 - left).
# Claude (status line riêng của người dùng): '5h 13% · week 24%' (đã là % dùng). Lấy lần xuất hiện cuối (chân màn hình).
function Get-LimitInfo([string]$screen) {
  function Find-Used([string]$text, [string]$label) {
    $ms = [regex]::Matches($text, "(?<![\w])$label\s+(\d{1,3})%(\s+left)?")
    if (-not $ms.Count) { return $null }
    $m = $ms[$ms.Count - 1]; $n = [int]$m.Groups[1].Value
    if ($n -gt 100) { return $null }
    if ($m.Groups[2].Success) { return 100 - $n }
    return $n
  }
  $five = Find-Used "$screen" '5h'
  $week = Find-Used "$screen" '(?:weekly|week)'
  # Mốc chỉ theo 5h; tuần chỉ bật cờ cảnh báo.
  $level = if ($null -eq $five) { 'không rõ' } else { Get-LimitLevel $five }
  $warn = $null -ne $week -and $week -ge (Get-LimitWeekWarn)
  return @{ FiveHour = $five; Week = $week; Level = $level; WeekWarn = $warn }
}

# Limit tính theo tài khoản agent, không theo pane: pane chạy mà đọc không được ('không rõ', vd chân màn hình bị cắt '…')
# lấy số của pane đầu tiên cùng agent đọc được, ghi From = tên pane đó. Hàm thuần, không gọi hc.
# Vào: mỗi dòng @{ Name; Agent; Live; Info } (Info = kết quả Get-LimitInfo, $null nếu tắt). Ra: thêm Shown (Info hiển thị) và From.
function Resolve-LimitRows($rows) {
  $out = @()
  foreach ($r in @($rows)) {
    $row = @{} + $r; $row.From = $null; $row.Shown = $r.Info
    if ($r.Live -and (-not $r.Info -or $r.Info.Level -eq 'không rõ')) {
      $src = @($rows | Where-Object { $_.Agent -eq $r.Agent -and $_.Name -ne $r.Name -and $_.Live -and $_.Info -and $_.Info.Level -ne 'không rõ' }) | Select-Object -First 1
      if ($src) {
        # Mượn nguyên Info (gồm WeekWarn); pane tự đọc được tuần ≥ngưỡng thì vẫn giữ cảnh báo.
        $row.Shown = @{} + $src.Info; $row.From = $src.Name
        if ($r.Info -and $r.Info.WeekWarn) { $row.Shown.WeekWarn = $true }
      }
    }
    $out += $row
  }
  return , $out
}

# ---- số limit trực tiếp từ CLI agent. Phản hồi thô có thể chứa email/gói tài khoản: chỉ giữ % và giờ reset, không in/ghi. ----
# % hợp lệ từ JSON: chỉ nhận kiểu số trong 0–100 (chuỗi, bool, null ⇒ $null). Số lẻ làm tròn.
function ConvertTo-LimitPercent($value) {
  if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) { return $null }
  if ($value -lt 0 -or $value -gt 100) { return $null }
  return [int][math]::Round([double]$value, [MidpointRounding]::AwayFromZero)
}

# Epoch giây ⇒ giờ địa phương gọn: cùng ngày 'HH:mm', khác ngày 'dd/MM HH:mm'. Sai kiểu/ngoài khoảng ⇒ $null.
function Format-LimitEpoch($epoch, [datetime]$now = (Get-Date)) {
  if ($epoch -isnot [int] -and $epoch -isnot [long]) { return $null }
  if ($epoch -le 0) { return $null }
  try { $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToLocalTime().DateTime } catch { return $null }
  $fmt = if ($at.Date -eq $now.Date) { 'HH:mm' } else { 'dd/MM HH:mm' }
  return $at.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
}

# Bước hội thoại JSON-RPC của `codex app-server`, thuần. Chỉ gửi initialize / initialized / account/rateLimits/read; không thread/turn nên không gọi model.
function Get-CodexLimitHello { '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"crew_limits","title":"crew","version":"0"}}}' }
function Get-CodexLimitStep([string]$line) {
  $msg = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { return @{ Write = @(); Done = $false } }
  # Bỏ qua thông báo và request từ server (có method), kể cả khi trùng id.
  if ($msg -isnot [pscustomobject] -or $msg.PSObject.Properties.Name -contains 'method' -or $msg.PSObject.Properties.Name -notcontains 'id') { return @{ Write = @(); Done = $false } }
  if ($msg.id -eq 1) {
    if ($msg.PSObject.Properties.Name -contains 'error') { return @{ Write = @(); Done = $true } }
    return @{ Write = @('{"method":"initialized"}', '{"method":"account/rateLimits/read","id":2}'); Done = $false }
  }
  if ($msg.id -eq 2) { return @{ Write = @(); Done = $true } }
  return @{ Write = @(); Done = $false }
}

# Tách phản hồi id=2 của Codex, thuần. Lấy cửa sổ theo windowDurationMins (300 = 5h, 10080 = tuần), không đoán theo primary/secondary.
function ConvertFrom-CodexLimitReply([string[]]$lines, [datetime]$now = (Get-Date)) {
  foreach ($line in @($lines)) {
    $msg = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    if ($msg -isnot [pscustomobject]) { continue }
    $names = $msg.PSObject.Properties.Name
    if ($names -notcontains 'id' -or $msg.id -ne 2 -or $names -contains 'method') { continue }
    if ($names -contains 'error' -or $names -notcontains 'result') { return $null }
    $result = $msg.result
    if ($result -isnot [pscustomobject]) { return $null }
    $limits = $result.rateLimits
    if ($limits -isnot [pscustomobject]) { return $null }
    $five = $null; $week = $null
    foreach ($w in @($limits.primary, $limits.secondary)) {
      if ($w -isnot [pscustomobject]) { return $null }
      if ($w.windowDurationMins -eq 300) { $five = $w } elseif ($w.windowDurationMins -eq 10080) { $week = $w }
    }
    if (-not $five -or -not $week) { return $null }
    $fiveUsed = ConvertTo-LimitPercent $five.usedPercent
    $weekUsed = ConvertTo-LimitPercent $week.usedPercent
    if ($null -eq $fiveUsed -or $null -eq $weekUsed) { return $null }
    return @{ FiveHour = $fiveUsed; Week = $weekUsed; FiveHourReset = (Format-LimitEpoch $five.resetsAt $now); WeekReset = (Format-LimitEpoch $week.resetsAt $now) }
  }
  return $null
}

# Tách văn bản /usage của Claude, thuần. Mỗi nhãn phải đúng một dòng khớp từ đầu dòng; không phụ thuộc ký tự '·' (console có thể làm hỏng).
# Giờ reset giữ như CLI in, bỏ múi giờ; có thể thiếu khi cửa sổ chưa bắt đầu. Thiếu số ⇒ $null.
function ConvertFrom-ClaudeUsageText([string]$text) {
  function Find-Window([string[]]$lines, [string]$label) {
    $hits = @($lines | ForEach-Object { [regex]::Match($_, "^\s*$label\s*:\s*(\d{1,3})\s*%\s*used\b(.*)$") } | Where-Object { $_.Success })
    if ($hits.Count -ne 1) { return $null }
    $used = [int]$hits[0].Groups[1].Value
    if ($used -gt 100) { return $null }
    $reset = $null
    $m = [regex]::Match($hits[0].Groups[2].Value, '\bresets\s+(.+?)\s*$')
    if ($m.Success) {
      $t = ($m.Groups[1].Value -replace '\s*\([^)]*\)\s*$', '').Trim()
      # Chỉ giữ thứ trông như giờ; chuỗi lạ không vào bảng.
      if ($t.Length -le 24 -and $t -match '\d' -and $t -notmatch '@') { $reset = $t }
    }
    return @{ Used = $used; Reset = $reset }
  }
  $lines = @("$text" -split '\r?\n')
  $five = Find-Window $lines 'Current session'
  $week = Find-Window $lines 'Current week\s*\(all models\)'
  if (-not $five -or -not $week) { return $null }
  return @{ FiveHour = $five.Used; Week = $week.Used; FiveHourReset = $five.Reset; WeekReset = $week.Reset }
}

# Tách stdout JSON của `claude -p /usage --output-format json`, thuần. Báo lỗi hoặc đã có lượt model (num_turns > 0) ⇒ $null: chữ model viết không phải số thật.
function ConvertFrom-ClaudeUsageReply([string[]]$lines) {
  $msg = try { (@($lines) -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { $null }
  if ($msg -isnot [pscustomobject]) { return $null }
  $names = $msg.PSObject.Properties.Name
  if ($names -notcontains 'result' -or $msg.result -isnot [string]) { return $null }
  if ($names -contains 'is_error' -and $msg.is_error -ne $false) { return $null }
  if ($names -contains 'num_turns' -and $msg.num_turns -ne 0) { return $null }
  return ConvertFrom-ClaudeUsageText $msg.result
}

# Dựng lệnh gọi CLI, thuần. Shim npm trên Windows (.ps1/.cmd/.bat) phải chạy qua pwsh; còn lại gọi thẳng (Unix chạy shebang).
function Get-LimitCliInvocation([string]$source, [string[]]$cliArgs, [string]$os = (Get-CrewOS), [string]$shell = ((Get-Process -Id $PID).Path)) {
  if ($os -ne 'windows' -or [IO.Path]::GetExtension($source) -notin '.ps1', '.cmd', '.bat') { return @{ File = $source; ArgList = @($cliArgs) } }
  $call = "[Console]::InputEncoding=[Console]::OutputEncoding=`$OutputEncoding=[Text.UTF8Encoding]::new(`$false); & '$($source.Replace("'", "''"))'"
  foreach ($a in @($cliArgs)) { $call += " '$($a.Replace("'", "''"))'" }
  return @{ File = $shell; ArgList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $call) }
}

# Tìm CLI trên PATH hiện tại; chỉ nhận file thực thi, không nhận alias/hàm. Thiếu ⇒ $null.
function Find-LimitCli([string]$name) {
  $c = Get-Command $name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# Thư mục làm việc rỗng, CỐ ĐỊNH và của riêng user. Không dùng thư mục tạm mới mỗi lần: Claude tạo một thư mục trong ~/.claude/projects cho mỗi cwd (đã đo),
# gọi nhiều sẽ tích rác. Không dùng tên cố định trong /tmp chung: user khác có thể đặt sẵn file cấu hình.
function Get-LimitCwd { Join-Path $HOME '.crewline/limits-cwd' }

# Chạy CLI trong $Cwd, đọc stdout bằng UTF-8, không quá hạn và luôn kill cả cây tiến trình khi xong.
# $OnLine (nếu có) nhận từng dòng, trả @{ Write; Done }. Stdin đóng ngay khi không có $OnLine. Ra: @{ Started; TimedOut; Killed; ExitCode; Lines }. Không ném lỗi.
function Invoke-LimitProcess($invocation, [string[]]$send = @(), [scriptblock]$OnLine = $null, [string]$Cwd, [int]$TimeoutMs = 12000) {
  $res = @{ Started = $false; TimedOut = $false; Killed = $false; ExitCode = $null; Lines = @() }
  $p = $null
  $lines = [Collections.Generic.List[string]]::new()
  try {
    $null = New-Item -ItemType Directory -Path $Cwd -Force -ErrorAction Stop
    $psi = [Diagnostics.ProcessStartInfo]::new($invocation.File)
    foreach ($a in @($invocation.ArgList)) { $psi.ArgumentList.Add([string]$a) }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $Cwd
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = $utf8; $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    # Không để tiến trình con kế thừa phiên agent/pane đang gọi crew.
    foreach ($v in 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN', 'HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET', 'HC_SCOPE') { $null = $psi.Environment.Remove($v) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $res.Started = $true
    $null = $p.StandardError.ReadToEndAsync()  # xả stderr để không kẹt pipe; không dùng nội dung
    foreach ($l in @($send)) { $p.StandardInput.WriteLine($l) }
    $p.StandardInput.Flush()
    if (-not $OnLine) { $p.StandardInput.Close() }
    $read = $null; $done = $false
    while (-not $done) {
      $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
      if ($left -le 0) { $res.TimedOut = $true; break }
      if (-not $read) { $read = $p.StandardOutput.ReadLineAsync() }
      if (-not $read.Wait([math]::Min($left, 200))) { continue }
      $line = $read.Result; $read = $null
      if ($null -eq $line) { break }
      $lines.Add($line)
      if ($OnLine) {
        $step = & $OnLine $line
        foreach ($l in @($step.Write)) { $p.StandardInput.WriteLine($l) }
        $p.StandardInput.Flush()
        if ($step.Done) { $done = $true }
      }
    }
    if (-not $done -and -not $res.TimedOut) {
      $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
      if ($left -le 0 -or -not $p.WaitForExit($left)) { $res.TimedOut = $true } else { $res.ExitCode = $p.ExitCode }
    }
  }
  catch { $res.ExitCode = $null }
  finally {
    if ($p) {
      try { if (-not $p.HasExited) { $p.Kill($true); $res.Killed = $true; $null = $p.WaitForExit(2000) } } catch {}
    }
  }
  $res.Lines = $lines.ToArray()
  return $res
}

# Việc chạm ngoài hàm thuần, tiêm được cho test: tìm CLI + chạy tiến trình.
function New-LimitOps {
  return @{
    Find = { param($name) Find-LimitCli $name }
    Run = { param($invocation, $send, $onLine) Invoke-LimitProcess $invocation $send $onLine (Get-LimitCwd) }
  }
}

function Get-CodexLiveLimit($Ops) {
  try {
    $src = & $Ops.Find 'codex'
    if (-not $src) { return $null }
    $inv = Get-LimitCliInvocation $src @('app-server')
    $r = & $Ops.Run $inv @(Get-CodexLimitHello) { param($line) Get-CodexLimitStep $line }
    if (-not $r -or $r.TimedOut) { return $null }
    return ConvertFrom-CodexLimitReply $r.Lines
  }
  catch { return $null }
}

function Get-ClaudeLiveLimit($Ops) {
  try {
    $src = & $Ops.Find 'claude'
    if (-not $src) { return $null }
    $inv = Get-LimitCliInvocation $src @('-p', '/usage', '--output-format', 'json', '--no-session-persistence')
    $r = & $Ops.Run $inv @() $null
    if (-not $r -or $r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    return ConvertFrom-ClaudeUsageReply $r.Lines
  }
  catch { return $null }
}

# Số trực tiếp ⇒ cùng dạng Info của Get-LimitInfo, thêm giờ reset. Mốc và cảnh báo tuần dùng chung ngưỡng.
function ConvertTo-LimitInfo($liveLimit) {
  return @{
    FiveHour = $liveLimit.FiveHour; Week = $liveLimit.Week; FiveHourReset = $liveLimit.FiveHourReset; WeekReset = $liveLimit.WeekReset
    Level = (Get-LimitLevel $liveLimit.FiveHour); WeekWarn = ($liveLimit.Week -ge (Get-LimitWeekWarn))
  }
}

function Invoke-Limits($Ops = (New-LimitOps)) {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $rows = @()
  if ($cfg.planner -ne 'none') { $rows += @{ Name = "$slug-planner"; Agent = $cfg.planner } }
  $wi = 0
  foreach ($kind in @($cfg.workers)) { $wi++; $rows += @{ Name = "$slug-w$wi"; Agent = $kind } }
  if ($cfg.rev -ne 'none') { $rows += @{ Name = "$slug-rev"; Agent = $cfg.rev } }
  # Limit theo tài khoản: mỗi loại agent trong config chỉ hỏi một lần, kể cả khi pane đang tắt.
  $liveByAgent = @{}
  foreach ($agent in @($rows | ForEach-Object { $_.Agent } | Select-Object -Unique)) {
    if ($agent -eq 'codex') { $liveByAgent[$agent] = Get-CodexLiveLimit $Ops }
    elseif ($agent -eq 'claude') { $liveByAgent[$agent] = Get-ClaudeLiveLimit $Ops }
  }
  $liveTerms = try { @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' }) } catch { Say "cảnh báo: $($_.Exception.Message) — không đọc được terminal nào."; @() }
  $live = @($liveTerms | ForEach-Object { $_.name })
  $foreign = @()
  foreach ($r in $rows) {
    $r.Live = $live -contains $r.Name
    # terminal cùng tên của project khác: không đọc số của nó, chỉ cảnh báo
    $why = if ($r.Live) { Get-ForeignTermError $r.Name ($liveTerms | Where-Object { $_.name -eq $r.Name } | Select-Object -First 1) $root } else { '' }
    if ($why) { $foreign += $why; $r.Live = $false }
    $direct = $liveByAgent[$r.Agent]
    $r.Direct = [bool]$direct
    $r.Info = if (-not $r.Live) { $null }
    elseif ($direct) { ConvertTo-LimitInfo $direct }
    else { Get-LimitInfo ((hc read $r.Name --lines 6 2>$null) -join "`n") }
  }
  $fmt = '{0,-18} {1,-7} {2,-8} {3,-10} {4,-9} {5,-15} {6}'
  $marks = @((Get-LimitTiers) | Sort-Object { $_.Min } | ForEach-Object { "$($_.Min)% $($_.Note)" }) -join ' · '
  Write-Host "== limits crew:$slug  (mốc 5h: $marks; tuần ≥$(Get-LimitWeekWarn)% cảnh báo)"
  $warned = @()
  Write-Host ($fmt -f 'terminal', 'agent', '5h dùng', 'tuần dùng', 'mốc', 'reset 5h', 'task')
  foreach ($r in (Resolve-LimitRows $rows)) {
    $task = ($tasks | Where-Object { $_.terminal -eq $r.Name } | ForEach-Object { $_.name }) -join ','
    if (-not $task) { $task = '-' }
    if (-not $r.Live) { Write-Host ($fmt -f $r.Name, $r.Agent, '-', '-', 'tắt', '-', $task); continue }
    $i = $r.Shown
    $p5 = if ($i -and $null -ne $i.FiveHour) { "$($i.FiveHour)%" } else { '?' }
    $pw = if ($i -and $null -ne $i.Week) { "$($i.Week)%" } else { '?' }
    $lv = if ($i) { $i.Level } else { 'không rõ' }
    $reset = if ($i -and $i.FiveHourReset) { $i.FiveHourReset } else { '-' }
    $note = ''
    if (-not $r.Direct) {
      $hasNumber = $i -and ($null -ne $i.FiveHour -or $null -ne $i.Week)
      $note = if ($hasNumber) { ' (màn hình, có thể cũ)' } else { ' (không hỏi được, màn hình không có số)' }
      if ($r.From) { $note += " (theo $($r.From))" }
    }
    if ($i -and $i.WeekWarn) { $lv = "$lv ⚠"; $warned += "$($r.Name) ($($r.Agent)): tuần $pw" }
    $line = ($fmt -f $r.Name, $r.Agent, $p5, $pw, $lv, $reset, $task) + $note
    if ($i -and $i.WeekWarn) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
  }
  foreach ($w in $warned) { Write-Host "⚠ tuần ≥$(Get-LimitWeekWarn)%: $w — báo chủ dự án trước khi giao cho agent này." -ForegroundColor Yellow }
  $failed = @($liveByAgent.Keys | Where-Object { -not $liveByAgent[$_] } | Sort-Object)
  if ($failed.Count) { Write-Host "Không hỏi được số trực tiếp từ: $($failed -join ', ') (thiếu CLI, chưa đăng nhập, hoặc đổi format)." }
  Write-Host 'Số hỏi trực tiếp từ Codex/Claude, không tốn token; không hỏi được thì lấy từ màn hình, có thể cũ. Limit tính theo tài khoản: mọi pane cùng agent dùng chung số. Mốc chỉ theo 5h; tuần chỉ cảnh báo.'
  foreach ($w in $foreign) { Write-Host "crew: CẢNH BÁO: $w (hiện 'tắt', không đọc số)" -ForegroundColor Yellow }
}

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
  if (-not $Name) { Die "dùng: crew clean <tên> [-Force]" }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die "chạy trong repo của crew." }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $ids = Get-Ids (Get-CrewIdKey $root $cfg)
  $tasks = Get-Tasks $root; $t = $tasks | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $t) { Die "task $Name không có trong .crew/tasks.json — không dọn." }

  # kiểm git trước (nhánh đã xóa ở lần chạy trước thì bỏ qua)
  if ((Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$($t.branch)").Code -eq 0) {
    if ((Invoke-GitQuiet -C $root merge-base --is-ancestor $t.branch HEAD).Code -ne 0 -and -not $Force) { Die "nhánh $($t.branch) chưa merge vào HEAD. Dùng -Force nếu chắc chắn bỏ." }
  }

  if (Test-KeepTask $root $t) {
    # bản mới: agent giữ phiên, thư mục giữ nguyên; chỉ đưa worktree về nhánh chính và xóa nhánh task
    $main = Get-MainBranch $root
    try { $warn = Reset-WorkerTree $root $t $main ([bool]$Force) }
    catch { Die "$($_.Exception.Message)`n  Bản ghi task $Name vẫn giữ trong .crew/tasks.json — sửa xong chạy lại: crew clean $Name" }
  } else {
    # bản cũ (worktree riêng theo task): gỡ worktree như trước
    if (-not $Force -and (Test-Path $t.worktree) -and (Test-WorktreeListed $root $t.worktree)) {
      $st = Invoke-GitQuiet -C $t.worktree status --porcelain
      if ($st.Code -eq 0 -and $st.Text) { Die "worktree $($t.worktree) còn thay đổi chưa commit. Commit/bỏ thay đổi, hoặc dùng -Force nếu chắc chắn bỏ." }
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
    catch { Die "$($_.Exception.Message)`n  Bản ghi task $Name vẫn giữ trong .crew/tasks.json — sửa xong chạy lại: crew clean $Name" }
  }
  Save-Tasks $root @($tasks | Where-Object { $_.name -ne $Name })
  foreach ($w in $warn) { Write-Host "crew: CẢNH BÁO: $w" -ForegroundColor Yellow }
  Say "đã dọn task $Name."
}

# ---------------- send / review ----------------
# Trạng thái terminal: `hc get --json` trả status = {app; state}, `hc ls` trả chuỗi. Ra @{ App; State }.
function Get-TermStatus($info) {
  $st = if ($info) { $info.status } else { $null }
  if ($st -is [string]) { return @{ App = $null; State = $st } }
  if ($st) { return @{ App = $st.app; State = $st.state } }
  return @{ App = $null; State = $null }
}

# Hàm thuần quyết định bước gửi (không gọi hc). $info = object `hc get`; $result = object `hc send --json`
# ($null = chưa gửi); $turnBefore = turn trước khi gửi (-1 = không rõ).
# Ra: 'dead' | 'blocked' | 'send' (chưa gửi, gửi được) | 'ok' | 'press-enter'.
function Get-SendPlan($info, $result, [int]$turnBefore = -1) {
  if (-not $info -or $info.state -ne 'live') { return 'dead' }
  $st = Get-TermStatus $info
  if ($st.State -eq 'blocked') { return 'blocked' }
  if ($null -eq $result) { return 'send' }
  # shell không báo working/turn: hc send thành công là xong
  if (-not $st.App) { return 'ok' }
  if ($result.started -eq $true -or $st.State -eq 'working') { return 'ok' }
  if ($turnBefore -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turnBefore) { return 'ok' }
  return 'press-enter'
}

function Get-TermInfo([string]$term) {
  $out = & { $ErrorActionPreference = 'Continue'; hc get $term --json 2>$null }
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  try { return (@($out) -join "`n") | ConvertFrom-Json } catch { return $null }
}

# Các lệnh hc thật mà Invoke-SendFlow dùng. Test tiêm bảng giả cùng khóa (Get/Send/Keys/Read/Sleep), không gọi hc.
# Send($term, $text, $raw): $raw = gửi trần, không bọc <hc from=…>.
function New-HcOps {
  @{
    Get   = { param($term) Get-TermInfo $term }
    Send  = {
      param($term, $text, $raw)
      $saved = @{ Id = $env:HC_TERMINAL_ID; Socket = $env:HC_TERMINAL_SOCKET }
      try {
        # gửi từ pane agent thì hc bọc <hc from=…> ⇒ shell ParserError, /clear|/new thành câu chat; $raw ⇒ để trống 2 biến chỉ cho lệnh này
        if ($raw) { $env:HC_TERMINAL_ID = $null; $env:HC_TERMINAL_SOCKET = $null }
        $out = & { $ErrorActionPreference = 'Continue'; hc send $term $text --json 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
      } finally { $env:HC_TERMINAL_ID = $saved.Id; $env:HC_TERMINAL_SOCKET = $saved.Socket }
      @{ Code = $code; Text = (@($out) -join "`n").Trim() }
    }
    Keys  = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term enter 2>&1 } | Out-Null }
    Tab   = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term tab 2>&1 } | Out-Null }
    Read  = { param($term) (@(& { $ErrorActionPreference = 'Continue'; hc read $term --lines 15 2>$null }) -join "`n") }
    Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
  }
}

# Codex đang working: Enter của hc send có lúc bị nuốt, tin nằm ở ô nhập dù hc báo started:true (đo thật 2026-11-02, codex-cli 0.166).
# Hàm thuần: ô nhập có ĐÚNG và CHỈ tin vừa gửi? Chỉ bỏ qua khoảng trắng tại chỗ xuống dòng của TUI, phân biệt hoa thường.
# $bare = tin gửi trần ⇒ không chấp nhận vỏ <hc from=…>; tin thường có thể có hoặc không có vỏ (hc chỉ bọc khi gửi từ pane agent), vỏ chỉ bỏ một lớp bọc kín cả ô.
function Test-SentInput([string[]]$lines, [string]$text, [bool]$bare = $false) {
  $want = "$text".Trim()
  if (-not $want -or -not @($lines).Count) { return $false }
  $same = {
    param($part)
    $want -cmatch ('^' + (@($part -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*') + '$')
  }
  $raw = @($lines) -join "`n"
  if (& $same $raw) { return $true }
  if ($bare) { return $false }
  $m = [regex]::Match($raw, '^<hc\s+from="[^"]*">(.*)</hc>$', 'Singleline')
  $m.Success -and (& $same $m.Groups[1].Value)
}

# Ô nhập đúng và chỉ có tin vừa gửi (Test-SentInput) ⇒ Tab 1 lần để vào hàng đợi thật của Codex: Tab gửi cả ô, nên chữ thêm, chữ sửa, bản nháp cùng đầu tin ⇒ không bấm.
# Đọc lại màn hình + trạng thái ngay trước phím; không live, không phải Codex, hết working, blocked, hộp thoại ⇒ không bấm.
function Send-CodexQueue([string]$term, [string]$text, $ops, [bool]$bare = $false) {
  $unsure = @{ Ok = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin có thể nằm lại ô nhập, xem crew hot" }
  if (-not $ops.Read -or -not $ops.Tab) { return $unsure }
  & $ops.Sleep 700
  $screen = & $ops.Read $term
  $info = & $ops.Get $term
  $st = Get-TermStatus $info
  if (-not $info -or $info.state -ne 'live' -or $st.App -ne 'codex' -or $st.State -ne 'working' -or (Get-ScreenDialog $screen)) { return $unsure }
  $box = Get-InputBox $screen
  if (-not $box -or $box.Kind -ne 'codex') { return $unsure }
  if (-not $box.Text) { return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: Codex đang bận đã nhận tin khỏi ô nhập (xem: crew hot)" } }
  if (-not (Test-SentInput $box.Lines $text $bare)) { return $unsure }
  & $ops.Tab $term
  for ($i = 0; $i -lt 3; $i++) {
    & $ops.Sleep 500
    $after = Get-InputBox (& $ops.Read $term)
    if ($after -and $after.Kind -eq 'codex' -and -not $after.Text) {
      return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: tin vào hàng đợi của Codex, chạy khi xong lượt (xem: crew hot)" }
    }
  }
  $unsure
}

# Điều phối gửi tin (không Die, không in): trả @{ Ok; Message }.
# Đọc lại hc get NGAY SAU send và NGAY TRƯỚC MỖI lần Enter; blocked/dead ⇒ dừng, không Enter (Enter có thể duyệt hộ hộp duyệt).
# $session = 'claude'|'codex' khi gửi /clear|/new: chỉ coi là xong khi Test-SessionReady (đọc màn hình qua $ops.Read);
# agent đang chạy lệnh thì chờ, không Enter. Màn hình có hộp thoại: ĐÚNG hộp chọn Codex /new ⇒ Enter 1 lần (chọn worktree
# hiện tại), hộp khác ⇒ dừng, không Enter. $tries = số vòng chờ ~2s.
# Gửi trần (không bọc <hc from>) khi: terminal là shell, tin là lệnh slash ('/…'), hoặc $raw.
function Invoke-SendFlow([string]$term, [string]$text, $ops, [string]$session = '', [int]$tries = 6, [bool]$raw = $false) {
  $fail = { param($m) @{ Ok = $false; Message = $m } }
  $info = & $ops.Get $term
  switch (Get-SendPlan $info $null) {
    'dead' { return & $fail "terminal $term không live (hc get không thấy hoặc đã tắt)." }
    'blocked' { return & $fail "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." }
  }
  $st0 = Get-TermStatus $info
  $bare = $raw -or (-not $st0.App) -or $text.StartsWith('/')
  # agent đang chạy lượt TRƯỚC khi gửi (tin thường): tin nằm chờ trong ô nhập, agent đọc khi xong lượt ⇒ báo rõ, không Enter thêm
  $busy = (-not $session) -and $st0.App -and $st0.State -eq 'working'
  $turn = if ($null -ne $info.turn) { [int]$info.turn } else { -1 }
  $r = & $ops.Send $term $text $bare
  if ($r.Code -ne 0) { return & $fail "hc send tới $term thất bại: $($r.Text)" }
  $result = try { $r.Text | ConvertFrom-Json } catch { [pscustomobject]@{ started = $null } }
  $verdict = {
    param($plan, $info)
    switch ($plan) {
      'ok' {
        $s = Get-TermStatus $info
        # chỉ còn chờ khi vẫn working cùng lượt và chưa bấm Enter; turn tăng/đã Enter/hết working ⇒ agent đã nhận hoặc rảnh, báo như cũ
        $newTurn = $turn -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turn
        if ($busy -and $s.State -eq 'working' -and $enter -eq 0 -and -not $newTurn) {
          if ($s.App -eq 'codex') { return Send-CodexQueue $term $text $ops $bare }
          return @{ Ok = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin nằm chờ, agent đọc khi xong lượt (xem: crew hot)" }
        }
        return @{ Ok = $true; Message = "đã gửi -> $term ($(if ($s.App) { $s.State } else { 'shell' }))" }
      }
      'dead' { return & $fail "terminal $term tắt sau khi gửi." }
      'blocked' { return & $fail "đã gửi tới $term nhưng nó đang chờ duyệt — chủ dự án xử lý (không bấm Enter)." }
      'dialog' { return & $fail "$term đang hiện một hộp thoại lạ sau '$text' — không bấm phím; xem: hc read $term --lines 20" }
    }
    $null
  }
  # kế hoạch sau gửi; chế độ phiên mới: 'ok' chỉ khi phiên mới sẵn sàng, agent đang chạy ⇒ 'wait' (không Enter);
  # màn hình đọc lại mỗi lần, hộp thoại xét TRƯỚC mọi kiểm sẵn sàng: hộp lạ ⇒ 'dialog' (dừng, 0 Enter);
  # hộp chọn Codex /new ⇒ 'pick' (1 lần, sau đó 'wait'). Tin thường: chỉ đọc màn hình ngay trước Enter (có $ops.Read).
  $picked = 0
  $judge = {
    param($info)
    $plan = Get-SendPlan $info $result $turn
    if (-not $session) {
      if ($plan -eq 'press-enter' -and $ops.Read -and (Get-ScreenDialog (& $ops.Read $term))) { return 'dialog' }
      return $plan
    }
    if ($plan -notin 'ok', 'press-enter') { return $plan }
    $screen = & $ops.Read $term
    $dlg = Get-ScreenDialog $screen
    if ($dlg -eq 'codex-new' -and $session -eq 'codex') { if ($picked -ge 1) { return 'wait' } return 'pick' }
    if ($dlg) { return 'dialog' }
    if (Test-SessionReady $session $info $screen) { return 'ok' }
    if ($result.started -eq $true -or (Get-TermStatus $info).State -eq 'working') { return 'wait' }
    'press-enter'
  }
  # tin kẹt ở ô nhập ⇒ Enter (tối đa 2 lần); tổng ≤ ~15s (mặc định 6 vòng)
  $enter = 0
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -eq 'wait' -or ($plan -eq 'press-enter' -and $enter -ge 2)) { continue }
    $want = $plan
    & $ops.Sleep 700
    # đọc lại trạng thái + màn hình NGAY TRƯỚC phím: vẫn đúng kế hoạch cũ mới bấm
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -ne $want) { continue }
    & $ops.Keys $term
    if ($plan -eq 'pick') { $picked++; continue }
    $enter++
    $result = [pscustomobject]@{ started = $false }
  }
  if ($session) {
    $what = if ($session -eq 'codex') { "phiên mới ('Context 100% left')" } else { "màn hình đã xóa ('❯ /clear' rồi ô nhập trống)" }
    return & $fail "chưa xác nhận được $what sau '$text' tới $term (~$(2 * $tries)s); xem: hc read $term --lines 20"
  }
  & $fail "đã gửi tới $term nhưng agent chưa chạy (vẫn $((Get-TermStatus $info).State)); xem: hc read $term --lines 20"
}

# Gửi tin tới terminal, dùng chung cho crew send/review. Lỗi ⇒ Die (exit 1). Agent bận ⇒ in báo tin nằm chờ (exit 0).
# $root khác rỗng ⇒ terminal live phải thuộc project đó (Get-ForeignTermError), sai chủ ⇒ Die trước khi gửi.
# $ops: bảng hc (test tiêm bảng giả); $null ⇒ New-HcOps.
function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false, [string]$root = '', $ops = $null) {
  if (-not $ops) { $ops = New-HcOps }
  if ($root) {
    $why = Get-ForeignTermError $term (& $ops.Get $term) $root
    if ($why) { Die "$why Không gửi." }
  }
  # tin cũ còn ở ô nhập: gửi nữa sẽ dính vào nó, Enter sẽ gửi cả hai ⇒ để người quyết
  $st = Get-TermStatus (& $ops.Get $term)
  if ($ops.Read -and $st.App -eq 'codex' -and $st.State -in 'idle', 'done') {
    $stuck = Get-StuckText $st.App $st.State (& $ops.Read $term)
    if ($stuck) {
      $shown = if ($stuck.Length -gt 200) { $stuck.Substring(0, 200) + '…' } else { $stuck }
      Die "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại."
    }
  }
  $r = Invoke-SendFlow $term $text $ops '' 6 $raw
  if (-not $r.Ok) { Die $r.Message }
  Say $r.Message
}

function Invoke-Send {
  if (-not $Name -or -not $PromptFile) { Die 'dùng: crew send <terminal> "<tin>" [-Raw]' }
  # gọi trong repo crew và terminal mang tên crew này ⇒ kiểm chủ; tên khác / ngoài repo ⇒ gửi như cũ
  $root = Get-MainRoot (Get-Location).Path
  $guard = ''
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    if ($Name -like "$(Get-CrewName $root (Get-Config $root))-*") { $guard = $root }
    if ($guard) { try { $mv = Get-MoveInfo $root (Get-Config $root) } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint } }
  }
  Send-CrewMessage $Name $PromptFile $Raw.IsPresent $guard
}

# Repo chính, kể cả khi gọi từ trong worktree: thư mục cha của git common dir.
function Get-MainRoot([string]$p) {
  $r = Invoke-GitQuiet -C $p rev-parse --path-format=absolute --git-common-dir
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  return (Resolve-Path (Split-Path $r.Text -Parent)).Path
}

# Mức review (chữ Việt) của task: review của task > dòng đầu HOT > config.review > Gọn.
function Get-ReviewLevel($task, [string]$hotText, [string]$cfgReview) {
  $vi = @{ fast = 'Nhanh'; lean = 'Gọn'; full = 'Đủ' }
  if ($task -and $task.review -and $vi.ContainsKey([string]$task.review)) { return $vi[[string]$task.review] }
  if ($hotText -match 'Chế độ review: \*\*(Gọn|Nhanh|Đủ)\*\*') { return $Matches[1] }
  if ($cfgReview -and $vi.ContainsKey($cfgReview)) { return $vi[$cfgReview] }
  return 'Gọn'
}

# Hàm thuần soạn tin giao Rev. $items: mảng @{ Name; Branch; Commits } theo thứ tự merge.
function Format-ReviewMessage([string]$level, $items) {
  $items = @($items)
  $merge = ($items | ForEach-Object { "$($_.Branch) ($(@($_.Commits) -join ','))" }) -join ' rồi '
  $notes = ($items | ForEach-Object { "context/tasks/$($_.Name).md" }) -join ', '
  $clean = ($items | ForEach-Object { "crew clean $($_.Name)" }) -join ', '
  $multi = $items.Count -gt 1
  $order = if ($multi) { ' (đúng thứ tự này)' } else { '' }
  $each = if ($multi) { ' của từng task' } else { '' }
  "Rev ${level}: merge $merge$order. Đọc $notes$each. Full test, $clean, báo planner. Không push."
}

function Invoke-Review {
  $names = @($NameList)
  if (-not $names.Count) { Die 'dùng: crew review <task>[,<task2>…] [-DryRun]' }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die 'chạy trong repo của crew.' }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $main = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
  if (-not $main) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD)." }
  $sel = @(foreach ($n in $names) {
    $t = $tasks | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $t) { Die "task $n không có trong .crew/tasks.json." }
    $t
  })
  $rl = Get-ReviewLine $root $main $sel $cfg.review
  if ($rl.Error) { Die $rl.Error }
  if ($DryRun) { Write-Host $rl.Msg; return }
  Send-CrewMessage "$slug-rev" $rl.Msg $false $root
  # gửi được ⇒ đánh dấu chờ review (crew repair giao lại khi Rev bị đóng giữa chừng); +i ms giữ thứ tự gửi
  $now = [DateTime]::UtcNow
  for ($i = 0; $i -lt $sel.Count; $i++) {
    $sel[$i] | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $now.AddMilliseconds($i).ToString('o') -Force
  }
  Save-Tasks $root $tasks
}

# Chuẩn hóa tên: PowerShell biến `a,b` / `a, b` thành mảng, Git Bash truyền chuỗi "a,b" ⇒ nối bằng ',' rồi tách, trim, bỏ rỗng.
function Get-NameArg($value) {
  @((@($value) -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$NameList = @(Get-NameArg $Name)
# review không dùng PromptFile: Git Bash `crew review a, b` tách thành "a," + "b" ⇒ gộp lại.
if ($Command -eq 'review' -and $PromptFile) { $NameList = @($NameList) + @(Get-NameArg $PromptFile) }
if ($Command -ne 'review' -and $NameList.Count -gt 1) { Die "crew $Command chỉ nhận một tên, nhận $($NameList.Count): $($NameList -join ', ')." }
# Các lệnh 1 tên dùng $Name là chuỗi (kể cả -Name sang check.ps1): bỏ ràng buộc [string[]] của param.
Remove-Variable -Name Name
$Name = if ($NameList.Count) { [string]$NameList[0] } else { '' }

if ($All -and $Command -ne 'up') { Die "-All chỉ dùng với crew up (crew up -All [-DryRun]), không dùng với crew $Command." }
if ($Command -eq 'up' -and $Restart -and $All) { Die '-All không đi với -Restart: -Restart bật lại terminal của một project.' }
if ($Command -eq 'up' -and $Restart -and $DryRun) { Die '-DryRun không đi với -Restart: -Restart luôn tắt và bật lại terminal.' }

switch ($Command) {
  'setup' { & (Join-Path $PSScriptRoot 'setup.ps1'); exit $LASTEXITCODE }
  'doctor' { Invoke-Doctor }
  'init' { Invoke-Init; Say 'xong. Bật đội: crew up' }
  'upgrade' { Invoke-Upgrade }
  'up' { if ($All) { Invoke-UpAll } elseif ($Restart) { Invoke-Up } else { Invoke-Recover $true } }
  'task' { Invoke-Task }
  'status' { Invoke-Hot }
  'hot' { Invoke-Hot }
  'limits' { Invoke-Limits }
  'clean' { Invoke-Clean }
  'send' { Invoke-Send }
  'review' { Invoke-Review }
  'check' { & (Join-Path $PSScriptRoot 'check.ps1') -Name $Name -Path $Path; exit $LASTEXITCODE }
  'selfcheck' { & (Join-Path $PSScriptRoot 'selfcheck.ps1'); exit $LASTEXITCODE }
  'repair' { Invoke-Recover $false }
  'self-pane-run' { Invoke-SelfPaneRun }
  'self-pane-work' { Invoke-SelfPaneWork }
  default {
    # 'help' và lệnh lạ ⇒ scripts/help.ps1 (-Topic = tên đầu tiên hoặc rỗng)
    $helpScript = Join-Path $PSScriptRoot 'help.ps1'
    if (-not (Test-Path -LiteralPath $helpScript)) {
      # chưa có help.ps1 ⇒ in tham chiếu ngắn ở khối đầu file
      Write-Host "crew: chưa có $helpScript — tham chiếu ngắn:"
      @(Get-Content $PSCommandPath -Encoding utf8 | Select-Object -Skip 1 | ForEach-Object -Begin { $on = $true } -Process { if ($_ -eq '#>') { $on = $false }; if ($on) { $_ } }) -join "`n" | Write-Host
      exit 0
    }
    & $helpScript -Topic $Name; exit $LASTEXITCODE
  }
}
