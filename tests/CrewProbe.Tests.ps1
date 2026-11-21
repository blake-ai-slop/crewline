function hc { throw 'hc thật bị cấm' }
. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# v16 crew probe: hàm thật qua AST, hc giả mô phỏng terminal agent (trust → phiên mới → gõ chữ → Enter → working → xong lượt → /clear|/new).
# Fixture thật: paste-v16 (Claude 2.1.329 ô trống), codex-v0.166/new-session (Codex phiên mới, Context 100%). Chuẩn hóa CRLF → LF.
$want = 'Get-ProbeRoot', 'Get-ProbeMessage', 'Get-ProbeKeys', 'Get-ProbeTrustKeys', 'Get-ProbeCommandLine', 'Invoke-Probe', 'Format-ProbeTable',
  'Save-ProbeScreens', 'Hide-ProbeHome', 'Set-ProbeTested', 'Invoke-ProbeCommand', 'Test-ProbeTerm', 'New-ProbeOps', 'New-HcOps', 'Get-SuggestionEnvLine', 'Get-Flags',
  'Get-ScreenRows', 'Find-PromptBox', 'Test-SameScreenRow', 'Compare-PasteScreens', 'Get-SendBox', 'Test-SentInput', 'Test-GhostInput', 'Get-GhostProbeMessage',
  'Get-InputBox', 'Get-ScreenDialog', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Send-CodexQueue', 'Test-SessionReady', 'Get-WorkerMode', 'Test-AgentScreen',
  'Get-CrewTestedAgents', 'Get-CrewAgentsFile', 'Read-CrewAgentsFile', 'Set-CrewAgentsEntry', 'Compare-CrewVersion', 'Get-CrewAgentKey', 'Get-AgentTestedVersion', 'Write-CrewStateFile'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { }
function Die($m) { throw "DIE: $m" }
function Get-AgentVersionHint { '' }

function Get-Fixture([string]$path) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$path")) -replace "`r`n", "`n" -replace '^\uFEFF', '').TrimEnd("`n") }
$CB = Get-Fixture 'paste-v16/claude-2.1.329-before.txt'
$XB = Get-Fixture 'codex-v0.166/new-session.txt'
$ClaudeTrust = "`n Quick safety check: Is this a project you created or one you trust?`n`n ❯ Yes, I trust this folder`n   No, exit`n`n Enter to confirm · Esc to cancel"
$CodexTrust = "`n> You are in a new folder`n`n  Trust this folder? Codex can edit files here.`n`n› 1. Trust and continue`n  2. Quit`n`n  enter continue · esc quit"

# Màn hình giả theo pha. Claude: ô '❯' của fixture; Codex: ô '› Ask Codex to do anything'.
function Get-FakeScreen {
  $p = $script:P
  if ($p.Odd) { return $p.Odd }
  switch ($p.Phase) {
    'trust' { if ($p.Kind -eq 'codex') { return $CodexTrust } return $ClaudeTrust }
    'dialog' { return ($(if ($p.Kind -eq 'codex') { $XB } else { $CB }) + "`n Do you want to proceed?`n ❯ 1. Yes`n   2. No") }
  }
  if ($p.Kind -eq 'codex') {
    $s = $XB
    if ($p.Phase -eq 'reply') { $s = $s -replace 'Context 100% left', 'Context 99% left' -replace '(?m)^› Ask Codex', "› reply with just ok`n`n• ok`n`n› Ask Codex" }
    if ($p.Box) { $s = $s -replace '(?m)^› Ask Codex to do anything$', "› $($p.Box)" }
    return $s
  }
  $s = $CB
  if ($p.Phase -eq 'reply') { $s = "❯ reply with just ok`n`n⏺ ok`n" + $s }
  if ($p.Phase -eq 'reset') { $s = "❯ /clear`n  ⎿  (no content)`n" + $CB }
  if ($p.Box) { $s = $s -replace '(?m)^❯\s*$', "❯ $($p.Box)" }
  $s
}

