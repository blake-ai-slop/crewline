# Test worker giữ phiên (worktree cố định w<N>): trích hàm bằng AST từ crew.ps1, repo git tạm trong $TestDrive, hc giả tiêm qua $ops — không gọi hc thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Invoke-GitQuiet', 'Invoke-GitOrDie', 'Get-Tasks', 'Save-Tasks', 'Test-WorktreeListed', 'Get-WorkerTree', 'Get-MainBranch',
  'Initialize-WorkerTree', 'Get-RestartTargets', 'Get-WorkerStartLine', 'Get-Flags', 'Quote', 'Get-AgentCommand', 'Get-TermStatus',
  'Get-SendPlan', 'Invoke-SendFlow', 'Get-WorkerMode', 'Test-SessionReady', 'Get-ScreenDialog', 'Get-TaskLine', 'Format-DirtyFiles', 'Initialize-TaskBranch', 'Send-WorkerTask',
  'Start-WorkerTask', 'Remove-TaskBranch', 'Remove-TaskGit', 'Test-KeepTask', 'Reset-WorkerTree', 'New-TaskRecord'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($msg) { }
function Die($msg) { throw $msg }
# hc thật không được gọi: mọi lệnh hc trong code dưới test phải đi qua $ops
$script:HcCalls = 0
function hc { $script:HcCalls++; throw 'gọi hc thật trong test' }

function New-KeepRepo {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $root = Join-Path $TestDrive "repo-$id"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  git -C $root init -q -b main
  git -C $root config user.name t; git -C $root config user.email t@t; git -C $root config core.autocrlf false
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  'a' | Set-Content (Join-Path $root 'a.txt')
  git -C $root add -A; git -C $root commit -q -m init
  $prompt = Join-Path $TestDrive "prompt-$id.md"
  'làm việc X' | Set-Content $prompt -Encoding utf8
  @{ Root = $root; Prompt = $prompt }
}

function New-Info([string]$app = 'claude-code', [string]$status = 'idle', [string]$state = 'live') {
  $st = if ($app) { [pscustomobject]@{ app = $app; state = $status } } else { $null }
  [pscustomobject]@{ name = 'x-w1'; state = $state; status = $st; turn = 1 }
}

# Màn hình Claude thật sau khi /clear đã chạy: '❯ /clear' thành dòng lịch sử, dưới là ô nhập trống.
$Cleared = @'
 ▐▛███▜▌   Claude Code
❯ /clear
  ⎿  (no content)
────────────────────────────
❯
────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
'@
# /clear còn kẹt ở ô nhập (chưa chạy): dòng prompt cuối là '❯ /clear' + menu gợi ý.
$NotCleared = @'
● Xong phần trước, đã commit.
────────────────────────────
❯ /clear
────────────────────────────
  /clear                Clear conversation history and free up context
'@
$CodexPicker = @'
  Where should the new conversation run?

› 1. Use current Git worktree  Keep using the current working directory
  2. Create new Git worktree   Create a separate checkout of this repository in another directory

  enter select · esc back
'@

# hc giả: Get/Read trả lần lượt phần tử của danh sách (hết thì giữ phần tử cuối); ghi lại các lệnh (Raw = cờ gửi trần của từng lần Send).
function New-FakeOps($gets, $screens = @(''), [string]$sendJson = '{"started":true}') {
  $st = @{ Gets = @($gets); Gi = 0; Screens = @($screens); Ri = 0; Keys = 0; Sent = [Collections.Generic.List[string]]::new(); Raw = [Collections.Generic.List[bool]]::new(); Log = [Collections.Generic.List[string]]::new() }
  @{
    State = $st
    Get   = { param($t) $st.Log.Add('get'); $k = [math]::Min($st.Gi, $st.Gets.Count - 1); $st.Gi++; $st.Gets[$k] }.GetNewClosure()
    Send  = { param($t, $x, $sh) $st.Log.Add("send:$x"); $st.Sent.Add($x); $st.Raw.Add([bool]$sh); @{ Code = 0; Text = $sendJson } }.GetNewClosure()
    Keys  = { param($t) $st.Log.Add('enter'); $st.Keys++ }.GetNewClosure()
    Sleep = { param($ms) }
    Read  = { param($t) $k = [math]::Min($st.Ri, $st.Screens.Count - 1); $st.Ri++; $st.Screens[$k] }.GetNewClosure()
  }
}

