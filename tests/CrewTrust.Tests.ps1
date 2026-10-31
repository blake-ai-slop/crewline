# AST + hc giả; không gọi terminal thật.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/crew.ps1'), [ref]$null, [ref]$null)
$want = 'Get-TermStatus', 'Get-SendPlan', 'Get-WorkerMode', 'Get-ScreenDialog', 'Test-SessionReady', 'Wait-WorkerReady', 'Invoke-SendFlow', 'Show-StartupTrust', 'Invoke-Up', 'Invoke-Hot'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

$ClaudeTrust = @'
Quick safety check: Is this a project you created or one you trust? ...
 ❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel
'@
$CodexTrust = @'
  Trust this folder? Codex can read, edit, and run files here, ...
› 1. Trust and continue
  2. Quit
  enter continue · esc quit
'@
$Picker = @'
Where should the new conversation run?
› 1. Use current Git worktree
  2. Create new Git worktree
enter select · esc back
'@
function New-TrustInfo($kind = 'claude', $state = 'idle') {
  [pscustomobject]@{ state = 'live'; status = [pscustomobject]@{ app = $(if ($kind -eq 'claude') { 'claude-code' } else { 'codex' }); state = $state }; turn = 1 }
}
function New-TrustOps($screens, $infos = @{}) {
  $defaultInfo = New-TrustInfo
  $st = @{ Reads = @{}; Keys = 0; Sleeps = 0; Screens = $screens; Infos = $infos }
  @{
    State = $st
    Get = { param($t) if ($st.Infos.ContainsKey($t)) { $st.Infos[$t] } else { $defaultInfo } }.GetNewClosure()
    Read = { param($t) if (-not $st.Reads.ContainsKey($t)) { $st.Reads[$t] = 0 }; $st.Reads[$t]++; $st.Screens[$t] }.GetNewClosure()
    Send = { param($t, $x, $raw) @{ Code = 0; Text = '{"started":false}' } }
    Keys = { param($t) $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) $st.Sleeps++ }.GetNewClosure()
  }
}
function Say($msg) { $script:Messages.Add([string]$msg) }
function Die($msg) { throw $msg }
function hc { throw 'không được gọi hc thật' }

Describe 'trust thư mục' {
  BeforeEach { $script:Messages = [Collections.Generic.List[string]]::new() }
  It 'nhận hai màn hình thật, hộp khác thắng trust và /new' {
    Get-ScreenDialog $ClaudeTrust | Should Be 'trust'
    Get-ScreenDialog $CodexTrust | Should Be 'trust'
    Get-ScreenDialog "$ClaudeTrust`nAllow command" | Should Be 'other'
    Get-ScreenDialog "$CodexTrust`nAllow command" | Should Be 'other'
    Get-ScreenDialog "$Picker`n$CodexTrust" | Should Be 'other'
    Get-ScreenDialog $Picker | Should Be 'codex-new'
    Get-ScreenDialog 'Do you want to proceed?' | Should Be 'other'
  }
  It 'SendFlow không Enter với trust, cả tin thường và /new' {
    foreach ($screen in @($ClaudeTrust, $CodexTrust)) {
      foreach ($session in @('', 'codex')) {
        $ops = New-TrustOps @{ t = $screen }
        (Invoke-SendFlow t '/new' $ops $session 2).Ok | Should Be $false
        $ops.State.Keys | Should Be 0
      }
    }
  }
  It 'trust thắng ready, Wait trả đúng phím kể cả blocked' {
    foreach ($kind in @('claude', 'codex')) {
      $screen = if ($kind -eq 'claude') { $ClaudeTrust } else { $CodexTrust }
      $ops = New-TrustOps @{ t = $screen } @{ t = (New-TrustInfo $kind 'blocked') }
      $msg = Wait-WorkerReady t $kind $ops 1
      $msg | Should Match '^t đang chờ trust thư mục — bấm trong pane:'
      if ($kind -eq 'claude') {
        $msg | Should Match '↓ rồi Enter'
        $msg | Should Match 'hc keys t down enter'
      } else {
        $msg | Should Match 'pane: Enter'
        $msg | Should Match 'hc keys t enter'
      }
      (Test-SessionReady $kind (New-TrustInfo $kind) "$screen`nContext 100% left`n❯ /clear`n❯") | Should Be $false
      $ops.State.Keys | Should Be 0
    }
  }
  It 'chờ tối đa 20s, dừng đọc pane có hộp hoặc ready' {
    $ops = New-TrustOps @{ a = $CodexTrust; b = ''; c = 'Allow command' } @{ b = (New-TrustInfo codex 'working') }
    Show-StartupTrust @(@{ Term = 'a'; Kind = 'codex' }, @{ Term = 'b'; Kind = 'codex' }, @{ Term = 'c'; Kind = 'claude' }) $ops
    $ops.State.Reads.a | Should Be 1
    $ops.State.Reads.b | Should Be 11
    $ops.State.Reads.c | Should Be 1
    $ops.State.Sleeps | Should Be 10
    $ops.State.Keys | Should Be 0
    ($script:Messages -join "`n") | Should Match 'hc keys a enter'
  }
}