function New-FakeProbeOps([string]$kind, [string]$phase = 'fresh') {
  $script:P = @{ Kind = $kind; Phase = $phase; Box = ''; Turn = 1; Work = 0; Odd = ''; StartOk = $true; ReadThrow = $false; NoType = $false
    Cwd = ''; Addr = 't9'; StartText = '{"address":"t9"}'; Gets = 0; SwapAt = 0; SwapInfo = $null
    App = $(if ($kind -eq 'codex') { 'codex' } else { 'claude-code' }) }
  $script:Log = [Collections.Generic.List[string]]::new(); $script:Closed = @(); $script:Targets = @()
  @{
    Start = { param($n, $cwd, $cmd) $script:Log.Add("start:$n"); $script:P.Cwd = $cwd; $script:P.Name = $n; @{ Ok = $script:P.StartOk; Text = $(if ($script:P.StartOk) { $script:P.StartText } else { 'lỗi hc' }) } }
    Get = {
      param($t)
      $script:Targets += @("get:$t"); $script:P.Gets++
      # SwapAt: từ lần get thứ N, hc trả terminal KHÁC (pane khác chiếm tên/address, cwd khác, đang hiện trust)
      if ($script:P.SwapAt -and $script:P.Gets -ge $script:P.SwapAt) { return $script:P.SwapInfo }
      $st = if ($script:P.Work -gt 0) { $script:P.Work--; 'working' } else { 'idle' }
      [pscustomobject]@{ state = 'live'; address = $script:P.Addr; name = $script:P.Name; cwd = $script:P.Cwd; turn = $script:P.Turn; status = [pscustomobject]@{ app = $script:P.App; state = $st } }
    }
    Read = { param($t) if ($script:P.ReadThrow) { throw 'hc read hỏng' }; Get-FakeScreen }
    Press = {
      param($t, [string[]]$keys)
      $script:Log.Add("press:$($keys -join ' ')"); $script:Targets += @("press:$t")
      if ($script:P.Phase -eq 'trust') { if ($keys -contains 'enter') { $script:P.Phase = 'fresh' }; return $true }
      if (-not $script:P.NoType) { $script:P.Box += (@($keys | ForEach-Object { if ($_ -eq 'space') { ' ' } else { $_ } }) -join '') }
      $true
    }
    Keys = {
      param($t) $script:Log.Add('enter'); $script:Targets += @("enter:$t")
      if ($script:P.Box) { $script:P.Box = ''; $script:P.Turn++; $script:P.Work = 2; $script:P.Phase = 'reply' }
    }
    Space = { param($t) $script:Log.Add('space'); $true }
    Tab = { param($t) $script:Log.Add('tab') }
    Send = { param($t, $text, $raw) $script:Log.Add("send:$text"); $script:Targets += @("send:$t"); $script:P.Phase = 'reset'; @{ Code = 0; Text = '{"started":false}' } }
    Close = { param($t, $a, $c) $script:Log.Add("close:$t"); $script:Closed += @("$t@$a@$c") }
    Sleep = { param($ms) }
  }
}

