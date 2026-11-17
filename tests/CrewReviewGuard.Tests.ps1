. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# crew review kiểm Rev trước khi gửi: Get-RevGuard + Invoke-Review thật qua AST; hc giả qua stub, không gọi hc thật.

$want = 'Get-TermStatus', 'Get-SendPlan', 'Get-WorkerMode', 'Test-AgentScreen', 'Get-RevGuard', 'Invoke-Review'
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($m) { $script:Said += @($m) }
function Die($m) { throw "DIE: $m" }
function hc { throw 'gọi hc thật trong test' }

function New-RevInfo([string]$app = 'claude-code', [string]$status = 'idle', [string]$state = 'live') {
  $st = if ($app) { [pscustomobject]@{ app = $app; state = $status } } else { $null }
  [pscustomobject]@{ name = 'demo-rev'; state = $state; status = $st; turn = 1 }
}

$ClaudeScreen = "● xong`n❯`n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
$CodexScreen = "› Ask Codex to do anything`n  GPT · Context 42% left"
$CodexShell = "  GPT · Context 42% left`nPS C:\x>"

Describe 'Get-RevGuard' {
  It 'Rev=none (hoặc thiếu khóa rev) ⇒ gợi ý review fast, không có pane' {
    Get-RevGuard @{ rev = 'none' } 'demo-rev' $null | Should Match 'Rev=none.*review fast'
    Get-RevGuard @{ } 'demo-rev' $null | Should Match 'Rev=none'
  }
  It 'không live ⇒ chạy crew up' {
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' $null | Should Match 'demo-rev không chạy — chạy crew up'
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' (New-RevInfo -state 'exited') | Should Match 'chạy crew up'
  }
  It 'chờ duyệt ⇒ chủ dự án xử lý' {
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' (New-RevInfo -status 'blocked') | Should Match 'chờ duyệt — chủ dự án xử lý'
  }
  It 'sai agent ⇒ nêu app thật, kind config, lệnh -Restart rev' {
    Get-RevGuard @{ rev = 'codex' } 'demo-rev' (New-RevInfo 'claude-code') | Should BeExactly 'rev đang chạy claude-code, config là codex — crew up -Restart rev'
  }
  It 'chỉ còn shell: màn hình không phải agent (hoặc không đọc được) ⇒ crew up -Restart rev' {
    $shell = New-RevInfo ''
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' $shell { "PS C:\x>" } | Should BeExactly 'rev chỉ còn shell — crew up -Restart rev'
    Get-RevGuard @{ rev = 'codex' } 'demo-rev' $shell { $CodexShell } | Should BeExactly 'rev chỉ còn shell — crew up -Restart rev'
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' $shell | Should BeExactly 'rev chỉ còn shell — crew up -Restart rev'
  }
  It 'hc báo shell nhưng màn hình là TUI agent (phiên mở lại chưa báo app) ⇒ gửi được, chỉ đọc màn hình khi shell' {
    $shell = New-RevInfo ''
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' $shell { $ClaudeScreen } | Should Be ''
    Get-RevGuard @{ rev = 'codex' } 'demo-rev' $shell { $CodexScreen } | Should Be ''
    $script:ScreenReads = 0
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' (New-RevInfo) { $script:ScreenReads++; 'x' } | Should Be ''
    $script:ScreenReads | Should Be 0
  }
  It 'đúng agent (idle/working) ⇒ gửi được' {
    Get-RevGuard @{ rev = 'claude' } 'demo-rev' (New-RevInfo) | Should Be ''
    Get-RevGuard @{ rev = 'codex' } 'demo-rev' (New-RevInfo 'codex' 'working') | Should Be ''
  }
}

Describe 'crew review kiểm Rev trước khi gửi' {
  BeforeEach {
    $script:Said = @(); $script:Saved = 0; $script:Sent = 0; $script:Reads = 0; $script:DryRun = $false
    $script:NameList = @('a'); $script:Rev = 'claude'; $script:RevInfo = New-RevInfo
    function Get-MainRoot($p) { 'C:\demo' }
    function Get-Config($p) { @{ review = 'lean'; rev = $script:Rev } }
    function Get-CrewName { 'demo' }
    function Get-Tasks { , @([pscustomobject]@{ name = 'a'; branch = 'crew/a' }) }
    function Invoke-GitOrDie { @{ Code = 0; Text = 'main' } }
    function Get-ReviewLine { @{ Msg = 'Rev Gọn: merge crew/a (1111111).'; Error = '' } }
    function Get-TermInfo($t) { $script:Reads++; $script:RevInfo }
    $script:Screen = 'PS C:\x>'
    function New-HcOps { @{ Read = { param($t) $script:Screen } } }
    function Send-CrewMessage { $script:Sent++ }
    function Save-Tasks { $script:Saved++ }
  }
  $cases = @(
    @{ Name = 'Rev=none'; Rev = 'none'; Info = $null; Want = 'Rev=none'; Reads = 0 },
    @{ Name = 'không live'; Rev = 'claude'; Info = $null; Want = 'chạy crew up'; Reads = 1 },
    @{ Name = 'chờ duyệt'; Rev = 'claude'; Info = (New-RevInfo -status 'blocked'); Want = 'chờ duyệt'; Reads = 1 },
    @{ Name = 'sai agent'; Rev = 'codex'; Info = (New-RevInfo); Want = 'rev đang chạy claude-code, config là codex — crew up -Restart rev'; Reads = 1 },
    @{ Name = 'chỉ còn shell'; Rev = 'claude'; Info = (New-RevInfo ''); Want = 'rev chỉ còn shell — crew up -Restart rev'; Reads = 1 }
  )
  foreach ($c in $cases) {
    It "$($c.Name): Die, không gửi, không đánh dấu reviewSentAt" {
      $script:Rev = $c.Rev; $script:RevInfo = $c.Info
      $err = try { Invoke-Review; '' } catch { "$_" }
      $err | Should Match ([regex]::Escape($c.Want))
      $script:Sent | Should Be 0
      $script:Saved | Should Be 0
      $script:Reads | Should Be $c.Reads
    }
    It "$($c.Name) + -DryRun: vẫn in dòng review, chỉ cảnh báo" {
      $script:Rev = $c.Rev; $script:RevInfo = $c.Info; $script:DryRun = $true
      $out = Invoke-Review 6>&1 | ForEach-Object { "$_" }
      ($out -join "`n") | Should Match 'Rev Gọn: merge crew/a'
      ($script:Said -join "`n") | Should Match ('^cảnh báo: .*' + [regex]::Escape($c.Want))
      $script:Sent | Should Be 0
      $script:Saved | Should Be 0
    }
  }
  It 'hc báo shell nhưng màn hình là agent: gửi và đánh dấu' {
    $script:RevInfo = New-RevInfo ''; $script:Screen = $ClaudeScreen
    Invoke-Review
    $script:Sent | Should Be 1
    $script:Saved | Should Be 1
  }
  It 'Rev sống, đúng agent: đọc 1 lần, gửi và đánh dấu như cũ' {
    Invoke-Review
    $script:Reads | Should Be 1
    $script:Sent | Should Be 1
    $script:Saved | Should Be 1
  }
}
