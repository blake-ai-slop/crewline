# Test tham số tên của crew (FIX-REVIEW-COMMA): `crew review a,b` từ PowerShell (mảng) và Git Bash (chuỗi); lệnh 1 tên giữ như cũ.
$CrewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'

function Invoke-ArgGit {
  $output = & git @args 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
}
# chạy crew trong $repo; $argText là đoạn PowerShell sau `& crew.ps1` (mảng thật) hoặc $null để dùng -File với $fileArgs
function Invoke-CrewCmd([string]$argText) {
  $q = $CrewScript.Replace("'", "''")
  $out = & pwsh -NoProfile -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Set-Location -LiteralPath '$($repo.Replace("'", "''"))'; & '$q' $argText; exit `$LASTEXITCODE" 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out -join "`n" }
}
function Invoke-CrewFile([string[]]$fileArgs) {
  Push-Location -LiteralPath $repo
  try { $out = & pwsh -NoProfile -File $CrewScript @fileArgs 2>&1 | ForEach-Object { "$_" } } finally { Pop-Location }
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out -join "`n" }
}

Describe 'crew: tham số tên' {
  BeforeAll {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $repo = Join-Path $TestDrive 'argrepo'
    New-Item -ItemType Directory -Force (Join-Path $repo '.crew') | Out-Null
    Invoke-ArgGit -C $repo init -q -b main
    Invoke-ArgGit -C $repo config core.autocrlf false
    Set-Content (Join-Path $repo '.gitignore') '.crew/'
    Invoke-ArgGit -C $repo add -A
    Invoke-ArgGit -C $repo -c user.name=t -c user.email=t@t commit -qm init
    foreach ($n in 'alpha', 'beta') {
      Invoke-ArgGit -C $repo checkout -q -b "crew/$n" main
      Set-Content (Join-Path $repo "$n.txt") $n
      Invoke-ArgGit -C $repo add -A
      Invoke-ArgGit -C $repo -c user.name=t -c user.email=t@t commit -qm $n
    }
    Invoke-ArgGit -C $repo checkout -q main
    Set-Content (Join-Path $repo '.crew/config.json') '{"review":"lean"}'
    $tasks = @(
      [pscustomobject]@{ name = 'beta'; branch = 'crew/beta'; worktree = ''; worker = 1 },
      [pscustomobject]@{ name = 'alpha'; branch = 'crew/alpha'; worktree = ''; worker = 2 }
    )
    Set-Content (Join-Path $repo '.crew/tasks.json') (ConvertTo-Json @($tasks))
    $script:repo = $repo
  }

  function Test-Order($r, [string]$first, [string]$second) {
    $r.Code | Should Be 0
    $r.Text | Should Match "merge crew/$first \([0-9a-f]+\) rồi crew/$second \([0-9a-f]+\) \(đúng thứ tự này\)"
    $r.Text | Should Match "crew clean $first, crew clean $second"
  }

  It 'review a,b qua -File (chuỗi, như Git Bash)' {
    Test-Order (Invoke-CrewFile @('review', 'alpha,beta', '-DryRun')) 'alpha' 'beta'
    Test-Order (Invoke-CrewFile @('review', 'beta,alpha', '-DryRun')) 'beta' 'alpha'
  }
  It 'review "a, b" và a, b tách 2 đối số (Git Bash) qua -File' {
    Test-Order (Invoke-CrewFile @('review', 'alpha, beta', '-DryRun')) 'alpha' 'beta'
    Test-Order (Invoke-CrewFile @('review', 'alpha,', 'beta', '-DryRun')) 'alpha' 'beta'
  }
  It 'review a,b / a, b / "a,b" trong PowerShell (mảng thật)' {
    Test-Order (Invoke-CrewCmd 'review alpha,beta -DryRun') 'alpha' 'beta'
    Test-Order (Invoke-CrewCmd 'review beta, alpha -DryRun') 'beta' 'alpha'
    Test-Order (Invoke-CrewCmd 'review "alpha,beta" -DryRun') 'alpha' 'beta'
  }
  It 'review 1 task vẫn chạy' {
    $r = Invoke-CrewCmd 'review alpha -DryRun'
    $r.Code | Should Be 0
    $r.Text | Should Match 'merge crew/alpha \([0-9a-f]+\)\. Đọc context/tasks/alpha\.md\.'
  }
  It 'review thiếu tên / task lạ báo đúng' {
    (Invoke-CrewCmd 'review -DryRun').Text | Should Match 'dùng: crew review'
    $r = Invoke-CrewCmd 'review alpha,ghost -DryRun'
    $r.Code | Should Be 1
    $r.Text | Should Match 'không có task tên ghost'
  }
  It 'clean / check 1 tên lạ: lỗi ra đúng tên' {
    $r = Invoke-CrewCmd 'clean ghost'
    $r.Code | Should Be 1
    $r.Text | Should Match 'không có task tên ghost'
    $r = Invoke-CrewFile @('check', 'ghost')
    $r.Code | Should Be 1
    $r.Text | Should Match 'task ghost không có trong \.crew/tasks\.json'
  }
  It 'task: tên sai / thiếu prompt vẫn báo như cũ' {
    (Invoke-CrewCmd 'task Bad_Name p.md').Text | Should Match 'tên task chỉ gồm a-z 0-9'
    (Invoke-CrewCmd 'task').Text | Should Match 'dùng: crew task'
  }
  It 'lệnh 1 tên nhận 2 tên -> lỗi rõ, không chạy' {
    foreach ($cmd in 'clean alpha,beta', 'check alpha,beta', 'task a,b p.md', 'send t1,t2 hi', 'probe claude,codex', 'confirm t1,t2') {
      $r = Invoke-CrewCmd $cmd
      $r.Code | Should Be 1
      $r.Text | Should Match 'chỉ nhận một tên, nhận 2: '
    }
    $r = Invoke-CrewFile @('clean', 'alpha,beta')
    $r.Code | Should Be 1
    $r.Text | Should Match 'crew clean chỉ nhận một tên, nhận 2: alpha, beta'
  }

  It 'probe: agent lạ / thiếu tên ⇒ exit 1 trước khi gọi hc; confirm thiếu terminal ⇒ cách dùng' {
    foreach ($a in @(@('probe', 'gemini'), @('probe'))) {
      $r = Invoke-CrewFile $a
      $r.Code | Should Be 1
      $r.Text | Should Match 'dùng: crew probe <claude\|codex>'
      $r.Text | Should Match '→ Làm tiếp:'
    }
    $c = Invoke-CrewFile @('confirm')
    $c.Code | Should Be 1
    $c.Text | Should Match 'dùng: crew confirm <terminal>'
  }

  It '-DryRun ở lệnh không có nó ⇒ exit 1 trước khi làm gì, kèm Làm tiếp; lệnh có -DryRun không bị chặn' {
    Set-Content (Join-Path $repo 'p.md') 'x'
    $before = git -C $repo branch --list 'crew/*'
    foreach ($cmd in @(@('task', 'gamma', 'p.md', '-DryRun'), @('clean', 'alpha', '-DryRun'), @('send', 't1', 'hi', '-DryRun'), @('init', '-DryRun'), @('probe', 'claude', '-DryRun'), @('confirm', 't1', '-DryRun'))) {
      $r = Invoke-CrewFile $cmd
      $r.Code | Should Be 1
      $r.Text | Should Match ([regex]::Escape("crew: LỖI: crew $($cmd[0]) không có -DryRun"))
      $r.Text | Should Match '→ Làm tiếp:\s*\r?\n\s+bỏ -DryRun rồi chạy lại crew '
      $r.Text | Should Match 'Lệnh có -DryRun: crew up, crew upgrade, crew repair, crew review <task>, crew queue -Run'
    }
    (git -C $repo branch --list 'crew/*') | Should Be $before
    Test-Path -LiteralPath (Join-Path $repo '.crew/queue.json') | Should Be $false
    $q = Invoke-CrewFile @('queue', 'gamma', 'p.md', '-DryRun')
    $q.Code | Should Be 1
    $q.Text | Should Match 'crew queue chỉ có -DryRun khi đi với -Run'
    $q.Text | Should Match 'crew queue -Run -DryRun'
    Test-Path -LiteralPath (Join-Path $repo '.crew/queue.json') | Should Be $false
    $ok = Invoke-CrewFile @('review', 'alpha', '-DryRun')
    $ok.Code | Should Be 0
    $ok.Text | Should Not Match 'không có -DryRun'
    $bad = Invoke-CrewFile @('tsak', '-DryRun')
    $bad.Code | Should Be 1
    $bad.Text | Should Match "không có lệnh 'tsak'"
  }
}
