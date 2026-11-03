# crew up -All và crew up tự khôi phục: e2e qua crew.ps1 thật trong HOME giả, hc + herdr-app giả đứng đầu PATH. Không gọi hc thật, không ghi ~/.crewline thật.
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Get-UpAllPlan', 'Get-UpChildResult', 'Format-UpAllSummary', 'ConvertTo-RootKey', 'Test-SamePath'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

$FakeHc = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
Add-Content -LiteralPath (Join-Path $dir 'hc.log') -Value ($args -join ' ') -Encoding utf8
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
switch ($args[0]) {
  'ls' { ConvertTo-Json -InputObject ([ordered]@{ terminals = @($terms) }) -Depth 6; exit 0 }
  'get' {
    $key = $args[1]  # $args trong Where-Object là của scriptblock đó
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
    $screen = Join-Path $dir 'screen.txt'
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
    if ($env:FAKE_HC_FAIL -and $cwd -like "*$($env:FAKE_HC_FAIL)*") { 'fake hc run lỗi'; exit 1 }
    $addr = "t$($terms.Count + 100)"
    $terms += [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' } }
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
if ($args[0] -ne 'ls') { exit 0 }
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
$spaces = @($terms | Where-Object { $_.space } | ForEach-Object { [ordered]@{ id = $_.space; tabs = @([ordered]@{ id = $_.tab; terminals = @([ordered]@{ terminal = $_.address }) }) } })
ConvertTo-Json -InputObject ([ordered]@{ spaces = $spaces }) -Depth 8; exit 0
'@

# Dựng HOME giả + thư mục CLI giả; dừng ngay nếu PATH chưa trỏ hc/herdr-app giả (không bao giờ tới hc thật).
function New-Ctx {
  $h = New-CrewTestHome
  $bin = Join-Path $TestDrive "bin-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  $state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr))) {
    # .gitattributes giữ *.ps1 ở CRLF; CR ở dòng shebang làm env không tìm thấy pwsh trên Unix.
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
      $src = (Get-Command $c -ErrorAction Stop | Select-Object -First 1).Source
      if (-not $src.StartsWith($bin)) { throw "PATH test trỏ tới $c thật: $src" }
    }
  } finally { $env:PATH = $saved }
  @{ Home = $h; State = $state; Env = @{ PATH = $path; FAKE_HC_DIR = $state; FAKE_HC_FAIL = $null; HC_SESSION = "crew-test-$([guid]::NewGuid().ToString('N'))"; HC_TERMINAL_ID = $null; HC_TERMINAL_SOCKET = $null } }
}

# Repo git thật + .crew/config.json. $name/$key rỗng ⇒ config kiểu cũ thiếu khóa đó.
function New-Repo($ctx, [string]$rel, [string]$name = '', [string]$key = '') {
  $root = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6))/$rel"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path -LiteralPath $root).Path
  git -C $root init -q -b main
  git -C $root config core.autocrlf false
  '.crew/' | Set-Content -LiteralPath (Join-Path $root '.gitignore')
  git -C $root add -A
  git -C $root -c user.name=t -c user.email=t@t commit -q -m init
  $cfg = [ordered]@{}
  if ($name) { $cfg.name = $name }
  if ($key) { $cfg.idKey = $key }
  $cfg.planner = 'none'; $cfg.workers = @('claude'); $cfg.rev = 'none'; $cfg.review = 'lean'; $cfg.access = 'work'
  $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.crew/config.json') -Encoding utf8
  $root
}

