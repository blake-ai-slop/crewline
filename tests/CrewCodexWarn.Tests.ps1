function hc { throw 'hc thật bị cấm' }
function Say { }
function Die($m) { throw $m }
. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($name in 'Get-InputBox','Get-ScreenDialog','Get-TermStatus','Get-SendPlan','Test-SentInput','Send-CodexQueue','Invoke-SendFlow','Send-CrewMessage') {
  . ([scriptblock]::Create((Get-CrewFunction $name).Extent.Text))
}

foreach ($name in 'Invoke-Review','Update-Tasks','Get-RestartGuard','Get-PendingReview','Test-TaskFinished') {
  . ([scriptblock]::Create((Get-CrewFunction $name).Extent.Text))
}

Describe 'review nối luồng gửi thật với dấu đang review' {
  BeforeEach {
    $script:NameList = @('a'); $script:Sent = $false; $script:DryRun = $false
    $script:ReviewStore = '[{"name":"a","branch":"crew/a","doneTracking":true}]'
    $script:ReviewWireSends = 0; $script:ReviewWireKeys = 0
    $script:WireCode = 0
    function Get-MainRoot { $TestDrive }
    function Get-Config { @{rev='codex';review='lean'} }
    function Get-CrewName { 'demo' }
    function Invoke-GitOrDie { @{Text='main';Code=0} }
    function Invoke-GitQuiet { @{Code=0} }
    function Get-Tasks { ,@($script:ReviewStore | ConvertFrom-Json) }
    function Save-Tasks($root,$items) { $script:ReviewStore = ConvertTo-Json -InputObject @($items) }
    function Use-CrewStateLock($root,$action) { & $action }
    function Get-ReviewLine { @{Msg='review a';Error=''} }
    function Get-TermInfo { [pscustomobject]@{state='live';status=@{app='codex';state='idle'};turn=1} }
    function Get-RevGuard { '' }
    function Get-ForeignTermError { '' }
    function Die($m,$next) { throw "$m`n→ Làm tiếp:`n$($next -join "`n")" }
    function New-HcOps {
      @{
        Get = { Get-TermInfo }
        Read = {
          if ($script:ReviewWireSends) { 'mất ô nhập sau gửi' }
          else { "› Ask Codex to do anything`n`n  GPT-6.1-Sol medium · Context 62% left`n⚠ 1 warning · f2 to view" }
        }
        Send = { $script:ReviewWireSends++; @{Code=$script:WireCode;Text='{"started":false}'} }
        Keys = { $script:ReviewWireKeys++ }
        Sleep = { }
      }
    }
  }
  It 'nobox sau gửi: lưu cờ, exit lỗi có lệnh xử lý, chặn restart và giữ repair/up đang review' {
    $err = try { Invoke-Review; '' } catch { "$_" }
    $err | Should Match 'chưa chắc Rev đã nhận review a'
    $err | Should Match '→ Làm tiếp:\s+hc read demo-rev --lines 20'
    $err | Should Match 'bấm Enter tay rồi: crew review a -Sent'
    $tasks = Get-Tasks
    $tasks[0].reviewSentAt | Should Not BeNullOrEmpty
    $tasks[0].reviewUnsure | Should Be $true
    Get-RestartGuard @('rev') $tasks '' | Should Match 'rev đang review/merge task a'
    (Get-PendingReview $TestDrive $tasks).Count | Should Be 1
    Test-TaskFinished $tasks[0] @{Clean=$true} | Should Be $true
    $script:ReviewWireSends | Should Be 1
    $script:ReviewWireKeys | Should Be 0
    $script:Sent = $true
    Invoke-Review
    (Get-Tasks)[0].reviewUnsure | Should BeNullOrEmpty
    $script:ReviewWireSends | Should Be 1
  }
  It 'hc send chắc chắn lỗi: không có dấu review, không có Enter' {
    $script:WireCode = 1
    { Invoke-Review } | Should Throw 'hc send tới demo-rev thất bại'
    (Get-Tasks)[0].reviewSentAt | Should BeNullOrEmpty
    (Get-Tasks)[0].reviewUnsure | Should BeNullOrEmpty
    $script:ReviewWireKeys | Should Be 0
  }
}

