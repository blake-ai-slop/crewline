<#
crew (Crewline) - dựng và điều khiển "đội agent" trong herdr-app + hc (Windows).

  crew doctor                               kiểm môi trường: herdr, hc, agent, git identity
  crew init  [-Path .] [-Team standard|solo|large] [-Review lean|fast|full] [-Access work|wide] [-GitInit] [-NoCommit]
  crew upgrade [-Path .] [-DryRun] [-NoCommit] [-Force] cập nhật skeleton context
  crew up    [-Path .] [-Restart w1|…|planner|rev|all] [-Force]  dựng space/tab/agent theo .crew/config.json; worker chạy sẵn agent trong worktree cố định .crew/worktrees/w<N>; -Restart kill + bật lại đúng terminal đó theo config hiện tại (đổi agent/quyền), worker đang có task cần -Force
  crew task  <tên> <file-prompt> [-Worker N] [-Review lean|fast|full] worker rảnh: nhánh crew/<tên> từ nhánh chính trong w<N> (phải sạch), chép prompt, /clear (Claude) hoặc /new (Codex) rồi giao việc; đổi model = /model trong pane, giữ qua task
  crew hot   [-Path .]                      worktree, terminal, task đang chạy
  crew limits [-Path .]                     đọc 1 lần % limit 5h/tuần từ màn hình từng terminal (mốc ok/theo dõi/hạn chế/dừng)
  crew clean <tên> [-Force]                 w<N> về detached nhánh chính, xóa nhánh crew/<tên> + bản ghi; không kill agent, không xóa thư mục (task kiểu cũ .crew/worktrees/<tên>: gỡ worktree như trước)
  crew send <terminal> "<tin>" [-Raw]       gửi tin; tin kẹt ở ô nhập thì tự Enter; shell, lệnh /… và -Raw gửi trần (không bọc <hc from>)
  crew review <task>[,<task2>…] [-DryRun]  soạn 1 dòng giao Rev merge các task theo thứ tự, gửi tới <slug>-rev
  crew check <task>                         đối chiếu diff với "Được sửa", parse, test phần đó
  crew selfcheck                            cài thử vào HOME giả + PS 5.1 + init/upgrade trước khi push
  crew repair [-DryRun]  chẩn đoán + sửa an toàn sau khi lỡ xóa pane/agent, giao lại task dở
  crew setup   chọn đội mặc định (agent, số worker, Rev, review, quyền)
  crew help [lệnh]                          mọi lệnh theo nhóm (scripts/help.ps1)
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
  [switch]$Raw
)

# Chốt chặn: crew cần pwsh 7. Gọi bằng Windows PowerShell 5.1 (powershell.exe) thì chạy lại chính file này bằng pwsh.
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

