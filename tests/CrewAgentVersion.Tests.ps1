. (Join-Path $PSScriptRoot 'CrewAst.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/platform.ps1')
# Bản agent đã kiểm + kiểm Crewline public: hàm thật trích AST, agent giả (.ps1 trên PATH), agents.json trong TestDrive, không gọi mạng.
$agentFns = 'Get-CrewTestedAgents', 'Get-CrewAgentsFile', 'Read-CrewAgentsFile', 'Set-CrewAgentsEntry', 'Compare-CrewVersion', 'Get-CrewAgentKey',
  'Invoke-AgentVersionCommand', 'Get-AgentInstalledVersion', 'Get-AgentTestedVersion', 'Get-AgentVersionNotice', 'Get-AgentVersionHint', 'Get-CrewPublicVersionUrl',
  'Get-CrewUpdateNotice', 'Show-CrewAgentNotices', 'Write-CrewStateFile', 'Get-CrewInstallCommand'
foreach ($fn in $agentFns) { . ([scriptblock]::Create((Get-CrewFunction $fn).Extent.Text)) }
function Invoke-CrewFetch([string]$url) { $script:fetchUrls += @($url); if ($script:fetchThrow) { throw 'mạng lỗi' }; $script:fetchText }
function Get-CrewVersion { [pscustomobject]@{ Version = $script:installedCrew } }

function Set-FakeAgent([string]$name, [string]$output) {
  $file = Join-Path $script:fakeBin "$name.ps1"
  [IO.File]::WriteAllText($file, "Add-Content -LiteralPath '$script:agentLog' -Value '$name'`n'$output'`n")
}
function Get-AgentCalls { if (Test-Path -LiteralPath $script:agentLog) { @(Get-Content -LiteralPath $script:agentLog) } else { @() } }
$today = Get-Date -Format 'yyyy-MM-dd'

Describe 'Compare-CrewVersion' {
  It 'so theo số, thiếu đoạn = 0, hỗ trợ 15.1' {
    Compare-CrewVersion '0.172.0' '0.171.0' | Should Be 1
    Compare-CrewVersion '0.171.0' '0.171' | Should Be 0
    Compare-CrewVersion '2.1.99' '2.1.329' | Should Be -1
    Compare-CrewVersion '15.1' '15' | Should Be 1
    Compare-CrewVersion '16' '15.1' | Should Be 1
    Compare-CrewVersion '15' '15.1' | Should Be -1
    Compare-CrewVersion '15.10' '15.9' | Should Be 1
  }
  It 'chuỗi không hợp lệ -> $null' {
    $null -eq (Compare-CrewVersion 'v15' '15') | Should Be $true
    $null -eq (Compare-CrewVersion '' '15') | Should Be $true
  }
}

