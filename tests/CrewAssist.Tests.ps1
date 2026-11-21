function hc { throw 'hc thật bị cấm' }
. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# v16 screen-assist + assist-nolearn: crew không chắc ⇒ khối "CẦN PLANNER XEM" (màn hình + lý do + crew confirm), 0 phím.
# KHÔNG có mẫu học (chủ dự án + planner chốt 2026-11-21 sau Rev P1): không đường nào đọc kho mẫu; mọi nhận diện ghi cứng.
# Hàm thật qua AST (mọi hàm của assist.ps1 + nhận diện của send/task + state/agents), hc giả, HOME/agents giả.
$want = 'Get-ScreenRows', 'Find-PromptBox', 'Test-SameScreenRow', 'Compare-PasteScreens', 'Get-SendBox', 'Test-SentInput',
  'Get-InputBox', 'Get-ScreenDialog', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Send-CodexQueue', 'Test-SessionReady',
  'Test-GhostInput', 'Get-GhostProbeMessage', 'Get-AssistMode', 'Write-CrewStateFile', 'Use-CrewStateLock', 'Invoke-GitQuiet', 'Get-MainRoot',
  'Read-CrewState', 'Get-CrewStateSchema', 'Get-CrewTestedAgents', 'Get-CrewAgentKey', 'Compare-CrewVersion', 'Get-CrewAgentsFile',
  'Read-CrewAgentsFile', 'Set-CrewAgentsEntry', 'Get-AgentInstalledVersion', 'Get-AgentVersionHint', 'Test-AgentScreen'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($a.Name -in $want -or $a.Extent.File -like '*assist.ps1') } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { $script:Said += @($m) }
function Die($m) { throw "DIE: $m" }
function Invoke-AgentVersionCommand { throw 'không được gọi agent thật' }
$Scripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'

function Get-Fixture([string]$path) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$path")) -replace "`r`n", "`n" -replace '^﻿', '').TrimEnd("`n") }
$CB = Get-Fixture 'paste-v16/claude-2.1.329-before.txt'
$CA = Get-Fixture 'paste-v16/claude-2.1.329-after.txt'
$XB = Get-Fixture 'paste-v16/codex-0.171-before.txt'
$XA = Get-Fixture 'paste-v16/codex-0.171-after.txt'
$XFresh = Get-Fixture 'probe-v16/codex-0.171-fresh-before.txt'
$Short = 'probe paste xin chao'
# "Codex 0.172" giả: sau khi dán vẽ thêm 1 dòng gợi ý mới dưới chân (crew: below-changed ⇒ không Enter)
$NewHint = '  ⇧⏎ newline · ctrl+t transcript · 3 tips'
$XA2 = "$XA`n$NewHint"
# Repro Rev (P1 trên de315df): hộp xác nhận tiếng Việt DƯỚI chân, lựa chọn không đánh số
$ViBox = "`n  Xác nhận lưu thay đổi?`n  Lưu thay đổi`n  Quay lại"
# phiên mới Codex 0.172 giả: đầu phiên đổi chữ, không còn 'Context N% left'
$XFresh2 = ($XFresh -replace '>_ OpenAI Codex \(v0\.171\.0\)', '>_ Codex CLI 0.172.0 · new session') -replace ' · Context 100% left', ''

function New-PInfo([string]$app = 'codex', [string]$status = 'idle', [int]$turn = 3, [string]$address = 't7') {
  [pscustomobject]@{ name = 't'; state = 'live'; address = $address; status = [pscustomobject]@{ app = $app; state = $status }; turn = $turn }
}
function New-POps($gets, $screens, [string]$sendJson = '{"started":false}') {
  $st = @{ Gets = @($gets); Gi = 0; Screens = @($screens); Ri = 0; Enter = 0; Tab = 0; Send = 0; Space = 0 }
  @{
    State = $st
    Get   = { param($t) $k = [math]::Min($st.Gi, $st.Gets.Count - 1); $st.Gi++; $st.Gets[$k] }.GetNewClosure()
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
    Send  = { param($t, $x, $raw) $st.Send++; @{ Code = 0; Text = $sendJson } }.GetNewClosure()
    Keys  = { param($t) $st.Enter++ }.GetNewClosure()
    Tab   = { param($t) $st.Tab++ }.GetNewClosure()
    Space = { param($t) $st.Space++; $true }.GetNewClosure()
    Sleep = { param($ms) }
  }
}
function Get-KeyCount($ops) { $ops.State.Enter + $ops.State.Tab + $ops.State.Space }

