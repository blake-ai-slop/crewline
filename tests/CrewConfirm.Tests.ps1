function hc { throw 'hc thật bị cấm' }
. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# v16 crew confirm: đọc màn hình 1 lần, agent rảnh + không hộp thoại + ô nhập có chữ ⇒ Enter đúng 1 lần; Rev ⇒ ghi trạng thái review.
# Hàm thật qua AST, hc giả. Fixture thật paste-v16 (Claude 2.1.329 / Codex 0.171, chữ gõ bằng hc keys, chưa Enter).
$want = 'Get-ConfirmPlan', 'Invoke-ConfirmCore', 'Update-ConfirmReview', 'Get-ReviewMessageBranches', 'Format-ReviewMessage', 'Update-Tasks',
  'Get-ScreenRows', 'Find-PromptBox', 'Get-SendBox', 'Get-InputBox', 'Get-ScreenDialog', 'Get-TermStatus', 'Test-AgentScreen'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { }
function Die($m) { throw "DIE: $m" }

function Get-Fixture([string]$path) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$path")) -replace "`r`n", "`n" -replace '^\uFEFF', '').TrimEnd("`n") }
$CB = Get-Fixture 'paste-v16/claude-2.1.329-before.txt'
$CA = Get-Fixture 'paste-v16/claude-2.1.329-after.txt'
$XB = Get-Fixture 'paste-v16/codex-0.171-before.txt'
$XA = Get-Fixture 'paste-v16/codex-0.171-after.txt'
$Dialog = $CA + "`n Do you want to proceed?`n ❯ 1. Yes`n   2. No"
function New-Info([string]$app, [string]$state = 'idle', [string]$live = 'live') {
  [pscustomobject]@{ state = $live; address = 't7'; turn = 3; status = $(if ($app) { [pscustomobject]@{ app = $app; state = $state } } else { 'idle' }) }
}
function New-ConfirmOps($info, [string]$screen) {
  $script:Keys = 0; $script:Reads = 0; $script:Info = $info; $script:Screen = $screen; $script:OnRead = $null; $script:KeysOk = $true
  @{
    Get = { param($t) $script:Info }
    Read = { param($t) $script:Reads++; if ($script:OnRead) { & $script:OnRead }; $script:Screen }
    Keys = { param($t) $script:Keys++; $script:KeysOk }
  }
}

Describe 'Get-ConfirmPlan: chỉ Enter khi agent rảnh, không hộp thoại, ô nhập đúng loại có chữ' {
  It 'Claude rảnh, tin nằm ô ❯ ⇒ được' {
    $p = Get-ConfirmPlan (New-Info 'claude-code') $CA
    $p.Ok | Should Be $true
    $p.Kind | Should Be 'claude'
    $p.Text | Should Be 'probe paste xin chao'
  }
  It 'Codex 0.171 rảnh, tin nằm ô › ⇒ được' {
    (Get-ConfirmPlan (New-Info 'codex') $XA).Ok | Should Be $true
  }
  It 'hc chưa báo app nhưng màn hình là Claude ⇒ được' {
    (Get-ConfirmPlan (New-Info '') $CA).Ok | Should Be $true
  }
  It 'không được: ô trống, hộp thoại, working, blocked, không live, lệch loại ô, shell' {
    (Get-ConfirmPlan (New-Info 'claude-code') $CB).Reason | Should Be 'ô nhập trống'
    (Get-ConfirmPlan (New-Info 'codex') $XB).Reason | Should Be 'ô nhập trống'
    (Get-ConfirmPlan (New-Info 'claude-code') $Dialog).Reason | Should Match 'hộp thoại'
    (Get-ConfirmPlan (New-Info 'claude-code' 'working') $CA).Reason | Should Match 'working'
    (Get-ConfirmPlan (New-Info 'claude-code' 'blocked') $CA).Reason | Should Match 'chờ duyệt'
    (Get-ConfirmPlan (New-Info 'claude-code' 'idle' 'exited') $CA).Reason | Should Match 'không live'
    (Get-ConfirmPlan (New-Info 'codex') $CA).Reason | Should Match 'ô nhập kiểu claude, app codex'
    (Get-ConfirmPlan (New-Info '') "PS C:\> ").Reason | Should Match 'shell'
    (Get-ConfirmPlan (New-Info 'claude-code') "$CA`n Trust this folder?`n› 1. Trust and continue`n  2. Quit`n  enter continue · esc quit").Ok | Should Be $false
  }
}