# giao task như Invoke-Task (bản ghi + Start-WorkerTask) trên worker 1
function Start-Task($r, [string]$name, $ops, [string]$kind = 'claude') {
  $tasks = Get-Tasks $r.Root
  $wt = Get-WorkerTree $r.Root 1
  $tasks = @($tasks) + (New-TaskRecord $name "crew/$name" $wt 1 'x-w1' $kind '')
  Start-WorkerTask $r.Root 'main' 1 $kind 'work' 'x-w1' $name $r.Prompt $tasks $ops
}

function Test-Branch([string]$root, [string]$b) { git -C $root show-ref --verify --quiet "refs/heads/$b"; $LASTEXITCODE -eq 0 }
function Get-Head([string]$dir, [string]$rev = 'HEAD') { (git -C $dir rev-parse $rev).Trim() }

Describe 'Get-WorkerTree / Initialize-WorkerTree' {
  It 'w<N> trong .crew/worktrees, tạo detached tại main khi thiếu, gọi lại không tạo lần nữa' {
    $r = New-KeepRepo
    $wt = Get-WorkerTree $r.Root 2
    $wt | Should Be ([IO.Path]::GetFullPath((Join-Path $r.Root '.crew/worktrees/w2')))
    (Initialize-WorkerTree $r.Root 2 'main') | Should Be $wt
    Test-WorktreeListed $r.Root $wt | Should Be $true
    (git -C $wt branch --show-current) | Should BeNullOrEmpty
    Get-Head $wt | Should Be (Get-Head $r.Root)
    (Initialize-WorkerTree $r.Root 2 'main') | Should Be $wt
  }
}

