# Test crew limits: trích hàm bằng AST từ crew.ps1, hc và CLI đều giả; không gọi hc/codex/claude thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/platform.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-LimitTiers', 'Get-LimitWeekWarn', 'Get-LimitLevel', 'Get-LimitInfo', 'Resolve-LimitRows',
    'ConvertTo-LimitPercent', 'Format-LimitEpoch', 'Get-CodexLimitHello', 'Get-CodexLimitStep', 'ConvertFrom-CodexLimitReply',
    'ConvertFrom-ClaudeUsageText', 'ConvertFrom-ClaudeUsageReply', 'Get-LimitCliInvocation', 'Invoke-LimitProcess',
    'Get-CodexLiveLimit', 'Get-ClaudeLiveLimit', 'ConvertTo-LimitInfo', 'Invoke-Limits',
    'Get-ForeignTermError', 'Test-TermOwner', 'Test-SamePath', 'ConvertTo-RootKey' }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

Describe 'Get-LimitInfo' {
  It 'chân màn hình Codex thật -> 5h 0, tuần 29, ok' {
    $s = "› gõ gì đó`nGPT-6.1-Sol medium · ~\Crewline · main · Context 58% left · 5h 100% left · weekly 71% left · 325K used"
    $i = Get-LimitInfo $s
    $i.FiveHour | Should Be 0
    $i.Week | Should Be 29
    $i.Level | Should Be 'ok'
  }

  It 'Codex 5h 40% left, weekly 90% left -> 60/10, theo dõi' {
    $i = Get-LimitInfo 'Context 90% left · 5h 40% left · weekly 90% left'
    $i.FiveHour | Should Be 60
    $i.Week | Should Be 10
    $i.Level | Should Be 'theo dõi'
  }

  It 'chỉ có 5h 15% left -> 85, tuần không rõ, hạn chế' {
    $i = Get-LimitInfo 'Context 99% left · 5h 15% left'
    $i.FiveHour | Should Be 85
    $null -eq $i.Week | Should Be $true
    $i.Level | Should Be 'hạn chế'
  }

  It 'status line Claude -> 13/24, ok' {
    $i = Get-LimitInfo 'ctx 42% · 5h 13% · week 24%'
    $i.FiveHour | Should Be 13
    $i.Week | Should Be 24
    $i.Level | Should Be 'ok'
  }

  It 'màn hình không có số -> không rõ' {
    $i = Get-LimitInfo "> Try `"fix lint`"`n? for shortcuts"
    $null -eq $i.FiveHour | Should Be $true
    $null -eq $i.Week | Should Be $true
    $i.Level | Should Be 'không rõ'
  }

  It 'chữ khác có % (Context 58% left, ctx 90%) không bị nhầm' {
    $i = Get-LimitInfo 'Context 58% left · ctx 90% · 15h 3% · biweekly 99%'
    $null -eq $i.FiveHour | Should Be $true
    $null -eq $i.Week | Should Be $true
    $i.Level | Should Be 'không rõ'
  }

  It 'màn hình rỗng -> không rõ' {
    (Get-LimitInfo '').Level | Should Be 'không rõ'
  }
}

Describe 'Mốc 3 cấp (ranh giới)' {
  $cases = @(
    @{ U = 0; L = 'ok' }, @{ U = 49; L = 'ok' }, @{ U = 50; L = 'theo dõi' }, @{ U = 69; L = 'theo dõi' },
    @{ U = 70; L = 'hạn chế' }, @{ U = 89; L = 'hạn chế' }, @{ U = 90; L = 'dừng' }, @{ U = 100; L = 'dừng' }
  )
  foreach ($c in $cases) {
    It "dùng $($c.U)% -> $($c.L) (Claude và Codex)" {
      (Get-LimitInfo "5h $($c.U)% · week 0%").Level | Should Be $c.L
      (Get-LimitInfo "5h $(100 - $c.U)% left · weekly 100% left").Level | Should Be $c.L
      Get-LimitLevel $c.U | Should Be $c.L
    }
  }

  It 'ngưỡng cảnh báo tuần chỉ ở Get-LimitWeekWarn: 90' {
    Get-LimitWeekWarn | Should Be 90
  }

  It 'ngưỡng chỉ ở Get-LimitTiers: 50/70/90 xếp giảm dần' {
    $t = Get-LimitTiers
    ($t | ForEach-Object { $_.Min }) -join ',' | Should Be '90,70,50'
    ($t | ForEach-Object { $_.Level }) -join ',' | Should Be 'dừng,hạn chế,theo dõi'
  }
}