Describe 'Invoke-Probe: luồng đầy đủ với hc giả' {
  It 'Claude: trust thư mục tạm ⇒ Enter, gõ tin, Invoke-SendFlow so trước/sau rồi Enter 1 lần, chờ xong lượt, /clear ⇒ đạt hết, đóng terminal' {
    $ops = New-FakeProbeOps 'claude' 'trust'
    $r = Invoke-Probe 'claude' 'crewprobe-claude-x' 'C:\tmp\p' 'claude' $ops @{ Ready = 5; Turn = 5 }
    ($r.Steps | ForEach-Object { "$($_.Step)=$($_.Status)" }) -join '|' | Should Not Match 'hụt|bỏ qua'
    $r.Ok | Should Be $true
    @($r.Steps).Count | Should Be 5
    $r.Steps[2].Reason | Should Match 'so trước/sau: ok, Enter 1 lần'
    @($script:Log | Where-Object { $_ -eq 'enter' }).Count | Should Be 1
    ($script:Log -contains 'press:enter') | Should Be $true
    ($script:Log -contains 'press:r e p l y space w i t h space j u s t space o k') | Should Be $true
    ($script:Log -contains 'send:/clear') | Should Be $true
    $script:Log[$script:Log.Count - 1] | Should Be 'close:crewprobe-claude-x'
    @($r.Screens.Keys) -join ',' | Should Be '00-trust,01-fresh,02-before,02-typed,03-reply,04-reset'
    $r.Screens['02-typed'] | Should Match '❯ reply with just ok'
    $script:Closed -join ',' | Should Be 'crewprobe-claude-x@t9@C:\tmp\p'
    # mọi thao tác theo ADDRESS đã xác nhận, không theo tên
    @($script:Targets | Where-Object { $_ -notmatch ':t9$' }).Count | Should Be 0
    @($script:Targets | Where-Object { $_ -like 'press:*' }).Count -gt 0 | Should Be $true
  }
  It 'Codex: phiên mới (Test-SessionReady), gõ tin, Enter 1 lần, /new ⇒ đạt hết' {
    $ops = New-FakeProbeOps 'codex'
    $r = Invoke-Probe 'codex' 'crewprobe-codex-x' 'C:\tmp\p' 'codex' $ops @{ Ready = 5; Turn = 5 }
    $r.Ok | Should Be $true
    $r.Steps[4].Step | Should Be '/new + phiên mới (Test-SessionReady)'
    @($script:Log | Where-Object { $_ -eq 'enter' }).Count | Should Be 1
    ($script:Log -contains 'send:/new') | Should Be $true
    ($script:Log -contains 'space') | Should Be $false
    $script:Log[$script:Log.Count - 1] | Should Be 'close:crewprobe-codex-x'
  }
  It 'hộp thoại lạ ở phiên mới ⇒ hụt, các bước sau bỏ qua, 0 phím, vẫn đóng terminal' {
    $ops = New-FakeProbeOps 'claude' 'dialog'
    $r = Invoke-Probe 'claude' 'p1' 'C:\tmp\p' 'claude' $ops @{ Ready = 3; Turn = 3 }
    $r.Ok | Should Be $false
    $r.Steps[1].Status | Should Be 'hụt'
    $r.Steps[1].Reason | Should Match 'hộp thoại lạ'
    @($r.Steps | Where-Object { $_.Status -eq 'bỏ qua' }).Count | Should Be 3
    @($script:Log | Where-Object { $_ -match '^(press|enter|send|space)' }).Count | Should Be 0
    ($script:Log -contains 'close:p1') | Should Be $true
  }
  It 'chân Claude lạ (mẫu chữ Get-InputBox không nhận) ⇒ hụt phiên mới, lý do nói rõ chỉ nhận theo ký tự ô' {
    $ops = New-FakeProbeOps 'claude'
    $script:P.Odd = $CB -replace 'bypass permissions on \(shift\+tab to cycle\)', 'new mode ✦ (ctrl+y)'
    $r = Invoke-Probe 'claude' 'p2' 'C:\tmp\p' 'claude' $ops @{ Ready = 2; Turn = 2 }
    $r.Steps[1].Status | Should Be 'hụt'
    $r.Steps[1].Reason | Should Match 'mẫu chữ \(Get-InputBox\) không nhận ra ô nhập'
    ($script:Log -contains 'close:p2') | Should Be $true
  }
  It 'gõ chữ không hiện trong ô (giao diện đổi) ⇒ hụt bước gõ tin, 0 Enter, vẫn đóng' {
    $ops = New-FakeProbeOps 'codex'
    $script:P.NoType = $true
    $r = Invoke-Probe 'codex' 'p3' 'C:\tmp\p' 'codex' $ops @{ Ready = 3; Turn = 3 }
    $r.Steps[2].Status | Should Be 'hụt'
    @($script:Log | Where-Object { $_ -eq 'enter' }).Count | Should Be 0
    $r.Steps[3].Status | Should Be 'bỏ qua'
    ($script:Log -contains 'close:p3') | Should Be $true
  }
  It 'hc run thất bại ⇒ hụt bước đầu, không gọi Close' {
    $ops = New-FakeProbeOps 'claude'
    $script:P.StartOk = $false
    $r = Invoke-Probe 'claude' 'p4' 'C:\tmp\p' 'claude' $ops @{ Ready = 2; Turn = 2 }
    $r.Steps[0].Status | Should Be 'hụt'
    $r.Steps[0].Reason | Should Match 'lỗi hc'
    @($script:Log | Where-Object { $_ -like 'close:*' }).Count | Should Be 0
  }
  It 'lỗi giữa chừng (hc read ném) ⇒ vẫn đóng terminal tạm (finally)' {
    $ops = New-FakeProbeOps 'claude'
    $script:P.ReadThrow = $true
    $threw = $false; try { Invoke-Probe 'claude' 'p5' 'C:\tmp\p' 'claude' $ops @{ Ready = 2; Turn = 2 } } catch { $threw = $true }
    $threw | Should Be $true
    ($script:Log -contains 'close:p5') | Should Be $true
  }
}

