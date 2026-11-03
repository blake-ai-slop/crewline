# crew up gõ ngay trong pane của một vai: e2e qua crew.ps1 thật + tiến trình nền thật, hc + herdr-app giả đứng đầu PATH, HOME giả.
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Start-BreakawayProcess', 'Get-SelfPaneTimeoutSec', 'Get-SelfTerm', 'Get-SelfPaneState', 'Get-TermStatus', 'Get-TermShellState', 'Wait-SelfPaneShell', 'Test-TermOwner', 'Test-SamePath', 'ConvertTo-RootKey', 'Get-HotWarnings',
  'Invoke-GitQuiet', 'Get-CrewName', 'Get-LegacySlug', 'Test-CrewName', 'Get-CopySource', 'Get-NameOwner', 'Test-OtherAlive', 'Get-NameConflict', 'Get-IdKeyOwner', 'Get-CrewIdKey', 'Get-LegacyIdKey', 'Test-IdKey', 'Get-Root', 'Get-Config', 'Get-ForeignTermError'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Read-ProjectRegistry { @{ Ok = $true; Map = [ordered]@{} } }
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

$CoreArgv = @('pwsh.exe', '-NoExit', '-Command', '$global:__hc_prompt = $function:prompt; function global:prompt { }')

# Màn hình: tiến trình còn HC_TERMINAL_ID là crew đang chạy trong pane (đang in); tiến trình nền đã xóa biến nên thấy màn hình sau khi crew thoát.
$FakeHc = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
Add-Content -LiteralPath (Join-Path $dir 'hc.log') -Value ($args -join ' ') -Encoding utf8
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
# Có file hang-<lệnh>.txt: tiến trình nền gọi lệnh đó thì treo, kèm một tiến trình cháu thật để kiểm không sót.
if (-not $env:HC_TERMINAL_ID -and (Test-Path -LiteralPath (Join-Path $dir "hang-$($args[0]).txt"))) {
  $child = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -PassThru -NoNewWindow
  Set-Content -LiteralPath (Join-Path $dir 'hang.pid') -Value $child.Id
  $child.WaitForExit()
}
switch ($args[0]) {
  'ls' { ConvertTo-Json -InputObject ([ordered]@{ terminals = @($terms) }) -Depth 6; exit 0 }
  'get' {
    $key = $args[1]
    $t = $terms | Where-Object { $_.name -eq $key -or $_.address -eq $key } | Select-Object -First 1
    if (-not $t) { exit 1 }
    $t | ConvertTo-Json -Depth 6; exit 0
  }
  'kill' {
    $key = $args[1]
    ConvertTo-Json -InputObject @($terms | Where-Object { $_.address -ne $key }) -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
    exit 0
  }
  'send' { '{"started":true}'; exit 0 }
  'read' {
    $name = if ($env:HC_TERMINAL_ID) { 'screen-running.txt' } else { 'screen-after.txt' }
    $screen = Join-Path $dir $name
    if (Test-Path -LiteralPath $screen) { Get-Content -LiteralPath $screen -Raw -Encoding utf8 }
    exit 0
  }
  'run' {
    $name = ''; $cwd = ''; $space = ''; $tab = ''
    for ($i = 1; $i -lt $args.Count; $i++) {
      if ($args[$i] -eq '--name') { $name = $args[$i + 1] }
      if ($args[$i] -eq '--cwd') { $cwd = $args[$i + 1] }
      if ($args[$i] -eq '--label' -and $args[$i + 1] -like 'herdr.space=*') { $space = $args[$i + 1].Substring(12) }
      if ($args[$i] -eq '--label' -and $args[$i + 1] -like 'herdr.tab=*') { $tab = $args[$i + 1].Substring(10) }
    }
    $n = [int](Get-Content -LiteralPath (Join-Path $dir 'next.txt') -ErrorAction Ignore) + 1
    Set-Content -LiteralPath (Join-Path $dir 'next.txt') -Value $n
    $addr = "t$($n + 100)"
    $terms += [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' }; argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x') }
    ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
    [pscustomobject]@{ address = $addr; name = $name } | ConvertTo-Json; exit 0
  }
  default { exit 0 }
}
'@
$FakeHerdr = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
Add-Content -LiteralPath (Join-Path $dir 'herdr.log') -Value ($args -join ' ') -Encoding utf8
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
if ($args[0] -eq 'do' -and $args[1] -eq 'pane.focus') { Set-Content -LiteralPath (Join-Path $dir 'focus.txt') -Value $args[3]; exit 0 }
if ($args[0] -eq 'do' -and $args[1] -eq 'pane.swap') {
  $focus = (Get-Content -LiteralPath (Join-Path $dir 'focus.txt')).Trim()
  $i = [array]::FindIndex([object[]]$terms, [Predicate[object]] { param($t) $t.address -eq $focus })
  $me = $terms[$i]
  for ($j = $i - 1; $j -ge 0; $j--) { if ($terms[$j].tab -eq $me.tab) { $terms[$i] = $terms[$j]; $terms[$j] = $me; break } }
  ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
  exit 0
}
if ($args[0] -ne 'ls') { exit 0 }
$spaces = @($terms | Where-Object { $_.space } | Group-Object space | ForEach-Object {
    [ordered]@{ id = $_.Name; tabs = @($_.Group | Group-Object tab | ForEach-Object {
          [ordered]@{ id = $_.Name; terminals = @($_.Group | ForEach-Object { [ordered]@{ terminal = $_.address; name = $_.name } }) } }) } })
ConvertTo-Json -InputObject ([ordered]@{ spaces = $spaces }) -Depth 8; exit 0
'@

