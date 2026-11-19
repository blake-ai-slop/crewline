. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($shared in 'Get-CrewStateSchema', 'Read-CrewState', 'Write-CrewStateFile', 'Use-CrewStateLock', 'Get-CrewVersion', 'Show-CrewUpgradeWarning', 'Get-SkeletonVersion') { . ([scriptblock]::Create((Get-CrewFunction $shared).Extent.Text)) }
# Tin kẹt ở ô nhập + nhận nhầm hộp thoại: hàm thật qua AST, hc giả. Fixture Codex lấy từ màn hình thật 2026-11-02 (hc 0.1.16, codex-cli 0.166.0).

$want = 'Get-WorkerInputError', 'Get-InputBox', 'Get-StuckText', 'Get-PendingInput', 'Get-ScreenDialog', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Test-SentInput', 'Send-CodexQueue', 'Test-SessionReady', 'Send-CrewMessage', 'Get-HotWarnings', 'Invoke-Hot', 'Get-TaskGitFacts', 'Test-TaskFinished', 'Get-WorkerMode', 'Get-RevGuard', 'Invoke-Review', 'Update-Tasks'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { $script:Said += @($m) }
function Die($m) { throw "DIE: $m" }

$Msg = '<hc from="t32 crewline-planner">nội dung tin</hc>'
$Footer = '  GPT-6.1-Sol medium · ~\Crewline · Đọc vai trò và chờ giao việc · Context 62% left · 5h 44% left · weekly 14% left · 219K used'
$Stuck = @"
  Worked for 9m 36s • 11:31 AM
                                              ⚠ weekly limit: 14% left · resets at 2:27 PM on 4 Nov · /status

› $Msg

$Footer
"@
$Wrapped = @"
• ok
  Worked for 3s • 1:51 PM

› <hc from="t33 crewline-w1">PROBE_IDLE reply only ok. padding words for wrapping check here. padding words for
  check here. padding words for wrapping check here. padding words for wrapping check here. padding words for
  check here. padding words for wrapping check here. </hc>

  GPT-6.1-Sol low · ~\AppData\Local\Temp\codexprobe · Context 100% left · 5h 44% left · weekly 14% le…
"@
# pane hẹp: chân bị cắt, không còn chữ Context
$Narrow = @"
  Worked for 4m 52s • 1:41 PM

› $Msg

  GPT-6.1-Sol medium · ~\Crewline\.crew\worktrees\w2 · Đọc và thực hiện prompt ·…
  ? for shortcuts                                      ⚠ 3 warnings · f2 to view
"@
$CodexEmpty = @"
› <hc from="t32 crewline-planner">tin cũ trong lịch sử</hc>
• Xong.

› Ask Codex to do anything

$Footer
  ? for shortcuts                                                       ⚠ 3 warnings · f2 to view
[hc] only its screen: it is working; read again once it stops for its history
"@
$CodexWorkingText = @"
• Working (10s • esc to interrupt) · 1 background terminal running · /ps to view · /stop to close

› $Msg

$Footer
  tab to queue message
"@
$CodexQueued = @"
• Working (12s • esc to interrupt)
• Queued follow-up inputs
  ↳ $Msg
    shift+← edit last queued message


› Ask Codex to do anything

$Footer
  ? for shortcuts
"@
$Rule = '─' * 40
$ClaudeHistory = @"
❯ <hc from="t32 crewline-planner">tin đã đọc trong lịch sử</hc>
● Đã xong.
$Rule
❯
$Rule
  ctx 6% · 5h 8% · week 28%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
"@
$ClaudeBoxHc = @"
● Đã xong.
$Rule
❯ <hc from="t32 crewline-planner">gợi ý hoặc tin</hc>
$Rule
  ⏵⏵ bypass permissions on (shift+tab to cycle)
"@
$CodexPicker = @'
  Where should the new conversation run?

› 1. Use current Git worktree  Keep using the current working directory
  2. Create new Git worktree   Create a separate checkout of this repository in another directory

  enter select · esc back
'@

function New-StuckInfo([string]$app = 'codex', [string]$status = 'idle', [int]$turn = 3, [string]$state = 'live') {
  [pscustomobject]@{ name = 't'; state = $state; status = [pscustomobject]@{ app = $app; state = $status }; turn = $turn }
}
# hc giả: Get/Read trả lần lượt phần tử (hết thì giữ cuối), đếm mọi phím.
function New-StuckOps($gets, $screens, [string]$sendJson = '{"started":true}') {
  $st = @{ Gets = @($gets); Gi = 0; Screens = @($screens); Ri = 0; Enter = 0; Tab = 0; Send = 0; Sent = @() }
  @{
    State = $st
    Get   = { param($t) $k = [math]::Min($st.Gi, $st.Gets.Count - 1); $st.Gi++; $st.Gets[$k] }.GetNewClosure()
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
    Send  = { param($t, $x, $raw) $st.Send++; $st.Sent += $x; @{ Code = 0; Text = $sendJson } }.GetNewClosure()
    Keys  = { param($t) $st.Enter++ }.GetNewClosure()
    Tab   = { param($t) $st.Tab++ }.GetNewClosure()
    Sleep = { param($ms) }
  }
}