Describe 'Invoke-Probe: chỉ thao tác terminal tạm đã xác nhận (address + cwd của lượt)' {
  It 'hc run không trả address ⇒ hụt, 0 thao tác, không đóng theo tên' {
    $ops = New-FakeProbeOps 'claude' 'trust'
    $script:P.StartText = '{"name":"crewprobe-claude-x"}'
    $r = Invoke-Probe 'claude' 'crewprobe-claude-x' 'C:\tmp\p' 'claude' $ops @{ Ready = 3; Turn = 3 }
    $r.Steps[0].Status | Should Be 'hụt'
    $r.Steps[0].Reason | Should Match 'không trả address'
    @($script:Log | Where-Object { $_ -match '^(press|enter|send|space|close)' }).Count | Should Be 0
  }
  It 'address trả về là terminal cwd khác ⇒ hụt ngay, 0 phím, không đóng' {
    $ops = New-FakeProbeOps 'claude' 'trust'
    $script:P.SwapAt = 1
    $script:P.SwapInfo = [pscustomobject]@{ state = 'live'; address = 't9'; name = 'crewprobe-claude-x'; cwd = 'D:\project\khac'; turn = 1; status = [pscustomobject]@{ app = 'codex'; state = 'idle' } }
    $r = Invoke-Probe 'claude' 'crewprobe-claude-x' 'C:\tmp\p' 'claude' $ops @{ Ready = 3; Turn = 3 }
    $r.Steps[0].Status | Should Be 'hụt'
    $r.Steps[0].Reason | Should Match 'không phải terminal tạm'
    @($script:Log | Where-Object { $_ -match '^(press|enter|send|space|close)' }).Count | Should Be 0
  }
  It 'giữa chừng hc trả pane KHÁC (t-other, cwd khác, đang hiện trust Codex) ⇒ không Enter vào nó, dừng, không đóng' {
    $ops = New-FakeProbeOps 'claude' 'trust'
    $script:P.SwapAt = 2
    $script:P.SwapInfo = [pscustomobject]@{ state = 'live'; address = 't-other'; name = 'crewprobe-claude-x'; cwd = 'D:\project\khac'; turn = 1; status = [pscustomobject]@{ app = 'codex'; state = 'idle' } }
    $r = Invoke-Probe 'claude' 'crewprobe-claude-x' 'C:\tmp\p' 'claude' $ops @{ Ready = 3; Turn = 3 }
    $r.Steps[0].Status | Should Be 'đạt'
    $r.Steps[1].Status | Should Be 'hụt'
    $r.Steps[1].Reason | Should Match 'không còn là terminal tạm'
    @($script:Log | Where-Object { $_ -match '^(press|enter|send|space|close)' }).Count | Should Be 0
  }
  It 'cùng address nhưng cwd đổi ngay trước Enter của luồng gửi ⇒ 0 Enter, không đóng' {
    $ops = New-FakeProbeOps 'codex'
    $script:P.SwapAt = 6
    $script:P.SwapInfo = [pscustomobject]@{ state = 'live'; address = 't9'; name = 'x'; cwd = 'D:\khac'; turn = 1; status = [pscustomobject]@{ app = 'codex'; state = 'idle' } }
    $r = Invoke-Probe 'codex' 'p6' 'C:\tmp\p' 'codex' $ops @{ Ready = 3; Turn = 3 }
    $r.Ok | Should Be $false
    @($script:Log | Where-Object { $_ -eq 'enter' }).Count | Should Be 0
    @($script:Log | Where-Object { $_ -like 'close:*' }).Count | Should Be 0
  }
  It 'Test-ProbeTerm: address, tên, cwd phải khớp; chỉ Windows bỏ qua hoa thường của đường dẫn' {
    $cwd = Join-Path $TestDrive 'Crewline-Probe-X'
    $otherCase = Join-Path $TestDrive 'crewline-probe-x'
    $otherPath = Join-Path $TestDrive 'crewline-probe-y'
    $i = [pscustomobject]@{ address = 't9'; name = 'n'; cwd = $cwd + [IO.Path]::DirectorySeparatorChar }
    Test-ProbeTerm $i 't9' $cwd 'n' | Should Be $true
    Test-ProbeTerm $i 't9' $cwd | Should Be $true
    Test-ProbeTerm $i 't9' $otherCase 'n' | Should Be ([bool]$IsWindows)
    Test-ProbeTerm $i 't8' $cwd 'n' | Should Be $false
    Test-ProbeTerm $i 't9' $otherPath 'n' | Should Be $false
    Test-ProbeTerm $i 't9' $cwd 'm' | Should Be $false
    Test-ProbeTerm $null 't9' $cwd | Should Be $false
    Test-ProbeTerm $i '' $cwd | Should Be $false
    Test-ProbeTerm ([pscustomobject]@{ address = 't9'; name = 'n' }) 't9' $cwd | Should Be $false
  }
}

