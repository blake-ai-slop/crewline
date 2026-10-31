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
    $r.Text | Should Match 'task ghost không có trong \.crew/tasks\.json'
  }
  It 'clean / check 1 tên lạ: lỗi ra đúng tên' {
    $r = Invoke-CrewCmd 'clean ghost'
    $r.Code | Should Be 1
    $r.Text | Should Match 'task ghost không có trong \.crew/tasks\.json'
    $r = Invoke-CrewFile @('check', 'ghost')
    $r.Code | Should Be 1
    $r.Text | Should Match 'task ghost không có trong \.crew/tasks\.json'
  }
  It 'task: tên sai / thiếu prompt vẫn báo như cũ' {
    (Invoke-CrewCmd 'task Bad_Name p.md').Text | Should Match 'tên task chỉ gồm a-z 0-9'
    (Invoke-CrewCmd 'task').Text | Should Match 'dùng: crew task'
  }
  It 'lệnh 1 tên nhận 2 tên -> lỗi rõ, không chạy' {
    foreach ($cmd in 'clean alpha,beta', 'check alpha,beta', 'task a,b p.md', 'send t1,t2 hi') {
      $r = Invoke-CrewCmd $cmd
      $r.Code | Should Be 1
      $r.Text | Should Match 'chỉ nhận một tên, nhận 2: '
    }
    $r = Invoke-CrewFile @('clean', 'alpha,beta')
    $r.Code | Should Be 1
    $r.Text | Should Match 'crew clean chỉ nhận một tên, nhận 2: alpha, beta'
  }
}
