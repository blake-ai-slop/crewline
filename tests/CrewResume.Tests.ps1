# Mở lại hội thoại: trích hàm bằng AST + e2e qua crew.ps1 thật trong HOME giả với hc/herdr-app giả. hc giả không chạy agent nào; không gọi hc thật.
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Get-Flags', 'Quote', 'Get-AgentCommand', 'ConvertTo-RootKey', 'Test-SamePath', 'Get-TermStatus', 'Get-SendPlan', 'Get-WorkerMode',
  'Get-TermShellState', 'Get-InputBox', 'Get-ScreenDialog', 'Wait-WorkerReady', 'Get-SessionsFile', 'New-SessionBook', 'Test-SessionId', 'Read-SessionBook', 'Save-SessionBook',
  'Set-SessionRecord', 'Get-NewSessionPlan', 'Get-SessionPlan', 'Format-SessionPlan', 'Test-AgentScreen', 'Get-ResumeState', 'Wait-ResumeStates'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($msg) { $script:Said += , [string]$msg }
function hc { throw 'không được gọi hc thật' }
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
$Id = '11111111-2222-4333-8444-555555555555'

function New-Cfg($planner = 'claude', $rev = 'claude', $workers = @('claude')) { [pscustomobject]@{ planner = $planner; rev = $rev; workers = $workers; access = 'wide' } }
function New-Book($roles = @{}, $codexRoot = @()) { $b = New-SessionBook; $b.Roles = $roles; $b.CodexRootRoles = $codexRoot; $b }