function Get-RegPath($ctx) { Join-Path $ctx.Home.Home '.crewline/projects.json' }
# $entries: mảng @(tên, root, idKey) theo thứ tự ghi vào sổ
function Set-Reg($ctx, $entries) {
  $o = [ordered]@{}
  foreach ($e in $entries) { $o[$e[0]] = [ordered]@{ root = $e[1]; idKey = $e[2] } }
  $f = Get-RegPath $ctx
  New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
}
function Get-Reg($ctx) { Get-Content -LiteralPath (Get-RegPath $ctx) -Raw -Encoding utf8 | ConvertFrom-Json }
function Set-Terms($ctx, $terms) {
  ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath (Join-Path $ctx.State 'terminals.json') -Encoding utf8
}
function New-Term([string]$name, [string]$addr, [string]$cwd) {
  [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' } }
}
function Get-HcLog($ctx) {
  $f = Join-Path $ctx.State 'hc.log'
  if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding utf8) } else { @() }
}
function Get-Written($ctx) { @(Get-HcLog $ctx | Where-Object { $_ -match '^(run|send|keys|kill|rm)\b' }) }
function Invoke-Crew($ctx, [string[]]$arguments, [string]$cwd) {
  $wd = if ($cwd) { $cwd } else { $ctx.Home.Home }
  Invoke-InTestHome -TestHome $ctx.Home -File $crewScript -Arguments $arguments -Env $ctx.Env -WorkingDirectory $wd
}
# Ảnh chụp mọi file (đường dẫn + hash) dưới các thư mục, bỏ .git (git status tự làm mới index).
function Get-Snapshot([string[]]$dirs) {
  @(foreach ($d in $dirs) {
      if (Test-Path -LiteralPath $d) {
        Get-ChildItem -LiteralPath $d -Recurse -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } | ForEach-Object {
          if ($_.PSIsContainer) { $_.FullName } else { "$($_.FullName) $((Get-FileHash -LiteralPath $_.FullName).Hash)" }
        }
      } else { "thiếu $d" }
    }) -join "`n"
}
# Dòng tổng kết của một project (sau tiêu đề == tổng kết)
function Get-SummaryRow([string]$output, [string]$root) {
  $tail = ($output -split '== tổng kết crew up -All')[-1]
  @($tail -split '\r?\n' | Where-Object { $_.Contains($root) }) -join "`n"
}

$savedOutEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Describe 'Get-UpAllPlan' {
  $mk = {
    param($r)
    $map = [ordered]@{}
    foreach ($k in $r.Keys) { $map[$k] = @{ Root = $r[$k]; IdKey = $k } }
    $map
  }
  It 'mục mất thư mục hoặc mất config -> bỏ qua kèm lý do, mục còn config không bỏ qua' {
    $ok = Join-Path $TestDrive 'plan/ok'; New-Item -ItemType Directory -Force (Join-Path $ok '.crew') | Out-Null
    '{}' | Set-Content (Join-Path $ok '.crew/config.json')
    $noCfg = Join-Path $TestDrive 'plan/nocfg'; New-Item -ItemType Directory -Force $noCfg | Out-Null
    $plan = Get-UpAllPlan (& $mk ([ordered]@{ a = $ok; b = $noCfg; c = (Join-Path $TestDrive 'plan/mat') })) ''
    @($plan).Count | Should Be 3
    $plan[0].Skip | Should Be ''
    $plan[1].Skip | Should Match 'config.json'
    $plan[2].Skip | Should Match 'thư mục không còn'
    Test-Path (Join-Path $TestDrive 'plan/mat') | Should Be $false
  }
  It 'project hiện tại chưa có trong sổ -> thêm cuối; đã có (khác dấu tách) -> không trùng' {
    $ok = Join-Path $TestDrive 'plan2/ok'; New-Item -ItemType Directory -Force (Join-Path $ok '.crew') | Out-Null
    '{}' | Set-Content (Join-Path $ok '.crew/config.json')
    $cur = Join-Path $TestDrive 'plan2/hien tai'
    $two = Get-UpAllPlan (& $mk ([ordered]@{ a = $ok })) $cur
    @($two).Count | Should Be 2
    $two[1].Root | Should Be $cur
    $two[1].Name | Should Be 'hien tai'
    $same = Get-UpAllPlan (& $mk ([ordered]@{ a = $ok })) "$ok/"
    $same.Count | Should Be 1
  }
  It 'sổ rỗng, không có project hiện tại -> mảng rỗng' {
    $none = Get-UpAllPlan ([ordered]@{}) ''
    $none.Count | Should Be 0
  }
}

