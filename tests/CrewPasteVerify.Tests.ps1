. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# v16 paste-verify: xác nhận tin nằm đúng ô nhập bằng so màn hình trước/sau khi dán (Compare-PasteScreens), hàm thật qua AST, hc giả.
# Fixture thật: tests/fixtures/paste-v16 (Claude Code 2.1.329, Codex 0.171 — chụp 2026-11-20 trên demo-win, gõ chữ bằng hc keys, không Enter),
# tests/fixtures/codex-v0.166 và màn hình Codex trong CrewSendStuck. Fixture chuẩn hóa CRLF -> LF trước khi dùng (PITFALLS).
$want = 'Get-ScreenRows', 'Find-PromptBox', 'Test-SameScreenRow', 'Compare-PasteScreens', 'Get-SendBox', 'Test-SentInput',
  'Get-InputBox', 'Get-ScreenDialog', 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Send-CodexQueue', 'Test-SessionReady', 'Send-CrewMessage'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { $script:Said += @($m) }
function Die($m) { throw "DIE: $m" }

function Get-Fixture([string]$path) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$path")) -replace "`r`n", "`n" -replace '^\uFEFF', '').TrimEnd("`n") }
$CB = Get-Fixture 'paste-v16/claude-2.1.329-before.txt'
$CA = Get-Fixture 'paste-v16/claude-2.1.329-after.txt'
$CALong = Get-Fixture 'paste-v16/claude-2.1.329-after-long.txt'
$XB = Get-Fixture 'paste-v16/codex-0.171-before.txt'
$XA = Get-Fixture 'paste-v16/codex-0.171-after.txt'
$XALong = Get-Fixture 'paste-v16/codex-0.171-after-long.txt'
$Short = 'probe paste xin chao'
$Long = 'probe long message one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty end'
$Old = Get-Fixture 'codex-v0.166/new-session.txt'
$QWrap = Get-Fixture 'codex-v0.166/queue-wrap.txt'
$Msg = '<hc from="t32 crewline-planner">nội dung tin</hc>'
$OldAfter = $Old -replace '› Ask Codex to do anything', "› $Msg"
# Biến thể giao diện: dòng gợi ý lạ ở chân, đổi chữ chân, thêm dòng ⚠ mới (có cả trước và sau khi dán)
$OddHint = { param($s) $s -replace '(?m)^  ← for agents · \? for shortcuts$', '  ✦ /skills to browse · ctrl+g editor' -replace '(?m)^  \? for shortcuts.*$', '  ✦ /skills to browse · ctrl+g editor' }
$OddFoot = { param($s) $s -replace '(?m)^  GPT-[^\n]*$', '  o9-mega high · D:\demo · 12 tools · budget 3/10' }
$NewWarn = { param($s) $s + "`n  ⚠ Heads up: you have used 80% of your plan this week, see /usage" }

Describe 'Compare-PasteScreens: màn hình thật Claude 2.1.329 / Codex 0.171' {
  It 'Claude: tin ngắn, ký tự đầu ô ❯ + NBSP: đạt, Box là ô sau dán' {
    $r = Compare-PasteScreens $CB $CA $Short
    $r.Reason | Should Be 'ok'
    $r.Ok | Should Be $true
    $r.Box -join '|' | Should Be $Short
  }
  It 'Claude: tin dài gói 2 dòng, dòng nối thụt lề: đạt' {
    $r = Compare-PasteScreens $CB $CALong $Long
    $r.Ok | Should Be $true
    @($r.Box).Count | Should Be 2
  }
  It 'Codex 0.171: dòng gợi ý "← for agents" biến mất khi ô có chữ: vẫn đạt' {
    (Compare-PasteScreens $XB $XA $Short).Ok | Should Be $true
    (Compare-PasteScreens $XB $XALong $Long).Ok | Should Be $true
  }
  It 'Codex 0.166 phiên mới, tin có vỏ <hc from>: đạt; gửi trần thì không nhận vỏ' {
    (Compare-PasteScreens $Old $OldAfter 'nội dung tin').Ok | Should Be $true
    (Compare-PasteScreens $Old $OldAfter 'nội dung tin' $true).Reason | Should Be 'text-mismatch'
  }
  It 'Codex 0.166 bận, khối queued + spinner đổi giây phía trên: đạt' {
    $before = $QWrap -replace '(?s)\n› <hc.*</hc>\n\n', "`n› Ask Codex to do anything`n" -replace '3m 41s', '3m 38s'
    $text = ((Get-InputBox $QWrap).Text -replace '^<hc from="[^"]*">', '' -replace '</hc>$', '')
    (Compare-PasteScreens $before $QWrap $text).Reason | Should Be 'ok'
  }
  It 'CRLF và LF cho cùng kết quả' {
    (Compare-PasteScreens ($CB -replace "`n", "`r`n") ($CA -replace "`n", "`r`n") $Short).Ok | Should Be $true
  }
}

