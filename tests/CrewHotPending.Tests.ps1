. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($shared in 'Get-CrewStateSchema', 'Read-CrewState', 'Get-CrewVersion', 'Show-CrewUpgradeWarning', 'Get-SkeletonVersion') { . ([scriptblock]::Create((Get-CrewFunction $shared).Extent.Text)) }
# Hàm thật qua AST, hc giả; fixture là đoạn cuối hc read --json thực tế
# 2026-11-01: crewline-planner/w1/rev (chỉ đọc), hp-test-claude/codex (đã kill).

$pendingFunctions = 'Get-WorkerMode','Get-SendPlan','Get-PendingInput','Get-TermStatus','Get-InputBox','Get-StuckText','Get-ScreenDialog','Invoke-Hot', 'Get-TaskGitFacts', 'Test-TaskFinished','Get-HotWarnings'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $pendingFunctions } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$ClaudeSuggestion = @'
─────────────────────────────────────────────────────────────────────────────────
❯ Phải chờ planner phản hồi.
─────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
'@
$ClaudeEmpty = @'
─────────────────────────────────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────────────────────────────────
  ctx 6% · 5h 8% · week 28%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
'@
$ClaudeQueued = @'
> <hc from="t2p crewline-w2">HP_TEST queued second message, reply acknowledged.</hc>
  ctrl+enter to send now

✻ Actualizing…

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
> Press up to edit queued messages
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ctx 4% · 5h 9% · week 28%
  ⏵⏵ bypass permissions on · 1 shell
'@
$CodexEmpty = @'
› Ask Codex to do anything

  GPT-6.1-Sol medium · ~\Crewline · Đọc vai trò rev và chờ giao việc · Context 85% left
  ? for shortcuts
'@
$CodexQueued = @'
• Queued follow-up inputs
  ↳ HP_TEST queued, reply acknowledged after current list.
    shift+← edit last queued message


› Ask Codex to do anything

  GPT-6.1-Sol medium · ~\Crewline\.crew\worktrees\w2 · List 250 distinct words · Context 100% left · 5h 91% left · weekly 26% left
  ? for shortcuts                                                                                                                                                              ⚠ 1 warning · f2 to view
'@
Describe 'Get-PendingInput bảo thủ với gợi ý và marker hàng đợi thật' {
  It 'Claude rảnh: gợi ý, chữ chưa chắc là tin thật và ô trống đều bỏ qua' {
    foreach ($state in 'idle','done','working') {
      Get-PendingInput claude-code $state $ClaudeSuggestion | Should Be ''
      Get-PendingInput claude $state $ClaudeEmpty | Should Be ''
      Get-PendingInput claude $state ($ClaudeSuggestion.Replace('Phải chờ planner phản hồi.', 'ok xong báo tôi')) | Should Be ''
    }
  }
  It 'Codex placeholder và chữ ô nhập không đủ chứng minh' {
    foreach ($state in 'idle','done','working') {
      Get-PendingInput codex $state $CodexEmpty | Should Be ''
      Get-PendingInput codex $state ($CodexEmpty.Replace('Ask Codex to do anything','')) | Should Be ''
    }
    # ô nhập thật còn chữ: rảnh là tin kẹt, working thì chưa (CrewSendStuck kiểm kỹ)
    Get-PendingInput codex working ($CodexEmpty.Replace('Ask Codex to do anything','HP_TEST queued, reply acknowledged after current list.')) | Should Be ''
    Get-PendingInput codex idle ($CodexEmpty.Replace('Ask Codex to do anything','HP_TEST queued, reply acknowledged after current list.')) | Should Be 'stuck'
  }
  It 'chỉ agent working có marker UI thật mới queued' {
    Get-PendingInput claude working $ClaudeQueued | Should Be 'queued'
    Get-PendingInput claude-code working $ClaudeQueued | Should Be 'queued'
    Get-PendingInput codex working $CodexQueued | Should Be 'queued'
    foreach ($state in 'idle','done','blocked','') {
      Get-PendingInput claude $state $ClaudeQueued | Should Be ''
      Get-PendingInput codex $state $CodexQueued | Should Be ''
    }
    Get-PendingInput shell working $ClaudeQueued | Should Be ''
    Get-PendingInput codex working 'Queued follow-up inputs' | Should Be ''
    Get-PendingInput claude working 'Press up to edit queued messages' | Should Be ''
    Get-PendingInput claude working "$ClaudeQueued`n$ClaudeEmpty" | Should Be ''
    Get-PendingInput codex working "$CodexQueued`n$CodexEmpty" | Should Be ''
  }
}