Describe 'Nhận diện tin kẹt' {
  It 'mẫu Codex thật: rảnh là tin kẹt, trả đúng chữ trong ô' {
    foreach ($state in 'idle', 'done') {
      Get-PendingInput codex $state $Stuck | Should Be 'stuck'
      Get-StuckText codex $state $Stuck | Should Be $Msg
    }
  }
  It 'tin dài xuống dòng và chân bị cắt ở pane hẹp vẫn nhận' {
    Get-PendingInput codex idle $Wrapped | Should Be 'stuck'
    Get-StuckText codex idle $Wrapped | Should Match '^<hc from.*PROBE_IDLE.*</hc>$'
    Get-PendingInput codex done $Narrow | Should Be 'stuck'
  }
  It 'mẫu đúng như prompt, cả khi còn thụt lề' {
    $sample = "  Worked for 9m 36s • 11:31 AM`n  ⚠ weekly limit: x`n  › $Msg`n`n  GPT-6.1-Sol medium · ~\Crewline · x"
    Get-PendingInput codex idle $sample | Should Be 'stuck'
  }
  It 'placeholder, ô trống, lịch sử có tin: không kẹt' {
    foreach ($state in 'idle', 'done') {
      Get-PendingInput codex $state $CodexEmpty | Should Be ''
      Get-PendingInput codex $state "› `n`n$Footer" | Should Be ''
      Get-PendingInput codex $state 'Ask Codex to do anything' | Should Be ''
      Get-PendingInput codex $state $Footer | Should Be ''
    }
  }
  It 'working, blocked, trạng thái lạ: không kẹt' {
    foreach ($state in 'working', 'blocked', '') {
      Get-PendingInput codex $state $Stuck | Should Be ''
      Get-PendingInput codex $state $CodexWorkingText | Should Be ''
    }
  }
  It 'không đúng khung thì không kẹt: thiếu dòng trống, thiếu chân, có dòng lạ dưới chân, dòng chọn số' {
    Get-PendingInput codex idle "› $Msg`n$Footer" | Should Be ''
    Get-PendingInput codex idle "› $Msg`n" | Should Be ''
    Get-PendingInput codex idle "› $Msg`n`n$Footer`n  dòng lạ" | Should Be ''
    Get-PendingInput codex idle "› 1. Yes`n`n$Footer" | Should Be ''
    Get-PendingInput codex idle "› $Msg`nkhông thụt lề`n`n$Footer" | Should Be ''
  }
  It 'Claude không bao giờ tin kẹt, kể cả có <hc from= trong lịch sử hoặc trong ô' {
    foreach ($app in 'claude', 'claude-code') {
      foreach ($state in 'idle', 'done', 'working') {
        Get-PendingInput $app $state $ClaudeHistory | Should Be ''
        Get-PendingInput $app $state $ClaudeBoxHc | Should Be ''
      }
    }
    Get-PendingInput shell idle $Stuck | Should Be ''
  }
  It 'marker hàng đợi cũ vẫn nhận khi working' {
    Get-PendingInput codex working $CodexQueued | Should Be 'queued'
  }
}

Describe 'Tin kẹt ở pane Claude: chỉ cách gỡ gợi ý mờ' {
  It 'Claude: thêm hướng dẫn bật lại đúng vai, không đổi câu cũ' {
    $why = Get-WorkerInputError 'demo-w2' $ClaudeBoxHc
    $why | Should Match '^demo-w2 có tin kẹt ở ô nhập'
    $why | Should Match 'sang pane demo-w2, Enter để gửi hoặc xóa chữ'
    $why | Should Match 'gợi ý mờ của Claude Code \(pane bật trước bản sửa\)'
    $why | Should Match 'crew up -Restart w2 \(worker có task cần -Force; xem docs/troubleshooting\.md mục Gợi ý của Claude\)'
    Get-WorkerInputError 'demo-planner' $ClaudeBoxHc | Should Match 'crew up -Restart planner '
    Get-WorkerInputError 'demo-rev' $ClaudeBoxHc | Should Match 'crew up -Restart rev '
    Get-WorkerInputError 'lạ' $ClaudeBoxHc | Should Match 'crew up -Restart <vai> '
  }
  It 'Codex hoặc ô trống: không có hướng dẫn gợi ý Claude' {
    Get-WorkerInputError 'demo-w2' $Stuck | Should Not Match 'gợi ý mờ'
    Get-WorkerInputError 'demo-w2' $ClaudeHistory | Should Be ''
  }
}

