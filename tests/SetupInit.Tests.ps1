. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$CrewScript = Join-Path $RepoRoot 'scripts/crew.ps1'
$SetupScript = Join-Path $RepoRoot 'scripts/setup.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
# Empty command stubs on PATH: .cmd on Windows, executable sh on Linux/macOS; PATH holds only the stub dir (+ System32 on Windows).
function New-AgentStub([string]$Bin, [string]$Name) {
  if ($OnWindows) { Set-Content (Join-Path $Bin "$Name.cmd") '@exit /b 0'; return }
  $file = Join-Path $Bin $Name
  [IO.File]::WriteAllText($file, "#!/bin/sh`nexit 0`n")
  & chmod +x $file
}
function Get-StubPathEnv([string]$Bin) {
  if ($OnWindows) { @{ Path = "$Bin;$env:SystemRoot\System32" } } else { @{ PATH = $Bin } }
}

# Exercise both branches' real scripts and teams.json. Agent stubs are only
# discovered on PATH; this workflow never launches agents or contacts hc.
Describe 'real setup -> personal defaults -> crew init' {
  BeforeEach {
    $h = New-CrewTestHome
    $bin = Join-Path $h.Home 'agents'
    $project = Join-Path $h.Home 'project'
    New-Item -ItemType Directory $bin, $project | Out-Null
    foreach ($agent in 'claude', 'codex') { New-AgentStub $bin $agent }
    $setupEnv = Get-StubPathEnv $bin; $setupEnv.CREWLINE_DEFAULTS = ''
    git -C $project init -q
    git -C $project config core.autocrlf false
    git -C $project -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m initial
  }

  function Read-Personal { Get-Content (Join-Path $h.Home '.crewline/config.json') -Raw | ConvertFrom-Json }
  function Init-FromPersonal {
    $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $project, '-NoCommit')
    $r.ExitCode | Should Be 0 | Out-Null
    Get-Content (Join-Path $project '.crew/config.json') -Raw | ConvertFrom-Json
  }

  It 'custom one worker retains array and forces fast without Rev' {
    $r = Invoke-InTestHome -TestHome $h -File $SetupScript -Env $setupEnv -InputText "custom`ncodex`n1`ncodex`nnone`nwide`n"
    $r.ExitCode | Should Be 0
    $personal = Read-Personal
    $personal.team | Should Be 'custom'
    @($personal.PSObject.Properties).Count | Should Be 6
    # Even an explicit review flag cannot enable review without a Rev.
    $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $project, '-NoCommit', '-Review', 'full')
    $r.ExitCode | Should Be 0
    $cfg = Get-Content (Join-Path $project '.crew/config.json') -Raw | ConvertFrom-Json
    $cfg.planner | Should Be 'codex'
    $cfg.workers -is [array] | Should Be $true
    @($cfg.workers).Count | Should Be 1
    $cfg.workers[0] | Should Be 'codex'
    $cfg.rev | Should Be 'none'
    $cfg.review | Should Be 'fast'
    $cfg.access | Should Be 'wide'
  }

  It 'crew setup dispatch custom six workers preserves all roles and settings' {
    $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments 'setup' -Env $setupEnv -InputText "4`nnone`n6`nclaude`ncodex`nclaude`ncodex`nclaude`ncodex`nclaude`nfull`nwide`n"
    $r.ExitCode | Should Be 0
    (Read-Personal).team | Should Be 'custom'
    $cfg = Init-FromPersonal
    $cfg.planner | Should Be 'none'
    @($cfg.workers).Count | Should Be 6
    ($cfg.workers -join ',') | Should Be 'claude,codex,claude,codex,claude,codex'
    $cfg.rev | Should Be 'claude'
    $cfg.review | Should Be 'full'
    $cfg.access | Should Be 'wide'
  }

  It 'solo uses the shared real preset through setup and init' {
    $r = Invoke-InTestHome -TestHome $h -File $SetupScript -Env $setupEnv -InputText "solo`nwork`n"
    $r.ExitCode | Should Be 0
    (Read-Personal).team | Should Be 'solo'
    $cfg = Init-FromPersonal
    $cfg.planner | Should Be 'none'
    @($cfg.workers).Count | Should Be 1
    $cfg.workers[0] | Should Be 'claude'
    $cfg.rev | Should Be 'none'
    $cfg.review | Should Be 'fast'
    $cfg.access | Should Be 'work'
  }

  It 'real install without DEFAULTS and with EOF writes defaults consumed by init' {
    $setupEnv.CREWLINE_NO_JQ = '1'
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $RepoRoot 'install.ps1') -Arguments '-NoDoctor' -Env $setupEnv -InputText ''
    $r.ExitCode | Should Be 0
    $personal = Read-Personal
    $personal.team | Should Be 'standard'
    @($personal.PSObject.Properties).Count | Should Be 6
    $cfg = Init-FromPersonal
    $cfg.planner | Should Be 'claude'
    ($cfg.workers -join ',') | Should Be 'claude,codex'
    $cfg.rev | Should Be 'codex'
    $cfg.review | Should Be 'lean'
    $cfg.access | Should Be 'work'
  }
}