Describe 'crew up với terminal giả' {
  BeforeEach {
    $script:Messages = [Collections.Generic.List[string]]::new()
    $script:Path = $TestDrive; $script:Restart = ''; $script:Force = $false
    function Get-Root($p) { $p }
    function Get-Config($p) { [pscustomobject]@{ planner = 'none'; rev = 'none'; workers = @('claude', 'codex'); access = 'full' } }
    function Get-Slug($p) { 'demo' }
    function Get-MainBranch($p) { 'main' }
    function Get-Ids($s) { @{ Space = 's'; Workers = { param($n) "w$n" } } }
    function Get-LiveTerminals { @([pscustomobject]@{ name = 'demo-old'; state = 'live' }) }
    function Initialize-WorkerTree($r, $n, $m) { "wt$n" }
    function Start-WorkerTerm($r, $c, $ids, $slug, $n, $m) { @{ address = "t$n" } }
    function Wait-Tab($t) { $false }
    function New-HcOps { $script:UpOps }
  }
  It '2 pane mới: chỉ in 1 dòng Claude trust, không đọc terminal cũ, không bấm' {
    $script:UpOps = New-TrustOps @{ 'demo-w1' = $ClaudeTrust; 'demo-w2' = '' } @{ 'demo-w2' = (New-TrustInfo codex) }
    Invoke-Up
    $out = $script:Messages -join "`n"
    $out | Should Match 'Chờ bạn bấm "trust thư mục"'
    @($script:Messages | Where-Object { $_ -match 'vào pane:' }).Count | Should Be 1
    $out | Should Match 'demo-w1  claude.*↓ rồi Enter.*hc keys demo-w1 down enter'
    $out | Should Match 'Trust một lần cho mỗi thư mục'
    $script:UpOps.State.Reads.Count | Should Be 2
    $script:UpOps.State.Keys | Should Be 0
  }
  It 'không ai trust: không in khối hoặc mẹo cũ' {
    $script:UpOps = New-TrustOps @{ 'demo-w1' = ''; 'demo-w2' = '' } @{ 'demo-w2' = (New-TrustInfo codex) }
    Invoke-Up
    ($script:Messages -join "`n") | Should Not Match 'trust thư mục|vào pane:|Agent hỏi trust'
    $script:UpOps.State.Keys | Should Be 0
  }
  It 'terminal đã chạy không đọc lại' {
    function Get-LiveTerminals { @([pscustomobject]@{ name = 'demo-w1'; state = 'live' }, [pscustomobject]@{ name = 'demo-w2'; state = 'live' }) }
    $script:UpOps = New-TrustOps @{}
    Invoke-Up
    $script:UpOps.State.Reads.Count | Should Be 0
  }
}

Describe 'crew hot đọc màn hình một lần cho agent idle/blocked' {
  It 'hiện chờ trust, bỏ qua working và shell' {
    $script:Messages = [Collections.Generic.List[string]]::new()
    $script:Path = $TestDrive
    function Get-Root($p) { $p }
    function Get-Config($p) { [pscustomobject]@{ workers = @(); planner = 'none'; rev = 'none'; access = 'full'; review = 'lean' } }
    function Get-Slug($p) { 'demo' }
    function Get-Tasks($p) { ,@() }
    function git { }
    function Get-LiveTerminals {
      @(
        [pscustomobject]@{ name = 'demo-w1'; address = 't1'; state = 'live'; status = 'blocked'; agent = 'claude' }
        [pscustomobject]@{ name = 'demo-w2'; address = 't2'; state = 'live'; status = [pscustomobject]@{ app = 'codex'; state = 'idle' }; agent = 'codex' }
        [pscustomobject]@{ name = 'demo-w3'; address = 't3'; state = 'live'; status = 'working'; agent = 'codex' }
        [pscustomobject]@{ name = 'demo-w4'; address = 't4'; state = 'live'; status = 'idle'; agent = '' }
      )
    }
    function Write-Host {
      param([Parameter(ValueFromPipeline = $true)]$Object)
      process { $script:Messages.Add([string]$Object) }
    }
    $script:HotOps = New-TrustOps @{ 'demo-w1' = $ClaudeTrust; 'demo-w2' = $CodexTrust }
    function New-HcOps { $script:HotOps }
    Invoke-Hot
    @($script:Messages | Where-Object { $_ -match 'chờ trust' }).Count | Should Be 2
    $script:HotOps.State.Reads.Count | Should Be 2
    $script:HotOps.State.Reads['demo-w1'] | Should Be 1
    $script:HotOps.State.Reads['demo-w2'] | Should Be 1
    $script:HotOps.State.Keys | Should Be 0
  }
}