Describe 'New-ProbeOps.Close: chỉ kill/rm terminal đúng address + tên + cwd của lượt' {
  BeforeEach { $script:HcCalls = @() }
  It 'thiếu address / hc get không thấy / cwd khác / tên khác ⇒ không gọi hc kill/rm' {
    function hc { $script:HcCalls += @($args -join ' ') }
    $close = (New-ProbeOps).Close
    function Get-TermInfo { $null }
    & $close 'crewprobe-claude-x' '' 'C:\tmp\p'
    & $close 'crewprobe-claude-x' 't9' 'C:\tmp\p'
    function Get-TermInfo { [pscustomobject]@{ address = 't9'; name = 'crewprobe-claude-x'; cwd = 'D:\khac'; state = 'live' } }
    & $close 'crewprobe-claude-x' 't9' 'C:\tmp\p'
    function Get-TermInfo { [pscustomobject]@{ address = 't9'; name = 'nguoi-khac'; cwd = 'C:\tmp\p'; state = 'live' } }
    & $close 'crewprobe-claude-x' 't9' 'C:\tmp\p'
    $script:HcCalls.Count | Should Be 0
  }
  It 'khớp ⇒ hc kill rồi hc rm theo ADDRESS' {
    function hc { $script:HcCalls += @($args -join ' ') }
    function Get-TermInfo { [pscustomobject]@{ address = 't9'; name = 'crewprobe-claude-x'; cwd = 'C:\tmp\p'; state = 'exited' } }
    & (New-ProbeOps).Close 'crewprobe-claude-x' 't9' 'C:\tmp\p'
    $script:HcCalls -join '|' | Should Be 'kill t9|rm t9'
  }
}