Describe 'crew hot pending chỉ đọc, một lần mỗi pane' {
  BeforeEach {
    $script:Path = $TestDrive
    $script:PendingReads = @{}; $script:PendingSend = 0; $script:PendingKeys = 0
    function Get-Root($p) { $p }
    function Get-Config($p) { @{ workers=@(); planner='none'; rev='none'; review='lean'; access='full' } }
    function Get-CrewName { 'demo' }
    function Get-ForeignTermError($n) { if ($n -eq 'demo-w5') { 'khác project' } }
    function Get-Tasks { ,@() }
    function Get-CopySource { '' }
    function Get-NameConflict { '' }
    function Invoke-GitQuiet { @{Code=0; Text=$(if ($args -contains 'rev-parse') { '.git/MERGE_HEAD' } else { '' })} }
    function git { }
    function hc { throw 'hc thật bị cấm' }
    function Get-LiveTerminals {
      @(
        @{name='demo-w1'; state='live'; status='working'; agent='claude-code'},
        @{name='demo-w2'; state='live'; status=@{app='codex'; state='working'}; agent='codex'},
        @{name='demo-w3'; state='live'; status='done'; agent='claude'},
        @{name='demo-w4'; state='live'; status='idle'; agent='codex'},
        @{name='demo-w5'; state='live'; status='working'; agent='codex'},
        @{name='demo-shell'; state='live'; status='idle'; agent=''},
        @{name='demo-dead'; state='finished'; status='idle'; agent='codex'},
        @{name='other-w1'; state='live'; status='working'; agent='codex'}
      ) | ForEach-Object { [pscustomobject]$_ }
    }
    $script:PendingScreens = @{'demo-w1'=$ClaudeQueued; 'demo-w2'=$CodexQueued; 'demo-w3'=$ClaudeSuggestion; 'demo-w4'=$CodexEmpty}
    function New-HcOps {
      @{
        Read = { param($t) $script:PendingReads[$t]++; $script:PendingScreens[$t] }
        Send = { $script:PendingSend++; throw 'cấm gửi' }
        Keys = { $script:PendingKeys++; throw 'cấm phím' }
      }
    }
  }
  It 'fixture nền Codex v0.166/Claude v2.1 thay done và idle, chỉ đọc một lần' {
    foreach ($fixture in 'codex-v0.166/background-running.txt', 'codex-v0.166/background-waiting.txt', 'claude-v2.1/background-running.txt') {
      $app = if ($fixture -like 'codex*') { 'codex' } else { 'claude-code' }
      $script:BackgroundApp = $app
      function Get-LiveTerminals { [pscustomobject]@{name='demo-w1'; state='live'; status=@{app=$script:BackgroundApp; state=$script:BackgroundState}; agent=$script:BackgroundApp} }
      $screen = Get-Content (Join-Path $PSScriptRoot "fixtures/$fixture") -Raw -Encoding UTF8
      foreach ($state in 'done', 'idle', 'working') {
        $script:BackgroundState = $state
        $script:PendingReads = @{}
        $script:PendingScreens['demo-w1'] = $screen
        $out = Invoke-Hot 6>&1 | Out-String
        $out | Should Match 'demo-w1\s+working \(nền\)'
        $out | Should Not Match 'tin kẹt'
        $script:PendingReads['demo-w1'] | Should Be 1
      }
    }
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
  It 'Claude footer 1 shell vẫn là nền, số 0 và blocked không đổi trạng thái' {
    function Get-LiveTerminals { [pscustomobject]@{name='demo-w1'; state='live'; status='done'; agent='claude-code'} }
    $script:PendingScreens['demo-w1'] = $ClaudeQueued.Replace('Press up to edit queued messages', '')
    (Invoke-Hot 6>&1 | Out-String) | Should Match 'working \(nền\)'
    $script:PendingScreens['demo-w1'] = $script:PendingScreens['demo-w1'].Replace('1 shell', '0 shells')
    (Invoke-Hot 6>&1 | Out-String) | Should Not Match 'working \(nền\)'
    $script:PendingScreens['demo-w1'] = '• Working · 1 background terminal running · /ps to view'
    function Get-LiveTerminals { [pscustomobject]@{name='demo-w1'; state='live'; status='blocked'; agent='codex'} }
    (Invoke-Hot 6>&1 | Out-String) | Should Not Match 'working \(nền\)'
  }
  It 'không marker UI còn chạy thì giữ done/idle, không lấy lời kể hoặc số 0' {
    function Get-LiveTerminals { [pscustomobject]@{name='demo-w1'; state='live'; status='done'; agent='codex'} }
    foreach ($screen in $CodexEmpty, "• Ran tests: 1 background terminal running`n$CodexEmpty", "• Working · 0 background terminals running · /ps to view`n$CodexEmpty") {
      $script:PendingScreens['demo-w1'] = $screen
      $out = Invoke-Hot 6>&1 | Out-String
      $out | Should Match 'demo-w1\s+done'
      $out | Should Not Match 'working \(nền\)'
    }
  }
  It 'nhãn xong của task mới cần doneAt và sạch; task cũ vẫn đoán theo commit và note' {
    $script:HotTask = [pscustomobject]@{ name='a'; worker=1; agent='claude'; branch='crew/a'; worktree=$TestDrive; doneTracking=$true }
    $script:HotClean = $true
    function Get-Tasks { ,@($script:HotTask) }
    function Get-TaskGitFacts { @{ Ahead=1; HasNote=$true; Clean=$script:HotClean } }
    (Invoke-Hot 6>&1 | Out-String) | Should Not Match 'đã xong, chờ planner'
    $script:HotTask | Add-Member NoteProperty doneAt '2026-11-18T00:00:00Z'
    (Invoke-Hot 6>&1 | Out-String) | Should Match 'đã xong, chờ planner'
    $script:HotClean = $false
    (Invoke-Hot 6>&1 | Out-String) | Should Not Match 'đã xong, chờ planner'
    $script:HotClean = $true
    $script:HotTask.PSObject.Properties.Remove('doneAt')
    $script:HotTask.PSObject.Properties.Remove('doneTracking')
    (Invoke-Hot 6>&1 | Out-String) | Should Match 'đã xong, chờ planner'
  }
  It 'pane sai config cảnh báo đúng vai, vẫn đọc một lần và không gửi phím' {
    function Get-Config { @{ workers=@('codex','claude','claude','codex'); planner='none'; rev='none'; review='lean'; access='wide' } }
    function Get-LiveTerminals {
      @(
        [pscustomobject]@{name='demo-w1'; state='live'; status=@{app='claude-code';state='working'}; agent='claude-code'},
        [pscustomobject]@{name='demo-w2'; state='live'; status=@{app='codex';state='working'}; agent='codex'}
      )
    }
    function Get-WorkerTree($r,$i) { Join-Path $r "w$i" }
    $out = Invoke-Hot 6>&1 | Out-String
    $out | Should Match 'demo-w1 đang chạy claude-code, config là codex — crew up -Restart w1'
    $out | Should Match 'demo-w2 đang chạy codex, config là claude — crew up -Restart w2'
    $script:PendingReads.Count | Should Be 2
    foreach ($n in $script:PendingReads.Keys) { $script:PendingReads[$n] | Should Be 1 }
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
  It 'hiện cột và cảnh báo hai hàng đợi, không báo gợi ý' {
    $out = Invoke-Hot 6>&1 | Out-String
    $out | Should Match 'demo-w1\s+working \(nền\)'
    $out | Should Match 'demo-w2\s+tin chờ'
    $out | Should Match 'demo-w1: có tin chờ, agent đọc khi xong lượt'
    $out | Should Match 'demo-w2: có tin chờ, agent đọc khi xong lượt'
    $out | Should Not Match 'demo-w[34]: có tin chờ|tin kẹt'
    $script:PendingReads.Count | Should Be 4
    foreach ($n in $script:PendingReads.Keys) { $script:PendingReads[$n] | Should Be 1 }
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
  It 'sạch không in tin chờ và không có cảnh báo' {
    $script:PendingScreens['demo-w1'] = $ClaudeEmpty
    $script:PendingScreens['demo-w2'] = $CodexEmpty
    $out = Invoke-Hot 6>&1 | Out-String
    $out | Should Not Match 'tin chờ|tin kẹt|== Cảnh báo'
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
  It 'reviewUnsure cảnh báo + hướng dẫn; chỉ xóa khi ô trống hoặc Rev working từ cùng lần đọc' {
    function Get-Config { @{workers=@();planner='none';rev='codex';review='lean';access='wide'} }
    function Get-LiveTerminals { [pscustomobject]@{name='demo-rev';state='live';status=@{app='codex';state=$script:RevState};agent='codex'} }
    function Get-Tasks { ,@($script:UnsureTask) }
    $script:HotUpdates = 0
    function Update-Tasks($root, $change) { $script:HotUpdates++; & $change @($script:UnsureTask) }
    foreach ($case in @(
      @{State='idle';Screen=$CodexEmpty.Replace('Ask Codex to do anything','review');Clear=$false},
      @{State='idle';Screen='không nhận ra ô';Clear=$false},
      @{State='blocked';Screen='Allow command (y/n)';Clear=$false},
      @{State='idle';Screen=$CodexEmpty;Clear=$true},
      @{State='working';Screen=$CodexEmpty.Replace('Ask Codex to do anything','review');Clear=$true}
    )) {
      $script:UnsureTask = [pscustomobject]@{name='a';worker=1;branch='crew/a';doneTracking=$true;reviewSentAt='2026-11-19T00:00:00Z';reviewUnsure=$true}
      $script:RevState = $case.State
      $script:PendingScreens['demo-rev'] = $case.Screen
      $script:PendingReads = @{}; $script:HotUpdates = 0
      $out = Invoke-Hot 6>&1 | Out-String
      if ($case.Clear) {
        $out | Should Not Match 'chưa chắc Rev'
        $script:UnsureTask.reviewUnsure | Should BeNullOrEmpty
        $script:HotUpdates | Should Be 1
      } else {
        $out | Should Match 'chưa chắc Rev đã nhận review a'
        $out | Should Match '→ Làm tiếp: hc read demo-rev --lines 20'
        $out | Should Match 'crew review a -Sent'
        $script:HotUpdates | Should Be 0
      }
      $script:UnsureTask.reviewSentAt | Should Be '2026-11-19T00:00:00Z'
      $script:PendingReads['demo-rev'] | Should Be 1
    }
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
  It 'cảnh báo stuck nhận từ map có chỉ dẫn xem và gửi lại' {
    $out = @(Get-HotWarnings $TestDrive @{} @() @() @{'demo-w1'='stuck'}) -join "`n"
    $out | Should Match 'demo-w1: tin kẹt ở ô nhập — sang pane demo-w1: Enter để gửi hoặc xóa chữ'
  }
  It 'plumbing stuck hiện đúng cột và cảnh báo khi bộ nhận diện trả stuck' {
    $script:PendingScreens['demo-w1'] = $ClaudeQueued.Replace(' · 1 shell', '')
    function Get-PendingInput($app, $state, $screen) { if ($app -eq 'claude-code') { 'stuck' } else { '' } }
    $out = Invoke-Hot 6>&1 | Out-String
    $out | Should Match 'demo-w1\s+tin kẹt'
    $out | Should Match 'demo-w1: tin kẹt ở ô nhập'
    $script:PendingSend | Should Be 0
    $script:PendingKeys | Should Be 0
  }
}
