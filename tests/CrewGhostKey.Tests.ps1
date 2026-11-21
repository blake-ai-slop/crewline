. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# v16 ghost-key: phép thử "gõ 1 phím" phân biệt gợi ý mờ của Claude với chữ thật (Test-GhostInput) + config "suggestions".
# Hàm thật qua AST, hc giả (bảng $ops mô phỏng ô nhập Claude: dấu cách làm gợi ý biến mất, chữ thật còn — đo thật context/tasks/suggest-probe.md).
$want = 'Get-ScreenRows', 'Find-PromptBox', 'Test-SameScreenRow', 'Compare-PasteScreens', 'Get-SendBox', 'Test-SentInput', 'Test-GhostInput', 'Get-GhostProbeMessage',
  'Get-WorkerInputError', 'Get-InputBox', 'Get-ScreenDialog', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Send-CodexQueue', 'Test-SessionReady',
  'Send-CrewMessage', 'Get-SuggestionMode', 'Test-SuggestionsOn', 'Test-PaneSuggestions', 'Get-SuggestionEnvLine', 'Invoke-GitQuiet', 'Read-CrewState',
  'Get-CrewStateSchema', 'Start-Term', 'Send-WorkerTask', 'Get-AgentCommand', 'Get-Flags', 'Quote'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { $script:Said += @($m) }
function Die($m) { throw "DIE: $m" }

function Get-Fixture([string]$path) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$path")) -replace "`r`n", "`n" -replace '^\uFEFF', '').TrimEnd("`n") }
# màn hình Claude Code 2.1.329 thật, ô trống (dòng '❯' trơn sau khi hc read cắt NBSP/khoảng trắng cuối)
$Empty = Get-Fixture 'paste-v16/claude-2.1.329-before.txt'
function Get-BoxScreen([string]$text) { if ($text) { $Empty -replace '(?m)^❯\s*$', "❯ $text" } else { $Empty } }
$Suggestion = 'thêm test cho cả hai hàm'

# Bảng hc giả: ô nhập có $Box; $Ghost = chữ đó là gợi ý mờ. Dấu cách: gợi ý biến mất, chữ thật còn (dấu cách cuối bị hc read cắt).
# Backspace (crew KHÔNG được bấm — mọi test đòi không có 'backspace'): trả ô như cũ. Ghi mọi phím vào $Keys. Send: dán thay gợi ý (ô có gợi ý không dính), chữ thật thì dính vào trước tin.
function New-GhostOps([string]$box, [bool]$ghost, [string]$app = 'claude', [string]$state = 'idle') {
  $script:Box = $box; $script:Ghost = $ghost; $script:Spaced = 0; $script:Keys = @(); $script:Sent = @(); $script:Reads = 0; $script:Dialog = $false
  $script:Info = [pscustomobject]@{ state = 'live'; turn = 1; status = [pscustomobject]@{ app = $app; state = $state } }
  @{
    Get = { param($t) $script:Info }
    Read = {
      param($t) $script:Reads++
      if ($script:ReadFail -and $script:Spaced) { throw 'hc read hỏng' }
      $dlg = if ($script:Dialog) { "`n Do you want to proceed?`n ❯ 1. Yes`n   2. No" } else { '' }
      if ($script:Spaced -and $script:Ghost) { return (Get-BoxScreen '') + $dlg }
      (Get-BoxScreen $script:Box) + $dlg
    }
    Space = { param($t) $script:Keys += 'space'; if ($script:SpaceFail) { return $false }; $script:Spaced++; $true }
    Backspace = { param($t) $script:Keys += 'backspace'; if ($script:Spaced) { $script:Spaced-- } }
    Keys = { param($t) $script:Keys += 'enter' }
    Tab = { param($t) $script:Keys += 'tab' }
    Send = {
      param($t, $text, $raw) $script:Sent += $text
      $script:Info = [pscustomobject]@{ state = 'live'; turn = 2; status = [pscustomobject]@{ app = $script:Info.status.app; state = 'working' } }
      @{ Code = 0; Text = '{"started":true}' }
    }
    Sleep = { param($ms) if ($script:OnSleep) { & $script:OnSleep; $script:OnSleep = $null } }
  }
}