Describe 'Get-ScreenDialog không nhận nhầm do lịch sử' {
  It 'lịch sử có chữ hộp thoại, cuối màn hình là ô nhập: không phải hộp' {
    foreach ($mark in 'Allow command', 'Do you want to proceed?', 'Press y (y/n)', 'Esc to cancel', 'Yes, proceed', '› 1. Yes, proceed (y)', 'Yes, I trust this folder') {
      Get-ScreenDialog "$mark`n$CodexEmpty" | Should Be ''
      Get-ScreenDialog "$mark`n$Stuck" | Should Be ''
      Get-ScreenDialog "$mark`n$ClaudeHistory" | Should Be ''
    }
  }
  It 'chữ hộp thoại nằm trong chính ô nhập: không phải hộp' {
    Get-ScreenDialog "› sửa lỗi Allow command (y/n)`n`n$Footer" | Should Be ''
    Get-ScreenDialog "$Rule`n❯ sửa lỗi Allow command`n$Rule`n  ⏵⏵ bypass permissions on" | Should Be ''
  }
  It 'hộp thoại thật vẫn thắng' {
    Get-ScreenDialog "Allow command?`n› 1. Yes, proceed (y)" | Should Be 'other'
    Get-ScreenDialog "Do you want to proceed?`n❯ 1. Yes`n  2. No" | Should Be 'other'
    Get-ScreenDialog "Allow command?`n› 1. Yes`nContext 100% left" | Should Be 'other'
    Get-ScreenDialog "$ClaudeHistory`nDo you want to proceed?`n❯ 1. Yes" | Should Be 'other'
    Get-ScreenDialog "$CodexEmpty`nAllow command" | Should Be 'other'
    Get-ScreenDialog "Allow command?`n› 1. Yes, proceed (y)`n`n$Footer" | Should Be 'other'
    Get-ScreenDialog "Allow command`n$Rule`n❯ 1. Yes`n$Rule`n  ⏵⏵ bypass permissions on" | Should Be 'other'
    Get-ScreenDialog "Allow command`n$Rule`n❯`n$Rule`n  không phải chân agent" | Should Be 'other'
    Get-ScreenDialog "Allow command`n$Rule`n❯`n$Rule`n  ⏵⏵ bypass permissions on`n  Esc to cancel" | Should Be 'other'
    Get-ScreenDialog $CodexPicker | Should Be 'codex-new'
  }
  It 'gửi tới Rev rảnh có Allow command trong lịch sử: Enter bình thường, không báo hộp lạ' {
    $screen = "Allow command`n$Stuck"
    # Codex chỉ Enter khi ô nhập đúng tin vừa gửi ⇒ gửi đúng chữ đang nằm trong ô ($Stuck chứa $Msg)
    $ops = New-StuckOps @((New-StuckInfo), (New-StuckInfo), (New-StuckInfo), (New-StuckInfo -status 'working')) @($screen) '{"started":false}'
    $r = Invoke-SendFlow 'demo-rev' 'nội dung tin' $ops
    $r.Ok | Should Be $true
    $ops.State.Enter | Should Be 1
  }
  It 'hộp thoại thật khi gửi: 0 Enter' {
    $ops = New-StuckOps @((New-StuckInfo)) @("Do you want to proceed?`n❯ 1. Yes`n  2. No") '{"started":false}'
    $r = Invoke-SendFlow 'demo-rev' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'hộp thoại'
    $ops.State.Enter | Should Be 0
  }
}

Describe 'crew send tới pane có tin kẹt' {
  BeforeEach { $script:Said = @() }
  It 'không gửi chồng, in tin đang kẹt và cách xử lý, 0 Enter' {
    foreach ($state in 'idle', 'done') {
      $ops = New-StuckOps @((New-StuckInfo -status $state)) @($Stuck)
      $err = try { Send-CrewMessage 'demo-w2' 'tin mới' $false '' $ops; '' } catch { "$_" }
      $err | Should Match '^DIE: demo-w2 có tin kẹt'
      $err | Should Match ([regex]::Escape($Msg))
      $err | Should Match 'sang pane demo-w2, Enter để gửi hoặc xóa chữ'
      $err | Should Not Match 'Flush|Discard'
      $ops.State.Send | Should Be 0
      $ops.State.Enter | Should Be 0
      $ops.State.Tab | Should Be 0
    }
  }
  It '-Raw cũng không gửi chồng' {
    $ops = New-StuckOps @((New-StuckInfo)) @($Stuck)
    { Send-CrewMessage 'demo-w2' '/status' $true '' $ops } | Should Throw 'tin kẹt'
    $ops.State.Send | Should Be 0
  }
  It 'tin kẹt dài được cắt khi in' {
    $ops = New-StuckOps @((New-StuckInfo)) @("› $('x' * 400)`n`n$Footer")
    $err = try { Send-CrewMessage 'demo-w2' 'tin' $false '' $ops; '' } catch { "$_" }
    $err | Should Match 'x{200}…'
    $err | Should Not Match 'x{201}'
  }
  It 'các trường hợp âm không chặn gửi' {
    $cases = @(
      @{ Info = (New-StuckInfo); Screen = $CodexEmpty },
      @{ Info = (New-StuckInfo -status 'done'); Screen = "Ask Codex to do anything`n$CodexEmpty" },
      @{ Info = (New-StuckInfo -app 'claude-code'); Screen = $ClaudeHistory },
      @{ Info = (New-StuckInfo -app 'claude-code'); Screen = $ClaudeBoxHc }
    )
    foreach ($c in $cases) {
      $ops = New-StuckOps @($c.Info) @($c.Screen)
      Send-CrewMessage 'demo-w2' 'tin mới' $false '' $ops
      $ops.State.Send | Should Be 1
    }
    # Codex working có chữ: gửi được, không phải tin kẹt
    $ops = New-StuckOps @((New-StuckInfo -status 'working')) @($CodexEmpty)
    Send-CrewMessage 'demo-w2' 'tin mới' $false '' $ops
    $ops.State.Send | Should Be 1
  }
}

