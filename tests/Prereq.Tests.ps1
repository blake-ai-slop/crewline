. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
# Tên biến PATH: Windows không phân biệt hoa thường (Path), Unix chỉ có PATH.
$PathKey = if ($OnWindows) { 'Path' } else { 'PATH' }
# Lệnh giả: .cmd rỗng (Unix: script sh) trong thư mục đầu PATH; PATH chỉ còn System32 (không có npm/winget/agent thật).
# npm.cmd / winget.cmd giả ghi tham số vào file, không cài gì.

function New-PrereqFixture {
  $f = Join-Path $TestDrive "fx-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force (Join-Path $f 'scripts') | Out-Null
  Copy-Item (Join-Path $RepoRoot 'install.ps1') $f
  Copy-Item (Join-Path $RepoRoot 'templates') $f -Recurse
  foreach ($n in 'platform.ps1', 'crew.ps1', 'setup.ps1', 'ui.ps1', 'prereq.ps1', 'teams.json') { Copy-Item (Join-Path $RepoRoot "scripts/$n") (Join-Path $f 'scripts') }
  # Các test winget/herdr.dev kiểm logic nhánh Windows: trên Linux/macOS giả Get-CrewOS = windows (test Unix bên dưới ghi đè lại).
  if (-not $OnWindows) { Add-Content (Join-Path $f 'scripts/platform.ps1') "`nfunction Get-CrewOS { 'windows' }" }
  $f
}