Describe 'Get-AgentCommand dựng lệnh theo phiên, giữ quyền của project' {
  $flags = @{ 'claude|work' = '--permission-mode acceptEdits'; 'claude|wide' = '--permission-mode bypassPermissions'
    'codex|work' = '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; 'codex|wide' = '--no-daemon --sandbox danger-full-access --ask-for-approval never' }
  foreach ($access in 'work', 'wide') {
    It "claude / $access" {
      $f = $flags["claude|$access"]
      Get-AgentCommand claude $access 'x' @{ Mode = 'new-id'; Id = $Id } | Should BeExactly "claude $f --session-id $Id 'x'"
      Get-AgentCommand claude $access 'x' @{ Mode = 'resume-id'; Id = $Id } | Should BeExactly "claude $f --resume $Id"
      Get-AgentCommand claude $access 'x' @{ Mode = 'continue' } | Should BeExactly "claude $f --continue"
      Get-AgentCommand claude $access 'x' | Should BeExactly "claude $f 'x'"
    }
    It "codex / $access" {
      $f = $flags["codex|$access"]
      Get-AgentCommand codex $access 'x' @{ Mode = 'resume-last' } | Should BeExactly "codex resume --last $f"
      Get-AgentCommand codex $access 'x' | Should BeExactly "codex $f 'x'"
    }
  }
}

Describe 'Get-SessionPlan: quy tắc chọn phiên' {
  $root = 'C:\p'
  It 'worker: Claude --continue, Codex resume --last, không cần id' {
    $b = New-Book @{ w1 = @{ agent = 'claude'; root = $root }; w2 = @{ agent = 'codex'; root = $root } }
    $c = New-Cfg 'none' 'none' @('claude', 'codex')
    $p = Get-SessionPlan $b $root $c 'w1' 'claude'
    $p.Resume | Should Be $true; $p.Session.Mode | Should Be 'continue'
    $p = Get-SessionPlan $b $root $c 'w2' 'codex'
    $p.Resume | Should Be $true; $p.Session.Mode | Should Be 'resume-last'
  }
  It 'planner/Rev Claude: --resume đúng id đã lưu; thiếu hoặc sai dạng id ⇒ hội thoại mới có cảnh báo' {
    $b = New-Book @{ planner = @{ agent = 'claude'; root = $root; sessionId = $Id }; rev = @{ agent = 'claude'; root = $root; sessionId = "x'; rm -r /" } }
    $p = Get-SessionPlan $b $root (New-Cfg) 'planner' 'claude'
    $p.Session.Mode | Should Be 'resume-id'; $p.Session.Id | Should Be $Id
    $p = Get-SessionPlan $b $root (New-Cfg) 'rev' 'claude'
    $p.Resume | Should Be $false; $p.Warn | Should Be $true; $p.Session.Mode | Should Be 'new-id'; $p.Session.Id | Should Not Match 'rm'
  }
  It 'Codex ở gốc: một vai resume --last; hai vai ⇒ hội thoại mới và cảnh báo' {
    $b = New-Book @{ planner = @{ agent = 'codex'; root = $root }; rev = @{ agent = 'codex'; root = $root } } @('planner', 'rev')
    foreach ($role in 'planner', 'rev') {
      $p = Get-SessionPlan $b $root (New-Cfg 'codex' 'codex') $role 'codex'
      $p.Resume | Should Be $false; $p.Warn | Should Be $true; $p.Reason | Should Match 'hai vai Codex'; $p.Session | Should BeNullOrEmpty
    }
    $b = New-Book @{ planner = @{ agent = 'codex'; root = $root } } @('planner')
    (Get-SessionPlan $b $root (New-Cfg 'codex' 'claude') 'planner' 'codex').Session.Mode | Should Be 'resume-last'
    (Get-SessionPlan $b $root (New-Cfg 'codex' 'none') 'planner' 'codex').Session.Mode | Should Be 'resume-last'
  }
  It 'Rev từng chạy Codex ở gốc rồi đổi agent: planner Codex không đoán, hội thoại mới rồi lần sau mới resume' {
    $c = New-Cfg 'codex' 'claude'
    $b = New-Book @{ planner = @{ agent = 'codex'; root = $root }; rev = @{ agent = 'claude'; root = $root; sessionId = $Id } } @('planner', 'rev')
    $p = Get-SessionPlan $b $root $c 'planner' 'codex'
    $p.Resume | Should Be $false; $p.Warn | Should Be $true
    Set-SessionRecord $b $root $c 'planner' 'codex' $p.Session
    (Get-SessionPlan $b $root $c 'planner' 'codex').Session.Mode | Should Be 'resume-last'
  }
  It 'chưa ghi nhận, đổi agent, đổi root, -Restart ⇒ hội thoại mới kèm lý do' {
    $c = New-Cfg
    (Get-SessionPlan (New-Book) $root $c 'w1' 'claude').Reason | Should Match 'chưa có ghi nhận'
    $b = New-Book @{ w1 = @{ agent = 'codex'; root = $root }; w2 = @{ agent = 'claude'; root = 'C:\khac' }; planner = @{ agent = 'claude'; root = $root; sessionId = $Id } }
    $p = Get-SessionPlan $b $root $c 'w1' 'claude'
    $p.Resume | Should Be $false; $p.Reason | Should Match 'đã đổi agent codex sang claude'
    $p = Get-SessionPlan $b $root $c 'w2' 'claude'
    $p.Resume | Should Be $false; $p.Reason | Should Match 'root khác'
    $p = Get-SessionPlan $b $root $c 'planner' 'claude' 'bật lại bằng -Restart'
    $p.Resume | Should Be $false; $p.Reason | Should Match 'Restart'; $p.Session.Id | Should Not Be $Id
  }
  It 'cùng root khác dấu tách vẫn được khôi phục' {
    $b = New-Book @{ w1 = @{ agent = 'claude'; root = 'C:/p/' } }
    (Get-SessionPlan $b $root (New-Cfg) 'w1' 'claude').Resume | Should Be $true
  }
}

Describe 'sổ .crew/sessions.json' {
  It 'thiếu file ⇒ sổ trống, không cảnh báo; ghi rồi đọc lại đúng; chỉ có vai, agent, root, UUID' {
    $root = Join-Path $TestDrive 'a'; New-Item -ItemType Directory -Force $root | Out-Null
    $b = Read-SessionBook $root
    $b.Roles.Count | Should Be 0; $b.Warning | Should BeNullOrEmpty
    Set-SessionRecord $b $root (New-Cfg 'claude' 'codex') 'planner' 'claude' @{ Mode = 'new-id'; Id = $Id }
    Set-SessionRecord $b $root (New-Cfg 'claude' 'codex') 'rev' 'codex' $null
    Set-SessionRecord $b $root (New-Cfg 'claude' 'codex') 'w1' 'claude' $null
    Save-SessionBook $root $b
    $text = Get-Content (Get-SessionsFile $root) -Raw
    $j = $text | ConvertFrom-Json
    @($j.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be 'codexRootRoles,roles,version'
    @($j.roles.planner.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be 'agent,root,sessionId'
    @($j.roles.w1.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be 'agent,root'
    $back = Read-SessionBook $root
    $back.Roles.planner.sessionId | Should Be $Id
    $back.CodexRootRoles | Should Be 'rev'
    Test-Path "$(Get-SessionsFile $root).tmp" | Should Be $false
  }
  It 'file hỏng dưới mọi dạng ⇒ coi như chưa có ghi nhận, cảnh báo, không throw' {
    $root = Join-Path $TestDrive 'b'; New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    foreach ($bad in '{', '', '[]', '1', '{"roles":3}', 'null') {
      [IO.File]::WriteAllText((Get-SessionsFile $root), $bad)
      $b = Read-SessionBook $root
      $b.Roles.Count | Should Be 0
      $b.Warning | Should Match 'hỏng'
    }
  }
  It 'mục sai dạng ⇒ chỉ bỏ mục đó' {
    $root = Join-Path $TestDrive 'c'; New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    [IO.File]::WriteAllText((Get-SessionsFile $root), '{"roles":{"w1":3,"w2":{"agent":1,"root":"x"},"w3":{"agent":"claude","root":"x"}}}')
    $b = Read-SessionBook $root
    @($b.Roles.Keys) -join ',' | Should Be 'w3'
    $b.Warning | Should BeNullOrEmpty
  }
  It 'không ghi được ⇒ cảnh báo, không throw' {
    $script:Said = @()
    $root = Join-Path $TestDrive 'd'; New-Item -ItemType Directory -Force $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.crew'), 'file chắn đường')
    { Save-SessionBook $root (New-Book @{ w1 = @{ agent = 'claude'; root = $root } }) } | Should Not Throw
    ($script:Said -join ' ') | Should Match 'không ghi được sổ phiên'
  }
}

Describe 'nhận phiên đã mở lại trên màn hình thật' {
  # Chân màn hình đo trên Claude Code 2.1.316 và codex-cli 0.166.0.
  $claudeOk = "Remember the word PLUM. Reply only: ok`n ok`n─────`n❯`n─────`n  ⏵⏵ accept edits on (shift+tab to cycle)"
  $claudeWide = "❯`n─────`n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
  $codexOk = "Remember PLUM`n Ask Codex to do anything`nGPT · ~\repo · Context 98% left · 5h 64% left"
  $coreEnc = [pscustomobject]@{ name = 'x-w1'; address = 't1'; state = 'live'; status = $null; turn = 0; argv = @('pwsh', '-NoExit', '-EncodedCommand', 'YQ==') }
  It 'Test-AgentScreen nhận chân TUI, bỏ shell kể cả khi chữ cũ còn trên màn hình' {
    Test-AgentScreen claude $claudeOk | Should Be $true
    Test-AgentScreen claude $claudeWide | Should Be $true
    Test-AgentScreen codex $codexOk | Should Be $true
    Test-AgentScreen codex 'Context 100% left' | Should Be $true
    Test-AgentScreen claude "$claudeOk`nPS C:\x> " | Should Be $false
    Test-AgentScreen codex "$codexOk`nPS C:\x>" | Should Be $false
    Test-AgentScreen claude 'PS C:\x>' | Should Be $false
    Test-AgentScreen claude "chữ thường`n" | Should Be $false
    Test-AgentScreen codex $claudeOk | Should Be $false
    Test-AgentScreen claude $codexOk | Should Be $false
  }
  $mkOps = { param($info, $screen) @{ Get = { param($t) $info }.GetNewClosure(); Read = { param($t) $screen }.GetNewClosure(); Sleep = { param($ms) } } }
  It 'Wait-WorkerReady: status null + chân TUI ⇒ sẵn sàng; shell thì không' {
    Wait-WorkerReady 'x-w1' 'claude' (& $mkOps $coreEnc $claudeOk) 2 | Should BeNullOrEmpty
    Wait-WorkerReady 'x-w1' 'codex' (& $mkOps $coreEnc $codexOk) 2 | Should BeNullOrEmpty
    Wait-WorkerReady 'x-w1' 'claude' (& $mkOps $coreEnc 'PS C:\x>') 2 | Should Match 'chưa sẵn sàng'
  }
  It 'prompt Unix sau TUI cũ không là agent sẵn sàng' {
    foreach ($prompt in 'user@host:~/repo$ ', 'root@host:/repo# ') {
      foreach ($kind in 'claude', 'codex') {
        $screen = $(if ($kind -eq 'claude') { $claudeOk } else { $codexOk }) + "`n" + $prompt
        Test-AgentScreen $kind $screen | Should Be $false
        Wait-WorkerReady 'x-w1' $kind (& $mkOps $coreEnc $screen) 2 | Should Match 'chưa sẵn sàng'
      }
    }
  }
  It 'Wait-WorkerReady: hộp thoại lạ và trust vẫn thắng chân TUI, không báo sẵn sàng' {
    Wait-WorkerReady 'x-w1' 'claude' (& $mkOps $coreEnc "Do you want to proceed?`n$claudeOk") 2 | Should Match 'hộp thoại'
    Wait-WorkerReady 'x-w1' 'codex' (& $mkOps $coreEnc "Trust this folder? x`n› 1. Trust and continue`n  2. Quit`n$codexOk") 2 | Should Match 'trust'
  }
  It 'Get-ResumeState: ready / exited / dialog / chưa rõ' {
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $coreEnc $claudeOk) | Should Be 'ready'
    Get-ResumeState 'x-w1' 'codex' (& $mkOps $coreEnc $codexOk) | Should Be 'ready'
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $coreEnc "No conversation found to continue`nPS C:\x>") | Should Be 'exited'
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $coreEnc "Do you want to proceed?`n$claudeOk") | Should Be 'dialog'
    $blocked = [pscustomobject]@{ state = 'live'; status = 'blocked'; argv = @('pwsh', '-EncodedCommand', 'YQ==') }
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $blocked $claudeOk) | Should Be 'dialog'
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $coreEnc 'đang tải') | Should BeNullOrEmpty
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $null '') | Should BeNullOrEmpty
    $gone = [pscustomobject]@{ state = 'finished'; status = $null; argv = @() }
    Get-ResumeState 'x-w1' 'claude' (& $mkOps $gone '') | Should Be 'exited'
  }
  It 'Wait-ResumeStates hết lượt chờ thì dừng, không lặp vô hạn' {
    $script:Sleeps = 0
    $ops = & $mkOps $coreEnc 'đang tải'
    $ops.Sleep = { param($ms) $script:Sleeps++ }
    $r = Wait-ResumeStates @(@{ Term = 'x-w1'; Kind = 'claude' }) $ops 3
    $r['x-w1'] | Should BeNullOrEmpty
    $script:Sleeps | Should Be 2
  }
}