Describe 'crew review tới Rev có tin kẹt' {
  BeforeEach {
    $script:Said = @(); $script:Saved = 0; $script:DryRun = $false
    $script:NameList = @('a')
    $script:StuckOps = New-StuckOps @((New-StuckInfo)) @($Stuck)
    function Get-MainRoot($p) { 'C:\demo' }
    function Get-Config($p) { @{ review = 'lean'; rev = 'codex' } }
    function Get-TermInfo($t) { New-StuckInfo }
    function Get-CrewName { 'demo' }
    function Get-Tasks { , @([pscustomobject]@{ name = 'a'; branch = 'crew/a' }) }
    function Invoke-GitOrDie { @{ Code = 0; Text = 'main' } }
    function Get-ReviewLine { @{ Msg = 'Rev Gọn: merge crew/a (1111111).'; Error = '' } }
    function Get-ForeignTermError { '' }
    function Save-Tasks { $script:Saved++ }
    function New-HcOps { $script:StuckOps }
  }
  It 'không gửi, 0 Enter, không đánh dấu đã giao review' {
    $err = try { Invoke-Review; '' } catch { "$_" }
    $err | Should Match 'demo-rev có tin kẹt'
    $err | Should Match 'Enter để gửi hoặc xóa chữ'
    $script:StuckOps.State.Send | Should Be 0
    $script:StuckOps.State.Enter | Should Be 0
    $script:Saved | Should Be 0
  }
  It 'Rev sạch: gửi và đánh dấu như cũ' {
    $script:StuckOps = New-StuckOps @((New-StuckInfo), (New-StuckInfo -status 'working')) @($CodexEmpty)
    Invoke-Review
    $script:StuckOps.State.Send | Should Be 1
    $script:Saved | Should Be 1
  }
}

Describe 'crew hot báo tin kẹt' {
  BeforeEach {
    $script:Path = $TestDrive
    $script:Reads = @{}; $script:HotSend = 0; $script:HotKeys = 0
    function Get-Root($p) { $p }
    function Get-Config($p) { @{ workers = @(); planner = 'none'; rev = 'none'; review = 'lean'; access = 'full' } }
    function Get-CrewName { 'demo' }
    function Get-ForeignTermError { '' }
    function Get-Tasks { , @() }
    function Get-CopySource { '' }
    function Get-NameConflict { '' }
    function Get-MoveInfo { $null }
    function Invoke-GitQuiet { @{ Code = 0; Text = $(if ($args -contains 'rev-parse') { '.git/MERGE_HEAD' } else { '' }) } }
    function git { }
    function hc { throw 'hc thật bị cấm' }
    function Get-LiveTerminals {
      @(
        @{ name = 'demo-w1'; state = 'live'; status = 'done'; agent = 'codex' },
        @{ name = 'demo-w2'; state = 'live'; status = 'working'; agent = 'codex' },
        @{ name = 'demo-w3'; state = 'live'; status = 'idle'; agent = 'codex' },
        @{ name = 'demo-w4'; state = 'live'; status = 'done'; agent = 'claude-code' }
      ) | ForEach-Object { [pscustomobject]$_ }
    }
    $script:Screens = @{ 'demo-w1' = $Stuck; 'demo-w2' = $CodexWorkingText; 'demo-w3' = $CodexEmpty; 'demo-w4' = $ClaudeHistory }
    function New-HcOps {
      @{
        Read = { param($t) $script:Reads[$t]++; $script:Screens[$t] }
        Send = { $script:HotSend++; throw 'cấm gửi' }
        Keys = { $script:HotKeys++; throw 'cấm phím' }
        Tab  = { $script:HotKeys++; throw 'cấm phím' }
      }
    }
  }
  It 'chỉ pane kẹt hiện tin kẹt kèm cách xử lý; 1 read mỗi pane; 0 Send/Keys' {
    $out = Invoke-Hot 6>&1 | Out-String
    $out | Should Match 'demo-w1\s+tin kẹt'
    $out | Should Match 'demo-w1: tin kẹt ở ô nhập — sang pane demo-w1: Enter để gửi hoặc xóa chữ'
    $out | Should Not Match 'demo-w[234]\s+tin kẹt'
    $out | Should Not Match 'demo-w[234]: tin kẹt'
    $out | Should Not Match 'Flush|Discard'
    foreach ($n in 'demo-w1', 'demo-w2', 'demo-w3', 'demo-w4') { $script:Reads[$n] | Should Be 1 }
    $script:HotSend | Should Be 0
    $script:HotKeys | Should Be 0
  }
}

Describe 'Codex working: Tab đưa tin vào hàng đợi thật' {
  $w = { New-StuckInfo -status 'working' }
  It 'tin vừa gửi còn ở ô nhập: đúng 1 Tab, 0 Enter, báo vào hàng đợi' {
    $ops = New-StuckOps @((& $w)) @($CodexWorkingText, $CodexQueued)
    $r = Invoke-SendFlow 't' $Msg $ops
    $r.Ok | Should Be $true
    $r.Queued | Should Be $true
    $r.Message | Should Match 'tin vào hàng đợi của Codex'
    $ops.State.Tab | Should Be 1
    $ops.State.Enter | Should Be 0
  }
  It 'tin đã rời ô nhập: 0 phím' {
    $ops = New-StuckOps @((& $w)) @($CodexEmpty)
    $r = Invoke-SendFlow 't' $Msg $ops
    $r.Ok | Should Be $true
    $r.Message | Should Match 'đã nhận tin khỏi ô nhập'
    $ops.State.Tab | Should Be 0
    $ops.State.Enter | Should Be 0
  }
  It 'không bấm Tab khi: chữ lạ, hộp thoại, blocked, hết working' {
    $other = "› bản nháp của người dùng`n`n$Footer"
    $cases = @(
      @{ Gets = @((& $w)); Screen = $other },
      @{ Gets = @((& $w)); Screen = "Allow command?`n› 1. Yes, proceed (y)" },
      @{ Gets = @((& $w), (& $w), (New-StuckInfo -status 'blocked')); Screen = $CodexWorkingText },
      @{ Gets = @((& $w), (& $w), (New-StuckInfo)); Screen = $CodexWorkingText }
    )
    foreach ($c in $cases) {
      $ops = New-StuckOps $c.Gets @($c.Screen)
      $r = Invoke-SendFlow 't' $Msg $ops
      $r.Message | Should Match 'tin có thể nằm lại ô nhập, xem crew hot'
      $ops.State.Tab | Should Be 0
      $ops.State.Enter | Should Be 0
    }
  }
  It 'sau Tab chữ vẫn còn: báo không chắc, không bấm thêm' {
    $ops = New-StuckOps @((& $w)) @($CodexWorkingText)
    $r = Invoke-SendFlow 't' $Msg $ops
    $r.Message | Should Match 'tin có thể nằm lại ô nhập, xem crew hot'
    $ops.State.Tab | Should Be 1
    $ops.State.Enter | Should Be 0
  }
  It 'bảng hc không có Read/Tab: đổi chữ cho đúng Codex, 0 phím' {
    $ops = New-StuckOps @((& $w)) @($CodexEmpty)
    $ops.Remove('Read'); $ops.Remove('Tab')
    $r = Invoke-SendFlow 't' $Msg $ops
    $r.Queued | Should Be $true
    $r.Message | Should Be 'đã gửi -> t nhưng agent đang bận: tin có thể nằm lại ô nhập, xem crew hot'
  }
  It 'Claude working: chữ cũ, không Tab' {
    $ops = New-StuckOps @((New-StuckInfo -app 'claude-code' -status 'working')) @($ClaudeHistory)
    $r = Invoke-SendFlow 't' $Msg $ops
    $r.Message | Should Be 'đã gửi -> t nhưng agent đang bận: tin nằm chờ, agent đọc khi xong lượt (xem: crew hot)'
    $ops.State.Tab | Should Be 0
  }
}