Describe 'crew task trên worktree cố định (hc giả)' {
  BeforeEach { $script:HcCalls = 0 }

  It 'lần 1: tạo crew/<tên> từ main, chép prompt, ghi task; agent claude đúng loại -> /clear rồi dòng giao việc' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info)) @($Cleared)
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $true
    $wt = Get-WorkerTree $r.Root 1
    (git -C $wt branch --show-current) | Should Be 'crew/a'
    Get-Head $wt | Should Be (Get-Head $r.Root 'main')
    (Get-Content (Join-Path $wt '.crew/prompt.md') -Raw -Encoding utf8) | Should Match 'làm việc X'
    $ops.State.Sent.Count | Should Be 2
    $ops.State.Sent[0] | Should Be '/clear'
    $ops.State.Sent[1] | Should Be (Get-TaskLine $wt 'crew/a')
    $ops.State.Sent[1] | Should Match ([regex]::Escape([IO.Path]::Combine($wt, '.crew', 'prompt.md')))
    # /clear gửi trần (để chạy lệnh thật), dòng giao việc gửi bọc như tin thường
    $ops.State.Raw[0] | Should Be $true
    $ops.State.Raw[1] | Should Be $false
    $ops.State.Keys | Should Be 0
    $t = Get-Tasks $r.Root
    $t.Count | Should Be 1
    $t[0].worktree | Should Be $wt
    $script:HcCalls | Should Be 0
  }

  It 'codex: /new, chờ tới khi thấy Context 100% left (không Enter khi đang chạy), rồi mới giao việc' {
    $r = New-KeepRepo
    $gets = @((New-Info 'codex'), (New-Info 'codex'), (New-Info 'codex' 'working'), (New-Info 'codex' 'working'), (New-Info 'codex'))
    $ops = New-FakeOps $gets @('Context 37% left', 'Context 37% left', 'Context 100% left')
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $true
    @($ops.State.Sent) -join '|' | Should Be ('/new|' + (Get-TaskLine (Get-WorkerTree $r.Root 1) 'crew/a'))
    $ops.State.Keys | Should Be 0
    $ops.State.Ri | Should BeGreaterThan 2
    @($ops.State.Raw) -join ',' | Should Be 'True,False'
  }

  It 'codex: /new hiện ĐÚNG hộp chọn worktree -> 1 Enter, chờ Context 100% left, rồi giao việc' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info 'codex')) @($CodexPicker, $CodexPicker, $CodexPicker, 'gpt-5 · Context 100% left · ~\w1')
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $true
    $ops.State.Keys | Should Be 1
    @($ops.State.Sent) -join '|' | Should Be ('/new|' + (Get-TaskLine (Get-WorkerTree $r.Root 1) 'crew/a'))
    # Enter chỉ sau khi đọc lại trạng thái và màn hình ngay trước phím
    $log = @($ops.State.Log); $e = [array]::IndexOf($log, 'enter')
    $log[$e - 1] | Should Be 'get'
  }

  It 'codex: hộp chọn còn sau Enter -> không bấm lần 2, hết giờ lỗi rõ, không giao việc' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info 'codex')) @($CodexPicker)
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $false
    $res.Message | Should Match 'chưa xác nhận'
    $ops.State.Keys | Should Be 1
    @($ops.State.Sent) -join '|' | Should Be '/new'
  }

  It 'codex: hộp duyệt lệnh khác (Allow command?) -> 0 Enter, lỗi, không giao việc' {
    $r = New-KeepRepo
    $dlg = "Allow command?`n  git push origin main`n› 1. Yes, proceed (y)`n  2. No, and tell Codex what to do differently (esc)"
    $ops = New-FakeOps @((New-Info 'codex')) @($dlg)
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $false
    $res.Message | Should Match 'hộp thoại lạ'
    $ops.State.Keys | Should Be 0
    @($ops.State.Sent) -join '|' | Should Be '/new'
  }

  It 'codex: hộp chọn bị thay bằng hộp khác ngay trước phím -> 0 Enter' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info 'codex')) @($CodexPicker, "Do you want to proceed?`n› 1. Yes`n  2. No")
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $false
    $ops.State.Keys | Should Be 0
  }

  It 'claude: hộp quyền (Do you want to proceed?) sau /clear -> 0 Enter, lỗi' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info)) @("Bash(rm -rf x)`nDo you want to proceed?`n❯ 1. Yes`n  2. No") '{"started":false}'
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $false
    $ops.State.Keys | Should Be 0
    @($ops.State.Sent) -join '|' | Should Be '/clear'
  }

  It 'codex: Context 100% left ĐỒNG THỜI hộp Allow command? -> chỉ /new, không gửi prompt, 0 Enter' {
    $r = New-KeepRepo
    $scr = "Allow command?`n  git push`n› 1. Yes, proceed (y)`n  2. No (esc)`ngpt-5 · Context 100% left · ~\w1"
    $ops = New-FakeOps @((New-Info 'codex')) @($scr)
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $false
    @($ops.State.Sent) -join '|' | Should Be '/new'
    $ops.State.Keys | Should Be 0
  }

  It 'codex: hộp chọn /new chung màn hình với hộp lạ -> hộp lạ thắng, 0 Enter' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info 'codex')) @("$CodexPicker`nDo you want to proceed?")
    $res = Start-Task $r 'a' $ops 'codex'
    $res.Ok | Should Be $false
    @($ops.State.Sent) -join '|' | Should Be '/new'
    $ops.State.Keys | Should Be 0
  }

  It 'claude: màn hình đã clear ĐỒNG THỜI hộp quyền -> chỉ /clear, không gửi prompt, 0 Enter' {
    $r = New-KeepRepo
    foreach ($json in '{"started":true}', '{"started":false}') {
      $ops = New-FakeOps @((New-Info)) @("$Cleared`nBash(git push)`nDo you want to proceed?`n❯ 1. Yes`n  2. No") $json
      $res = Start-Task $r "a$($json.Length)" $ops
      $res.Ok | Should Be $false
      @($ops.State.Sent) -join '|' | Should Be '/clear'
      $ops.State.Keys | Should Be 0
      git -C (Get-WorkerTree $r.Root 1) switch -q --detach main; Save-Tasks $r.Root @()
    }
  }

  It 'hộp thoại hiện ra ngay sau khi xác nhận phiên mới -> không gửi prompt' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info)) @($Cleared, "Do you want to proceed?`n❯ 1. Yes")
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $false
    $res.Message | Should Match 'hộp thoại'
    @($ops.State.Sent) -join '|' | Should Be '/clear'
    $ops.State.Keys | Should Be 0
  }

  It 'claude: màn hình chưa xóa -> hết giờ lỗi rõ, không gửi dòng giao việc' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info)) @($NotCleared)
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $false
    $res.Message | Should Match 'chưa xác nhận được màn hình đã xóa'
    @($ops.State.Sent) -join '|' | Should Be '/clear'
    $ops.State.Keys | Should Be 0
  }

  It 'claude: /clear kẹt ở ô nhập (started:false) -> Enter, rồi thấy đã xóa -> giao việc' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info)) @($NotCleared, $NotCleared, $Cleared) '{"started":false}'
    Start-Task $r 'a' $ops | Out-Null
    $ops.State.Sent[0] | Should Be '/clear'
    $ops.State.Sent.Count | Should Be 2
    # đúng 1 Enter cho /clear (trước khi gửi dòng giao việc)
    $log = @($ops.State.Log); $i2 = [array]::IndexOf($log, "send:$($ops.State.Sent[1])")
    @($log[0..$i2] | Where-Object { $_ -eq 'enter' }).Count | Should Be 1
  }

  It 'blocked ngay sau /clear: dừng, không gửi dòng giao việc, 0 Enter' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info), (New-Info), (New-Info -status 'blocked')) @($Cleared)
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $false
    $res.Message | Should Match 'chờ duyệt'
    @($ops.State.Sent) -join '|' | Should Be '/clear'
    $ops.State.Keys | Should Be 0
  }

  It 'blocked trước khi giao: lỗi rõ, không tạo nhánh, không gửi gì' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info -status 'blocked'))
    { Start-Task $r 'a' $ops } | Should Throw 'chờ duyệt'
    Test-Branch $r.Root 'crew/a' | Should Be $false
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
  }

  It 'terminal là shell (agent đã thoát) -> bật agent trong worktree với dòng giao việc làm prompt đầu' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info ''))
    $res = Start-Task $r 'a' $ops
    $res.Ok | Should Be $true
    $wt = Get-WorkerTree $r.Root 1
    $ops.State.Sent.Count | Should Be 1
    $cmd = $ops.State.Sent[0]
    $cmd | Should Match ([regex]::Escape("Set-Location -LiteralPath '$wt'"))
    $cmd | Should Match ([regex]::Escape((Get-AgentCommand 'claude' 'work' (Get-TaskLine $wt 'crew/a'))))
    $cmd | Should Not Match '/clear'
  }

  It 'terminal chạy sai loại agent -> lỗi gợi ý crew up -Restart w1, không tạo nhánh' {
    $r = New-KeepRepo
    $ops = New-FakeOps @((New-Info 'codex'))
    { Start-Task $r 'a' $ops 'claude' } | Should Throw 'crew up -Restart w1'
    Test-Branch $r.Root 'crew/a' | Should Be $false
    $ops.State.Sent.Count | Should Be 0
  }

  It 'terminal không live -> lỗi gợi ý crew up' {
    $r = New-KeepRepo
    $ops = New-FakeOps @($null)
    { Start-Task $r 'a' $ops } | Should Throw "crew up"
  }

  It 'worktree bẩn -> từ chối, nêu file, không tạo nhánh, không gửi, không ghi task' {
    $r = New-KeepRepo
    $wt = Initialize-WorkerTree $r.Root 1 'main'
    'bẩn' | Set-Content (Join-Path $wt 'x.txt')
    $ops = New-FakeOps @((New-Info))
    { Start-Task $r 'a' $ops } | Should Throw 'w1 còn thay đổi chưa commit: x.txt'
    Test-Branch $r.Root 'crew/a' | Should Be $false
    $ops.State.Sent.Count | Should Be 0
    (Get-Tasks $r.Root).Count | Should Be 0
  }
}

