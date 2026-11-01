. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Bootstrap = Join-Path $RepoRoot 'bootstrap.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

# Repo Crewline gia trong TestDrive: install.ps1 chi ghi dau vao HOME gia, khong goi mang/hc.
function New-FakeCrewlineRepo {
  $src = Join-Path $TestDrive "src-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force (Join-Path $src 'scripts') | Out-Null
  Set-Content (Join-Path $src 'scripts/crew.ps1') '# crew gia'
  Set-Content (Join-Path $src 'install.ps1') 'Add-Content (Join-Path $HOME "install-ran.txt") "ran"'
  git init -q -b main $src
  git -C $src config core.autocrlf false
  Invoke-Git $src add -A
  Invoke-Git $src commit -q -m init
  $src
}

function Invoke-Git($repo) { git -C $repo -c user.name=test -c user.email=test@example.com @args }
function Get-InstallRuns($h) {
  $f = Join-Path $h.Home 'install-ran.txt'
  if (Test-Path $f) { @(Get-Content $f).Count } else { 0 }
}

Describe 'bootstrap.ps1' {
  $src = New-FakeCrewlineRepo

  Context 'Dir chua co' {
    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'Crewline'
    $r = Invoke-InTestHome -TestHome $h -File $Bootstrap -Arguments '-Dir', $dir, '-Repo', $src

    It 'clone moi roi chay install.ps1' {
      $r.ExitCode | Should Be 0
      Test-Path (Join-Path $dir 'scripts/crew.ps1') | Should Be $true
      Get-InstallRuns $h | Should Be 1
    }

    It 'khong con canh bao le ve herdr/hc/claude/codex (install in bang kiem)' {
      $r.Output | Should Not Match 'chua thay'
    }

    It 'chay lai thi git pull commit moi' {
      Set-Content (Join-Path $src 'new.txt') 'moi'
      Invoke-Git $src add -A
      Invoke-Git $src commit -q -m second
      $r2 = Invoke-InTestHome -TestHome $h -File $Bootstrap -Arguments '-Dir', $dir, '-Repo', $src
      $r2.ExitCode | Should Be 0
      Test-Path (Join-Path $dir 'new.txt') | Should Be $true
      Get-InstallRuns $h | Should Be 2
    }

    It 'worktree ban thi khong pull, canh bao, van chay install' {
      Set-Content (Join-Path $dir 'scripts/crew.ps1') '# sua tay'
      Set-Content (Join-Path $src 'third.txt') 'ba'
      Invoke-Git $src add -A
      Invoke-Git $src commit -q -m third
      $r3 = Invoke-InTestHome -TestHome $h -File $Bootstrap -Arguments '-Dir', $dir, '-Repo', $src
      $r3.ExitCode | Should Be 0
      $r3.Output | Should Match 'bo qua git pull'
      Test-Path (Join-Path $dir 'third.txt') | Should Be $false
      (Get-Content (Join-Path $dir 'scripts/crew.ps1') -Raw).Trim() | Should Be '# sua tay'
      Get-InstallRuns $h | Should Be 3
    }
  }

  Context 'Dir la (khong phai Crewline)' {
    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'Khac'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir 'cua-toi.txt') 'giu nguyen'
    $r = Invoke-InTestHome -TestHome $h -File $Bootstrap -Arguments '-Dir', $dir, '-Repo', $src

    It 'dung voi ma loi, khong ghi de, khong chay install' {
      $r.ExitCode | Should Not Be 0
      $r.Output | Should Match 'Khong ghi de'
      @(Get-ChildItem -Force $dir).Count | Should Be 1
      (Get-Content (Join-Path $dir 'cua-toi.txt') -Raw).Trim() | Should Be 'giu nguyen'
      Get-InstallRuns $h | Should Be 0
    }
  }

  Context 'bien moi truong thay cho tham so (chay qua iex)' {
    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'TuEnv'
    $r = Invoke-InTestHome -TestHome $h -File $Bootstrap -Env @{ CREWLINE_DIR = $dir; CREWLINE_REPO = $src; CREWLINE_BRANCH = 'main' }

    It 'doc CREWLINE_DIR/CREWLINE_REPO/CREWLINE_BRANCH' {
      $r.ExitCode | Should Be 0
      Test-Path (Join-Path $dir 'install.ps1') | Should Be $true
      Get-InstallRuns $h | Should Be 1
    }
  }

  Context 'chay qua Invoke-Expression' {
    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'QuaIex'
    $runner = Join-Path $TestDrive 'iex-runner.ps1'
    Set-Content $runner "Get-Content '$Bootstrap' -Raw | Invoke-Expression; 'SHELL-CON-SONG'"
    $r = Invoke-InTestHome -TestHome $h -File $runner -Env @{ CREWLINE_DIR = $dir; CREWLINE_REPO = $src }

    It 'clone + install va khong exit shell goi no' {
      $r.Output | Should Match 'SHELL-CON-SONG'
      Test-Path (Join-Path $dir 'install.ps1') | Should Be $true
      Get-InstallRuns $h | Should Be 1
    }
  }

  # powershell.exe chỉ có trên Windows: Linux/macOS bỏ cả Context.
  if ($OnWindows) { Context 'Windows PowerShell 5.1 (dan vao powershell.exe)' {
    $h = New-CrewTestHome
    $dir = Join-Path $h.Home 'Ps51'
    $runner = Join-Path $TestDrive 'iex-runner-51.ps1'
    Set-Content $runner "Get-Content '$Bootstrap' -Raw | Invoke-Expression; 'SHELL-CON-SONG'"
    # pwsh cha them $PSHOME (thu muc goi WindowsApps, khong chay truc tiep duoc) vao PATH cua tien trinh con; nguoi dung that khong co
    $path = ($env:Path -split ';' | Where-Object { $_ -and ($PSHOME -notmatch '\\WindowsApps\\' -or $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\')) }) -join ';'
    $r = Invoke-InTestHome -TestHome $h -File $runner -Shell 'powershell' -Env @{ CREWLINE_DIR = $dir; CREWLINE_REPO = $src; Path = $path }

    It 'chay duoc tren 5.1, clone + goi install bang pwsh' {
      $r.Output | Should Match 'SHELL-CON-SONG'
      Test-Path (Join-Path $dir 'install.ps1') | Should Be $true
      Get-InstallRuns $h | Should Be 1
    }
  } }
}

Describe 'bootstrap truyen stdin va DEFAULTS qua iex' {
  $src = New-FakeCrewlineRepo
  Set-Content (Join-Path $src 'install.ps1') @'
$line = [Console]::ReadLine()
@{ input = $line; defaults = $env:CREWLINE_DEFAULTS } | ConvertTo-Json | Set-Content (Join-Path $HOME 'bootstrap-input.json')
'@
  Invoke-Git $src add -A
  Invoke-Git $src commit -q -m stdin
  $runner = Join-Path $TestDrive 'bootstrap-stdin.ps1'
  Set-Content $runner "Get-Content '$Bootstrap' -Raw | Invoke-Expression; 'SHELL-CON-SONG'"

  It 'pwsh iex giu stdin cho install va ke thua CREWLINE_DEFAULTS' {
    $h = New-CrewTestHome
    $r = Invoke-InTestHome $h $runner -Env @{ CREWLINE_DIR = (Join-Path $h.Home 'Crewline'); CREWLINE_REPO = $src } -InputText 'answer'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'SHELL-CON-SONG'
    $captured = Get-Content (Join-Path $h.Home 'bootstrap-input.json') -Raw | ConvertFrom-Json
    $captured.input | Should Be 'answer'
    $captured.defaults | Should Be '1'
  }
  It 'PS 5.1 iex giu stdin va truyen DEFAULTS rong xuong pwsh install' -Skip:(-not $OnWindows) {
    $h = New-CrewTestHome
    $path = ($env:Path -split ';' | Where-Object { $_ -and ($PSHOME -notmatch '\\WindowsApps\\' -or $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\')) }) -join ';'
    $r = Invoke-InTestHome $h $runner -Shell powershell -Env @{ CREWLINE_DIR = (Join-Path $h.Home 'Crewline'); CREWLINE_REPO = $src; CREWLINE_DEFAULTS = ''; Path = $path } -InputText 'answer51'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'SHELL-CON-SONG'
    $captured = Get-Content (Join-Path $h.Home 'bootstrap-input.json') -Raw | ConvertFrom-Json
    $captured.input | Should Be 'answer51'
    [string]$captured.defaults | Should Be ''
  }
}

Describe 'bootstrap.sh POSIX entrypoint' {
  $sh = if (Get-Command sh -ErrorAction SilentlyContinue) { (Get-Command sh).Source } else { 'C:/Program Files/Git/bin/sh.exe' }
  It 'parses as POSIX sh and is ASCII' {
    & $sh -n (Join-Path $RepoRoot 'bootstrap.sh')
    $LASTEXITCODE | Should Be 0
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot 'bootstrap.sh'))
    @($bytes | Where-Object { $_ -gt 127 -or $_ -eq 13 }).Count | Should Be 0
  }
  It 'selects the release asset using uname and rejects unsupported hosts' {
    $source = (Join-Path $RepoRoot 'bootstrap.sh').Replace('\', '/')
    foreach ($case in @(@('Linux', 'x86_64', 'linux-x64'), @('Linux', 'aarch64', 'linux-arm64'), @('Darwin', 'arm64', 'osx-arm64'), @('Darwin', 'x86_64', 'osx-x64'))) {
      $command = 'CREWLINE_BOOTSTRAP_LIBRARY=1; . "' + $source + '"; uname() { case "$1" in -s) echo ' + $case[0] + ';; -m) echo ' + $case[1] + ';; esac; }; crew_pwsh_asset'
      $out = & $sh -c $command
      $LASTEXITCODE | Should Be 0
      $out | Should Be $case[2]
    }
    $command = 'CREWLINE_BOOTSTRAP_LIBRARY=1; . "' + $source + '"; uname() { echo unsupported; }; crew_pwsh_asset 2>/dev/null'
    & $sh -c $command
    $LASTEXITCODE | Should Be 1
  }
}