function Get-Slug([string]$root) {
  $s = (Split-Path $root -Leaf).ToLower() -replace '[^a-z0-9]+', '-'
  $s = $s.Trim('-')
  if ($s.Length -gt 12) { $s = $s.Substring(0, 12).TrimEnd('-') }
  return $s
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

# dòng lệnh bật agent dùng chung cho planner, worker, Rev; cờ quyền theo access (codex đã có --no-daemon trong Get-Flags)
function Get-AgentCommand([string]$kind, [string]$access, [string]$line) {
  $exe = if ($kind -eq 'codex') { 'codex' } else { 'claude' }
  "$exe $(Get-Flags $kind $access) $(Quote $line)"
}

function Get-LiveTerminals {
  $j = hc ls --json | ConvertFrom-Json
  return @($j.terminals)
}

function Get-Ids([string]$slug) {
  $k = $slug -replace '-', ''
  return @{ Space = "spcrew$k"; Planner = "tbcrew${k}planner"; Rev = "tbcrew${k}rev"; Workers = { param($n) "tbcrew${k}workers$n" }.GetNewClosure() }
}

# Chạy một chương trình trong pwsh (giữ shell khi chương trình thoát) thành terminal hc có tên, gắn vào tab herdr.
function Start-Term([string]$name, [string]$cwd, [string]$space, [string]$tab, [string]$cmdline) {
  $argv = @('run', '--bg', '--json', '--name', $name, '--keep', '--outlive-parent', '--no-parent', '--no-notify',
    '--cwd', $cwd, '--label', "herdr.space=$space", '--label', "herdr.tab=$tab", '--', 'pwsh', '-NoLogo')
  if ($cmdline) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmdline))
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
  [IO.Path]::GetFullPath((Join-Path $root ".crew\worktrees\w$n"))
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
function Start-WorkerTerm([string]$root, $cfg, $ids, [string]$slug, [int]$n, [string]$main) {
  $kind = @($cfg.workers)[$n - 1]
  $wt = Initialize-WorkerTree $root $n $main
  $tab = & $ids.Workers ([math]::Ceiling($n / 2))
  Start-Term "$slug-w$n" $wt $ids.Space $tab (Get-AgentCommand $kind $cfg.access (Get-WorkerStartLine $n))
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
  $tdir = Join-Path $env:APPDATA 'herdr-core/templates'
  $tpl = @(Get-ChildItem $tdir -Filter 'crew-*.md' -ErrorAction SilentlyContinue).Count
  Check "template hc ($tpl trong $tdir)" ($tpl -ge 4) 'chạy install.ps1'
  Check "khung context ($Skeleton)" (Test-Path (Join-Path $Skeleton 'context/roles/planner.md')) 'repo Crewline thiếu skeleton/'
  if (Get-Command hc -ErrorAction SilentlyContinue) {
    & { $ErrorActionPreference = 'Continue'; hc server status *> $null }
    Check 'herdr-core đang chạy' ($LASTEXITCODE -eq 0) 'mở herdr-app'
  }
  Write-Host "Nhắc: agent phải đã đăng nhập, crew không tự đăng nhập: $(($need | ForEach-Object { "$_ ($(Get-AgentLogin $_))" }) -join ', ')."
  if ($script:bad) { exit 1 }
}

# ---------------- init ----------------
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
    Say "tạo commit đầu với các file đang có."
    Invoke-GitOrDie 'git add' -C $root add -A | Out-Null
    Invoke-GitOrDie 'commit đầu' -C $root commit -q --allow-empty -m 'chore: initial commit' | Out-Null
    $hasHead = $true
  }

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
  $cfg = [ordered]@{ planner = $t.planner; workers = @($t.workers); rev = $t.rev; review = $rv; access = $Access }
  $cfg | ConvertTo-Json | Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
  Say "ghi .crew/config.json: $(($cfg | ConvertTo-Json -Compress))"

  if ($NoCommit) { Say "bỏ qua commit (-NoCommit)."; return }
  Invoke-GitQuiet -C $root add context CLAUDE.md AGENTS.md .gitignore | Out-Null
  if ((Invoke-GitQuiet -C $root diff --cached --quiet).Code -eq 0) { Say "không có gì mới để commit."; return }
  Invoke-GitOrDie 'commit khung context' -C $root commit -q -m 'chore: crew context skeleton' | Out-Null
  Say "commit: $(git -C $root log -1 --format='%h %s')"
}