Describe 'Mốc chỉ theo 5h, tuần chỉ cảnh báo' {
  It '5h thấp + tuần cao (<90) -> ok, không cảnh báo' {
    $i = Get-LimitInfo '5h 10% · week 89%'
    $i.Level | Should Be 'ok'
    $i.WeekWarn | Should Be $false
  }

  It '5h thấp + tuần ≥90 -> ok + cảnh báo' {
    $i = Get-LimitInfo '5h 10% · week 90%'
    $i.Level | Should Be 'ok'
    $i.WeekWarn | Should Be $true
  }

  It '5h 75 + tuần 10 -> hạn chế, không cảnh báo' {
    $i = Get-LimitInfo '5h 75% · week 10%'
    $i.Level | Should Be 'hạn chế'
    $i.WeekWarn | Should Be $false
  }

  It 'thiếu 5h + có tuần -> không rõ; tuần ≥90 vẫn cảnh báo' {
    $i = Get-LimitInfo 'ctx 40% · week 30%'
    $i.Level | Should Be 'không rõ'
    $i.WeekWarn | Should Be $false
    $j = Get-LimitInfo 'Context 80% left · weekly 5% left'
    $j.Level | Should Be 'không rõ'
    $j.Week | Should Be 95
    $j.WeekWarn | Should Be $true
  }

  It 'màn hình Codex: 5h 100% left · weekly 5% left -> ok + cảnh báo' {
    $i = Get-LimitInfo 'GPT-6.1-Sol medium · Context 58% left · 5h 100% left · weekly 5% left · 325K used'
    $i.FiveHour | Should Be 0
    $i.Week | Should Be 95
    $i.Level | Should Be 'ok'
    $i.WeekWarn | Should Be $true
  }

  It 'màn hình Claude: 5h 13% · week 95% -> ok + cảnh báo' {
    $i = Get-LimitInfo 'ctx 42% · 5h 13% · week 95%'
    $i.FiveHour | Should Be 13
    $i.Week | Should Be 95
    $i.Level | Should Be 'ok'
    $i.WeekWarn | Should Be $true
  }

  It 'không có số -> không cảnh báo' {
    (Get-LimitInfo '').WeekWarn | Should Be $false
  }
}

Describe 'Resolve-LimitRows (limit theo tài khoản agent)' {
  $codexFull = 'Context 58% left · 5h 100% left · weekly 71% left · 325K used'
  $codexCut = 'GPT-6.1-Sol medium · ~\Crewline · main · Context 90% left · …'

  It 'pane codex bị cắt lấy số của pane codex đọc được, ghi From' {
    $rows = @(
      @{ Name = 'c-w2'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexCut) },
      @{ Name = 'c-rev'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexFull) }
    )
    $out = Resolve-LimitRows $rows
    $out.Count | Should Be 2
    $out[0].From | Should Be 'c-rev'
    $out[0].Shown.FiveHour | Should Be 0
    $out[0].Shown.Week | Should Be 29
    $out[0].Shown.Level | Should Be 'ok'
    $null -eq $out[1].From | Should Be $true
    $out[1].Shown.Week | Should Be 29
  }

  It 'pane mượn số cũng mượn mốc mới (dừng)' {
    $rows = @(
      @{ Name = 'c-w1'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexCut) },
      @{ Name = 'c-w2'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo '5h 5% left · weekly 50% left') }
    )
    $out = Resolve-LimitRows $rows
    $out[0].From | Should Be 'c-w2'
    $out[0].Shown.FiveHour | Should Be 95
    $out[0].Shown.Level | Should Be 'dừng'
  }

  It 'không mượn chéo agent; cả agent không đọc được -> không rõ' {
    $rows = @(
      @{ Name = 'c-w1'; Agent = 'claude'; Live = $true; Info = (Get-LimitInfo '? for shortcuts') },
      @{ Name = 'c-rev'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexFull) }
    )
    $out = Resolve-LimitRows $rows
    $null -eq $out[0].From | Should Be $true
    $out[0].Shown.Level | Should Be 'không rõ'
  }

  It 'pane tắt không mượn và không làm nguồn' {
    $rows = @(
      @{ Name = 'c-w1'; Agent = 'codex'; Live = $false; Info = $null },
      @{ Name = 'c-w2'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexCut) }
    )
    $out = Resolve-LimitRows $rows
    $null -eq $out[0].From | Should Be $true
    $null -eq $out[1].From | Should Be $true
    $out[1].Shown.Level | Should Be 'không rõ'
  }

  It 'mượn số giữ cờ cảnh báo tuần của nguồn' {
    $rows = @(
      @{ Name = 'c-w1'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo $codexCut) },
      @{ Name = 'c-rev'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo '5h 100% left · weekly 5% left') }
    )
    $out = Resolve-LimitRows $rows
    $out[0].From | Should Be 'c-rev'
    $out[0].Shown.Level | Should Be 'ok'
    $out[0].Shown.WeekWarn | Should Be $true
  }

  It 'pane tự đọc được tuần ≥90 nhưng thiếu 5h: mượn 5h, vẫn giữ cảnh báo' {
    $rows = @(
      @{ Name = 'c-w1'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo 'Context 90% left · weekly 8% left') },
      @{ Name = 'c-rev'; Agent = 'codex'; Live = $true; Info = (Get-LimitInfo '5h 100% left') }
    )
    $out = Resolve-LimitRows $rows
    $out[0].From | Should Be 'c-rev'
    $out[0].Shown.Level | Should Be 'ok'
    $out[0].Shown.WeekWarn | Should Be $true
    $out[1].Shown.WeekWarn | Should Be $false
  }
}