Describe 'màn hình thật từ crew probe (tests/fixtures/probe-v16)' {
  It 'Claude 2.1.329 accept edits: chân mất mục cuối " · ← for agents" khi ô có chữ ⇒ Compare-PasteScreens vẫn đạt (trước đây below-changed)' {
    $b = Get-Fixture 'probe-v16/claude-2.1.329-accept-before.txt'
    $a = Get-Fixture 'probe-v16/claude-2.1.329-accept-typed.txt'
    $r = Compare-PasteScreens $b $a (Get-ProbeMessage) $true
    $r.Reason | Should Be 'ok'
    $r.Kind | Should Be 'claude'
  }
  It 'Codex 0.171 phiên mới: logo động phía trên ô biến mất khi ô có chữ ⇒ đạt (trước đây above-changed)' {
    $b = Get-Fixture 'probe-v16/codex-0.171-fresh-before.txt'
    $a = Get-Fixture 'probe-v16/codex-0.171-fresh-typed.txt'
    $r = Compare-PasteScreens $b $a (Get-ProbeMessage) $true
    $r.Reason | Should Be 'ok'
    $r.Kind | Should Be 'codex'
  }
  It 'phía trên ô: dòng MỚI, hoặc dòng cũ hiện lại sai thứ tự (hộp vẽ trên ô) ⇒ vẫn above-changed' {
    $b = Get-Fixture 'probe-v16/codex-0.171-fresh-before.txt'
    $a = Get-Fixture 'probe-v16/codex-0.171-fresh-typed.txt'
    $new = $a -replace '(?m)^(› reply with just ok)$', "  Run rm -rf build? (y/n)`n`n`$1"
    (Compare-PasteScreens $b $new (Get-ProbeMessage) $true).Reason | Should Be 'above-changed'
    $moved = $a -replace '(?m)^(› reply with just ok)$', "  >_ OpenAI Codex (v0.171.0)`n`n`$1"
    (Compare-PasteScreens $b $moved (Get-ProbeMessage) $true).Reason | Should Be 'above-changed'
  }
  It 'chân THÊM mục mới khi ô có chữ ⇒ vẫn below-changed (chỉ chấp nhận mất)' {
    $b = Get-Fixture 'probe-v16/claude-2.1.329-accept-before.txt'
    $a = (Get-Fixture 'probe-v16/claude-2.1.329-accept-typed.txt') -replace '\(shift\+tab to cycle\)', '(shift+tab to cycle) · ← for agents · Allow?'
    (Compare-PasteScreens $b $a (Get-ProbeMessage) $true).Reason | Should Be 'below-changed'
  }
}