# ---------- e2e: crew.ps1 thật, HOME giả, hc giả ghi lệnh pane đã giải mã ----------
# hc giả không chạy agent: mô phỏng theo lệnh pane. FAKE_RESUME = ok | fail | dialog | hang quyết định pane mở lại phiên ra sao.
$FakeHc = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
Add-Content -LiteralPath (Join-Path $dir 'hc.log') -Value ($args -join ' ') -Encoding utf8
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
$saveTerms = { param($list) ConvertTo-Json -InputObject @($list) -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8 }
switch ($args[0]) {
  'ls' { ConvertTo-Json -InputObject ([ordered]@{ terminals = @($terms) }) -Depth 6; exit 0 }
  'get' {
    $key = $args[1]
    $t = $terms | Where-Object { $_.name -eq $key -or $_.address -eq $key } | Select-Object -First 1
    if (-not $t) { exit 1 }
    $t | ConvertTo-Json -Depth 6; exit 0
  }
  'kill' { $key = $args[1]; & $saveTerms @($terms | Where-Object { $_.address -ne $key }); exit 0 }
  'send' { '{"started":true}'; exit 0 }
  'read' {
    $key = $args[1]
    $t = $terms | Where-Object { $_.name -eq $key -or $_.address -eq $key } | Select-Object -First 1
    if ($t) { $t.screen }
    exit 0
  }
  'run' {
    $name = ''; $cwd = ''; $space = ''; $tab = ''; $enc = ''
    for ($i = 1; $i -lt $args.Count; $i++) {
      if ($args[$i] -eq '--name') { $name = $args[$i + 1] }
      if ($args[$i] -eq '--cwd') { $cwd = $args[$i + 1] }
      if ($args[$i] -eq '-EncodedCommand') { $enc = $args[$i + 1] }
      if ($args[$i] -eq '--label' -and $args[$i + 1] -like 'herdr.space=*') { $space = $args[$i + 1].Substring(12) }
      if ($args[$i] -eq '--label' -and $args[$i + 1] -like 'herdr.tab=*') { $tab = $args[$i + 1].Substring(10) }
    }
    $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc))
    Add-Content -LiteralPath (Join-Path $dir 'cmds.log') -Value "$name|$cmd" -Encoding utf8
    $bare = ($cmd -split '\}; ', 2)[-1]
    $kind = if ($bare -like 'codex*') { 'codex' } else { 'claude' }
    $resume = $bare -match '--resume |--continue|resume --last'
    $mode = if ($resume) { $env:FAKE_RESUME } else { 'new' }
    $argv = @('pwsh', '-NoLogo', '-NoExit', '-EncodedCommand', $enc)
    $footer = if ($kind -eq 'codex') { 'Ask Codex to do anything' + "`n" + 'GPT · Context 42% left' } else { '❯' + "`n" + '  ⏵⏵ bypass permissions on (shift+tab to cycle)' }
    if ($env:FAKE_CODEX_EMPTY -and $kind -eq 'codex' -and $resume) { $footer = 'Ask Codex to do anything' + "`n" + 'GPT · Context 100% left' }
    $status = $null; $screen = $footer
    switch ($mode) {
      'new' { $status = [pscustomobject]@{ app = $(if ($kind -eq 'codex') { 'codex' } else { 'claude-code' }); state = 'idle' }; $screen = $footer }
      'fail' { $screen = 'No conversation found to continue' + "`n" + 'PS C:\x>' }
      'dialog' { $screen = 'Do you want to proceed?' }
      'hang' { $screen = 'đang tải' }
    }
    $addr = "t$((Get-Content -LiteralPath (Join-Path $dir 'hc.log')).Count + 100)"
    $terms += [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 0; status = $status; argv = $argv; screen = $screen }
    & $saveTerms $terms
    [pscustomobject]@{ address = $addr; name = $name } | ConvertTo-Json; exit 0
  }
  default { exit 0 }
}
'@
$FakeHerdr = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
if ($args[0] -ne 'ls') { exit 0 }
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
$spaces = @($terms | Where-Object { $_.space } | ForEach-Object { [ordered]@{ id = $_.space; tabs = @([ordered]@{ id = $_.tab; terminals = @([ordered]@{ terminal = $_.address }) }) } })
ConvertTo-Json -InputObject ([ordered]@{ spaces = $spaces }) -Depth 8; exit 0
'@