Describe 'Get-AssistMode + khối CẦN PLANNER XEM' {
  It 'config assist: off | ask | auto; thiếu/sai ⇒ ask' {
    Get-AssistMode 'off' | Should Be 'off'
    Get-AssistMode ' AUTO ' | Should Be 'auto'
    Get-AssistMode $null | Should Be 'ask'
    Get-AssistMode 'yes' | Should Be 'ask'
  }
  It 'khối có màn hình 20–40 dòng, agent+bản, lý do, crew confirm (không learn), câu theo chế độ, phạm vi cấm, gợi ý gửi màn hình' {
    $b = @(Format-AssistBlock 'demo-w2' 'Codex 0.172.0' '0.171.0' 'nobox (below-changed)' $XA2 'ask')
    $txt = $b -join "`n"
    $txt | Should Match 'CẦN PLANNER XEM'
    $txt | Should Match 'Codex 0\.172\.0'
    $txt | Should Match 'lý do: nobox \(below-changed\)'
    $txt | Should Match 'crew confirm demo-w2'
    $txt | Should Not Match 'learn'
    $txt | Should Match 'hỏi chủ dự án trước khi chạy'
    $txt | Should Match 'hộp xin duyệt'
    $txt | Should Match 'bấm phím khác Enter'
    $txt | Should Match 'Muốn gửi màn hình này cho Crewline không'
    $n = @($b | Where-Object { $_ -like '| *' -or $_ -eq '| ' }).Count
    ($n -ge 20 -and $n -le 40) | Should Be $true
    $txt | Should Match ([regex]::Escape($NewHint.Trim()))
    (@(Format-AssistBlock 't' 'Claude Code 2.2.0' '' 'stuck' $CA 'auto') -join "`n") | Should Match 'tự quyết.*báo chủ dự án 1 dòng'
  }
}