Describe 'Compare-PasteScreens: giao diện đổi nhỏ vẫn gửi' {
  $cases = @(
    @{ N = 'dòng gợi ý lạ ở chân'; F = $OddHint },
    @{ N = 'đổi chữ chân'; F = $OddFoot },
    @{ N = 'thêm dòng ⚠ mới'; F = $NewWarn }
  )
  foreach ($c in $cases) {
    It "$($c.N): Claude, Codex 0.171, Codex 0.166 đều đạt" {
      $f = $c.F
      (Compare-PasteScreens (& $f $CB) (& $f $CA) $Short).Reason | Should Be 'ok'
      (Compare-PasteScreens (& $f $XB) (& $f $XA) $Short).Reason | Should Be 'ok'
      (Compare-PasteScreens (& $f $Old) (& $f $OldAfter) 'nội dung tin').Reason | Should Be 'ok'
    }
  }
  It 'mẫu chữ cũ (Get-InputBox) không nhận ra ô khi chân lạ — chính là chỗ v15 hỏng' {
    Get-InputBox (& $OddFoot $XA) | Should Be $null
    Get-InputBox (& $OddHint $XB) | Should Be $null
    Get-InputBox (& $OddHint $Old) | Should Be $null
  }
}

Describe 'Compare-PasteScreens: không chắc thì không đạt' {
  It 'hộp xin duyệt thay ô nhập (Claude)' {
    $dlg = $CA -replace '(?s)─{20,}\n❯.*$', "Bash command`n  rm -rf build`nDo you want to proceed?`n❯ 1. Yes`n  2. No`nEsc to cancel"
    (Compare-PasteScreens $CB $dlg $Short).Ok | Should Be $false
  }
  It 'hộp thoại lạ dưới ô nhập (có dấu hộp thoại ở Tail)' {
    $dlg = $XA + "`n  Allow command 'git push'? (y/n)"
    $r = Compare-PasteScreens $XB $dlg $Short
    $r.Ok | Should Be $false
    $r.Reason | Should Be 'dialog'
  }
  It 'menu chọn số lạ thay ô nhập: không có ô' {
    $menu = $XB -replace '(?s)\n› Ask Codex to do anything.*$', "`n  Pick a model`n› 1. small`n  2. large`n  press enter"
    (Compare-PasteScreens $XB $menu $Short).Ok | Should Be $false
  }
  It 'ô có chữ gõ dở trước khi dán: chữ dính vào tin ⇒ text-mismatch' {
    $draft = $CB -replace '(?m)^❯$', '❯ abc'
    $after = $CB -replace '(?m)^❯$', "❯ abc$Short"
    (Compare-PasteScreens $draft $after $Short).Reason | Should Be 'text-mismatch'
    $after2 = $XB -replace '› Ask Codex to do anything', "› sửa dở $Short"
    (Compare-PasteScreens $XB $after2 $Short).Reason | Should Be 'text-mismatch'
  }
  It 'tin không hiện: ô vẫn trống / placeholder' {
    (Compare-PasteScreens $CB $CB $Short).Ok | Should Be $false
    (Compare-PasteScreens $XB $XB $Short).Reason | Should Be 'text-mismatch'
  }
  It 'tin đã có sẵn trong ô trước khi dán (không đổi): unchanged' {
    (Compare-PasteScreens $CA $CA $Short).Reason | Should Be 'unchanged'
  }
  It 'chỉ một phần tin hiện (thiếu đuôi)' {
    (Compare-PasteScreens $CB $CA 'probe paste xin chao ban').Reason | Should Be 'text-mismatch'
  }
  It 'phía trên ô đổi (agent in thêm dòng): above-changed' {
    $after = $CA -replace '(?m)^(  Mình chờ planner giao task mới.*)$', "`$1`n● dòng mới agent vừa in"
    (Compare-PasteScreens $CB $after $Short).Reason | Should Be 'above-changed'
  }
  It 'không có màn hình trước, hoặc trước không có ô' {
    (Compare-PasteScreens '' $CA $Short).Reason | Should Be 'no-box-before'
    (Compare-PasteScreens $CB '' $Short).Reason | Should Be 'no-box'
  }
}