Describe 'Invoke-ConfirmCore: Enter đúng 1 lần, đọc màn hình 1 lần' {
  It 'đạt ⇒ 1 Enter, 1 lần đọc, câu báo có chữ trong ô' {
    $ops = New-ConfirmOps (New-Info 'claude-code') $CA
    $r = Invoke-ConfirmCore 'demo-w1' $ops
    $r.Ok | Should Be $true
    $script:Keys | Should Be 1
    $script:Reads | Should Be 1
    $r.Message | Should Match 'đã bấm Enter 1 lần ở demo-w1 \(ô nhập: probe paste xin chao\)'
  }
  It 'trạng thái đổi sau lần đọc (blocked / working / pane khác cùng tên / turn mới / app khác / mất) ⇒ kiểm lại sát trước phím, không bấm' {
    $changes = @(
      { $script:Info = New-Info 'claude-code' 'blocked' },
      { $script:Info = New-Info 'claude-code' 'working' },
      { $i = New-Info 'claude-code'; $i.address = 't8'; $script:Info = $i },
      { $i = New-Info 'claude-code'; $i.turn = 4; $script:Info = $i },
      { $script:Info = New-Info 'codex' },
      { $script:Info = $null }
    )
    foreach ($change in $changes) {
      $ops = New-ConfirmOps (New-Info 'claude-code') $CA
      $script:OnRead = $change
      $r = Invoke-ConfirmCore 'demo-w1' $ops
      $r.Ok | Should Be $false
      $r.Message | Should Match 'không bấm Enter'
      $script:Keys | Should Be 0
    }
  }
  It 'hc keys thất bại ⇒ không Ok (không coi là đã gửi)' {
    $ops = New-ConfirmOps (New-Info 'claude-code') $CA
    $script:KeysOk = $false
    $r = Invoke-ConfirmCore 'demo-w1' $ops
    $r.Ok | Should Be $false
    $r.Message | Should Match 'hc keys enter thất bại'
  }
  It 'hộp thoại / ô trống ⇒ không bấm phím' {
    foreach ($s in $Dialog, $CB) {
      $ops = New-ConfirmOps (New-Info 'claude-code') $s
      $r = Invoke-ConfirmCore 'demo-w1' $ops
      $r.Ok | Should Be $false
      $r.Message | Should Match 'không bấm Enter'
      $script:Keys | Should Be 0
    }
  }
}