Describe 'Không còn mẫu học (assist-nolearn)' {
  It 'send/task/assist/crew.ps1 không còn đường đọc kho mẫu hay biến mẫu học; không còn lệnh crew assist' {
    foreach ($f in 'crew/send.ps1', 'crew/task.ps1', 'crew/assist.ps1', 'crew/sessions.ps1', 'crew/up.ps1', 'crew/hot.ps1', 'crew/core.ps1', 'crew.ps1', 'help.ps1') {
      $src = [IO.File]::ReadAllText((Join-Path $Scripts $f))
      $src | Should Not Match 'screen-patterns|CREWLINE_PATTERNS_FILE|CrewLearnedPatterns|Use-AssistPatterns|Remove-AssistRows|Test-AssistFresh|Get-AssistSkipRows|Test-AssistRawBox|Get-AssistDialogRest|Invoke-Assist\b|assist-last'
    }
    $crew = [IO.File]::ReadAllText((Join-Path $Scripts 'crew.ps1'))
    $crew | Should Not Match "'assist' \{"
    $crew | Should Not Match "'confirm','assist'"
  }
  It 'kho mẫu ở CREWLINE_PATTERNS_FILE + biến cũ đặt sẵn ⇒ vẫn 0 phím (không ai đọc)' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("crew-nolearn-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
      $env:CREWLINE_PATTERNS_FILE = Join-Path $tmp 'screen-patterns.json'
      Set-Content -LiteralPath $env:CREWLINE_PATTERNS_FILE -Value '{"patterns":[{"id":"p1","kind":"input-box","agent":"codex","version":"0.172.0","rows":["⇧⏎ newline · ctrl+t transcript · # tips"]}]}' -Encoding utf8
      $script:CrewLearnedPatterns = @(@{ kind = 'input-box'; agent = 'codex'; version = '0.172.0'; rows = @('⇧⏎ newline · ctrl+t transcript · # tips') })
      $i = New-PInfo 'codex'
      $ops = New-POps @($i, $i, $i, (New-PInfo 'codex' 'working')) @($XB, $XA2)
      $r = Invoke-SendFlow 't' $Short $ops
      $r.Ok | Should Be $false
      Get-KeyCount $ops | Should Be 0
      $r.Assist | Should Be 'nobox'
      $r.Why | Should Be 'below-changed'
      $r.Screen | Should Be $XA2
      $r.ContainsKey('Learn') | Should Be $false
    } finally {
      $env:CREWLINE_PATTERNS_FILE = $null; $script:CrewLearnedPatterns = $null
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'Hồi quy repro Rev (P1 de315df) ⇒ 0 phím' {
  It 'hộp xác nhận tiếng Việt dưới chân (không đánh số), Codex rảnh ⇒ 0 Enter, khối planner' {
    $i = New-PInfo 'codex'
    $ops = New-POps @($i, $i, $i, $i) @($XB, "$XA$ViBox")
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    Get-KeyCount $ops | Should Be 0
    $r.Assist | Should Not BeNullOrEmpty
  }
  It 'cùng hộp, Claude rảnh, ô đúng tin ⇒ 0 phím, khối planner' {
    $i = New-PInfo 'claude-code'
    $ops = New-POps @($i, $i, $i, $i) @($CB, "$CA$ViBox")
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    Get-KeyCount $ops | Should Be 0
    $r.Assist | Should Be 'nobox'
  }
  # Planner chốt (đổi hành vi có chủ ý): phím KHÔNG phải tin (Tab hàng đợi Codex, Space ghost-key) chỉ khi dưới ô toàn dòng ghi cứng đã biết.
  It 'cùng hộp, Codex đang chạy (hàng đợi) ⇒ 0 Tab, không chắc mang Assist + gợi ý crew confirm' {
    $w = New-PInfo 'codex' 'working'
    $ops = New-POps @($w) @("$XA$ViBox")
    $r = Send-CodexQueue 't' $Short $ops
    Get-KeyCount $ops | Should Be 0
    $r.Unsure | Should Be $true
    $r.Assist | Should Be 'queue-unknown-tail'
    $r.Screen | Should Be "$XA$ViBox"
    $r.Message | Should Match 'crew confirm t'
    # cùng màn không có hộp (chân ghi cứng) ⇒ vẫn 1 Tab như cũ
    $ops2 = New-POps @($w) @($XA, $XB)
    Send-CodexQueue 't' $Short $ops2 | Out-Null
    $ops2.State.Tab | Should Be 1
  }
  It 'cùng hộp, Claude ô có chữ khác tin ⇒ 0 Space (không thử ghost-key), báo stuck + khối planner' {
    $i = New-PInfo 'claude-code'
    $other = ($CA -replace [regex]::Escape($Short), 'chữ khác hẳn') + $ViBox
    $ops = New-POps @($i, $i, $i, $i, $i, $i) @($CB, $other)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    Get-KeyCount $ops | Should Be 0
    Test-GhostInput 't' (New-POps @($i) @($other)) | Should Be 'unknown'
    # không có hộp ⇒ phép thử Space vẫn chạy như cũ
    $plain = $CA -replace [regex]::Escape($Short), 'chữ khác hẳn'
    $ops3 = New-POps @($i) @($plain, $plain)
    Test-GhostInput 't' $ops3 | Should Be 'real'
    $ops3.State.Space | Should Be 1
  }
  It "phiên Codex có 'Context: 90% left' (dấu hai chấm) ⇒ không phải phiên mới; /new không báo OK" {
    $ctx = $XFresh -replace 'Context 100% left', 'Context: 90% left'
    $ctx | Should Not Be $XFresh
    Test-SessionReady 'codex' (New-PInfo 'codex') $ctx | Should Be $false
    Test-SessionReady 'codex' (New-PInfo 'codex') ($XFresh -replace 'Context 100% left', 'Context: 100% left') | Should Be $true
    Test-SessionReady 'codex' (New-PInfo 'codex') ($XFresh2 -replace '(?m)^(  GPT-\S+ .*)$', '$1 · Context: 90% left') | Should Be $false
    $i = New-PInfo 'codex'
    $ops = New-POps @($i) @($ctx) '{"started":true}'
    $r = Invoke-SendFlow 't' '/new' $ops 'codex' 3
    $r.Ok | Should Be $false
    Get-KeyCount $ops | Should Be 0
    $r.Assist | Should Be 'fresh-session'
  }
  It "Test-AgentScreen nhận chân Codex 'Context: 90% left'" {
    Test-AgentScreen 'codex' "  Context: 90% left" | Should Be $true
  }
  It 'phiên Codex mới bản lạ (không đầu phiên, không Context) ⇒ không nhận, như trước screen-assist' {
    Test-SessionReady 'codex' (New-PInfo 'codex') $XFresh2 | Should Be $false
  }
}

Describe 'Bộ phủ định ghi cứng trên màn hình mẫu sai (tests/fixtures/screen-negative)' {
  $negDir = Join-Path $PSScriptRoot 'fixtures/screen-negative'
  It 'đủ loại: hộp duyệt Claude/Codex, Allow command, duyệt trên ô, ô gõ dở, hội thoại cũ, hộp lạ' {
    @(Get-ChildItem -LiteralPath $negDir -Filter *.txt).Count | Should Be 11
  }
  It 'gửi tin rồi màn sau là màn mẫu sai ⇒ 0 Enter/Tab, không báo OK (ô Claude gõ dở: chỉ phép thử ghost-key Space như cũ)' {
    foreach ($f in @(Get-ChildItem -LiteralPath $negDir -Filter *.txt)) {
      $screen = Get-Fixture "screen-negative/$($f.Name)"
      $claude = $f.Name -like 'claude-*' -or $f.Name -eq 'unknown-dialog.txt'
      $i = New-PInfo $(if ($claude) { 'claude-code' } else { 'codex' })
      $ops = New-POps @($i, $i, $i, $i) @($(if ($claude) { $CB } else { $XB }), $screen)
      # tin gửi khác mọi chữ trong màn mẫu (bản nháp mẫu đúng bằng $Short ⇒ đúng tin thì Enter là đúng)
      $r = Invoke-SendFlow 't' 'giao viec khac han' $ops
      $bad = $ops.State.Enter + $ops.State.Tab + $(if ($f.Name -eq 'claude-draft.txt') { 0 } else { $ops.State.Space })
      if ($r.Ok -or $bad) { throw "$($f.Name): Ok=$($r.Ok) Enter=$($ops.State.Enter) Tab=$($ops.State.Tab) Space=$($ops.State.Space)" }
    }
  }
}

Describe 'Show-AssistNeeded + nhật ký' {
  BeforeEach {
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("crew-assist-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Tmp | Out-Null
    $env:CREWLINE_AGENTS_FILE = Join-Path $script:Tmp 'agents.json'
    $today = Get-Date -Format 'yyyy-MM-dd'
    Set-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Value "{`"codex`":{`"version`":`"0.172.0`",`"checkedAt`":`"$today`"},`"claude`":{`"version`":`"2.1.329`",`"checkedAt`":`"$today`"}}" -Encoding utf8
    $script:Repo = Join-Path $script:Tmp 'repo'
    New-Item -ItemType Directory $script:Repo | Out-Null
    git -C $script:Repo init -q 2>$null
    New-Item -ItemType Directory (Join-Path $script:Repo '.crew') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:Repo '.crew/config.json') -Value '{"name":"demo","assist":"ask"}' -Encoding utf8
  }
  AfterEach {
    $env:CREWLINE_AGENTS_FILE = $null
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  It 'khối in khi assist ≠ off, ghi nhật ký shown (không ghi assist-last.json); confirm sau đó ghi confirmed; hot đếm hôm nay' {
    Push-Location $script:Repo
    try {
      $out = @(Show-AssistNeeded 'demo-w2' @{ Assist = 'nobox'; Why = 'below-changed'; Screen = $XA2 } 'codex' { param($t) $XA2 } 6>&1) -join "`n"
      $out | Should Match 'CẦN PLANNER XEM'
      $out | Should Match 'Codex 0\.172\.0'
      $out | Should Match 'crew confirm demo-w2'
      $out | Should Not Match 'learn'
      Get-AssistTodayCount $script:Repo | Should Be 1
      Test-Path -LiteralPath (Join-Path $script:Repo '.crew/assist-last.json') | Should Be $false
      Add-AssistConfirmLog 'demo-w2'
      $log = @(Get-AssistLog $script:Repo)
      $log[-1].Action | Should Be 'confirmed'
      $log[-1].Agent | Should Be 'codex 0.172.0'
      Add-AssistConfirmLog 'demo-w2'
      @(Get-AssistLog $script:Repo).Count | Should Be 2
      Set-Content -LiteralPath (Join-Path $script:Repo '.crew/config.json') -Value '{"name":"demo","assist":"off"}' -Encoding utf8
      $off = @(Show-AssistNeeded 'demo-w2' @{ Assist = 'nobox'; Screen = $XA2 } 'codex' { param($t) $XA2 } 6>&1) -join "`n"
      $off | Should Be ''
      Get-AssistTodayCount $script:Repo | Should Be 1
      Get-AssistTodayCount $script:Repo ((Get-Date).AddDays(1)) | Should Be 0
    } finally { Pop-Location }
  }
}

# v16 knowntail-fix (Rev P1 sau 0862b2f): KnownTail kiểm TỪNG dòng dưới ô, khớp toàn dòng (đã trim) danh sách đóng trong Get-SendBox.
$RevWarn = Get-Fixture 'codex-v0.171/warn-rightaligned.txt'
$RevText = 'Rev Nhanh: merge crew/tested-agents (2f8333a). Đọc context/tasks/tested-agents.md. Full test, crew clean tested-agents, báo planner. Không push.'
function Set-LastPrompt([string]$screen, [string]$text) {
  $i = $screen.LastIndexOf("`n› "); $j = $screen.IndexOf("`n", $i + 1)
  $screen.Substring(0, $i + 1) + "› $text" + $(if ($j -ge 0) { $screen.Substring($j) } else { '' })
}
$Plain = $CA -replace [regex]::Escape($Short), 'chữ khác hẳn'
$RevA = $Plain -replace '(?m)^(  Opus 5\.5 - medium - 5%)$', "  Xác nhận lưu thay đổi`n`$1"
$RevB = $XA -replace '(?m)^  GPT-6\.2-Sol .*$', "  Lưu thay đổi · Quay lại`n  ? for shortcuts"
$RevC = "$XA`n  ? for shortcuts · Lưu thay đổi"
$RevC2 = "$XA`n  tab to queue message   Xác nhận lưu"

Describe 'knowntail-fix: 3 ca Rev ⇒ 0 phím (LF + CRLF), ca chuẩn vẫn Tab/Space' {
  $w = New-PInfo 'codex' 'working'
  $i = New-PInfo 'claude-code'
  It '(a) Claude: dòng lạ chen TRƯỚC chân chuẩn ⇒ KnownTail false, 0 Space' {
    foreach ($s in $RevA, $RevA.Replace("`n", "`r`n")) {
      (Get-SendBox $s).KnownTail | Should Be $false
      $ops = New-POps @($i) @($s, $s)
      Test-GhostInput 't' $ops | Should Be 'unknown'
      Get-KeyCount $ops | Should Be 0
    }
  }
  It '(b) Codex: chân lạ có " · " ở giữa + gợi ý chuẩn ⇒ 0 Tab; (c) gợi ý chuẩn có hậu tố lạ ⇒ 0 Tab' {
    foreach ($s in $RevB, $RevC, $RevC2) {
      foreach ($v in $s, $s.Replace("`n", "`r`n")) {
        (Get-InputBox $v).Kind | Should Be 'codex'
        (Get-SendBox $v).KnownTail | Should Be $false
        $ops = New-POps @($w) @($v, $XB)
        $r = Send-CodexQueue 't' $Short $ops
        Get-KeyCount $ops | Should Be 0
        $r.Assist | Should Be 'queue-unknown-tail'
      }
    }
  }
  It 'Codex chuẩn: chân, có/không gợi ý, ← for agents, tab to queue message, ⚠ căn phải, chân bị cắt … ⇒ 1 Tab (LF + CRLF)' {
    $cut = $XA -replace ' · weekly 42% left · Context 97% left', ' · weekly 42% left · C…'
    $cut | Should Not Be $XA
    foreach ($s in $XA, "$XA`n  ← for agents · ? for shortcuts", "$XA`n  tab to queue message                    ⚠ 3 warnings · f2 to view",
      "$XA`n  ? for shortcuts", "$XA`n                                        ⚠ 1 warning · f2 to view", $cut) {
      foreach ($v in $s, $s.Replace("`n", "`r`n")) {
        (Get-SendBox $v).KnownTail | Should Be $true
        $ops = New-POps @($w) @($v, $XB)
        Send-CodexQueue 't' $Short $ops | Out-Null
        $ops.State.Tab | Should Be 1
      }
    }
  }
  It 'Claude chuẩn: bypass/accept edits, có/không " · ← for agents", status line ⇒ Space thử như cũ (LF + CRLF)' {
    $acc = Get-Fixture 'probe-v16/claude-2.1.329-accept-before.txt'
    $acc = $acc -replace '(?m)^❯\s*$', '❯ chữ khác hẳn'
    foreach ($s in $Plain, $acc, ($acc -replace ' · ← for agents', '')) {
      foreach ($v in $s, $s.Replace("`n", "`r`n")) {
        (Get-SendBox $v).KnownTail | Should Be $true
        $ops = New-POps @($i) @($v, $v)
        Test-GhostInput 't' $ops | Should Be 'real'
        $ops.State.Space | Should Be 1
      }
    }
  }
  It 'mẫu dòng: khớp toàn dòng sau trim, không chuỗi con' {
    Get-SendBox '' 'codex' '                 ⚠ 5h limit: 47% left · resets at 2:05 PM · /status' | Should Be $true
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline · Đọc vai trò rev và chờ giao việc · Context 58% left · 5h 41% left' | Should Be $true
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Đọc vai trò · Lưu thay đổi · Context 58% left' | Should Be $false
    Get-SendBox '' 'codex' '  5h 47% left · weekly 53% left' | Should Be $true
    Get-SendBox '' 'codex' '  Lưu thay đổi · 5h 47% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.2-Sol medium · Context 9… thêm' | Should Be $false
    Get-SendBox '' 'codex' '  ⚠ 5h limit: 47% left · Lưu thay đổi' | Should Be $false
    Get-SendBox '' 'claude' '  ⏵⏵ bypass permissions on (shift+tab to cycle) · Lưu' | Should Be $false
    Get-SendBox '' 'claude' '  ⏵⏵ bypass permissions on · 1 background task · ↓ to view' | Should Be $true
    Get-SendBox '' 'claude' '  ⚠ 1 warning · f2 to view' | Should Be $false
  }
}

# v16 knowntail-fix2 (Rev P1 sau 85bf96c, planner chọn B): chân Codex — tối đa 1 đoạn tự do (tên luồng), chỉ sau đầu/đường dẫn, trước mục số, không ở cuối.
$Foot = '  GPT-6.2-Sol medium · 5h 97% left · weekly 42% left · Context 97% left'
Describe 'knowntail-fix2: hậu tố dính sau Context / mục chữ thêm ⇒ 0 Tab (LF + CRLF)' {
  $w = New-PInfo 'codex' 'working'
  It 'mẫu trong $XA có chân chuẩn' { $XA.Contains($Foot) | Should Be $true }
  It '4 ca Rev ⇒ KnownTail false, 0 phím, queue-unknown-tail' {
    foreach ($bad in "$Foot Xác nhận lưu thay đổi", "$Foot · Xác nhận lưu thay đổi",
      '  GPT-6.2-Sol medium · 5h 97% left · weekly 42% left · Context 97% left Xác nhận lưu thay đổi · ? for shortcuts',
      '  GPT-6.2-Sol medium · 5h 97% left · Xác nhận lưu thay đổi · Context 97% left') {
      $s = $XA.Replace($Foot, $bad)
      foreach ($v in $s, $s.Replace("`n", "`r`n")) {
        (Get-SendBox $v).KnownTail | Should Be $false
        $ops = New-POps @($w) @($v, $XB)
        $r = Send-CodexQueue 't' $Short $ops
        Get-KeyCount $ops | Should Be 0
        $r.Assist | Should Be 'queue-unknown-tail'
      }
    }
  }
  It 'mẫu dòng: vị trí đoạn tự do' {
    # được: tên luồng sau đầu hoặc sau đường dẫn, trước mục số (queue-wrap thật)
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Đọc vai trò rev · Context 58% left' | Should Be $true
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline · crew/knowntail-fix2 · 5h 41% left · 219K used' | Should Be $true
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline · Đọc vai trò · C…' | Should Be $true
    # không được: ở cuối, sau mục số, 2 đoạn tự do, không có mục số theo sau, không đầu GPT-, cắt … ở đoạn tự do
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline · Đọc vai trò' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Context 58% left · Đọc vai trò' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Context 58% left · Đọc vai trò · 5h 41% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Context 58% left Lưu · 5h 41% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline · 5h 41% left Xác nhận · Context 58% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · ~\Crewline Xác nhận · Context 58% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Đọc · Lưu · Context 58% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Đọc vai trò · ~\Crewline' | Should Be $false
    Get-SendBox '' 'codex' '  ~\Crewline · Đọc vai trò · Context 58% left' | Should Be $false
    Get-SendBox '' 'codex' '  GPT-6.1-Sol medium · Đọc vai tr…' | Should Be $false
  }
  It 'Rev lần 2: hậu tố DÍNH LIỀN sau left/Context/5h/weekly/used (đoạn tự do chứa mảnh mục số) ⇒ 0 phím (LF + CRLF)' {
    foreach ($seg in 'Context 97% leftXác nhận lưu thay đổi', 'ContextXác nhận lưu', 'Context: 97% leftXác', '5hXác nhận', '5h 97% leftXác nhận',
      'weeklyXác nhận', 'weekly 42% leftXác', 'Xác nhận 97% left', 'Xác nhận 219K used', 'xác CONTEXT lưu', 'Xác nhận lưu 97%') {
      Get-SendBox '' 'codex' "  GPT-6.2-Sol medium · $seg · 5h 97% left" | Should Be $false
      Get-SendBox '' 'codex' "  GPT-6.2-Sol medium · ~\Crewline · $seg · Context 97% left" | Should Be $false
      $s = $XA.Replace($Foot, "  GPT-6.2-Sol medium · $seg · 5h 97% left · weekly 42% left · Context 97% left")
      foreach ($v in $s, $s.Replace("`n", "`r`n")) {
        (Get-SendBox $v).KnownTail | Should Be $false
        $ops = New-POps @($w) @($v, $XB)
        $r = Send-CodexQueue 't' $Short $ops
        Get-KeyCount $ops | Should Be 0
        $r.Assist | Should Be 'queue-unknown-tail'
      }
    }
  }
  It 'GIỚI HẠN ĐÃ BIẾT (để Rev đánh giá): 1 mục chữ chèn giữa đầu/đường dẫn và mục số không phân biệt được với tên luồng thật ⇒ vẫn Tab' {
    $s = $XA.Replace($Foot, '  GPT-6.2-Sol medium · Xác nhận lưu thay đổi · 5h 97% left · weekly 42% left · Context 97% left')
    (Get-SendBox $s).KnownTail | Should Be $true
  }
}

Describe 'knowntail-fix: màn thật Codex 0.171 cảnh báo căn phải (fixtures/codex-v0.171/warn-rightaligned.txt)' {
  $before = Set-LastPrompt $RevWarn 'Ask Codex to do anything'
  It 'ô nhận, dưới ô toàn dòng ghi cứng; Codex bận ⇒ 1 Tab (LF + CRLF)' {
    foreach ($v in $RevWarn, $RevWarn.Replace("`n", "`r`n")) {
      $box = Get-SendBox $v
      $box.Kind | Should Be 'codex'
      $box.KnownTail | Should Be $true
      $ops = New-POps @((New-PInfo 'codex' 'working')) @($v, $before)
      $r = Send-CodexQueue 't' $RevText $ops
      $ops.State.Tab | Should Be 1
      $r.Unsure | Should Not Be $true
    }
  }
  It 'so màn trước/sau dán: dòng ⚠ ghi cứng hiện/ẩn/tách khỏi gợi ý ⇒ vẫn ok; dòng lạ thêm dưới ô vẫn below-changed' {
    $rows = $before -split "`n"
    $hintWarn = (($rows[0..($rows.Count - 2)]) -join "`n") + "`n  ← for agents · ? for shortcuts" + $rows[-1].Substring(33)
    $noUpper = $before -replace '(?m)^\s+⚠ 5h limit.*\n', ''
    $hintOnly = $before -replace '(?m)^\s+⚠ 1 warning.*$', '  ← for agents · ? for shortcuts'
    foreach ($b in $before, $hintWarn, $noUpper, $hintOnly) {
      (Compare-PasteScreens $b $RevWarn $RevText).Reason | Should Be 'ok'
      (Compare-PasteScreens $b.Replace("`n", "`r`n") $RevWarn.Replace("`n", "`r`n") $RevText).Reason | Should Be 'ok'
    }
    (Compare-PasteScreens $before "$RevWarn`n  ⚠ Lưu thay đổi?" $RevText).Reason | Should Be 'below-changed'
    (Compare-PasteScreens $before "$RevWarn`n$NewHint" $RevText).Reason | Should Be 'below-changed'
  }
}