function New-Ctx {
  $h = New-CrewTestHome
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $bin = Join-Path $TestDrive "bin-$tag"; $state = Join-Path $TestDrive "state-$tag"
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr))) {
    $text = $pair[1] -replace "`r`n", "`n"
    $file = Join-Path $bin $(if ($OnWindows) { "$($pair[0]).ps1" } else { $pair[0] })
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($true))
    if (-not $OnWindows) { [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($false)); & chmod +x $file }
  }
  $path = "$bin$([IO.Path]::PathSeparator)$env:PATH"
  $saved = $env:PATH
  try {
    $env:PATH = $path
    foreach ($c in 'hc', 'herdr-app') {
      $src = (Get-Command $c -CommandType ExternalScript, Application -ErrorAction Stop | Select-Object -First 1).Source
      if (-not $src.StartsWith($bin)) { throw "PATH test trỏ tới $c thật: $src" }
    }
  } finally { $env:PATH = $saved }
  @{ Home = $h; State = $state; Env = @{ PATH = $path; FAKE_HC_DIR = $state; FAKE_RESUME = 'ok'; FAKE_CODEX_EMPTY = $null; HC_SESSION = "crew-test-$tag"; HC_TERMINAL_ID = $null; HC_TERMINAL_SOCKET = $null } }
}
function New-Repo($ctx, [string]$name, $planner, $rev, $workers) {
  $root = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6))/$name"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path -LiteralPath $root).Path
  git -C $root init -q -b main
  git -C $root config core.autocrlf false
  '.crew/' | Set-Content -LiteralPath (Join-Path $root '.gitignore')
  git -C $root add -A
  git -C $root -c user.name=t -c user.email=t@t commit -q -m init
  Set-RepoCfg $root $name $planner $rev $workers
  $root
}
function Set-RepoCfg([string]$root, [string]$name, $planner, $rev, $workers) {
  [ordered]@{ name = $name; idKey = $name; planner = $planner; workers = @($workers); rev = $rev; review = 'lean'; access = 'wide' } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $root '.crew/config.json') -Encoding utf8
}
function Invoke-Crew($ctx, [string[]]$arguments, [string]$cwd) { Invoke-InTestHome -TestHome $ctx.Home -File $crewScript -Arguments $arguments -Env $ctx.Env -WorkingDirectory $cwd }
function Get-TermsFile($ctx) { Join-Path $ctx.State 'terminals.json' }
function Clear-Terms($ctx) { Remove-Item -LiteralPath (Get-TermsFile $ctx) -Force -ErrorAction SilentlyContinue; Clear-Log $ctx }
function Clear-Log($ctx) { foreach ($f in 'hc.log', 'cmds.log') { Remove-Item -LiteralPath (Join-Path $ctx.State $f) -Force -ErrorAction SilentlyContinue } }
function Get-Log($ctx, [string]$f) { $p = Join-Path $ctx.State $f; if (Test-Path -LiteralPath $p) { @(Get-Content -LiteralPath $p -Encoding utf8) } else { @() } }
# name -> lệnh agent (bỏ đoạn xóa biến phiên); nhiều lần bật ⇒ mảng theo thứ tự.
function Get-Cmds($ctx, [string]$name) { @(Get-Log $ctx 'cmds.log' | Where-Object { $_.StartsWith("$name|") } | ForEach-Object { ($_.Substring($name.Length + 1) -split '\}; ', 2)[-1] }) }
function Get-Sends($ctx) { @(Get-Log $ctx 'hc.log' | Where-Object { $_ -match '^send ' }) }
function Get-KeysLog($ctx) { @(Get-Log $ctx 'hc.log' | Where-Object { $_ -match '^keys ' }) }
function Get-Book([string]$root) { Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw -Encoding utf8 | ConvertFrom-Json }
function Set-LostPanes($ctx, [string]$root, [hashtable]$roles) {
  $terms = @(foreach ($k in $roles.Keys) {
      [pscustomobject]@{ name = $k; address = "t$(Get-Random -Minimum 2000 -Maximum 9000)"; state = 'live'; cwd = $roles[$k]; turn = 0; status = $null; screen = 'PS C:\x>'
        argv = @('pwsh.exe', '-NoExit', '-Command', '$global:__hc_prompt = $function:prompt; function global:prompt { }') }
    })
  ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath (Get-TermsFile $ctx) -Encoding utf8
  foreach ($f in 'hc.log', 'cmds.log') { Remove-Item -LiteralPath (Join-Path $ctx.State $f) -Force -ErrorAction SilentlyContinue }
}

$savedOutEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$pc = '--permission-mode bypassPermissions'
$px = '--no-daemon --sandbox danger-full-access --ask-for-approval never'
$uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

Describe 'crew up: lần đầu rồi khôi phục (hc giả)' {
  It 'mọi vai × agent: lần đầu hội thoại mới có prompt; terminal thiếu ⇒ mở lại đúng phiên, không kèm prompt, 0 tin' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'mix' 'claude' 'codex' @('claude', 'codex')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'mix-planner: hội thoại mới \(chưa có ghi nhận phiên\)'
    $r.Output | Should Match 'mix-w1: hội thoại mới'
    $r.Output | Should Match 'mix-w2: hội thoại mới'
    $r.Output | Should Match 'mix-rev: hội thoại mới'
    @(Get-Cmds $ctx 'mix-planner')[0] | Should Match "^claude $pc --session-id $uuid 'Bạn là planner"
    @(Get-Cmds $ctx 'mix-w1')[0] | Should Match "^claude $pc 'Bạn là worker w1"
    @(Get-Cmds $ctx 'mix-w2')[0] | Should Match "^codex $px 'Bạn là worker w2"
    @(Get-Cmds $ctx 'mix-rev')[0] | Should Match "^codex $px 'Bạn là rev"
    (Get-Log $ctx 'cmds.log')[0] | Should Match 'CLAUDE_CODE_CHILD_SESSION'
    $book = Get-Book $root
    $id = $book.roles.planner.sessionId
    $id | Should Match "^$uuid$"
    $book.roles.w1.PSObject.Properties.Name -contains 'sessionId' | Should Be $false
    @($book.codexRootRoles) -join ',' | Should Be 'rev'
    $bookText = Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw

    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    (Get-Cmds $ctx 'mix-planner') | Should BeExactly "claude $pc --resume $id"
    (Get-Cmds $ctx 'mix-w1') | Should BeExactly "claude $pc --continue"
    (Get-Cmds $ctx 'mix-w2') | Should BeExactly "codex resume --last $px"
    (Get-Cmds $ctx 'mix-rev') | Should BeExactly "codex resume --last $px"
    foreach ($n in 'planner', 'w1', 'w2', 'rev') { $r.Output | Should Match "mix-${n}: mở lại hội thoại" }
    @(Get-Sends $ctx).Count | Should Be 0
    @(Get-KeysLog $ctx).Count | Should Be 0
    (Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw) | Should BeExactly $bookText

    # chạy lại: pane đang mở lại chưa báo status vẫn là còn sống, không bật chồng, không gửi
    Clear-Log $ctx
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    @(Get-Log $ctx 'cmds.log').Count | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 0
  }
  It 'shell trống sau reboot (lost) ⇒ tắt pane, mở lại đúng phiên' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'lost' 'claude' 'none' @('codex')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    $id = (Get-Book $root).roles.planner.sessionId
    Set-LostPanes $ctx $root @{ 'lost-planner' = $root; 'lost-w1' = (Join-Path $root '.crew/worktrees/w1') }
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    @(Get-Log $ctx 'hc.log' | Where-Object { $_ -match '^kill ' }).Count | Should Be 2
    (Get-Cmds $ctx 'lost-planner') | Should BeExactly "claude $pc --resume $id"
    (Get-Cmds $ctx 'lost-w1') | Should BeExactly "codex resume --last $px"
    @(Get-Sends $ctx).Count | Should Be 0
  }
  It 'worker Codex/Claude có task dở: mở lại rồi nhận đúng 1 dòng tiếp tục task; lần hai 0 tin' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'dodang' 'none' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    $wt = Join-Path $root '.crew/worktrees/w1'
    git -C $wt switch -q -c crew/viec main
    New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
    'prompt' | Set-Content -LiteralPath (Join-Path $wt '.crew/prompt.md')
    $rec = [ordered]@{ name = 'viec'; branch = 'crew/viec'; worktree = $wt; worker = 1; terminal = 'dodang-w1'; agent = 'claude'; created = '2026-11-02T00:00:00' }
    ConvertTo-Json -InputObject @($rec) -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.crew/tasks.json') -Encoding utf8
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    (Get-Cmds $ctx 'dodang-w1') | Should BeExactly "claude $pc --continue"
    $sends = @(Get-Sends $ctx)
    $sends.Count | Should Be 1
    $sends[0] | Should Match 'Tiếp tục task viec'
    Clear-Log $ctx
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 0
  }
  It 'crew up -All: mở lại theo từng project' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'allp' 'none' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up', '-All') $root
    $r.ExitCode | Should Be 0
    (Get-Cmds $ctx 'allp-w1') | Should BeExactly "claude $pc --continue"
    $r.Output | Should Match 'allp-w1: mở lại hội thoại'
  }
}

