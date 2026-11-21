. "$PSScriptRoot/TestHome.ps1"
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'

Describe 'crew init personal defaults' {
  BeforeEach {
    $h = New-CrewTestHome
    $fakeHome = $h.Home
    $userConfig = Join-Path $fakeHome 'config.json'
    $testEnv = @{ CREWLINE_USER_CONFIG = $userConfig }
    $repo = Join-Path $fakeHome 'project'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo config core.autocrlf false
    git -C $repo config user.name 'Crew Test'
    git -C $repo config user.email 'crew@example.invalid'
    git -C $repo commit -q --allow-empty -m initial
  }

  It 'uses existing defaults without creating personal config when file is absent' {
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $cfg = Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json
    $cfg.workers.Count | Should Be 2
    $cfg.review | Should Be 'lean'
    $cfg.access | Should Be 'work'
    Test-Path $userConfig | Should Be $false
  }

  It 'applies personal team review and access' {
    Set-Content $userConfig '{"team":"large","review":"full","access":"wide"}'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $cfg = Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json
    $cfg.workers.Count | Should Be 4
    $cfg.review | Should Be 'full'
    $cfg.access | Should Be 'wide'
    (Get-Content "$repo/context/HOT.md" -Raw -Encoding utf8) | Should Match 'Đủ.*Mở rộng'
  }

  It 'lets explicitly supplied default values override personal config' {
    Set-Content $userConfig '{"team":"large","review":"full","access":"wide"}'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo, '-Team', 'standard', '-Review', 'lean', '-Access', 'work')
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $cfg = Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json
    $cfg.workers.Count | Should Be 2
    $cfg.review | Should Be 'lean'
    $cfg.access | Should Be 'work'
  }

  It 'reads config from the fake HOME when override is absent and preserves solo review' {
    New-Item -ItemType Directory "$fakeHome/.crewline" | Out-Null
    Set-Content "$fakeHome/.crewline/config.json" '{"team":"solo","review":"full"}'
    $testEnv.CREWLINE_USER_CONFIG = $null
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 0
    $cfg = Get-Content "$repo/.crew/config.json" -Raw | ConvertFrom-Json
    $cfg.workers.Count | Should Be 1
    $cfg.review | Should Be 'fast'
    $cfg.access | Should Be 'work'
  }

  It 'rejects malformed JSON before modifying the project' {
    Set-Content $userConfig '{broken'
    $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $output = $result.Output
    $result.ExitCode | Should Be 1
    ($output -join "`n") | Should Match 'config cá nhân.*không hợp lệ'
    Test-Path "$repo/context" | Should Be $false
    @(git -C $repo status --porcelain).Count | Should Be 0
  }

  It 'rejects invalid values even when explicit flags are present' {
    foreach ($json in '{"team":"invalid"}', '{"review":null}', '{"access":42}', '[]', 'null') {
      Set-Content $userConfig $json
      $result = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo, '-Team', 'standard', '-Review', 'lean', '-Access', 'work')
      $output = $result.Output
      $result.ExitCode | Should Be 1
      ($output -join "`n") | Should Match 'config cá nhân.*không hợp lệ'
      Test-Path "$repo/context" | Should Be $false
    }
  }
}

. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($fn in 'Get-SuggestionMode', 'Test-SuggestionsOn') { . ([scriptblock]::Create((Get-CrewFunction $fn).Extent.Text)) }
Describe 'config suggestions của project (.crew/config.json)' {
  It 'thiếu ⇒ off (như cũ); planner chỉ bật pane planner; all bật mọi vai; giá trị sai ⇒ off' {
    Get-SuggestionMode $null | Should Be 'off'
    Get-SuggestionMode ' OFF ' | Should Be 'off'
    Get-SuggestionMode 'planner' | Should Be 'planner'
    Get-SuggestionMode 'ALL' | Should Be 'all'
    Get-SuggestionMode 'true' | Should Be 'off'
    foreach ($role in 'planner', 'rev', 'w1') { Test-SuggestionsOn 'off' $role | Should Be $false; Test-SuggestionsOn 'all' $role | Should Be $true }
    Test-SuggestionsOn 'planner' 'planner' | Should Be $true
    Test-SuggestionsOn 'planner' 'w3' | Should Be $false
  }
}

Describe 'config assist (v16 screen-assist)' {
  . (Join-Path $PSScriptRoot 'CrewAst.ps1')
  . ([scriptblock]::Create((Get-CrewFunction 'Get-AssistMode').Extent.Text))
  It 'off | ask | auto; thiếu hoặc sai ⇒ ask (mặc định)' {
    Get-AssistMode 'off' | Should Be 'off'
    Get-AssistMode 'Ask' | Should Be 'ask'
    Get-AssistMode 'auto' | Should Be 'auto'
    Get-AssistMode $null | Should Be 'ask'
    Get-AssistMode 42 | Should Be 'ask'
  }
  It 'crew init không ghi assist (thiếu = ask); crew hot cảnh báo giá trị sai' {
    $hot = (Get-CrewFunction 'Invoke-Hot').Extent.Text
    $hot.Contains('assist=''$($cfg.assist)'' không hợp lệ (off | ask | auto)') | Should Be $true
    $hot | Should Match 'planner hỗ trợ hôm nay'
  }
}