# Lệnh giả ghi tham số vào $Log (nếu có): .cmd trên Windows, script sh thực thi trên Linux/macOS.
function New-FakeCmd([string]$Bin, [string]$Name, [string]$Log) {
  if ($OnWindows) {
    $body = if ($Log) { "@echo %*>>`"$Log`"`r`n@exit /b 0`r`n" } else { "@exit /b 0`r`n" }
    [IO.File]::WriteAllText((Join-Path $Bin "$Name.cmd"), $body)
    return
  }
  $file = Join-Path $Bin $Name
  $body = if ($Log) { "#!/bin/sh`necho `"`$*`" >> '$Log'`nexit 0`n" } else { "#!/bin/sh`nexit 0`n" }
  [IO.File]::WriteAllText($file, $body)
  & chmod +x $file
}

# Trả @{ Bin; Log; WLog; Path }. $Have: tên lệnh giả cần tạo (npm -> Log, winget -> WLog).
# Path chỉ còn thư mục giả (+ System32 trên Windows): không có npm/winget/agent thật.
function New-FakeBin([string[]]$Have) {
  $bin = Join-Path $TestDrive "bin-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force $bin | Out-Null
  $log = Join-Path $bin 'npm-args.txt'
  $wlog = Join-Path $bin 'winget-args.txt'
  foreach ($c in $Have) {
    $l = if ($c -eq 'npm') { $log } elseif ($c -eq 'winget') { $wlog } else { '' }
    New-FakeCmd $bin $c $l
  }
  $path = if ($OnWindows) { "$bin;$env:SystemRoot\System32" } else { $bin }
  @{ Bin = $bin; Log = $log; WLog = $wlog; Path = $path }
}

function New-UserConfig($h, [string]$team) {
  $file = Join-Path $h.Home 'user-config.json'
  Set-Content $file "{`"team`":`"$team`",`"review`":`"lean`",`"access`":`"work`"}"
  $file
}

function Invoke-Install($fx, $h, $fake, [hashtable]$Env = @{}, [string]$InputText = '') {
  $vars = @{ CREWLINE_DEFAULTS = ''; CREWLINE_NO_JQ = '1'; $PathKey = $fake.Path }
  foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
  Invoke-InTestHome $h (Join-Path $fx 'install.ps1') -Arguments '-NoDoctor' -Env $vars -InputText $InputText
}

$All = @('git', 'pwsh', 'herdr-app', 'hc', 'claude', 'npm')

Describe 'scripts/prereq.ps1' {
  It 'dot-source khong chay gi, chi dinh nghia ham' {
    $out = & { . (Join-Path $RepoRoot 'scripts/prereq.ps1') }
    $out | Should BeNullOrEmpty
  }
  . (Join-Path $RepoRoot 'scripts/prereq.ps1')
  It 'bang co du muc va link' {
    $p = Get-Prereqs
    ($p | Where-Object Name -eq 'herdr').Url | Should Be 'https://herdr.dev/'
    ($p | Where-Object Name -eq 'herdr').Group | Should Be 'required'
    ($p | Where-Object Name -eq 'codex').Npm | Should Be '@openai/codex'
    ($p | Where-Object Name -eq 'git').Winget | Should Be 'Git.Git'
  }
  It 'Get-PrereqTeam: khong co config => standard; solo chi claude' {
    $teams = Join-Path $RepoRoot 'scripts/teams.json'
    (Get-TeamAgents (Get-PrereqTeam @('khong-co.json') $teams)) -join ',' | Should Be 'claude,codex'
    $solo = Join-Path $TestDrive 'solo.json'; Set-Content $solo '{"team":"solo"}'
    (Get-TeamAgents (Get-PrereqTeam @($solo) $teams)) -join ',' | Should Be 'claude'
    $proj = Join-Path $TestDrive 'proj.json'; Set-Content $proj '{"planner":"codex","workers":["codex"],"rev":"none"}'
    (Get-TeamAgents (Get-PrereqTeam @($proj, $solo) $teams)) -join ',' | Should Be 'codex'
  }
}

Describe 'install.ps1 kiem phan mem' {
  $savedEnc = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $fx = New-PrereqFixture

  It 'thieu codex + co npm + stdin 2 => goi npm install -g @openai/codex' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } '2'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Kiểm phần mềm'
    $r.Output | Should Match 'Cài codex bằng: npm install -g @openai/codex'
    $r.Output | Should Match '1\. Bỏ qua, tôi tự cài'
    $r.Output | Should Match '2\. Cài giúp'
    $r.Output | Should Match 'Lựa chọn \[1\]'
    (Get-Content $fake.Log -Raw).Trim() | Should Be 'install -g @openai/codex'
  }

  It 'stdin 1 (Bo qua) => khong goi npm' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } '1'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Cài codex bằng'
    Test-Path $fake.Log | Should Be $false
  }

  # Regression (Rev P1): Enter trong / EOF khong bao gio cai. Thieu git (co winget) + thieu codex (co npm) => 2 cau hoi.
  $Both = @('pwsh', 'herdr-app', 'hc', 'claude', 'npm', 'winget')
  It 'config co san + stdin rong => khong goi npm va winget' {
    $h = New-CrewTestHome; $fake = New-FakeBin $Both
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } ''
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Cài git bằng: winget install Git.Git'
    Test-Path $fake.Log | Should Be $false
    Test-Path $fake.WLog | Should Be $false
  }
  It 'config co san + 2 dong trong => khong goi npm va winget' {
    $h = New-CrewTestHome; $fake = New-FakeBin $Both
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } "`n"
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Cài codex bằng'
    Test-Path $fake.Log | Should Be $false
    Test-Path $fake.WLog | Should Be $false
  }
  It 'DEFAULTS=1 hoac NO_INSTALL=1 + stdin 2 => khong goi npm va winget' {
    foreach ($e in @(@{ CREWLINE_DEFAULTS = '1' }, @{ CREWLINE_NO_INSTALL = '1' })) {
      $h = New-CrewTestHome; $fake = New-FakeBin $Both
      $e.CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard')
      $r = Invoke-Install $fx $h $fake $e "2`n2"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'Cài git bằng'
      Test-Path $fake.Log | Should Be $false
      Test-Path $fake.WLog | Should Be $false
    }
  }
  It 'stdin 2, 2 => goi winget va npm dung tham so' {
    $h = New-CrewTestHome; $fake = New-FakeBin $Both
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } "2`n2"
    $r.ExitCode | Should Be 0
    (Get-Content $fake.WLog -Raw).Trim() | Should Be 'install Git.Git'
    (Get-Content $fake.Log -Raw).Trim() | Should Be 'install -g @openai/codex'
  }
  It 'go ten "cai giup" cung cai' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } 'Cài giúp'
    (Get-Content $fake.Log -Raw).Trim() | Should Be 'install -g @openai/codex'
  }

  It 'CREWLINE_DEFAULTS=1 => khong hoi, khong goi npm, van in bang' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_DEFAULTS = '1' } '2'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Theo đội của bạn \(planner claude · worker claude, codex · Rev codex\)'
    $r.Output | Should Match 'codex +chưa cài → npm install -g @openai/codex'
    $r.Output | Should Not Match 'Cài codex bằng'
    Test-Path $fake.Log | Should Be $false
  }

  It 'stdin het sau setup => khong goi npm' {
    # Chua co config: setup dung dong trong duy nhat, cau hoi cai gap EOF.
    $h = New-CrewTestHome; $fake = New-FakeBin @('git', 'pwsh', 'herdr-app', 'hc', 'npm')
    $r = Invoke-Install $fx $h $fake @{} ''
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Kiểm phần mềm'
    Test-Path $fake.Log | Should Be $false
  }

  It 'CREWLINE_NO_INSTALL=1 => khong hoi, van in bang' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard'); CREWLINE_NO_INSTALL = '1' } '2'
    $r.Output | Should Match 'CREWLINE_NO_INSTALL=1'
    $r.Output | Should Not Match 'Cài codex bằng'
    Test-Path $fake.Log | Should Be $false
  }

  It 'khong co npm => in link nodejs, khong hoi' {
    $h = New-CrewTestHome; $fake = New-FakeBin @('git', 'pwsh', 'herdr-app', 'hc', 'claude')
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'standard') } '2'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'tải: https://github.com/openai/codex \(cần Node.js: https://nodejs.org\)'
    $r.Output | Should Not Match 'Cài codex bằng'
  }

  It 'doi solo (chi claude) => codex khong bi coi la thieu' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo') } '2'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Theo đội của bạn \(worker claude\)'
    $r.Output | Should Not Match 'codex'
    Test-Path $fake.Log | Should Be $false
  }

  It 'thieu herdr => khoi CHUA dung duoc + https://herdr.dev/, exit 0' {
    $h = New-CrewTestHome; $fake = New-FakeBin @('git', 'pwsh', 'claude', 'npm')
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo') } ''
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'herdr-app \+ hc +chưa cài → tải: https://herdr.dev/'
    $r.Output | Should Match 'Crew đã cài nhưng CHƯA dùng được: thiếu herdr-app \+ hc → https://herdr.dev/'
    $r.Output | Should Not Match 'Cài herdr'
  }

  It 'nhac dang nhap agent theo doi' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_DEFAULTS = '1' }
    $r.Output | Should Match 'codex login'
    $r.Output | Should Match 'chạy `claude` một lần'
  }

  [Console]::OutputEncoding = $savedEnc
}