Describe 'probe: hàm phụ' {
  It 'Get-ProbeKeys: chữ thường + dấu cách ⇒ tên phím; ký tự khác ⇒ ném' {
    (Get-ProbeKeys (Get-ProbeMessage)) -join ' ' | Should Be 'r e p l y space w i t h space j u s t space o k'
    $threw = $false; try { Get-ProbeKeys 'a:b' } catch { $threw = $true }
    $threw | Should Be $true
  }
  It 'Get-ProbeTrustKeys: dòng trust đang chọn ⇒ enter; dòng thoát đang chọn ⇒ di chuyển; không rõ ⇒ không bấm' {
    (Get-ProbeTrustKeys 'claude' $ClaudeTrust) -join ' ' | Should Be 'enter'
    (Get-ProbeTrustKeys 'codex' $CodexTrust) -join ' ' | Should Be 'enter'
    $noSel = "  Yes, I trust this folder`n ❯ No, exit"
    (Get-ProbeTrustKeys 'claude' $noSel) -join ' ' | Should Be 'up'
    $codexQuit = "  1. Trust and continue`n› 2. Quit"
    (Get-ProbeTrustKeys 'codex' $codexQuit) -join ' ' | Should Be 'up'
    @(Get-ProbeTrustKeys 'claude' "  Yes, I trust this folder`n  No, exit").Count | Should Be 0
  }
  It 'Get-ProbeCommandLine: bỏ biến phiên cha, tắt gợi ý Claude, cờ quyền như worker' {
    $c = Get-ProbeCommandLine 'claude' 'work'
    $c | Should Match "Remove-Item `"Env:"
    $c | Should Match "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'"
    $c | Should Match 'claude --permission-mode acceptEdits$'
    Get-ProbeCommandLine 'codex' 'work' | Should Match 'codex --no-daemon --sandbox workspace-write --ask-for-approval on-request$'
  }
  It 'Save-ProbeScreens: thư mục <agent>-<bản>-<thời điểm>, mỗi màn hình 1 file + steps.txt, UTF-8 không BOM' {
    $res = @{ Steps = @([pscustomobject]@{ Step = 'bật terminal tạm'; Status = 'đạt'; Reason = 'ok' }); Screens = [ordered]@{ '01-fresh' = "❯ ô`nchân" } }
    $dir = Save-ProbeScreens (Join-Path $TestDrive 'probe') 'claude' '2.1.329' $res ([datetime]'2026-11-21T10:15:00')
    Split-Path $dir -Leaf | Should Be 'claude-2.1.329-20261121-101500'
    [IO.File]::ReadAllText((Join-Path $dir '01-fresh.txt')) | Should Be "❯ ô`nchân"
    $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'steps.txt'))
    $bytes[0] | Should Not Be 0xEF
    [IO.File]::ReadAllText((Join-Path $dir 'steps.txt')) | Should Match 'bật terminal tạm\s+đạt\s+ok'
    Split-Path (Save-ProbeScreens (Join-Path $TestDrive 'probe') 'codex' '' $res ([datetime]'2026-11-21T10:15:00')) -Leaf | Should Be 'codex-unknown-20261121-101500'
  }
  It 'Save-ProbeScreens: thư mục HOME người dùng ⇒ ~ trong màn hình và steps.txt (hoa thường, \ và /), không đụng tên dài hơn' {
    $h = 'C:\Users\Ann'
    $screen = "  C:\Users\Ann\AppData\Local\Temp\crewline-probe-codex-1`n  c:\users\ann\appdata\x`n  C:/Users/Ann/w C:\Users\Anna\y C:\Users\Ann`n  ở C:\Users\Ann…"
    $res = @{ Steps = @([pscustomobject]@{ Step = 'bật terminal tạm'; Status = 'đạt'; Reason = 'C:\Users\Ann\Temp\p' }); Screens = [ordered]@{ '01-trust' = $screen } }
    $dir = Save-ProbeScreens (Join-Path $TestDrive 'probe-home') 'codex' '0.171' $res ([datetime]'2026-11-21T10:15:00') $h
    [IO.File]::ReadAllText((Join-Path $dir '01-trust.txt')) | Should Be "  ~\AppData\Local\Temp\crewline-probe-codex-1`n  ~\appdata\x`n  ~/w C:\Users\Anna\y ~`n  ở ~…"
    [IO.File]::ReadAllText((Join-Path $dir 'steps.txt')) | Should Match '~\\Temp\\p'
    [IO.File]::ReadAllText((Join-Path $dir 'steps.txt')) | Should Not Match 'Users'
    Hide-ProbeHome '/home/ann/x /home/anna' '/home/ann/' | Should Be '~/x /home/anna'
    Hide-ProbeHome 'C:\x' '' | Should Be 'C:\x'
  }
  It 'Get-ProbeRoot: CREWLINE_PROBE_DIR đổi đường dẫn, mặc định ~/.crewline/probe' {
    $saved = $env:CREWLINE_PROBE_DIR
    try {
      $env:CREWLINE_PROBE_DIR = 'X:\p'; Get-ProbeRoot | Should Be 'X:\p'
      $env:CREWLINE_PROBE_DIR = $null; Get-ProbeRoot | Should Be (Join-Path $HOME '.crewline/probe')
    } finally { $env:CREWLINE_PROBE_DIR = $saved }
  }
  It 'Set-ProbeTested: ghi tested vào agents.json (hàm agent-version), không hạ bản đã kiểm, giữ mục khác' {
    $saved = $env:CREWLINE_AGENTS_FILE
    try {
      $env:CREWLINE_AGENTS_FILE = Join-Path $TestDrive 'agents.json'
      [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, '{"claude":{"version":"2.1.400","checkedAt":"2026-11-21"}}')
      Set-ProbeTested 'claude' '2.1.400' | Should Be $true
      $d = (Read-CrewAgentsFile).Data
      $d.claude.tested | Should Be '2.1.400'
      $d.claude.version | Should Be '2.1.400'
      Get-AgentTestedVersion 'claude' | Should Be '2.1.400'
      Set-ProbeTested 'claude' '2.1.350' | Should Be $false
      (Read-CrewAgentsFile).Data.claude.tested | Should Be '2.1.400'
      Set-ProbeTested 'codex' '' | Should Be $false
    } finally { $env:CREWLINE_AGENTS_FILE = $saved }
  }
}

