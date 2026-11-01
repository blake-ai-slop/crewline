# Test crew send/review/task -Review: trích hàm thuần bằng AST từ crew.ps1, không gọi hc thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$wanted = 'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-ScreenDialog', 'Get-ReviewLevel', 'Format-ReviewMessage', 'New-TaskRecord', 'Send-CrewMessage', 'Test-SessionReady'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $wanted }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

function New-Info([string]$state = 'live', [string]$app = 'claude', [string]$status = 'idle', [int]$turn = 3) {
  $st = if ($app) { [pscustomobject]@{ app = $app; state = $status } } else { $null }
  [pscustomobject]@{ name = 't'; state = $state; status = $st; turn = $turn }
}

Describe 'Get-SendPlan' {
  It 'không live -> dead' {
    Get-SendPlan $null $null | Should Be 'dead'
    Get-SendPlan (New-Info -state 'exited') $null | Should Be 'dead'
  }
  It 'blocked -> blocked (trước và sau gửi)' {
    Get-SendPlan (New-Info -status 'blocked') $null | Should Be 'blocked'
    Get-SendPlan (New-Info -status 'blocked') ([pscustomobject]@{ started = $false }) 3 | Should Be 'blocked'
  }
  It 'live, chưa gửi -> send' {
    Get-SendPlan (New-Info) $null | Should Be 'send'
  }
  It 'started true -> ok' {
    Get-SendPlan (New-Info) ([pscustomobject]@{ started = $true }) 3 | Should Be 'ok'
  }
  It 'started false + idle -> press-enter' {
    Get-SendPlan (New-Info) ([pscustomobject]@{ started = $false }) 3 | Should Be 'press-enter'
  }
  It 'started false + working -> ok' {
    Get-SendPlan (New-Info -status 'working') ([pscustomobject]@{ started = $false }) 3 | Should Be 'ok'
  }
  It 'started false + idle nhưng turn đã tăng -> ok' {
    Get-SendPlan (New-Info -turn 4) ([pscustomobject]@{ started = $false }) 3 | Should Be 'ok'
  }
  It 'shell (không có status.app) gửi xong -> ok' {
    Get-SendPlan (New-Info -app '') ([pscustomobject]@{ started = $false }) 3 | Should Be 'ok'
  }
  It 'status dạng chuỗi (như hc ls) vẫn đọc được' {
    $i = [pscustomobject]@{ state = 'live'; status = 'blocked' }
    Get-SendPlan $i $null | Should Be 'blocked'
  }
}

# hc giả: mỗi lần Get trả phần tử kế trong $gets (hết thì giữ phần tử cuối); ghi lại thứ tự lệnh.
function New-FakeOps($gets, [string]$sendJson = '{"started":false}', [int]$sendCode = 0) {
  $st = @{ Gets = @($gets); I = 0; Keys = 0; Raw = $null; Log = [Collections.Generic.List[string]]::new() }
  $ops = @{
    State = $st
    Get   = { param($t) $st.Log.Add('get'); $k = [math]::Min($st.I, $st.Gets.Count - 1); $st.I++; $st.Gets[$k] }.GetNewClosure()
    Send  = { param($t, $x, $sh) $st.Log.Add('send'); $st.Raw = [bool]$sh; @{ Code = $sendCode; Text = $sendJson } }.GetNewClosure()
    Keys  = { param($t) $st.Log.Add('enter'); $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) $st.Log.Add("sleep$ms") }.GetNewClosure()
  }
  $ops
}

