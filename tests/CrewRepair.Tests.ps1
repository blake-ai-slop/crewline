# Test crew repair: trích hàm bằng AST từ crew.ps1, repo git tạm trong $TestDrive, hc giả tiêm qua $ops (Get/Send/Keys/Read/Sleep/Up) — không gọi hc thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Invoke-GitQuiet', 'Invoke-GitOrDie', 'Get-Tasks', 'Save-Tasks', 'Test-WorktreeListed', 'Get-WorkerTree', 'Initialize-WorkerTree',
  'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-WorkerMode', 'Test-SessionReady', 'Get-ScreenDialog', 'Format-DirtyFiles',
  'Test-KeepTask', 'New-TaskRecord', 'Get-WorktreeMeta', 'Get-ResumeLine', 'Get-TreeState', 'Wait-WorkerReady', 'Get-ResumeCheck', 'Invoke-RepairCore',
  'Get-ReviewLevel', 'Format-ReviewMessage', 'Get-ReviewLine', 'Get-MainOp', 'Get-PendingReview', 'Invoke-Review', 'Get-MainRoot', 'Get-Config', 'Get-Slug'
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

  It '-DryRun: w1 thiếu terminal + có task + đúng nhánh -> in sẽ giao lại task, 0 Send/Keys/Up' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops $true
    (@($res.Done) -join '|') | Should Match ([regex]::Escape('(sẽ làm) giao lại task a -> x-w1'))
    @($res.Done | Where-Object { $_ -notlike '(sẽ làm)*' }).Count | Should Be 0
    @($res.Human).Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    $ops.State.Ri | Should Be 0
    $script:HcCalls | Should Be 0
  }

  It '-DryRun: worktree sai nhánh -> không có dòng giao lại, có việc cần người' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $wt = Get-WorkerTree $root 1
    git -C $wt switch -q --detach main
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops $true
    (@($res.Done) -join '|') | Should Not Match 'giao lại task'
    (@($res.Human) -join '|') | Should Match ([regex]::Escape("x-w1 vừa bật lại nhưng $wt không ở crew/a — chưa giao lại task a."))
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
  }

  It '-DryRun: thiếu prompt.md nhưng có prompt nguồn -> in sẽ chép lại, không tạo file' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $wt = Get-WorkerTree $root 1
    $pm = Join-Path $wt '.crew/prompt.md'
    Remove-Item -LiteralPath $pm -Force
    New-Item -ItemType Directory -Force (Join-Path $root '.crew/prompts') | Out-Null
    'nguồn' | Set-Content (Join-Path $root '.crew/prompts/a.md')
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops $true
    $d = @($res.Done) -join '|'
    $d | Should Match ([regex]::Escape('(sẽ làm) chép lại prompt'))
    $d | Should Match ([regex]::Escape('(sẽ làm) giao lại task a -> x-w1'))
    Test-Path -LiteralPath $pm | Should Be $false
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Up | Should Be 0
  }

  It '-DryRun: w1 bị xóa + thiếu terminal -> coi như tạo lại + switch, báo thiếu prompt giống chạy thật' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $wt = Get-WorkerTree $root 1
    Remove-Item -LiteralPath $wt -Recurse -Force
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops $true
    (@($res.Human) -join '|') | Should Match ([regex]::Escape("$wt thiếu .crew/prompt.md"))
    (@($res.Human) -join '|') | Should Not Match 'không ở crew/a'
    Test-Path $wt | Should Be $false
  }

  It 'chạy thật: thiếu prompt.md + có prompt nguồn -> chép lại rồi gửi' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1
    $pm = Join-Path (Get-WorkerTree $root 1) '.crew/prompt.md'
    Remove-Item -LiteralPath $pm -Force
    New-Item -ItemType Directory -Force (Join-Path $root '.crew/prompts') | Out-Null
    'nguồn' | Set-Content (Join-Path $root '.crew/prompts/a.md')
    $ops = New-FakeOps @{ 'x-w1' = $null; 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    Test-Path -LiteralPath $pm | Should Be $true
    (@($res.Done) -join '|') | Should Match ([regex]::Escape('chép lại prompt'))
    $ops.State.Sent.Count | Should Be 1
    @($res.Human).Count | Should Be 0
  }
}

# ---------------- Rev bị đóng giữa review/merge ----------------
$CfgRev = [pscustomobject]@{ planner = 'none'; workers = @('claude', 'claude'); rev = 'claude'; access = 'work'; review = 'lean' }
function Invoke-RepRev([string]$root, $ops, [bool]$dry = $false) { Invoke-RepairCore $root $CfgRev 'x' 'main' $dry $ops }

# commit 1 file trong worktree của task
function Add-Commit([string]$root, [string]$name, [int]$n, [string]$file = 'n.txt', [string]$text = 'x') {
  $wt = Get-WorkerTree $root $n
  $text | Set-Content (Join-Path $wt $file); git -C $wt add -A; git -C $wt commit -q -m $name
}