# ---- Số trực tiếp từ CLI. Fixture tự viết, tài khoản giả; không gọi codex/claude thật. ----
function New-CodexReply($five = 18, $week = 75, $fiveMins = 300, $weekMins = 10080) {
  $reply = @{ id = 2; result = @{ account = @{ email = 'fake@example.test'; planType = 'fakeplan' }; rateLimits = @{
    primary = @{ usedPercent = $five; windowDurationMins = $fiveMins; resetsAt = 1893456000 }
    secondary = @{ usedPercent = $week; windowDurationMins = $weekMins; resetsAt = 1893888000 }
  } } }
  return ($reply | ConvertTo-Json -Depth 6 -Compress)
}
$FakeUsage = "Tip: 99% of people use /help`nCurrent session: 13% used · resets Nov 2, 1:30am (Asia/Bangkok)`nCurrent week (all models): 29% used · resets Nov 7, 11am (Asia/Bangkok)`nCurrent week (Sonnet only): 77% used · resets Nov 7, 11am (Asia/Bangkok)`nAccount: fake@example.test"
function New-ClaudeReply([string]$text = $FakeUsage, $turns = 0, $isError = $false) {
  return (@{ type = 'result'; is_error = $isError; num_turns = $turns; total_cost_usd = 0; result = $text } | ConvertTo-Json -Compress)
}

Describe 'ConvertFrom-CodexLimitReply' {
  $now = [datetime]'2030-01-01'
  It 'phản hồi đủ: lấy %, giờ reset; bỏ qua dòng khác' {
    $r = ConvertFrom-CodexLimitReply @('banner không phải JSON', '{"method":"account/updated"}', '{"id":1,"result":{}}', (New-CodexReply)) $now
    $r.FiveHour | Should Be 18
    $r.Week | Should Be 75
    $r.FiveHourReset | Should Be (Format-LimitEpoch 1893456000 $now)
    $r.WeekReset | Should Be (Format-LimitEpoch 1893888000 $now)
  }
  It 'kết quả chỉ giữ %, giờ reset, không giữ dữ liệu tài khoản' {
    $r = ConvertFrom-CodexLimitReply @(New-CodexReply) $now
    ($r.Keys | Sort-Object) -join ',' | Should Be 'FiveHour,FiveHourReset,Week,WeekReset'
    ($r | ConvertTo-Json) -match 'example\.test|fakeplan' | Should Be $false
  }
  It 'số lẻ làm tròn; 5h ở secondary vẫn đúng cửa sổ theo windowDurationMins' {
    (ConvertFrom-CodexLimitReply @(New-CodexReply 89.6 10) $now).FiveHour | Should Be 90
    $swapped = ConvertFrom-CodexLimitReply @(New-CodexReply 40 7 10080 300) $now
    $swapped.FiveHour | Should Be 7
    $swapped.Week | Should Be 40
  }
  It 'thiếu resetsAt: vẫn có số, giờ reset rỗng' {
    $line = '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":"sai"}}}}'
    $r = ConvertFrom-CodexLimitReply @($line) $now
    $r.FiveHour | Should Be 1
    $null -eq $r.FiveHourReset | Should Be $true
    $null -eq $r.WeekReset | Should Be $true
  }
  $bad = @{
    'thiếu primary' = '{"id":2,"result":{"rateLimits":{"secondary":{"usedPercent":2,"windowDurationMins":10080}}}}'
    'thiếu secondary' = '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":2,"windowDurationMins":300}}}}'
    'usedPercent là chuỗi' = (New-CodexReply '18' 75)
    'usedPercent là bool' = '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":true,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080}}}}'
    'usedPercent null' = '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080}}}}'
    'usedPercent quá 100' = (New-CodexReply 101 75)
    'usedPercent âm' = (New-CodexReply -1 75)
    'cửa sổ lạ, không đoán' = (New-CodexReply 10 20 60 1440)
    'JSON hỏng' = '{"id":2,"result":{"rateLimits"'
    'phản hồi error' = '{"id":2,"error":{"code":-32600,"message":"not logged in"}}'
    'result là chuỗi' = '{"id":2,"result":"x"}'
    'rateLimits null' = '{"id":2,"result":{"rateLimits":null}}'
    'không có id=2' = '{"id":1,"result":{}}'
    'request từ server trùng id' = '{"id":2,"method":"x","result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080}}}}'
  }
  foreach ($k in $bad.Keys) {
    $line = $bad[$k]
    It "$k -> null" { $null -eq (ConvertFrom-CodexLimitReply @($line) $now) | Should Be $true }
  }
  It 'không có dòng nào -> null' { $null -eq (ConvertFrom-CodexLimitReply @() $now) | Should Be $true }
}