Describe 'Test-SentInput: đúng và chỉ tin vừa gửi' {
  $sent = 'alpha không push'
  $hc = '<hc from="t32 crewline-planner">'
  It 'khớp: trần, có vỏ hc from, xuống dòng ở khoảng trắng, xuống dòng trong vỏ' {
    Test-SentInput @($sent) $sent | Should Be $true
    Test-SentInput @("$hc$sent</hc>") $sent | Should Be $true
    Test-SentInput @('alpha', 'không push') $sent | Should Be $true
    Test-SentInput @('<hc from="t32', 'crewline-planner">alpha không', 'push</hc>') $sent | Should Be $true
    Test-SentInput @("$hc", "$sent", '</hc>') $sent | Should Be $true
    Test-SentInput @($sent) "  $sent " | Should Be $true
  }
  It 'ca thật Rev: alpha không push vs UNAPPROVED-DRAFT push public' {
    $draft = 'UNAPPROVED-DRAFT push public'
    foreach ($box in @(
        @($draft),
        @("$sent $draft"),
        @("$draft $sent"),
        @("$hc$draft</hc>"),
        @("$hc$sent $draft</hc>"),
        @("$hc$sent</hc> $draft"),
        @("$draft $hc$sent</hc>"),
        @($sent, $draft))) {
      Test-SentInput $box $sent | Should Be $false
    }
  }
  It 'cùng đầu tin, thiếu đuôi, sửa chữ, khác hoa thường, khoảng trắng giữa dòng: không khớp' {
    $long = 'Rev Gọn: merge crew/send-stuck (6e85013). Đọc note. Không push.'
    Test-SentInput @('Rev Gọn: merge crew/send-stuck (6e85013). Đọc note. Push public luôn.') $long | Should Be $false
    Test-SentInput @('Rev Gọn: merge crew/send-stuck (6e85013).') $long | Should Be $false
    Test-SentInput @("$long thêm") $long | Should Be $false
    Test-SentInput @('alpha khong push') $sent | Should Be $false
    Test-SentInput @('ALPHA không push') $sent | Should Be $false
    Test-SentInput @('alpha  không push') $sent | Should Be $false
    Test-SentInput @('alphakhông push') $sent | Should Be $false
  }
  It 'vỏ sai hoặc lồng: không khớp; tin gửi trần không nhận vỏ' {
    Test-SentInput @("<hc>$sent</hc>") $sent | Should Be $false
    Test-SentInput @("$hc$sent") $sent | Should Be $false
    Test-SentInput @("$sent</hc>") $sent | Should Be $false
    Test-SentInput @("$hc$hc$sent</hc></hc>") $sent | Should Be $false
    Test-SentInput @("$hc$sent</hc>") $sent $true | Should Be $false
    Test-SentInput @($sent) $sent $true | Should Be $true
  }
  It 'ô trống hoặc tin rỗng: không khớp' {
    Test-SentInput @() $sent | Should Be $false
    Test-SentInput @($sent) '' | Should Be $false
  }
  It 'màn hình thật có wrap qua Get-InputBox: khớp đúng tin' {
    $text = 'PROBE_IDLE reply only ok. padding words for wrapping check here. padding words for wrapping check here.'
    $screen = "› <hc from=`"t33 crewline-w1`">PROBE_IDLE reply only ok. padding words for`n  wrapping check here. padding words for`n  wrapping check here.</hc>`n`n$Footer`n  tab to queue message"
    Test-SentInput (Get-InputBox $screen).Lines $text | Should Be $true
    Test-SentInput (Get-InputBox $screen).Lines "$text x" | Should Be $false
  }
}

