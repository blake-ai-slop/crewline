. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($shared in 'Get-CrewStateSchema', 'Read-CrewState', 'Get-CrewVersion', 'Show-CrewUpgradeWarning', 'Get-SkeletonVersion') { . ([scriptblock]::Create((Get-CrewFunction $shared).Extent.Text)) }
. "$PSScriptRoot/TestHome.ps1"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# crew queue: hàm của scripts/crew/queue.ps1 trích bằng AST, ops giả (không hc, không spawn) cho Invoke-QueueRun;
# e2e chạy crew.ps1 thật (queue -Run ⇒ tiến trình con crew task thật, clean, hot) với hc/herdr-app giả trong HOME giả.
$repo = Split-Path $PSScriptRoot -Parent
$crewScript = Join-Path $repo 'scripts/crew.ps1'
$queueFile = Join-Path $repo 'scripts/crew/queue.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

$queueAst = [System.Management.Automation.Language.Parser]::ParseFile($queueFile, [ref]$null, [ref]$null)
foreach ($fn in $queueAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-Tasks', 'Save-Tasks', 'Update-Tasks', 'Write-CrewStateFile', 'Use-CrewStateLock', 'Get-LimitTiers', 'Get-LimitLevel', 'Get-WorkerTree', 'Invoke-GitQuiet', 'Get-MainRoot', 'Get-PromptScope', 'Get-ScopeConflicts' } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$script:Said = [Collections.Generic.List[string]]::new()
function Say($msg) { $script:Said.Add([string]$msg) }
function Die($msg) { throw "DIE: $msg" }
function hc { throw 'gọi hc thật trong test' }

function New-QueueRoot([string[]]$workers = @('claude', 'codex')) {
  $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force (Join-Path $root '.crew/queue') | Out-Null
  ConvertTo-Json -InputObject ([ordered]@{ workers = $workers }) | Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
  $root
}
function Add-Q([string]$root, [string]$name, [int]$worker = 0, [string]$after = '', [string]$size = 'M', [string]$review = '') {
  "Được sửa: ``$name.ps1``" | Set-Content (Get-QueuePromptPath $root $name) -Encoding utf8
  Save-QueueItems $root (@(Get-QueueItems $root) + (New-QueueItem $name ".crew/queue/$name.md" $worker $review $after $size))
}
function Add-T([string]$root, [string]$name, [int]$worker) {
  Save-Tasks $root (@(Get-Tasks $root) + [pscustomobject]@{ name = $name; worker = $worker; worktree = '' })
}
# Ops giả: Spawn ghi task như crew task thật (hoặc lỗi theo $fail), Limit trả % theo loại agent.
function New-FakeOps($limits = @{}, [string]$fail = '') {
  $log = @{ Spawn = [Collections.Generic.List[object]]::new(); Limit = [Collections.Generic.List[string]]::new() }
  $ops = @{
    Log = $log
    Limit = { param($kind) $log.Limit.Add($kind); $limits[$kind] }.GetNewClosure()
    Spawn = {
      param($root, [string[]]$argv)
      $log.Spawn.Add(@($argv))
      if ($fail) { return @{ Code = 1; Text = "crew: phiên mới`ncrew: LỖI: $fail`n  Task …" } }
      $w = [int]$argv[[array]::IndexOf($argv, '-Worker') + 1]
      $f = Join-Path $root '.crew/tasks.json'
      $list = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ } })
      $list += [pscustomobject]@{ name = $argv[1]; worker = $w; worktree = '' }
      ConvertTo-Json -InputObject @($list) | Set-Content $f -Encoding utf8
      @{ Code = 0; Text = 'ok' }
    }.GetNewClosure()
  }
  $ops
}
function Get-Names($root) { @(Get-QueueItems $root | ForEach-Object { $_.name }) -join ',' }