Describe 'Invoke-ConfirmCore ở Rev: ghi trạng thái review như crew review -Sent' {
  BeforeEach {
    $script:Store = '[{"name":"a","branch":"crew/a","reviewSentAt":"2026-11-21T01:00:00Z","reviewUnsure":true},{"name":"b","branch":"crew/b","doneAt":"x"},{"name":"bb","branch":"crew/bb","doneAt":"x"},{"name":"c","branch":"crew/c"}]'
    function Get-Tasks { , @($script:Store | ConvertFrom-Json) }
    function Save-Tasks($root, $items) { $script:Store = ConvertTo-Json -InputObject @($items) -Depth 10 }
    function Use-CrewStateLock($root, $action) { & $action }
  }
  It 'chỉ task có nhánh trong tin ở ô: ô nhắc crew/b ⇒ chỉ b ghi reviewSentAt; reviewUnsure của a, nhánh tiền tố bb, c không đụng' {
    $screen = $CB -replace '(?m)^❯\s*$', '❯ Rev Gọn: merge crew/b (abc123). Đọc context/tasks/b.md. Full test, crew clean b, báo planner. Không push.'
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    $r = Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo'
    $r.Ok | Should Be $true
    $script:Keys | Should Be 1
    (@($r.Changed)) -join ',' | Should Be 'b'
    $t = @($script:Store | ConvertFrom-Json)
    $t[0].reviewUnsure | Should Be $true
    $t[1].reviewSentAt | Should Not BeNullOrEmpty
    $t[2].PSObject.Properties['reviewSentAt'] | Should Be $null
    $t[3].PSObject.Properties['reviewSentAt'] | Should Be $null
  }
  It 'ô nhắc crew/a (đang reviewUnsure) ⇒ bỏ reviewUnsure, giữ reviewSentAt cũ; task khác không đổi' {
    $screen = $CB -replace '(?m)^❯\s*$', '❯ Rev Gọn: merge crew/a (abc123). Đọc context/tasks/a.md. Full test, crew clean a, báo planner. Không push.'
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    $r = Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo'
    (@($r.Changed)) -join ',' | Should Be 'a'
    $t = @($script:Store | ConvertFrom-Json)
    $t[0].PSObject.Properties['reviewUnsure'] | Should Be $null
    ([datetime]$t[0].reviewSentAt).ToUniversalTime().ToString('s') | Should Be '2026-11-21T01:00:00'
    $t[1].PSObject.Properties['reviewSentAt'] | Should Be $null
  }
  It 'Rev: hc keys thất bại ⇒ không đổi task' {
    $before = $script:Store
    $screen = $CB -replace '(?m)^❯\s*$', '❯ Rev Gọn: merge crew/b (abc123).'
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    $script:KeysOk = $false
    (Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo').Ok | Should Be $false
    $script:Store | Should Be $before
  }
  It 'Rev: trạng thái đổi trước phím ⇒ không bấm, không đổi task' {
    $before = $script:Store
    $screen = $CB -replace '(?m)^❯\s*$', '❯ Rev Gọn: merge crew/b (abc123).'
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    $script:OnRead = { $script:Info = New-Info 'claude-code' 'blocked' }
    (Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo').Ok | Should Be $false
    $script:Keys | Should Be 0
    $script:Store | Should Be $before
  }
  It 'tin thường có nhắc crew/b (không phải tin review crew sinh) ⇒ vẫn Enter nhưng KHÔNG đổi task' {
    $before = $script:Store
    $screen = $CB -replace '(?m)^❯\s*$', '❯ Please do not merge crew/b until I review it'
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    $r = Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo'
    $r.Ok | Should Be $true
    $script:Keys | Should Be 1
    $r.Changed.Count | Should Be 0
    $script:Store | Should Be $before
  }
  It 'tin review có vỏ <hc from> (gửi từ pane planner) ⇒ đổi đúng task trong tin' {
    $msg = '<hc from="t2v demo-planner">Rev Gọn: merge crew/b (abc123). Đọc context/tasks/b.md. Full test, crew clean b, báo planner. Không push.</hc>'
    $screen = $CB -replace '(?m)^❯\s*$', "❯ $msg"
    $ops = New-ConfirmOps (New-Info 'claude-code') $screen
    (@((Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo').Changed)) -join ',' | Should Be 'b'
  }
    It 'terminal không phải Rev ⇒ không đổi task' {
    $before = $script:Store
    $ops = New-ConfirmOps (New-Info 'claude-code') $CA
    $r = Invoke-ConfirmCore 'demo-w1' $ops 'C:\repo' 'demo'
    $r.Changed.Count | Should Be 0
    $script:Store | Should Be $before
  }
  It 'không bấm được ⇒ không đổi task' {
    $before = $script:Store
    $ops = New-ConfirmOps (New-Info 'claude-code') $Dialog
    (Invoke-ConfirmCore 'demo-rev' $ops 'C:\repo' 'demo').Ok | Should Be $false
    $script:Store | Should Be $before
  }
}

Describe 'Get-ReviewMessageBranches: chỉ nhận đúng khuôn tin Format-ReviewMessage' {
  It 'tin do Format-ReviewMessage sinh (1 và nhiều task, mọi mức) ⇒ đúng nhánh theo thứ tự' {
    $one = Format-ReviewMessage 'Gọn' @(@{ Name = 'b'; Branch = 'crew/b'; Commits = @('abc123') })
    (Get-ReviewMessageBranches $one) -join ',' | Should Be 'crew/b'
    $two = Format-ReviewMessage 'Đủ' @(@{ Name = 'a'; Branch = 'crew/a'; Commits = @('c1', 'c2') }, @{ Name = 'b'; Branch = 'crew/b'; Commits = @('(đã merge)') })
    (Get-ReviewMessageBranches $two) -join ',' | Should Be 'crew/a,crew/b'
    # TUI gói dòng: khoảng trắng thừa giữa các từ vẫn nhận
    (Get-ReviewMessageBranches ($one -replace ' Full test,', "`n  Full test,")) -join ',' | Should Be 'crew/b'
  }
  It 'tin thường / tin sửa đổi / thêm chữ ⇒ @()' {
    @(Get-ReviewMessageBranches 'Please do not merge crew/b until I review it').Count | Should Be 0
    @(Get-ReviewMessageBranches 'merge crew/b (abc123)').Count | Should Be 0
    $one = Format-ReviewMessage 'Gọn' @(@{ Name = 'b'; Branch = 'crew/b'; Commits = @('abc123') })
    @(Get-ReviewMessageBranches "$one Đừng làm gì cả.").Count | Should Be 0
    @(Get-ReviewMessageBranches ($one -replace 'Không push\.$', 'Push luôn.')).Count | Should Be 0
    @(Get-ReviewMessageBranches ($one -replace 'crew clean b', 'crew clean b, crew clean c')).Count | Should Be 0
  }
}
