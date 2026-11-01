. "$PSScriptRoot/TestHome.ps1"
$repoRoot = Split-Path $PSScriptRoot -Parent
$crewScript = Join-Path $repoRoot 'scripts/crew.ps1'

Describe 'crew init đội tùy chỉnh' {
  BeforeEach {
    $h = New-CrewTestHome
    $userConfig = Join-Path $h.Home 'config.json'
    $testEnv = @{ CREWLINE_USER_CONFIG = $userConfig }
    $repo = Join-Path $h.Home 'project'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo config core.autocrlf false
    git -C $repo config user.name 'Crew Test'
    git -C $repo config user.email 'crew@example.invalid'
    git -C $repo commit -q --allow-empty -m initial
  }

  function Invoke-Init([string[]]$Extra = @(), [string]$Script = $crewScript) {
    Invoke-InTestHome -TestHome $h -File $Script -Env $testEnv -Arguments (@('init', '-Path', $repo, '-NoCommit') + $Extra)
  }
  function Read-Cfg { Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json }

  It 'custom 1 worker: ghi đúng vai, rev none ép review fast' {
    Set-Content $userConfig '{"team":"custom","planner":"codex","workers":["codex"],"rev":"none","review":"full","access":"wide"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'codex'
    @($cfg.workers).Count | Should Be 1
    $cfg.workers[0] | Should Be 'codex'
    $cfg.rev | Should Be 'none'
    $cfg.review | Should Be 'fast'
    $cfg.access | Should Be 'wide'
    (Get-Content "$repo/.crew/config.json" -Raw) | Should Match '"workers":\s*\['
  }

  It 'custom 6 worker, rev claude: giữ review từ config' {
    Set-Content $userConfig '{"team":"custom","planner":"none","workers":["claude","codex","claude","codex","claude","codex"],"rev":"claude","review":"full"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'none'
    ($cfg.workers -join ',') | Should Be 'claude,codex,claude,codex,claude,codex'
    $cfg.rev | Should Be 'claude'
    $cfg.review | Should Be 'full'
  }

  It 'đủ vai mà không có team vẫn dùng vai trong config' {
    Set-Content $userConfig '{"planner":"claude","workers":["claude","claude","claude"],"rev":"codex"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    @((Read-Cfg).workers).Count | Should Be 3
  }

  It 'từ chối config sai trước khi sửa project' {
    $cases = @(
      @{ json = '{"planner":"claude","workers":["claude","codex","claude","codex","claude","codex","claude"],"rev":"codex"}'; key = 'workers' }
      @{ json = '{"planner":"claude","workers":[],"rev":"codex"}'; key = 'workers' }
      @{ json = '{"planner":"claude","workers":"claude","rev":"codex"}'; key = 'workers' }
      @{ json = '{"planner":"claude","workers":["claude","none"],"rev":"codex"}'; key = 'workers' }
      @{ json = '{"planner":"gpt","workers":["claude"],"rev":"codex"}'; key = 'planner' }
      @{ json = '{"planner":"claude","workers":["claude"],"rev":"Claude"}'; key = 'rev' }
      @{ json = '{"team":"huge"}'; key = 'team' }
    )
    foreach ($c in $cases) {
      Set-Content $userConfig $c.json
      $r = Invoke-Init
      $r.ExitCode | Should Be 1
      $r.Output | Should Match "config cá nhân.*không hợp lệ.*'$($c.key)' phải là"
      Test-Path "$repo/context" | Should Be $false
    }
  }

  It 'team custom thiếu vai thì dừng' {
    Set-Content $userConfig '{"team":"custom","planner":"claude","rev":"codex"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 1
    $r.Output | Should Match "custom.*thiếu planner/workers/rev"
    Test-Path "$repo/context" | Should Be $false
  }

  It 'cờ -Team large thắng đội custom trong config' {
    Set-Content $userConfig '{"team":"custom","planner":"none","workers":["codex"],"rev":"none"}'
    $r = Invoke-Init @('-Team', 'large')
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'claude'
    ($cfg.workers -join ',') | Should Be 'claude,codex,claude,codex'
    $cfg.rev | Should Be 'codex'
    $cfg.review | Should Be 'lean'
  }

  It 'cờ -Team lạ thì báo lỗi' {
    $r = Invoke-Init @('-Team', 'custom')
    $r.ExitCode | Should Be 1
    $r.Output | Should Match '-Team phải là: standard, solo, large'
  }

  It 'chỉ có team solo: đội solo, review fast' {
    Set-Content $userConfig '{"team":"solo","review":"full"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'none'
    @($cfg.workers).Count | Should Be 1
    $cfg.rev | Should Be 'none'
    $cfg.review | Should Be 'fast'
  }

  It 'team mẫu + thiếu một vai thì theo mẫu' {
    Set-Content $userConfig '{"team":"large","planner":"none"}'
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'claude'
    @($cfg.workers).Count | Should Be 4
  }

  It 'không có config: standard' {
    $r = Invoke-Init
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'claude'
    ($cfg.workers -join ',') | Should Be 'claude,codex'
    $cfg.rev | Should Be 'codex'
    $cfg.review | Should Be 'lean'
  }

  It 'đọc mẫu đội từ scripts/teams.json' {
    $copy = Join-Path $h.Home 'crewline'
    New-Item -ItemType Directory "$copy/scripts" | Out-Null
    Copy-Item $crewScript "$copy/scripts/"
    Copy-Item (Join-Path $repoRoot 'scripts/platform.ps1') "$copy/scripts/"
    Copy-Item (Join-Path $repoRoot 'skeleton') $copy -Recurse
    Set-Content "$copy/scripts/teams.json" '{"standard":{"planner":"none","workers":["codex","codex","codex"],"rev":"claude"},"duo":{"planner":"claude","workers":["claude"],"rev":"none"}}'
    $r = Invoke-Init -Script "$copy/scripts/crew.ps1"
    $r.ExitCode | Should Be 0
    $cfg = Read-Cfg
    $cfg.planner | Should Be 'none'
    ($cfg.workers -join ',') | Should Be 'codex,codex,codex'
    $cfg.rev | Should Be 'claude'
    Remove-Item "$repo/.crew/config.json"
    Set-Content $userConfig '{"team":"duo"}'
    $r = Invoke-Init -Script "$copy/scripts/crew.ps1"
    $r.ExitCode | Should Be 0
    (Read-Cfg).review | Should Be 'fast'
  }

  It 'teams.json hỏng thì dừng' {
    $copy = Join-Path $h.Home 'crewline'
    New-Item -ItemType Directory "$copy/scripts" | Out-Null
    Copy-Item $crewScript "$copy/scripts/"
    Copy-Item (Join-Path $repoRoot 'scripts/platform.ps1') "$copy/scripts/"
    Set-Content "$copy/scripts/teams.json" '{"standard":{"planner":"claude","workers":["claude"],"rev":"bad"}}'
    $r = Invoke-Init -Script "$copy/scripts/crew.ps1"
    $r.ExitCode | Should Be 1
    $r.Output | Should Match "mẫu đội.*không hợp lệ.*'rev' phải là"
  }
}