Describe 'Invoke-QueueRun (ops giả)' {
  BeforeEach { $script:Said.Clear() }

  It 'hàng đợi trống: gọi tay in "hàng đợi trống", tự động im lặng, không hỏi limit' {
    $root = New-QueueRoot
    $ops = New-FakeOps
    Invoke-QueueRun $root $false $true $ops | Should Be 0
    ($script:Said -join "`n") | Should Be 'hàng đợi trống'
    $script:Said.Clear()
    Invoke-QueueRun $root $false $false $ops | Should Be 0
    $script:Said.Count | Should Be 0
    $ops.Log.Limit.Count | Should Be 0
  }

  It 'giao theo thứ tự vào worker rảnh bằng crew task con; xóa khỏi hàng đợi và xóa prompt chép' {
    $root = New-QueueRoot
    Add-Q $root 'a'; Add-Q $root 'b' -review 'fast'; Add-Q $root 'c'
    $ops = New-FakeOps
    Invoke-QueueRun $root $false $true $ops | Should Be 2
    $ops.Log.Spawn.Count | Should Be 2
    ($ops.Log.Spawn[0] -join ' ') | Should Be "task a $(Get-QueuePromptPath $root 'a') -Worker 1"
    ($ops.Log.Spawn[1] -join ' ') | Should Be "task b $(Get-QueuePromptPath $root 'b') -Worker 2 -Review fast"
    Get-Names $root | Should Be 'c'
    Test-Path (Get-QueuePromptPath $root 'a') | Should Be $false
    Test-Path (Get-QueuePromptPath $root 'c') | Should Be $true
    $script:Said -contains 'a: đã giao → w1' | Should Be $true
    $script:Said -contains 'b: đã giao → w2' | Should Be $true
    $script:Said -contains 'c: giữ: không có worker rảnh' | Should Be $true
    (Get-QueueItems $root)[0].hold | Should Be 'không có worker rảnh'
  }

  It '-After: giữ khi task còn trong tasks.json hoặc còn trong hàng đợi (kể cả đứng sau); task không còn ⇒ giao' {
    $root = New-QueueRoot @('claude', 'codex', 'claude')
    Add-T $root 'dang' 3
    Add-Q $root 'x' -after 'dang'; Add-Q $root 'y' -after 'z'; Add-Q $root 'z'; Add-Q $root 'w' -after 'xong-roi'
    $ops = New-FakeOps
    Invoke-QueueRun $root $false $true $ops | Should Be 2
    Get-Names $root | Should Be 'x,y'
    $script:Said -contains 'x: giữ: chờ task dang xong' | Should Be $true
    $script:Said -contains 'y: giữ: chờ z (còn trong hàng đợi)' | Should Be $true
    $script:Said -contains 'z: đã giao → w1' | Should Be $true
    $script:Said -contains 'w: đã giao → w2' | Should Be $true
  }

  It 'mục giao trước trong cùng lần chạy chặn mục -After nó' {
    $root = New-QueueRoot
    Add-Q $root 'a'; Add-Q $root 'b' -after 'a'
    Invoke-QueueRun $root $false $true (New-FakeOps) | Should Be 1
    $script:Said -contains 'b: giữ: chờ task a xong' | Should Be $true
  }

  It 'trùng file với task đang chạy (Get-ScopeConflicts thật) ⇒ giữ, nêu task và cặp mẫu' {
    $root = New-QueueRoot
    $wt = Join-Path $root 'wt-cu'
    New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
    'Được sửa: `scripts/`, `context/tasks/cu.md`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding utf8
    Save-Tasks $root @([pscustomobject]@{ name = 'cu'; worker = 1; worktree = $wt })
    Add-Q $root 'moi'
    'Được sửa: `scripts\a.ps1`, `context/tasks/moi.md`' | Set-Content (Get-QueuePromptPath $root 'moi') -Encoding utf8
    $ops = New-FakeOps
    Invoke-QueueRun $root $false $true $ops | Should Be 0
    $script:Said -contains 'moi: giữ: trùng file với cu (scripts/a.ps1 ~ scripts/)' | Should Be $true
    $ops.Log.Spawn.Count | Should Be 0
    $ops.Log.Limit.Count | Should Be 0
  }

  It '-Worker: chỉ giao đúng worker đó; bận ⇒ giữ, không lấy worker khác' {
    $root = New-QueueRoot
    Add-T $root 'cu' 2
    Add-Q $root 'a' -worker 2; Add-Q $root 'b' -worker 1
    $ops = New-FakeOps
    Invoke-QueueRun $root $false $true $ops | Should Be 1
    $script:Said -contains 'a: giữ: w2 đang bận' | Should Be $true
    ($ops.Log.Spawn[0] -join ' ') | Should Match '^task b .* -Worker 1$'
  }

  It 'limit: hạn chế ⇒ không giao L nhưng giao M; dừng ⇒ không giao; không rõ ⇒ giao; mỗi loại agent hỏi một lần' {
    $root = New-QueueRoot @('claude', 'claude')
    Add-Q $root 'lon' -size 'L'; Add-Q $root 'vua'; Add-Q $root 'nho' -size 'S'
    $ops = New-FakeOps @{ claude = 75 }
    Invoke-QueueRun $root $false $true $ops | Should Be 2
    $script:Said -contains 'lon: giữ: w1: limit claude 75% (hạn chế, không giao size L); w2: limit claude 75% (hạn chế, không giao size L)' | Should Be $true
    $script:Said -contains 'vua: đã giao → w1' | Should Be $true
    $script:Said -contains 'nho: đã giao → w2' | Should Be $true
    ($ops.Log.Limit -join ',') | Should Be 'claude'
    # codex không hỏi được (null) ⇒ vẫn giao size L
    $root = New-QueueRoot @('codex')
    Add-Q $root 'lon' -size 'L'
    Invoke-QueueRun $root $false $true (New-FakeOps @{ codex = $null }) | Should Be 1
  }

  It 'limit L: worker claude hạn chế bị bỏ qua, chọn worker codex rảnh' {
    $root = New-QueueRoot @('claude', 'codex')
    Add-Q $root 'lon' -size 'L'
    $ops = New-FakeOps @{ claude = 80; codex = 10 }
    Invoke-QueueRun $root $false $true $ops | Should Be 1
    $script:Said -contains 'lon: đã giao → w2' | Should Be $true
    ($ops.Log.Limit -join ',') | Should Be 'claude,codex'
  }

  It 'limit dừng ở mọi worker rảnh ⇒ giữ với lý do từng worker; giữ lý do lần chạy gần nhất' {
    $root = New-QueueRoot @('claude', 'codex')
    Add-Q $root 'a'; Add-Q $root 'b'
    $ops = New-FakeOps @{ claude = 95; codex = 92 }
    Invoke-QueueRun $root $false $true $ops | Should Be 0
    $script:Said -contains 'a: giữ: w1: limit claude 95% (dừng); w2: limit codex 92% (dừng)' | Should Be $true
    ($ops.Log.Limit -join ',') | Should Be 'claude,codex'
    (Get-QueueItems $root)[1].hold | Should Match 'limit claude 95% \(dừng\)'
  }

  It 'không có mục sắp giao ⇒ không hỏi limit' {
    $root = New-QueueRoot @('claude')
    Add-T $root 'cu' 1
    Add-Q $root 'a'
    $ops = New-FakeOps @{ claude = 10 }
    Invoke-QueueRun $root $false $true $ops | Out-Null
    $ops.Log.Limit.Count | Should Be 0
  }

  It 'crew task con lỗi ⇒ giữ mục, ghi lý do LỖI, dừng giao tiếp (không thử worker khác, không giao mục sau)' {
    $root = New-QueueRoot
    Add-Q $root 'a'; Add-Q $root 'b'
    $ops = New-FakeOps @{} 'w1 đang chờ duyệt'
    Invoke-QueueRun $root $false $true $ops | Should Be 0
    $ops.Log.Spawn.Count | Should Be 1
    Get-Names $root | Should Be 'a,b'
    (Get-QueueItems $root)[0].hold | Should Be 'crew task lỗi: w1 đang chờ duyệt'
    Test-Path (Get-QueuePromptPath $root 'a') | Should Be $true
    $script:Said -contains 'a: giữ: crew task lỗi: w1 đang chờ duyệt' | Should Be $true
    @($script:Said | Where-Object { $_ -like 'b:*' }).Count | Should Be 0
  }

  It '-DryRun: không spawn, không ghi file, mô phỏng worker bận cho mục sau' {
    $root = New-QueueRoot @('claude')
    Add-Q $root 'a'; Add-Q $root 'b'; Add-Q $root 'c' -after 'a'
    $before = Get-Content (Get-QueueFile $root) -Raw
    $ops = New-FakeOps
    Invoke-QueueRun $root $true $true $ops | Should Be 0
    $ops.Log.Spawn.Count | Should Be 0
    (Get-Content (Get-QueueFile $root) -Raw) | Should Be $before
    $script:Said -contains 'a: sẽ giao → w1' | Should Be $true
    $script:Said -contains 'b: giữ: không có worker rảnh' | Should Be $true
    $script:Said -contains 'c: giữ: chờ task a xong' | Should Be $true
  }

  It '-DryRun xét scope của các mục sẽ giao cùng lượt; không ghi queue, prompt hay log' {
    $root = New-QueueRoot @('claude', 'codex')
    Add-Q $root 'a'; Add-Q $root 'b'; Add-Q $root 'c'
    'Được sửa: `src/`' | Set-Content (Get-QueuePromptPath $root 'a') -Encoding utf8
    'Được sửa: `src/a.ps1`' | Set-Content (Get-QueuePromptPath $root 'b') -Encoding utf8
    $before = Get-Content (Get-QueueFile $root) -Raw
    $ops = New-FakeOps
    Invoke-QueueRun $root $true $true $ops | Should Be 0
    $script:Said -contains 'a: sẽ giao → w1' | Should Be $true
    ($script:Said -join "`n") | Should Match 'b: giữ: trùng file với a'
    $script:Said -contains 'c: sẽ giao → w2' | Should Be $true
    $ops.Log.Spawn.Count | Should Be 0
    (Get-Content (Get-QueueFile $root) -Raw) | Should Be $before
    Test-Path (Get-QueuePromptPath $root 'a') | Should Be $true
    Test-Path (Join-Path $root '.crew/queue.log') | Should Be $false
  }

  It 'log lượt thật ghi nguồn, từng mục và chỉ giữ 200 dòng mới; list hiện lần gần nhất cả khi trống' {
    $root = New-QueueRoot @('claude')
    Add-Q $root 'a'; Add-Q $root 'b'
    $file = Join-Path $root '.crew/queue.log'
    1..205 | Set-Content $file
    Invoke-QueueRun $root $false $false (New-FakeOps) 'up' | Should Be 1
    $lines = @(Get-Content $file -Encoding utf8)
    $lines.Count | Should Be 200
    $lines[-3] | Should Match '^== \d{4}-.* \(up\)$'
    $lines[-2] | Should Be 'a: đã giao → w1'
    $lines[-1] | Should Be 'b: giữ: không có worker rảnh'
    $before = Get-Content $file -Raw
    Invoke-QueueRun $root $true $true (New-FakeOps) | Should Be 0
    (Get-Content $file -Raw) | Should Be $before
    Save-QueueItems $root @()
    $script:Said.Clear()
    Show-Queue $root
    $script:Said[0] | Should Match 'lần chạy gần nhất: .* \(up\) — xem \.crew/queue.log'
    $script:Said[1] | Should Be 'hàng đợi trống'
    Invoke-QueueRun $root $false $false (New-FakeOps) 'clean' | Should Be 0
    @(Get-Content $file)[-1] | Should Match '\(clean\)$'
  }

  It 'lượt log quá 200 dòng vẫn giữ tiêu đề mới nhất và đếm theo dòng thực' {
    $root = New-QueueRoot
    $block = @('== 2026-11-17T10:00:00 (run)') + @(1..210 | ForEach-Object { "giữ: $_`nchi tiết" })
    Write-QueueLog $root $block
    $lines = @(Get-Content (Join-Path $root '.crew/queue.log'))
    $lines.Count | Should Be 200
    $lines[0] | Should Be '== 2026-11-17T10:00:00 (run)'
    $lines[-1] | Should Be 'chi tiết'
  }

  It 'log ghi mục lỗi và các mục còn lại bị giữ sau lỗi' {
    $root = New-QueueRoot
    Add-Q $root 'a'; Add-Q $root 'b'
    Invoke-QueueRun $root $false $true (New-FakeOps @{} 'terminal lỗi') | Should Be 0
    $text = Get-Content (Join-Path $root '.crew/queue.log') -Raw -Encoding utf8
    $text | Should Match '\(run\)'
    $text | Should Match 'a: giữ: crew task lỗi: terminal lỗi'
    $text | Should Match 'b: giữ: dừng giao tiếp vì crew task lỗi'
  }

  It 'thiếu prompt chép ⇒ giữ, nêu đường dẫn' {
    $root = New-QueueRoot
    Add-Q $root 'a'
    Remove-Item (Get-QueuePromptPath $root 'a')
    Invoke-QueueRun $root $false $true (New-FakeOps) | Should Be 0
    $script:Said[0] | Should Match '^a: giữ: thiếu prompt '
  }
}