Describe 'Get-UpChildResult + Format-UpAllSummary' {
  It 'exit 0 = ok; exit 1 có dòng kết luận = cần người quyết; còn lại = lỗi' {
    Get-UpChildResult 0 'x' | Should Be 'ok'
    Get-UpChildResult 1 "== kết luận`n  CẦN NGƯỜI QUYẾT: y" | Should Be 'cần người quyết'
    Get-UpChildResult 1 'crew: LỖI: z' | Should Be 'lỗi'
    Get-UpChildResult 1 'terminal ghi CẦN NGƯỜI QUYẾT: giữa dòng' | Should Be 'lỗi'
  }
  It 'bảng có tiêu đề, đường dẫn dấu cách và lý do' {
    $lines = @(Format-UpAllSummary @(@{ Name = 'a'; Root = 'C:\project trackerlio'; Result = 'ok'; Note = '' }, @{ Name = 'bb'; Root = 'D:\x'; Result = 'bỏ qua'; Note = 'thư mục không còn' }))
    $lines.Count | Should Be 3
    $lines[0] | Should Match 'tên\s+đường dẫn\s+kết quả'
    $lines[1] | Should Match 'C:\\project trackerlio\s+ok$'
    $lines[2] | Should Match 'bỏ qua: thư mục không còn$'
  }
}