Describe 'crew up: không chắc phiên thì hội thoại mới và nói rõ (hc giả)' {
  It 'hai vai Codex ở gốc: cả hai hội thoại mới, cảnh báo; worker vẫn mở lại' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'hai' 'codex' 'codex' @('codex')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    @(Get-Cmds $ctx 'hai-planner')[0] | Should Match "^codex $px 'Bạn là planner"
    @(Get-Cmds $ctx 'hai-rev')[0] | Should Match "^codex $px 'Bạn là rev"
    (Get-Cmds $ctx 'hai-w1') | Should BeExactly "codex resume --last $px"
    $r.Output | Should Match 'cảnh báo: hai-planner: hội thoại mới \(hai vai Codex'
    $r.Output | Should Match 'cảnh báo: hai-rev: hội thoại mới \(hai vai Codex'
  }
  It 'sổ hỏng: cảnh báo, hội thoại mới, exit 0, sổ được ghi lại' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'hong' 'claude' 'none' @('claude')
    [IO.File]::WriteAllText((Join-Path $root '.crew/sessions.json'), '{hỏng')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'sổ phiên .* hỏng'
    @(Get-Cmds $ctx 'hong-planner')[0] | Should Match '--session-id'
    @(Get-Cmds $ctx 'hong-w1')[0] | Should Match "'Bạn là worker"
    (Get-Book $root).roles.planner.agent | Should Be 'claude'
  }
  It 'đổi agent trong config: hội thoại mới theo agent mới, sổ cập nhật; lần sau mở lại' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'doi' 'claude' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Set-RepoCfg $root 'doi' 'codex' 'none' @('codex')
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'doi-planner: hội thoại mới \(đã đổi agent claude sang codex\)'
    @(Get-Cmds $ctx 'doi-planner')[0] | Should Match "^codex $px 'Bạn là planner"
    @(Get-Cmds $ctx 'doi-w1')[0] | Should Match "^codex $px 'Bạn là worker"
    (Get-Book $root).roles.planner.PSObject.Properties.Name -contains 'sessionId' | Should Be $false
    Clear-Terms $ctx
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    (Get-Cmds $ctx 'doi-planner') | Should BeExactly "codex resume --last $px"
  }
  It 'sổ ghi root khác: hội thoại mới' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'khac' 'none' 'none' @('claude')
    New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.crew/sessions.json'), '{"version":1,"roles":{"w1":{"agent":"claude","root":"C:/noi-khac"}},"codexRootRoles":[]}')
    $r = Invoke-Crew $ctx @('up') $root
    $r.Output | Should Match 'khac-w1: hội thoại mới \(sổ ghi root khác'
    @(Get-Cmds $ctx 'khac-w1')[0] | Should Match "'Bạn là worker"
  }
  It 'mở lại thất bại (CLI thoát về shell): tắt pane, hội thoại mới đúng 1 lần, cảnh báo nêu tên vai, UUID mới; không lặp' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'hu' 'claude' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    $old = (Get-Book $root).roles.planner.sessionId
    Clear-Terms $ctx
    $ctx.Env.FAKE_RESUME = 'fail'
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $pl = @(Get-Cmds $ctx 'hu-planner')
    $pl.Count | Should Be 2
    $pl[0] | Should BeExactly "claude $pc --resume $old"
    $pl[1] | Should Match "^claude $pc --session-id $uuid 'Bạn là planner"
    $pl[1] | Should Not Match $old
    $wk = @(Get-Cmds $ctx 'hu-w1')
    $wk.Count | Should Be 2
    $wk[0] | Should BeExactly "claude $pc --continue"
    $wk[1] | Should Match "^claude $pc 'Bạn là worker"
    @(Get-Log $ctx 'hc.log' | Where-Object { $_ -match '^kill ' }).Count | Should Be 2
    $r.Output | Should Match 'cảnh báo: hu-planner: hội thoại mới \(không mở lại được'
    $r.Output | Should Match 'cảnh báo: hu-w1: hội thoại mới \(không mở lại được'
    $new = (Get-Book $root).roles.planner.sessionId
    $new | Should Not Be $old
    $new | Should Match "^$uuid$"
    # lần sau mở lại đúng phiên mới
    $ctx.Env.FAKE_RESUME = 'ok'
    Clear-Terms $ctx
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    (Get-Cmds $ctx 'hu-planner') | Should BeExactly "claude $pc --resume $new"
  }
  It 'Codex không có phiên cũ, mở phiên trống: nói rõ là hội thoại mới' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'trong' 'none' 'none' @('codex')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Clear-Terms $ctx
    $ctx.Env.FAKE_CODEX_EMPTY = '1'
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    (Get-Cmds $ctx 'trong-w1') | Should BeExactly "codex resume --last $px"
    $r.Output | Should Match 'cảnh báo: trong-w1: hội thoại mới \(Codex không có phiên cũ'
    $r.Output | Should Not Match 'trong-w1: mở lại hội thoại'
  }
  It 'hộp thoại lạ khi mở lại: 0 phím, không bật chồng, không giao task' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'hop' 'none' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Clear-Terms $ctx
    $ctx.Env.FAKE_RESUME = 'dialog'
    $r = Invoke-Crew $ctx @('up') $root
    @(Get-Cmds $ctx 'hop-w1').Count | Should Be 1
    @(Get-KeysLog $ctx).Count | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 0
    $r.Output | Should Match 'hộp thoại'
  }
}