Describe 'Test-QueueSourceNewer' {
  It 'mục cũ không source, thiếu file gốc/bản chép, cùng giờ hoặc chỉ touch ⇒ false; gốc sửa sau ⇒ true' {
    $root = New-QueueRoot
    $src = Join-Path $root 'p.md'; 'v1' | Set-Content $src -Encoding utf8
    Add-Q $root 'a'
    Copy-Item $src (Get-QueuePromptPath $root 'a') -Force
    Test-QueueSourceNewer $root ([pscustomobject]@{ name = 'a' }) | Should Be $false
    $item = [pscustomobject]@{ name = 'a'; source = $src }
    (Get-Item $src).LastWriteTimeUtc = (Get-Item (Get-QueuePromptPath $root 'a')).LastWriteTimeUtc
    Test-QueueSourceNewer $root $item | Should Be $false
    (Get-Item $src).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
    Test-QueueSourceNewer $root $item | Should Be $false
    'v2' | Set-Content $src -Encoding utf8
    (Get-Item $src).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
    Test-QueueSourceNewer $root $item | Should Be $true
    Remove-Item (Get-QueuePromptPath $root 'a')
    Test-QueueSourceNewer $root $item | Should Be $false
    $item.source = (Join-Path $root 'khong-co.md')
    Test-QueueSourceNewer $root $item | Should Be $false
  }
}