# đánh dấu chờ review theo thứ tự $names (giống crew review đã gửi)
function Set-ReviewSent([string]$root, [string[]]$names) {
  $tasks = Get-Tasks $root; $t0 = [DateTime]::UtcNow
  for ($i = 0; $i -lt $names.Count; $i++) {
    $t = $tasks | Where-Object { $_.name -eq $names[$i] }
    $t | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $t0.AddMilliseconds($i).ToString('o') -Force
  }
  Save-Tasks $root $tasks
}

# a, b cùng sửa a.txt; main merge a (ff) rồi merge b ⇒ xung đột thật, MERGE_HEAD
function New-MergeConflict([string]$root) {
  Add-Commit $root 'a' 1 'a.txt' 'từ a'
  Add-Commit $root 'b' 2 'a.txt' 'từ b'
  git -C $root merge -q crew/a 2>&1 | Out-Null
  git -C $root merge -q --no-edit crew/b 2>&1 | Out-Null
}

Describe 'crew repair: Rev bị đóng giữa review (hc giả)' {
  BeforeEach { $script:HcCalls = 0 }

  It 'Rev thiếu + 2 task chờ review -> bật lại, gửi đúng 1 dòng = Get-ReviewLine theo thứ tự gửi' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Commit $root 'a' 1
    Add-Task $root 'b' 2; Add-Commit $root 'b' 2
    Set-ReviewSent $root @('b', 'a')
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null }
    $res = Invoke-RepRev $root $ops
    $all = Get-Tasks $root; $tb = $all | Where-Object { $_.name -eq 'b' }; $ta = $all | Where-Object { $_.name -eq 'a' }
    $want = (Get-ReviewLine $root 'main' @($tb, $ta) 'lean' $false).Msg
    $ops.State.Up | Should Be 1
    $ops.State.Sent.Count | Should Be 1
    $ops.State.Sent[0] | Should Be $want
    $ops.State.Sent[0] | Should Match ([regex]::Escape('merge crew/b ('))
    $ops.State.Sent[0].IndexOf('crew/b') | Should BeLessThan $ops.State.Sent[0].IndexOf('crew/a')
    $ops.State.Keys | Should Be 0
    (@($res.Done) -join '|') | Should Match ([regex]::Escape('giao lại review b,a -> x-rev'))
    @($res.Human).Count | Should Be 0
    @((Get-Tasks $root) | ForEach-Object { $_ } | Where-Object { $_.reviewSentAt }).Count | Should Be 2
    $script:HcCalls | Should Be 0
  }

  It 'Rev thiếu + main merge dở (xung đột thật) -> dòng có Lưu ý merge dở; repo chính không đổi HEAD/MERGE_HEAD' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Task $root 'b' 2
    New-MergeConflict $root
    Set-ReviewSent $root @('a', 'b')
    $head = (git -C $root rev-parse HEAD).Trim()
    $mh = Get-Content (Join-Path $root '.git/MERGE_HEAD') -Raw
    $op = Get-MainOp $root
    $op.Kind | Should Be 'merge'
    $op.Files -join ',' | Should Be 'a.txt'
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null }
    $res = Invoke-RepRev $root $ops
    $ops.State.Sent.Count | Should Be 1
    $ops.State.Sent[0] | Should Match ([regex]::Escape('crew/a (đã merge) rồi crew/b ('))
    $ops.State.Sent[0] | Should Match ([regex]::Escape('Lưu ý: bạn bị gián đoạn; repo chính đang merge dở — xem git status'))
    $ops.State.Keys | Should Be 0
    @($res.Human).Count | Should Be 0
    (git -C $root rev-parse HEAD).Trim() | Should Be $head
    Get-Content (Join-Path $root '.git/MERGE_HEAD') -Raw | Should Be $mh
  }

  It 'Rev live + main merge dở -> không gửi, việc cần người (exit 1), không đụng repo chính' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Task $root 'b' 2
    New-MergeConflict $root
    Set-ReviewSent $root @('a', 'b')
    $head = (git -C $root rev-parse HEAD).Trim()
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = (New-Info) }
    $res = Invoke-RepRev $root $ops
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    (@($res.Human) -join '|') | Should Match ([regex]::Escape('main đang merge dở — hỏi Rev (x-rev) hoặc xem git status'))
    (git -C $root rev-parse HEAD).Trim() | Should Be $head
    Test-Path (Join-Path $root '.git/MERGE_HEAD') | Should Be $true
    @((Get-Tasks $root) | ForEach-Object { $_ } | Where-Object { $_.reviewSentAt }).Count | Should Be 2
  }

  It 'rev: none + main merge dở -> việc cần người' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Task $root 'b' 2
    New-MergeConflict $root
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info) }
    $res = Invoke-Rep $root $ops
    (@($res.Human) -join '|') | Should Match ([regex]::Escape('main đang merge dở — không có Rev'))
    $ops.State.Sent.Count | Should Be 0
  }

  It 'Rev thiếu, không có task chờ review -> bật lại nhưng không gửi' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Commit $root 'a' 1
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null }
    $res = Invoke-RepRev $root $ops
    $ops.State.Up | Should Be 1
    $ops.State.Sent.Count | Should Be 0
    @($res.Human).Count | Should Be 0
  }

  It '-DryRun: Rev thiếu + task chờ review + merge dở -> (sẽ làm) giao lại review, 0 Send/Keys/Up/Read' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Task $root 'b' 2
    New-MergeConflict $root
    Set-ReviewSent $root @('a', 'b')
    $head = (git -C $root rev-parse HEAD).Trim()
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null }
    $res = Invoke-RepRev $root $ops $true
    (@($res.Done) -join '|') | Should Match ([regex]::Escape('(sẽ làm) giao lại review a,b -> x-rev'))
    @($res.Done | Where-Object { $_ -notlike '(sẽ làm)*' }).Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    $ops.State.Ri | Should Be 0
    (git -C $root rev-parse HEAD).Trim() | Should Be $head
    Test-Path (Join-Path $root '.git/MERGE_HEAD') | Should Be $true
    $script:HcCalls | Should Be 0
  }

  It 'Rev vừa bật lại nhưng blocked -> không gửi review, 0 Enter, cần người' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Commit $root 'a' 1
    Set-ReviewSent $root @('a')
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null } @('') (New-Info 'blocked')
    $res = Invoke-RepRev $root $ops
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    (@($res.Human) -join '|') | Should Match 'chưa giao lại review a'
  }

  It 'Rev vừa bật lại chờ trust -> hướng dẫn từ Wait-WorkerReady, không gửi review/Enter' {
    $root = New-RepairRepo
    Add-Task $root 'a' 1; Add-Commit $root 'a' 1
    Set-ReviewSent $root @('a')
    $screen = "Quick safety check:`n❯ No, exit`n  Yes, I trust this folder`nEnter to confirm · Esc to cancel"
    $ops = New-FakeOps @{ 'x-w1' = (New-Info); 'x-w2' = (New-Info); 'x-rev' = $null } @($screen) (New-Info 'blocked')
    $res = Invoke-RepRev $root $ops
    $ops.State.Up | Should Be 1
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    (@($res.Human) -join '|') | Should Match 'x-rev đang chờ trust thư mục.*hc keys x-rev down enter'
    (@($res.Human) -join '|') | Should Match 'chưa giao lại review a'
  }
}

