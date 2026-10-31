# Test crew repair: trích hàm bằng AST từ crew.ps1, repo git tạm trong $TestDrive, hc giả tiêm qua $ops (Get/Send/Keys/Read/Sleep/Up) — không gọi hc thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Invoke-GitQuiet', 'Invoke-GitOrDie', 'Get-Tasks', 'Save-Tasks', 'Test-WorktreeListed', 'Get-WorkerTree', 'Initialize-WorkerTree',
  'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-WorkerMode', 'Test-SessionReady', 'Get-ScreenDialog', 'Format-DirtyFiles',
  'Test-KeepTask', 'New-TaskRecord', 'Get-WorktreeMeta', 'Get-ResumeLine', 'Get-TreeState', 'Wait-WorkerReady', 'Invoke-RepairCore'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($msg) { }
function Die($msg) { throw $msg }
function Write-Host { }
$script:HcCalls = 0
function hc { $script:HcCalls++; throw 'gọi hc thật trong test' }

$Cfg = [pscustomobject]@{ planner = 'none'; workers = @('claude', 'claude'); rev = 'none'; access = 'work' }

function New-Info([string]$status = 'idle', [string]$app = 'claude-code') {
  [pscustomobject]@{ name = 'x'; state = 'live'; status = [pscustomobject]@{ app = $app; state = $status }; turn = 1 }
}

# repo tạm với w1, w2 detached tại main
function New-RepairRepo {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $root = Join-Path $TestDrive "repo-$id"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  git -C $root init -q -b main
  git -C $root config user.name t; git -C $root config user.email t@t; git -C $root config core.autocrlf false
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  'a' | Set-Content (Join-Path $root 'a.txt')
  git -C $root add -A; git -C $root commit -q -m init
  Initialize-WorkerTree $root 1 'main' | Out-Null
  Initialize-WorkerTree $root 2 'main' | Out-Null
  $root
}

# task trên worker $n: nhánh crew/<tên> trong w<N>, prompt.md, bản ghi tasks.json
function Add-Task([string]$root, [string]$name, [int]$n) {
  $wt = Get-WorkerTree $root $n
  git -C $wt switch -q -c "crew/$name" main
  New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
  'prompt' | Set-Content (Join-Path $wt '.crew/prompt.md')
  $tasks = Get-Tasks $root
  Save-Tasks $root (@($tasks) + (New-TaskRecord $name "crew/$name" $wt $n "x-w$n" 'claude' ''))
}

# hc giả: $terms = tên -> info ($null = thiếu); Up bật mọi terminal thiếu thành $upInfo.
function New-FakeOps($terms, $screens = @(''), $upInfo = (New-Info)) {
  $st = @{ Terms = $terms; Screens = @($screens); Ri = 0; Keys = 0; Up = 0; Sent = [Collections.Generic.List[string]]::new() }
  @{
    State = $st
    Get   = { param($t) $st.Terms[$t] }.GetNewClosure()
    Send  = { param($t, $x, $sh) $st.Sent.Add($x); @{ Code = 0; Text = '{"started":true}' } }.GetNewClosure()
    Keys  = { param($t) $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) }
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
    Up    = { $st.Up++; foreach ($k in @($st.Terms.Keys)) { if (-not $st.Terms[$k]) { $st.Terms[$k] = $upInfo } } }.GetNewClosure()
  }
}

function Invoke-Rep([string]$root, $ops, [bool]$dry = $false) { Invoke-RepairCore $root $Cfg 'x' 'main' $dry $ops }