Describe 'Get-QueueLimitHold / Get-QueueSpawnError (thuần)' {
  It 'theo mốc Get-LimitTiers' {
    Get-QueueLimitHold 'claude' $null 'L' | Should Be ''
    Get-QueueLimitHold 'claude' 69 'L' | Should Be ''
    Get-QueueLimitHold 'claude' 70 'M' | Should Be ''
    Get-QueueLimitHold 'claude' 70 'L' | Should Be 'limit claude 70% (hạn chế, không giao size L)'
    Get-QueueLimitHold 'codex' 90 'S' | Should Be 'limit codex 90% (dừng)'
  }
  It 'lấy dòng LỖI đầu, không có thì dòng cuối' {
    Get-QueueSpawnError "a`ncrew: LỖI: x hỏng`ncrew: LỖI: y" | Should Be 'x hỏng'
    Get-QueueSpawnError "a`nb`n" | Should Be 'b'
    Get-QueueSpawnError '' | Should Be 'crew task lỗi, không có thông báo'
  }
}

Describe 'Invoke-QueueAuto' {
  BeforeEach { $script:Said.Clear() }
  It 'không có queue.json ⇒ im lặng; queue.json hỏng ⇒ chỉ cảnh báo, không ném lỗi' {
    $root = New-QueueRoot
    git -C $root init -q 2>$null
    { Invoke-QueueAuto $root } | Should Not Throw
    $script:Said.Count | Should Be 0
    'không phải json' | Set-Content (Get-QueueFile $root)
    { Invoke-QueueAuto $root } | Should Not Throw
    { Invoke-QueueAuto (Join-Path $TestDrive 'khong-co') } | Should Not Throw
  }
  It 'lỗi đọc queue/config/tasks chỉ cảnh báo, giữ exit code lệnh chính với Die thật' {
    $h = New-CrewTestHome
    foreach ($name in 'queue', 'config', 'tasks') {
      foreach ($bad in '{broken', '{"schema":99}') {
        $root = New-QueueRoot
        Add-Q $root 'waiting'
        $file = Join-Path $root ".crew/$name.json"
        [IO.File]::WriteAllText($file, $bad)
        $before = (Get-FileHash $file).Hash
        $defs = @('Die','Get-CrewStateSchema','Read-CrewState','Get-Tasks','Get-QueueFile','Get-QueueItems','Read-QueueConfig','Invoke-QueueRun','Write-QueueLog','Invoke-QueueAuto') | ForEach-Object { (Get-CrewFunction $_).Extent.Text }
        $body = ($defs -join "`n") + @"
function Get-MainRoot(`$at) { '$($root.Replace("'", "''"))' }
function New-QueueOps { return @{ Limit = {}; Spawn = {} } }
`$global:LASTEXITCODE = 7
Invoke-QueueAuto '$($root.Replace("'", "''"))'
Write-Host "MAIN CONTINUES `$global:LASTEXITCODE"
exit `$global:LASTEXITCODE
"@
        $scriptFile = Join-Path $TestDrive 'queue-auto-state.ps1'
        [IO.File]::WriteAllText($scriptFile, $body, [Text.UTF8Encoding]::new($true))
        $r = Invoke-InTestHome -TestHome $h -File $scriptFile
        $r.ExitCode | Should Be 7
        $r.Output | Should Match 'crew: CẢNH BÁO: hàng đợi:'
        $r.Output | Should Match "$name.json"
        $r.Output | Should Match 'MAIN CONTINUES 7'
        $r.Output | Should Not Match 'crew: LỖI:'
        (Get-FileHash $file).Hash | Should Be $before
      }
    }
  }

}

Describe 'nối vào crew.ps1, clean, up, hot (AST)' {
  $entry = @(Get-CrewAsts)[0]
  $dispatch = $entry.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -Last 1
  $clause = { param($name) @($dispatch.Clauses | Where-Object { $_.Item1.Value -eq $name })[0].Item2.Extent.Text }

  It 'param có After/Size/Run/Remove; loader nạp queue ngay sau task; dispatch queue' {
    $params = @(Get-CrewParamNames)
    foreach ($p in 'After', 'Size', 'Run', 'Remove') { $params -contains $p | Should Be $true }
    $text = [IO.File]::ReadAllText($crewScript)
    $text | Should Match "'task', 'queue',"
    (& $clause 'queue') | Should Be '{ Invoke-Queue }'
  }

  It 'cuối Invoke-Clean gọi Invoke-QueueAuto; Invoke-Hot in dòng hàng đợi ở cuối' {
    $clean = (Get-CrewFunction 'Invoke-Clean').Body.EndBlock.Statements
    $clean[-1].Extent.Text | Should Be 'Invoke-QueueAuto $root'
    $hot = (Get-CrewFunction 'Invoke-Hot').Body.EndBlock.Statements
    $hot[-1].Extent.Text | Should Match '== hàng đợi: '
  }

  # Chạy đúng nhánh dispatch 'up' trong pwsh con với Recover và tự giao giả (không gọi CLI agent/hc).
  $runUp = {
    param([string]$flags, [string]$child = '', [string]$recover = 'exit 1')
    $body = (& $clause 'up').Trim().TrimStart('{').TrimEnd('}')
    $script = @"
function Get-MainRoot(`$p) { return `$null }
function Invoke-Recover(`$x) { Write-Host 'RECOVER'; $recover }
function Invoke-Up { Write-Host 'UP' }
function Invoke-UpAll { Write-Host 'UPALL' }
function Invoke-QueueAuto(`$p, `$source) { Write-Host "AUTO `$p `$source" }
`$Path = '.'; `$All = `$false; `$Restart = ''; `$DryRun = `$false
$flags
`$env:CREWLINE_UP_ALL_CHILD = '$child'
$body
exit 0
"@
    $f = Join-Path $TestDrive "up-$([guid]::NewGuid().ToString('N').Substring(0, 6)).ps1"
    [IO.File]::WriteAllText($f, $script, [Text.UTF8Encoding]::new($true))
    $out = & pwsh -NoProfile -File $f 2>&1 | ForEach-Object { "$_" }
    @{ Code = $LASTEXITCODE; Text = $out -join "`n" }
  }

  It 'crew up lỗi: không tự giao và giữ exit code' {
    $r = & $runUp '& pwsh -NoProfile -Command ''exit 9'''
    $r.Text | Should Be 'RECOVER'
    $r.Code | Should Be 1
  }
  It 'native trước đó lỗi, Recover trả về bình thường ⇒ thoát 0 và tự giao' {
    $r = & $runUp '& pwsh -NoProfile -Command ''exit 9''; if ($LASTEXITCODE -ne 9) { throw ''native phải trả 9'' }' '' 'return'
    $r.Text | Should Be "RECOVER`nAUTO . up"
    $r.Code | Should Be 0
  }
  It 'crew up thành công mới tự giao, giữ exit 0 kể cả LASTEXITCODE cũ khác 0' {
    $r = & $runUp '$global:LASTEXITCODE = 9' '' 'exit 0'
    $r.Text | Should Be "RECOVER`nAUTO . up"
    $r.Code | Should Be 0
    (& $runUp '' '' 'exit 7').Code | Should Be 7
    (& $runUp '' '' 'exit 7').Text | Should Be 'RECOVER'
  }
  It 'crew up Recover throw: không tự giao' {
    $r = & $runUp '' '' "throw 'recover failed'"
    $r.Code | Should Be 1
    $r.Text | Should Not Match 'AUTO'
  }
  It 'crew up -DryRun / -Restart / -All / con của -All: không tự giao' {
    (& $runUp '$DryRun = $true' '' 'exit 0').Text | Should Be 'RECOVER'
    (& $runUp '$Restart = ''w1''').Text | Should Be 'UP'
    (& $runUp '$All = $true').Text | Should Be 'UPALL'
    (& $runUp '' '1' 'exit 0').Text | Should Be 'RECOVER'
  }
}

# ---------------- e2e: crew.ps1 thật, HOME giả, hc/herdr-app giả ----------------
# hc giả: terminal từ terminals.json; send ghi sends.log và trả started:true; read trả rỗng.
$FakeHc = @'
#!/usr/bin/env pwsh
$dir = $env:FAKE_HC_DIR
$file = Join-Path $dir 'terminals.json'
$terms = @(if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json | ForEach-Object { $_ } })
switch ($args[0]) {
  'ls' { ConvertTo-Json -InputObject ([ordered]@{ terminals = @($terms) }) -Depth 6; exit 0 }
  'get' {
    $key = $args[1]
    $t = $terms | Where-Object { $_.name -eq $key -or $_.address -eq $key } | Select-Object -First 1
    if (-not $t) { exit 1 }
    $t | ConvertTo-Json -Depth 6; exit 0
  }
  'send' { Add-Content -LiteralPath (Join-Path $dir 'sends.log') -Value "$($args[1]) $($args[2])" -Encoding utf8; '{"started":true}'; exit 0 }
  default { exit 0 }
}
'@
$FakeHerdr = @'
#!/usr/bin/env pwsh
if ($args[0] -eq 'ls') { '{"spaces":[]}' }
exit 0
'@
# claude/codex giả: crew queue -Run hỏi limit qua New-QueueOps thật ⇒ không được chạm CLI agent thật (PITFALLS).
# Trả % 5h cố định (FAKE_CLAUDE_USED / FAKE_CODEX_USED, mặc định 12) và ghi mỗi lần gọi vào limits.log.
$FakeClaude = @'
#!/usr/bin/env pwsh
Add-Content -LiteralPath (Join-Path $env:FAKE_HC_DIR 'limits.log') -Value "claude $($args -join ' ')" -Encoding utf8
if ($args[0] -ne '-p' -or $args[1] -ne '/usage') { exit 2 }
$used = if ($env:FAKE_CLAUDE_USED) { $env:FAKE_CLAUDE_USED } else { '12' }
[ordered]@{ type = 'result'; is_error = $false; num_turns = 0; result = "Current session: $used% used`nCurrent week (all models): 30% used" } | ConvertTo-Json -Compress
exit 0
'@
$FakeCodex = @'
#!/usr/bin/env pwsh
Add-Content -LiteralPath (Join-Path $env:FAKE_HC_DIR 'limits.log') -Value "codex $($args -join ' ')" -Encoding utf8
if ($args[0] -ne 'app-server') { exit 2 }
$used = if ($env:FAKE_CODEX_USED) { [int]$env:FAKE_CODEX_USED } else { 12 }
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $msg = try { $line | ConvertFrom-Json } catch { continue }
  if ($msg.id -eq 1) { '{"id":1,"result":{}}'; [Console]::Out.Flush() }
  elseif ($msg.id -eq 2) {
    $limits = [ordered]@{ primary = [ordered]@{ usedPercent = $used; windowDurationMins = 300; resetsAt = 1900000000 }; secondary = [ordered]@{ usedPercent = 30; windowDurationMins = 10080; resetsAt = 1900000000 } }
    [ordered]@{ id = 2; result = [ordered]@{ rateLimits = $limits } } | ConvertTo-Json -Depth 5 -Compress; [Console]::Out.Flush(); exit 0
  }
}
exit 0
'@

