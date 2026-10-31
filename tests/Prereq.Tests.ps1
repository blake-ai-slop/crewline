. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
# Lệnh giả: .cmd rỗng trong thư mục đầu PATH; PATH chỉ còn System32 (không có npm/winget/agent thật).
# npm.cmd / winget.cmd giả ghi tham số vào file, không cài gì.

function New-PrereqFixture {
  $f = Join-Path $TestDrive "fx-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force (Join-Path $f 'scripts') | Out-Null
  Copy-Item (Join-Path $RepoRoot 'install.ps1') $f
  Copy-Item (Join-Path $RepoRoot 'templates') $f -Recurse
  foreach ($n in 'crew.ps1', 'setup.ps1', 'ui.ps1', 'prereq.ps1', 'teams.json') { Copy-Item (Join-Path $RepoRoot "scripts/$n") (Join-Path $f 'scripts') }
  $f
}

# Trả @{ Bin; Log; WLog; Path }. $Have: tên lệnh giả cần tạo (npm -> Log, winget -> WLog).
function New-FakeBin([string[]]$Have) {
  $bin = Join-Path $TestDrive "bin-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  New-Item -ItemType Directory -Force $bin | Out-Null
  $log = Join-Path $bin 'npm-args.txt'
  $wlog = Join-Path $bin 'winget-args.txt'
  foreach ($c in $Have) {
    $body = if ($c -eq 'npm') { "@echo %*>>`"$log`"`r`n@exit /b 0`r`n" }
    elseif ($c -eq 'winget') { "@echo %*>>`"$wlog`"`r`n@exit /b 0`r`n" }
    else { "@exit /b 0`r`n" }
    [IO.File]::WriteAllText((Join-Path $bin "$c.cmd"), $body)
  }
  @{ Bin = $bin; Log = $log; WLog = $wlog; Path = "$bin;$env:SystemRoot\System32" }
}

function New-UserConfig($h, [string]$team) {
  $file = Join-Path $h.Home 'user-config.json'
  Set-Content $file "{`"team`":`"$team`",`"review`":`"lean`",`"access`":`"work`"}"
  $file
}

function Invoke-Install($fx, $h, $fake, [hashtable]$Env = @{}, [string]$InputText = '') {
  $vars = @{ CREWLINE_DEFAULTS = ''; CREWLINE_NO_JQ = '1'; Path = $fake.Path }
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
    $r = Invoke-InTestHome $h (Join-Path $fx 'scripts/crew.ps1') -Arguments 'doctor' -WorkingDirectory $h.Home -Env @{ Path = $fake.Path; CREWLINE_USER_CONFIG = (New-UserConfig $h 'solo') }
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'THIẾU herdr-app \+ hc  -> tải: https://herdr.dev/'
    $r.Output | Should Match 'codex \(không dùng trong đội\)'
    $r.Output | Should Not Match 'thêm vào PATH'
  }

  It 'doi standard thieu codex co npm => goi y lenh npm' {
    $h = New-CrewTestHome; $fake = New-FakeBin $All
    $r = Invoke-InTestHome $h (Join-Path $fx 'scripts/crew.ps1') -Arguments 'doctor' -WorkingDirectory $h.Home -Env @{ Path = $fake.Path }
    $r.Output | Should Match 'THIẾU codex  -> npm install -g @openai/codex'
    Test-Path $fake.Log | Should Be $false
  }

  [Console]::OutputEncoding = $savedEnc
}