function New-Ctx([string]$self) {
  $h = New-CrewTestHome
  $bin = Join-Path $TestDrive "bin-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  $state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr))) {
    $text = $pair[1] -replace "`r`n", "`n"
    $file = Join-Path $bin $(if ($OnWindows) { "$($pair[0]).ps1" } else { $pair[0] })
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($false))
    if (-not $OnWindows) { & chmod +x $file }
  }
  $path = "$bin$([IO.Path]::PathSeparator)$env:PATH"
  $saved = $env:PATH
  try {
    $env:PATH = $path
    foreach ($c in 'hc', 'herdr-app') {
      if (-not (Get-Command $c -ErrorAction Stop | Select-Object -First 1).Source.StartsWith($bin)) { throw "PATH test trỏ tới $c thật" }
    }
  } finally { $env:PATH = $saved }
  [IO.File]::WriteAllText((Join-Path $state 'screen-running.txt'), 'crew: đang chạy')
  [IO.File]::WriteAllText((Join-Path $state 'screen-after.txt'), 'PS C:\x>')
  @{ Home = $h; State = $state; Env = @{ PATH = $path; FAKE_HC_DIR = $state; HC_SESSION = "crew-test-$([guid]::NewGuid().ToString('N'))"; HC_TERMINAL_ID = $self; HC_TERMINAL_SOCKET = $null; CREWLINE_UP_ALL_CHILD = $null } }
}
function New-Repo([string]$name, [string]$planner = 'claude', [string[]]$workers = @('claude'), [string]$rev = 'none') {
  $root = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6))/$name"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path -LiteralPath $root).Path
  git -C $root init -q -b main
  git -C $root config core.autocrlf false
  '.crew/' | Set-Content -LiteralPath (Join-Path $root '.gitignore')
  git -C $root add -A
  git -C $root -c user.name=t -c user.email=t@t commit -q -m init
  [ordered]@{ name = $name; idKey = $name; planner = $planner; workers = $workers; rev = $rev; review = 'lean'; access = 'work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.crew/config.json') -Encoding utf8
  $root
}
function Set-Reg($ctx, $entries) {
  $o = [ordered]@{}
  foreach ($e in $entries) { $o[$e[0]] = [ordered]@{ root = $e[1]; idKey = $e[0] } }
  $f = Join-Path $ctx.Home.Home '.crewline/projects.json'
  New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
}
function Set-Terms($ctx, $terms) { ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath (Join-Path $ctx.State 'terminals.json') -Encoding utf8 }
function New-CoreShell([string]$name, [string]$addr, [string]$cwd, [string]$space = '', [string]$tab = '') {
  [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 0; status = $null; argv = $CoreArgv }
}
function New-Agent([string]$name, [string]$addr, [string]$cwd, [string]$space = '', [string]$tab = '') {
  [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' }; argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x') }
}
function Add-Worktree([string]$root, [int]$n) { $wt = Join-Path $root ".crew/worktrees/w$n"; git -C $root worktree add -q --detach $wt main; $wt }
# Lần gọi crew gần nhất, để Wait-Background in khi hết hạn.
$LastCrew = @{ Ctx = $null; Result = $null }
function Invoke-Crew($ctx, [string[]]$arguments, [string]$cwd) {
  $r = Invoke-InTestHome -TestHome $ctx.Home -File $crewScript -Arguments $arguments -Env $ctx.Env -WorkingDirectory $cwd
  $LastCrew.Ctx = $ctx; $LastCrew.Result = $r
  $r
}
function Get-HcLog($ctx) { $f = Join-Path $ctx.State 'hc.log'; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding utf8) } else { @() } }
function Get-HerdrLog($ctx) { $f = Join-Path $ctx.State 'herdr.log'; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding utf8) } else { @() } }
function Get-Lines($ctx, [string]$re) { @(Get-HcLog $ctx | Where-Object { $_ -match $re }) }
function Get-Index($lines, [string]$re) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $re) { return $i } }; -1 }
# Đợi tiến trình nền xong: file job đã đọc xong và khóa đã nhả.
function Wait-Background([string]$root, [int]$tries = 400) {
  $job = Join-Path $root '.crew/self-pane.json'; $lock = Join-Path $root '.crew/self-pane.lock'
  for ($i = 0; $i -lt $tries; $i++) {
    if (-not (Test-Path -LiteralPath $job) -and (Test-Path -LiteralPath $lock)) {
      try { ([IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')).Dispose(); return } catch { }
    }
    Start-Sleep -Milliseconds 250
  }
  $lockState = if (-not (Test-Path -LiteralPath $lock)) { 'không có' } else { try { ([IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')).Dispose(); 'có, mở được' } catch { 'có, đang bị giữ' } }
  $procs = if ($OnWindows) { @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'self-pane-(run|work)' } | ForEach-Object { "$($_.ProcessId) $($_.CommandLine)" }) } else { @() }
  $hc = if ($LastCrew.Ctx) { @(Get-HcLog $LastCrew.Ctx | Select-Object -Last 15) -join "`n" } else { '' }
  throw (@(
      "tiến trình nền chưa xong: $root"
      "file job: $(if (Test-Path -LiteralPath $job) { 'còn' } else { 'mất' })"
      "lock: $lockState"
      "tiến trình self-pane còn chạy: $($procs.Count)"
      $procs
      "--- self-pane.log ---`n$(Get-BgLog $root)"
      "--- crew (exit $($LastCrew.Result.ExitCode)) ---`n$($LastCrew.Result.Output)"
      "--- hc.log (15 dòng cuối) ---`n$hc"
    ) -join "`n")
}
function Get-BgLog([string]$root) { $f = Join-Path $root '.crew/self-pane.log'; if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -Encoding utf8 } else { '' } }
function Get-Snapshot([string[]]$dirs) {
  @(foreach ($d in $dirs) {
      Get-ChildItem -LiteralPath $d -Recurse -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName } else { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName).Hash)" }
      }
    }) -join "`n"
}

# Dò thật bằng chính Start-BreakawayProcess. Chỉ nhận "bị cấm" khi lỗi 5 VÀ tiến trình nằm trong job; lỗi khác thì e2e vẫn chạy và đỏ thật.
function Get-BreakawayBlock {
  try { Start-BreakawayProcess $env:ComSpec "`"$env:ComSpec`" /c exit 0" ([IO.Path]::GetTempPath()); return '' }
  catch {
    $why = $_.Exception.Message
    if ($why -notmatch ' 5$') { return '' }
    if (-not ('Crew.JobProbe' -as [type])) {
      Add-Type -Namespace Crew -Name JobProbe -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessInJob(System.IntPtr process, System.IntPtr job, out bool result);'
    }
    $inJob = $false
    if ([Crew.JobProbe]::IsProcessInJob([Diagnostics.Process]::GetCurrentProcess().Handle, [IntPtr]::Zero, [ref]$inJob) -and $inJob) { return "$why, tiến trình nằm trong job cấm breakaway" }
    ''
  }
}
$BreakawayBlock = if ($OnWindows) { Get-BreakawayBlock } else { '' }
# Unix không có đường thay pane. Windows chỉ bỏ qua khi máy này thật sự cấm breakaway.
$NoBackground = (-not $OnWindows) -or [bool]$BreakawayBlock
if ($BreakawayBlock) { Write-Host "CrewSelfPane: BỎ QUA các test e2e cần tiến trình nền, máy này không tạo được: $BreakawayBlock. Đường 'không tạo được tiến trình nền' vẫn chạy thật." -ForegroundColor Yellow }

# Chạy một .ps1 trong job mới không cho breakaway: lỗi 5 thật của Windows, trên máy nào cũng tái hiện được.
$NoBreakawayWrapper = @'
$target = $args[0]; $rest = @($args | Select-Object -Skip 1)
Add-Type -Namespace Crew -Name JobWrap -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern System.IntPtr CreateJobObject(System.IntPtr attrs, string name);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AssignProcessToJobObject(System.IntPtr job, System.IntPtr process);
"@
$job = [Crew.JobWrap]::CreateJobObject([IntPtr]::Zero, $null)
if (-not [Crew.JobWrap]::AssignProcessToJobObject($job, [Diagnostics.Process]::GetCurrentProcess().Handle)) { Write-Output "wrapper: không vào được job, lỗi $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 99 }
& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $target @rest 2>&1
exit $LASTEXITCODE
'@
function Invoke-NoBreakaway($ctx, [string]$target, [string[]]$arguments, [string]$cwd) {
  $w = Join-Path $ctx.State 'no-breakaway.ps1'
  [IO.File]::WriteAllText($w, $NoBreakawayWrapper, [Text.UTF8Encoding]::new($true))
  $r = Invoke-InTestHome -TestHome $ctx.Home -File $w -Arguments (@($target) + $arguments) -Env $ctx.Env -WorkingDirectory $cwd
  $LastCrew.Ctx = $ctx; $LastCrew.Result = $r
  $r
}

$savedOutEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Describe 'Wait-Background khi hết hạn' {
  It 'lỗi có file job, lock, self-pane.log và output crew' {
    $root = Join-Path $TestDrive 'wait-diag'
    New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.crew/self-pane.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $root '.crew/self-pane.log'), 'dòng log nền')
    $LastCrew.Ctx = $null; $LastCrew.Result = @{ ExitCode = 7; Output = 'chữ của crew' }
    $msg = try { Wait-Background $root 1; '' } catch { $_.Exception.Message }
    $msg | Should Match 'file job: còn'
    $msg | Should Match 'lock: không có'
    $msg | Should Match 'dòng log nền'
    $msg | Should Match 'crew \(exit 7\)'
    $msg | Should Match 'chữ của crew'
  }
}

Describe 'Get-SelfTerm + Get-SelfPaneState' {
  $savedId = $env:HC_TERMINAL_ID
  $core = { [pscustomobject]@{ state = 'live'; status = $null; argv = $CoreArgv } }
  It 'chỉ nhận đúng địa chỉ trong $mine, phân biệt hoa thường; không có biến thì $null' {
    $terms = @([pscustomobject]@{ name = 'a-planner'; address = 't3m' }, [pscustomobject]@{ name = $null; address = 't1' })
    $env:HC_TERMINAL_ID = 't3m'
    (Get-SelfTerm $terms @('a-planner')).name | Should Be 'a-planner'
    Get-SelfTerm $terms @('a-w1') | Should BeNullOrEmpty
    $env:HC_TERMINAL_ID = 'T3M'
    Get-SelfTerm $terms @('a-planner') | Should BeNullOrEmpty
    $env:HC_TERMINAL_ID = 't1'
    Get-SelfTerm $terms @('a-planner') | Should BeNullOrEmpty
    $env:HC_TERMINAL_ID = $null
    Get-SelfTerm $terms @('a-planner') | Should BeNullOrEmpty
    $env:HC_TERMINAL_ID = $savedId
  }
  It 'shell core là lost dù màn hình đang in; EncodedCommand là exited; Unix không tự nhận' {
    Get-SelfPaneState (& $core) $true | Should Be 'lost'
    Get-SelfPaneState (& $core) $false | Should Be 'unix-shell'
    $enc = & $core; $enc.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x')
    Get-SelfPaneState $enc $true | Should Be 'exited'
  }
  It 'agent, blocked, foreground lạ, thiếu marker hoặc không rõ thì không phải shell' {
    $a = & $core; $a.status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' }
    Get-SelfPaneState $a $true | Should BeNullOrEmpty
    $b = & $core; $b.status = 'blocked'
    Get-SelfPaneState $b $true | Should BeNullOrEmpty
    $f = & $core; $f | Add-Member foreground ([pscustomobject]@{ argv = @('node.exe', 'claude') })
    Get-SelfPaneState $f $true | Should BeNullOrEmpty
    $m = & $core; $m.argv = @('pwsh.exe', '-NoExit')
    Get-SelfPaneState $m $true | Should BeNullOrEmpty
    $c = & $core; $c.argv = @('cmd.exe', '__hc_prompt')
    Get-SelfPaneState $c $true | Should BeNullOrEmpty
    Get-SelfPaneState $null $true | Should BeNullOrEmpty
  }
  It 'foreground là shell hoặc lệnh crew đang gọi vẫn nhận' {
    foreach ($exe in 'C:\p\pwsh.EXE', 'hc.exe', 'git') {
      $f = & $core; $f | Add-Member foreground ([pscustomobject]@{ argv = @($exe) })
      Get-SelfPaneState $f $true | Should Be 'lost'
    }
  }
}

Describe 'Wait-SelfPaneShell' -Tag 'windows' {
  $root = [string]$TestDrive
  $job = @{ root = $root; term = 'a-planner'; address = 't1'; restart = $false; parentPid = 999999 }
  $mk = { [pscustomobject]@{ name = 'a-planner'; address = 't1'; cwd = $root; state = 'live'; status = $null; pid = 5; argv = $CoreArgv } }
  $ops = { param($info, $screen) @{ Get = { param($t) $info }.GetNewClosure(); Read = { param($t) $screen }.GetNewClosure(); Sleep = { param($ms) } } }
  It 'shell trống, crew đã thoát -> trả info' -Skip:(-not $OnWindows) {
    (Wait-SelfPaneShell $job (& $ops (& $mk) 'PS C:\x>') 4 0).Why | Should Be ''
  }
  It 'người dùng đang gõ lệnh khác -> giữ pane' -Skip:(-not $OnWindows) {
    (Wait-SelfPaneShell $job (& $ops (& $mk) 'PS C:\x> git status') 4 0).Why | Should Match 'shell trống'
  }
  It 'đổi địa chỉ, đổi tên, khác project, mất terminal -> giữ pane' -Skip:(-not $OnWindows) {
    $a = & $mk; $a.address = 't2'; (Wait-SelfPaneShell $job (& $ops $a 'PS C:\x>') 4 0).Why | Should Match 'đã đổi'
    $n = & $mk; $n.name = 'x'; (Wait-SelfPaneShell $job (& $ops $n 'PS C:\x>') 4 0).Why | Should Match 'đã đổi'
    $o = & $mk; $o.cwd = 'C:\khac'; (Wait-SelfPaneShell $job (& $ops $o 'PS C:\x>') 4 0).Why | Should Match 'không thuộc project'
    (Wait-SelfPaneShell $job (& $ops $null 'PS C:\x>') 4 0).Why | Should Match 'không đọc được'
  }
  It 'pane exited chỉ thay khi -Restart' -Skip:(-not $OnWindows) {
    $e = & $mk; $e.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x')
    (Wait-SelfPaneShell $job (& $ops $e 'PS C:\x>') 4 0).Why | Should Match 'shell trống'
    $r = $job.Clone(); $r.restart = $true
    (Wait-SelfPaneShell $r (& $ops $e 'PS C:\x>') 4 0).Why | Should Be ''
  }
  It 'crew chưa thoát (pid cha còn sống, khác shell) -> không kết luận shell trống' -Skip:(-not $OnWindows) {
    $r = $job.Clone(); $r.parentPid = $PID
    (Wait-SelfPaneShell $r (& $ops (& $mk) 'PS C:\x>') 3 0).Why | Should Match 'chưa thoát'
    # shim chạy crew trong chính shell của pane: pid cha = pid pane thì không đợi pid
    $same = & $mk; $same.pid = $PID
    (Wait-SelfPaneShell $r (& $ops $same 'PS C:\x>') 3 0).Why | Should Be ''
  }
}

Describe 'Get-SelfPaneTimeoutSec' {
  $saved = $env:CREWLINE_SELF_PANE_TIMEOUT_SEC
  It 'mặc định 10 phút; số dương từ biến môi trường; giá trị lạ về mặc định' {
    $env:CREWLINE_SELF_PANE_TIMEOUT_SEC = $null
    Get-SelfPaneTimeoutSec | Should Be 600
    $env:CREWLINE_SELF_PANE_TIMEOUT_SEC = '7'
    Get-SelfPaneTimeoutSec | Should Be 7
    foreach ($bad in 'abc', '0', '-5') {
      $env:CREWLINE_SELF_PANE_TIMEOUT_SEC = $bad
      Get-SelfPaneTimeoutSec | Should Be 600
    }
    $env:CREWLINE_SELF_PANE_TIMEOUT_SEC = $saved
  }
}

Describe 'Get-HotWarnings: terminal không tên' {
  $root = Join-Path $TestDrive 'hot'
  New-Item -ItemType Directory -Force $root | Out-Null
  git -C $root init -q -b main
  $cfg = [pscustomobject]@{ name = 'demo'; workers = @('claude'); review = 'lean'; access = 'work'; planner = 'none'; rev = 'none' }
  [IO.File]::WriteAllText((Join-Path $root '.gitignore'), ".crew/`n")
  git -C $root add -A; git -C $root -c user.name=t -c user.email=t@t commit -q -m init
  $warn = { param($t) @(Get-HotWarnings $root $cfg @() @($t)) -join "`n" }
  foreach ($exe in 'pwsh', 'pwsh.exe', 'powershell', 'powershell.exe', 'PWSH.EXE', 'PowerShell.Exe') {
    It "shell thường $exe không tên -> không cảnh báo" {
      & $warn ([pscustomobject]@{ name = $null; cwd = $root; agent = $exe }) | Should Not Match 'planner thứ hai'
    }
  }
  It 'agent thật không tên vẫn cảnh báo; shell có tên giữ như cũ' {
    & $warn ([pscustomobject]@{ name = $null; cwd = $root; agent = 'claude-code' }) | Should Match 'planner thứ hai'
    & $warn ([pscustomobject]@{ name = $null; cwd = $root; agent = 'codex' }) | Should Match 'planner thứ hai'
    & $warn ([pscustomobject]@{ name = 'tay'; cwd = $root; agent = 'pwsh.exe' }) | Should Match 'planner thứ hai'
  }
}

Describe 'crew up trong pane của một vai (hc giả, tiến trình nền thật)' {
  It 'lỗi t3m: planner shell core, crew đang in -> không bỏ qua, không cần người quyết, exit 0, thay sau cùng, mở lại hội thoại, đúng tab' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $sid = '11111111-2222-3333-4444-555555555555'
    [ordered]@{ version = 1; roles = [ordered]@{ planner = [ordered]@{ agent = 'claude'; root = $root; sessionId = $sid } }; codexRootRoles = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Encoding utf8
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root 'spcrewproj' 'tbcrewprojplanner')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'proj-planner đã chạy, bỏ qua'
    $r.Output | Should Not Match 'agent đã thoát'
    $r.Output | Should Not Match 'CẦN NGƯỜI QUYẾT'
    $r.Output | Should Match 'pane hiện tại, shell trống'
    $r.Output | Should Match 'tab này sắp chuyển thành proj-planner sau vài giây; chữ đang in sẽ mất'
    Wait-Background $root
    Get-BgLog $root | Should Be ''
    $log = Get-HcLog $ctx
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name proj-w1').Count | Should Be 1
    # vai khác bật trước khi pane bị thay; đúng đường bật + nhãn tab
    (Get-Index $log '^run .*--name proj-w1') | Should BeLessThan (Get-Index $log '^kill t3m')
    (Get-Index $log '^kill t3m') | Should BeLessThan (Get-Index $log '^run .*--name proj-planner')
    $run = @(Get-Lines $ctx '^run .*--name proj-planner')[0]
    $run | Should Match 'herdr\.space=spcrewproj'
    $run | Should Match 'herdr\.tab=tbcrewprojplanner'
    $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($run -split '-EncodedCommand ')[1].Trim()))
    $cmd | Should Match "--resume $sid"
    # tab bị đóng khi mất terminal duy nhất: bật lại xong vẫn đặt tên, xếp thứ tự, focus như cuối crew up
    $herdr = Get-HerdrLog $ctx
    $herdr[-1] | Should Match 'tab\.select --id tbcrewprojplanner'
    @($herdr | Where-Object { $_ -match 'tab\.move --id tbcrewprojplanner --index 1' }).Count | Should BeGreaterThan 0
    @($herdr | Where-Object { $_ -match 'tab\.rename --id tbcrewprojplanner --name planner' }).Count | Should BeGreaterThan 0
    # sổ phiên giữ nguyên id
    (Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw | ConvertFrom-Json).roles.planner.sessionId | Should Be $sid
  }

  It 'chạy lại sau khi thay: pane đã là agent -> không làm gì thêm, 0 kill, 0 bật, 0 gửi' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Wait-Background $root
    $before = @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count
    $newAddr = ((Get-Content -LiteralPath (Join-Path $ctx.State 'terminals.json') -Raw | ConvertFrom-Json) | Where-Object { $_.name -eq 'proj-planner' }).address
    $ctx.Env.HC_TERMINAL_ID = $newAddr
    $again = Invoke-Crew $ctx @('up') $root
    $again.ExitCode | Should Be 0
    $again.Output | Should Match 'không có gì phải sửa'
    $again.Output | Should Not Match 'sắp chuyển'
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be $before
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
  }

  It 'đọc lại khác đi (người dùng đã gõ lệnh khác) -> 0 kill, 0 bật chồng, log, crew up sau nhắc log' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen-after.txt'), 'PS C:\x> git status')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 0
    Get-BgLog $root | Should Match 'giữ pane proj-planner'
    $ctx.Env.HC_TERMINAL_ID = $null
    $next = Invoke-Crew $ctx @('up', '-DryRun') $root
    $next.Output | Should Match 'lần thay pane trước có chuyện cần xem'
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.log') | Should Be $true
    $real = Invoke-Crew $ctx @('repair') $root
    $real.Output | Should Match 'self-pane\.log\.old'
    (Invoke-Crew $ctx @('repair') $root).Output | Should Not Match 'lần thay pane trước'
  }

  It '-All nhiều project, pane thuộc project đầu: project sau bật trước, thay sau bảng tổng kết, tiến trình con nhận được HC_TERMINAL_ID' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $a = New-Repo 'aa'
    $b = New-Repo 'bb' 'none'
    Set-Reg $ctx @(@('aa', $a), @('bb', $b))
    Set-Terms $ctx @(New-CoreShell 'aa-planner' 't3m' $a)
    $r = Invoke-Crew $ctx @('up', '-All') $a
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'CREW-SELF-PANE'
    $r.Output | Should Not Match 'CẦN NGƯỜI QUYẾT'
    $tail = ($r.Output -split '== tổng kết crew up -All')[1]
    $tail | Should Match 'tab này sắp chuyển thành aa-planner'
    ($r.Output -split '== tổng kết crew up -All')[0] | Should Not Match 'tab này sắp chuyển'
    Wait-Background $a
    Get-BgLog $a | Should Be ''
    $log = Get-HcLog $ctx
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    (Get-Index $log '^run .*--name bb-w1') | Should BeLessThan (Get-Index $log '^kill t3m')
    (Get-Lines $ctx '^run .*--name aa-planner').Count | Should Be 1
  }

  It 'worker có task trong tab 2 pane: task giao đúng 1 lần, pane về đúng vị trí' -Skip:$NoBackground {
    $ctx = New-Ctx 't40'
    $root = New-Repo 'wk' 'none' @('claude', 'claude')
    $wt1 = Add-Worktree $root 1; $wt2 = Add-Worktree $root 2
    git -C $wt1 switch -q -c 'crew/viec'
    New-Item -ItemType Directory -Force (Join-Path $wt1 '.crew') | Out-Null
    'prompt' | Set-Content -LiteralPath (Join-Path $wt1 '.crew/prompt.md')
    ConvertTo-Json -InputObject @([ordered]@{ name = 'viec'; branch = 'crew/viec'; worktree = $wt1; worker = 1; terminal = 'wk-w1'; agent = 'claude'; created = '2026-11-02T00:00:00' }) -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.crew/tasks.json') -Encoding utf8
    Set-Terms $ctx @((New-CoreShell 'wk-w1' 't40' $wt1 'spcrewwk' 'tbcrewwkworkers1'), (New-Agent 'wk-w2' 't41' $wt2 'spcrewwk' 'tbcrewwkworkers1'))
    $r = Invoke-Crew $ctx @('up') $wt1
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'tab này sắp chuyển thành wk-w1'
    @(Get-Lines $ctx '^send ').Count | Should Be 0
    Wait-Background $root
    Get-BgLog $root | Should Be ''
    (Get-Lines $ctx '^kill t40').Count | Should Be 1
    (Get-Lines $ctx '^kill t41').Count | Should Be 0
    $sends = @(Get-Lines $ctx '^send ')
    $sends.Count | Should Be 1
    $sends[0] | Should Match '^send wk-w1 .*viec'
    $herdr = Get-HerdrLog $ctx
    @($herdr | Where-Object { $_ -match 'pane\.swap --direction left' }).Count | Should Be 1
    $order = @((Get-Content -LiteralPath (Join-Path $ctx.State 'terminals.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_.name })
    $order[0] | Should Be 'wk-w1'
    $order[1] | Should Be 'wk-w2'
    $herdr[-1] | Should Match 'tab\.select --id tbcrewwkworkers1'
    # chạy lại không gửi lần hai
    $ctx.Env.HC_TERMINAL_ID = $null
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    @(Get-Lines $ctx '^send ').Count | Should Be 1
  }

  It 'vai rev: cùng đường thay; worker pane sau không cần đổi vị trí' -Skip:$NoBackground {
    $ctx = New-Ctx 't50'
    $root = New-Repo 'rv' 'none' @('claude') 'claude'
    Set-Terms $ctx @(New-CoreShell 'rv-rev' 't50' $root)
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t50').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name rv-rev').Count | Should Be 1
    @(Get-HerdrLog $ctx | Where-Object { $_ -match 'pane\.swap' }).Count | Should Be 0
  }

  It '-DryRun: chỉ báo sẽ thay, 0 ghi, 0 tiến trình nền' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    Set-Reg $ctx @(, @('proj', $root))
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-CoreShell 'proj-planner' 't3m' $root), (New-Agent 'proj-w1' 't2' $wt))
    $before = Get-Snapshot @($root, (Join-Path $ctx.Home.Home '.crewline'))
    $r = Invoke-Crew $ctx @('up', '-DryRun') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match '\(sẽ làm\) thay pane hiện tại thành proj-planner'
    $r.Output | Should Not Match 'tab này sắp chuyển'
    Get-Snapshot @($root, (Join-Path $ctx.Home.Home '.crewline')) | Should Be $before
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be 0
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
    $all = Invoke-Crew $ctx @('up', '-All', '-DryRun') $root
    $all.ExitCode | Should Be 0
    $all.Output | Should Match '\(sẽ làm\) thay pane hiện tại'
    $all.Output | Should Not Match 'CREW-SELF-PANE'
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
  }

  It 'crew repair: hiện pane hiện tại, shell trống; không thay; vai khác vẫn được bật' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    $r = Invoke-Crew $ctx @('repair') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'pane hiện tại, shell trống'
    $r.Output | Should Match 'crew repair không tự thay'
    $r.Output | Should Not Match 'tab này sắp chuyển'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-w1').Count | Should Be 1
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
  }

  It 'không có HC_TERMINAL_ID: hành vi như cũ' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx $null
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    # màn hình không phải dấu nhắc: bỏ qua, cần người quyết
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen-after.txt'), 'chưa rõ')
    $keep = Invoke-Crew $ctx @('up') $root
    $keep.ExitCode | Should Be 1
    $keep.Output | Should Match 'CẦN NGƯỜI QUYẾT:.*agent đã thoát'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    # dấu nhắc: tắt ngay trong lệnh, không tiến trình nền
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen-after.txt'), 'PS C:\x>')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'sắp chuyển'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
  }

  It 'gọi từ terminal khác của cùng project: vẫn khôi phục shell trống ngay, không tiến trình nền' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't99'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen-running.txt'), 'PS C:\x>')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.lock') | Should Be $false
  }

  It 'pane exited (crew bật, agent đã thoát) không -Restart: cảnh báo như cũ, không thay' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    $p = New-CoreShell 'proj-planner' 't3m' $root
    $p.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x')
    Set-Terms $ctx @($p, (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'CẦN NGƯỜI QUYẾT: proj-planner: agent đã thoát'
    $r.Output | Should Not Match 'sắp chuyển'
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be 0
  }

  It 'còn thư mục w<N> lạ: vai khác không bật được thì cũng không thay pane' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    New-Item -ItemType Directory -Force (Join-Path $root '.crew/worktrees/w1') | Out-Null
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'chưa thay pane hiện tại'
    $r.Output | Should Not Match 'sắp chuyển'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
  }

  It 'Unix: không tự thay, in hướng dẫn, exit 0' -Skip:$OnWindows {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    $p = New-CoreShell 'proj-planner' 't3m' $root
    $p.argv = @('/bin/bash')
    Set-Terms $ctx @($p, (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Mở tab khác rồi chạy lại'
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be 0
  }
}

Describe 'không tạo được tiến trình nền (job thật cấm breakaway, hc giả)' {
  It 'dò năng lực: trong job cấm breakaway báo bị cấm kèm lý do' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx ''
    $probe = Join-Path $ctx.State 'probe.ps1'
    $body = "function Start-BreakawayProcess { $(${function:Start-BreakawayProcess}) }`nfunction Get-BreakawayBlock { $(${function:Get-BreakawayBlock}) }`n`"BLOCK=`$(Get-BreakawayBlock)`"`n"
    [IO.File]::WriteAllText($probe, $body, [Text.UTF8Encoding]::new($true))
    $r = Invoke-NoBreakaway $ctx $probe @() $ctx.State
    $r.Output | Should Match 'BLOCK=CreateProcess lỗi 5, tiến trình nằm trong job cấm breakaway'
  }

  It 'crew up: giữ pane, báo rõ, không kill, vai khác vẫn bật, không sót job/lock/tiến trình' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    $r = Invoke-NoBreakaway $ctx $crewScript @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'không tạo được tiến trình nền \(CreateProcess lỗi 5\); giữ pane\. Mở tab khác rồi chạy lại: crew up'
    (Get-Lines $ctx '^kill ').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-w1').Count | Should Be 1
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.lock') | Should Be $false
    Get-BgLog $root | Should Be ''
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'self-pane-(run|work)' -and $_.CommandLine -match [regex]::Escape($root) }).Count | Should Be 0
  }

  It 'crew up -Restart: gợi ý đúng lệnh -Restart, không kill pane mình' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-CoreShell 'proj-planner' 't3m' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-NoBreakaway $ctx $crewScript @('up', '-Restart', 'planner') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'CreateProcess lỗi 5\); giữ pane\. Mở tab khác rồi chạy lại: crew up -Restart planner'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 0
  }
}

