# AST thật + adapter hc thật với lệnh hc giả; không đụng terminal người dùng.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/crew.ps1'), [ref]$null, [ref]$null)
$want = 'Get-TermShellState', 'Get-TermStatus', 'Invoke-Up', 'Test-TermOwner', 'Test-SamePath', 'ConvertTo-RootKey',
  'Get-ForeignTermError', 'Get-TermInfo', 'New-HcOps', 'Stop-Term', 'Get-LiveTerminals'
$want += 'Get-SessionsFile', 'New-SessionBook', 'Test-SessionId', 'Read-SessionBook', 'Save-SessionBook', 'Set-SessionRecord', 'Get-NewSessionPlan', 'Get-SessionPlan', 'Format-SessionPlan', 'Test-AgentScreen', 'Get-ResumeState', 'Wait-ResumeStates'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function New-CoreShell {
  [pscustomobject]@{ name = 'demo-w1'; address = 't7'; cwd = [string]$TestDrive; state = 'live'; status = $null
    argv = @('C:\Program Files\PowerShell\7\pwsh.exe', '-NoExit', '-Command', '$global:__hc_prompt = $function:prompt; function global:prompt { }')
    keep = $true }
}

Describe 'Get-TermShellState chỉ tin shell core đã xác minh' {
  It 'mẫu thật Windows là lost, kể cả đường dẫn shell có khoảng trắng' -Skip:($IsWindows -eq $false) {
    Get-TermShellState (New-CoreShell) { 'PS C:\x> ' } | Should Be 'lost'
  }
  It 'Linux/macOS chưa xác minh: không tự nhận lost dù có marker PowerShell' -Skip:($IsWindows -ne $false) {
    Get-TermShellState (New-CoreShell) { 'PS /tmp/x>' } | Should BeNullOrEmpty
  }
  It 'agent chưa báo status, shell thiếu marker và shell Unix không là lost' {
    foreach ($exe in 'claude', 'codex', 'node', 'pwsh.exe', 'bash', '/bin/zsh', '/bin/sh') {
      $info = New-CoreShell
      $info.argv = @($exe)
      Get-TermShellState $info { '❯' } | Should BeNullOrEmpty
      Get-TermShellState $info { 'PS C:\x>' } | Should BeNullOrEmpty
    }
    foreach ($exe in 'claude', 'codex', 'node', '/bin/bash') {
      $info = New-CoreShell; $info.argv[0] = $exe
      Get-TermShellState $info { 'PS C:\x>' } | Should BeNullOrEmpty
    }
  }
  It 'foreground agent hoặc tiến trình lạ thắng argv của shell' {
    foreach ($exe in 'claude', 'codex', 'node') {
      $info = New-CoreShell
      $info | Add-Member foreground ([pscustomobject]@{ argv = @($exe) })
      Get-TermShellState $info { 'PS C:\x>' } | Should BeNullOrEmpty
    }
  }
  It 'ô nhập Claude, status agent hoặc blocked không là lost' {
    $info = New-CoreShell
    Get-TermShellState $info { '❯' } | Should BeNullOrEmpty
    $info.status = @{ app = 'claude-code'; state = 'idle' }
    Get-TermShellState $info { 'PS C:\x>' } | Should BeNullOrEmpty
    $info.status = 'blocked'
    Get-TermShellState $info { 'PS C:\x>' } | Should BeNullOrEmpty
  }
  It 'EncodedCommand vẫn là exited' {
    $info = New-CoreShell; $info.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'YQ==')
    Get-TermShellState $info { 'PS C:\x>' } | Should Be 'exited'
  }
}

