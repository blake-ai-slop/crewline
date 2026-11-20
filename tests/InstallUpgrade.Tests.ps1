. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent

Describe 'real bootstrap -> patch update' {
  It 'updates v15 to v15.1 and displays the matching release notes' {
    $bootstrap = Join-Path $RepoRoot 'bootstrap.ps1'
    $source = Join-Path $TestDrive 'release'
    git init -q -b main $source
    git -C $source config core.autocrlf false
    git -C $source config user.name 'Crew Test'
    git -C $source config user.email 'crew@example.invalid'
    foreach ($item in 'install.ps1', 'scripts', 'skeleton', 'templates') {
      Copy-Item -LiteralPath (Join-Path $RepoRoot $item) -Destination $source -Recurse
    }
    Set-Content (Join-Path $source 'VERSION') '15'
    git -C $source add -A
    git -C $source commit -q -m v15
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the v15 fixture.' }

    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'Crewline'
    $settings = @{
      CREWLINE_REPO = $source
      CREWLINE_DIR = $dir
      CREWLINE_BRANCH = 'main'
      CREWLINE_NO_INSTALL = '1'
      CREWLINE_NO_JQ = '1'
      CREWLINE_NO_PATH = '1'
    }
    $first = Invoke-InTestHome $h $bootstrap -Env $settings
    if ($first.ExitCode -ne 0) { throw $first.Output }

    Set-Content (Join-Path $source 'VERSION') '15.1'
    @"
## v15x1 — wrong heading
- **wrong release notes**

## v15.1 — patch
- **correct release notes**
"@ | Set-Content (Join-Path $source 'CHANGELOG.md') -Encoding utf8
    git -C $source add -A
    git -C $source commit -q -m v15.1
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the v15.1 fixture.' }

    $r = Invoke-InTestHome $h $bootstrap -Env $settings
    if ($r.ExitCode -ne 0) { throw $r.Output }
    $r.Output | Should Match 'cap nhat Crewline v15 -> v15\.1 \(commit \w+ -> \w+, khung context v[0-9]+\)'
    $r.Output | Should Match '(?m)^== .*Crewline v15\.1$'
    $r.Output | Should Match 'correct release notes'
    $r.Output | Should Not Match 'wrong release notes'

    $r = Invoke-InTestHome $h (Join-Path $dir 'scripts/crew.ps1') -Arguments 'version'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match '(?m)^Crewline v15\.1$'
  }
}

Describe 'real install -> personal config -> init -> upgrade' {
  It 'uses the installed shim and fake HOME defaults, then upgrades and preserves project settings' {
    $h = New-CrewTestHome
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $RepoRoot 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_NO_JQ = '1' }
    if ($r.ExitCode -ne 0) { throw $r.Output }
    Test-Path (Join-Path $h.Home '.crewline') -PathType Container | Should Be $true
    $personalConfig = Join-Path $h.Home '.crewline/config.json'
    Set-Content $personalConfig '{"team":"large","review":"full","access":"wide"}'
    $repo = Join-Path $h.Home 'project'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo config core.autocrlf false
    git -C $repo config user.name 'Crew Test'
    git -C $repo config user.email 'crew@example.invalid'
    git -C $repo commit -q --allow-empty -m initial
    # Unix: shim là file thực thi `crew` (shebang pwsh), không có crew.ps1.
    $shimName = if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { 'crew' } else { 'crew.ps1' }
    $shim = Join-Path $h.Home ".local/bin/$shimName"
    $r = Invoke-InTestHome -TestHome $h -File $shim -Arguments 'init', '-Path', $repo
    if ($r.ExitCode -ne 0) { throw $r.Output }
    $cfg = Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json
    $cfg.workers.Count | Should Be 4
    $cfg.review | Should Be 'full'
    $cfg.access | Should Be 'wide'
    $configBefore = [IO.File]::ReadAllText("$repo/.crew/config.json")
    $hotBefore = [IO.File]::ReadAllText("$repo/context/HOT.md")
    $projectBefore = [IO.File]::ReadAllText("$repo/context/PROJECT.md")
    Set-Content "$repo/context/roles/worker.md" 'old worker role'
    Remove-Item -Force "$repo/context/.skeleton-version"
    git -C $repo add context
    git -C $repo commit -q -m old
    $r = Invoke-InTestHome -TestHome $h -File $shim -Arguments 'upgrade', '-Path', $repo
    if ($r.ExitCode -ne 0) { throw $r.Output }
    # role đã sửa tay: giữ nguyên, bản mới ra .new (không commit)
    (Get-Content "$repo/context/roles/worker.md" -Raw).Trim() | Should Be 'old worker role'
    [IO.File]::ReadAllText("$repo/context/roles/worker.md.new") | Should Be ([IO.File]::ReadAllText("$RepoRoot/skeleton/context/roles/worker.md"))
    @(Get-ChildItem "$repo/context/roles/worker.md.bak-*").Count | Should Be 0
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be ((Get-Content "$RepoRoot/skeleton/VERSION" -Raw).Trim())
    [IO.File]::ReadAllText("$repo/.crew/config.json") | Should Be $configBefore
    [IO.File]::ReadAllText("$repo/context/HOT.md") | Should Be $hotBefore
    [IO.File]::ReadAllText("$repo/context/PROJECT.md") | Should Be $projectBefore
    (Get-Content $personalConfig -Raw).Trim() | Should Be '{"team":"large","review":"full","access":"wide"}'
    @(git -C $repo status --porcelain).Count | Should Be 0
  }
}