Describe 'Invoke-ProbeCommand: thư mục tạm mới duy nhất, chỉ xóa thứ chính lượt probe tạo' {
  BeforeAll {
    function claude { }
    function Invoke-AgentVersionCommand { 'claude 2.1.329 (Claude Code)' }
    function Get-CrewInstallCommand { 'irm x | iex' }
    function Write-Host { }
  }
  BeforeEach {
    $script:SavedEnv = @{ P = $env:CREWLINE_PROBE_DIR; A = $env:CREWLINE_AGENTS_FILE }
    $env:CREWLINE_PROBE_DIR = Join-Path $TestDrive 'probe-out'
    $env:CREWLINE_AGENTS_FILE = Join-Path $TestDrive ("agents-" + [guid]::NewGuid().ToString('N') + '.json')
    $script:Tmp = Join-Path $TestDrive ("tmp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Tmp | Out-Null
    # thư mục probe cũ có sẵn (của lượt khác / người dùng): không được đụng
    $script:Old = Join-Path $script:Tmp 'crewline-probe-claude-old'
    New-Item -ItemType Directory $script:Old | Out-Null
    Set-Content (Join-Path $script:Old 'keep.txt') 'giữ'
    $script:Name = 'claude'; $script:Access = 'work'
  }
  AfterEach { $env:CREWLINE_PROBE_DIR = $script:SavedEnv.P; $env:CREWLINE_AGENTS_FILE = $script:SavedEnv.A }
  It 'chạy đủ: tạo crewline-probe-claude-<GUID 32>, git init trong đó, đóng đúng terminal, xóa đúng thư mục đó; thư mục cũ còn nguyên' {
    $script:GitDirs = @()
    function Invoke-GitQuiet { $script:GitDirs += @($args[1]); @{ Code = 0; Text = '' } }
    $ops = New-FakeProbeOps 'claude'
    Invoke-ProbeCommand $ops $script:Tmp
    $script:GitDirs.Count | Should Be 1
    (Split-Path $script:GitDirs[0] -Leaf) | Should Match '^crewline-probe-claude-[0-9a-f]{32}$'
    Test-Path -LiteralPath $script:GitDirs[0] | Should Be $false
    Test-Path -LiteralPath (Join-Path $script:Old 'keep.txt') | Should Be $true
    @(Get-ChildItem -LiteralPath $script:Tmp -Name) -join ',' | Should Be 'crewline-probe-claude-old'
    $script:Closed.Count | Should Be 1
    $script:Closed[0] | Should Match '^crewprobe-claude-[0-9a-f]{8}@t9@.*crewline-probe-claude-[0-9a-f]{32}$'
    (Read-CrewAgentsFile).Data.claude.tested | Should Be '2.1.329'
  }
  It 'git init lỗi ⇒ Die, vẫn xóa thư mục chính lượt này vừa tạo, không bật terminal; thư mục cũ còn nguyên' {
    $script:GitDirs = @()
    function Invoke-GitQuiet { $script:GitDirs += @($args[1]); @{ Code = 1; Text = 'git hỏng' } }
    $ops = New-FakeProbeOps 'claude'
    $threw = $false; try { Invoke-ProbeCommand $ops $script:Tmp } catch { $threw = "$_" -match 'git init' }
    $threw | Should Be $true
    Test-Path -LiteralPath $script:GitDirs[0] | Should Be $false
    @($script:Log | Where-Object { $_ -like 'start:*' }).Count | Should Be 0
    Test-Path -LiteralPath (Join-Path $script:Old 'keep.txt') | Should Be $true
  }
}