Describe 'Test-GhostInput: gõ đúng 1 dấu cách, không bao giờ phím xóa' {
  BeforeEach { $script:ReadFail = $false; $script:SpaceFail = $false; $script:OnSleep = $null; $script:Dialog = $false }
  It 'gợi ý mờ: dấu cách làm chữ biến mất ⇒ ghost, không Backspace (ô còn 1 dấu cách)' {
    $ops = New-GhostOps $Suggestion $true
    Test-GhostInput 'demo-planner' $ops | Should Be 'ghost'
    ($script:Keys -join ',') | Should Be 'space'
    $script:Spaced | Should Be 1
  }
  It 'chữ thật: dấu cách không làm chữ mất ⇒ real, không Backspace, chữ giữ nguyên (+1 dấu cách)' {
    $ops = New-GhostOps 'abc chữ tôi đang gõ' $false
    Test-GhostInput 'demo-planner' $ops | Should Be 'real'
    ($script:Keys -join ',') | Should Be 'space'
    $script:Box | Should Be 'abc chữ tôi đang gõ'
  }
  It 'đọc lại lỗi sau khi đã gõ dấu cách ⇒ changed, KHÔNG Backspace' {
    $ops = New-GhostOps $Suggestion $true
    $script:ReadFail = $true
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'Rev P1 ca 1: người dùng gõ q trong lúc chờ (ô abc q) ⇒ changed, KHÔNG Backspace, chữ q còn' {
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Box = 'abc q' }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
    $script:Box | Should Be 'abc q'
  }
  It 'Rev P1 ca 2: hộp duyệt hiện (blocked) trong lúc chờ ⇒ changed, KHÔNG Backspace vào hộp' {
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Dialog = $true; $script:Info = [pscustomobject]@{ state = 'live'; turn = 1; status = [pscustomobject]@{ app = 'claude'; state = 'blocked' } } }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
    # chỉ hộp thoại (state không đổi) cũng không bấm
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Dialog = $true }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'turn đổi hoặc chuyển working trong lúc chờ ⇒ changed, KHÔNG Backspace' {
    $ops = New-GhostOps $Suggestion $true
    $script:OnSleep = { $script:Info = [pscustomobject]@{ state = 'live'; turn = 2; status = [pscustomobject]@{ app = 'claude'; state = 'idle' } } }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    $ops = New-GhostOps $Suggestion $true
    $script:OnSleep = { $script:Info = [pscustomobject]@{ state = 'live'; turn = 1; status = [pscustomobject]@{ app = 'claude'; state = 'working' } } }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'gợi ý mà người dùng gõ chữ khác vào ô trong lúc chờ ⇒ changed, KHÔNG Backspace' {
    $ops = New-GhostOps $Suggestion $true
    $script:OnSleep = { $script:Ghost = $false; $script:Box = 'x' }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'Rev lần 2 ca 1: người dùng bấm ← trong lúc chờ (chữ đọc lại y hệt) ⇒ real, KHÔNG phím xóa nào' {
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Keys += 'user-left' }
    Test-GhostInput 'demo-planner' $ops | Should Be 'real'
    ($script:Keys -join ',') | Should Be 'space,user-left'
    $script:Box | Should Be 'abc'
  }
  It 'Rev lần 2 ca 2: pane bị thay cùng tên (address đổi) ⇒ changed, KHÔNG phím nào thêm' {
    $ops = New-GhostOps 'abc' $false
    $script:Info = [pscustomobject]@{ state = 'live'; address = 't-old'; turn = 1; status = [pscustomobject]@{ app = 'claude'; state = 'idle' } }
    $script:OnSleep = { $script:Info = [pscustomobject]@{ state = 'live'; address = 't-new'; turn = 1; status = [pscustomobject]@{ app = 'claude'; state = 'idle' } } }
    Test-GhostInput 'demo-planner' $ops | Should Be 'changed'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'tin dán sau dấu cách của crew: Compare-PasteScreens/Get-SendBox/Test-SentInput chấp nhận dấu cách đầu tin' {
    $after = Get-BoxScreen ' <hc from="t1 x-w1">tin mới</hc>'
    (Compare-PasteScreens $Empty $after '<hc from="t1 x-w1">tin mới</hc>').Ok | Should Be $true
    $box = Get-SendBox $after
    Test-SentInput $box.Lines 'tin mới' | Should Be $true
  }
  It 'hc keys space thất bại ⇒ unknown, không Backspace (không xóa chữ của người dùng)' {
    $ops = New-GhostOps 'abc' $false
    $script:SpaceFail = $true
    Test-GhostInput 'demo-planner' $ops | Should Be 'unknown'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'Codex, Claude working/blocked, terminal tắt ⇒ unknown, 0 phím' {
    foreach ($c in @(@('codex', 'idle'), @('claude', 'working'), @('claude', 'blocked'))) {
      $ops = New-GhostOps $Suggestion $true $c[0] $c[1]
      Test-GhostInput 'demo-planner' $ops | Should Be 'unknown'
      $script:Keys.Count | Should Be 0
    }
    $ops = New-GhostOps $Suggestion $true
    $script:Info = [pscustomobject]@{ state = 'exited'; status = [pscustomobject]@{ app = 'claude'; state = 'idle' } }
    Test-GhostInput 'demo-planner' $ops | Should Be 'unknown'
    $script:Keys.Count | Should Be 0
  }
  It 'màn hình có hộp thoại ⇒ unknown, 0 phím' {
    $ops = New-GhostOps $Suggestion $true
    $ops.Read = { param($t) (Get-BoxScreen 'x') + "`n Do you want to proceed?`n ❯ 1. Yes`n   2. No" }
    Test-GhostInput 'demo-planner' $ops | Should Be 'unknown'
    $script:Keys.Count | Should Be 0
  }
  It 'ô trống sẵn ⇒ ghost (ô thật trống), 0 phím; bảng hc thiếu Space/Backspace ⇒ unknown, 0 phím' {
    $ops = New-GhostOps '' $false
    Test-GhostInput 'demo-planner' $ops | Should Be 'ghost'
    $script:Keys.Count | Should Be 0
    $ops = New-GhostOps $Suggestion $true
    $ops.Remove('Space'); $ops.Remove('Backspace')
    Test-GhostInput 'demo-planner' $ops | Should Be 'unknown'
    $script:Keys.Count | Should Be 0
  }
}

Describe 'crew send tới Claude rảnh có chữ trong ô nhập' {
  BeforeEach { $script:ReadFail = $false; $script:SpaceFail = $false; $script:Said = @(); $script:OnSleep = $null; $script:Dialog = $false }
  It 'gợi ý mờ ⇒ gửi như ô trống, phím ngoài tin chỉ có 1 space' {
    $ops = New-GhostOps $Suggestion $true
    Send-CrewMessage 'demo-planner' 'tin từ worker' $false '' $ops
    $script:Sent.Count | Should Be 1
    $script:Sent[0] | Should Be 'tin từ worker'
    ($script:Keys -join ',') | Should Be 'space'
    ($script:Said -join "`n") | Should Match 'đã gửi -> demo-planner'
  }
  It 'chữ thật ⇒ chặn, không dán, chữ người gõ giữ nguyên' {
    $ops = New-GhostOps 'abc đang gõ dở' $false
    $err = try { Send-CrewMessage 'demo-planner' 'tin mới' $false '' $ops; '' } catch { "$_" }
    $err | Should Match 'DIE: demo-planner: ô nhập Claude có chữ bạn gõ \(crew đã thêm 1 dấu cách để kiểm, không xóa gì\).*abc đang gõ dở'
    $script:Sent.Count | Should Be 0
    ($script:Keys -join ',') | Should Be 'space'
    $script:Box | Should Be 'abc đang gõ dở'
  }
  It 'đọc lại không ra ô ⇒ coi là pane đổi: chặn, không dán, không Backspace' {
    $ops = New-GhostOps 'abc' $false
    $ops.Read = { param($t) if ($script:Spaced) { 'màn hình lạ' } else { Get-BoxScreen 'abc' } }
    { Send-CrewMessage 'demo-planner' 'tin' $false '' $ops } | Should Throw 'đổi trong lúc crew kiểm ô nhập'
    $script:Sent.Count | Should Be 0
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'pane đổi trong lúc thử ⇒ chặn, báo có thể còn 1 dấu cách thừa, không Backspace, không dán' {
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Box = 'abc q' }
    $err = try { Send-CrewMessage 'demo-planner' 'tin' $false '' $ops; '' } catch { "$_" }
    $err | Should Match 'đổi trong lúc crew kiểm ô nhập'
    $err | Should Match 'có thể còn 1 dấu cách thừa'
    $script:Sent.Count | Should Be 0
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'ô trống ⇒ gửi, 0 phím thử' {
    $ops = New-GhostOps '' $false
    Send-CrewMessage 'demo-planner' 'tin' $false '' $ops
    $script:Sent.Count | Should Be 1
    $script:Keys.Count | Should Be 0
  }
  It 'Claude đang working ⇒ không thử phím (tin nằm chờ như cũ)' {
    $ops = New-GhostOps $Suggestion $true 'claude' 'working'
    Send-CrewMessage 'demo-planner' 'tin' $false '' $ops
    $script:Sent.Count | Should Be 1
    $script:Keys -contains 'space' | Should Be $false
  }
  It 'Codex có chữ ⇒ giữ nguyên hành vi chặn cũ, không gõ space' {
    $codex = "› bản nháp codex`n`n  GPT-6.1-Sol medium · ~\demo · Context 90% left`n  ? for shortcuts"
    $ops = New-GhostOps 'x' $false 'codex' 'idle'
    $ops.Read = { param($t) $codex }
    { Send-CrewMessage 'demo-w2' 'tin' $false '' $ops } | Should Throw 'tin kẹt'
    $script:Keys.Count | Should Be 0
  }
}

Describe 'Invoke-SendFlow: ô Claude còn chữ khác tin sau khi gửi' {
  BeforeEach { $script:ReadFail = $false; $script:SpaceFail = $false; $script:OnSleep = $null; $script:Dialog = $false }
  It 'gợi ý mới hiện (tin chưa chạy) ⇒ thử 1 lần, coi ô trống ⇒ chờ, không Enter, không báo kẹt' {
    $ops = New-GhostOps '' $false
    # hc send không làm agent chạy; sau dán ô chỉ còn gợi ý
    $ops.Send = { param($t, $text, $raw) $script:Sent += $text; $script:Box = $Suggestion; $script:Ghost = $true; @{ Code = 0; Text = '{"started":false}' } }
    $r = Invoke-SendFlow 'demo-planner' 'tin' $ops '' 3
    $r.Ok | Should Be $false
    $r.Message | Should Match 'agent chưa chạy'
    $r.Message | Should Not Match 'còn chữ khác'
    @($script:Keys | Where-Object { $_ -eq 'space' }).Count | Should Be 1
    @($script:Keys | Where-Object { $_ -eq 'backspace' }).Count | Should Be 0
    $script:Keys -contains 'enter' | Should Be $false
  }
  It 'pane đổi trong lúc thử ⇒ dừng, báo dấu cách thừa, không Backspace, không Enter' {
    $ops = New-GhostOps '' $false
    $ops.Send = { param($t, $text, $raw) $script:Sent += $text; $script:Box = 'zzz'; $script:Ghost = $false; @{ Code = 0; Text = '{"started":false}' } }
    $ops.Space = { param($t) $script:Keys += 'space'; $script:Spaced++; $script:Box = 'zzz q'; $true }
    $r = Invoke-SendFlow 'demo-planner' 'tin' $ops '' 3
    $r.Ok | Should Be $false
    $r.Message | Should Match 'pane đổi trong lúc crew kiểm ô nhập'
    $r.Message | Should Match 'có thể còn 1 dấu cách thừa'
    ($script:Keys -join ',') | Should Be 'space'
  }
  It 'chữ thật khác tin ⇒ stuck như cũ, 0 Enter' {
    $ops = New-GhostOps '' $false
    $ops.Send = { param($t, $text, $raw) $script:Sent += $text; $script:Box = 'abc' + $text; $script:Ghost = $false; @{ Code = 0; Text = '{"started":false}' } }
    $r = Invoke-SendFlow 'demo-planner' 'tin' $ops '' 3
    $r.Ok | Should Be $false
    $r.Message | Should Match 'còn chữ khác tin vừa gửi'
    $script:Keys -contains 'enter' | Should Be $false
  }
}

Describe 'Get-WorkerInputError (crew task) với phép thử' {
  BeforeEach { $script:ReadFail = $false; $script:SpaceFail = $false; $script:OnSleep = $null; $script:Dialog = $false }
  It 'gợi ý ⇒ không lỗi; chữ thật ⇒ lỗi không kèm câu gợi ý mờ; không có ops ⇒ câu cũ chỉ cách bật lại' {
    $ops = New-GhostOps $Suggestion $true
    Get-WorkerInputError 'demo-w1' (Get-BoxScreen $Suggestion) $ops | Should Be ''
    ($script:Keys -join ',') | Should Be 'space'
    $ops = New-GhostOps 'abc' $false
    $m = Get-WorkerInputError 'demo-w1' (Get-BoxScreen 'abc') $ops
    $m | Should Match 'có chữ bạn gõ \(crew đã thêm 1 dấu cách'
    $m | Should Not Match 'gợi ý mờ'
    $m = Get-WorkerInputError 'demo-w1' (Get-BoxScreen 'abc')
    $m | Should Match 'gợi ý mờ'
    $ops = New-GhostOps 'abc' $false
    $script:OnSleep = { $script:Box = 'abcd' }
    Get-WorkerInputError 'demo-w1' (Get-BoxScreen 'abc') $ops | Should Match 'có thể còn 1 dấu cách thừa'
    ($script:Keys -join ',') | Should Be 'space'
  }
}

Describe 'config suggestions' {
  It 'Get-SuggestionMode: off|planner|all, thiếu/sai ⇒ off' {
    Get-SuggestionMode $null | Should Be 'off'
    Get-SuggestionMode 'Planner' | Should Be 'planner'
    Get-SuggestionMode 'all' | Should Be 'all'
    Get-SuggestionMode 'yes' | Should Be 'off'
  }
  It 'Test-SuggestionsOn theo vai' {
    Test-SuggestionsOn 'planner' 'planner' | Should Be $true
    Test-SuggestionsOn 'planner' 'w1' | Should Be $false
    Test-SuggestionsOn 'planner' 'rev' | Should Be $false
    Test-SuggestionsOn 'all' 'w2' | Should Be $true
    Test-SuggestionsOn $null 'planner' | Should Be $false
  }
  It 'Get-SuggestionEnvLine: tắt đặt false, bật xóa biến (pane cha có thể đã truyền false)' {
    $old = $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
    try {
      $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
      $on = & pwsh -NoProfile -NonInteractive -Command ((Get-SuggestionEnvLine $true) + "'[' + `$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION + ']'")
      "$on".Trim() | Should Be '[]'
      $off = & pwsh -NoProfile -NonInteractive -Command ((Get-SuggestionEnvLine $false) + "'[' + `$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION + ']'")
      "$off".Trim() | Should Be '[false]'
      $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION | Should Be 'false'
    } finally { $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = $old }
  }
  It 'Test-PaneSuggestions đọc config repo chính, cả từ worktree; thiếu config/JSON hỏng ⇒ false' {
    $repo = Join-Path $TestDrive 'proj'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
    Test-PaneSuggestions 'demo-planner' $repo | Should Be $false
    New-Item -ItemType Directory (Join-Path $repo '.crew') | Out-Null
    Set-Content (Join-Path $repo '.crew/config.json') '{"suggestions":"planner"}'
    Test-PaneSuggestions 'demo-planner' $repo | Should Be $true
    Test-PaneSuggestions 'demo-rev' $repo | Should Be $false
    Test-PaneSuggestions 'demo-w1' $repo | Should Be $false
    $wt = Join-Path $TestDrive 'wt1'
    git -C $repo worktree add -q --detach $wt 2>$null
    Set-Content (Join-Path $repo '.crew/config.json') '{"suggestions":"all"}'
    Test-PaneSuggestions 'demo-w1' $wt | Should Be $true
    Test-PaneSuggestions 'tên-lạ' $repo | Should Be $false
    Set-Content (Join-Path $repo '.crew/config.json') '{ hỏng'
    Test-PaneSuggestions 'demo-planner' $repo | Should Be $false
  }
}

Describe 'Start-Term / Send-WorkerTask theo config suggestions' {
  BeforeEach {
    $script:HcArgs = @()
    function hc { $script:HcArgs = @($args); $global:LASTEXITCODE = 0; '{"address":"t9","name":"x-planner"}' }
    function Get-HerdrSpaces { @{ Ok = $true; spaces = @([pscustomobject]@{ tabs = @([pscustomobject]@{ terminals = @([pscustomobject]@{ terminal = 't9' }) }) }) } }
  }
  function Get-PaneCmd { $i = [array]::IndexOf($script:HcArgs, '-EncodedCommand'); [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:HcArgs[$i + 1])) }
  It 'suggest $true: xóa biến thay vì đặt false; $false: đặt false' {
    Start-Term 'x-planner' 'C:\x' 'sp' 'tb' 'claude' $true | Out-Null
    (Get-PaneCmd).EndsWith("}; Remove-Item Env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION -ErrorAction Ignore; claude") | Should Be $true
    Start-Term 'x-planner' 'C:\x' 'sp' 'tb' 'claude' $false | Out-Null
    (Get-PaneCmd).EndsWith("}; `$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; claude") | Should Be $true
  }
  It 'không truyền suggest: theo config của repo ở cwd và vai trong tên' {
    $repo = Join-Path $TestDrive 'st'
    New-Item -ItemType Directory (Join-Path $repo '.crew') -Force | Out-Null
    git -C $repo init -q
    Set-Content (Join-Path $repo '.crew/config.json') '{"suggestions":"planner"}'
    Start-Term 'demo-planner' $repo 'sp' 'tb' 'claude' | Out-Null
    Get-PaneCmd | Should Match 'Remove-Item Env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'
    Start-Term 'demo-rev' $repo 'sp' 'tb' 'claude' | Out-Null
    Get-PaneCmd | Should Match "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'"
  }
  It 'Send-WorkerTask shell + suggest ⇒ xóa biến trước Set-Location' {
    $script:SentCmd = ''
    function Invoke-SendFlow($term, $text, $ops) { $script:SentCmd = $text; @{ Ok = $true; Message = 'ok' } }
    Send-WorkerTask 'x-w1' 'claude' 'shell' 'C:\wt' 'làm task' 'full' $null $true | Out-Null
    $script:SentCmd | Should Match "^Remove-Item Env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION -ErrorAction Ignore; Set-Location -LiteralPath 'C:\\wt'; "
  }
}
