. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$Install = Join-Path $RepoRoot 'install.ps1'
$NoJq = @{ CREWLINE_NO_JQ = '1'; CREWLINE_NO_INSTALL = '1' }
# pwsh dat `$PSHOME dau PATH cho tien trinh con; pwsh ban Store goi thang tu thu muc goi (WindowsApps) bi Access denied khi ho so nguoi dung la gia.
# Bo `$PSHOME khoi PATH de PS 5.1 tim pwsh qua alias nhu may that.
$Ps51Path = (($env:Path -split ';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\') }) -join ';'

Describe 'install.ps1' {
  $h = New-CrewTestHome
  $bin = Join-Path $h.Home '.local/bin'
  $tdir = Join-Path $h.AppData 'herdr-core/templates'
  $r1 = Invoke-InTestHome -TestHome $h -File $Install -Arguments '-NoDoctor' -Env $NoJq

  It 'chay thanh cong' {
    $r1.ExitCode | Should Be 0
  }

  It 'tao shim crew.ps1 tro ve scripts/crew.ps1 cua repo' {
    $s = Get-Content (Join-Path $bin 'crew.ps1') -Raw
    $s | Should Match 'Crewline shim'
    $s.Contains((Join-Path $RepoRoot 'scripts/crew.ps1')) | Should Be $true
  }

  It 'shim crew.ps1 goi tu PS 5.1 chay duoc (chuyen sang pwsh, khong NativeCommandError)' {
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $bin 'crew.ps1') -Shell powershell -Arguments 'help' -Env @{ Path = $Ps51Path }
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'crew doctor'
    $r.Output | Should Not Match 'NativeCommandError'
  }

  It 'tao shim crew cho Git Bash voi dong LF' {
    $raw = [IO.File]::ReadAllText((Join-Path $bin 'crew'))
    $raw | Should Match '^#!/usr/bin/env bash'
    $raw.Contains("`r") | Should Be $false
  }

  It 'chep template vao APPDATA gia' {
    foreach ($t in Get-ChildItem (Join-Path $RepoRoot 'templates') -Filter '*.md') {
      $d = Join-Path $tdir $t.Name
      Test-Path $d | Should Be $true
      (Get-FileHash $d).Hash | Should Be (Get-FileHash $t.FullName).Hash
    }
  }

  It 'tao thu muc ~/.crewline rong' {
    $c = Join-Path $h.Home '.crewline'
    Test-Path $c -PathType Container | Should Be $true
    @(Get-ChildItem -Force $c).Count | Should Be 0
  }

  It 'khong chay crew doctor khi -NoDoctor, khong ghi PATH khi CREWLINE_NO_PATH=1' {
    $r1.Output | Should Match 'qua crew doctor'
    $r1.Output | Should Match 'CREWLINE_NO_PATH=1'
  }

  It 'chay lan 2 khong tao .bak-* moi' {
    $r2 = Invoke-InTestHome -TestHome $h -File $Install -Arguments '-NoDoctor' -Env $NoJq
    $r2.ExitCode | Should Be 0
    @(Get-ChildItem -Recurse -Force $h.Home -Filter '*.bak-*').Count | Should Be 0
  }
}

Describe 'install.ps1 voi template da co ban khac' {
  $h = New-CrewTestHome
  $tdir = Join-Path $h.AppData 'herdr-core/templates'
  New-Item -ItemType Directory -Force $tdir | Out-Null
  $name = (Get-ChildItem (Join-Path $RepoRoot 'templates') -Filter '*.md' | Select-Object -First 1).Name
  Set-Content (Join-Path $tdir $name) 'ban cu cua nguoi dung'
  $r = Invoke-InTestHome -TestHome $h -File $Install -Arguments '-NoDoctor' -Env $NoJq
  $bak = Join-Path $tdir "$name.bak-$(Get-Date -Format 'yyyyMMdd')"

  It 'sao luu ban cu thanh .bak-<ngay> roi ghi ban moi' {
    $r.ExitCode | Should Be 0
    Test-Path $bak | Should Be $true
    (Get-Content $bak -Raw).Trim() | Should Be 'ban cu cua nguoi dung'
    (Get-FileHash (Join-Path $tdir $name)).Hash | Should Be (Get-FileHash (Join-Path $RepoRoot "templates/$name")).Hash
  }
}

Describe 'install setup voi stdin gia' {
  # teams.json thuoc task team-config: dung fixture, khong tao trong repo that.
  $fixture = Join-Path $TestDrive 'install-fixture'
  New-Item -ItemType Directory -Force (Join-Path $fixture 'scripts') | Out-Null
  Copy-Item $Install $fixture
  Copy-Item (Join-Path $RepoRoot 'templates') $fixture -Recurse
  Copy-Item (Join-Path $RepoRoot 'scripts/setup.ps1') (Join-Path $fixture 'scripts')
  Copy-Item (Join-Path $RepoRoot 'scripts/crew.ps1') (Join-Path $fixture 'scripts')
  Copy-Item (Join-Path $RepoRoot 'scripts/ui.ps1') (Join-Path $fixture 'scripts')
  Copy-Item (Join-Path $RepoRoot 'scripts/prereq.ps1') (Join-Path $fixture 'scripts')
  Set-Content (Join-Path $fixture 'scripts/teams.json') '{"standard":{"planner":"claude","workers":["claude","codex"],"rev":"codex"},"solo":{"planner":"none","workers":["claude"],"rev":"none"},"large":{"planner":"claude","workers":["claude","codex","claude","codex"],"rev":"codex"}}'

  It 'khong DEFAULTS + stdin rong tao config mac dinh' {
    $h = New-CrewTestHome
    $r = Invoke-InTestHome $h (Join-Path $fixture 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_DEFAULTS = ''; CREWLINE_NO_JQ = '1'; CREWLINE_NO_INSTALL = '1'; Path = "$env:SystemRoot\System32" } -InputText ''
    $r.ExitCode | Should Be 0
    $c = Get-Content (Join-Path $h.Home '.crewline/config.json') -Raw | ConvertFrom-Json
    $c.team | Should Be 'standard'
    $c.review | Should Be 'lean'
  }
  It 'config da co giu nguyen va goi y crew setup' {
    $h = New-CrewTestHome
    $file = Join-Path $h.Home 'config.json'
    Set-Content $file '{"keep":true}'
    $before = (Get-FileHash $file).Hash
    $r = Invoke-InTestHome $h (Join-Path $fixture 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_DEFAULTS = ''; CREWLINE_NO_JQ = '1'; CREWLINE_NO_INSTALL = '1'; CREWLINE_USER_CONFIG = $file }
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'crew setup'
    (Get-FileHash $file).Hash | Should Be $before
  }
}

Describe 'shim PowerShell chuyen sang pwsh 7' {
  # crew.ps1 gia in phien ban PowerShell va tham so nhan duoc.
  $fixture = Join-Path $TestDrive 'shim-fixture'
  New-Item -ItemType Directory -Force (Join-Path $fixture 'scripts') | Out-Null
  Copy-Item $Install $fixture
  Copy-Item (Join-Path $RepoRoot 'templates') $fixture -Recurse
  Copy-Item (Join-Path $RepoRoot 'scripts/ui.ps1'), (Join-Path $RepoRoot 'scripts/prereq.ps1') (Join-Path $fixture 'scripts')
  Set-Content (Join-Path $fixture 'scripts/crew.ps1') 'Write-Output "MAJOR=$($PSVersionTable.PSVersion.Major) ARGS=$($args -join ''|'')"; exit 3'
  $h = New-CrewTestHome
  $r0 = Invoke-InTestHome -TestHome $h -File (Join-Path $fixture 'install.ps1') -Arguments '-NoDoctor' -Env $NoJq
  $shimFile = Join-Path $h.Home '.local/bin/crew.ps1'

  It 'install chay thanh cong, shim van la Crewline shim' {
    $r0.ExitCode | Should Be 0
    [IO.File]::ReadAllText($shimFile) | Should Match 'Crewline shim'
  }

  It 'goi tu PS 5.1 => chay bang pwsh 7, giu tham so va exit code' {
    $r = Invoke-InTestHome -TestHome $h -File $shimFile -Shell powershell -Arguments @('init', '-Path', 'a b') -Env @{ Path = $Ps51Path }
    $r.ExitCode | Should Be 3
    $r.Output | Should Match 'MAJOR=7 ARGS=init\|-Path\|a b'
  }

  It 'goi tu pwsh 7 => goi thang' {
    $r = Invoke-InTestHome -TestHome $h -File $shimFile -Arguments @('hot')
    $r.ExitCode | Should Be 3
    $r.Output | Should Match 'MAJOR=7 ARGS=hot'
  }

  It 'PS 5.1 khong co pwsh => bao cach cai pwsh' {
    $r = Invoke-InTestHome -TestHome $h -File $shimFile -Shell powershell -Arguments 'help' -Env @{ Path = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell1.0" }
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'PowerShell 7 \(pwsh\)'
    $r.Output | Should Match 'aka.ms/powershell'
  }

  It 'chay lai install ghi de shim, khong tao .bak' {
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $fixture 'install.ps1') -Arguments '-NoDoctor' -Env $NoJq
    $r.ExitCode | Should Be 0
    @(Get-ChildItem -Force (Split-Path $shimFile) -Filter '*.bak-*').Count | Should Be 0
  }
}