Describe 'bản agent đã kiểm' {
  BeforeEach {
    $script:fakeBin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:fakeBin | Out-Null
    $script:agentLog = Join-Path $script:fakeBin 'calls.log'
    $script:savedPath = $env:PATH
    $script:savedFile = $env:CREWLINE_AGENTS_FILE
    # PATH chỉ có CLI giả: máy có claude/codex thật cũng không bị gọi
    $env:PATH = $script:fakeBin
    $env:CREWLINE_AGENTS_FILE = Join-Path $script:fakeBin 'home/.crewline/agents.json'
  }
  AfterEach {
    $env:PATH = $script:savedPath
    $env:CREWLINE_AGENTS_FILE = $script:savedFile
  }
  It 'hằng số đã kiểm ở một chỗ, đúng dạng phiên bản' {
    $t = Get-CrewTestedAgents
    @($t.Keys | Sort-Object) -join ',' | Should Be 'claude,codex'
    foreach ($v in $t.Values) { $v | Should Match '^\d+(\.\d+)+$' }
  }
  It 'chưa có file: so với hằng số; mới hơn -> 1 dòng, cache theo ngày (gọi --version 1 lần)' {
    $tested = (Get-CrewTestedAgents).codex
    $newer = ($tested -split '\.')[0..1] -join '.'; $newer = "$newer.$([int](($tested -split '\.')[2]) + 1)"
    Set-FakeAgent 'codex' "codex-cli $newer"
    $global:LASTEXITCODE = 37
    Get-AgentVersionNotice 'codex' | Should Be "Codex $newer mới hơn bản Crewline này đã kiểm ($tested)"
    Get-AgentVersionNotice 'codex' | Should Be "Codex $newer mới hơn bản Crewline này đã kiểm ($tested)"
    @(Get-AgentCalls).Count | Should Be 1
    $data = Get-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Raw | ConvertFrom-Json
    $data.codex.version | Should Be $newer
    $data.codex.checkedAt | Should Be $today
    $global:LASTEXITCODE | Should Be 37   # không chạm LASTEXITCODE của người gọi
  }
  It 'bằng hoặc cũ hơn bản đã kiểm -> không báo; claude-code dùng chung khóa claude' {
    Set-FakeAgent 'claude' "$((Get-CrewTestedAgents).claude) (Claude Code)"
    Get-AgentVersionNotice 'claude-code' | Should Be ''
    Get-AgentVersionHint 'claude' | Should Be ''
    Set-FakeAgent 'codex' 'codex-cli 0.1.0'
    Get-AgentVersionNotice 'codex' | Should Be ''
  }
  It 'cache hôm qua -> đọc lại; cache hôm nay -> không gọi agent' {
    Set-FakeAgent 'claude' '99.0.0 (Claude Code)'
    New-Item -ItemType Directory -Force (Split-Path $env:CREWLINE_AGENTS_FILE) | Out-Null
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, (@{ claude = @{ version = '1.0.0'; checkedAt = '2000-01-01' } } | ConvertTo-Json))
    Get-AgentVersionNotice 'claude' | Should Match '^Claude Code 99\.0\.0 mới hơn'
    @(Get-AgentCalls).Count | Should Be 1
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, (@{ claude = @{ version = '1.0.0'; checkedAt = $today } } | ConvertTo-Json))
    Get-AgentVersionNotice 'claude' | Should Be ''
    @(Get-AgentCalls).Count | Should Be 1
  }
  It 'tested trong file lớn hơn hằng số -> dùng làm bản đã kiểm; nhỏ hơn -> bỏ qua' {
    New-Item -ItemType Directory -Force (Split-Path $env:CREWLINE_AGENTS_FILE) | Out-Null
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, (@{ codex = @{ version = '50.0.0'; checkedAt = $today; tested = '50.0.0' } } | ConvertTo-Json))
    Get-AgentVersionNotice 'codex' | Should Be ''
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, (@{ codex = @{ version = '50.0.0'; checkedAt = $today; tested = '0.0.1' } } | ConvertTo-Json))
    Get-AgentVersionNotice 'codex' | Should Be "Codex 50.0.0 mới hơn bản Crewline này đã kiểm ($((Get-CrewTestedAgents).codex))"
  }
  It 'không có lệnh agent -> im lặng, vẫn cache ngày để không dò lại' {
    Get-AgentVersionNotice 'codex' | Should Be ''
    (Get-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Raw | ConvertFrom-Json).codex.checkedAt | Should Be $today
  }
  It 'CLI treo -> trả trong ≤2.5s, coi như không biết bản (không cảnh báo), cache ngày kể cả hết giờ' {
    [IO.File]::WriteAllText((Join-Path $script:fakeBin 'codex.ps1'), "Add-Content -LiteralPath '$script:agentLog' -Value 'codex'`nStart-Sleep -Seconds 6`n'codex-cli 99.0.0'`n")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Get-AgentVersionNotice 'codex' | Should Be ''
    $sw.Stop()
    $sw.ElapsedMilliseconds -lt 2500 | Should Be $true
    $data = Get-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Raw | ConvertFrom-Json
    $data.codex.checkedAt | Should Be $today
    $data.codex.version | Should Be ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Get-AgentVersionNotice 'codex' | Should Be ''
    $sw.ElapsedMilliseconds -lt 500 | Should Be $true
  }
  It 'cùng thư mục có .cmd và .ps1 (npm trên Windows) -> chạy .cmd' -Skip:(-not $IsWindows) {
    Set-FakeAgent 'codex' 'codex-cli 0.0.1'
    [IO.File]::WriteAllText((Join-Path $script:fakeBin 'codex.cmd'), "@echo codex-cli 99.0.0`r`n")
    Get-AgentInstalledVersion 'codex' | Should Be '99.0.0'
    @(Get-AgentCalls).Count | Should Be 0
  }
  It 'đường dẫn .cmd có & ( ) dấu cách -> vẫn đọc được bản' -Skip:(-not $IsWindows) {
    $odd = Join-Path $script:fakeBin 'R&D (x) a b'
    New-Item -ItemType Directory $odd | Out-Null
    [IO.File]::WriteAllText((Join-Path $odd 'codex.cmd'), "@echo codex-cli 99.0.0`r`n")
    $env:PATH = $odd
    (Invoke-AgentVersionCommand 'codex').Trim() | Should Be 'codex-cli 99.0.0'
    Get-AgentInstalledVersion 'codex' | Should Be '99.0.0'
  }
  It 'file hỏng -> vẫn tính, không ghi đè byte' {
    Set-FakeAgent 'codex' 'codex-cli 99.0.0'
    New-Item -ItemType Directory -Force (Split-Path $env:CREWLINE_AGENTS_FILE) | Out-Null
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, '{ hong')
    Get-AgentVersionNotice 'codex' | Should Match '^Codex 99\.0\.0 mới hơn'
    [IO.File]::ReadAllText($env:CREWLINE_AGENTS_FILE) | Should BeExactly '{ hong'
  }
  It 'Get-AgentVersionHint: một bước Làm tiếp có lệnh cài; loại lạ -> rỗng' {
    Set-FakeAgent 'codex' 'codex-cli 99.0.0'
    $hint = Get-AgentVersionHint 'codex'
    $hint | Should Match '^Codex 99\.0\.0 mới hơn bản Crewline này đã kiểm'
    $hint | Should Match ([regex]::Escape("cập nhật Crewline ($(Get-CrewInstallCommand)) hoặc báo planner"))
    Get-AgentVersionHint 'shell' | Should Be ''
    Get-AgentVersionHint '' | Should Be ''
  }
  It 'Show-CrewAgentNotices: mỗi loại agent trong config 1 dòng, bỏ none, không lặp' {
    Set-FakeAgent 'codex' 'codex-cli 99.0.0'
    Set-FakeAgent 'claude' "$((Get-CrewTestedAgents).claude) (Claude Code)"
    $env:CREWLINE_NO_UPDATE_CHECK = '1'
    try {
      $out = Show-CrewAgentNotices ([pscustomobject]@{ planner = 'claude'; rev = 'none'; workers = @('codex', 'codex') }) 6>&1 | Out-String
    } finally { Remove-Item Env:CREWLINE_NO_UPDATE_CHECK }
    @([regex]::Matches($out, 'Codex 99\.0\.0 mới hơn bản Crewline này đã kiểm')).Count | Should Be 1
    $out | Should Match ([regex]::Escape("nếu crew không gửi được tin: cập nhật Crewline ($(Get-CrewInstallCommand)) hoặc báo planner"))
    $out | Should Not Match 'Claude Code'
  }
}