Describe 'Test-SameScreenRow: dòng hay đổi được liệt kê' {
  It 'chỉ khác số ở dòng limit/đồng hồ/thời gian chạy/tokens/warnings: như nhau' {
    Test-SameScreenRow '  GPT-6.2-Sol medium · 5h 97% left · weekly 42% left' '  GPT-6.2-Sol medium · 5h 96% left · weekly 41% left' | Should Be $true
    Test-SameScreenRow '  Worked for 44s • 5:20 PM' '  Worked for 44s • 5:21 PM' | Should Be $true
    Test-SameScreenRow '  ⚠ 5h limit: 47% left' '  ⚠ 5h limit: 46% left' | Should Be $true
    Test-SameScreenRow '  ⚠ 3 warnings · f2 to view' '  ⚠ 4 warnings · f2 to view' | Should Be $true
    Test-SameScreenRow '  ↓ 300 tokens' '  ↓ 1200 tokens' | Should Be $true
  }
  It 'spinner Claude/Codex: như nhau dù đổi động từ' {
    Test-SameScreenRow '✻ Baked for 18s · done 4:43 PM' '✶ Pondering… (3s · esc to interrupt)' | Should Be $true
    Test-SameScreenRow '• Working (3m 41s • esc to interrupt)' '• Working (3m 43s • esc to interrupt) · 1 background terminal' | Should Be $true
  }
  It 'dòng thường khác chữ, hoặc dòng hay đổi khác chữ: khác' {
    Test-SameScreenRow '● xong' '● chưa xong' | Should Be $false
    Test-SameScreenRow '  5h 97% left' '  weekly 97% left' | Should Be $false
    Test-SameScreenRow '• Ran git status --short…' '• Ran git log --oneline…' | Should Be $false
    Test-SameScreenRow '  version 12' '  version 13' | Should Be $false
  }
}

function New-PInfo([string]$app = 'claude-code', [string]$status = 'idle', [int]$turn = 3) {
  [pscustomobject]@{ name = 't'; state = 'live'; status = [pscustomobject]@{ app = $app; state = $status }; turn = $turn }
}
function New-POps($gets, $screens, [string]$sendJson = '{"started":false}') {
  $st = @{ Gets = @($gets); Gi = 0; Screens = @($screens); Ri = 0; Enter = 0; Tab = 0; Send = 0 }
  @{
    State = $st
    Get   = { param($t) $k = [math]::Min($st.Gi, $st.Gets.Count - 1); $st.Gi++; $st.Gets[$k] }.GetNewClosure()
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
    Send  = { param($t, $x, $raw) $st.Send++; @{ Code = 0; Text = $sendJson } }.GetNewClosure()
    Keys  = { param($t) $st.Enter++ }.GetNewClosure()
    Tab   = { param($t) $st.Tab++ }.GetNewClosure()
    Sleep = { param($ms) }
  }
}

