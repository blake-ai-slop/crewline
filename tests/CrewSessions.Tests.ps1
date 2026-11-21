. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# Start-Term + Send-WorkerTask (shell) thật qua AST; hc giả là hàm, không gọi hc thật.
$want = 'Start-Term', 'Send-WorkerTask', 'Get-AgentCommand', 'Get-Flags', 'Quote', 'Get-SuggestionEnvLine'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Die($m) { throw "DIE: $m" }

Describe 'Start-Term tắt gợi ý câu kế tiếp của Claude Code' {
  BeforeEach {
    $script:HcArgs = @()
    function hc { $script:HcArgs = @($args); $global:LASTEXITCODE = 0; '{"address":"t9","name":"x-w1"}' }
    function Get-HerdrSpaces { @{ Ok = $true; spaces = @([pscustomobject]@{ tabs = @([pscustomobject]@{ terminals = @([pscustomobject]@{ terminal = 't9' }) }) }) } }
  }
  It 'lệnh pane (giải base64) đặt biến sau đoạn xóa biến phiên cha và trước lệnh agent' {
    foreach ($agent in "claude --dangerously-skip-permissions 'Bạn là worker w1'", "codex resume --last") {
      Start-Term 'x-w1' 'C:\x' 'sp' 'tb' $agent | Out-Null
      $i = [array]::IndexOf($script:HcArgs, '-EncodedCommand')
      $i | Should BeGreaterThan 0
      $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:HcArgs[$i + 1]))
      $cmd | Should Match 'CLAUDE_CODE_CHILD_SESSION'
      $cmd.EndsWith("}; `$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; $agent") | Should Be $true
    }
  }
  It 'config suggestions bật cho vai (suggest $true): xóa biến thay vì đặt false' {
    Start-Term 'x-planner' 'C:\x' 'sp' 'tb' 'claude' $true | Out-Null
    $i = [array]::IndexOf($script:HcArgs, '-EncodedCommand')
    $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:HcArgs[$i + 1]))
    $cmd.EndsWith("}; Remove-Item Env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION -ErrorAction Ignore; claude") | Should Be $true
    $cmd | Should Not Match "= 'false'"
  }
  It 'không có lệnh (shell trống): không EncodedCommand' {
    Start-Term 'x-w1' 'C:\x' 'sp' 'tb' '' | Out-Null
    $script:HcArgs -contains '-EncodedCommand' | Should Be $false
  }
  It 'biến chạy được trong pwsh: chỉ đặt trong tiến trình pane' {
    # pane crew đã có biến = 'false' ⇒ dùng giá trị canh riêng để biết Start-Term không đổi biến của tiến trình cha
    $old = $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
    try {
      $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'sentinel-cha'
      Start-Term 'x-w1' 'C:\x' 'sp' 'tb' 'Write-Output $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION' | Out-Null
      $i = [array]::IndexOf($script:HcArgs, '-EncodedCommand')
      $out = & pwsh -NoProfile -NonInteractive -EncodedCommand $script:HcArgs[$i + 1]
      "$out".Trim() | Should Be 'false'
      $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION | Should Be 'sentinel-cha'
    } finally { $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = $old }
  }
}

Describe 'Send-WorkerTask bật agent trong shell cũng tắt gợi ý' {
  It 'lệnh gõ vào shell đặt biến trước Set-Location và lệnh agent' {
    $script:Sent = ''
    function Invoke-SendFlow($term, $text, $ops) { $script:Sent = $text; @{ Ok = $true; Message = 'ok' } }
    $r = Send-WorkerTask 'x-w1' 'claude' 'shell' 'C:\wt' 'làm task' 'full' $null
    $r.Ok | Should Be $true
    $script:Sent | Should Match "^\`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; Set-Location -LiteralPath 'C:\\wt'; .*\{ claude "
  }
}