Describe 'crew up đọc lại ngay trước kill (hc giả)' {
  BeforeEach {
    $script:Path = $TestDrive; $script:Restart = ''; $script:Force = $false; $script:FromRepair = $false
    $script:ShellMessages = @(); $script:ShellCalls = @(); $script:ShellStarts = 0; $script:ShellGi = 0
    $script:ShellFirst = New-CoreShell; $script:ShellFresh = New-CoreShell
    $script:ShellReadText = 'PS C:\x>'; $script:ShellGetError = ''; $script:ShellThrowGet = $false
    function Say($msg) { $script:ShellMessages += $msg }
    function Die($msg) { throw $msg }
function Update-ConfigName($root, $dry) { }  # ghi sổ project cũ: test ở CrewRepairAll
    function Get-Root($p) { $p }
    function Get-Config($p) { [pscustomobject]@{ planner = 'none'; rev = 'none'; workers = @('claude'); access = 'wide' } }
    function Get-CrewName($p, $c) { 'demo' }
    function Get-CrewIdKey($p, $c) { 'demo' }
    function Get-NameConflict($p, $c) { '' }
    function Get-MoveInfo($p, $c) { $null }
    function Get-MainBranch($p) { 'main' }
    function Get-Ids($s) { @{ Space = 's'; Workers = { param($n) 'w1' } } }
    function Get-HerdrSpaces { @{ Ok = $false; Error = 'fake' } }
    function Initialize-WorkerTree($r, $n, $m) { $TestDrive }
    function Start-WorkerTerm($r, $c, $ids, $slug, $n, $m) { $script:ShellStarts++; @{ address = 't8' } }
    function Wait-Tab($t) { $false }
    function Get-Tasks($r) { ,@() }
    function Show-StartupTrust($s, $ops) { }
    function hc {
      $verb = $args[0]; $script:ShellCalls += $verb; $global:LASTEXITCODE = 0
      switch ($verb) {
        ls { @{ terminals = @((New-CoreShell)) } | ConvertTo-Json -Depth 10 -Compress }
        get {
          $script:ShellGi++
          if ($script:ShellThrowGet) { throw 'get failed' }
          if ($script:ShellGetError) { $global:LASTEXITCODE = 1; return $script:ShellGetError }
          $obj = if ($script:ShellGi -eq 1) { $script:ShellFirst } else { $script:ShellFresh }
          $obj | ConvertTo-Json -Depth 10 -Compress
        }
        read { $script:ShellReadText }
        kill { $args[1] | Should Be 't7' }
        rm { }
        default { throw "hc không được phép: $args" }
      }
    }
  }
  It 'mẫu thật: 2 lần get/read rồi đúng 1 kill và 1 agent mới' -Skip:($IsWindows -eq $false) {
    Invoke-Up
    ($script:ShellCalls -join ',') | Should Be 'ls,get,read,get,read,kill,rm'
    $script:ShellStarts | Should Be 1
  }
  It 'ls đúng chủ nhưng get thuộc project khác: không kill/bật chồng' -Skip:($IsWindows -eq $false) {
    $script:ShellFirst.cwd = Join-Path $TestDrive 'OtherProject'; $script:ShellFresh.cwd = $script:ShellFirst.cwd
    Invoke-Up
    @($script:ShellCalls | Where-Object { $_ -eq 'kill' }).Count | Should Be 0
    $script:ShellStarts | Should Be 0
    ($script:ShellMessages -join ' ') | Should Match 'không tắt demo-w1'
  }
  It 'get thiếu cwd: không kill/bật chồng' {
    $script:ShellFirst.PSObject.Properties.Remove('cwd'); $script:ShellFresh.PSObject.Properties.Remove('cwd')
    Invoke-Up
    @($script:ShellCalls | Where-Object { $_ -eq 'kill' }).Count | Should Be 0
    $script:ShellStarts | Should Be 0
  }
  It 'get lỗi/null/JSON hỏng: không kill/bật chồng' {
    foreach ($mode in 'exit', 'null', 'json', 'throw') {
      $script:ShellCalls = @(); $script:ShellGi = 0
      $script:ShellGetError = if ($mode -eq 'exit') { 'failed' } elseif ($mode -eq 'json') { '{' } else { '' }
      $script:ShellThrowGet = $mode -eq 'throw'
      $script:ShellFirst = $null
      Invoke-Up
      @($script:ShellCalls | Where-Object { $_ -eq 'kill' }).Count | Should Be 0
      $script:ShellStarts | Should Be 0
      ($script:ShellMessages -join ' ') | Should Match 'không tắt demo-w1'
    }
  }
  It 'lần đọc mới đổi address/tên/chủ/thiếu cwd/null/hết lost: không kill/bật chồng' {
    foreach ($mode in 'address', 'name', 'cwd', 'missing-cwd', 'null', 'agent') {
      $script:ShellCalls = @(); $script:ShellGi = 0; $script:ShellFresh = New-CoreShell
      switch ($mode) {
        address { $script:ShellFresh.address = 't9' }
        name { $script:ShellFresh.name = 'other' }
        cwd { $script:ShellFresh.cwd = Join-Path $TestDrive 'OtherProject' }
        missing-cwd { $script:ShellFresh.PSObject.Properties.Remove('cwd') }
        null { $script:ShellFresh = $null }
        agent { $script:ShellFresh.argv = @('claude') }
      }
      Invoke-Up
      @($script:ShellCalls | Where-Object { $_ -eq 'kill' }).Count | Should Be 0
      $script:ShellStarts | Should Be 0
    }
  }
  It 'exited chỉ cảnh báo: không kill/bật chồng' {
    $script:ShellFirst.argv = @('pwsh', '-NoExit', '-EncodedCommand', 'YQ==')
    Invoke-Up
    @($script:ShellCalls | Where-Object { $_ -eq 'kill' }).Count | Should Be 0
    $script:ShellStarts | Should Be 0
    ($script:ShellMessages -join ' ') | Should Match 'đã thoát'
  }
}