function New-ReviewRepo {
  $root = New-RepairRepo
  '{"review":"lean"}' | Set-Content (Join-Path $root '.crew/config.json')
  Add-Task $root 'a' 1; Add-Commit $root 'a' 1
  Add-Task $root 'b' 2; Add-Commit $root 'b' 2
  $root
}

Describe 'crew review ghi reviewSentAt' {
  $script:ReviewSent = [Collections.Generic.List[string]]::new()
  function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false) { $script:ReviewSent.Add("$term|$text") }
  BeforeEach { $script:ReviewSent.Clear() }

  It 'gửi OK -> tasks.json có reviewSentAt (ISO, theo thứ tự), không đổi trường khác' {
    $root = New-ReviewRepo
    $before = Get-Content (Join-Path $root '.crew/tasks.json') -Raw | ConvertFrom-Json
    $NameList = @('b', 'a'); $DryRun = $false
    Push-Location $root
    try { Invoke-Review } finally { Pop-Location }
    $script:ReviewSent.Count | Should Be 1
    $tasks = Get-Tasks $root
    Get-Content (Join-Path $root '.crew/tasks.json') -Raw | Should Match '"reviewSentAt":\s*"\d{4}-\d\d-\d\dT'
    $ta = $tasks | Where-Object { $_.name -eq 'a' }; $tb = $tasks | Where-Object { $_.name -eq 'b' }
    ([datetime]$tb.reviewSentAt) | Should BeLessThan ([datetime]$ta.reviewSentAt)
    foreach ($t in $before) {
      $now = $tasks | Where-Object { $_.name -eq $t.name }
      foreach ($p in $t.PSObject.Properties) { [string]$now.($p.Name) | Should Be ([string]$p.Value) }
    }
    $pend = Get-PendingReview $root $tasks
    (@($pend | ForEach-Object { $_.name }) -join ',') | Should Be 'b,a'
    $script:ReviewSent[0] | Should Be ("$(Get-Slug $root)-rev|" + (Get-ReviewLine $root 'main' $pend 'lean').Msg)
  }

  It '-DryRun -> không gửi, không ghi reviewSentAt' {
    $root = New-ReviewRepo
    $NameList = @('a', 'b'); $DryRun = $true
    Push-Location $root
    try { Invoke-Review } finally { Pop-Location }
    $script:ReviewSent.Count | Should Be 0
    @((Get-Tasks $root) | ForEach-Object { $_ } | Where-Object { $_.reviewSentAt }).Count | Should Be 0
  }
}