Describe 'kiểm Crewline public (không mạng)' {
  BeforeEach {
    $script:fetchUrls = @(); $script:fetchThrow = $false; $script:fetchText = "16`n"; $script:installedCrew = '15.1'
    $script:savedFile = $env:CREWLINE_AGENTS_FILE
    $env:CREWLINE_AGENTS_FILE = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))/agents.json"
    $script:savedNoCheck = $env:CREWLINE_NO_UPDATE_CHECK
    $env:CREWLINE_NO_UPDATE_CHECK = $null
  }
  AfterEach {
    $env:CREWLINE_AGENTS_FILE = $script:savedFile
    $env:CREWLINE_NO_UPDATE_CHECK = $script:savedNoCheck
  }
  It 'public mới hơn -> 1 dòng có lệnh cài; đọc VERSION raw.githubusercontent; 1 lần/ngày' {
    Get-CrewUpdateNotice | Should Be "Có Crewline v16: cập nhật bằng $(Get-CrewInstallCommand)"
    Get-CrewUpdateNotice | Should Be "Có Crewline v16: cập nhật bằng $(Get-CrewInstallCommand)"
    @($script:fetchUrls).Count | Should Be 1
    $script:fetchUrls[0] | Should Match '^https://raw\.githubusercontent\.com/.+/VERSION$'
    (Get-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Raw | ConvertFrom-Json).crewline.latest | Should Be '16'
  }
  It 'so dạng N.M: 15.1 đang cài, public 15.1 hoặc 15 -> không báo; 15.2 -> báo' {
    foreach ($case in @(@('15.1', ''), @('15', ''), @('15.2', 'v15.2'))) {
      Remove-Item -LiteralPath $env:CREWLINE_AGENTS_FILE -ErrorAction SilentlyContinue
      $script:fetchText = $case[0]
      $n = Get-CrewUpdateNotice
      if ($case[1]) { $n | Should Match ([regex]::Escape("Có Crewline $($case[1]):")) } else { $n | Should Be '' }
    }
  }
  It 'CREWLINE_NO_UPDATE_CHECK=1 -> không gọi mạng, không ghi file' {
    $env:CREWLINE_NO_UPDATE_CHECK = '1'
    Get-CrewUpdateNotice | Should Be ''
    @($script:fetchUrls).Count | Should Be 0
    Test-Path -LiteralPath $env:CREWLINE_AGENTS_FILE | Should Be $false
  }
  It 'lỗi mạng hoặc nội dung lạ -> im lặng, cache ngày (không thử lại trong ngày)' {
    $script:fetchThrow = $true
    Get-CrewUpdateNotice | Should Be ''
    Get-CrewUpdateNotice | Should Be ''
    @($script:fetchUrls).Count | Should Be 1
    Remove-Item -LiteralPath $env:CREWLINE_AGENTS_FILE
    $script:fetchThrow = $false; $script:fetchText = '<html>404</html>'
    Get-CrewUpdateNotice | Should Be ''
  }
  It 'bản đang cài không rõ (v?) -> không kiểm' {
    $script:installedCrew = '?'
    Get-CrewUpdateNotice | Should Be ''
    @($script:fetchUrls).Count | Should Be 0
  }
  It 'giữ mục agent khác trong file khi ghi cache crewline' {
    New-Item -ItemType Directory -Force (Split-Path $env:CREWLINE_AGENTS_FILE) | Out-Null
    [IO.File]::WriteAllText($env:CREWLINE_AGENTS_FILE, (@{ codex = @{ version = '0.171.0'; checkedAt = $today; tested = '0.172.0' } } | ConvertTo-Json))
    $null = Get-CrewUpdateNotice
    $data = Get-Content -LiteralPath $env:CREWLINE_AGENTS_FILE -Raw | ConvertFrom-Json
    $data.codex.tested | Should Be '0.172.0'
    $data.crewline.checkedAt | Should Be $today
  }
}