function New-E2E {
  $h = New-CrewTestHome
  [IO.File]::WriteAllText((Join-Path $h.Home 'gitconfig'), "[user]`n`tname = t`n`temail = t@t`n[core]`n`tautocrlf = false`n")
  $bin = Join-Path $h.Home 'fakebin'; $state = Join-Path $h.Home 'fakestate'
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr), @('claude', $FakeClaude), @('codex', $FakeCodex))) {
    $file = Join-Path $bin $(if ($OnWindows) { "$($pair[0]).ps1" } else { $pair[0] })
    [IO.File]::WriteAllText($file, ($pair[1] -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    if (-not $OnWindows) { & chmod +x $file }
  }
  $path = "$bin$([IO.Path]::PathSeparator)$env:PATH"
  $saved = $env:PATH
  try {
    $env:PATH = $path
    foreach ($c in 'hc', 'herdr-app', 'claude', 'codex') {
      $src = (Get-Command $c -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1).Source
      if (-not $src.StartsWith($bin)) { throw "PATH test trỏ tới $c thật: $src" }
    }
  } finally { $env:PATH = $saved }
  $root = Join-Path $h.Home 'proj'
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path $root).Path
  git -C $root init -q -b main
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  git -C $root add -A; git -C $root -c user.name=t -c user.email=t@t commit -qm init
  ConvertTo-Json -InputObject ([ordered]@{ name = 'qt'; idKey = 'qt'; planner = 'none'; workers = @('claude'); rev = 'none'; review = 'lean'; access = 'work' }) |
    Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
  # w1 là shell trống (không app) trong worktree cố định ⇒ crew task bật agent bằng một lệnh gửi.
  $wt = Join-Path $root '.crew/worktrees/w1'
  ConvertTo-Json -InputObject @([ordered]@{ name = 'qt-w1'; address = 't1'; state = 'live'; cwd = $wt; turn = 1 }) | Set-Content (Join-Path $state 'terminals.json') -Encoding utf8
  @{ Home = $h; Root = $root; State = $state; Wt = $wt; Script = $crewScript
    Env = @{ PATH = $path; FAKE_HC_DIR = $state; HC_SESSION = "crew-test-$([guid]::NewGuid().ToString('N'))"; HC_TERMINAL_ID = $null; HC_TERMINAL_SOCKET = $null; CREWLINE_UP_ALL_CHILD = $null; FAKE_CLAUDE_USED = $null; FAKE_CODEX_USED = $null } }
}
function Run-Crew($c, [string[]]$argv) {
  $r = Invoke-InTestHome -TestHome $c.Home -File $c.Script -Arguments $argv -Env $c.Env -WorkingDirectory $c.Root
  [pscustomobject]@{ Code = $r.ExitCode; Text = $r.Output }
}