Describe 'crew up -All (hc giả)' {
  It 'trộn ok, lỗi, cần người quyết, bỏ qua: project lỗi không chặn project sau, exit 1, sổ giữ nguyên' {
    $ctx = New-Ctx
    $ctx.Env.FAKE_HC_FAIL = 'boomdir'
    $boom = New-Repo $ctx 'boomdir' 'boom' 'boom'
    $hum = New-Repo $ctx 'hum' 'hum' 'hum'
    $spaced = New-Repo $ctx 'project trackerlio' 'project-trac' 'projecttrac'
    $gone = Join-Path $TestDrive 'mat-roi/gone'
    $noCfg = Join-Path $TestDrive 'nocfg-dir'; New-Item -ItemType Directory -Force $noCfg | Out-Null
    Set-Reg $ctx @(@('boom', $boom, 'boom'), @('gone', $gone, 'gone'), @('hum', $hum, 'hum'), @('nocfg', $noCfg, 'nocfg'), @('project-trac', $spaced, 'projecttrac'))
    Set-Terms $ctx @(New-Term 'hum-w1' 't90' (Join-Path $TestDrive 'noi-khac'))
    $r = Invoke-Crew $ctx @('up', '-All')
    $r.ExitCode | Should Be 1
    Get-SummaryRow $r.Output $boom | Should Match 'lỗi'
    Get-SummaryRow $r.Output $hum | Should Match 'cần người quyết'
    Get-SummaryRow $r.Output $spaced | Should Match '  ok$'
    Get-SummaryRow $r.Output $gone | Should Match 'bỏ qua: thư mục không còn'
    Get-SummaryRow $r.Output $noCfg | Should Match 'bỏ qua: không còn \.crew/config\.json'
    # project sau project lỗi vẫn chạy, đường dẫn có dấu cách tới đúng worktree
    $run = @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name project-trac-w1' })
    $run.Count | Should Be 1
    $run[0] | Should Match ([regex]::Escape((Join-Path $spaced '.crew/worktrees/w1')))
    # mục bỏ qua còn nguyên trong sổ, không tạo gì trong thư mục đó
    $reg = Get-Reg $ctx
    $reg.gone.root | Should Be $gone
    $reg.nocfg.root | Should Be $noCfg
    Test-Path -LiteralPath $gone | Should Be $false
    @(Get-ChildItem -LiteralPath $noCfg -Force).Count | Should Be 0
  }

  It 'chỉ có ok và bỏ qua -> exit 0' {
    $ctx = New-Ctx
    $a = New-Repo $ctx 'aa' 'aa' 'aa'
    Set-Reg $ctx @(@('aa', $a, 'aa'), @('gone', (Join-Path $TestDrive 'khong-co'), 'gone'))
    $r = Invoke-Crew $ctx @('up', '-All')
    $r.ExitCode | Should Be 0
    Get-SummaryRow $r.Output $a | Should Match '  ok$'
  }

  It 'đứng trong project cũ chưa có trong sổ (từ thư mục con và worktree) -> được khôi phục, ghi tên vào config và sổ theo slug cũ' {
    $ctx = New-Ctx
    $a = New-Repo $ctx 'aa' 'aa' 'aa'
    Set-Reg $ctx @(, @('aa', $a, 'aa'))
    $old = New-Repo $ctx 'project trackerlio'
    New-Item -ItemType Directory -Force (Join-Path $old 'src') | Out-Null
    $r = Invoke-Crew $ctx @('up', '-All') (Join-Path $old 'src')
    $r.ExitCode | Should Be 0
    Get-SummaryRow $r.Output $old | Should Match '  ok$'
    $cfg = Get-Content -LiteralPath (Join-Path $old '.crew/config.json') -Raw | ConvertFrom-Json
    $cfg.name | Should BeExactly 'project-trac'
    $cfg.idKey | Should BeExactly 'projecttrac'
    (Get-Reg $ctx).'project-trac'.idKey | Should BeExactly 'projecttrac'
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name project-trac-w1 .*herdr\.space=spcrewprojecttrac' }).Count | Should Be 1
    # lần sau đứng trong worktree của nó: đã có trong sổ, không chạy lặp
    $wt = Join-Path $old '.crew/worktrees/w1'
    $again = Invoke-Crew $ctx @('up', '-All') $wt
    $again.ExitCode | Should Be 0
    @((($again.Output -split '== tổng kết crew up -All')[0]) -split '\r?\n' | Where-Object { $_ -match '^== ' }).Count | Should Be 2
  }

  It '-DryRun: không ghi sổ/config/worktree, không bật, không gửi; project cũ chỉ báo sẽ ghi' {
    $ctx = New-Ctx
    $a = New-Repo $ctx 'aa' 'aa' 'aa'
    $old = New-Repo $ctx 'project trackerlio'
    $gone = Join-Path $TestDrive 'mat-dry/gone'
    Set-Reg $ctx @(@('aa', $a, 'aa'), @('gone', $gone, 'gone'))
    $before = Get-Snapshot @($a, $old, (Join-Path $ctx.Home.Home '.crewline'))
    $r = Invoke-Crew $ctx @('up', '-All', '-DryRun') $old
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'sẽ ghi name ''project-trac'''
    Get-SummaryRow $r.Output $old | Should Match '  ok$'
    Get-Snapshot @($a, $old, (Join-Path $ctx.Home.Home '.crewline')) | Should Be $before
    @(Get-Written $ctx).Count | Should Be 0
    Test-Path -LiteralPath $gone | Should Be $false
  }

  It 'sổ hỏng -> báo lỗi, không ghi đè, exit 1, không chạy project hiện tại' {
    $ctx = New-Ctx
    $cur = New-Repo $ctx 'cur' 'cur' 'cur'
    $f = Get-RegPath $ctx
    New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
    [IO.File]::WriteAllText($f, '{ hong')
    $r = Invoke-Crew $ctx @('up', '-All') $cur
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'hỏng'
    [IO.File]::ReadAllText($f) | Should BeExactly '{ hong'
    @(Get-HcLog $ctx).Count | Should Be 0
  }

  It 'sổ trống, thư mục ngoài project -> exit 0, không gọi hc' {
    $ctx = New-Ctx
    $r = Invoke-Crew $ctx @('up', '-All')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'không có gì để khôi phục'
    @(Get-HcLog $ctx).Count | Should Be 0
  }

  foreach ($cmd in 'repair', 'hot', 'upgrade') {
    It "-All với crew $cmd -> lỗi rõ, không gọi hc" {
      $ctx = New-Ctx
      $cur = New-Repo $ctx 'cur' 'cur' 'cur'
      $r = Invoke-Crew $ctx @($cmd, '-All') $cur
      $r.ExitCode | Should Be 1
      $r.Output | Should Match '-All chỉ dùng với crew up'
      @(Get-HcLog $ctx).Count | Should Be 0
    }
  }
}

