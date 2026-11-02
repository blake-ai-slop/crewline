# crew up init: CLI thật, HOME và hc/herdr giả.
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
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
    $encIndex = [array]::IndexOf($args, '-EncodedCommand')
    $commandLine = if ($encIndex -ge 0) { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($args[$encIndex + 1])) } else { '' }
    $addr = "t$($terms.Count + 100)"
    $terms += [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; space = $space; tab = $tab; turn = 1; status = [pscustomobject]@{ app = $(if ($commandLine -match '(^|\}; )codex ') { 'codex' } else { 'claude-code' }); state = 'idle' } }
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

function Run-Up($c, $argv, $inputText = '') {
  Invoke-InTestHome -TestHome $c.Home -File $crewScript -Arguments $argv -Env $c.Env -InputText $inputText
}
function Assert-NoInit($c, $dir, $git = $false, $count = 0) {
  Test-Path (Join-Path $dir '.git') | Should Be $git
  foreach ($n in 'context','.crew','CLAUDE.md','AGENTS.md','.gitignore') { Test-Path (Join-Path $dir $n) | Should Be $false }
  if ($count) { @(git -C $dir log --oneline).Count | Should Be $count }
  foreach ($n in 'hc.log','herdr.log') { Test-Path (Join-Path $c.State $n) | Should Be $false }
}
$savedUpEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Describe 'crew up init' {
  BeforeEach {
    $c = New-Ctx
    $c.Env.CREWLINE_DEFAULTS = ''
    Set-Content (Join-Path $c.Home.Home 'gitconfig') "[user]`n name = t`n email = t@t`n[core]`n autocrlf = false"
    $dir = Join-Path $c.Home.Home 'project with spaces'
    New-Item -ItemType Directory $dir | Out-Null
    Set-Content (Join-Path $dir 'note.txt') 'existing'
  }
  It 'repo co commit: Enter init standard, du space/tab, lan hai khong hoi' {
    git -C $dir init -qb main
    git -C $dir -c user.name=t -c user.email=t@t commit -qm init --allow-empty
    $r = Run-Up $c @('up','-Path',$dir) "`n"
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Lựa chọn \[1\]'
    foreach ($n in $dir,'context/','CLAUDE.md','AGENTS.md','.crew/','.gitignore') { $r.Output | Should Match ([regex]::Escape($n)) }
    $terms = @(Get-Content (Join-Path $c.State 'terminals.json') -Raw | ConvertFrom-Json)
    $terms.Count | Should Be 4
    @($terms | Where-Object { -not $_.space -or -not $_.tab }).Count | Should Be 0
    $log = Get-Content (Join-Path $c.State 'herdr.log') -Raw
    foreach ($n in 'space.rename','tab.rename.*planner','tab.rename.*workers','tab.rename.*rev') { $log | Should Match $n }
    $r = Run-Up $c @('up','-Path',$dir) "2`n"
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'Lựa chọn'
  }
  It 'chua git: mac dinh Thoi, mot cau, khong tao' {
    $r = Run-Up $c @('up','-Path',$dir) "`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'git init.*commit TẤT CẢ'
    $r.Output | Should Match 'Lựa chọn \[2\]'
    ([regex]::Matches($r.Output,'Lựa chọn')).Count | Should Be 1
    Assert-NoInit $c $dir
  }
  It 'chua git: Co mot cau, commit file cu, Team solo' {
    New-Item -ItemType Directory (Join-Path $c.Home.Home '.crewline') | Out-Null
    '{"team":"large"}' | Set-Content (Join-Path $c.Home.Home '.crewline/config.json')
    $r = Run-Up $c @('up','-Path',$dir,'-Team','solo') "Có`n"
    $r.ExitCode | Should Be 0
    ([regex]::Matches($r.Output,'Lựa chọn')).Count | Should Be 1
    @(git -C $dir log --oneline).Count | Should Be 2
    git -C $dir ls-files note.txt | Should Be 'note.txt'
    (Get-Content (Join-Path $dir '.crew/config.json') -Raw | ConvertFrom-Json).rev | Should Be 'none'
  }
  It 'khong Team: dung day du vai trong config ca nhan truoc ten mau' {
    New-Item -ItemType Directory (Join-Path $c.Home.Home '.crewline') | Out-Null
    '{"team":"large","planner":"none","workers":["claude"],"rev":"none"}' | Set-Content (Join-Path $c.Home.Home '.crewline/config.json')
    $r = Run-Up $c @('up','-Path',$dir) "1`n"
    $r.ExitCode | Should Be 0
    $cfg = Get-Content (Join-Path $dir '.crew/config.json') -Raw | ConvertFrom-Json
    $cfg.planner | Should Be 'none'
    @($cfg.workers).Count | Should Be 1
    $cfg.rev | Should Be 'none'
  }
  It 'repo chua commit: Thoi khong tao commit; Co khong hoi lan hai' {
    git -C $dir init -qb main
    $r = Run-Up $c @('up','-Path',$dir) "2`n"
    $r.ExitCode | Should Be 1
    Assert-NoInit $c $dir $true
    git -C $dir rev-parse --verify -q HEAD
    $LASTEXITCODE | Should Be 1
    $r = Run-Up $c @('up','-Path',$dir,'-Team','solo') "1`n"
    $r.ExitCode | Should Be 0
    ([regex]::Matches($r.Output,'Lựa chọn')).Count | Should Be 1
  }
  It 'repo co commit: Thoi giu nguyen commit' {
    git -C $dir init -qb main
    git -C $dir -c user.name=t -c user.email=t@t commit -qm init --allow-empty
    $r = Run-Up $c @('up','-Path',$dir) "2`n"
    $r.ExitCode | Should Be 1
    Assert-NoInit $c $dir $true 1
  }
  It 'DEFAULTS khong hoi khong tao' {
    $c.Env.CREWLINE_DEFAULTS = '1'
    $r = Run-Up $c @('up','-Path',$dir) "1`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Not Match 'Lựa chọn'
    $r.Output | Should Match 'crew init'
    Assert-NoInit $c $dir
  }
  It 'EOF khong tao' {
    $wrap = Join-Path $c.Home.Home 'eof.ps1'
    Set-Content $wrap "`$null | & (Get-Process -Id `$PID).Path -NoProfile -File '$crewScript' up -Path '$dir'; exit `$LASTEXITCODE"
    $r = Invoke-InTestHome -TestHome $c.Home -File $wrap -Env $c.Env
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'crew init'
    Assert-NoInit $c $dir
  }
  It 'HOME khac hoa thuong va dau tach cuoi: chan truoc hoi' {
    $target = $c.Home.Home + '/'
    if ($OnWindows) { $target = $target.ToUpperInvariant() }
    $r = Run-Up $c @('up','-Path',$target) "1`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'HOME'
    $r.Output | Should Not Match 'Lựa chọn'
    Assert-NoInit $c $c.Home.Home
  }
  It 'goc he thong: AST fake duong dan, khong dong goc that' {
    $wrap = Join-Path $c.Home.Home 'root.ps1'
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-Recover' }, $false)[0].Extent.Text
    $pre = 'param($target); $Path = $target; function Get-MainRoot { $null }; function Test-SamePath($a,$b) { $b -eq [IO.Path]::GetPathRoot($target) }; function Die($msg) { Write-Output $msg; exit 1 }'
    Set-Content $wrap ($pre + "`n" + $fn + "`nInvoke-Recover `$true")
    $r = Invoke-InTestHome -TestHome $c.Home -File $wrap -Arguments @($dir) -Env $c.Env
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'gốc hệ thống'
    $r.Output | Should Not Match 'Lựa chọn'
    Assert-NoInit $c $dir
  }
  It 'HOME da git init chua HEAD: chan ca tu thu muc con, khong hoi hay stage file' {
    git -C $c.Home.Home init -qb main
    foreach ($target in @(($c.Home.Home + '/'), $dir)) {
      $r = Run-Up $c @('up','-Path',$target) "1`n"
      $r.ExitCode | Should Be 1
      $r.Output | Should Match 'HOME.*chưa có commit'
      $r.Output | Should Not Match 'Lựa chọn'
      Assert-NoInit $c $c.Home.Home $true
      @(git -C $c.Home.Home ls-files).Count | Should Be 0
      git -C $c.Home.Home rev-parse --verify -q HEAD
      $LASTEXITCODE | Should Be 1
    }
  }
  It 'goc da git init chua HEAD: AST fake root, khong hoi hay tao commit' {
    git -C $dir init -qb main
    $wrap = Join-Path $c.Home.Home 'git-root.ps1'
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-Recover' }, $false)[0].Extent.Text
    $pre = 'param($target); $Path = $target; function Get-MainRoot { $target }; function Get-Root { $target }; function Invoke-GitQuiet { @{ Code = 1 } }; function Test-SamePath($a,$b) { $a -eq $b -or $b -eq [IO.Path]::GetPathRoot($target) }; function Die($msg) { Write-Output $msg; exit 1 }'
    Set-Content $wrap ($pre + "`n" + $fn + "`nInvoke-Recover `$true")
    $r = Invoke-InTestHome -TestHome $c.Home -File $wrap -Arguments @($dir) -Env $c.Env
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'gốc hệ thống.*chưa có commit'
    $r.Output | Should Not Match 'Lựa chọn'
    Assert-NoInit $c $dir $true
    @(git -C $dir ls-files).Count | Should Be 0
    git -C $dir rev-parse --verify -q HEAD
    $LASTEXITCODE | Should Be 1
  }
  It 'HOME da co HEAD: van hoi init nhu repo thuong' {
    git -C $c.Home.Home init -qb main
    git -C $c.Home.Home -c user.name=t -c user.email=t@t commit -qm init --allow-empty
    $r = Run-Up $c @('up','-Path',$c.Home.Home) "2`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'Lựa chọn \[1\]'
    $r.Output | Should Match 'thôi, không tạo gì'
    Assert-NoInit $c $c.Home.Home $true 1
  }
  It 'worktree phu: chan, neu root chinh, giu commit' {
    git -C $dir init -qb main
    git -C $dir -c user.name=t -c user.email=t@t commit -qm init --allow-empty
    $wt = Join-Path $c.Home.Home 'secondary'
    git -C $dir worktree add -qb secondary $wt
    $r = Run-Up $c @('up','-Path',$wt) "1`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Match ([regex]::Escape($dir))
    $r.Output | Should Not Match 'Lựa chọn'
    Assert-NoInit $c $dir $true 1
    foreach ($n in 'context','.crew') { Test-Path (Join-Path $wt $n) | Should Be $false }
  }
  It 'DryRun bao; Restart repair All va con All khong hoi tao' {
    $r = Run-Up $c @('up','-Path',$dir,'-DryRun') "1`n"
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'project chưa init, crew up sẽ hỏi tạo'
    foreach ($argv in @(@('up','-Restart','w1'), @('repair'), @('up','-All'))) {
      $r = Run-Up $c ($argv + @('-Path',$dir)) "1`n"
      $r.Output | Should Not Match 'Lựa chọn'
    }
    $c.Env.CREWLINE_UP_ALL_CHILD = '1'
    $r = Run-Up $c @('up','-Path',$dir) "1`n"
    $r.ExitCode | Should Be 1
    $r.Output | Should Not Match 'Lựa chọn'
    Assert-NoInit $c $dir
  }
}
[Console]::OutputEncoding = $savedUpEncoding