Describe 'Send-CodexQueue: chữ khác tin vừa gửi hoặc trạng thái đổi thì 0 Tab' {
  $sent = 'alpha không push'
  $w = { New-StuckInfo -status 'working' }
  $boxOf = { param($t) "› $t`n`n$Footer`n  tab to queue message" }
  It 'ô nhập có đúng tin: 1 Tab, có vỏ hoặc không' {
    foreach ($t in $sent, "<hc from=`"t32 crewline-planner`">$sent</hc>") {
      $ops = New-StuckOps @((& $w)) @((& $boxOf $t), $CodexEmpty)
      (Invoke-SendFlow 't' $sent $ops).Message | Should Match 'tin vào hàng đợi của Codex'
      $ops.State.Tab | Should Be 1
      $ops.State.Enter | Should Be 0
    }
  }
  It 'chữ thêm, chữ sửa, cùng đầu tin, bản nháp khác: 0 Tab, 0 Enter, báo có thể nằm lại ô nhập' {
    $long = 'Rev Gọn: merge crew/send-stuck (6e85013). Đọc note. Không push.'
    $cases = @(
      @{ Sent = $sent; Box = 'UNAPPROVED-DRAFT push public' },
      @{ Sent = $sent; Box = "$sent UNAPPROVED-DRAFT push public" },
      @{ Sent = $sent; Box = "UNAPPROVED-DRAFT push public $sent" },
      @{ Sent = $sent; Box = "<hc from=`"t32 crewline-planner`">$sent UNAPPROVED-DRAFT push public</hc>" },
      @{ Sent = $sent; Box = 'alpha có push' },
      @{ Sent = $long; Box = 'Rev Gọn: merge crew/send-stuck (6e85013). Đọc note. Push public luôn.' }
    )
    foreach ($c in $cases) {
      $ops = New-StuckOps @((& $w)) @((& $boxOf $c.Box))
      $r = Invoke-SendFlow 't' $c.Sent $ops
      $r.Ok | Should Be $true
      $r.Message | Should Match 'tin có thể nằm lại ô nhập, xem crew hot'
      $ops.State.Tab | Should Be 0
      $ops.State.Enter | Should Be 0
    }
  }
  It 'gửi -Raw mà ô nhập có vỏ hc from: 0 Tab' {
    $ops = New-StuckOps @((& $w)) @((& $boxOf "<hc from=`"t32 crewline-planner`">$sent</hc>"))
    (Invoke-SendFlow 't' $sent $ops '' 6 $true).Message | Should Match 'tin có thể nằm lại ô nhập'
    $ops.State.Tab | Should Be 0
  }
  It 'đọc lại ngay trước phím: không live, mất Get, đổi app, blocked, hết working, hộp thoại đều 0 Tab' {
    $screen = & $boxOf $sent
    $cases = @(
      @{ Last = (New-StuckInfo -status 'working' -state 'finished'); Screen = $screen },
      @{ Last = $null; Screen = $screen },
      @{ Last = (New-StuckInfo -app 'claude-code' -status 'working'); Screen = $screen },
      @{ Last = (New-StuckInfo -status 'blocked'); Screen = $screen },
      @{ Last = (New-StuckInfo -status 'idle'); Screen = $screen },
      @{ Last = (New-StuckInfo -status 'done'); Screen = $screen },
      @{ Last = (& $w); Screen = "Allow command?`n› 1. Yes, proceed (y)" }
    )
    foreach ($c in $cases) {
      $ops = New-StuckOps @((& $w)) @($c.Screen)
      (Send-CodexQueue 't' $sent @{ Read = $ops.Read; Get = { param($t) $c.Last }.GetNewClosure(); Tab = $ops.Tab; Sleep = $ops.Sleep }).Message | Should Match 'tin có thể nằm lại ô nhập'
      $ops.State.Tab | Should Be 0
    }
    # đối chứng: cùng cách dựng, đọc lại vẫn working và đúng tin thì có đúng 1 Tab
    $last = & $w
    $ops = New-StuckOps @((& $w)) @($screen, $CodexEmpty)
    (Send-CodexQueue 't' $sent @{ Read = $ops.Read; Get = { param($t) $last }.GetNewClosure(); Tab = $ops.Tab; Sleep = $ops.Sleep }).Message | Should Match 'tin vào hàng đợi của Codex'
    $ops.State.Tab | Should Be 1
  }
}

# Fixture dựng theo màn hình Codex v0.166 (lỗi Q3/Q4 realcheck-win 2026-11-18): tests/fixtures/codex-v0.166/*.txt
function Get-CodexFixture([string]$n) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/codex-v0.166/$n.txt")) -replace "`r`n", "`n").TrimEnd("`n") }
$QWrap = Get-CodexFixture 'queue-wrap'
$QWrapAfter = Get-CodexFixture 'queue-wrap-after-tab'
$NewSession = Get-CodexFixture 'new-session'
$NewDrawing = Get-CodexFixture 'new-session-drawing'
$NewPicker = Get-CodexFixture 'new-picker'
$QText = 'Rev Gọn: merge crew/codex-queue-wrap (f1b2b51) rồi crew/small-win (e867d4f) (đúng thứ tự này). Đọc context/tasks/codex-queue-wrap.md, context/tasks/small-win.md của từng task. Full test, crew clean codex-queue-wrap, crew clean small-win, báo planner. Không push.'

Describe 'Codex v0.166 bận: tin dài gói dòng, có khối queued sẵn (Q3)' {
  $w = { New-StuckInfo -status 'working' }
  It 'Get-InputBox nhận ô nhập gói 3 dòng + dòng trống cuối ô, bỏ qua khối queued phía trên' {
    $box = Get-InputBox $QWrap
    $box.Kind | Should Be 'codex'
    @($box.Lines).Count | Should Be 3
    $box.Text | Should Match '^<hc from="t1h crewline-planner">Rev Gọn: merge crew/codex-queue-wrap .*Không push\.</hc>$'
    Test-SentInput $box.Lines $QText | Should Be $true
    Get-ScreenDialog $QWrap | Should Be ''
    (Get-InputBox $QWrapAfter).Text | Should Be ''
  }
  It 'tin dài gói dòng: đúng 1 Tab, 0 Enter, xác nhận ô trống sau Tab, báo vào hàng đợi' {
    foreach ($screen in $QWrap, ($QWrap -replace "</hc>`n`n`n", "</hc>`n`n")) {
      $ops = New-StuckOps @((& $w)) @($screen, $QWrapAfter)
      $r = Invoke-SendFlow 'crewline-rev' $QText $ops
      $r.Ok | Should Be $true
      $r.Queued | Should Be $true
      $r.Message | Should Match 'tin vào hàng đợi của Codex'
      $ops.State.Tab | Should Be 1
      $ops.State.Enter | Should Be 0
    }
  }
  It 'lần đọc đầu ô nhập chưa vẽ xong: đọc lại, rồi đúng 1 Tab' {
    $half = $QWrap -replace '(?s)\n  này\)\..*?</hc>', ''
    $ops = New-StuckOps @((& $w)) @($half, $QWrap, $QWrapAfter)
    (Invoke-SendFlow 'crewline-rev' $QText $ops).Message | Should Match 'tin vào hàng đợi của Codex'
    $ops.State.Tab | Should Be 1
  }
  It 'tin ngắn 1 dòng vẫn đạt khi có khối queued' {
    $short = $QWrap -replace '(?s)\n› <hc.*</hc>', "`n› <hc from=`"t1h crewline-planner`">alpha không push</hc>"
    $ops = New-StuckOps @((& $w)) @($short, $QWrapAfter)
    (Invoke-SendFlow 'crewline-rev' 'alpha không push' $ops).Message | Should Match 'tin vào hàng đợi của Codex'
    $ops.State.Tab | Should Be 1
  }
  It 'ô nhập có chữ người dùng gõ khác tin (cả khi gói dòng, có khối queued): 0 Tab, 0 Enter' {
    $user = $QWrap -replace 'Không push\.</hc>', 'Không push.</hc> rồi push public luôn'
    $draft = $QWrap -replace '(?s)\n› <hc.*</hc>', "`n› bản nháp của người dùng về crew/codex-queue-wrap, chưa gửi`n  dòng hai của bản nháp"
    foreach ($screen in $user, $draft) {
      $ops = New-StuckOps @((& $w)) @($screen)
      $r = Invoke-SendFlow 'crewline-rev' $QText $ops
      $r.Message | Should Match 'tin có thể nằm lại ô nhập'
      $ops.State.Tab | Should Be 0
      $ops.State.Enter | Should Be 0
    }
  }
  It 'sau Tab ô vẫn còn chữ: báo không chắc, không bấm thêm' {
    $ops = New-StuckOps @((& $w)) @($QWrap)
    (Invoke-SendFlow 'crewline-rev' $QText $ops).Message | Should Match 'tin có thể nằm lại ô nhập'
    $ops.State.Tab | Should Be 1
    $ops.State.Enter | Should Be 0
  }
  It 'hộp thoại hoặc hết working ngay trước phím: 0 Tab' {
    foreach ($c in @(@{ Get = (& $w); Screen = "$QWrap`nAllow command?`n› 1. Yes, proceed (y)" }, @{ Get = (New-StuckInfo -status 'blocked'); Screen = $QWrap })) {
      $ops = New-StuckOps @((& $w)) @($c.Screen)
      $last = $c.Get
      (Send-CodexQueue 't' $QText @{ Read = $ops.Read; Get = { param($t) $last }.GetNewClosure(); Tab = $ops.Tab; Sleep = $ops.Sleep }).Message | Should Match 'tin có thể nằm lại ô nhập'
      $ops.State.Tab | Should Be 0
    }
  }
  It 'Codex rảnh, tin dài nằm lại với dòng trống cuối ô: crew hot thấy tin kẹt' {
    Get-StuckText codex idle $QWrap | Should Match '^<hc from="t1h crewline-planner">Rev Gọn'
  }
}

Describe 'Codex v0.166: crew send /new rồi tin thường (Q4)' {
  BeforeEach { $script:Said = @() }
  It 'màn hình phiên mới có logo + banner Update available: sẵn sàng, không phải hộp thoại' {
    Get-ScreenDialog $NewSession | Should Be ''
    Test-SessionReady 'codex' (New-StuckInfo) $NewSession | Should Be $true
    (Get-InputBox $NewSession).Text | Should Be ''
    Get-ScreenDialog $NewPicker | Should Be 'codex-new'
  }
  It "crew send '/new': hộp chọn worktree thì đúng 1 Enter, chờ phiên mới rồi báo đã gửi" {
    $ops = New-StuckOps @((New-StuckInfo)) @($CodexEmpty, $NewPicker, $NewPicker, $NewDrawing, $NewSession) '{"started":false}'
    Send-CrewMessage 'crewline-rev' '/new' $true '' $ops
    $ops.State.Enter | Should Be 1
    $ops.State.Send | Should Be 1
    ($script:Said -join "`n") | Should Match 'đã gửi -> crewline-rev'
  }
  It "crew send '/new' mở thẳng phiên mới: 0 Enter" {
    $ops = New-StuckOps @((New-StuckInfo)) @($CodexEmpty, $NewSession) '{"started":false}'
    Send-CrewMessage 'crewline-rev' '/new' $false '' $ops
    $ops.State.Enter | Should Be 0
    ($script:Said -join "`n") | Should Match 'đã gửi -> crewline-rev'
  }
  It "crew send '/new' mà hộp lạ hiện ra: lỗi, 0 Enter" {
    $ops = New-StuckOps @((New-StuckInfo)) @($CodexEmpty, "Allow command?`n› 1. Yes, proceed (y)`n  2. No (esc)") '{"started":false}'
    { Send-CrewMessage 'crewline-rev' '/new' $false '' $ops } | Should Throw 'hộp thoại lạ'
    $ops.State.Enter | Should Be 0
  }
  It 'tin thường khi hộp chọn /new còn mở: không gửi, 0 phím' {
    $ops = New-StuckOps @((New-StuckInfo)) @($NewPicker)
    { Send-CrewMessage 'crewline-rev' $Msg $false '' $ops } | Should Throw 'hộp chọn của /new'
    $ops.State.Send | Should Be 0
    $ops.State.Enter | Should Be 0
    $ops.State.Tab | Should Be 0
  }
  It 'tin thường khi phiên mới chưa vẽ ô nhập: chờ tới khi sẵn sàng rồi mới gửi' {
    $ops = New-StuckOps @((New-StuckInfo), (New-StuckInfo), (New-StuckInfo), (New-StuckInfo -status 'working')) @($NewDrawing, $NewDrawing, $NewSession)
    Send-CrewMessage 'crewline-rev' 'nội dung tin' $false '' $ops
    $ops.State.Send | Should Be 1
    $ops.State.Ri -ge 3 | Should Be $true   # 3 lần đọc chờ sẵn sàng trước khi gửi
    $ops.State.Enter | Should Be 0
  }
  It 'phiên mới mãi chưa sẵn sàng: không gửi' {
    $ops = New-StuckOps @((New-StuckInfo)) @($NewDrawing)
    { Send-CrewMessage 'crewline-rev' 'nội dung tin' $false '' $ops } | Should Throw 'chưa hiện ô nhập sẵn sàng'
    $ops.State.Send | Should Be 0
  }
  It 'sau gửi ô nhập còn tin mất đầu: báo kẹt, 0 Enter (started false hoặc true)' {
    $cut = $NewSession -replace '› Ask Codex to do anything', '› h crewline-planner">nội dung tin</hc>'
    foreach ($json in '{"started":false}', '{"started":true}') {
      $ops = New-StuckOps @((New-StuckInfo)) @($NewSession, $cut) $json
      $err = try { Send-CrewMessage 'crewline-rev' 'nội dung tin' $false '' $ops; '' } catch { "$_" }
      $err | Should Match ([regex]::Escape('còn chữ khác tin vừa gửi: h crewline-planner">nội dung tin</hc>'))
      $err | Should Match 'không bấm Enter'
      $ops.State.Enter | Should Be 0
    }
  }
  It 'sau gửi Enter bị nuốt, ô nhập có ĐÚNG tin (kể cả dòng trống cuối ô): Enter 1 lần như cũ' {
    $left = $NewSession -replace '› Ask Codex to do anything', "› $Msg`n"
    $ops = New-StuckOps @((New-StuckInfo), (New-StuckInfo), (New-StuckInfo), (New-StuckInfo), (New-StuckInfo -status 'working')) @($NewSession, $left) '{"started":false}'
    Send-CrewMessage 'crewline-rev' 'nội dung tin' $false '' $ops
    $ops.State.Enter | Should Be 1
  }
  It 'sau gửi không nhận ra ô nhập Codex: không Enter mù' {
    $ops = New-StuckOps @((New-StuckInfo)) @($NewSession, $NewDrawing) '{"started":false}'
    { Send-CrewMessage 'crewline-rev' 'nội dung tin' $false '' $ops } | Should Throw 'không nhận ra ô nhập Codex'
    $ops.State.Enter | Should Be 0
  }
}

# Fixture dựng lại theo bố cục Claude Code v2.1, không phải bản chụp máy thật.
Describe 'Claude v2.1 /clear qua crew send' {
  It 'chờ màn hình clear sẵn sàng rồi gửi được tin tiếp theo nguyên vẹn' {
    $ready = Get-Content (Join-Path $PSScriptRoot 'fixtures/claude-v2.1-after-clear-reconstructed.txt') -Raw
    $ops = New-StuckOps @((New-StuckInfo -app 'claude-code')) @($ClaudeHistory, $ready, $ClaudeHistory)
    Send-CrewMessage 't' '/clear' $false '' $ops
    $ops.State.Ri | Should Be 2
    $ops.State.Enter | Should Be 0
    Send-CrewMessage 't' 'tin ngay sau clear' $false '' $ops
    $ops.State.Sent[0] | Should Be '/clear'
    $ops.State.Sent[1] | Should Be 'tin ngay sau clear'
  }
  It 'hộp thoại thật sau clear vẫn chặn, không bấm phím' {
    $ops = New-StuckOps @((New-StuckInfo -app 'claude-code')) @("Do you want to proceed?`n❯ 1. Yes`n  2. No")
    { Send-CrewMessage 't' '/clear' $false '' $ops } | Should Throw 'hộp thoại lạ'
    $ops.State.Enter | Should Be 0
    $ops.State.Send | Should Be 1
  }
}