Describe 'crew repair / crew up -Restart giữ hành vi, tự ghi sổ project cũ (hc giả)' {
  It 'crew repair không -All chỉ đụng project của nó, exit theo kết luận, bảng tổng kết không in' {
    $ctx = New-Ctx
    $a = New-Repo $ctx 'aa' 'aa' 'aa'
    $b = New-Repo $ctx 'bb' 'bb' 'bb'
    Set-Reg $ctx @(@('aa', $a, 'aa'), @('bb', $b, 'bb'))
    $r = Invoke-Crew $ctx @('repair') $b
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'tổng kết crew up -All'
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run ' -and $_ -match '--name aa-' }).Count | Should Be 0
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run ' -and $_ -match '--name bb-w1' }).Count | Should Be 1
  }

  It 'crew up project cũ -> ghi name/idKey cũ + sổ, terminal và space giữ tên cũ' {
    $ctx = New-Ctx
    $old = New-Repo $ctx 'my-app'
    $r = Invoke-Crew $ctx @('up') $old
    $r.ExitCode | Should Be 0
    $cfg = Get-Content -LiteralPath (Join-Path $old '.crew/config.json') -Raw | ConvertFrom-Json
    $cfg.name | Should BeExactly 'my-app'
    $cfg.idKey | Should BeExactly 'myapp'
    (Get-Reg $ctx).'my-app'.idKey | Should BeExactly 'myapp'
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name my-app-w1 .*herdr\.space=spcrewmyapp\b' }).Count | Should Be 1
  }

  It 'crew repair project cũ trùng tên project khác, terminal đang sống -> chỉ cảnh báo, exit 0, giữ chủ cũ trong sổ, không kill' {
    $ctx = New-Ctx
    $owner = New-Repo $ctx 'app' 'app' 'app'
    Set-Reg $ctx @(, @('app', $owner, 'app'))
    $copy = New-Repo $ctx 'app'
    Set-Terms $ctx @(New-Term 'app-w1' 't50' (Join-Path $copy '.crew/worktrees/w1'))
    $r = Invoke-Crew $ctx @('repair') $copy
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'cảnh báo: tên ''app''/idKey ''app'' đã thuộc project'
    (Get-Reg $ctx).app.root | Should Be $owner
    @(Get-Written $ctx).Count | Should Be 0
  }

  It 'project đã chuyển, config thiếu idKey: -Restart vẫn báo chuyển, không xóa dấu vết sổ; crew up cập nhật sổ sang root mới' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'moved' 'app' ''
    $gone = Join-Path $TestDrive 'root-cu/moved'
    Set-Reg $ctx @(, @('app', $gone, 'app'))
    $up = Invoke-Crew $ctx @('up', '-Restart', 'w1') $root
    $up.ExitCode | Should Be 1
    $up.Output | Should Match 'project đã chuyển từ'
    (Get-Reg $ctx).app.root | Should Be $gone
    (Get-Content -LiteralPath (Join-Path $root '.crew/config.json') -Raw | ConvertFrom-Json).idKey | Should BeExactly 'app'
    @(Get-Written $ctx).Count | Should Be 0
    $rep = Invoke-Crew $ctx @('up') $root
    $rep.ExitCode | Should Be 0
    $rep.Output | Should Match 'project đã chuyển'
    (Get-Reg $ctx).app.root | Should Be $root
  }

  It 'crew repair -DryRun project cũ không ghi config, không ghi sổ' {
    $ctx = New-Ctx
    $old = New-Repo $ctx 'my-app'
    $cfgFile = Join-Path $old '.crew/config.json'
    $before = [IO.File]::ReadAllText($cfgFile)
    $r = Invoke-Crew $ctx @('repair', '-DryRun') $old
    $r.ExitCode | Should Be 0
    [IO.File]::ReadAllText($cfgFile) | Should BeExactly $before
    Test-Path -LiteralPath (Get-RegPath $ctx) | Should Be $false
    @(Get-Written $ctx).Count | Should Be 0
  }
}