Describe 'self-pane-run có giới hạn thời gian (hc giả treo, tiến trình nền thật)' {
  $assertNoLeftover = {
    param($ctx, $root)
    $pidFile = Join-Path $ctx.State 'hang.pid'
    Test-Path -LiteralPath $pidFile | Should Be $true
    Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue | Should BeNullOrEmpty
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.json') | Should Be $false
    Test-Path -LiteralPath (Join-Path $root '.crew/self-pane.killed') | Should Be $false
    ([IO.File]::Open((Join-Path $root '.crew/self-pane.lock'), 'Open', 'ReadWrite', 'None')).Dispose()
  }

  It 'treo trước khi kill: quá hạn thì giữ pane, ghi log, nhả lock, không sót tiến trình; crew up sau nhắc log' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $ctx.Env.CREWLINE_SELF_PANE_TIMEOUT_SEC = '10'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    [IO.File]::WriteAllText((Join-Path $ctx.State 'hang-get.txt'), 'x')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 0
    $log = Get-BgLog $root
    $log | Should Match 'quá hạn 10 giây'
    $log | Should Match 'pane chưa bị tắt, giữ nguyên'
    & $assertNoLeftover $ctx $root
    Remove-Item -LiteralPath (Join-Path $ctx.State 'hang-get.txt')
    $ctx.Env.HC_TERMINAL_ID = $null
    (Invoke-Crew $ctx @('up', '-DryRun') $root).Output | Should Match 'lần thay pane trước có chuyện cần xem'
  }

  It 'treo sau khi kill: quá hạn thì ghi log, nhả lock, không sót tiến trình; crew up sau bật vai thiếu và nhắc log' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $ctx.Env.CREWLINE_SELF_PANE_TIMEOUT_SEC = '25'
    $root = New-Repo 'proj'
    Set-Terms $ctx @(New-CoreShell 'proj-planner' 't3m' $root)
    [IO.File]::WriteAllText((Join-Path $ctx.State 'hang-run.txt'), 'x')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    $log = Get-BgLog $root
    $log | Should Match 'quá hạn 25 giây'
    $log | Should Match 'pane có thể đã tắt'
    & $assertNoLeftover $ctx $root
    Remove-Item -LiteralPath (Join-Path $ctx.State 'hang-run.txt')
    $ctx.Env.HC_TERMINAL_ID = $null
    $next = Invoke-Crew $ctx @('up') $root
    $next.ExitCode | Should Be 0
    $next.Output | Should Match 'lần thay pane trước có chuyện cần xem'
    ((Get-Content -LiteralPath (Join-Path $ctx.State 'terminals.json') -Raw | ConvertFrom-Json) | Where-Object { $_.name -eq 'proj-planner' }).state | Should Be 'live'
  }
}