Describe 'crew queue e2e (crew task con thật, hc giả)' {
  It 'thêm/liệt kê/bỏ; kiểm tên, trùng, cờ chỉ của queue' {
    $c = New-E2E
    $p = Join-Path $c.Root 'p.md'; 'Được sửa: `a.ps1`' | Set-Content $p -Encoding utf8
    $r = Run-Crew $c @('queue', 'a', $p, '-Size', 'L', '-After', 'zz')
    $r.Code | Should Be 1
    $r.Text | Should Match 'không có task tên zz đang chạy hay trong hàng đợi'
    Test-Path (Join-Path $c.Root '.crew/queue/a.md') | Should Be $false
    Test-Path (Join-Path $c.Root '.crew/queue.json') | Should Be $false
    ConvertTo-Json -InputObject @([ordered]@{ name = 'zz'; branch = 'crew/zz'; worktree = ''; worker = 1 }) | Set-Content (Join-Path $c.Root '.crew/tasks.json') -Encoding utf8
    $r = Run-Crew $c @('queue', 'a', $p, '-Size', 'L', '-After', 'zz')
    $r.Code | Should Be 0
    $r.Text | Should Match 'đã xếp a vào hàng đợi \(vị trí 1\)'
    # -After trỏ mục trong hàng đợi cũng hợp lệ
    (Run-Crew $c @('queue', 'a2', $p, '-After', 'a')).Code | Should Be 0
    (Run-Crew $c @('queue', 'a2', '-Remove')).Code | Should Be 0
    Test-Path (Join-Path $c.Root '.crew/queue/a.md') | Should Be $true
    (Run-Crew $c @('queue', 'a', $p)).Text | Should Match 'đã cập nhật a trong hàng đợi \(vị trí 1'
    (Run-Crew $c @('queue', 'Bad_Name', $p)).Text | Should Match 'tên task chỉ gồm a-z 0-9'
    (Run-Crew $c @('queue', 'b', $p, '-Worker', '3')).Text | Should Match '-Worker phải từ 1 tới 1'
    (Run-Crew $c @('queue', 'b', $p, '-After', 'b')).Text | Should Match '-After không được là chính nó'
    $list = Run-Crew $c @('queue')
    $list.Code | Should Be 0
    $list.Text | Should Match '(?m)^a\s+-\s+L\s+zz\s+-'
    $r = Run-Crew $c @('task', 'x', $p, '-Size', 'L')
    $r.Code | Should Be 1
    $r.Text | Should Match 'chỉ dùng với crew queue'
    (Run-Crew $c @('queue', 'a', '-Remove')).Text | Should Match 'đã bỏ a khỏi hàng đợi'
    Test-Path (Join-Path $c.Root '.crew/queue/a.md') | Should Be $false
    (Run-Crew $c @('queue')).Text | Should Match 'hàng đợi trống'
    (Run-Crew $c @('queue', '-Run')).Text | Should Match 'hàng đợi trống'
    (Run-Crew $c @('queue', 'a', '-Remove')).Code | Should Be 1
  }

  It '-Run giao qua crew task thật; mục còn lại hiện ở hot; crew clean tự giao mục kế' {
    $c = New-E2E
    $pa = Join-Path $c.Root 'pa.md'; 'prompt A' | Set-Content $pa -Encoding utf8
    $pb = Join-Path $c.Root 'pb.md'; 'prompt B' | Set-Content $pb -Encoding utf8
    (Run-Crew $c @('queue', 'a', $pa)).Code | Should Be 0
    (Run-Crew $c @('queue', 'b', $pb, '-Review', 'fast')).Code | Should Be 0
    $dry = Run-Crew $c @('queue', '-Run', '-DryRun')
    $dry.Text | Should Match 'a: sẽ giao → w1'
    Test-Path (Join-Path $c.State 'sends.log') | Should Be $false
    Test-Path (Join-Path $c.Root '.crew/queue.log') | Should Be $false

    $r = Run-Crew $c @('queue', '-Run')
    $r.Code | Should Be 0
    $r.Text | Should Match 'a: đã giao → w1'
    $r.Text | Should Match 'b: giữ: không có worker rảnh'
    (Get-Content (Join-Path $c.Root '.crew/queue.log') -Raw) | Should Match '\(run\)'
    # limit hỏi qua claude giả, đúng một lần; -DryRun trước đó cũng hỏi một lần
    $limitLog = @(Get-Content (Join-Path $c.State 'limits.log') -Encoding utf8)
    $limitLog.Count | Should Be 2
    $limitLog[-1] | Should Be 'claude -p /usage --output-format json --no-session-persistence'
    $tasks = @(Get-Content (Join-Path $c.Root '.crew/tasks.json') -Raw | ConvertFrom-Json)
    $tasks.Count | Should Be 1
    $tasks[0].name | Should Be 'a'
    (Get-Content (Join-Path $c.Wt '.crew/prompt.md') -Raw).Trim() | Should Be 'prompt A'
    (git -C $c.Wt branch --show-current) | Should Be 'crew/a'
    (Get-Content (Join-Path $c.State 'sends.log') -Raw) | Should Match 'qt-w1 .*crew/a'

    $hot = Run-Crew $c @('hot')
    $hot.Text | Should Match '== hàng đợi: 1 \(b\)'

    $clean = Run-Crew $c @('clean', 'a')
    $clean.Code | Should Be 0
    $clean.Text | Should Match 'đã dọn task a'
    $clean.Text | Should Match 'b: đã giao → w1'
    $log = Get-Content (Join-Path $c.Root '.crew/queue.log') -Raw -Encoding utf8
    $log | Should Match '\(clean\)'
    $log | Should Match 'b: đã giao → w1'
    (Run-Crew $c @('queue')).Text | Should Match 'lần chạy gần nhất: .* \(clean\)'
    $tasks = @(Get-Content (Join-Path $c.Root '.crew/tasks.json') -Raw | ConvertFrom-Json)
    $tasks[0].name | Should Be 'b'
    $tasks[0].review | Should Be 'fast'
    (Get-Content (Join-Path $c.Wt '.crew/prompt.md') -Raw).Trim() | Should Be 'prompt B'
    (Run-Crew $c @('queue')).Text | Should Match 'hàng đợi trống'
  }

  It 'trùng file Được sửa với task vừa giao (hàm scope-guard thật) ⇒ giữ dù còn worker rảnh' {
    $c = New-E2E
    ConvertTo-Json -InputObject ([ordered]@{ name = 'qt'; idKey = 'qt'; planner = 'none'; workers = @('claude', 'codex'); rev = 'none'; review = 'lean'; access = 'work' }) |
      Set-Content (Join-Path $c.Root '.crew/config.json') -Encoding utf8
    ConvertTo-Json -InputObject @(
      [ordered]@{ name = 'qt-w1'; address = 't1'; state = 'live'; cwd = $c.Wt; turn = 1 },
      [ordered]@{ name = 'qt-w2'; address = 't2'; state = 'live'; cwd = (Join-Path $c.Root '.crew/worktrees/w2'); turn = 1 }
    ) | Set-Content (Join-Path $c.State 'terminals.json') -Encoding utf8
    $pa = Join-Path $c.Root 'pa.md'; 'Được sửa: `scripts/crew/`' | Set-Content $pa -Encoding utf8
    $pb = Join-Path $c.Root 'pb.md'; 'Được sửa: `scripts/crew/queue.ps1`' | Set-Content $pb -Encoding utf8
    $pc = Join-Path $c.Root 'pc.md'; 'Được sửa: `docs/x.md`' | Set-Content $pc -Encoding utf8
    foreach ($q in @(@('a', $pa), @('b', $pb), @('c', $pc))) { (Run-Crew $c @('queue', $q[0], $q[1])).Code | Should Be 0 }
    $dry = Run-Crew $c @('queue', '-Run', '-DryRun')
    $dry.Code | Should Be 0
    $dry.Text | Should Match 'a: sẽ giao → w1'
    $dry.Text | Should Match 'b: giữ: trùng file với a'
    $dry.Text | Should Match 'c: sẽ giao → w2'
    Test-Path (Join-Path $c.Root '.crew/queue.log') | Should Be $false
    $r = Run-Crew $c @('queue', '-Run')
    $r.Code | Should Be 0
    $r.Text | Should Match 'a: đã giao → w1'
    $r.Text | Should Match 'b: giữ: trùng file với a \(scripts/crew/queue\.ps1 ~ scripts/crew/\)'
    $r.Text | Should Match 'c: đã giao → w2'
    $limitLog = @(Get-Content (Join-Path $c.State 'limits.log') -Encoding utf8)
    ($limitLog -join '|') | Should Be 'claude -p /usage --output-format json --no-session-persistence|codex app-server|claude -p /usage --output-format json --no-session-persistence|codex app-server'
    (Run-Crew $c @('queue')).Text | Should Match '(?m)^b\s.*trùng file với a'
  }

  It 'xếp lại cùng tên ⇒ cập nhật bản chép tại chỗ, chỉ đổi cờ được truyền; liệt kê cảnh báo khi file gốc mới hơn' {
    $c = New-E2E
    $pa = Join-Path $c.Root 'pa.md'; 'prompt A1' | Set-Content $pa -Encoding utf8
    $pb = Join-Path $c.Root 'pb.md'; 'prompt B' | Set-Content $pb -Encoding utf8
    (Run-Crew $c @('queue', 'a', $pa, '-Size', 'L', '-Review', 'fast')).Code | Should Be 0
    (Run-Crew $c @('queue', 'b', $pb, '-After', 'a')).Code | Should Be 0
    $copy = Join-Path $c.Root '.crew/queue/a.md'
    (Run-Crew $c @('queue')).Text | Should Not Match 'CẢNH BÁO'
    'prompt A2' | Set-Content $pa -Encoding utf8
    (Get-Item $pa).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
    $list = Run-Crew $c @('queue')
    $list.Code | Should Be 0
    $list.Text | Should Match ([regex]::Escape("CẢNH BÁO: $pa mới hơn bản chép của a"))
    $list.Text | Should Not Match 'bản chép của b'
    $r = Run-Crew $c @('queue', 'a', $pa, '-Worker', '1')
    $r.Code | Should Be 0
    $r.Text | Should Match 'đã cập nhật a trong hàng đợi \(vị trí 1'
    (Get-Content $copy -Raw).Trim() | Should Be 'prompt A2'
    $items = @(Get-Content (Join-Path $c.Root '.crew/queue.json') -Raw -Encoding utf8 | ConvertFrom-Json)
    ($items | ForEach-Object { $_.name }) -join ',' | Should Be 'a,b'
    $items[0].worker | Should Be 1
    $items[0].size | Should Be 'L'
    $items[0].review | Should Be 'fast'
    $items[0].source | Should Be $pa
    $items[1].after | Should Be 'a'
    (Run-Crew $c @('queue')).Text | Should Not Match 'CẢNH BÁO'
    # file prompt khác, đổi -Size/-After; b vẫn đứng sau
    $p2 = Join-Path $c.Root 'p2.md'; 'prompt B2' | Set-Content $p2 -Encoding utf8
    (Run-Crew $c @('queue', 'b', $p2, '-Size', 'S', '-After', '')).Code | Should Be 0
    $items = @(Get-Content (Join-Path $c.Root '.crew/queue.json') -Raw -Encoding utf8 | ConvertFrom-Json)
    ($items | ForEach-Object { $_.name }) -join ',' | Should Be 'a,b'
    $items[1].size | Should Be 'S'
    $items[1].after | Should Be ''
    $items[1].source | Should Be $p2
    (Get-Content (Join-Path $c.Root '.crew/queue/b.md') -Raw).Trim() | Should Be 'prompt B2'
    # mục cũ không có source ⇒ không cảnh báo
    $raw = Get-Content (Join-Path $c.Root '.crew/queue.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $legacy = @($raw | ForEach-Object { $_ | Select-Object name, prompt, worker, review, after, size, added, hold })
    ConvertTo-Json -InputObject $legacy | Set-Content (Join-Path $c.Root '.crew/queue.json') -Encoding utf8
    'prompt A3' | Set-Content $pa -Encoding utf8
    (Get-Item $pa).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(10)
    $list = Run-Crew $c @('queue')
    $list.Code | Should Be 0
    $list.Text | Should Not Match 'CẢNH BÁO'
  }

  It 'limit thật qua New-QueueOps (claude giả 95%) ⇒ giữ mốc dừng, không gọi crew task' {
    $c = New-E2E
    $c.Env.FAKE_CLAUDE_USED = '95'
    $pa = Join-Path $c.Root 'pa.md'; 'prompt A' | Set-Content $pa -Encoding utf8
    (Run-Crew $c @('queue', 'a', $pa)).Code | Should Be 0
    $r = Run-Crew $c @('queue', '-Run')
    $r.Code | Should Be 0
    $r.Text | Should Match 'a: giữ: w1: limit claude 95% \(dừng\)'
    Test-Path (Join-Path $c.State 'sends.log') | Should Be $false
    Test-Path (Join-Path $c.Root '.crew/tasks.json') | Should Be $false
    @(Get-Content (Join-Path $c.State 'limits.log')).Count | Should Be 1
  }

  It 'crew task con lỗi (terminal tắt) ⇒ giữ mục với lý do, không ghi task' {
    $c = New-E2E
    '[]' | Set-Content (Join-Path $c.State 'terminals.json')
    $pa = Join-Path $c.Root 'pa.md'; 'prompt A' | Set-Content $pa -Encoding utf8
    (Run-Crew $c @('queue', 'a', $pa)).Code | Should Be 0
    $r = Run-Crew $c @('queue', '-Run')
    $r.Code | Should Be 0
    $r.Text | Should Match 'a: giữ: crew task lỗi: không thấy terminal qt-w1'
    $r.Text | Should Match 'dừng giao tiếp'
    (Run-Crew $c @('queue')).Text | Should Match 'crew task lỗi: không thấy terminal'
    Test-Path (Join-Path $c.Root '.crew/tasks.json') | Should Be $false
  }
}
