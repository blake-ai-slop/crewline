# Thiếu tên/email git: crew hỏi rồi lưu --global. CLI thật, HOME và gitconfig giả, hc/herdr-app giả.
. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
$IdentityVars = 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'EMAIL'
$Explain = @(
  'Git cần tên và email để ghi vào commit trong project này.',
  'Đây là yêu cầu của git, không phải của Crewline: crew cần commit để',
  'tạo worktree riêng cho từng worker. Crewline không thu thập hay gửi',
  'thông tin này đi đâu. Tên và email không cần là tài khoản thật.'
)

# hc giả: trả danh sách terminal rỗng rồi nhận terminal mới; đủ để crew up chạy hết đường mà không chạm hc thật.
$FakeHc = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
switch ($args[0]) {
  'ls' { ConvertTo-Json -InputObject ([ordered]@{ terminals = @($terms) }) -Depth 6; exit 0 }
  'get' {
    $key = $args[1]
    $t = $terms | Where-Object { $_.name -eq $key -or $_.address -eq $key } | Select-Object -First 1
    if (-not $t) { exit 1 }
    $t | ConvertTo-Json -Depth 6; exit 0
  }
  'send' { '{"started":true}'; exit 0 }
  'run' {
    $name = ''; $cwd = ''
    for ($i = 1; $i -lt $args.Count; $i++) {
      if ($args[$i] -eq '--name') { $name = $args[$i + 1] }
      if ($args[$i] -eq '--cwd') { $cwd = $args[$i + 1] }
    }
    $addr = "t$($terms.Count + 100)"
    $terms += [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; turn = 1; status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' } }
    ConvertTo-Json -InputObject @($terms) -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
    [pscustomobject]@{ address = $addr; name = $name } | ConvertTo-Json; exit 0
  }
  default { exit 0 }
}
'@
$FakeHerdr = @'
#!/usr/bin/env pwsh
if ($args[0] -eq 'ls') { '{"spaces":[]}' }
exit 0
'@

function New-Ctx([string]$GlobalConfig = "[user]`n`tuseConfigOnly = true`n[core]`n`tautocrlf = false`n") {
  $h = New-CrewTestHome
  $global = Join-Path $h.Home 'gitconfig'
  [IO.File]::WriteAllText($global, $GlobalConfig)
  $bin = Join-Path $h.Home 'fakebin'; $state = Join-Path $h.Home 'fakestate'
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr))) {
    # .gitattributes giữ *.ps1 ở CRLF; CR ở dòng shebang làm env không tìm thấy pwsh trên Unix.
    $file = Join-Path $bin $(if ($OnWindows) { "$($pair[0]).ps1" } else { $pair[0] })
    [IO.File]::WriteAllText($file, ($pair[1] -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
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
  $dir = Join-Path $h.Home 'project'
  New-Item -ItemType Directory $dir | Out-Null
  Set-Content (Join-Path $dir 'note.txt') 'existing'
  @{ Home = $h; Global = $global; Dir = $dir; Env = @{ PATH = $path; FAKE_HC_DIR = $state; HC_SESSION = "crew-test-$([guid]::NewGuid().ToString('N'))"; HC_TERMINAL_ID = $null; HC_TERMINAL_SOCKET = $null; CREWLINE_DEFAULTS = '' } }
}

function Run-Crew($c, [string[]]$argv, [string]$inputText = '', [hashtable]$extra = @{}) {
  $e = @{}
  foreach ($k in $c.Env.Keys) { $e[$k] = $c.Env[$k] }
  foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
  Invoke-InTestHome -TestHome $c.Home -File $crewScript -Arguments $argv -Env $e -InputText $inputText
}
# stdin đóng hẳn (EOF ngay dòng đầu), khác với '' | pwsh gửi một dòng trống.
function Run-CrewEof($c, [string[]]$argv) {
  $wrap = Join-Path $c.Home.Home 'eof.ps1'
  $quoted = @($argv | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
  Set-Content $wrap "`$null | & (Get-Process -Id `$PID).Path -NoProfile -NonInteractive -File '$crewScript' $quoted; exit `$LASTEXITCODE"
  $e = @{}
  foreach ($k in $c.Env.Keys) { $e[$k] = $c.Env[$k] }
  Invoke-InTestHome -TestHome $c.Home -File $wrap -Env $e
}
function Get-Global($c, [string]$key) {
  $v = git config --file $c.Global --get $key
  if ($LASTEXITCODE -eq 0) { "$v" } else { '' }
}
function Assert-NothingCreated($c) {
  @(Get-ChildItem -LiteralPath $c.Dir -Force | ForEach-Object { $_.Name }) -join ',' | Should Be 'note.txt'
}
function Assert-Explained([string]$output, [bool]$expected = $true) {
  foreach ($line in $Explain) { ([regex]::IsMatch($output, [regex]::Escape($line))) | Should Be $expected }
}
function Init-Repo($c) {
  git -C $c.Dir init -qb main
  git -C $c.Dir -c user.name=seed -c user.email=seed@example.invalid commit -qm init --allow-empty
}
# Project đã init, dựng khi có danh tính rồi gỡ để giống máy mất cấu hình.
function Init-Project($c) {
  Init-Repo $c
  $saved = [IO.File]::ReadAllText($c.Global)
  [IO.File]::WriteAllText($c.Global, "[user]`n`tname = seed`n`temail = seed@example.invalid`n[core]`n`tautocrlf = false`n")
  $r = Run-Crew $c @('init', '-Path', $c.Dir, '-NoCommit') '' @{ CREWLINE_DEFAULTS = '1' }
  if ($r.ExitCode -ne 0) { throw $r.Output }
  git -C $c.Dir add -A
  git -C $c.Dir -c user.name=seed -c user.email=seed@example.invalid commit -qm skeleton
  [IO.File]::WriteAllText($c.Global, $saved)
}

$savedEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$savedVars = @{}
foreach ($k in $IdentityVars + @('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM')) { $savedVars[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
$env:GIT_CONFIG_NOSYSTEM = '1'
foreach ($k in $IdentityVars) { Remove-Item "Env:$k" -ErrorAction Ignore }
try {
  Describe 'danh tính git: crew init' {
    BeforeEach {
      $c = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $c.Global  # lệnh git của chính test cũng không đọc config thật
    }

    It 'đã có đủ: không hỏi, không in, không ghi' {
      $config = "[user]`n`tname = Ann`n`temail = ann@example.invalid`n[core]`n`tautocrlf = false`n"
      [IO.File]::WriteAllText($c.Global, $config)
      Init-Repo $c
      $r = Run-Crew $c @('init', '-Path', $c.Dir) "nhập thừa`n"
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output $false
      $r.Output | Should Not Match 'Tên:|Email:|đã lưu'
      [IO.File]::ReadAllText($c.Global) | Should Be $config
      git -C $c.Dir log -1 --format=%ae | Should Be 'ann@example.invalid'
    }

    It 'thiếu cả hai: có giải thích, hỏi cả hai, ghi global, commit đúng tác giả, không ghi local' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "Nguyễn Văn An`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output
      $r.Output | Should Match 'Tên: '
      $r.Output | Should Match 'Email: '
      $r.Output | Should Match 'đã lưu user\.name=Nguyễn Văn An, user\.email=an@example\.invalid vào cấu hình git toàn máy'
      Get-Global $c 'user.name' | Should Be 'Nguyễn Văn An'
      Get-Global $c 'user.email' | Should Be 'an@example.invalid'
      Get-Global $c 'user.useConfigOnly' | Should Be 'true'
      @(git -C $c.Dir log --format='%an <%ae>') -join '|' | Should Be 'Nguyễn Văn An <an@example.invalid>|Nguyễn Văn An <an@example.invalid>'
      git -C $c.Dir config --local --get user.name | Should BeNullOrEmpty
      git -C $c.Dir config --local --get user.email | Should BeNullOrEmpty
    }

    It 'lời giải thích đứng trước câu hỏi, câu hỏi trước git init' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "An`nan@example.invalid`n"
      $r.Output.IndexOf($Explain[0]) | Should BeLessThan $r.Output.IndexOf('Tên: ')
      $r.Output.IndexOf('đã lưu') | Should BeLessThan $r.Output.IndexOf('git init')
    }

    It 'có tên toàn máy: chỉ hỏi email, không ghi đè tên' {
      [IO.File]::WriteAllText($c.Global, "[user]`n`tname = Có Sẵn`n`tuseConfigOnly = true`n[core]`n`tautocrlf = false`n")
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "an@example.invalid`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'Tên: '
      $r.Output | Should Match 'Email: '
      $r.Output | Should Not Match 'user\.name='
      Get-Global $c 'user.name' | Should Be 'Có Sẵn'
      Get-Global $c 'user.email' | Should Be 'an@example.invalid'
    }

    It 'có email toàn máy: chỉ hỏi tên, không ghi đè email' {
      [IO.File]::WriteAllText($c.Global, "[user]`n`temail = co@example.invalid`n`tuseConfigOnly = true`n[core]`n`tautocrlf = false`n")
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "An`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'Tên: '
      $r.Output | Should Not Match 'Email: '
      Get-Global $c 'user.name' | Should Be 'An'
      Get-Global $c 'user.email' | Should Be 'co@example.invalid'
    }

    It 'có sẵn trong repo: không hỏi, global không đổi' {
      Init-Repo $c
      git -C $c.Dir config user.name Repo
      git -C $c.Dir config user.email repo@example.invalid
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('init', '-Path', $c.Dir)
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output $false
      [IO.File]::ReadAllText($c.Global) | Should Be $before
      git -C $c.Dir log -1 --format=%ae | Should Be 'repo@example.invalid'
    }

    It 'biến môi trường đủ cả author và committer: không hỏi, không ghi' {
      Init-Repo $c
      $before = [IO.File]::ReadAllText($c.Global)
      try {
        $env:GIT_AUTHOR_NAME = 'Env'; $env:GIT_AUTHOR_EMAIL = 'env@example.invalid'
        $env:GIT_COMMITTER_NAME = 'Env'; $env:GIT_COMMITTER_EMAIL = 'env@example.invalid'
        $r = Run-Crew $c @('init', '-Path', $c.Dir)
      } finally { foreach ($k in $IdentityVars) { Remove-Item "Env:$k" -ErrorAction Ignore } }
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output $false
      [IO.File]::ReadAllText($c.Global) | Should Be $before
      git -C $c.Dir log -1 --format=%ae | Should Be 'env@example.invalid'
    }

    It 'chỉ có biến committer: git vẫn không commit được nên vẫn hỏi' {
      Init-Repo $c
      try {
        $env:GIT_COMMITTER_NAME = 'Env'; $env:GIT_COMMITTER_EMAIL = 'env@example.invalid'
        $r = Run-Crew $c @('init', '-Path', $c.Dir) "An`nan@example.invalid`n"
      } finally { foreach ($k in $IdentityVars) { Remove-Item "Env:$k" -ErrorAction Ignore } }
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output
      Get-Global $c 'user.name' | Should Be 'An'
    }

    It 'Enter trống rồi nhập: dùng giá trị nhập' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "`nAn`n`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      Get-Global $c 'user.name' | Should Be 'An'
      Get-Global $c 'user.email' | Should Be 'an@example.invalid'
    }

    It 'trống hai lần: exit khác 0, không tạo gì, không ghi global, in 2 lệnh' {
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "`n`nAn`nan@example.invalid`n"
      $r.ExitCode | Should Not Be 0
      Assert-NothingCreated $c
      [IO.File]::ReadAllText($c.Global) | Should Be $before
      $r.Output | Should Match 'git config --global user\.name "'
      $r.Output | Should Match 'git config --global user\.email "'
    }

    It 'git từ chối tên: báo lỗi, hỏi lại, không lưu giá trị bị từ chối' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "<>`nan@example.invalid`nAn`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'Git không nhận'
      Get-Global $c 'user.name' | Should Be 'An'
      @(git config --file $c.Global --get-all user.name).Count | Should Be 1
    }

    It 'git từ chối mãi: dừng, không tạo gì, global không có giá trị xấu' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') (("<>`nan@example.invalid`n") * 3)
      $r.ExitCode | Should Not Be 0
      Assert-NothingCreated $c
      Get-Global $c 'user.name' | Should Be ''
    }

    It 'CREWLINE_DEFAULTS=1: dừng, không tạo gì, có 2 lệnh, không hỏi' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "An`nan@example.invalid`n" @{ CREWLINE_DEFAULTS = '1' }
      $r.ExitCode | Should Not Be 0
      Assert-NothingCreated $c
      Assert-Explained $r.Output $false
      $r.Output | Should Match 'git config --global user\.name "'
      $r.Output | Should Match 'git config --global user\.email "'
      Get-Global $c 'user.name' | Should Be ''
    }

    It 'stdin đóng: dừng, không tạo gì, có 2 lệnh' {
      $r = Run-CrewEof $c @('init', '-Path', $c.Dir, '-GitInit')
      $r.ExitCode | Should Not Be 0
      Assert-NothingCreated $c
      $r.Output | Should Match 'git config --global user\.name "'
      $r.Output | Should Match 'git config --global user\.email "'
    }

    It 'chọn Thôi ở câu hỏi git: không hỏi danh tính' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir) "2`n"
      $r.ExitCode | Should Be 1
      Assert-Explained $r.Output $false
      Assert-NothingCreated $c
    }

    It 'repo có commit, -NoCommit: không có commit nào nên không hỏi' {
      Init-Repo $c
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-NoCommit') '' @{ CREWLINE_DEFAULTS = '1' }
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output $false
      Test-Path (Join-Path $c.Dir 'context/README.md') | Should Be $true
    }

    It 'sau khi lưu: worktree của worker commit được' {
      $r = Run-Crew $c @('init', '-Path', $c.Dir, '-GitInit') "An`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      $wt = Join-Path $c.Dir '.crew/worktrees/w1'
      git -C $c.Dir worktree add -q -b crew/thu $wt
      $LASTEXITCODE | Should Be 0
      git -C $wt commit -q --allow-empty -m viec
      $LASTEXITCODE | Should Be 0
      git -C $wt log -1 --format=%ae | Should Be 'an@example.invalid'
    }
  }

  Describe 'danh tính git: crew up' {
    BeforeEach {
      $c = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $c.Global
    }

    It 'project mới: hỏi trước khi tạo, commit đúng tác giả' {
      Init-Repo $c
      $r = Run-Crew $c @('up', '-Path', $c.Dir) "1`nAn`nan@example.invalid`n"
      $r.Output.IndexOf('Lựa chọn') | Should BeLessThan $r.Output.IndexOf($Explain[0])
      Get-Global $c 'user.name' | Should Be 'An'
      git -C $c.Dir log -1 --format=%ae | Should Be 'an@example.invalid'
    }

    It 'project mới, chọn Thôi: không hỏi danh tính' {
      Init-Repo $c
      $r = Run-Crew $c @('up', '-Path', $c.Dir) "2`n"
      $r.ExitCode | Should Be 1
      Assert-Explained $r.Output $false
    }

    It 'đã init, có người: hỏi và lưu' {
      Init-Project $c
      $r = Run-Crew $c @('up', '-Path', $c.Dir) "An`nan@example.invalid`n"
      Assert-Explained $r.Output
      Get-Global $c 'user.name' | Should Be 'An'
      Get-Global $c 'user.email' | Should Be 'an@example.invalid'
    }

    It 'đã init, stdin đóng: cảnh báo một dòng kèm 2 lệnh, vẫn chạy, exit như có danh tính' {
      Init-Project $c
      $r = Run-CrewEof $c @('up', '-Path', $c.Dir)
      @($r.Output -split "`n" | Where-Object { $_ -match 'cảnh báo: git chưa có tên/email' -and $_ -match 'user\.name "' -and $_ -match 'user\.email "' }).Count | Should Be 1
      $r.Output | Should Match 'kết luận'
      Test-Path (Join-Path $c.Env.FAKE_HC_DIR 'terminals.json') | Should Be $true
      Get-Global $c 'user.name' | Should Be ''
      $noIdentityExit = $r.ExitCode

      $d = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $d.Global
      Init-Project $d
      [IO.File]::AppendAllText($d.Global, "[user]`n`tname = Ann`n`temail = ann@example.invalid`n")
      $withIdentity = Run-CrewEof $d @('up', '-Path', $d.Dir)
      $noIdentityExit | Should Be $withIdentity.ExitCode
    }

    It 'đã init, CREWLINE_DEFAULTS=1: cảnh báo, không đọc stdin' {
      Init-Project $c
      $r = Run-Crew $c @('up', '-Path', $c.Dir) "An`nan@example.invalid`n" @{ CREWLINE_DEFAULTS = '1' }
      $r.Output | Should Match 'cảnh báo: git chưa có tên/email'
      Assert-Explained $r.Output $false
      Get-Global $c 'user.name' | Should Be ''
    }

    It '-DryRun: không hỏi, không ghi, có báo' {
      Init-Project $c
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('up', '-Path', $c.Dir, '-DryRun') "An`nan@example.invalid`n"
      $r.Output | Should Match 'DryRun không hỏi, không ghi'
      Assert-Explained $r.Output $false
      [IO.File]::ReadAllText($c.Global) | Should Be $before
    }

    It '-All: hỏi đúng một lần ở tiến trình cha, con không hỏi' {
      Init-Project $c
      $r = Run-Crew $c @('up', '-All', '-Path', $c.Dir) "An`nan@example.invalid`n"
      ([regex]::Matches($r.Output, [regex]::Escape($Explain[0]))).Count | Should Be 1
      $r.Output | Should Match 'tổng kết crew up -All'
      Get-Global $c 'user.name' | Should Be 'An'
    }

    It '-All, stdin đóng: một cảnh báo cho cả lượt, vẫn chạy' {
      Init-Project $c
      $r = Run-CrewEof $c @('up', '-All', '-Path', $c.Dir)
      ([regex]::Matches($r.Output, 'cảnh báo: git chưa có tên/email')).Count | Should Be 1
      $r.Output | Should Match 'tổng kết crew up -All'
    }

    It '-All -DryRun: không hỏi, không ghi' {
      Init-Project $c
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('up', '-All', '-DryRun', '-Path', $c.Dir) "An`nan@example.invalid`n"
      Assert-Explained $r.Output $false
      [IO.File]::ReadAllText($c.Global) | Should Be $before
    }
  }

  Describe 'danh tính git: tiến trình nền' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
    $functions = @{}
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$fn.Name] = $fn.Extent.Text }

    It 'Invoke-Up: đường FromRepair (tiến trình nền) không gọi hỏi' {
      $functions['Invoke-Up'] | Should Match 'if \(-not \$script:FromRepair\) \{ Confirm-GitIdentity'
    }
    It 'Invoke-SelfPaneRun/Work không gọi trực tiếp Confirm-GitIdentity' {
      $functions['Invoke-SelfPaneRun'] | Should Not Match 'Confirm-GitIdentity'
      $functions['Invoke-SelfPaneWork'] | Should Not Match 'Confirm-GitIdentity'
    }
    It 'lệnh self-pane-*: chỉ cảnh báo, không đọc stdin dù stdin còn dữ liệu' {
      $c = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $c.Global
      Init-Repo $c
      # Chạy đúng các hàm thật trong tiến trình con, Read-GitIdentityField giả báo nếu bị gọi.
      $code = @(
        'function Say($msg) { Write-Host "crew: $msg" }',
        $functions['Invoke-GitQuiet'], $functions['Get-GitIdentityError'], $functions['Get-GitIdentityFix'], $functions['Confirm-GitIdentity'],
        'function Read-GitIdentityField { throw "đã đọc stdin" }',
        '$Command = "self-pane-work"',
        ('Confirm-GitIdentity ''{0}'' $false $false' -f ($c.Dir -replace "'", "''"))
      ) -join "`n"
      $file = Join-Path $c.Home.Home 'selfpane.ps1'
      [IO.File]::WriteAllText($file, $code, [Text.UTF8Encoding]::new($true))
      $e = @{}; foreach ($k in $c.Env.Keys) { $e[$k] = $c.Env[$k] }
      $r = Invoke-InTestHome -TestHome $c.Home -File $file -Env $e -InputText "An`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'cảnh báo: git chưa có tên/email'
      $r.Output | Should Not Match 'đã đọc stdin'
      Get-Global $c 'user.name' | Should Be ''
    }
  }

  Describe 'danh tính git: crew upgrade' {
    BeforeEach {
      $c = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $c.Global
      Init-Project $c
      $role = Join-Path $c.Dir 'context/roles/worker.md'
    }
    function Make-Old($c) {
      Set-Content (Join-Path $c.Dir 'context/roles/worker.md') 'old role'
      git -C $c.Dir add context
      git -C $c.Dir -c user.name=seed -c user.email=seed@example.invalid commit -qm old
    }

    It 'có commit: hỏi trước khi ghi file, commit đúng tác giả' {
      Make-Old $c
      $r = Run-Crew $c @('upgrade', '-Path', $c.Dir) "An`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output
      $r.Output.IndexOf('đã lưu') | Should BeLessThan $r.Output.IndexOf('sao lưu + cập nhật')
      git -C $c.Dir log -1 --format=%ae | Should Be 'an@example.invalid'
    }

    It 'có commit, không có người: dừng trước khi ghi file' {
      Make-Old $c
      $r = Run-Crew $c @('upgrade', '-Path', $c.Dir) '' @{ CREWLINE_DEFAULTS = '1' }
      $r.ExitCode | Should Not Be 0
      $r.Output | Should Match 'git config --global user\.name "'
      (Get-Content $role -Raw).Trim() | Should Be 'old role'
      @(Get-ChildItem "$role.bak-*" -ErrorAction Ignore).Count | Should Be 0
      git -C $c.Dir status --porcelain | Should BeNullOrEmpty
    }

    It 'không có gì để commit: không hỏi, exit 0' {
      # Lần upgrade đầu sau init còn ghi lại .skeleton-version nên chạy một lần khi có danh tính.
      $noIdentity = [IO.File]::ReadAllText($c.Global)
      [IO.File]::AppendAllText($c.Global, "[user]`n`tname = seed`n`temail = seed@example.invalid`n")
      $first = Run-Crew $c @('upgrade', '-Path', $c.Dir) '' @{ CREWLINE_DEFAULTS = '1' }
      $first.ExitCode | Should Be 0
      [IO.File]::WriteAllText($c.Global, $noIdentity)
      $r = Run-Crew $c @('upgrade', '-Path', $c.Dir) '' @{ CREWLINE_DEFAULTS = '1' }
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'không có gì mới'
      Assert-Explained $r.Output $false
    }

    It '-NoCommit: không hỏi' {
      Make-Old $c
      $r = Run-Crew $c @('upgrade', '-Path', $c.Dir, '-NoCommit') '' @{ CREWLINE_DEFAULTS = '1' }
      $r.ExitCode | Should Be 0
      Assert-Explained $r.Output $false
    }

    It '-DryRun có việc: báo, không hỏi, không ghi' {
      Make-Old $c
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('upgrade', '-Path', $c.Dir, '-DryRun') "An`nan@example.invalid`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'DryRun không hỏi, không ghi'
      Assert-Explained $r.Output $false
      [IO.File]::ReadAllText($c.Global) | Should Be $before
      (Get-Content $role -Raw).Trim() | Should Be 'old role'
    }
  }

  Describe 'danh tính git: crew doctor' {
    BeforeEach {
      $c = New-Ctx
      $env:GIT_CONFIG_GLOBAL = $c.Global
    }
    It 'thiếu: ghi chú lý do, không tính là thiếu, không ghi' {
      $before = [IO.File]::ReadAllText($c.Global)
      $r = Run-Crew $c @('doctor', '-Path', $c.Dir)
      $r.Output | Should Match 'GHI CHÚ git identity: .*git yêu cầu.*crew sẽ hỏi khi cần commit'
      $r.Output | Should Not Match 'THIẾU git identity'
      [IO.File]::ReadAllText($c.Global) | Should Be $before
    }
    It 'có: OK kèm danh tính' {
      [IO.File]::WriteAllText($c.Global, "[user]`n`tname = Ann`n`temail = ann@example.invalid`n")
      $r = Run-Crew $c @('doctor', '-Path', $c.Dir)
      $r.Output | Should Match 'OK    git identity \(Ann <ann@example\.invalid>\)'
    }
  }
} finally {
  foreach ($k in $savedVars.Keys) { [Environment]::SetEnvironmentVariable($k, $savedVars[$k], 'Process') }
  foreach ($k in $savedVars.Keys) { if ($null -eq $savedVars[$k]) { Remove-Item "Env:$k" -ErrorAction Ignore } }
  [Console]::OutputEncoding = $savedEncoding
}
