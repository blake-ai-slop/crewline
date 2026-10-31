$CheckScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'

function Invoke-FixtureGit {
  $output = & git @args 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
}
function Save-CheckFixture([hashtable]$Files, [string]$Rules = 'Được sửa: `scripts/ok.ps1`, `tests/*.Tests.ps1`') {
  foreach ($file in $Files.Keys) {
    $target = Join-Path $taskTree $file
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
    [IO.File]::WriteAllText($target, $Files[$file], [Text.UTF8Encoding]::new($true))
  }
  [IO.File]::WriteAllText("$taskTree/.crew/prompt.md", $Rules, [Text.UTF8Encoding]::new($true))
  Invoke-FixtureGit -C $taskTree add .
  Invoke-FixtureGit -C $taskTree -c user.name=Test -c user.email=test@example.invalid commit -qm task
}
function Run-FixtureCheck([string]$TaskName = 'sample') {
  $output = & pwsh -NoProfile -File $CheckScript check -Name $TaskName -Path $fixture 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = $output -join "`n" }
}

Describe 'crew check committed task changes' {
  BeforeEach {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $taskTree = "$fixture-task"
    New-Item -ItemType Directory $fixture | Out-Null
    Invoke-FixtureGit -C $fixture init -q -b main
    Invoke-FixtureGit -C $fixture config core.autocrlf false
    Set-Content "$fixture/.gitignore" '.crew/'
    Invoke-FixtureGit -C $fixture add .
    Invoke-FixtureGit -C $fixture -c user.name=Test -c user.email=test@example.invalid commit -qm initial
    Invoke-FixtureGit -C $fixture worktree add -qb crew/sample $taskTree
    New-Item -ItemType Directory "$fixture/.crew", "$taskTree/.crew" | Out-Null
    @(@{ name = 'sample'; branch = 'crew/sample'; worktree = $taskTree }) | ConvertTo-Json | Set-Content "$fixture/.crew/tasks.json" -Encoding UTF8
  }
  AfterEach {
    Invoke-FixtureGit -C $fixture worktree remove --force $taskTree
  }
  It 'accepts allowed files, task notes, and parses both shells' {
    Save-CheckFixture @{ 'scripts/ok.ps1' = 'Write-Output ok'; 'context/tasks/sample.md' = 'note' }
    $r = Run-FixtureCheck
    $r.Code | Should Be 0
    $r.Text | Should Match 'parse : OK'
    $r.Text | Should Match 'không có test thay đổi'
  }
  It 'rejects files outside the prompt list' {
    Save-CheckFixture @{ 'outside.txt' = 'no' }
    $r = Run-FixtureCheck
    $r.Code | Should Be 1
    $r.Text | Should Match 'NGOÀI PHẠM VI: outside.txt'
  }
  It 'accepts globs, directory descendants, and parenthetical comments' {
    Save-CheckFixture @{ 'scripts/a.ps1' = '# ok'; 'skeleton/nested/role.md' = 'ok' } 'Được sửa: `scripts/*.ps1` (mới), `skeleton/` (thư mục)'
    (Run-FixtureCheck).Code | Should Be 0
  }
  It 'does not treat a directory name prefix as a descendant' {
    Save-CheckFixture @{ 'skeleton-other/file.md' = 'no' } 'Được sửa: `skeleton/`'
    (Run-FixtureCheck).Code | Should Be 1
  }
  It 'accepts every backtick path including alternatives inside parentheses' {
    Save-CheckFixture @{ 'tests/CrewSend.Tests.ps1' = '# allowed'; 'tests/CrewArgs.Tests.ps1' = '# alternative' } 'Được sửa: `tests/CrewSend.Tests.ps1` (hoặc file test mới `tests/CrewArgs.Tests.ps1`, UTF-8 BOM)'
    $r = Run-FixtureCheck
    $r.Code | Should Be 0
    $r.Text | Should Match 'phạm vi : OK'
    $r.Text | Should Match 'test : OK'
  }
  It 'does not allow unquoted paths in parenthetical comments' {
    Save-CheckFixture @{ 'outside.txt' = 'no' } 'Được sửa: `scripts/ok.ps1` (chú thích outside.txt, UTF-8 BOM)'
    $r = Run-FixtureCheck
    $r.Code | Should Be 1
    $r.Text | Should Match 'NGOÀI PHẠM VI: outside.txt'
  }
  It 'rejects syntax errors and prints filename plus line' {
    Save-CheckFixture @{ 'scripts/ok.ps1' = 'function Broken {' }
    $r = Run-FixtureCheck
    $r.Code | Should Be 1
    $r.Text | Should Match 'scripts/ok.ps1:1:'
    $r.Text | Should Match 'parse : LỖI'
  }
  It 'warns but skips scope when the prompt has no allowed list' {
    Save-CheckFixture @{ 'anything.txt' = 'ok' } 'Just a prompt'
    $r = Run-FixtureCheck
    $r.Code | Should Be 0
    $r.Text | Should Match 'không có danh sách Được sửa'
    $r.Text | Should Match 'phạm vi : bỏ qua'
  }
  It 'reports a missing task clearly' {
    $r = Run-FixtureCheck 'absent'
    $r.Code | Should Be 1
    $r.Text | Should Match 'task absent không có'
  }
  It 'runs changed tests in the task worktree and propagates failures' {
    Save-CheckFixture @{ 'tests/Example.Tests.ps1' = 'Describe "child" { It "cwd" { (Get-Location).Path | Should Be $PSScriptRoot.Replace("\tests", "") }; It "failure" { 1 | Should Be 2 } }' }
    $r = Run-FixtureCheck
    $r.Code | Should Be 1
    $r.Text | Should Match 'test : LỖI'
    $r.Text | Should Match 'Passed: 1 Failed: 1'
  }
  It 'accepts a passing changed test' {
    Save-CheckFixture @{ 'tests/Example.Tests.ps1' = 'Describe "child" { It "pass" { 1 | Should Be 1 } }' }
    $r = Run-FixtureCheck
    $r.Code | Should Be 0
    $r.Text | Should Match 'test : OK'
  }
}