Describe 'crew repair (hc giả)' {
  BeforeEach { $script:HcCalls = 0 }

  It 'mọi thứ ổn -> không làm gì, không cần người quyết' {
    $root = New-RepairRepo
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    @($res.Done).Count | Should Be 0
    @($res.Human).Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $script:HcCalls | Should Be 0
  }

  It 'w1 thiếu terminal + có task -> bật lại qua Up, gửi đúng 1 dòng Tiếp tục task, 0 Enter' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    $ops.State.Up | Should Be 1
    $wt = Get-WorkerTree $root 1
    $ops.State.Sent.Count | Should Be 1
    $ops.State.Sent[0] | Should Be (Get-ResumeLine 'a' $wt 'crew/a')
    $ops.State.Sent[0] | Should Match ([regex]::Escape('Tiếp tục task a (bị gián đoạn)'))
    $ops.State.Sent[0] | Should Match ([regex]::Escape("$wt\.crew\prompt.md"))
    $ops.State.Keys | Should Be 0
    @($res.Sent) -join ',' | Should Be 'a'
    @($res.Human).Count | Should Be 0
    $script:HcCalls | Should Be 0
  }

  It 'w1 live + có task -> không bật, không gửi' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = (New-Info 'working'); 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    @($res.Human).Count | Should Be 0
  }

  It 'thư mục w2 bị xóa tay -> prune + tạo lại, task của w2 -> switch đúng nhánh (không đổi commit)' {
    $root = New-RepairRepo
    Add-Task $root 'b' 2
    $wt = Get-WorkerTree $root 2
    'x' | Set-Content (Join-Path $wt 'n.txt'); git -C $wt add -A; git -C $wt commit -q -m w
    $head = (git -C $root rev-parse crew/b).Trim()
    Remove-Item -LiteralPath $wt -Recurse -Force
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    Test-Path $wt | Should Be $true
    Test-WorktreeListed $root $wt | Should Be $true
    (git -C $wt branch --show-current) | Should Be 'crew/b'
    (git -C $root rev-parse crew/b).Trim() | Should Be $head
    (@($res.Done) -join '|') | Should Match 'prune'
    $ops.State.Sent.Count | Should Be 0
    @($res.Human).Count | Should Be 0
  }

  It 'task có nhánh đã mất -> không sửa, gợi ý clean -Force, còn việc cần người' {
    $root = New-RepairRepo
    $wt = Get-WorkerTree $root 1
    Save-Tasks $root @(New-TaskRecord 'c' 'crew/c' $wt 1 'x-w1' 'claude' '')
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    (@($res.Human) -join '|') | Should Match ([regex]::Escape('crew clean c -Force'))
    (Get-Tasks $root).Count | Should Be 1
    $ops.State.Sent.Count | Should Be 0
  }

  It 'worktree bẩn không có task -> báo, không đụng file' {
    $root = New-RepairRepo
    $wt = Get-WorkerTree $root 2
    'bẩn' | Set-Content (Join-Path $wt 'x.txt')
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    (@($res.Human) -join '|') | Should Match 'w2 bẩn mà không có task \(x\.txt\)'
    Test-Path (Join-Path $wt 'x.txt') | Should Be $true
    (git -C $wt status --porcelain) | Should Match 'x.txt'
  }

  It '-DryRun -> không ghi git, không bật, không gửi; chỉ in sẽ làm' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $wt = Get-WorkerTree $root 1
    Remove-Item -LiteralPath $wt -Recurse -Force
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops $true
    Test-Path $wt | Should Be $false
    (git -C $root worktree list --porcelain) -join "`n" | Should Match 'prunable'
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    @($res.Done).Count | Should BeGreaterThan 0
    @($res.Done | Where-Object { $_ -notlike '(sẽ làm)*' }).Count | Should Be 0
  }

  It 'vừa bật lại nhưng hiện hộp thoại lạ -> không gửi, 0 Enter, cần người' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) } @("Do you want to proceed?`n❯ 1. Yes`n  2. No")
    $res = Invoke-Rep $root $ops
    $ops.State.Up | Should Be 1
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    (@($res.Human) -join '|') | Should Match 'hộp thoại'
  }

  It 'vừa bật lại nhưng blocked -> không gửi, 0 Enter, cần người' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) } @('') (New-Info 'blocked')
    $res = Invoke-Rep $root $ops
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    (@($res.Human) -join '|') | Should Match 'chờ duyệt'
  }
}