Describe 'crew doctor dung bang prereq' {
  $savedEnc = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $fx = New-PrereqFixture

  It 'thieu herdr => link tu prereq.ps1; doi solo => codex khong dung' {
    $h = New-CrewTestHome; $fake = New-FakeBin @('git', 'pwsh', 'claude')
    $r = Invoke-InTestHome $h (Join-Path $fx 'scripts/crew.ps1') -Arguments 'doctor' -WorkingDirectory $h.Home -Env @{ $PathKey = $fake.Path; CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo') }
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'THIẾU herdr-app \+ hc  -> tải: https://herdr.dev/'
    $r.Output | Should Match 'codex \(không dùng trong đội\)'
    $r.Output | Should Not Match 'thêm vào PATH'
  }

  It 'doi standard thieu codex co npm => goi y lenh npm' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-InTestHome $h (Join-Path $fx 'scripts/crew.ps1') -Arguments 'doctor' -WorkingDirectory $h.Home -Env @{ $PathKey = $fake.Path }
    $r.Output | Should Match 'THIẾU codex  -> npm install -g @openai/codex'
    Test-Path $fake.Log | Should Be $false
  }

  [Console]::OutputEncoding = $savedEnc
}


Describe 'prereq platform installation commands' {
  . (Join-Path $RepoRoot 'scripts/prereq.ps1')
  It 'Linux suggests apt/dnf, never returns a sudo install action' {
    Mock Get-CrewOS { 'linux' }
    Mock Get-Command { $null }
    foreach ($name in 'git', 'pwsh', 'jq') {
      $p = Get-Prereqs | Where-Object Name -eq $name
      Get-PrereqInstall $p | Should BeNullOrEmpty
      Get-PrereqFix $p | Should Match 'sudo apt install .+ / sudo dnf install'
    }
    $herdr = Get-Prereqs | Where-Object Name -eq 'herdr'
    $i = Get-PrereqInstall $herdr
    $i.Exe | Should Be 'sh'
    $i.Args[0] | Should Be '-c'
    $i.Args[1] | Should Be 'curl -fsSL https://releases.herdr.dev/app/install.sh | sh'
  }
  It 'macOS uses brew when present and npm for agents' {
    Mock Get-CrewOS { 'macos' }
    Mock Get-Command { [pscustomobject]@{ Source = 'fake-command' } }
    $git = Get-Prereqs | Where-Object Name -eq 'git'
    (Get-PrereqInstall $git).Text | Should Be 'brew install git'
    $pwsh = Get-Prereqs | Where-Object Name -eq 'pwsh'
    (Get-PrereqInstall $pwsh).Text | Should Be 'brew install powershell'
    $agent = Get-Prereqs | Where-Object Name -eq 'codex'
    (Get-PrereqInstall $agent).Text | Should Be 'npm install -g @openai/codex'
  }
  It 'macOS without brew has no automatic package-manager action' {
    Mock Get-CrewOS { 'macos' }
    Mock Get-Command { $null }
    $git = Get-Prereqs | Where-Object Name -eq 'git'
    Get-PrereqInstall $git | Should BeNullOrEmpty
  }
  It 'matches command names without an exe suffix' {
    Mock Get-Command { [pscustomobject]@{ Source = '/usr/local/bin/hc' } }
    $p = Get-Prereqs | Where-Object Name -eq 'herdr'
    Test-Prereq $p | Should Be $true
    Assert-MockCalled Get-Command -ParameterFilter { $Name -eq 'hc' } -Times 1
  }
}