Describe 'crew clean bản mới + task lần 2 trên cùng worker' {
  BeforeEach { $script:HcCalls = 0 }

  It 'clean -> w1 về detached main, nhánh mất, thư mục còn, không gọi hc; task lần 2 lấy main mới nhất' {
    $r = New-KeepRepo
    (Start-Task $r 'a' (New-FakeOps @((New-Info)) @($Cleared))).Ok | Should Be $true
    $wt = Get-WorkerTree $r.Root 1
    'việc' | Set-Content (Join-Path $wt 'b.txt')
    git -C $wt add -A; git -C $wt commit -q -m work
    git -C $r.Root merge -q --ff-only crew/a
    $task = (Get-Tasks $r.Root)[0]
    Test-KeepTask $r.Root $task | Should Be $true
    $warn = Reset-WorkerTree $r.Root $task 'main' $false
    @($warn).Count | Should Be 0
    Test-Path $wt | Should Be $true
    Test-WorktreeListed $r.Root $wt | Should Be $true
    (git -C $wt branch --show-current) | Should BeNullOrEmpty
    Get-Head $wt | Should Be (Get-Head $r.Root 'main')
    Test-Branch $r.Root 'crew/a' | Should Be $false
    $script:HcCalls | Should Be 0
    Save-Tasks $r.Root @()

    # main tiến thêm sau khi clean ⇒ task lần 2 phải lấy commit mới nhất
    'mới' | Set-Content (Join-Path $r.Root 'c.txt')
    git -C $r.Root add -A; git -C $r.Root commit -q -m newer
    $ops = New-FakeOps @((New-Info)) @($Cleared)
    (Start-Task $r 'b' $ops).Ok | Should Be $true
    (git -C $wt branch --show-current) | Should Be 'crew/b'
    Get-Head $wt | Should Be (Get-Head $r.Root 'main')
    $ops.State.Sent[0] | Should Be '/clear'
  }

  It 'clean khi w1 bẩn: không -Force -> lỗi, giữ nhánh; -Force -> bỏ thay đổi, về main, xóa nhánh' {
    $r = New-KeepRepo
    (Start-Task $r 'a' (New-FakeOps @((New-Info)) @($Cleared))).Ok | Should Be $true
    $wt = Get-WorkerTree $r.Root 1
    'sửa' | Set-Content (Join-Path $wt 'a.txt')
    $task = (Get-Tasks $r.Root)[0]
    { Reset-WorkerTree $r.Root $task 'main' $false } | Should Throw 'w1 còn thay đổi chưa commit: a.txt'
    Test-Branch $r.Root 'crew/a' | Should Be $true
    (git -C $wt branch --show-current) | Should Be 'crew/a'
    Reset-WorkerTree $r.Root $task 'main' $true | Out-Null
    (git -C $wt status --porcelain) | Should BeNullOrEmpty
    (git -C $wt branch --show-current) | Should BeNullOrEmpty
    Test-Branch $r.Root 'crew/a' | Should Be $false
    Test-Path $wt | Should Be $true
  }

  It 'clean nhánh chưa merge, không -Force -> lỗi git branch, w1 đã về main nhưng nhánh còn' {
    $r = New-KeepRepo
    (Start-Task $r 'a' (New-FakeOps @((New-Info)) @($Cleared))).Ok | Should Be $true
    $wt = Get-WorkerTree $r.Root 1
    'x' | Set-Content (Join-Path $wt 'n.txt'); git -C $wt add -A; git -C $wt commit -q -m w
    { Reset-WorkerTree $r.Root (Get-Tasks $r.Root)[0] 'main' $false } | Should Throw 'git branch'
    Test-Branch $r.Root 'crew/a' | Should Be $true
  }
}

