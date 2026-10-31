. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent

function New-SetupFixture([string[]]$Agents = @('claude', 'codex')) {
  $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
  $scripts = Join-Path $root 'scripts'
  $bin = Join-Path $root 'bin'
  New-Item -ItemType Directory -Force $scripts, $bin | Out-Null
  Copy-Item (Join-Path $RepoRoot 'scripts/setup.ps1') $scripts
  Copy-Item (Join-Path $RepoRoot 'scripts/ui.ps1') $scripts
  Set-Content (Join-Path $scripts 'teams.json') '{"standard":{"planner":"claude","workers":["claude","codex"],"rev":"codex"},"solo":{"planner":"none","workers":["claude"],"rev":"none"},"large":{"planner":"claude","workers":["claude","codex","claude","codex"],"rev":"codex"}}'
  foreach ($a in $Agents) { Set-Content (Join-Path $bin "$a.cmd") '' }
  @{ File = Join-Path $scripts 'setup.ps1'; Env = @{ CREWLINE_DEFAULTS = ''; Path = "$bin;$env:SystemRoot\System32" } }
}
function Read-SetupConfig($h) { Get-Content (Join-Path $h.Home '.crewline/config.json') -Raw | ConvertFrom-Json }

Describe 'setup.ps1' {
  # Output của pwsh con là UTF-8; console OEM sẽ giải mã sai tiếng Việt khi so khớp.
  $savedEncoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  It 'Defaults voi ca hai agent dung standard va day du khoa' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Arguments '-Defaults' -Env $f.Env
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.team | Should Be 'standard'
    $c.planner | Should Be 'claude'
    ($c.workers -join ',') | Should Be 'claude,codex'
    $c.rev | Should Be 'codex'
    $c.review | Should Be 'lean'
    $c.access | Should Be 'work'
    @($c.PSObject.Properties).Count | Should Be 6
  }
  It 'chi claude thi custom moi vai claude va CREWLINE_DEFAULTS khong hoi' {
    $h = New-CrewTestHome; $f = New-SetupFixture @('claude'); $f.Env.CREWLINE_DEFAULTS = '1'
    $r = Invoke-InTestHome $h $f.File -Env $f.Env
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.team | Should Be 'custom'
    $c.planner | Should Be 'claude'
    ($c.workers -join ',') | Should Be 'claude,claude'
    $c.rev | Should Be 'claude'
  }
  It 'custom stdin tao ba worker va nhan review quyen' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "4`n2`n3`n1`n2`n2`n1`n3`n2`n"
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.team | Should Be 'custom'
    $c.planner | Should Be 'codex'
    ($c.workers -join ',') | Should Be 'claude,codex,codex'
    $c.rev | Should Be 'claude'
    $c.review | Should Be 'full'
    $c.access | Should Be 'wide'
    $r.Output | Should Match '\[1\] Mẫu đội'
    $r.Output | Should Match '1\. standard +planner claude · worker claude, codex · Rev codex'
    $r.Output | Should Match '2\. solo +1 worker claude · không planner, không Rev'
    $r.Output | Should Match '\[6\] Worker 3'
    $r.Output | Should Match '\[9\] Quyền agent'
    $r.Output | Should Match '3\. full — Đủ'
    $r.Output | Should Match 'Lựa chọn \[1\]: '
    $r.Output | Should Not Match '\[\d+/\d+\]'
    $r.Output | Should Match 'Đổi lại: crew setup'
  }
  It 'van nhan go ten thay cho so' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "custom`ncodex`n1`nclaude`nnone`nwide`n"
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.planner | Should Be 'codex'
    ($c.workers -join ',') | Should Be 'claude'
    $c.rev | Should Be 'none'
    $c.review | Should Be 'fast'
    $c.access | Should Be 'wide'
  }
  It 'nhap sai thi hoi lai dung cau do' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "sai`n4`nsai`n3`n0`n7`n1`n3`n2`n3`nsai`n2`n"
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.planner | Should Be 'none'
    ($c.workers -join ',') | Should Be 'codex'
    $c.rev | Should Be 'none'
    $c.review | Should Be 'fast'
    $c.access | Should Be 'wide'
    $r.Output | Should Match 'Không hợp lệ — nhập số từ 1 đến 6\.'
    $r.Output | Should Match '\[6\] Quyền agent'
    $r.Output | Should Not Match '\] Review'
  }
  It 'agent chua cai duoc danh dau trong danh sach vai' {
    $h = New-CrewTestHome; $f = New-SetupFixture @('codex')
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "`n`n`n`n`n`n2`n"
    $r.ExitCode | Should Be 0
    $r.Output | Should Match '1\. claude \(chưa cài\)'
    $r.Output | Should Match 'Planner\s+1\. claude \(chưa cài\)\s+2\. codex\s+3\. không dùng\s+Lựa chọn \[2\]'
    $c = Read-SetupConfig $h
    $c.team | Should Be 'custom'
    ($c.workers -join ',') | Should Be 'codex,codex'
  }
  It 'stdin rong chon mac dinh khong treo' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText ''
    $r.ExitCode | Should Be 0
    (Read-SetupConfig $h).team | Should Be 'standard'
  }
  It 'khong co agent thi canh bao standard va Enter van dung' {
    $h = New-CrewTestHome; $f = New-SetupFixture @()
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText ''
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'chưa có agent'
    $r.Output | Should Match 'claude ✗ chưa cài   codex ✗ chưa cài'
    (Read-SetupConfig $h).team | Should Be 'standard'
  }
  It 'tu choi doi thieu agent thi khong ghi config' {
    $h = New-CrewTestHome; $f = New-SetupFixture @('codex')
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "1`n2`n"
    $r.ExitCode | Should Be 0
    Test-Path (Join-Path $h.Home '.crewline/config.json') | Should Be $false
    $r.Output | Should Match 'claude ✗ chưa cài'
    $r.Output | Should Match 'Vẫn dùng đội này'
  }
  It 'solo ep fast va khong hoi review' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "2`n2`n"
    $r.ExitCode | Should Be 0
    $c = Read-SetupConfig $h
    $c.review | Should Be 'fast'
    $c.access | Should Be 'wide'
    @($c.workers).Count | Should Be 1
    $r.Output | Should Match '\[2\] Quyền agent'
  }
  It 'config da co + n hoac EOF hoac Defaults giu nguyen byte' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $file = Join-Path $h.Home '.crewline/config.json'
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    Set-Content $file '{"marker":"keep"}'
    $before = (Get-FileHash $file).Hash
    foreach ($inputText in @('1', 'n', '')) {
      $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText $inputText
      $r.ExitCode | Should Be 0
      (Get-FileHash $file).Hash | Should Be $before
    }
    $r = Invoke-InTestHome $h $f.File -Arguments '-Defaults' -Env $f.Env
    $r.ExitCode | Should Be 0
    (Get-FileHash $file).Hash | Should Be $before
  }
  It 'ghi de y va duong dan CREWLINE_USER_CONFIG khong cham project' {
    $h = New-CrewTestHome; $f = New-SetupFixture
    $file = Join-Path $h.Home 'other/personal.json'
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    Set-Content $file '{}'
    $project = Join-Path $h.Home '.crew/config.json'
    New-Item -ItemType Directory -Force (Split-Path $project) | Out-Null
    Set-Content $project 'keep'
    $f.Env.CREWLINE_USER_CONFIG = $file
    $r = Invoke-InTestHome $h $f.File -Env $f.Env -InputText "2`n3`n2`n2`n" -WorkingDirectory $h.Home
    $r.ExitCode | Should Be 0
    $c = Get-Content $file -Raw | ConvertFrom-Json
    $c.team | Should Be 'large'
    @($c.workers).Count | Should Be 4
    $c.review | Should Be 'fast'
    (Get-Content $project -Raw).Trim() | Should Be 'keep'
  }
  [Console]::OutputEncoding = $savedEncoding
}
