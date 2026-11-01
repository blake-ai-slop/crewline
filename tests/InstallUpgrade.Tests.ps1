. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent

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
    [IO.File]::ReadAllText("$repo/context/roles/worker.md") | Should Be ([IO.File]::ReadAllText("$RepoRoot/skeleton/context/roles/worker.md"))
    @(Get-ChildItem "$repo/context/roles/worker.md.bak-*").Count | Should Be 1
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be ((Get-Content "$RepoRoot/skeleton/VERSION" -Raw).Trim())
    [IO.File]::ReadAllText("$repo/.crew/config.json") | Should Be $configBefore
    [IO.File]::ReadAllText("$repo/context/HOT.md") | Should Be $hotBefore
    [IO.File]::ReadAllText("$repo/context/PROJECT.md") | Should Be $projectBefore
    (Get-Content $personalConfig -Raw).Trim() | Should Be '{"team":"large","review":"full","access":"wide"}'
    @(git -C $repo status --porcelain).Count | Should Be 0
  }
}