Describe 'Invoke-SendFlow (hc giả)' {
  It 'idle -> blocked ngay sau send: dừng, không Enter' {
    $ops = New-FakeOps @((New-Info), (New-Info -status 'blocked'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'chờ duyệt'
    $ops.State.Keys | Should Be 0
  }
  It 'idle -> blocked trong lúc delay trước Enter: dừng, không Enter' {
    $ops = New-FakeOps @((New-Info), (New-Info), (New-Info -status 'blocked'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'chờ duyệt'
    $ops.State.Keys | Should Be 0
    ($ops.State.Log -join ',') | Should Be 'get,send,get,sleep700,get'
  }
  It 'blocked trước khi gửi: không send, không Enter' {
    $ops = New-FakeOps @((New-Info -status 'blocked'))
    (Invoke-SendFlow 't' 'tin' $ops).Ok | Should Be $false
    $ops.State.Log -contains 'send' | Should Be $false
    $ops.State.Keys | Should Be 0
  }
  It 'started:false + idle rồi working sau Enter -> ok, Enter 1 lần' {
    $ops = New-FakeOps @((New-Info), (New-Info), (New-Info), (New-Info -status 'working'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $true
    $r.Message | Should Be 'đã gửi -> t (working)'
    $ops.State.Keys | Should Be 1
  }
  It 'started:false nhưng working ngay sau send -> ok, không Enter' {
    $ops = New-FakeOps @((New-Info), (New-Info -status 'working'))
    (Invoke-SendFlow 't' 'tin' $ops).Ok | Should Be $true
    $ops.State.Keys | Should Be 0
  }
  It 'turn tăng trong lúc delay -> ok, không Enter' {
    $ops = New-FakeOps @((New-Info -turn 3), (New-Info -turn 3), (New-Info -turn 4))
    (Invoke-SendFlow 't' 'tin' $ops).Ok | Should Be $true
    $ops.State.Keys | Should Be 0
  }
  It 'dead trước khi gửi -> lỗi, không send' {
    $ops = New-FakeOps @($null)
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'không live'
    $ops.State.Log -contains 'send' | Should Be $false
  }
  It 'dead sau send -> lỗi, không Enter' {
    $ops = New-FakeOps @((New-Info), (New-Info -state 'exited'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'tắt'
    $ops.State.Keys | Should Be 0
  }
  It 'idle mãi -> Enter tối đa 2 lần rồi báo lỗi' {
    $ops = New-FakeOps @((New-Info))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $ops.State.Keys | Should Be 2
  }
  It 'tin thường tới agent -> gửi bọc (Raw false)' {
    $ops = New-FakeOps @((New-Info), (New-Info -status 'working'))
    (Invoke-SendFlow 't' 'Bạn là worker…' $ops).Ok | Should Be $true
    $ops.State.Raw | Should Be $false
  }
  It 'lệnh slash tới agent -> gửi trần (Raw true)' {
    foreach ($s in '/clear', '/new', '/model') {
      $ops = New-FakeOps @((New-Info), (New-Info -status 'working'))
      (Invoke-SendFlow 't' $s $ops).Ok | Should Be $true
      $ops.State.Raw | Should Be $true
    }
  }
  It 'tin kẹt ở ô nhập nhưng màn hình có hộp quyền ngay trước Enter -> 0 Enter, lỗi' {
    $ops = New-FakeOps @((New-Info))
    $ops.Read = { param($t) "Do you want to proceed?`n❯ 1. Yes`n  2. No" }
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'hộp thoại'
    $ops.State.Keys | Should Be 0
  }
  It 'tin kẹt ở ô nhập, màn hình thường -> vẫn Enter như cũ' {
    $ops = New-FakeOps @((New-Info), (New-Info), (New-Info), (New-Info -status 'working'))
    $ops.Read = { param($t) "● xong`n❯ tin" }
    (Invoke-SendFlow 't' 'tin' $ops).Ok | Should Be $true
    $ops.State.Keys | Should Be 1
  }
  It 'crew send -Raw -> gửi trần cả tin thường' {
    $ops = New-FakeOps @((New-Info), (New-Info -status 'working'))
    (Invoke-SendFlow 't' 'tin' $ops '' 6 $true).Ok | Should Be $true
    $ops.State.Raw | Should Be $true
  }
  It 'shell -> gửi trần' {
    $ops = New-FakeOps @((New-Info -app ''))
    (Invoke-SendFlow 't' 'Get-Location' $ops).Ok | Should Be $true
    $ops.State.Raw | Should Be $true
  }
  It 'agent working trước gửi -> Ok, Queued, báo tin nằm chờ, 0 Enter' {
    $ops = New-FakeOps @((New-Info -status 'working'), (New-Info -status 'working'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $true
    $r.Queued | Should Be $true
    $r.Message | Should Be 'đã gửi -> t nhưng agent đang bận: tin nằm chờ, agent đọc khi xong lượt (xem: crew hot)'
    $ops.State.Keys | Should Be 0
  }
  It 'agent working trước gửi, turn đã tăng sau gửi -> báo như cũ (đã sang lượt mới)' {
    $ops = New-FakeOps @((New-Info -status 'working' -turn 3), (New-Info -status 'working' -turn 4))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Message | Should Be 'đã gửi -> t (working)'
    $r.Queued | Should Be $null
  }
  It 'working trước gửi, xong lượt ngay sau gửi, Enter rồi working -> không báo chờ' {
    $ops = New-FakeOps @((New-Info -status 'working'), (New-Info), (New-Info), (New-Info -status 'working'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $true
    $r.Message | Should Be 'đã gửi -> t (working)'
    $r.Queued | Should Be $null
    $ops.State.Keys | Should Be 1
  }
  It 'working trước gửi, started:true nhưng đã idle -> báo cũ, không Queued' {
    $ops = New-FakeOps @((New-Info -status 'working'), (New-Info)) '{"started":true}'
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Message | Should Be 'đã gửi -> t (idle)'
    $r.Queued | Should Be $null
    $ops.State.Keys | Should Be 0
  }
  It 'idle -> working sau gửi -> báo cũ, không Queued' {
    $ops = New-FakeOps @((New-Info), (New-Info -status 'working'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Message | Should Be 'đã gửi -> t (working)'
    $r.Queued | Should Be $null
  }
  It 'shell -> báo cũ, không Queued' {
    $ops = New-FakeOps @((New-Info -app ''))
    $r = Invoke-SendFlow 't' 'ls' $ops
    $r.Message | Should Be 'đã gửi -> t (shell)'
    $r.Queued | Should Be $null
  }
  It 'blocked trước gửi -> vẫn lỗi, 0 Enter, không Queued' {
    $ops = New-FakeOps @((New-Info -status 'blocked'))
    $r = Invoke-SendFlow 't' 'tin' $ops
    $r.Ok | Should Be $false
    $r.Queued | Should Be $null
    $ops.State.Keys | Should Be 0
  }
  It 'chế độ phiên mới không dùng báo chờ' {
    $ops = New-FakeOps @((New-Info -status 'working'), (New-Info -status 'working'), (New-Info -status 'idle' -turn 4))
    $ops.Read = { param($t) "❯ /clear`n`n❯ " }
    $r = Invoke-SendFlow 't' '/clear' $ops 'claude' 3
    $r.Queued | Should Be $null
    $r.Message | Should Not Match 'tin nằm chờ'
  }
  It 'hc send lỗi -> báo lỗi, không Enter' {
    $ops = New-FakeOps @((New-Info)) 'busy' 1
    (Invoke-SendFlow 't' 'tin' $ops).Message | Should Match 'thất bại'
    $ops.State.Keys | Should Be 0
  }
}

Describe 'Soạn tin review' {
  $hot = 'Chế độ review: **Nhanh**. Quyền agent: Mở rộng.'
  It 'mức từ task' {
    Get-ReviewLevel ([pscustomobject]@{ name = 'a'; review = 'full' }) $hot 'lean' | Should Be 'Đủ'
  }
  It 'không có review trong task -> lấy HOT' {
    Get-ReviewLevel ([pscustomobject]@{ name = 'a' }) $hot 'full' | Should Be 'Nhanh'
  }
  It 'không có HOT -> lấy config' {
    Get-ReviewLevel ([pscustomobject]@{ name = 'a' }) '' 'full' | Should Be 'Đủ'
  }
  It '1 task' {
    $m = Format-ReviewMessage 'Gọn' @(@{ Name = 'crew-send'; Branch = 'crew/crew-send'; Commits = @('abc1234', 'def5678') })
    $m | Should Be 'Rev Gọn: merge crew/crew-send (abc1234,def5678). Đọc context/tasks/crew-send.md. Full test, crew clean crew-send, báo planner. Không push.'
  }
  It '2 task giữ thứ tự truyền vào' {
    $m = Format-ReviewMessage 'Đủ' @(
      @{ Name = 'b'; Branch = 'crew/b'; Commits = @('2222222') },
      @{ Name = 'a'; Branch = 'crew/a'; Commits = @('1111111') })
    $m | Should Be 'Rev Đủ: merge crew/b (2222222) rồi crew/a (1111111) (đúng thứ tự này). Đọc context/tasks/b.md, context/tasks/a.md của từng task. Full test, crew clean b, crew clean a, báo planner. Không push.'
  }
}

Describe 'New-TaskRecord (-Review)' {
  It 'có -Review -> ghi review' {
    $r = New-TaskRecord 'x' 'crew/x' 'C:\wt' 1 's-w1' 'claude' 'full'
    $r.review | Should Be 'full'
    $r.name | Should Be 'x'
    $r.worker | Should Be 1
  }
  It 'không -Review -> không có khóa review' {
    $r = New-TaskRecord 'x' 'crew/x' 'C:\wt' 1 's-w1' 'claude' ''
    ($r.PSObject.Properties.Name -contains 'review') | Should Be $false
  }
}

Describe 'Send-CrewMessage (review tới Rev đang bận)' {
  It 'Rev working -> in báo tin nằm chờ, không Die, 0 Enter' {
    $script:said = @(); $script:died = $null
    function Say($m) { $script:said += $m }
    function Die($m) { $script:died = $m; throw "DIE: $m" }
    $ops = New-FakeOps @((New-Info -status 'working'), (New-Info -status 'working'))
    Send-CrewMessage 'demo-rev' 'Rev Gọn: merge crew/a (1111111).' $false '' $ops
    $script:died | Should Be $null
    ($script:said -join "`n") | Should Match 'demo-rev nhưng agent đang bận: tin nằm chờ'
    $ops.State.Keys | Should Be 0
  }
}