Describe 'Tương thích task cũ (worktree riêng theo task)' {
  It 'task kiểu .crew/worktrees/<tên> -> không phải keep, clean kiểu cũ gỡ worktree + nhánh' {
    $r = New-KeepRepo
    $old = Join-Path $r.Root '.crew/worktrees/cu'
    git -C $r.Root worktree add -q $old -b crew/cu HEAD 2>$null
    $task = [pscustomobject]@{ name = 'cu'; branch = 'crew/cu'; worktree = $old; worker = 1; terminal = 'x-w1' }
    Test-KeepTask $r.Root $task | Should Be $false
    $warn = Remove-TaskGit $r.Root $task $false
    @($warn).Count | Should Be 0
    Test-Path $old | Should Be $false
    Test-WorktreeListed $r.Root $old | Should Be $false
    Test-Branch $r.Root 'crew/cu' | Should Be $false
  }

  It 'Test-KeepTask nhận cả đường dẫn dấu / lẫn \' {
    $r = New-KeepRepo
    $t = [pscustomobject]@{ worktree = "$($r.Root)/.crew/worktrees/w3"; worker = 3 }
    Test-KeepTask $r.Root $t | Should Be $true
    $t.worker = 2
    Test-KeepTask $r.Root $t | Should Be $false
  }
}

Describe 'Get-RestartTargets' {
  It 'một vai' {
    @(Get-RestartTargets 'w2' 3 $true $true) -join ',' | Should Be 'w2'
    @(Get-RestartTargets 'planner' 2 $true $true) -join ',' | Should Be 'planner'
    @(Get-RestartTargets 'REV' 2 $true $true) -join ',' | Should Be 'rev'
  }
  It 'all -> mọi vai đang có trong config' {
    @(Get-RestartTargets 'all' 2 $true $true) -join ',' | Should Be 'planner,w1,w2,rev'
    @(Get-RestartTargets 'all' 1 $false $false) -join ',' | Should Be 'w1'
  }
  It 'giá trị sai hoặc vai không có -> lỗi nêu giá trị cho phép' {
    { Get-RestartTargets 'w5' 2 $true $true } | Should Throw 'planner, w1, w2, rev, all'
    { Get-RestartTargets 'rev' 2 $true $false } | Should Throw '-Restart phải là'
    { Get-RestartTargets 'xx' 2 $true $true } | Should Throw '-Restart phải là'
  }
}