Describe 'crew up -Restart và -DryRun (hc giả)' {
  It '-Restart không resume dù sổ đủ; vai khác còn sống không đụng; UUID mới' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'rs' 'claude' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    $old = (Get-Book $root).roles.planner.sessionId
    Clear-Log $ctx
    $r = Invoke-Crew $ctx @('up', '-Restart', 'all') $root
    $r.ExitCode | Should Be 0
    @(Get-Cmds $ctx 'rs-planner')[0] | Should Match "^claude $pc --session-id $uuid 'Bạn là planner"
    @(Get-Cmds $ctx 'rs-w1')[0] | Should Match "^claude $pc 'Bạn là worker"
    (Get-Book $root).roles.planner.sessionId | Should Not Be $old
    $r.Output | Should Match 'rs-w1: hội thoại mới \(bật lại bằng -Restart\)'
    Clear-Log $ctx
    $r = Invoke-Crew $ctx @('up', '-Restart', 'w1') $root
    @(Get-Cmds $ctx 'rs-planner').Count | Should Be 0
    @(Get-Cmds $ctx 'rs-w1')[0] | Should Match "'Bạn là worker"
  }
  It '-Restart w1 khi vai khác thiếu terminal: vai thiếu cũng hội thoại mới' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'rt' 'claude' 'none' @('claude')
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up', '-Restart', 'w1') $root
    @(Get-Cmds $ctx 'rt-planner')[0] | Should Match '--session-id'
    $r.Output | Should Match 'rt-planner: hội thoại mới \(crew up -Restart không khôi phục'
  }
  It '-DryRun chỉ báo từng vai: không ghi sổ, không bật, không gửi; lần đầu và khôi phục' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'dry' 'claude' 'codex' @('claude')
    $r = Invoke-Crew $ctx @('up', '-DryRun') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'dry-planner: hội thoại mới \(chưa có ghi nhận phiên\)'
    Test-Path -LiteralPath (Join-Path $root '.crew/sessions.json') | Should Be $false
    @(Get-Log $ctx 'cmds.log').Count | Should Be 0

    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    $before = Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw
    Clear-Terms $ctx
    $r = Invoke-Crew $ctx @('up', '-DryRun') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'dry-planner: mở lại hội thoại'
    $r.Output | Should Match 'dry-w1: mở lại hội thoại'
    $r.Output | Should Match 'dry-rev: mở lại hội thoại'
    @(Get-Log $ctx 'cmds.log').Count | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 0
    (Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw) | Should BeExactly $before
  }
  It '-DryRun với sổ hỏng: cảnh báo, không throw, không sửa file' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'dh' 'none' 'none' @('claude')
    [IO.File]::WriteAllText((Join-Path $root '.crew/sessions.json'), 'rác')
    $r = Invoke-Crew $ctx @('up', '-DryRun') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'sổ phiên .* hỏng'
    (Get-Content -LiteralPath (Join-Path $root '.crew/sessions.json') -Raw) | Should Be 'rác'
  }
}

[Console]::OutputEncoding = $savedOutEnc
