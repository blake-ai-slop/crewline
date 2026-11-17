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
    Remove-Item -Force "$repo/context/.skeleton-version"
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

  It 'does not re-add pitfalls already moved to context/archive/PITFALLS-*.md' {
    $bullets = @(Get-Content "$skeletonDir/context/PITFALLS.md" -Encoding utf8 | Where-Object { $_ -like '- *' })
    $original = "# My pitfalls`n`n- private rule`n"
    [IO.File]::WriteAllText("$repo/context/PITFALLS.md", $original)
    [IO.File]::WriteAllText("$repo/context/archive/PITFALLS-2026-10.md", "# old`r`n`r`n  $($bullets[0])  `r`n")
    [IO.File]::WriteAllText("$repo/context/archive/PITFALLS-2026-11.md", (($bullets | Select-Object -Skip 1) -join "`n") + "`n")
    git -C $repo add context
    git -C $repo commit -q -m archived
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-DryRun')
    $result.ExitCode | Should Be 0
    ($result.Output -join "`n") | Should Not Match 'PITFALLS\.md'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit')
    $result.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/context/PITFALLS.md") | Should Be $original
    # file archive khác mẫu PITFALLS-*.md không tính: dòng thiếu vẫn được thêm
    Remove-Item "$repo/context/archive/PITFALLS-2026-11.md"
    Set-Content "$repo/context/archive/OLD-PITFALLS.md" (($bullets | Select-Object -Skip 1) -join "`n") -Encoding utf8
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit', '-Force')
    $result.ExitCode | Should Be 0
    $got = @([IO.File]::ReadAllText("$repo/context/PITFALLS.md") -split "`r?`n" | ForEach-Object { $_.Trim() })
    @($got | Where-Object { $_ -ceq $bullets[0].Trim() }).Count | Should Be 0
    @($got | Where-Object { $_ -ceq $bullets[1].Trim() }).Count | Should Be 1
  }

  # Repo public không phát hành context nội bộ; các ca fixture tổng quát ở trên/dưới vẫn chạy.
  It 'on a copy of this repo context, pitfalls already in archive/PITFALLS-*.md are not re-added' -Skip:(-not (Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'context') -PathType Container)) {
    $real = Join-Path (Split-Path $PSScriptRoot -Parent) 'context'
    Remove-Item -Recurse -Force "$repo/context"
    Copy-Item -Recurse $real "$repo/context"
    git -C $repo add -A context
    git -C $repo commit -q -m copy
    $trim = { param($files) @(Get-Content $files -Encoding utf8 | ForEach-Object { $_.Trim() }) }
    $current = & $trim "$repo/context/PITFALLS.md"
    $archived = & $trim @(Get-ChildItem "$repo/context/archive" -Filter 'PITFALLS-*.md' | ForEach-Object { $_.FullName })
    $skel = @(& $trim "$skeletonDir/context/PITFALLS.md" | Where-Object { $_.StartsWith('- ') })
    $have = @($current) + @($archived)
    $expect = @($skel | Where-Object { $s = $_; -not @($have | Where-Object { $_.StartsWith($s, [StringComparison]::Ordinal) }).Count })
    # quyết định planner 2026-11-17: trên repo này chỉ còn đúng 1 dòng không có ở đâu
    $expect.Count | Should Be 1
    $expect[0] | Should Match '^- Tên terminal hc là duy nhất'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-DryRun')
    $result.ExitCode | Should Be 0
    if (-not $expect.Count) { ($result.Output -join "`n") | Should Not Match 'PITFALLS\.md' }
    $before = [IO.File]::ReadAllText("$repo/context/PITFALLS.md")
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit')
    $result.ExitCode | Should Be 0
    $after = [IO.File]::ReadAllText("$repo/context/PITFALLS.md")
    $added = @($after.Substring($before.Length) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    ($added -join "`n") | Should BeExactly ($expect -join "`n")
    foreach ($line in $added) { $archived -ccontains $line | Should Be $false }
  }

  It 'counts a longer line starting with the skeleton bullet (in PITFALLS or archive) as present, not one containing it mid-line' {
    $bullets = @(Get-Content "$skeletonDir/context/PITFALLS.md" -Encoding utf8 | Where-Object { $_ -like '- *' } | ForEach-Object { $_.Trim() })
    $original = "# My pitfalls`n`n  $($bullets[0]) Thêm chi tiết riêng của dự án.`n"
    [IO.File]::WriteAllText("$repo/context/PITFALLS.md", $original)
    $arch = @("  $($bullets[1]) Chi tiết sự cố ở archive.", "Ghi chú: $($bullets[2])", "$($bullets[3].ToUpper())")
    $arch += @($bullets | Select-Object -Skip 4)
    [IO.File]::WriteAllText("$repo/context/archive/PITFALLS-2026-11.md", ($arch -join "`n") + "`n")
    git -C $repo add context
    git -C $repo commit -q -m prefix
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('upgrade', '-Path', $repo, '-NoCommit')
    $result.ExitCode | Should Be 0
    $text = [IO.File]::ReadAllText("$repo/context/PITFALLS.md")
    $text.StartsWith($original) | Should Be $true
    $added = @($text.Substring($original.Length) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # chỉ dòng 3 (chỉ chứa ở giữa) và dòng 4 (khác hoa thường) được thêm
    ($added -join "`n") | Should BeExactly (@($bullets[2], $bullets[3]) -join "`n")
  }
}