Describe 'crew up trong pane worker có task đã xong (hc giả, tiến trình nền thật)' {
  It 'báo trước, thay pane, 0 tin giao lại; log xóa như khi xong êm' -Skip:$NoBackground {
    $ctx = New-Ctx 't40'
    $root = New-Repo 'wk' 'none'
    $wt = Add-Worktree $root 1
    git -C $wt switch -q -c 'crew/viec'
    New-Item -ItemType Directory -Force (Join-Path $wt '.crew'), (Join-Path $wt 'context/tasks') | Out-Null
    'prompt' | Set-Content -LiteralPath (Join-Path $wt '.crew/prompt.md')
    'note' | Set-Content -LiteralPath (Join-Path $wt 'context/tasks/viec.md')
    git -C $wt add -A
    git -C $wt -c user.name=t -c user.email=t@t commit -q -m xong
    ConvertTo-Json -InputObject @([ordered]@{ name = 'viec'; branch = 'crew/viec'; worktree = $wt; worker = 1; terminal = 'wk-w1'; agent = 'claude'; created = '2026-11-02T00:00:00' }) -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.crew/tasks.json') -Encoding utf8
    Set-Terms $ctx @(New-CoreShell 'wk-w1' 't40' $wt)
    $r = Invoke-Crew $ctx @('up') $wt
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'task viec có vẻ đã xong, không giao lại'
    $r.Output | Should Match 'tab này sắp chuyển thành wk-w1'
    Wait-Background $root
    Get-BgLog $root | Should Be ''
    (Get-Lines $ctx '^kill t40').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name wk-w1').Count | Should Be 1
    @(Get-Lines $ctx '^send ').Count | Should Be 0
  }
}