Describe 'Codex v0.166 với cảnh báo quanh ô nhập (fixture dựng)' {
  BeforeEach {
    $script:WarningKeys = 0; $script:WarningSends = 0
    $script:WarningScreen = ''
    $script:WarningOps = @{
      Get = { [pscustomobject]@{ state='live'; status=@{app='codex';state=$(if ($script:WarningKeys) {'working'} else {'idle'})}; turn=1 } }
      Read = { $script:WarningScreen }
      Send = { $script:WarningSends++; @{Code=0;Text='{"started":false}'} }
      Keys = { $script:WarningKeys++ }
      Sleep = { }
    }
  }
  It 'nhiều dòng cảnh báo trên/dưới ô, trước/sau chân: khớp toàn tin và Enter' {
    foreach ($warnings in @(
      "⚠ 5h limit: 38% left · resets at 4:00 PM · /status`n⚠ 1 warning · f2 to view",
      '  ⚠ weekly limit: 14% left · resets at 2:27 PM on 4 Nov · /status'
    )) {
      foreach ($position in 'above','before-footer','below-footer') {
        $script:WarningKeys = 0
        $body = "› đúng tin`n  vừa gửi`n`n"
        $footer = "  GPT-6.1-Sol medium · ~\Crewline · Context 62% left`n  ? for shortcuts"
        $script:WarningScreen = switch ($position) {
          above { "$warnings`n`n$body$footer" }
          before-footer { "$body$warnings`n$footer" }
          below-footer { "$body$footer`n$warnings" }
        }
        $box = Get-InputBox $script:WarningScreen
        $box.Kind | Should Be 'codex'
        Test-SentInput $box.Lines 'đúng tin vừa gửi' | Should Be $true
        (Invoke-SendFlow demo-rev 'đúng tin vừa gửi' $script:WarningOps).Ok | Should Be $true
        $script:WarningKeys | Should Be 1
      }
    }
  }
  It 'cảnh báo trong bản nháp không bị bỏ, mất đầu tin không Enter' {
    $script:WarningScreen = "› tin`n  ⚠ 1 warning · f2 to view`n`n  GPT-6.1-Sol medium · Context 62% left"
    (Get-InputBox $script:WarningScreen).Text | Should Match '⚠ 1 warning'
    (Invoke-SendFlow demo-rev 'tin' $script:WarningOps).Ok | Should Be $false
    $script:WarningKeys | Should Be 0
  }
  It 'hộp lạ, thiếu chân, cảnh báo lạ không được Enter' {
    foreach ($screen in @(
      "› 1. Yes, proceed`n`n⚠ 1 warning · f2 to view`n  GPT-6.1-Sol medium · Context 62% left",
      "› tin`n`n⚠ 1 warning · f2 to view",
      "› tin`n`n  GPT-6.1-Sol medium · Context 62% left`n⚠ Allow command (y/n)",
      "› tin`n`n  GPT-6.1-Sol medium · Context 62% left`n⚠ 5h limit: 38% left · Allow command (y/n)"
    )) {
      $script:WarningScreen = $screen
      (Invoke-SendFlow demo-rev tin $script:WarningOps).Ok | Should Be $false
      $script:WarningKeys | Should Be 0
    }
  }
  It 'chỉ lỗi sau hc send thành công mới đánh dấu Unsure' {
    $script:WarningScreen = 'không thấy ô nhập'
    (Invoke-SendFlow demo-rev tin $script:WarningOps).Unsure | Should Be $true
    $script:WarningOps.Send = { @{Code=1;Text='không gõ được'} }
    (Invoke-SendFlow demo-rev tin $script:WarningOps).Unsure | Should Be $false
    $script:WarningOps.Get = { $null }
    (Invoke-SendFlow demo-rev tin $script:WarningOps).Unsure | Should Be $false
  }
  It 'preflight send nhận ô trống có cảnh báo rồi gửi như thường' {
    $script:WarningOps.Read = {
      "› $(if ($script:WarningSends) {'tin'} else {'Ask Codex to do anything'})`n`n⚠ 5h limit: 38% left · /status`n  GPT-6.1-Sol medium · Context 62% left`n⚠ 1 warning · f2 to view"
    }
    (Send-CrewMessage demo-rev tin $false '' $script:WarningOps -PassResult).Ok | Should Be $true
    $script:WarningSends | Should Be 1
    $script:WarningKeys | Should Be 1
  }
}