# Task dở thật: nhánh crew/<tên> trên w1, prompt, tasks.json. Trả tên terminal.
function Add-OpenTask($ctx, [string]$root, [string]$slug, [string]$task) {
  $wt = Join-Path $root '.crew/worktrees/w1'
  git -C $root worktree add -q --detach $wt main
  git -C $wt switch -q -c "crew/$task"
  New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
  'prompt' | Set-Content -LiteralPath (Join-Path $wt '.crew/prompt.md')
  $rec = [ordered]@{ name = $task; branch = "crew/$task"; worktree = $wt; worker = 1; terminal = "$slug-w1"; agent = 'claude'; created = '2026-11-02T00:00:00' }
  ConvertTo-Json -InputObject @($rec) -Depth 5 | Set-Content -LiteralPath (Join-Path $root '.crew/tasks.json') -Encoding utf8
}
function Get-Sends($ctx) { @(Get-HcLog $ctx | Where-Object { $_ -match '^send ' }) }

Describe 'crew up tự khôi phục (hc giả)' {
  It 'project mới: dựng đủ space/tab, lần hai không làm gì và gửi 0 tin' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'fresh' 'fresh' 'fresh'
    $first = Invoke-Crew $ctx @('up') $root
    $first.ExitCode | Should Be 0
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name fresh-w1' }).Count | Should Be 1
    $herdr = Get-Content -LiteralPath (Join-Path $ctx.State 'herdr.log') -Encoding utf8
    @($herdr | Where-Object { $_ -match '^do space\.rename .*crew:fresh' }).Count | Should Be 1
    @($herdr | Where-Object { $_ -match '^do tab\.rename ' }).Count | Should Be 1
    $written = @(Get-Written $ctx).Count
    $second = Invoke-Crew $ctx @('up') $root
    $second.ExitCode | Should Be 0
    $second.Output | Should Match 'không có gì phải sửa'
    @(Get-Written $ctx).Count | Should Be $written
    @(Get-Sends $ctx).Count | Should Be 0
  }

  It 'worker thiếu + task dở -> bật lại, giao lại đúng 1 tin; lần hai 0 tin' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'dang lam' 'danglam' 'danglam'
    Add-OpenTask $ctx $root 'danglam' 'viec-do'
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'chạy crew repair'
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name danglam-w1' }).Count | Should Be 1
    $sends = @(Get-Sends $ctx)
    $sends.Count | Should Be 1
    $sends[0] | Should Match '^send danglam-w1 .*viec-do'
    $again = Invoke-Crew $ctx @('up') $root
    $again.ExitCode | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 1
  }

  It 'worker thiếu + task đã xong -> up/repair/DryRun không gửi, exit 0, báo rõ; status có nhãn, không đọc thêm pane' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'xong' 'xong' 'xong'
    Add-OpenTask $ctx $root 'xong' 'viec-xong'
    $wt = Join-Path $root '.crew/worktrees/w1'
    # chưa xong: status không có nhãn
    (Invoke-Crew $ctx @('up') $root).ExitCode | Should Be 0
    @(Get-Sends $ctx).Count | Should Be 1
    $readsOf = { @(Get-HcLog $ctx | Where-Object { $_ -match '^read ' }).Count }
    $r0 = & $readsOf
    (Invoke-Crew $ctx @('status') $root).Output | Should Not Match 'đã xong, chờ planner'
    $perStatus = (& $readsOf) - $r0
    New-Item -ItemType Directory -Force (Join-Path $wt 'context/tasks') | Out-Null
    'note' | Set-Content -LiteralPath (Join-Path $wt 'context/tasks/viec-xong.md')
    git -C $wt add -A
    git -C $wt -c user.name=t -c user.email=t@t commit -q -m xong
    $r1 = & $readsOf
    (Invoke-Crew $ctx @('status') $root).Output | Should Match 'viec-xong.*đã xong, chờ planner'
    ((& $readsOf) - $r1) | Should Be $perStatus
    # đã gửi Rev: đang chờ Rev, không phải chờ planner
    $tf = Join-Path $root '.crew/tasks.json'
    $plain = Get-Content -LiteralPath $tf -Raw -Encoding utf8
    $sentRec = @($plain | ConvertFrom-Json | ForEach-Object { $_ })
    $sentRec[0] | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue '2026-11-03T00:00:00' -Force
    ConvertTo-Json -InputObject $sentRec -Depth 5 | Set-Content -LiteralPath $tf -Encoding utf8
    (Invoke-Crew $ctx @('status') $root).Output | Should Not Match 'đã xong, chờ planner'
    Set-Content -LiteralPath $tf -Value $plain -Encoding utf8 -NoNewline
    $sent = @(Get-Sends $ctx).Count
    # mất terminal: cùng kết luận ở cả ba đường
    Set-Terms $ctx @()
    $dry = Invoke-Crew $ctx @('up', '-DryRun') $root
    $dry.ExitCode | Should Be 0
    $dry.Output | Should Match 'task viec-xong có vẻ đã xong, không giao lại; còn việc thì: crew send xong-w1'
    $dry.Output | Should Not Match 'giao lại task viec-xong ->'
    @(Get-Sends $ctx).Count | Should Be $sent
    $up = Invoke-Crew $ctx @('up') $root
    $up.ExitCode | Should Be 0
    $up.Output | Should Match 'task viec-xong có vẻ đã xong'
    $up.Output | Should Not Match 'CẦN NGƯỜI QUYẾT'
    @(Get-Sends $ctx).Count | Should Be $sent
    Set-Terms $ctx @()
    $rep = Invoke-Crew $ctx @('repair') $root
    $rep.ExitCode | Should Be 0
    $rep.Output | Should Match 'task viec-xong có vẻ đã xong'
    @(Get-Sends $ctx).Count | Should Be $sent
  }

  It 'shell trống sau reboot + task dở -> tắt pane cũ, bật lại, giao lại đúng 1 tin' -Skip:(-not $OnWindows) {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'reboot' 'reboot' 'reboot'
    Add-OpenTask $ctx $root 'reboot' 'viec-do'
    $wt = Join-Path $root '.crew/worktrees/w1'
    Set-Terms $ctx @([pscustomobject]@{ name = 'reboot-w1'; address = 't40'; state = 'live'; cwd = $wt; turn = 0; status = $null; argv = @('pwsh', '-NoExit', '-Command', '__hc_prompt') })
    [IO.File]::WriteAllText((Join-Path $ctx.State 'screen.txt'), 'PS C:\x>')
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    @(Get-HcLog $ctx | Where-Object { $_ -match '^kill t40' }).Count | Should Be 1
    @(Get-Sends $ctx).Count | Should Be 1
  }

  It 'chạy lại khi agent vừa bật chưa báo status -> không báo agent đã thoát, exit 0' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'starting' 'starting' 'starting'
    Set-Terms $ctx @([pscustomobject]@{ name = 'starting-w1'; address = 't41'; state = 'live'; cwd = (Join-Path $root '.crew/worktrees/w1'); turn = 0; status = $null; argv = @('pwsh', '-NoExit', '-EncodedCommand', 'x') })
    git -C $root worktree add -q --detach (Join-Path $root '.crew/worktrees/w1') main
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'agent đang khởi động'
    $r.Output | Should Not Match 'CẦN NGƯỜI QUYẾT'
    @(Get-Written $ctx).Count | Should Be 0
  }

  It 'worker đang chờ duyệt có task -> in việc cần người quyết, exit 1, 0 tin' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'duyet' 'duyet' 'duyet'
    Add-OpenTask $ctx $root 'duyet' 'viec-do'
    Set-Terms $ctx @([pscustomobject]@{ name = 'duyet-w1'; address = 't42'; state = 'live'; cwd = (Join-Path $root '.crew/worktrees/w1'); turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'blocked' } })
    $r = Invoke-Crew $ctx @('up') $root
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'CẦN NGƯỜI QUYẾT:.*chờ duyệt'
    @(Get-Written $ctx).Count | Should Be 0
  }

  It '-DryRun: báo sẽ làm, không ghi, không bật, không gửi' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'my-app'
    Add-OpenTask $ctx $root 'my-app' 'viec-do'
    $before = Get-Snapshot @($root, (Join-Path $ctx.Home.Home '.crewline'))
    $r = Invoke-Crew $ctx @('up', '-DryRun') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'sẽ ghi name ''my-app'''
    $r.Output | Should Match '\(sẽ làm\) bật terminal thiếu'
    $r.Output | Should Match '\(sẽ làm\) giao lại task viec-do'
    Get-Snapshot @($root, (Join-Path $ctx.Home.Home '.crewline')) | Should Be $before
    @(Get-Written $ctx).Count | Should Be 0
  }

  It 'chép nguyên thư mục (tên đã thuộc project khác còn tồn tại) -> crew up vẫn dừng, 0 bật' {
    $ctx = New-Ctx
    $owner = New-Repo $ctx 'app' 'app' 'app'
    Set-Reg $ctx @(, @('app', $owner, 'app'))
    $copy = New-Repo $ctx 'app' 'app' 'app'
    $r = Invoke-Crew $ctx @('up') $copy
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'crew init -Name'
    @(Get-Written $ctx).Count | Should Be 0
  }

  It '-Restart: vẫn tắt và bật lại đúng terminal, không qua khôi phục; -Restart với -All hoặc -DryRun bị từ chối' {
    $ctx = New-Ctx
    $root = New-Repo $ctx 'rs' 'rs' 'rs'
    $wt = Join-Path $root '.crew/worktrees/w1'
    git -C $root worktree add -q --detach $wt main
    Set-Terms $ctx @(New-Term 'rs-w1' 't43' $wt)
    $r = Invoke-Crew $ctx @('up', '-Restart', 'w1') $root
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match '== kết luận'
    @(Get-HcLog $ctx | Where-Object { $_ -match '^kill t43' }).Count | Should Be 1
    @(Get-HcLog $ctx | Where-Object { $_ -match '^run .*--name rs-w1' }).Count | Should Be 1
    $n = @(Get-Written $ctx).Count
    $all = Invoke-Crew $ctx @('up', '-All', '-Restart', 'w1') $root
    $all.ExitCode | Should Be 1
    $all.Output | Should Match '-All không đi với -Restart'
    $dry = Invoke-Crew $ctx @('up', '-DryRun', '-Restart', 'w1') $root
    $dry.ExitCode | Should Be 1
    $dry.Output | Should Match '-DryRun không đi với -Restart'
    @(Get-Written $ctx).Count | Should Be $n
  }
}

[Console]::OutputEncoding = $savedOutEnc