Describe 'Get-CodexLimitStep (chỉ đúng 3 thông điệp)' {
  It 'sau initialize mới gửi initialized + rateLimits/read, không có thread/turn' {
    $s = Get-CodexLimitStep '{"id":1,"result":{}}'
    $s.Done | Should Be $false
    @($s.Write).Count | Should Be 2
    (@(Get-CodexLimitHello) + @($s.Write)) -join "`n" | Should Not Match 'thread/|turn/'
    $s.Write[1] | Should Match 'account/rateLimits/read'
  }
  It 'id=2 hoặc initialize lỗi thì xong; thông báo/dòng rác thì đọc tiếp' {
    (Get-CodexLimitStep '{"id":2,"result":{}}').Done | Should Be $true
    (Get-CodexLimitStep '{"id":1,"error":{}}').Done | Should Be $true
    (Get-CodexLimitStep '{"method":"account/updated"}').Done | Should Be $false
    (Get-CodexLimitStep '{"id":2,"method":"server/request"}').Done | Should Be $false
    (Get-CodexLimitStep 'rác').Done | Should Be $false
  }
}

Describe 'Format-LimitEpoch' {
  $at = [DateTimeOffset]::FromUnixTimeSeconds(1893456000).ToLocalTime().DateTime
  It 'cùng ngày chỉ giờ, khác ngày thêm ngày, theo giờ địa phương' {
    Format-LimitEpoch 1893456000 $at | Should Be $at.ToString('HH:mm')
    Format-LimitEpoch 1893456000 $at.AddDays(-2) | Should Be $at.ToString('dd/MM HH:mm')
  }
  It 'sai kiểu/ngoài khoảng -> null' {
    foreach ($v in @('1893456000', 0, -5, [long]::MaxValue, $null)) { $null -eq (Format-LimitEpoch $v $at) | Should Be $true }
  }
}

Describe 'ConvertFrom-ClaudeUsageText' {
  It 'văn bản mẫu: lấy đúng 2 dòng, bỏ múi giờ, bỏ dòng gợi ý và Sonnet' {
    $r = ConvertFrom-ClaudeUsageText $FakeUsage
    $r.FiveHour | Should Be 13
    $r.Week | Should Be 29
    $r.FiveHourReset | Should Be 'Nov 2, 1:30am'
    $r.WeekReset | Should Be 'Nov 7, 11am'
    ($r | ConvertTo-Json) -match 'example\.test' | Should Be $false
  }
  It 'dấu · hỏng encoding vẫn tách được' {
    $r = ConvertFrom-ClaudeUsageText ($FakeUsage.Replace('·', '┬╖'))
    $r.FiveHour | Should Be 13
    $r.FiveHourReset | Should Be 'Nov 2, 1:30am'
  }
  It 'không có reset: vẫn có số, giờ reset rỗng' {
    $r = ConvertFrom-ClaudeUsageText "Current session: 0% used`nCurrent week (all models): 29% used"
    $r.FiveHour | Should Be 0
    $null -eq $r.FiveHourReset | Should Be $true
  }
  It 'chuỗi lạ sau resets không vào bảng' {
    $r = ConvertFrom-ClaudeUsageText "Current session: 1% used · resets fake1@example.test`nCurrent week (all models): 2% used · resets soon"
    $null -eq $r.FiveHourReset | Should Be $true
    $null -eq $r.WeekReset | Should Be $true
  }
  $bad = @{
    'thiếu dòng tuần' = 'Current session: 13% used · resets Nov 2, 1:30am'
    'chỉ có tuần Sonnet' = "Current session: 13% used`nCurrent week (Sonnet only): 29% used"
    'thiếu dòng phiên' = 'Current week (all models): 29% used'
    'format lạ: % còn lại' = "Current session: 13% left`nCurrent week (all models): 29% left"
    'format lạ: không có %' = "Current session: 13 used`nCurrent week (all models): 29 used"
    'nhãn giữa câu' = "Tip: Current session: 13% used`nTip: Current week (all models): 29% used"
    'trên 100' = "Current session: 130% used`nCurrent week (all models): 29% used"
    'nhãn lặp, không đoán' = "Current session: 13% used`nCurrent session: 90% used`nCurrent week (all models): 29% used"
    'rỗng' = ''
  }
  foreach ($k in $bad.Keys) {
    $text = $bad[$k]
    It "$k -> null" { $null -eq (ConvertFrom-ClaudeUsageText $text) | Should Be $true }
  }
}