Describe 'lỗi gửi tin thêm gợi ý cập nhật Crewline' {
  $sendFns = 'Get-ScreenRows', 'Find-PromptBox', 'Test-SameScreenRow', 'Compare-PasteScreens', 'Get-SendBox', 'Get-InputBox', 'Get-ScreenDialog',
    'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Test-SentInput', 'Send-CodexQueue', 'Test-SessionReady', 'Send-CrewMessage'
  foreach ($fn in $sendFns) { . ([scriptblock]::Create((Get-CrewFunction $fn).Extent.Text)) }
  function Say($m) { }
  function Die($m, $n = '') { $script:dieNext = @($n); throw "DIE: $m" }
  function Get-AgentVersionHint([string]$kind) { $script:hintKinds += @($kind); if ($script:hint) { "$script:hint ($kind)" } else { '' } }
  function New-Ops($screens, [string]$sendJson = '{"started":false}') {
    $st = @{ Screens = @($screens); Ri = 0 }
    @{
      Get   = { param($t) [pscustomobject]@{ name = 't'; state = 'live'; status = [pscustomobject]@{ app = 'codex'; state = 'idle' }; turn = 3 } }
      Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
      Send  = { param($t, $x, $raw) @{ Code = 0; Text = $sendJson } }.GetNewClosure()
      Keys  = { param($t) throw 'không được bấm Enter' }
      Tab   = { param($t) throw 'không được bấm Tab' }
      Sleep = { param($ms) }
    }
  }
  $fixture = { param($n) ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/codex-v0.166/$n.txt")) -replace "`r`n", "`n").TrimEnd("`n") }
  $session = & $fixture 'new-session'
  $drawing = & $fixture 'new-session-drawing'
  BeforeEach { $script:dieNext = @(); $script:hintKinds = @(); $script:hint = 'GỢI Ý' }
  It 'chưa hiện ô nhập sẵn sàng: thêm gợi ý vào Làm tiếp (theo app của terminal)' {
    { Send-CrewMessage 'x-w1' 'tin' $false '' (New-Ops @($drawing)) } | Should Throw 'chưa hiện ô nhập sẵn sàng'
    $script:dieNext[0] | Should Match 'hc read x-w1'
    ($script:dieNext -contains 'GỢI Ý (codex)') | Should Be $true
  }
  It 'sau gửi không nhận ra ô nhập: giữ bước cũ, thêm gợi ý' {
    { Send-CrewMessage 'x-w1' 'tin' $false '' (New-Ops @($session, $drawing)) } | Should Throw 'không nhận ra ô nhập Codex'
    $script:dieNext[0] | Should Match 'sang pane x-w1'
    ($script:dieNext -contains 'GỢI Ý (codex)') | Should Be $true
  }
  It 'agent không mới hơn: gợi ý rỗng, Làm tiếp như cũ' {
    $script:hint = ''
    { Send-CrewMessage 'x-w1' 'tin' $false '' (New-Ops @($drawing)) } | Should Throw 'chưa hiện ô nhập sẵn sàng'
    @($script:dieNext | Where-Object { $_ }).Count | Should Be 1
  }
  It 'crew task: lỗi gửi việc gọi gợi ý theo loại agent của worker' {
    $text = (Get-CrewFunction 'Invoke-Task').Extent.Text
    $text | Should Match ([regex]::Escape('$(try { Get-AgentVersionHint $kind } catch { '''' })'))
  }
}