Describe 'Invoke-SendFlow: Enter bị nuốt, so trước/sau quyết định Enter' {
  It 'Claude + Codex 0.171 thật, cả biến thể chân lạ/⚠ mới: Enter 1 lần rồi working' {
    foreach ($p in @(
        @{ App = 'claude-code'; B = $CB; A = $CA },
        @{ App = 'codex'; B = $XB; A = $XA },
        @{ App = 'codex'; B = (& $OddHint $XB); A = (& $OddHint $XA) },
        @{ App = 'codex'; B = (& $OddFoot $XB); A = (& $OddFoot $XA) },
        @{ App = 'claude-code'; B = (& $NewWarn $CB); A = (& $NewWarn $CA) })) {
      $i = New-PInfo $p.App
      $ops = New-POps @($i, $i, $i, (New-PInfo $p.App 'working')) @($p.B, $p.A)
      $r = Invoke-SendFlow 't' $Short $ops
      $r.Message | Should Be 'đã gửi -> t (working)'
      $ops.State.Enter | Should Be 1
    }
  }
  It 'hộp xin duyệt / hộp lạ sau dán: 0 Enter, báo hộp thoại' {
    $dlg = $CA -replace '(?s)─{20,}\n❯.*$', "Do you want to proceed?`n❯ 1. Yes`n  2. No"
    $ops = New-POps @((New-PInfo)) @($CB, $dlg)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'hộp thoại'
    $ops.State.Enter | Should Be 0
  }
  It 'ô có chữ gõ dở: 0 Enter, báo còn chữ khác tin (Claude và Codex chân lạ)' {
    foreach ($p in @(
        @{ App = 'claude-code'; B = ($CB -replace '(?m)^❯$', '❯ abc'); A = ($CB -replace '(?m)^❯$', "❯ abc$Short") },
        @{ App = 'codex'; B = (& $OddFoot ($XB -replace 'Ask Codex to do anything', 'dở')); A = (& $OddFoot ($XB -replace 'Ask Codex to do anything', "dở $Short")) })) {
      $ops = New-POps @((New-PInfo $p.App)) @($p.B, $p.A)
      $r = Invoke-SendFlow 't' $Short $ops
      $r.Ok | Should Be $false
      $r.Message | Should Match 'còn chữ khác tin vừa gửi'
      $ops.State.Enter | Should Be 0
    }
  }
  It 'tin không hiện (ô vẫn trống): chờ, 0 Enter' {
    $ops = New-POps @((New-PInfo 'codex')) @($XB, $XB)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    $ops.State.Enter | Should Be 0
  }
  It 'phía trên ô đổi và mẫu chữ không xác nhận được: 0 Enter, báo không nhận ra ô (kèm lý do)' {
    $after = (& $OddFoot $XA) -replace '(?m)^(  Worked for 44s.*)$', "• dòng mới`n`$1"
    $ops = New-POps @((New-PInfo 'codex')) @((& $OddFoot $XB), $after)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'above-changed'
    $r.Message | Should Match 'không bấm Enter'
    $ops.State.Enter | Should Be 0
  }
  It 'phía trên đổi dù Get-InputBox thấy đúng tin (Rev P1): dòng mới ngoài ô ⇒ 0 Enter' {
    $after = $XA -replace '(?m)^(  Worked for 44s.*)$', "• dòng mới`n`$1"
    $ops = New-POps @((New-PInfo 'codex')) @($XB, $after)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    $ops.State.Enter | Should Be 0
  }
  It 'không có màn trước (agent vừa hết bận): lớp mẫu chữ cũ thấy đúng tin ⇒ Enter như cũ' {
    $i = New-PInfo 'codex'
    $ops = New-POps @((New-PInfo 'codex' 'working'), $i, $i, $i, (New-PInfo 'codex' 'working')) @($XA)
    $r = Invoke-SendFlow 't' $Short $ops
    $ops.State.Enter | Should Be 1
  }
}