Describe 'ConvertFrom-ClaudeUsageReply' {
  It 'JSON đủ -> số' { (ConvertFrom-ClaudeUsageReply @(New-ClaudeReply)).Week | Should Be 29 }
  It 'JSON hỏng, is_error, có lượt model, thiếu result -> null' {
    $null -eq (ConvertFrom-ClaudeUsageReply @('{hỏng')) | Should Be $true
    $null -eq (ConvertFrom-ClaudeUsageReply @(New-ClaudeReply $FakeUsage 0 $true)) | Should Be $true
    $null -eq (ConvertFrom-ClaudeUsageReply @(New-ClaudeReply $FakeUsage 1)) | Should Be $true
    $null -eq (ConvertFrom-ClaudeUsageReply @('{"type":"result"}')) | Should Be $true
    $null -eq (ConvertFrom-ClaudeUsageReply @()) | Should Be $true
  }
}

Describe 'Get-LimitCliInvocation' {
  It 'Windows: shim .ps1/.cmd chạy qua pwsh, không profile, thoát nháy đơn' {
    foreach ($ext in 'ps1', 'cmd', 'bat') {
      $i = Get-LimitCliInvocation "C:\it's\codex.$ext" @('app-server') 'windows' 'C:\pwsh.exe'
      $i.File | Should Be 'C:\pwsh.exe'
      $i.ArgList -contains '-NoProfile' | Should Be $true
      $i.ArgList[-1] | Should Match ([regex]::Escape("& 'C:\it''s\codex.$ext' 'app-server'"))
    }
  }
  It 'Windows .exe và Unix gọi thẳng' {
    $exe = Get-LimitCliInvocation 'C:\x\claude.exe' @('-p', '/usage') 'windows' 'C:\pwsh.exe'
    $exe.File | Should Be 'C:\x\claude.exe'
    $exe.ArgList -join ' ' | Should Be '-p /usage'
    foreach ($os in 'linux', 'macos') {
      $u = Get-LimitCliInvocation '/usr/bin/codex.ps1' @('app-server') $os '/pwsh'
      $u.File | Should Be '/usr/bin/codex.ps1'
      $u.ArgList -join ' ' | Should Be 'app-server'
    }
  }
}

