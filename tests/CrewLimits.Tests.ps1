# Test Get-LimitInfo: trích hàm bằng AST từ crew.ps1, không gọi hc.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-LimitTiers', 'Get-LimitWeekWarn', 'Get-LimitLevel', 'Get-LimitInfo', 'Resolve-LimitRows' }, $false)) {
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
