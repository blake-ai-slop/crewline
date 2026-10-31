. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$skeletonDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'skeleton'
$skeletonVersion = (Get-Content (Join-Path $skeletonDir 'VERSION') -Raw).Trim()

Describe 'crew upgrade' {
  BeforeEach {
    $h = New-CrewTestHome
    $fakeHome = $h.Home
    $userConfig = Join-Path $fakeHome 'config.json'
    $testEnv = @{ CREWLINE_USER_CONFIG = $userConfig }
    $repo = Join-Path $fakeHome 'project'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo config core.autocrlf false
    git -C $repo config user.name 'Crew Test'
    git -C $repo config user.email 'crew@example.invalid'
    git -C $repo commit -q --allow-empty -m initial
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $output = $result.Output
    if ($result.ExitCode -ne 0) { throw "$output" }
  }

  It 'writes version on init and upgrades old roles with a backup while preserving project files' {
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be $skeletonVersion
    Set-Content "$repo/context/roles/worker.md" 'old role'
    Set-Content "$repo/context/PROJECT.md" 'my project'
    Set-Content "$repo/context/HOT.md" 'my hot'
    Remove-Item "$repo/context/.skeleton-version"
    git -C $repo add context
    git -C $repo commit -q -m old
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    ($output -join "`n") | Should Match "v0 -> v$skeletonVersion"
    [IO.File]::ReadAllText("$repo/context/roles/worker.md") | Should Be ([IO.File]::ReadAllText("$skeletonDir/context/roles/worker.md"))
    $backups = @(Get-ChildItem "$repo/context/roles/worker.md.bak-*")
    $backups.Count | Should Be 1
    (Get-Content $backups[0].FullName -Raw).Trim() | Should Be 'old role'
    (Get-Content "$repo/context/PROJECT.md" -Raw).Trim() | Should Be 'my project'
    (Get-Content "$repo/context/HOT.md" -Raw).Trim() | Should Be 'my hot'
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be $skeletonVersion
    (git -C $repo log -1 --format=%s) | Should Be "chore: crew upgrade context -> v$skeletonVersion"
    @(git -C $repo show --name-only --format= HEAD | Where-Object { $_ -like '*.bak-*' }).Count | Should Be 0
    ($output -join "`n") | Should Match 'worker\.md\.bak-'
    @(git -C $repo status --porcelain --untracked-files=all).Count | Should Be 0
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $result.ExitCode | Should Be 0
    ($result.Output -join "`n") | Should Match 'không có gì mới'
  }

  It 'adds *.bak-* to .gitignore when missing, commits it, never commits backups' {
    [IO.File]::WriteAllText("$repo/.gitignore", ".crew/`n")
    Set-Content "$repo/context/roles/planner.md" 'old planner'
    git -C $repo add .gitignore context
    git -C $repo commit -q -m 'no bak ignore'
    # bản .bak cũ chưa ignore không được coi là context bẩn
    Set-Content "$repo/context/roles/rev.md.bak-20200101" 'stale backup'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    if ($result.ExitCode -ne 0) { throw "$output" }
    (git -C $repo log -1 --format=%s) | Should Be "chore: crew upgrade context -> v$skeletonVersion"
    $committed = @(git -C $repo show --name-only --format= HEAD)
    $committed -ccontains '.gitignore' | Should Be $true
    $committed -ccontains 'context/roles/planner.md' | Should Be $true
    @($committed | Where-Object { $_ -like '*.bak-*' }).Count | Should Be 0
    @(Get-Content "$repo/.gitignore" | ForEach-Object { $_.Trim() }) -ccontains '*.bak-*' | Should Be $true
    @(Get-ChildItem "$repo/context/roles/planner.md.bak-*").Count | Should Be 1
    @(git -C $repo ls-files '*.bak-*').Count | Should Be 0
    @(git -C $repo status --porcelain --untracked-files=all).Count | Should Be 0
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $result.ExitCode | Should Be 0
    ($result.Output -join "`n") | Should Match 'không có gì mới'
  }

  It 'NoCommit writes the missing backup ignore rule and reports that it is uncommitted' {
    [IO.File]::WriteAllText("$repo/.gitignore", ".crew/`r`n")
    git -C $repo add .gitignore
    git -C $repo commit -q -m 'no bak ignore'
    $head = git -C $repo rev-parse HEAD
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit')
    $result.ExitCode | Should Be 0
    $result.Output | Should Match ([regex]::Escape('đã thêm *.bak-* vào .gitignore (chưa commit)'))
    @(Get-Content "$repo/.gitignore" | ForEach-Object { $_.Trim() }) -ccontains '*.bak-*' | Should Be $true
    (git -C $repo rev-parse HEAD) | Should Be $head
    @(git -C $repo diff --name-only) -ccontains '.gitignore' | Should Be $true
    @(git -C $repo diff --cached --name-only).Count | Should Be 0
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-DryRun', '-Force')
    $result.ExitCode | Should Be 0
    $result.Output | Should Not Match ([regex]::Escape('sẽ thêm *.bak-* vào .gitignore.'))
  }

  It 'adds missing pitfalls once and leaves the original text intact' {
    $bullet = @(Get-Content "$skeletonDir/context/PITFALLS.md" -Encoding utf8 | Where-Object { $_ -like '- *' })[0]
    $original = "# My pitfalls`n`n- private rule`n  $bullet  `n"
    [IO.File]::WriteAllText("$repo/context/PITFALLS.md", $original)
    git -C $repo add context
    git -C $repo commit -q -m custom
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit')
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $text = [IO.File]::ReadAllText("$repo/context/PITFALLS.md")
    $text.StartsWith($original) | Should Be $true
    @($text -split '\r?\n' | Where-Object { $_.Trim() -ceq $bullet }).Count | Should Be 1
    foreach ($line in Get-Content "$skeletonDir/context/PITFALLS.md" -Encoding utf8 | Where-Object { $_ -like '- *' }) {
      @($text -split '\r?\n' | ForEach-Object { $_.Trim() }) -ccontains $line.Trim() | Should Be $true
    }
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit', '-Force')
    $output = $result.Output
    $result.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/context/PITFALLS.md") | Should Be $text
  }

  It 'does not write or commit in DryRun' {
    [IO.File]::WriteAllText("$repo/.gitignore", ".crew/`r`n")
    $ignoreBefore = [IO.File]::ReadAllText("$repo/.gitignore")
    Set-Content "$repo/context/roles/rev.md" 'old'
    git -C $repo add .gitignore context
    git -C $repo commit -q -m old
    $head = git -C $repo rev-parse HEAD
    $before = git -C $repo status --porcelain --untracked-files=all
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-DryRun')
    $output = $result.Output
    $result.ExitCode | Should Be 0
    ($output -join "`n") | Should Match 'sao lưu'
    $output | Should Match ([regex]::Escape('sẽ thêm *.bak-* vào .gitignore.'))
    [IO.File]::ReadAllText("$repo/.gitignore") | Should Be $ignoreBefore
    (Get-Content "$repo/context/roles/rev.md" -Raw).Trim() | Should Be 'old'
    @(Get-ChildItem "$repo/context/roles/*.bak-*").Count | Should Be 0
    (git -C $repo status --porcelain --untracked-files=all) | Should Be $before
    (git -C $repo rev-parse HEAD) | Should Be $head
  }

  It 'refuses dirty and untracked context unless forced; NoCommit leaves HEAD unchanged' {
    Set-Content "$repo/context/new.md" 'private'
    $head = git -C $repo rev-parse HEAD
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 1
    ($output -join "`n") | Should Match 'context/ có thay đổi'
    Set-Content "$repo/context/roles/rev.md" 'dirty'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-Force', '-NoCommit')
    $output = $result.Output
    $result.ExitCode | Should Be 0
    (git -C $repo rev-parse HEAD) | Should Be $head
    @(git -C $repo status --porcelain).Count | Should BeGreaterThan 0
  }

  It 'replaces delimited and legacy crew blocks, preserving surrounding text and unrelated staged files' {
    $legacy = "before`n<!-- crew -->`n## Context dùng chung (crew)`nold read instruction`n- old rule`n`nafter`n"
    [IO.File]::WriteAllText("$repo/CLAUDE.md", $legacy)
    [IO.File]::WriteAllText("$repo/AGENTS.md", "prefix`n<!-- crew -->`nold`n<!-- /crew -->`nsuffix`n")
    Set-Content "$repo/unrelated.txt" 'staged'
    git -C $repo add unrelated.txt
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $text = Get-Content "$repo/CLAUDE.md" -Raw -Encoding utf8
    $text | Should Match '^before\n<!-- crew -->'
    $text | Should Match '<!-- /crew -->\n\nafter\n$'
    $text | Should Not Match 'old rule'
    (Get-Content "$repo/AGENTS.md" -Raw) | Should Match '<!-- /crew -->\nsuffix\n$'
    foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
      $updated = [IO.File]::ReadAllText("$repo/$name")
      $updated | Should Match ([regex]::Escape('- Bản đồ code: context/MAP.md.'))
      $updated | Should Match ([regex]::Escape('- Không push (chỉ planner push khi chủ dự án cho phép). Mặc định chế độ gọn: worker chạy test của phần mình, không tự review.'))
      $updated | Should Not Match 'old'
    }
    (Get-Content "$repo/AGENTS.md" -Raw) | Should Match '^prefix\n<!-- crew -->'
    @(git -C $repo diff --cached --name-only) | Should Be 'unrelated.txt'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    ($output -join "`n") | Should Match 'không có gì mới'
  }

  It 'copies missing skeleton files and never modifies tasks or archive' {
    Remove-Item "$repo/context/MAP.md"
    Set-Content "$repo/context/tasks/private.md" 'task'
    Set-Content "$repo/context/archive/private.md" 'archive'
    git -C $repo add context
    git -C $repo commit -q -m missing
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/context/MAP.md") | Should Be ([IO.File]::ReadAllText("$skeletonDir/context/MAP.md"))
    (Get-Content "$repo/context/tasks/private.md" -Raw).Trim() | Should Be 'task'
    (Get-Content "$repo/context/archive/private.md" -Raw).Trim() | Should Be 'archive'
  }
}