Describe 'Invoke-LimitProcess (tiến trình giả, không gọi CLI thật)' {
  $pwshPath = (Get-Process -Id $PID).Path
  function Invoke-FakeScript([string]$body, [string[]]$send = @(), [scriptblock]$OnLine = $null, [int]$TimeoutMs = 12000) {
    $file = Join-Path $TestDrive "fake-$([guid]::NewGuid().ToString('N')).ps1"
    [IO.File]::WriteAllText($file, $body, [Text.UTF8Encoding]::new($true))
    Invoke-LimitProcess @{ File = $pwshPath; ArgList = @('-NoLogo', '-NoProfile', '-File', $file) } $send $OnLine (Join-Path $TestDrive 'cwd') $TimeoutMs
  }

  It 'đọc stdout bằng UTF-8, đóng stdin, trả mã thoát, chạy trong Cwd' {
    $body = '$null = [Console]::In.ReadToEnd(); $b = [Text.UTF8Encoding]::new($false).GetBytes("a " + [char]0xB7 + " b`n" + (Get-Location).Path + "`n"); $o = [Console]::OpenStandardOutput(); $o.Write($b, 0, $b.Length); $o.Flush(); exit 3'
    $r = Invoke-FakeScript $body
    $r.TimedOut | Should Be $false
    $r.Killed | Should Be $false
    $r.ExitCode | Should Be 3
    $r.Lines[0] | Should Be ("a " + [char]0xB7 + " b")
    (Split-Path $r.Lines[1] -Leaf) | Should Be 'cwd'
  }

  It 'không kế thừa biến phiên agent/pane' {
    $saved = $env:CLAUDECODE, $env:HC_TERMINAL_ID
    try {
      $env:CLAUDECODE = '1'; $env:HC_TERMINAL_ID = 't1'
      $r = Invoke-FakeScript '"[$env:CLAUDECODE][$env:HC_TERMINAL_ID]"'
      $r.Lines[0] | Should Be '[][]'
    }
    finally { $env:CLAUDECODE = $saved[0]; $env:HC_TERMINAL_ID = $saved[1] }
  }

  It 'hết giờ: báo TimedOut, kill cả cây, không treo' {
    $parentFile = Join-Path $TestDrive 'parent.pid'
    $childFile = Join-Path $TestDrive 'child.pid'
    $child = "`$PID | Set-Content '$childFile'; Start-Sleep -Seconds 120"
    $body = "`$PID | Set-Content '$parentFile'; & '$pwshPath' -NoLogo -NoProfile -Command `"$child`""
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-FakeScript $body -TimeoutMs 8000
    $clock.Stop()
    $r.TimedOut | Should Be $true
    $r.Killed | Should Be $true
    $clock.Elapsed.TotalSeconds -lt 15 | Should Be $true
    (Test-Path $parentFile) -and (Test-Path $childFile) | Should Be $true
    $null -eq (Get-Process -Id ([int](Get-Content $parentFile)) -ErrorAction SilentlyContinue) | Should Be $true
    $null -eq (Get-Process -Id ([int](Get-Content $childFile)) -ErrorAction SilentlyContinue) | Should Be $true
  }

  It 'file không tồn tại: không ném lỗi, Started false' {
    $r = Invoke-LimitProcess @{ File = (Join-Path $TestDrive 'khong-co'); ArgList = @() } @() $null (Join-Path $TestDrive 'cwd')
    $r.Started | Should Be $false
    @($r.Lines).Count | Should Be 0
  }

  It 'e2e Get-CodexLiveLimit qua tiến trình giả và shim: chỉ gửi đúng 3 thông điệp, kill khi xong' {
    $log = Join-Path $TestDrive 'methods.log'
    $pidFile = Join-Path $TestDrive 'codex.pid'
    $replyLine = (New-CodexReply 18 75).Replace("'", "''")
    $fake = Join-Path $TestDrive 'codex.ps1'
    $body = @"
#!/usr/bin/env pwsh
`$PID | Set-Content '$pidFile'
'banner'
if (`$args -join ' ' -ne 'app-server') { exit 9 }
while (`$null -ne (`$l = [Console]::In.ReadLine())) {
  `$m = `$l | ConvertFrom-Json
  `$m.method | Add-Content '$log'
  if (`$m.id -eq 1) { '{"id":1,"result":{}}'; '{"method":"account/updated"}' }
  if (`$m.id -eq 2) { '$replyLine'; Start-Sleep -Seconds 120 }
}
"@
    # .gitattributes giữ *.ps1 ở CRLF cả trên Linux; CR ở dòng shebang làm env không tìm thấy pwsh.
    $body = $body -replace "`r`n", "`n"
    [IO.File]::WriteAllText($fake, $body, [Text.UTF8Encoding]::new($false))
    if ((Get-CrewOS) -ne 'windows') { & chmod +x $fake }
    $script:FakeCli = $fake
    $script:FakeCwd = Join-Path $TestDrive 'cwd'
    $ops = @{
      Find = { param($n) $script:FakeCli }
      Run = { param($i, $s, $o) Invoke-LimitProcess $i $s $o $script:FakeCwd }
    }
    $r = Get-CodexLiveLimit $ops
    $r.FiveHour | Should Be 18
    $r.Week | Should Be 75
    (Get-Content $log) -join ',' | Should Be 'initialize,initialized,account/rateLimits/read'
    Start-Sleep -Milliseconds 300
    $null -eq (Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue) | Should Be $true
  }
}

Describe 'Get-*LiveLimit không ném lỗi' {
  It 'thiếu CLI -> null, không chạy tiến trình' {
    $script:RunCalls = 0
    $ops = @{ Find = { param($n) $null }; Run = { param($i, $s, $o) $script:RunCalls++ } }
    $null -eq (Get-CodexLiveLimit $ops) | Should Be $true
    $null -eq (Get-ClaudeLiveLimit $ops) | Should Be $true
    $script:RunCalls | Should Be 0
  }
  It 'ops ném lỗi / hết giờ / mã thoát khác 0 -> null' {
    $boom = @{ Find = { param($n) throw 'boom' }; Run = { } }
    $null -eq (Get-CodexLiveLimit $boom) | Should Be $true
    $null -eq (Get-ClaudeLiveLimit $boom) | Should Be $true
    $late = @{ Find = { param($n) '/fake/x' }; Run = { param($i, $s, $o) @{ TimedOut = $true; ExitCode = $null; Lines = @() } } }
    $null -eq (Get-CodexLiveLimit $late) | Should Be $true
    $null -eq (Get-ClaudeLiveLimit $late) | Should Be $true
    $script:ClaudeLine = New-ClaudeReply
    $fail = @{ Find = { param($n) '/fake/x' }; Run = { param($i, $s, $o) @{ TimedOut = $false; ExitCode = 1; Lines = @($script:ClaudeLine) } } }
    $null -eq (Get-ClaudeLiveLimit $fail) | Should Be $true
  }
  It 'claude chỉ dùng đúng lệnh /usage, không có prompt khác' {
    $script:Seen = $null
    $script:ClaudeLine = New-ClaudeReply
    $ops = @{ Find = { param($n) '/fake/claude' }; Run = { param($i, $s, $o) $script:Seen = $i; @{ TimedOut = $false; ExitCode = 0; Lines = @($script:ClaudeLine) } } }
    (Get-ClaudeLiveLimit $ops).FiveHour | Should Be 13
    $script:Seen.ArgList -join ' ' | Should Be '-p /usage --output-format json --no-session-persistence'
  }
}

Describe 'Invoke-Limits' {
  # Stub đúng phạm vi: không chạm hc, git, HOME thật. Get-ForeignTermError/Test-TermOwner là hàm thật.
  function Get-Root($p) { $script:FakeRoot }
  function Get-Config($r) { $script:FakeCfg }
  function Get-CrewName($r, $c) { 'c' }
  function Get-Tasks($r) { @() }
  function Get-LiveTerminals { $script:FakeTerms }
  function Say($m) { Write-Host "crew: $m" }
  function Die($m) { throw $m }
  function hc { $script:HcCalls.Add(($args -join ' ')); $script:FakeScreen }

  function New-FakeOps($answers) {
    $script:AskCalls = [Collections.Generic.List[string]]::new()
    $script:Answers = $answers
    return @{
      Find = { param($n) if ($script:Answers[$n] -eq 'thiếu') { $null } else { "/fake/$n" } }
      Run = {
        param($i, $s, $o)
        $n = Split-Path $i.File -Leaf
        $script:AskCalls.Add($n)
        if ($script:Answers[$n] -eq 'hết giờ') { return @{ TimedOut = $true; Killed = $true; ExitCode = $null; Lines = @() } }
        return @{ TimedOut = $false; ExitCode = 0; Lines = @($script:Answers[$n]) }
      }
    }
  }
  function Invoke-Table($answers, $cfg, [string[]]$liveNames, [string]$screen = '', [string[]]$foreign = @()) {
    $script:FakeRoot = "$TestDrive"
    $script:FakeCfg = $cfg
    $script:FakeScreen = $screen
    $script:HcCalls = [Collections.Generic.List[string]]::new()
    $script:FakeTerms = @($liveNames | ForEach-Object {
        $cwd = if ($foreign -contains $_) { Join-Path $TestDrive 'project-khac' } else { "$TestDrive" }
        [pscustomobject]@{ name = $_; state = 'live'; cwd = $cwd }
      })
    $Path = "$TestDrive"
    return (Invoke-Limits (New-FakeOps $answers) 6>&1 | Out-String)
  }
  function Get-TableLine([string]$out, [string]$name) { (($out -split '\r?\n') | Where-Object { $_ -match "^$([regex]::Escape($name))\s" }) | Select-Object -First 1 }
  $mixed = [pscustomobject]@{ planner = 'claude'; workers = @('codex', 'codex'); rev = 'claude' }
  $allLive = 'c-planner', 'c-w1', 'c-w2', 'c-rev'

  It 'cả hai trực tiếp: không đọc màn hình, không chú thích có thể cũ, có giờ reset' {
    $out = Invoke-Table @{ codex = (New-CodexReply 18 75); claude = (New-ClaudeReply) } $mixed $allLive '5h 99% · week 99%'
    $script:HcCalls.Count | Should Be 0
    (Get-TableLine $out 'c-planner') | Should Match '13%\s+29%\s+ok\s+Nov 2, 1:30am\s+-'
    (Get-TableLine $out 'c-w1') | Should Match '18%\s+75%\s+ok\s'
    (Get-TableLine $out 'c-w1') | Should Match ([regex]::Escape((Format-LimitEpoch 1893456000)))
    (Get-TableLine $out 'c-planner') | Should Not Match 'màn hình'
    (Get-TableLine $out 'c-w1') | Should Not Match 'màn hình'
    $out | Should Match 'reset 5h'
    $out | Should Not Match 'Không hỏi được số trực tiếp'
    $out | Should Not Match 'example\.test|fakeplan'
  }

  It 'dòng cuối nói đúng nguồn và không tốn token' {
    $out = Invoke-Table @{ codex = (New-CodexReply); claude = (New-ClaudeReply) } $mixed $allLive
    $out | Should Match 'hỏi trực tiếp từ Codex/Claude, không tốn token'
    $out | Should Match 'lấy từ màn hình, có thể cũ'
  }

  It 'mỗi agent chỉ hỏi 1 lần dù nhiều pane' {
    $null = Invoke-Table @{ codex = (New-CodexReply); claude = (New-ClaudeReply) } $mixed $allLive
    ($script:AskCalls | Sort-Object) -join ',' | Should Be 'claude,codex'
  }

  It 'một agent lỗi: agent đó lấy màn hình + chú thích, agent kia vẫn trực tiếp' {
    $out = Invoke-Table @{ codex = 'rác không phải JSON'; claude = (New-ClaudeReply) } $mixed $allLive 'Context 58% left · 5h 60% left · weekly 71% left'
    (Get-TableLine $out 'c-w1') | Should Match '40%\s+29%\s+ok\s+-\s+-\s*\(màn hình, có thể cũ\)'
    (Get-TableLine $out 'c-planner') | Should Match '13%\s+29%'
    (Get-TableLine $out 'c-planner') | Should Not Match 'màn hình'
    ($script:HcCalls | Sort-Object) -join ',' | Should Be 'read c-w1 --lines 6,read c-w2 --lines 6'
    $out | Should Match 'Không hỏi được số trực tiếp từ: codex'
  }

  It 'hết giờ: về màn hình, có kill (Run báo), chú thích có thể cũ' {
    $out = Invoke-Table @{ codex = 'hết giờ'; claude = 'hết giờ' } $mixed @('c-w1') '5h 13% · week 24%'
    (Get-TableLine $out 'c-w1') | Should Match '13%\s+24%.*\(màn hình, có thể cũ\)'
    @($script:AskCalls).Count | Should Be 2
  }

  It 'thiếu CLI: về màn hình; màn hình cũng không có số thì nói rõ, không ghi có thể cũ' {
    $out = Invoke-Table @{ codex = 'thiếu'; claude = 'thiếu' } $mixed @('c-w1') '? for shortcuts'
    @($script:AskCalls).Count | Should Be 0
    (Get-TableLine $out 'c-w1') | Should Match '\?\s+\?\s+không rõ.*không hỏi được, màn hình không có số'
    (Get-TableLine $out 'c-w1') | Should Not Match 'có thể cũ'
  }

  It 'màn hình mượn số pane cùng agent: giữ chú thích nguồn và tên pane' {
    $script:Screens = @{ 'c-w1' = 'bị cắt …'; 'c-w2' = '5h 40% left · weekly 90% left' }
    function hc { $script:HcCalls.Add(($args -join ' ')); $script:Screens[$args[1]] }
    $out = Invoke-Table @{ codex = 'thiếu'; claude = 'thiếu' } ([pscustomobject]@{ planner = 'none'; workers = @('codex', 'codex'); rev = 'none' }) @('c-w1', 'c-w2')
    (Get-TableLine $out 'c-w1') | Should Match '60%.*\(màn hình, có thể cũ\) \(theo c-w2\)'
  }

  It 'số trực tiếp 5h ≥90% -> dừng; tuần ≥90% -> ⚠ và cảnh báo' {
    $out = Invoke-Table @{ codex = (New-CodexReply 90 10); claude = (New-ClaudeReply "Current session: 5% used`nCurrent week (all models): 90% used") } $mixed $allLive
    (Get-TableLine $out 'c-w1') | Should Match '90%\s+10%\s+dừng\s'
    (Get-TableLine $out 'c-planner') | Should Match '5%\s+90%\s+ok ⚠'
    $out | Should Match '⚠ tuần ≥90%: c-planner \(claude\): tuần 90%'
    $out | Should Not Match '⚠ tuần ≥90%: c-w1'
  }

  It 'agent không có trong config thì không hỏi; none không hỏi' {
    $cfg = [pscustomobject]@{ planner = 'claude'; workers = @('claude'); rev = 'none' }
    $out = Invoke-Table @{ codex = (New-CodexReply); claude = (New-ClaudeReply) } $cfg @('c-planner', 'c-w1')
    $script:AskCalls -join ',' | Should Be 'claude'
    $out | Should Not Match 'c-rev'
  }

  It 'pane tắt: vẫn hỏi, vẫn hiện tắt, không hiện số' {
    $out = Invoke-Table @{ codex = (New-CodexReply); claude = (New-ClaudeReply) } $mixed @('c-planner')
    (Get-TableLine $out 'c-w1') | Should Match 'codex\s+-\s+-\s+tắt\s+-\s+-'
    ($script:AskCalls | Sort-Object) -join ',' | Should Be 'claude,codex'
    (Get-TableLine $out 'c-planner') | Should Match '13%'
  }

  It 'pane của project khác: hiện tắt + cảnh báo, không đọc màn hình, kể cả khi không hỏi được' {
    $out = Invoke-Table @{ codex = 'thiếu'; claude = (New-ClaudeReply) } $mixed @('c-planner', 'c-w1') '5h 99% left · weekly 99% left' @('c-w1')
    (Get-TableLine $out 'c-w1') | Should Match 'codex\s+-\s+-\s+tắt'
    $out | Should Match 'CẢNH BÁO: terminal c-w1 đang chạy ở project khác'
    $script:HcCalls.Count | Should Be 0
  }

  It '0 Send/Keys: hc chỉ được gọi read, kể cả khi quay về màn hình' {
    $null = Invoke-Table @{ codex = 'thiếu'; claude = 'thiếu' } $mixed $allLive '5h 13% · week 24%'
    $script:HcCalls.Count | Should Be 4
    @($script:HcCalls | Where-Object { $_ -notmatch '^read ' }).Count | Should Be 0
  }
}