Describe 'Send-CrewMessage / Send-CodexQueue: chân lạ không chặn gửi' {
  It 'Codex rảnh, chân + gợi ý lạ: gửi được (trước đây chờ ~10s rồi báo chưa hiện ô nhập)' {
    $b = & $OddHint (& $OddFoot $XB); $a = & $OddHint (& $OddFoot $XA)
    $i = New-PInfo 'codex'
    $ops = New-POps @($i, $i, $i, $i, $i, (New-PInfo 'codex' 'working')) @($b, $b, $a)
    $script:Said = @()
    Send-CrewMessage 't' $Short $false '' $ops
    $ops.State.Send | Should Be 1
    $ops.State.Enter | Should Be 1
  }
  It 'Codex rảnh, chân lạ nhưng ô có chữ dở: không gửi chồng' {
    $b = & $OddFoot ($XB -replace 'Ask Codex to do anything', 'chữ dở')
    $ops = New-POps @((New-PInfo 'codex')) @($b)
    { Send-CrewMessage 't' $Short $false '' $ops } | Should Throw 'tin kẹt ở ô nhập'
    $ops.State.Send | Should Be 0
  }
  It 'Codex rảnh, chân lạ + chữ hộp thoại trên màn hình: hộp thắng (an toàn), không gửi, 0 phím' {
    $b = (& $OddHint (& $OddFoot $XB)) -replace '(?m)^(  Worked for 44s.*)$', "• Do you want to allow command? đã trả lời trước đó`n`$1"
    Get-ScreenDialog $b | Should Be 'other'
    $ops = New-POps @((New-PInfo 'codex')) @($b)
    { Send-CrewMessage 't' $Short $false '' $ops } | Should Throw 'hộp thoại'
    $ops.State.Send | Should Be 0
    $ops.State.Enter | Should Be 0
  }
  # v16 assist-nolearn (đổi hành vi có chủ ý, planner chốt): Tab không phải tin ⇒ chỉ khi dưới ô toàn dòng ghi cứng đã biết; chân lạ + bận ⇒ 0 phím, planner confirm
  It 'Codex bận, chân lạ: đúng tin ⇒ 0 phím, không chắc (khối planner, gợi ý crew confirm)' {
    $w = New-PInfo 'codex' 'working'
    $empty = & $OddHint (& $OddFoot $XB)
    $box = & $OddHint (& $OddFoot ($XB -replace 'Ask Codex to do anything', $Short))
    Get-InputBox $box | Should Be $null
    $ops = New-POps @($w) @($box, $empty)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Unsure | Should Be $true
    $r.Message | Should Match 'crew confirm t'
    $ops.State.Tab | Should Be 0
    $ops.State.Enter | Should Be 0
  }
  It 'Codex bận, chân lạ, ô có chữ khác: 0 Tab' {
    $w = New-PInfo 'codex' 'working'
    $box = & $OddHint (& $OddFoot ($XB -replace 'Ask Codex to do anything', "x$Short"))
    $ops = New-POps @($w) @($box)
    (Invoke-SendFlow 't' $Short $ops).Message | Should Match 'tin có thể nằm lại ô nhập'
    $ops.State.Tab | Should Be 0
  }
}

