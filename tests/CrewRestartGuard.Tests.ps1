. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# crew up -Restart không tự tắt planner/Rev đang làm: hàm thuần Get-RestartGuard qua AST (e2e với hc giả ở CrewResume.Tests.ps1).

foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-RestartGuard' } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

Describe 'Get-RestartGuard' {
  $sent = [pscustomobject]@{ name = 'a'; worker = 1; reviewSentAt = '2026-11-17T00:00:00Z' }
  $plain = [pscustomobject]@{ name = 'b'; worker = 2 }

  It 'planner là đích và đang chạy agent ⇒ chặn (mọi trạng thái working/idle đều là mode agent)' {
    Get-RestartGuard @('planner') @() 'agent' | Should Match 'planner đang chạy — bật lại sẽ mất hội thoại điều phối; thêm -Force nếu chắc chắn\.'
    Get-RestartGuard @('planner', 'w1', 'rev') @() 'agent' | Should Match '^planner đang chạy'
  }
  It 'planner không chạy agent (shell, sai agent, không live) hoặc không là đích ⇒ không chặn' {
    foreach ($m in '', 'shell', 'dead', 'wrong', 'blocked') { Get-RestartGuard @('planner') @() $m | Should Be '' }
    Get-RestartGuard @('w1') @() 'agent' | Should Be ''
  }
  It 'rev là đích và có task đã gửi review ⇒ chặn, nêu tên task' {
    $why = Get-RestartGuard @('rev') @($sent, $plain, [pscustomobject]@{ name = 'c'; reviewSentAt = 'x' }) ''
    $why | Should Match 'rev đang review/merge task a, c'
    $why | Should Match '-Force'
    $why | Should Not Match '\bb\b,'
  }
  It 'rev không có task chờ review, hoặc rev không là đích ⇒ không chặn' {
    Get-RestartGuard @('rev') @($plain) '' | Should Be ''
    Get-RestartGuard @('rev') @() '' | Should Be ''
    Get-RestartGuard @('w1', 'planner') @($sent) '' | Should Be ''
  }
}