Describe 'Unix install flow simulated in a fake HOME' {
  $fx = New-PrereqFixture
  Add-Content (Join-Path $fx 'scripts/platform.ps1') "`nfunction Get-CrewOS { 'linux' }`nfunction chmod { `$global:LASTEXITCODE = 0 }"
  It 'macOS reports missing jq without offering to install the optional package' {
    $mac = New-PrereqFixture
    Add-Content (Join-Path $mac 'scripts/platform.ps1') "`nfunction Get-CrewOS { 'macos' }`nfunction chmod { `$global:LASTEXITCODE = 0 }"
    $h = New-CrewTestHome
    $fake = New-FakeBin @('git', 'pwsh', 'herdr-app', 'hc', 'claude', 'brew')
    $r = Invoke-Install $mac $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo'); XDG_CONFIG_HOME = (Join-Path $h.Home '.config') } '2'
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'jq .+brew install jq'
    $r.Output | Should Not Match 'Cài jq'
  }
  It 'creates a pwsh shim, uses XDG templates, and never downloads jq.exe' {
    $h = New-CrewTestHome
    $fake = New-FakeBin @('git', 'pwsh', 'claude', 'jq')
    $xdg = Join-Path $h.Home 'config-unix'
    $r = Invoke-Install $fx $h $fake @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo'); XDG_CONFIG_HOME = $xdg; CREWLINE_NO_JQ = ''; CREWLINE_DEFAULTS = '1' } '2'
    $r.ExitCode | Should Be 0
    $shim = Get-Content (Join-Path $h.Home '.local/bin/crew') -Raw
    $shim | Should Match '^#!/usr/bin/env pwsh'
    $shim | Should Match '@args'
    Test-Path (Join-Path $h.Home '.local/bin/crew.ps1') | Should Be $false
    Test-Path (Join-Path $h.Home '.local/bin/jq.exe') | Should Be $false
    Test-Path (Join-Path $xdg 'herdr-core/templates/crew-planner.md') | Should Be $true
    $r.Output | Should Match 'curl -fsSL https://releases.herdr.dev/app/install.sh'
    $r.Output | Should Not Match 'Cài herdr'
  }
  It 'herdr shell installer only runs after explicit selection' {
    foreach ($scenario in @(@{ Input = ''; Env = @{}; Run = $false }, @{ Input = "`n"; Env = @{}; Run = $false }, @{ Input = '2'; Env = @{ CREWLINE_NO_INSTALL = '1' }; Run = $false }, @{ Input = '2'; Env = @{ CREWLINE_DEFAULTS = '1' }; Run = $false }, @{ Input = '2'; Env = @{}; Run = $true })) {
      $h = New-CrewTestHome
      $fake = New-FakeBin @('git', 'pwsh', 'claude', 'jq')
      $log = Join-Path $fake.Bin 'sh-log.txt'
      New-FakeCmd $fake.Bin 'sh' $log
      $vars = @{ CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo'); XDG_CONFIG_HOME = (Join-Path $h.Home '.config') }
      foreach ($k in $scenario.Env.Keys) { $vars[$k] = $scenario.Env[$k] }
      $r = Invoke-Install $fx $h $fake $vars $scenario.Input
      $r.ExitCode | Should Be 0
      (Test-Path $log) | Should Be $scenario.Run
      if ($scenario.Run) { Get-Content $log -Raw | Should Match 'curl -fsSL https://releases.herdr.dev/app/install.sh \| sh' }
    }
  }
}