# Rev P1 (2026-11-20): hộp xin duyệt hiện phía trên ô nhập sau khi dán — trước đây mép trên bị bỏ so + Get-SendDialog nuốt 'other' ⇒ 1 Enter.
Describe 'Hồi quy Rev P1: hộp xin duyệt xuất hiện ngoài khối ô nhập ⇒ 0 Enter' {
  $Rule = '─' * 60
  $Odd = '  ✦ odd footer · ctrl+g editor'
  $Bf = "● đã xong lượt trước`n$Rule`n❯`n$Rule`n$Odd"
  $dialogs = @(
    @{ N = 'Allow command (Rev)'; D = "Allow command 'git push origin main'?" },
    @{ N = 'Claude Do you want…'; D = "Bash command`n  git push origin main`nDo you want to proceed?" },
    @{ N = 'Codex approval'; D = "Would you like to run the following command?`n  `$ git push origin main`n  Yes, proceed (y)" }
  )
  foreach ($c in $dialogs) {
    It "$($c.N): Compare không đạt, Invoke-SendFlow 0 Enter, báo hộp thoại" {
      $af = "$($c.D)`n$Rule`n❯ $Short`n$Rule`n$Odd"
      (Compare-PasteScreens $Bf $af $Short).Ok | Should Be $false
      Get-InputBox $af | Should Be $null
      $ops = New-POps @((New-PInfo)) @($Bf, $af)
      $r = Invoke-SendFlow 't' $Short $ops
      $r.Ok | Should Be $false
      $r.Message | Should Match 'hộp thoại'
      $ops.State.Enter | Should Be 0
    }
  }
  It 'cả khi mẫu chữ cũ nhận ra ô đúng tin (chân Claude chuẩn): hộp phía trên vẫn chặn, 0 Enter' {
    $foot = '  ⏵⏵ bypass permissions on (shift+tab to cycle)'
    $b2 = "● đã xong`n$Rule`n❯`n$Rule`n$foot"
    $a2 = "Do you want to proceed?`n$Rule`n❯ $Short`n$Rule`n$foot"
    (Get-InputBox $a2).Text | Should Be $Short
    $ops = New-POps @((New-PInfo)) @($b2, $a2)
    $r = Invoke-SendFlow 't' $Short $ops
    $ops.State.Enter | Should Be 0
    $r.Ok | Should Be $false
    $r.Message | Should Match 'above-changed'
  }
  It 'dòng mới không phải hộp: thay 1 dòng mép trên bằng dòng chưa từng có ⇒ above-changed' {
    $af = "● dòng hoàn toàn mới`n$Rule`n❯ $Short`n$Rule`n$Odd"
    (Compare-PasteScreens $Bf $af $Short).Reason | Should Be 'above-changed'
  }
  It 'màn sau dài hơn phía trên (thêm dòng trên cùng) ⇒ above-changed' {
    $af = "● dòng mới`n● đã xong lượt trước`n$Rule`n❯ $Short`n$Rule`n$Odd"
    (Compare-PasteScreens $Bf $af $Short).Reason | Should Be 'above-changed'
  }
  It 'dòng mới dưới ô nhập ⇒ below-changed; dòng chân MẤT đi vẫn đạt' {
    (Compare-PasteScreens $Bf "● đã xong lượt trước`n$Rule`n❯ $Short`n$Rule`n$Odd`n  press y to approve" $Short).Reason | Should Be 'below-changed'
    (Compare-PasteScreens $Bf "● đã xong lượt trước`n$Rule`n❯ $Short`n$Rule" $Short).Reason | Should Be 'ok'
  }
}

# Rev P2 (2026-11-20): loại ô phải khớp app của terminal ở cả hai lối Enter.
Describe 'Hồi quy Rev P2: ô kiểu Claude trên terminal Codex (và ngược lại) ⇒ 0 Enter' {
  It 'Compare trả Kind theo ký tự đầu ô' {
    (Compare-PasteScreens $CB $CA $Short).Kind | Should Be 'claude'
    (Compare-PasteScreens $XB $XA $Short).Kind | Should Be 'codex'
    (Compare-PasteScreens $CB '' $Short).Kind | Should Be ''
  }
  It 'app codex + màn Claude khớp tin (lối so trước/sau): 0 Enter, báo kind-mismatch' {
    $ops = New-POps @((New-PInfo 'codex')) @($CB, $CA)
    $r = Invoke-SendFlow 't' $Short $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'kind-mismatch'
    $ops.State.Enter | Should Be 0
  }
  It 'app claude-code + màn Codex khớp tin: 0 Enter' {
    $ops = New-POps @((New-PInfo 'claude-code')) @($XB, $XA)
    (Invoke-SendFlow 't' $Short $ops).Ok | Should Be $false
    $ops.State.Enter | Should Be 0
  }
  It 'lối mẫu chữ cũ (không có màn trước, Get-InputBox.Kind=claude) trên app codex: 0 Enter' {
    $Rule = '─' * 60
    $a = "● xong`n$Rule`n❯ $Short`n$Rule`n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    (Get-InputBox $a).Kind | Should Be 'claude'
    $ops = New-POps @((New-PInfo 'codex' 'working'), (New-PInfo 'codex')) @($a)
    (Invoke-SendFlow 't' $Short $ops).Message | Should Match 'kind-mismatch'
    $ops.State.Enter | Should Be 0
  }
  It 'app lạ (không phải codex/claude): 0 Enter' {
    $ops = New-POps @((New-PInfo 'aider')) @($CB, $CA)
    (Invoke-SendFlow 't' $Short $ops).Ok | Should Be $false
    $ops.State.Enter | Should Be 0
  }
}