Describe 'Get-WorkerMode / Test-SessionReady' {
  It 'mode theo hc get' {
    (Get-WorkerMode $null 'claude').Mode | Should Be 'dead'
    (Get-WorkerMode (New-Info -status 'blocked') 'claude').Mode | Should Be 'blocked'
    (Get-WorkerMode (New-Info '') 'codex').Mode | Should Be 'shell'
    (Get-WorkerMode (New-Info 'claude-code') 'claude').Mode | Should Be 'agent'
    (Get-WorkerMode (New-Info 'codex') 'codex').Mode | Should Be 'agent'
    (Get-WorkerMode (New-Info 'codex') 'claude').Mode | Should Be 'wrong'
    (Get-WorkerMode (New-Info 'claude-code') 'codex').Mode | Should Be 'wrong'
  }
  It 'codex sẵn sàng khi thấy Context 100% left và không working' {
    Test-SessionReady 'codex' (New-Info 'codex') "abc`nContext 100% left" | Should Be $true
    Test-SessionReady 'codex' (New-Info 'codex') 'Context 42% left' | Should Be $false
    Test-SessionReady 'codex' (New-Info 'codex' 'working') 'Context 100% left' | Should Be $false
  }
  It 'claude sẵn sàng khi idle và /clear không còn ở chân màn hình' {
    Test-SessionReady 'claude' (New-Info) $Cleared | Should Be $true
    Test-SessionReady 'claude' (New-Info) "> /clear`n> " | Should Be $true
    Test-SessionReady 'claude' (New-Info) $NotCleared | Should Be $false
    Test-SessionReady 'claude' (New-Info) "> /clear`n  /clear  Clear conversation" | Should Be $false
    Test-SessionReady 'claude' (New-Info) "xin chào`n> " | Should Be $false
    Test-SessionReady 'claude' (New-Info -status 'blocked') $Cleared | Should Be $false
  }
  It 'codex: hộp chọn của /new che chân màn hình -> chưa sẵn sàng' {
    Test-SessionReady 'codex' (New-Info 'codex') "$CodexPicker`nContext 100% left" | Should Be $false
  }
  It 'marker sẵn sàng + hộp quyền -> chưa sẵn sàng (cả codex lẫn claude)' {
    Test-SessionReady 'codex' (New-Info 'codex') "Allow command?`n› 1. Yes`nContext 100% left" | Should Be $false
    Test-SessionReady 'claude' (New-Info) "$Cleared`nDo you want to proceed?`n❯ 1. Yes" | Should Be $false
  }
}

Describe 'Get-ScreenDialog' {
  It 'đúng hộp chọn Codex /new với dòng 1 đang chọn -> codex-new' {
    Get-ScreenDialog $CodexPicker | Should Be 'codex-new'
  }
  It 'hộp chọn nhưng dòng 2 đang chọn -> other (không bấm)' {
    Get-ScreenDialog ($CodexPicker -replace '› 1\.', '  1.' -replace '  2\. Create', '› 2. Create') | Should Be 'other'
  }
  It 'hộp duyệt/quyền -> other' {
    Get-ScreenDialog "Allow command?`n› 1. Yes, proceed (y)" | Should Be 'other'
    Get-ScreenDialog "Do you want to proceed?`n❯ 1. Yes`n  2. No" | Should Be 'other'
  }
  It 'hộp chọn /new + dấu hiệu hộp khác cùng màn hình -> other (hộp lạ thắng)' {
    Get-ScreenDialog "$CodexPicker`nAllow command?" | Should Be 'other'
    Get-ScreenDialog "Do you want to proceed?`n$CodexPicker" | Should Be 'other'
    Get-ScreenDialog "$CodexPicker`n(y/n)" | Should Be 'other'
  }
  It 'màn hình thường, ô nhập kẹt /clear -> rỗng' {
    Get-ScreenDialog $NotCleared | Should Be ''
    Get-ScreenDialog $Cleared | Should Be ''
    Get-ScreenDialog 'Context 37% left' | Should Be ''
  }
}