Describe 'crew up -Restart từ chính pane của vai (hc giả, tiến trình nền thật)' {
  It 'pane có agent sống: Die trước mọi kill, nêu cách làm' {
    $ctx = New-Ctx 't1'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-Agent 'proj-planner' 't1' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'planner') $root
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'Mở tab khác rồi chạy lại: crew up -Restart planner'
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be 0
  }

  It '-Restart all từ pane agent sống: 0 kill ở mọi vai' {
    $ctx = New-Ctx 't2'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-Agent 'proj-planner' 't1' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'all') $root
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'Không tắt vai nào'
    @(Get-Lines $ctx '^(run|send|keys|kill|rm)\b').Count | Should Be 0
  }

  It 'agent ở pane khác restart worker: vẫn được, không đụng pane mình' {
    $ctx = New-Ctx 't1'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-Agent 'proj-planner' 't1' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'w1') $root
    $r.ExitCode | Should Be 0
    (Get-Lines $ctx '^kill t2').Count | Should Be 1
    (Get-Lines $ctx '^kill t1').Count | Should Be 0
    $r.Output | Should Not Match 'sắp chuyển'
  }

  It 'pane shell: thay sau cùng, hội thoại mới' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    $old = '11111111-2222-3333-4444-555555555555'
    [ordered]@{ version = 1; roles = [ordered]@{ planner = [ordered]@{ agent = 'claude'; root = $root; sessionId = $old } }; codexRootRoles = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Encoding utf8
    Set-Terms $ctx @((New-CoreShell 'proj-planner' 't3m' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'planner') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'tab này sắp chuyển thành proj-planner'
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    Wait-Background $root
    Get-BgLog $root | Should Be ''
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    $run = @(Get-Lines $ctx '^run .*--name proj-planner')[0]
    $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($run -split '-EncodedCommand ')[1].Trim()))
    $cmd | Should Match '--session-id'
    $cmd | Should Not Match $old
    (Get-Lines $ctx '^kill t2').Count | Should Be 0
  }

  It '-Restart all từ pane shell: vai khác tắt và bật trước, pane mình sau cùng' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-CoreShell 'proj-planner' 't3m' $root), (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'all') $root
    $r.ExitCode | Should Be 0
    (Get-Lines $ctx '^kill t2').Count | Should Be 1
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-w1').Count | Should Be 1
    Wait-Background $root
    Get-BgLog $root | Should Be ''
    $log = Get-HcLog $ctx
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name proj-w1').Count | Should Be 1
    (Get-Index $log '^run .*--name proj-w1') | Should BeLessThan (Get-Index $log '^kill t3m')
    (Get-Index $log '^kill t3m') | Should BeLessThan (Get-Index $log '^run .*--name proj-planner')
  }

  It 'pane exited + -Restart: được thay' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    $p = New-CoreShell 'proj-planner' 't3m' $root
    $p.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x')
    Set-Terms $ctx @($p, (New-Agent 'proj-w1' 't2' $wt))
    $r = Invoke-Crew $ctx @('up', '-Restart', 'planner') $root
    $r.ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t3m').Count | Should Be 1
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 1
  }

  It 'đọc lại khác đi sau -Restart: 0 kill pane mình' -Skip:$NoBackground {
    $ctx = New-Ctx 't3m'
    $root = New-Repo 'proj'
    $wt = Add-Worktree $root 1
    Set-Terms $ctx @((New-CoreShell 'proj-planner' 't3m' $root), (New-Agent 'proj-w1' 't2' $wt))
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen-after.txt'), 'claude đang chạy')
    (Invoke-Crew $ctx @('up', '-Restart', 'planner') $root).ExitCode | Should Be 0
    Wait-Background $root
    (Get-Lines $ctx '^kill t3m').Count | Should Be 0
    (Get-Lines $ctx '^run .*--name proj-planner').Count | Should Be 0
    Get-BgLog $root | Should Match 'giữ pane'
  }
}

[Console]::OutputEncoding = $savedOutEnc
