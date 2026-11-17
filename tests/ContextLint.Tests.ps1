. (Join-Path $PSScriptRoot '../scripts/lint.ps1')
$lintCrew = Join-Path $PSScriptRoot '../scripts/crew.ps1'
Describe 'Get-ContextLint chỉ đọc' {
  BeforeEach {
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $repo 'context') -Force | Out-Null
    git -C $repo init -q
    'function Get-Current { }' | Set-Content (Join-Path $repo 'code.ps1')
    git -C $repo add code.ps1
  }
  It 'repo sạch; tên hàm trong code tracked, bỏ qua archive/tasks và mẫu đường dẫn' {
    '- `Get-Current` `code.ps1` `https://example.com/a` `<root>/x` `~/x` `%APPDATA%/x` `$root/x` `x/*`' | Set-Content (Join-Path $repo 'context/MAP.md')
    foreach ($dir in 'archive','tasks') {
      New-Item -ItemType Directory (Join-Path $repo "context/$dir") | Out-Null
      ('- ' + ('x' * 7000)) | Set-Content (Join-Path $repo "context/$dir/HOT.md")
    }
    @(Get-ContextLint $repo).Count | Should Be 0
  }
  It 'trần dòng không rỗng đúng bốn file, biên bằng ngưỡng không cảnh báo' {
    $limits = Get-LintLimits
    foreach ($file in $limits.Lines.Keys) {
      $n = $limits.Lines[$file]
      (@('line') * $n + @('','')) | Set-Content (Join-Path $repo "context/$file")
    }
    @(Get-ContextLint $repo).Count | Should Be 0
    foreach ($file in $limits.Lines.Keys) { Add-Content (Join-Path $repo "context/$file") 'extra' }
    $warnings = @(Get-ContextLint $repo)
    @($warnings | Where-Object Rule -eq 'line-limit').Count | Should Be 4
  }
  It 'mục dài gồm dòng nối; trùng nguyên văn giữa file; file quá 6 KB' {
    ('- ' + ('x' * 200) + "`n  " + ('y' * 100)) | Set-Content (Join-Path $repo 'context/HOT.md')
    '- shared' | Add-Content (Join-Path $repo 'context/HOT.md')
    @('- shared', ('z' * 6200)) | Set-Content (Join-Path $repo 'context/DECISIONS.md')
    $warnings = @(Get-ContextLint $repo)
    @($warnings | Where-Object Rule -eq 'item-length').Count | Should Be 1
    @($warnings | Where-Object Rule -eq 'duplicate').Count | Should Be 1
    @($warnings | Where-Object Rule -eq 'file-size').Count | Should Be 1
  }
  It 'tên cũ chỉ kiểm code tracked ngoài context; đường dẫn và số dòng chính xác' {
    'Get-Gone' | Set-Content (Join-Path $repo 'untracked.ps1')
    @('# Map', '- `Get-Gone` `missing/file.md`', '- `Get-Current` `code.ps1`') | Set-Content (Join-Path $repo 'context/MAP.md')
    $before = (git -C $repo status --porcelain) -join "`n"
    $warnings = @(Get-ContextLint $repo)
    $warnings.Count | Should Be 2
    $warnings[0].File | Should Be 'context/MAP.md'
    $warnings[0].Line | Should Be 2
    $warnings[0].Message | Should Match 'tên không còn trong code'
    ((git -C $repo status --porcelain) -join "`n") | Should Be $before
  }
  It 'bỏ qua khoảng trắng, slash command và ổ đĩa Windows' {
    '- `irm … | iex` `hc server stop/restart` `claude -p /usage …` `C:/Program Files/Git/new` `/new` `/clear` `/…` `Z:/missing.md` `X:missing.json` `docs/gone space.md`' | Set-Content (Join-Path $repo 'context/MAP.md')
    @(Get-ContextLint $repo).Count | Should Be 0
  }
  It 'giải đường dẫn từ repo rồi context, tên trần dùng basename file tracked ở mọi nơi' {
    foreach ($dir in 'context/archive','scripts','tests') { New-Item -ItemType Directory (Join-Path $repo $dir) -Force | Out-Null }
    'archive' | Set-Content (Join-Path $repo 'context/archive/HOT-2026-11.md')
    'script' | Set-Content (Join-Path $repo 'scripts/setup.ps1')
    'helper' | Set-Content (Join-Path $repo 'tests/TestHome.ps1')
    git -C $repo add scripts tests context/archive
    '- `code.ps1` `archive/HOT-2026-11.md` `archive/` `setup.ps1` `TestHome.ps1` `missing.md` `gone/file.json`' | Set-Content (Join-Path $repo 'context/MAP.md')
    $warnings = @(Get-ContextLint $repo)
    $warnings.Count | Should Be 2
    ($warnings.Message -join ';') | Should Match 'missing.md.*gone/file.json'
    'untracked' | Set-Content (Join-Path $repo 'tests/Untracked.ps1')
    '- `Untracked.ps1`' | Set-Content (Join-Path $repo 'context/MAP.md')
    @(Get-ContextLint $repo).Count | Should Be 1
  }
  It 'git ignore một lần cho cả lô kể cả file và thư mục chưa tồn tại' {
    @('.crew/', 'cache/', 'ignored.md') | Set-Content (Join-Path $repo '.gitignore')
    '- `.crew/config.json` `.crew/sessions.json` `.crew/self-pane.log` `cache/not-created/file.md` `ignored.md` `missing.md`' | Set-Content (Join-Path $repo 'context/MAP.md')
    $script:LintGitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $script:LintIgnoreCalls = 0
    function git {
      $inputLines = @($input)
      if ($args -contains 'check-ignore') {
        $script:LintIgnoreCalls++
        $inputLines | & $script:LintGitExe @args
      } else { & $script:LintGitExe @args }
    }
    $warnings = @(Get-ContextLint $repo)
    $script:LintIgnoreCalls | Should Be 1
    $warnings.Count | Should Be 1
    $warnings[0].Message | Should Match '^missing.md'
  }
  It 'chỉ nhận đúng chữ hoa của tên hàm PowerShell và chỉ kiểm ba file quy định' {
    '- `crewline-dev` `get-Gone` `Get-gone` `GET-Gone` `Get-Gone` `missing.md`' | Set-Content (Join-Path $repo 'context/MAP.md')
    '- `Get-HotGone` `tools/smoke.ps1`' | Set-Content (Join-Path $repo 'context/HOT.md')
    '- `Get-OtherGone` `other/file.md`' | Set-Content (Join-Path $repo 'context/PROJECT.md')
    foreach ($file in 'DECISIONS','PITFALLS') { '- `Get-Gone` `missing.md`' | Set-Content (Join-Path $repo "context/$file.md") }
    $warnings = @(Get-ContextLint $repo)
    @($warnings | Where-Object Rule -eq 'missing-function').Count | Should Be 3
    @($warnings | Where-Object Rule -eq 'missing-path').Count | Should Be 3
    @($warnings | Where-Object { $_.File -in 'context/HOT.md','context/PROJECT.md' }).Count | Should Be 0
  }
  It 'dispatch tìm gốc repo khi Path là thư mục con hoặc cwd là thư mục con' {
    '- `Get-Gone`' | Set-Content (Join-Path $repo 'context/MAP.md')
    $child = Join-Path $repo 'child'
    New-Item -ItemType Directory $child | Out-Null
    $out = & pwsh -NoProfile -File $lintCrew lint -Path $child -Strict
    $LASTEXITCODE | Should Be 1
    ($out -join "`n") | Should Match 'context/MAP.md:1 missing-function:'
    Push-Location -LiteralPath $child
    try { $out = & pwsh -NoProfile -File $lintCrew lint -Strict; $code = $LASTEXITCODE } finally { Pop-Location }
    $code | Should Be 1
    ($out -join "`n") | Should Match 'context/MAP.md:1 missing-function:'
  }
  It 'dispatch từ chối thư mục không phải repo git' {
    $out = & pwsh -NoProfile -File $lintCrew lint -Path $TestDrive
    $LASTEXITCODE | Should Be 1
    ($out -join "`n") | Should Match 'không phải repo git'
  }
  It 'thiếu context trả sạch' {
    @(Get-ContextLint $TestDrive).Count | Should Be 0
  }
  It 'dispatch thật mặc định exit 0; Strict exit 1 khi có cảnh báo, không thay file' {
    '- `Get-Gone`' | Set-Content (Join-Path $repo 'context/MAP.md')
    $before = (git -C $repo status --porcelain) -join "`n"
    $out = & pwsh -NoProfile -File $lintCrew lint -Path $repo
    $LASTEXITCODE | Should Be 0
    ($out -join "`n") | Should Match 'context/MAP.md:1 missing-function:'
    ($out -join "`n") | Should Match 'context: 1 cảnh báo'
    $null = & pwsh -NoProfile -File $lintCrew lint -Path $repo -Strict
    $LASTEXITCODE | Should Be 1
    ((git -C $repo status --porcelain) -join "`n") | Should Be $before
    '- ok' | Set-Content (Join-Path $repo 'context/MAP.md')
    $out = & pwsh -NoProfile -File $lintCrew lint -Path $repo -Strict
    $LASTEXITCODE | Should Be 0
    ($out -join "`n") | Should Be 'context sạch'
  }
}