# ---------------- upgrade ----------------
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
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-Slug $root; $ids = Get-Ids $slug
  $main = Get-MainBranch $root
  $liveTerms = @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' })
  $live = @($liveTerms | ForEach-Object { $_.name })
  $made = @()

  # -Restart: kill đúng terminal đó (đã chạy thì) rồi để vòng dưới bật lại theo config hiện tại
  if ($Restart) {
    try { $targets = Get-RestartTargets $Restart @($cfg.workers).Count ($cfg.planner -ne 'none') ($cfg.rev -ne 'none') } catch { Die $_.Exception.Message }
    $tasks = Get-Tasks $root
    foreach ($tg in $targets) {
      if ($tg -notlike 'w*' -or $Force) { continue }
      $busy = @($tasks | Where-Object { "w$([int]$_.worker)" -eq $tg } | ForEach-Object { $_.name })
      if ($busy.Count) { Die "$tg đang có task $($busy -join ', ') — bật lại sẽ mất phiên đang làm. Đợi xong + crew clean, hoặc thêm -Force nếu chắc chắn." }
    }
    foreach ($tg in $targets) {
      $n = "$slug-$tg"
      $term = $liveTerms | Where-Object { $_.name -eq $n } | Select-Object -First 1
      if ($term) { Say "dừng $n ($($term.address)) để bật lại."; Stop-Term $term.address }
      $live = @($live | Where-Object { $_ -ne $n })
    }
  }

  if ($cfg.planner -ne 'none') {
    $n = "$slug-planner"
    if ($live -contains $n) { Say "$n đã chạy, bỏ qua." } else {
      $line = 'Bạn là planner của crew này. Đọc context/README.md rồi context/roles/planner.md; làm đúng vai trò đó và chờ chủ dự án giao việc.'
      $r = Start-Term $n $root $ids.Space $ids.Planner (Get-AgentCommand $cfg.planner $cfg.access $line); $made += "$n=$($r.address)"
    }
  }
  $wi = 0
  foreach ($kind in $cfg.workers) {
    $wi++; $n = "$slug-w$wi"
    $wt = Initialize-WorkerTree $root $wi $main
    if ($live -contains $n) { Say "$n đã chạy, bỏ qua."; continue }
    $r = Start-WorkerTerm $root $cfg $ids $slug $wi $main; $made += "$n=$($r.address) ($kind trong $wt)"
  }
  if ($cfg.rev -ne 'none') {
    $n = "$slug-rev"
    if ($live -contains $n) { Say "$n đã chạy, bỏ qua." } else {
      $line = 'Bạn là rev của crew này. Đọc context/README.md rồi context/roles/rev.md; làm đúng vai trò đó và chờ planner giao việc.'
      $r = Start-Term $n $root $ids.Space $ids.Rev (Get-AgentCommand $cfg.rev $cfg.access $line); $made += "$n=$($r.address)"
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
  Say "space 'crew:$slug' sẵn sàng. Agent hỏi trust thư mục? Claude: 'hc keys <tên> down enter', Codex: 'hc keys <tên> enter'."
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

# Hàm thuần: màn hình đang có hộp thoại? 'codex-new' = ĐÚNG hộp chọn của Codex /new với dòng 1 đang chọn (an toàn để Enter);
# 'other' = hộp khác (duyệt lệnh/quyền, trust, …) — không bao giờ bấm; '' = không thấy hộp.
# Hộp lạ thắng: chỉ trả 'codex-new' khi bỏ các dòng của hộp chọn đi, phần còn lại KHÔNG còn dấu hiệu hộp nào.
function Get-ScreenDialog([string]$screen) {
  $marks = 'Where should the new conversation run', 'Do you want to', 'Allow command', '(?m)^\s*Allow\b', '\(y/n\)', 'enter select',
    'esc back', 'Esc to cancel', '(?m)^\s*[›❯]\s*\d+\.\s', 'Yes, proceed'
  $hasMark = { param($t) foreach ($m in $marks) { if ($t -match $m) { return $true } } $false }
  $s = "$screen"
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
  "Bạn là worker. Đọc context/roles/worker.md, rồi làm đúng file $wt\.crew\prompt.md. Thư mục làm việc: $wt (nhánh $branch); mọi lệnh chạy trong thư mục này."
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
  $m = Get-WorkerMode (& $ops.Get $term) $kind
  switch ($m.Mode) {
    'dead' { throw "không thấy terminal $term đang chạy — chạy 'crew up' trước." }
    'blocked' { throw "$term đang chờ duyệt — chủ dự án xử lý trước, không giao việc." }
    'wrong' { throw "$term đang chạy $($m.App), config w$n là $kind — chạy 'crew up -Restart w$n' để bật lại đúng agent." }
  }
  $wt = Initialize-TaskBranch $root $n $main $name $promptPath
  Save-Tasks $root $tasks
  $line = Get-TaskLine $wt "crew/$name"
  if ($m.Mode -eq 'shell') { Say "bật $kind trong $term" } else { Say "phiên mới cho $kind trong $term" }
  $r = Send-WorkerTask $term $kind $m.Mode $wt $line $access $ops
  @{ Ok = $r.Ok; Message = $r.Message; Line = $line }
}

function Invoke-Task {
  if (-not $Name -or -not $PromptFile) { Die "dùng: crew task <tên> <file-prompt> [-Worker N]" }
  if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') { Die "tên task chỉ gồm a-z 0-9 -, tối đa 31 ký tự." }
  if (-not (Test-Path $PromptFile)) { Die "không thấy file prompt $PromptFile" }
  $promptPath = (Resolve-Path $PromptFile).Path
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die "chạy trong repo của crew." }
  $cfg = Get-Config $root; $slug = Get-Slug $root; $tasks = Get-Tasks $root
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
function Invoke-Hot {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-Slug $root
  Write-Host "== crew:$slug  review=$($cfg.review) access=$($cfg.access) planner=$($cfg.planner) workers=$($cfg.workers -join ',') rev=$($cfg.rev)"
  Write-Host "== git worktree list"; git -C $root worktree list
  Write-Host "== terminal"
  Get-LiveTerminals | Where-Object { $_.name -like "$slug-*" } |
    ForEach-Object { "{0,-18} {1,-5} {2,-9} {3}" -f $_.name, $_.address, $(if ($_.status) { $_.status } else { '-' }), $_.agent } | Write-Host
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
    foreach ($t in $tasks) {
      $ahead = (Invoke-GitQuiet -C $root rev-list --count "HEAD..$($t.branch)").Text
      $rv = if ($t.review) { " review=$($t.review)" } else { '' }
      ("{0,-20} w{1} {2,-6} {3} (+{4} commit) {5}" -f $t.name, $t.worker, $t.agent, $t.branch, $ahead, $t.worktree) + $rv | Write-Host
    }
  }
}

# ---------------- repair ----------------
# Metadata worktree từ `git worktree list --porcelain`: đường dẫn chuẩn hóa -> @{ Branch; Prunable }.
function Get-WorktreeMeta([string]$root) {
  $norm = { param($p) [IO.Path]::GetFullPath(($p -replace '/', '\')).TrimEnd('\') }
  $map = @{}; $cur = $null
  foreach ($l in @((Invoke-GitQuiet -C $root worktree list --porcelain).Text -split '\r?\n')) {
    if ($l -like 'worktree *') { $cur = @{ Branch = ''; Prunable = $false }; $map[(& $norm $l.Substring(9))] = $cur }
    elseif ($cur -and $l -like 'branch *') { $cur.Branch = $l.Substring(7) -replace '^refs/heads/', '' }
    elseif ($cur -and $l -like 'prunable*') { $cur.Prunable = $true }
  }
  $map
}

function Get-ResumeLine([string]$name, [string]$wt, [string]$branch) {
  "Bạn là worker. Tiếp tục task $name (bị gián đoạn): đọc context/roles/worker.md, file $wt\.crew\prompt.md, context/tasks/$name.md nếu có, xem git log và git status; làm tiếp phần còn lại. Thư mục làm việc: $wt (nhánh $branch)."
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
  $key = [IO.Path]::GetFullPath(($wt -replace '/', '\')).TrimEnd('\')
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
function Wait-WorkerReady([string]$term, [string]$kind, $ops, [int]$tries = 30) {
  $why = 'agent chưa sẵn sàng'
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $info = & $ops.Get $term
    $m = Get-WorkerMode $info $kind
    if ($m.Mode -eq 'blocked') { return "$term đang chờ duyệt" }
    if ($m.Mode -eq 'wrong') { return "$term đang chạy $($m.App), config là $kind" }
    if (Get-ScreenDialog (& $ops.Read $term)) { return "$term đang hiện hộp thoại" }
    if ($m.Mode -eq 'agent' -and (Get-TermStatus $info).State -ne 'working') { return '' }
    if ($m.Mode -eq 'dead') { $why = "$term không live" }
  }
  $why
}

# Lõi crew repair (không Die). $ops = bảng hc như New-HcOps + Up (bật terminal thiếu = logic crew up).
# Trả @{ Done; Human; Sent } — Human rỗng ⇒ không còn gì cần người quyết.
# Không bao giờ: xóa nhánh, bỏ thay đổi chưa commit, xóa bản ghi task, kill terminal live.
function Invoke-RepairCore([string]$root, $cfg, [string]$slug, [string]$main, [bool]$dry, $ops) {
  $done = [Collections.Generic.List[string]]::new(); $human = [Collections.Generic.List[string]]::new(); $sent = @()
  $will = { param($m) if ($dry) { $done.Add("(sẽ làm) $m") } else { $done.Add($m) } }
  $tasks = Get-Tasks $root
  $workers = @($cfg.workers)

  # --- chẩn đoán terminal ---
  $roles = @()
  if ($cfg.planner -ne 'none') { $roles += @{ Role = 'planner'; Kind = $cfg.planner } }
  for ($i = 1; $i -le $workers.Count; $i++) { $roles += @{ Role = "w$i"; Kind = $workers[$i - 1]; N = $i } }
  if ($cfg.rev -ne 'none') { $roles += @{ Role = 'rev'; Kind = $cfg.rev } }
  Write-Host "== terminal"
  foreach ($r in $roles) {
    $r.Term = "$slug-$($r.Role)"
    $r.Mode = (Get-WorkerMode (& $ops.Get $r.Term) $r.Kind).Mode
    $r.Live = $r.Mode -ne 'dead'
    $note = @{ dead = 'thiếu'; agent = 'live, đúng agent'; wrong = 'live, SAI agent'; shell = 'live, shell (agent đã thoát)'; blocked = 'live, chờ duyệt' }[$r.Mode]
    Write-Host ("{0,-20} {1,-7} {2}" -f $r.Term, $r.Kind, $note)
  }

  # --- chẩn đoán worktree ---
  $meta = Get-WorktreeMeta $root
  $trees = @{}
  Write-Host "== worktree"
  for ($i = 1; $i -le $workers.Count; $i++) {
    $s = Get-TreeState $root (Get-WorkerTree $root $i) $meta; $trees[$i] = $s
    $dirty = if ($s.DirtyCount) { "bẩn ($($s.DirtyCount)): $($s.Dirty -join ', ')$(if ($s.DirtyCount -gt 5) { ', …' })" } elseif ($s.State -eq 'có') { 'sạch' } else { '' }
    Write-Host ("{0,-4} {1,-5} {2} {3} {4}" -f "w$i", $s.State, $s.Path, $s.Branch, $dirty)
  }

  # --- chẩn đoán task ---
  Write-Host "== task"
  $info = @{}
  foreach ($t in $tasks) {
    $hasBranch = (Invoke-GitQuiet -C $root show-ref --verify --quiet "refs/heads/$($t.branch)").Code -eq 0
    $ahead = if ($hasBranch) { (Invoke-GitQuiet -C $root rev-list --count "$main..$($t.branch)").Text } else { '-' }
    $role = $roles | Where-Object { $_.N -eq [int]$t.worker } | Select-Object -First 1
    $wtb = if (Test-Path -LiteralPath $t.worktree) { (Invoke-GitQuiet -C $t.worktree branch --show-current).Text } else { '' }
    $info[$t.name] = @{ HasBranch = $hasBranch; Role = $role }
    Write-Host ("{0,-20} w{1} {2} {3} (+{4} commit) worker {5}, worktree {6}" -f $t.name, $t.worker, $t.branch,
      $(if ($hasBranch) { 'còn' } else { 'MẤT' }), $ahead, $(if ($role -and $role.Live) { 'live' } else { 'thiếu' }),
      $(if ($wtb -eq $t.branch) { 'đúng nhánh' } elseif ($wtb) { "ở $wtb" } else { 'chưa đúng nhánh' }))
    if (-not $hasBranch) { $human.Add("task $($t.name): nhánh $($t.branch) đã mất — không sửa; bỏ bản ghi bằng: crew clean $($t.name) -Force") }
  }
  if (-not $tasks.Count) { Write-Host '(không có)' }

  # --- sửa: prune + tạo lại w<N> ---
  if (@($trees.Values | Where-Object { $_.State -eq 'hỏng' }).Count -or @($meta.Values | Where-Object { $_.Prunable }).Count) {
    & $will 'git worktree prune (metadata hỏng)'
    if (-not $dry) {
      $r = Invoke-GitQuiet -C $root worktree prune
      if ($r.Code -ne 0) { $human.Add("git worktree prune lỗi: $($r.Text)") }
    }
  }
  $stray = $false
  $planned = @{}  # DryRun: w<N> -> nhánh sẽ switch sau khi tạo lại
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
    else {
      & $will "bật terminal thiếu qua crew up: $(@($dead | ForEach-Object { $_.Term }) -join ', ')"
      if ($dry) { $started = $dead }  # DryRun: coi như bật được, không gọi Up
      else {
        & $ops.Up
        foreach ($r in $dead) {
          if ((Get-WorkerMode (& $ops.Get $r.Term) $r.Kind).Mode -ne 'dead') { $started += $r } else { $human.Add("$($r.Term) vẫn chưa live sau crew up.") }
        }
      }
    }
  }

  # --- giao lại task dở (chỉ worker vừa bật lại) + việc cần người với worker live ---
  foreach ($t in $tasks) {
    $role = $info[$t.name].Role
    if (-not $role -or -not $info[$t.name].HasBranch) { continue }
    if ($role.Live) {
      switch ($role.Mode) {
        'blocked' { $human.Add("$($role.Term) (task $($t.name)) đang chờ duyệt — chủ dự án xử lý.") }
        'wrong' { $human.Add("$($role.Term) (task $($t.name)) chạy sai agent — xem tay; crew up -Restart $($role.Role) -Force sẽ mất phiên.") }
        'shell' { $human.Add("$($role.Term) (task $($t.name)) là shell (agent đã thoát) — gửi lại: crew send $($role.Term) `"$(Get-ResumeLine $t.name $t.worktree $t.branch)`"") }
      }
      continue
    }
    if ($started -notcontains $role -or -not (Test-KeepTask $root $t)) { continue }
    $chk = Get-ResumeCheck $root $t $role $(if ($dry) { [string]$planned[[int]$t.worker] } else { '' })
    if ($chk.Human) { $human.Add($chk.Human); continue }
    $line = $chk.Line
    if ($chk.Src) {
      & $will "chép lại prompt $($chk.Src) -> $($chk.Pm)"
      if (-not $dry) { New-Item -ItemType Directory -Force (Split-Path $chk.Pm) | Out-Null; Copy-Item -LiteralPath $chk.Src $chk.Pm }
    }
    if ($dry) { & $will "giao lại task $($t.name) -> $($role.Term)"; continue }
    $why = Wait-WorkerReady $role.Term $role.Kind $ops
    if ($why) { $human.Add("$why — chưa giao lại task $($t.name), không bấm phím; sau đó: crew send $($role.Term) `"$line`""); continue }
    $r = Invoke-SendFlow $role.Term $line $ops
    if ($r.Ok) { $done.Add("giao lại task $($t.name) -> $($role.Term)"); $sent += $t.name }
    else { $human.Add("giao lại task $($t.name) chưa xong: $($r.Message)") }
  }
  foreach ($r in $roles | Where-Object { $_.Live -and $_.Role -notlike 'w*' -and $_.Mode -in 'wrong', 'shell', 'blocked' }) {
    $human.Add("$($r.Term): $(@{ wrong = 'sai agent'; shell = 'agent đã thoát'; blocked = 'chờ duyệt' }[$r.Mode]) — xem tay (crew up -Restart $($r.Role) để bật lại).")
  }
  @{ Done = @($done); Human = @($human); Sent = $sent }
}

function Invoke-Repair {
  $root = Get-MainRoot (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-Slug $root; $main = Get-MainBranch $root
  $script:Path = $root  # crew up dựng theo repo chính, kể cả khi gọi từ worktree
  $ops = New-HcOps; $ops.Up = { Invoke-Up }
  $res = Invoke-RepairCore $root $cfg $slug $main ([bool]$DryRun) $ops
  Write-Host "== kết luận$(if ($DryRun) { ' (DryRun: không ghi git, không bật, không gửi)' })"
  if ($res.Done.Count) { foreach ($d in $res.Done) { Write-Host "  đã làm: $d" } } else { Write-Host '  không có gì phải sửa.' }
  foreach ($h in $res.Human) { Write-Host "  CẦN NGƯỜI QUYẾT: $h" -ForegroundColor Yellow }
  if ($res.Human.Count) { exit 1 }
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
  $vals = @($five, $week | Where-Object { $null -ne $_ })
  $level = if (-not $vals.Count) { 'không rõ' } else {
    $max = ($vals | Measure-Object -Maximum).Maximum
    Get-LimitLevel $max
  }
  return @{ FiveHour = $five; Week = $week; Level = $level }
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
      if ($src) { $row.Shown = $src.Info; $row.From = $src.Name }
    }
    $out += $row
  }
  return , $out
}

function Invoke-Limits {
  $root = Get-Root (Resolve-Path $Path).Path; if (-not $root) { Die "không phải repo git." }
  $cfg = Get-Config $root; $slug = Get-Slug $root; $tasks = Get-Tasks $root
  $rows = @()
  if ($cfg.planner -ne 'none') { $rows += @{ Name = "$slug-planner"; Agent = $cfg.planner } }
  $wi = 0
  foreach ($kind in @($cfg.workers)) { $wi++; $rows += @{ Name = "$slug-w$wi"; Agent = $kind } }
  if ($cfg.rev -ne 'none') { $rows += @{ Name = "$slug-rev"; Agent = $cfg.rev } }
  $live = @(Get-LiveTerminals | Where-Object { $_.state -eq 'live' } | ForEach-Object { $_.name })
  foreach ($r in $rows) {
    $r.Live = $live -contains $r.Name
    $r.Info = if ($r.Live) { Get-LimitInfo ((hc read $r.Name --lines 6 2>$null) -join "`n") } else { $null }
  }
  $fmt = '{0,-18} {1,-7} {2,-8} {3,-10} {4,-9} {5}'
  $marks = @((Get-LimitTiers) | Sort-Object { $_.Min } | ForEach-Object { "$($_.Min)% $($_.Note)" }) -join ' · '
  Write-Host "== limits crew:$slug  (mốc: $marks)"
  Write-Host ($fmt -f 'terminal', 'agent', '5h dùng', 'tuần dùng', 'mốc', 'task')
  foreach ($r in (Resolve-LimitRows $rows)) {
    $task = ($tasks | Where-Object { $_.terminal -eq $r.Name } | ForEach-Object { $_.name }) -join ','
    if (-not $task) { $task = '-' }
    $note = if ($r.From) { " (theo $($r.From))" } else { '' }
    if (-not $r.Live) { Write-Host ($fmt -f $r.Name, $r.Agent, '-', '-', 'tắt', $task); continue }
    $i = $r.Shown
    $p5 = if ($i -and $null -ne $i.FiveHour) { "$($i.FiveHour)%" } else { '?' }
    $pw = if ($i -and $null -ne $i.Week) { "$($i.Week)%" } else { '?' }
    $lv = if ($i) { $i.Level } else { 'không rõ' }
    Write-Host (($fmt -f $r.Name, $r.Agent, $p5, $pw, $lv, $task) + $note)
  }
  Write-Host 'Limit tính theo tài khoản: mọi pane cùng agent dùng chung số.'
}

# ---------------- clean ----------------

function Test-WorktreeListed([string]$root, [string]$wt) {
  $norm = { param($p) [IO.Path]::GetFullPath(($p -replace '/', '\')).TrimEnd('\') }
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
  $norm = { param($p) [IO.Path]::GetFullPath(($p -replace '/', '\')).TrimEnd('\') }
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
  $cfg = Get-Config $root; $slug = Get-Slug $root; $ids = Get-Ids $slug
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
    $old = [IO.Path]::GetFullPath(($t.worktree -replace '/', '\')).TrimEnd('\')
    if ($info -and $info.state -eq 'live' -and $cwd -and ([IO.Path]::GetFullPath($cwd).TrimEnd('\') + '\').StartsWith("$old\", [StringComparison]::OrdinalIgnoreCase)) {
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
    Read  = { param($term) (@(& { $ErrorActionPreference = 'Continue'; hc read $term --lines 15 2>$null }) -join "`n") }
    Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
  }
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
  $bare = $raw -or (-not (Get-TermStatus $info).App) -or $text.StartsWith('/')
  $turn = if ($null -ne $info.turn) { [int]$info.turn } else { -1 }
  $r = & $ops.Send $term $text $bare
  if ($r.Code -ne 0) { return & $fail "hc send tới $term thất bại: $($r.Text)" }
  $result = try { $r.Text | ConvertFrom-Json } catch { [pscustomobject]@{ started = $null } }
  $verdict = {
    param($plan, $info)
    switch ($plan) {
      'ok' { $s = Get-TermStatus $info; return @{ Ok = $true; Message = "đã gửi -> $term ($(if ($s.App) { $s.State } else { 'shell' }))" } }
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

# Gửi tin tới terminal, dùng chung cho crew send/review. Lỗi ⇒ Die (exit 1).
function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false) {
  $r = Invoke-SendFlow $term $text (New-HcOps) '' 6 $raw
  if (-not $r.Ok) { Die $r.Message }
  Say $r.Message
}

function Invoke-Send {
  if (-not $Name -or -not $PromptFile) { Die 'dùng: crew send <terminal> "<tin>" [-Raw]' }
  Send-CrewMessage $Name $PromptFile $Raw.IsPresent
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
  $cfg = Get-Config $root; $slug = Get-Slug $root; $tasks = Get-Tasks $root
  $main = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
  if (-not $main) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD)." }
  $hotFile = Join-Path $root 'context/HOT.md'
  $hot = if (Test-Path $hotFile) { (Get-Content $hotFile -TotalCount 1 -Encoding utf8) -join '' } else { '' }
  $items = @(); $levels = @()
  foreach ($n in $names) {
    $t = $tasks | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $t) { Die "task $n không có trong .crew/tasks.json." }
    $r = Invoke-GitQuiet -C $root log --format=%h "$main..$($t.branch)"
    if ($r.Code -ne 0) { Die "không đọc được commit của $($t.branch): $($r.Text)" }
    $commits = @($r.Text -split '\r?\n' | Where-Object { $_ })
    if (-not $commits.Count) { Die "nhánh $($t.branch) không có commit mới so với $main." }
    $items += @{ Name = $n; Branch = $t.branch; Commits = $commits }
    $levels += Get-ReviewLevel $t $hot $cfg.review
  }
  # các task khác mức ⇒ lấy mức cao nhất (Đủ > Gọn > Nhanh)
  $level = @('Đủ', 'Gọn', 'Nhanh') | Where-Object { $levels -contains $_ } | Select-Object -First 1
  $msg = Format-ReviewMessage $level $items
  if ($DryRun) { Write-Host $msg; return }
  Send-CrewMessage "$slug-rev" $msg
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

switch ($Command) {
  'setup' { & (Join-Path $PSScriptRoot 'setup.ps1'); exit $LASTEXITCODE }
  'doctor' { Invoke-Doctor }
  'init' { Invoke-Init }
  'upgrade' { Invoke-Upgrade }
  'up' { Invoke-Up }
  'task' { Invoke-Task }
  'hot' { Invoke-Hot }
  'limits' { Invoke-Limits }
  'clean' { Invoke-Clean }
  'send' { Invoke-Send }
  'review' { Invoke-Review }
  'check' { & (Join-Path $PSScriptRoot 'check.ps1') -Name $Name -Path $Path; exit $LASTEXITCODE }
  'selfcheck' { & (Join-Path $PSScriptRoot 'selfcheck.ps1'); exit $LASTEXITCODE }
  'repair' { Invoke-Repair }
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
