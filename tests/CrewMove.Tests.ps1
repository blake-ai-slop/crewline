# crew repair xử lý project đã đổi tên / chuyển thư mục (Get-MoveInfo). Hàm trích bằng AST từ crew.ps1; git thật trong $TestDrive
# (đổi tên thư mục repo + worktree thật); hc/herdr giả tiêm qua $ops; sổ tên crew trong $TestDrive (HOME giả) — không gọi hc thật.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Invoke-GitQuiet', 'Invoke-GitOrDie', 'Get-Tasks', 'Save-Tasks', 'Test-WorktreeListed', 'Get-WorkerTree', 'Initialize-WorkerTree',
  'Get-TermStatus', 'Get-SendPlan', 'Invoke-SendFlow', 'Get-WorkerMode', 'Get-TermShellState', 'Test-SessionReady', 'Get-InputBox', 'Test-SentInput', 'Send-CodexQueue', 'Get-ScreenDialog', 'Format-DirtyFiles',
  'Test-KeepTask', 'New-TaskRecord', 'Get-WorktreeMeta', 'Get-ResumeLine', 'Get-TreeState', 'Wait-WorkerReady', 'Get-ResumeCheck', 'Invoke-RepairCore',
  'Get-ReviewLevel', 'Format-ReviewMessage', 'Get-ReviewLine', 'Get-MainOp', 'Get-PendingReview', 'Get-MainRoot', 'Get-Config',
  'Get-Slug', 'Get-LegacySlug', 'Test-CrewName', 'Get-CrewName', 'ConvertTo-RootKey', 'Test-SamePath', 'Test-TermOwner', 'Get-ForeignTermError',
  'Get-MoveInfo', 'Get-MovedPath', 'ConvertTo-IdKey', 'Get-LegacyIdKey', 'Test-IdKey', 'Get-CrewIdKey', 'Get-Ids', 'Read-ProjectRegistry',
  'Save-ProjectRegistry', 'Test-OtherAlive', 'Get-NameOwner', 'Get-IdKeyOwner', 'Register-CrewName', 'Get-NameConflict',
  'Invoke-Up', 'Invoke-Task', 'Invoke-Send', 'Test-FolderOwner', 'Get-ForeignSpaceError', 'Get-CopySource', 'Quote',
  'Get-LiveTerminals', 'New-RepairOps', 'New-HcOps', 'Get-TermInfo', 'Stop-Term', 'Get-HerdrSpaces'
$want += 'Get-SessionsFile', 'New-SessionBook', 'Test-SessionId', 'Read-SessionBook', 'Save-SessionBook', 'Set-SessionRecord', 'Get-NewSessionPlan', 'Get-SessionPlan', 'Format-SessionPlan', 'Test-AgentScreen', 'Get-ResumeState', 'Wait-ResumeStates'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
$script:Said = [Collections.Generic.List[string]]::new()
function Say($msg) { $script:Said.Add([string]$msg) }
function Die($msg) { throw $msg }
function Update-ConfigName($root, $dry) { }  # ghi sổ project cũ: test ở CrewRepairAll
function Write-Host { }
$script:HcCalls = 0
function hc { $script:HcCalls++; throw 'gọi hc thật trong test' }
function herdr-app { throw 'gọi herdr-app thật trong test' }
$script:RegFile = ''
function Get-ProjectsFile { $script:RegFile }
$script:RealGit = ${function:Invoke-GitQuiet}

$Cfg = [pscustomobject]@{ name = 'app'; idKey = 'app'; planner = 'none'; workers = @('claude', 'claude'); rev = 'none'; access = 'work'; review = 'lean' }

function New-Term([string]$name, [string]$addr, [string]$cwd, [string]$state = 'idle') {
  [pscustomobject]@{ name = $name; address = $addr; state = 'live'; cwd = $cwd; status = [pscustomobject]@{ app = 'claude-code'; state = $state }; turn = 1 }
}
function New-Space([string]$id, [string]$folder, [string[]]$addrs) {
  [pscustomobject]@{ id = $id; folder = $folder; tabs = @([pscustomobject]@{ id = "tbcrew${id}workers1"; terminals = @($addrs | ForEach-Object { [pscustomobject]@{ terminal = $_ } }) }) }
}

# project 'app' (name/idKey trong config, đã vào sổ) có w1 + w2, task a dở trên w1 (1 commit). Trả root.
function New-MoveRepo([string]$base) {
  $script:RegFile = Join-Path $TestDrive "projects-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
  $dir = Join-Path $TestDrive "$base-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
  $root = Join-Path $dir 'app'
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path $root).Path
  git -C $root init -q -b main
  git -C $root config user.name t; git -C $root config user.email t@t; git -C $root config core.autocrlf false
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  'a' | Set-Content (Join-Path $root 'a.txt')
  git -C $root add -A; git -C $root commit -q -m init
  $Cfg | ConvertTo-Json | Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
  Initialize-WorkerTree $root 1 'main' | Out-Null
  Initialize-WorkerTree $root 2 'main' | Out-Null
  $wt = Get-WorkerTree $root 1
  git -C $wt switch -q -c crew/a main
  New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
  'prompt' | Set-Content (Join-Path $wt '.crew/prompt.md')
  'x' | Set-Content (Join-Path $wt 'n.txt'); git -C $wt add -A; git -C $wt commit -q -m a
  Save-Tasks $root @(New-TaskRecord 'a' 'crew/a' $wt 1 'app-w1' 'claude' '')
  Register-CrewName 'app' $root 'app' | Should Be $true | Out-Null
  $root
}

# đổi tên thư mục project (repo + worktree bên trong) — cách người dùng hay làm. Trả root mới.
function Move-Project([string]$root, [string]$newLeaf = 'app-moi') {
  $new = Join-Path (Split-Path $root -Parent) $newLeaf
  Move-Item -LiteralPath $root -Destination $new
  (Resolve-Path $new).Path
}

# hc/herdr giả: $live = terminal live (hc ls); $spaces = herdr-app ls; Up bật mọi vai thiếu ở root mới.
function New-MoveOps([string]$newRoot, $live, $spaces) {
  $st = @{ Live = [Collections.Generic.List[object]]::new(); Spaces = [Collections.Generic.List[object]]::new(); Killed = [Collections.Generic.List[string]]::new()
    Closed = [Collections.Generic.List[string]]::new(); Up = 0; Keys = 0; Sent = [Collections.Generic.List[string]]::new(); Ri = 0 }
  foreach ($t in @($live)) { $st.Live.Add($t) }
  foreach ($s in @($spaces)) { $st.Spaces.Add($s) }
  @{
    State      = $st
    Get        = { param($t) $st.Live | Where-Object { $_.name -eq $t } | Select-Object -First 1 }.GetNewClosure()
    List       = { @($st.Live) }.GetNewClosure()
    Spaces     = { @{ Ok = $true; Spaces = @($st.Spaces) } }.GetNewClosure()
    Kill       = { param($a) $st.Killed.Add($a); foreach ($t in @($st.Live | Where-Object { $_.address -eq $a })) { [void]$st.Live.Remove($t) } }.GetNewClosure()
    CloseSpace = { param($id) $st.Closed.Add($id); foreach ($s in @($st.Spaces | Where-Object { $_.id -eq $id })) { [void]$st.Spaces.Remove($s) }; @{ Code = 0; Text = '' } }.GetNewClosure()
    Send       = { param($t, $x, $sh) $st.Sent.Add($x); @{ Code = 0; Text = '{"started":true}' } }.GetNewClosure()
    Keys       = { param($t) $st.Keys++ }.GetNewClosure()
    Sleep      = { param($ms) }
    Read       = { param($t) $st.Ri++; '' }.GetNewClosure()
    Up         = {
      $st.Up++
      foreach ($n in 'app-w1', 'app-w2') {
        if (-not @($st.Live | Where-Object { $_.name -eq $n }).Count) {
          $i = $n.Substring(4)  # closure không thấy New-Term của test ⇒ dựng object tại chỗ
          $st.Live.Add([pscustomobject]@{ name = $n; address = "n$i"; state = 'live'; cwd = (Join-Path $newRoot ".crew/worktrees/$i")
              status = [pscustomobject]@{ app = 'claude-code'; state = 'idle' }; turn = 1 })
        }
      }
    }.GetNewClosure()
  }
}

# terminal w1/w2 + space của crew vẫn chạy ở root cũ (sau khi chuyển thư mục)
function Get-OldLive([string]$old) {
  @((New-Term 'app-w1' 't1' (Join-Path $old '.crew/worktrees/w1') 'working'), (New-Term 'app-w2' 't2' (Join-Path $old '.crew/worktrees/w2')))
}

function Get-Snapshot([string]$root) {
  @{
    Tasks = [IO.File]::ReadAllText((Join-Path $root '.crew/tasks.json'))
    Reg   = [IO.File]::ReadAllText($script:RegFile)
    Wt    = (git -C $root worktree list --porcelain) -join "`n"
    Refs  = (git -C $root for-each-ref --format='%(refname) %(objectname)') -join "`n"
    Wt1   = [IO.File]::ReadAllText((Join-Path $root '.crew/worktrees/w1/.git'))
  }
}

Describe 'Get-MoveInfo' {
  It 'sổ ghi tên này cho root cũ đã mất -> đã chuyển (không cần hc/herdr)' {
    $old = New-MoveRepo 'gm1'; $new = Move-Project $old
    $m = Get-MoveInfo $new $Cfg @() @()
    $m.Moved | Should Be $true
    $m.OldRoot | Should Be $old
    $m.Hint | Should Be "project đã chuyển từ $old, chạy crew repair"
  }

  It 'sổ trống nhưng space spcrewapp + terminal trong đó ở root cũ đã mất -> đã chuyển, Terms/Spaces đúng' {
    $old = New-MoveRepo 'gm2'; $new = Move-Project $old
    [IO.File]::WriteAllText($script:RegFile, '{}')
    $live = Get-OldLive $old
    $m = Get-MoveInfo $new $Cfg $live @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $m.Moved | Should Be $true
    $m.OldRoot | Should Be $old
    (@($m.Terms | ForEach-Object { $_.name }) -join ',') | Should Be 'app-w1,app-w2'
    @($m.Spaces).Count | Should Be 1
  }

  It 'terminal cùng tên ở thư mục mất nhưng không thuộc space spcrewapp, sổ không biết -> không coi là chuyển (không rõ idKey)' {
    $old = New-MoveRepo 'gm3'; $new = Move-Project $old
    [IO.File]::WriteAllText($script:RegFile, '{}')
    $m = Get-MoveInfo $new $Cfg (Get-OldLive $old) @(New-Space 'spcrewkhac' $old @('t1', 't2'))
    $m.Moved | Should Be $false
    @($m.Terms).Count | Should Be 0
  }

  It 'sổ ghi tên này nhưng idKey khác -> không dùng mục sổ đó' {
    $old = New-MoveRepo 'gm4'; $new = Move-Project $old
    [IO.File]::WriteAllText($script:RegFile, (@{ app = @{ root = $old; idKey = 'khac' } } | ConvertTo-Json))
    (Get-MoveInfo $new $Cfg @() @()).Moved | Should Be $false
  }

  It 'root cũ CÒN tồn tại (chép thư mục) -> không coi là chuyển, kể cả terminal/space ở root cũ' {
    $old = New-MoveRepo 'gm5'
    $copy = Join-Path (Split-Path $old -Parent) 'app-copy'
    Copy-Item -LiteralPath $old -Destination $copy -Recurse
    $m = Get-MoveInfo $copy $Cfg (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $m.Moved | Should Be $false
    @($m.Terms).Count | Should Be 0
    @($m.Spaces).Count | Should Be 0
  }

  It 'project không chuyển (sổ + terminal + space ở chính root) -> không chuyển' {
    $root = New-MoveRepo 'gm6'
    $live = @(New-Term 'app-w1' 't1' (Join-Path $root '.crew/worktrees/w1'))
    (Get-MoveInfo $root $Cfg $live @(New-Space 'spcrewapp' $root @('t1'))).Moved | Should Be $false
  }

  It 'Get-MovedPath: trong root cũ -> dưới root mới; ngoài -> giữ nguyên; tiền tố tên không tính' {
    $old = Join-Path $TestDrive 'p/app'; $new = Join-Path $TestDrive 'q/app2'
    Get-MovedPath (Join-Path $old '.crew/worktrees/w1') $old $new | Should Be ([IO.Path]::GetFullPath((Join-Path $new '.crew/worktrees/w1')))
    Get-MovedPath $old $old $new | Should Be (ConvertTo-RootKey $new)
    Get-MovedPath (Join-Path $TestDrive 'p/app-2/x') $old $new | Should Be (Join-Path $TestDrive 'p/app-2/x')
  }
}

Describe 'ranh giới đã chuyển (Get-MoveInfo) / bản chép (Get-CopySource), code thật của cả hai' {
  It 'cùng sổ + config: root cũ còn -> CopySource = root cũ, Moved = false; root cũ mất -> Moved = true, CopySource rỗng' {
    $old = New-MoveRepo 'bd1'
    $copy = Join-Path (Split-Path $old -Parent) 'app-copy'
    Copy-Item -LiteralPath $old -Destination $copy -Recurse
    $cfg = Get-Config $copy
    Get-CopySource $copy $cfg | Should Be (ConvertTo-RootKey $old)
    (Get-MoveInfo $copy $cfg @() @()).Moved | Should Be $false
    Remove-Item -LiteralPath $old -Recurse -Force
    Get-CopySource $copy $cfg | Should Be ''
    $m = Get-MoveInfo $copy $cfg @() @()
    $m.Moved | Should Be $true
    $m.OldRoot | Should Be (ConvertTo-RootKey $old)
  }
}

Describe 'crew repair: project đã chuyển thư mục (git thật, hc giả)' {
  BeforeEach { $script:HcCalls = 0; $script:Said.Clear() }

  It 'chạy thật: worktree repair, tasks.json + sổ trỏ root mới, kill terminal root cũ, đóng space cũ, bật lại + giao lại task, 0 xóa nhánh' {
    $old = New-MoveRepo 'rp1'
    $refs = (git -C $old for-each-ref --format='%(refname) %(objectname)') -join "`n"
    $new = Move-Project $old
    (git -C $new worktree list --porcelain) -join "`n" | Should Match 'prunable'
    $ops = New-MoveOps $new (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false $ops
    @($res.Human) -join '|' | Should Be ''
    # git worktree repair: w1/w2 ở đường dẫn mới, đọc được nhánh, không còn prunable, không mất metadata
    $wt1 = Get-WorkerTree $new 1; $wt2 = Get-WorkerTree $new 2
    $list = (git -C $new worktree list --porcelain) -join "`n"
    $list | Should Not Match 'prunable'
    Test-WorktreeListed $new $wt1 | Should Be $true
    Test-WorktreeListed $new $wt2 | Should Be $true
    (git -C $wt1 branch --show-current) | Should Be 'crew/a'
    (git -C $new for-each-ref --format='%(refname) %(objectname)') -join "`n" | Should Be $refs
    # tasks.json + sổ
    $t = Get-Tasks $new
    $t.Count | Should Be 1
    $t[0].worktree | Should Be $wt1
    $t[0].branch | Should Be 'crew/a'
    $reg = (Read-ProjectRegistry).Map
    $reg['app'].Root | Should Be (ConvertTo-RootKey $new)
    $reg['app'].IdKey | Should Be 'app'
    # terminal root cũ bị kill, space cũ đóng, bật lại qua Up, giao lại đúng 1 dòng, 0 Enter
    (@($ops.State.Killed) -join ',') | Should Be 't1,t2'
    (@($ops.State.Closed) -join ',') | Should Be 'spcrewapp'
    $ops.State.Up | Should Be 1
    $ops.State.Sent.Count | Should Be 1
    $ops.State.Sent[0] | Should Be (Get-ResumeLine 'a' $wt1 'crew/a')
    $ops.State.Keys | Should Be 0
    @($res.Sent) -join ',' | Should Be 'a'
    # sau repair: không còn coi là chuyển
    (Get-MoveInfo $new $Cfg @(& $ops.List) (& $ops.Spaces).Spaces).Moved | Should Be $false
    $script:HcCalls | Should Be 0
  }

  It '-DryRun: in đủ từng việc (sẽ làm), 0 thay đổi git/tasks/sổ, 0 Kill/Close/Up/Send/Keys' {
    $old = New-MoveRepo 'rp2'; $new = Move-Project $old
    $before = Get-Snapshot $new
    $ops = New-MoveOps $new (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $true $ops
    $d = @($res.Done) -join '|'
    @($res.Done | Where-Object { $_ -notlike '(sẽ làm)*' }).Count | Should Be 0
    $d | Should Match ([regex]::Escape("(sẽ làm) git worktree repair $(Get-WorkerTree $new 1) $(Get-WorkerTree $new 2)"))
    $d | Should Match ([regex]::Escape("(sẽ làm) tasks.json: worktree a: $(Get-WorkerTree $old 1) -> $(Get-WorkerTree $new 1)"))
    $d | Should Match ([regex]::Escape("(sẽ làm) sổ $($script:RegFile): app -> $new (giữ tên, idKey app)"))
    $d | Should Match ([regex]::Escape('(sẽ làm) kill app-w1 (t1)'))
    $d | Should Match ([regex]::Escape('(sẽ làm) kill app-w2 (t2)'))
    $d | Should Match ([regex]::Escape('(sẽ làm) đóng space spcrewapp'))
    $d | Should Match ([regex]::Escape('(sẽ làm) bật terminal thiếu qua crew up: app-w1, app-w2'))
    $d | Should Match ([regex]::Escape('(sẽ làm) giao lại task a -> app-w1'))
    $d | Should Not Match 'prune'
    @($res.Human) -join '|' | Should Be ''
    $after = Get-Snapshot $new
    foreach ($k in $before.Keys) { $after[$k] | Should Be $before[$k] }
    $ops.State.Killed.Count | Should Be 0
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $ops.State.Keys | Should Be 0
    $ops.State.Ri | Should Be 0
    $script:HcCalls | Should Be 0
  }

  It 'repro Rev P1: git worktree repair lỗi (exit 1) -> dừng: 0 prune/kill/close/up/Save-Tasks/ghi sổ, metadata .git/worktrees còn nguyên' {
    $old = New-MoveRepo 'rp6'; $new = Move-Project $old
    $before = Get-Snapshot $new
    $meta = @(Get-ChildItem -LiteralPath (Join-Path $new '.git/worktrees') -Recurse -File | ForEach-Object { "$($_.FullName)=$([IO.File]::ReadAllText($_.FullName))" }) -join "`n"
    $script:GitCalls = [Collections.Generic.List[string]]::new()
    function Invoke-GitQuiet { $script:GitCalls.Add("$args"); if ($args -contains 'repair') { return [pscustomobject]@{ Code = 1; Text = 'lỗi giả' } }; & $script:RealGit @args }
    $ops = New-MoveOps $new (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false $ops
    $h = @($res.Human) -join '|'
    $h | Should Match 'git worktree repair lỗi \(mã 1\): lỗi giả — repair dừng'
    $h | Should Match ([regex]::Escape("git -C '$new' worktree repair"))
    @($script:GitCalls | Where-Object { $_ -match 'prune' }).Count | Should Be 0
    $ops.State.Killed.Count | Should Be 0
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    $after = Get-Snapshot $new
    foreach ($k in $before.Keys) { $after[$k] | Should Be $before[$k] }
    (@(Get-ChildItem -LiteralPath (Join-Path $new '.git/worktrees') -Recurse -File | ForEach-Object { "$($_.FullName)=$([IO.File]::ReadAllText($_.FullName))" }) -join "`n") | Should Be $meta
  }

  It 'repro Rev P2: terminal lạ t9 vào space cũ SAU kill -> đọc lại trước Close: 0 Close, 0 Up, cần người' {
    $old = New-MoveRepo 'rp7'; $new = Move-Project $old
    $ops = New-MoveOps $new (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $st = $ops.State; $kill = $ops.Kill
    $ops.Kill = {
      param($a) & $kill $a
      if (-not @($st.Live | Where-Object { $_.address -eq 't9' }).Count) {
        $st.Live.Add([pscustomobject]@{ name = 'la'; address = 't9'; state = 'live'; cwd = $old })
        $sp = $st.Spaces[0]; $sp.tabs[0].terminals = @($sp.tabs[0].terminals) + [pscustomobject]@{ terminal = 't9' }
      }
    }.GetNewClosure()
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false $ops
    (@($ops.State.Killed) -join ',') | Should Be 't1,t2'
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    (@($res.Human) -join '|') | Should Match 'space spcrewapp .*còn terminal live t9 — không đóng, không bật lại'
    (@($res.Human) -join '|') | Should Match 'chưa bật terminal thiếu'
  }

  It 'terminal root cũ vẫn live sau kill -> không đóng space, không bật lại, cần người' {
    $old = New-MoveRepo 'rp8'; $new = Move-Project $old
    $ops = New-MoveOps $new (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $st = $ops.State
    $ops.Kill = { param($a) $st.Killed.Add($a) }.GetNewClosure()  # kill "thành công" nhưng terminal không tắt
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false $ops
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    (@($res.Human) -join '|') | Should Match 'vẫn live sau kill: t1, t2'
  }

  It 'space cũ còn terminal khác (không phải của crew) -> không đóng, không bật lại (crew up sẽ lỗi), cần người' {
    $old = New-MoveRepo 'rp3'; $new = Move-Project $old
    $live = @(Get-OldLive $old) + @(New-Term 'shell-rieng' 't9' $old)
    $ops = New-MoveOps $new $live @(New-Space 'spcrewapp' $old @('t1', 't2', 't9'))
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false $ops
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    $ops.State.Sent.Count | Should Be 0
    (@($res.Human) -join '|') | Should Match 'space spcrewapp .*còn terminal khác t9 — không đóng'
    (@($res.Human) -join '|') | Should Match 'chưa bật terminal thiếu'
    # phần git/tasks/sổ vẫn đã sửa (an toàn, không phụ thuộc space)
    (Get-Tasks $new)[0].worktree | Should Be (Get-WorkerTree $new 1)
    (git -C (Get-WorkerTree $new 1) branch --show-current) | Should Be 'crew/a'
  }

  It 'project độc lập trùng idKey với project khác (còn hoặc đã xóa, space spcrewapp còn) -> không coi là chuyển, 0 thay đổi' {
    $root = New-MoveRepo 'rp5'
    $parent = Split-Path $root -Parent
    $alive = Join-Path $parent 'khac'; New-Item -ItemType Directory -Force (Join-Path $alive '.crew') | Out-Null
    '{"name":"khac","idKey":"app"}' | Set-Content (Join-Path $alive '.crew/config.json')
    $deleted = Join-Path $parent 'da-xoa'
    $map = (Read-ProjectRegistry).Map; $map['khac'] = @{ Root = $alive; IdKey = 'app' }; $map['da-xoa'] = @{ Root = $deleted; IdKey = 'app' }
    Save-ProjectRegistry $map
    $before = Get-Snapshot $root
    foreach ($folder in $alive, $deleted) {
      $live = @((New-Term 'khac-w1' 't7' (Join-Path $folder '.crew/worktrees/w1')), (New-Term 'app-w1' 't8' (Join-Path $root '.crew/worktrees/w1')))
      $sp = @(New-Space 'spcrewapp' $folder @('t7'))
      (Get-MoveInfo $root $Cfg $live $sp).Moved | Should Be $false
      foreach ($dry in $true, $false) {
        $ops = New-MoveOps $root $live $sp
        $res = Invoke-RepairCore $root $Cfg 'app' 'main' $dry $ops
        (@($res.Done) -join '|') | Should Not Match 'worktree repair|tasks.json|sổ|kill|đóng space'
        $ops.State.Killed.Count | Should Be 0
        $ops.State.Closed.Count | Should Be 0
      }
    }
    $after = Get-Snapshot $root
    foreach ($k in $before.Keys) { $after[$k] | Should Be $before[$k] }
  }

  It 'root cũ còn tồn tại (bản chép) -> repair không coi là chuyển: 0 kill/close/sửa sổ, terminal root cũ là KHÁC PROJECT' {
    $old = New-MoveRepo 'rp4'
    $copy = Join-Path (Split-Path $old -Parent) 'app-copy'
    Copy-Item -LiteralPath $old -Destination $copy -Recurse
    $reg = [IO.File]::ReadAllText($script:RegFile)
    $ops = New-MoveOps $copy (Get-OldLive $old) @(New-Space 'spcrewapp' $old @('t1', 't2'))
    $res = Invoke-RepairCore $copy $Cfg 'app' 'main' $false $ops
    $ops.State.Killed.Count | Should Be 0
    $ops.State.Closed.Count | Should Be 0
    $ops.State.Up | Should Be 0
    [IO.File]::ReadAllText($script:RegFile) | Should Be $reg
    (@($res.Human) -join '|') | Should Match 'project khác'
  }
}

Describe 'up/task gặp project đã chuyển -> 1 dòng gợi ý repair, 0 Start/Send' {
  BeforeEach {
    $script:Started = [Collections.Generic.List[string]]::new(); $script:HcCalls = 0
    function Get-Root($p) { $p }
    function Get-MainBranch($p) { 'main' }
    function Start-Term($n, $cwd, $sp, $tab, $cmd) { $script:Started.Add($n); @{ address = 'tx' } }
    function Start-WorkerTerm($r, $c, $ids, $slug, $n, $m) { $script:Started.Add("$slug-w$n"); @{ address = "t$n" } }
    function Stop-Term($a) { $script:Started.Add("kill $a") }
    function Wait-Tab($t) { $false }
    function Show-StartupTrust($r, $o) { }
    $script:Ops = New-MoveOps 'x' @() @()
    function New-HcOps { $script:Ops }
  }

  It 'crew up: dừng với "project đã chuyển từ <cũ>, chạy crew repair" thay vì báo trùng tên/khác project' {
    $old = New-MoveRepo 'up1'; $new = Move-Project $old
    $script:OldLive = Get-OldLive $old
    function Get-LiveTerminals { $script:OldLive }
    $script:Spaces = @{ Ok = $true; Spaces = @(New-Space 'spcrewapp' $old @('t1', 't2')) }
    function Get-HerdrSpaces { $script:Spaces }
    $Path = $new; $Restart = ''; $Force = $false
    { Invoke-Up } | Should Throw "project đã chuyển từ $old, chạy crew repair"
    $script:Started.Count | Should Be 0
  }

  It 'crew task: dừng với dòng gợi ý repair, không ghi task, 0 Send/Keys' {
    $old = New-MoveRepo 'tk1'; $new = Move-Project $old
    function Get-LiveTerminals { @() }
    function Get-HerdrSpaces { @{ Ok = $false; Spaces = @(); Error = 'không có herdr-app' } }
    $prompt = Join-Path $TestDrive 'p-move.md'; 'việc' | Set-Content $prompt -Encoding utf8
    $tasks = [IO.File]::ReadAllText((Join-Path $new '.crew/tasks.json'))
    $Name = 'b'; $PromptFile = $prompt; $Worker = 0; $InitParameters = @{}
    Push-Location $new
    try { { Invoke-Task } | Should Throw "project đã chuyển từ $old, chạy crew repair" } finally { Pop-Location }
    $script:Ops.State.Sent.Count | Should Be 0
    $script:Ops.State.Keys | Should Be 0
    [IO.File]::ReadAllText((Join-Path $new '.crew/tasks.json')) | Should Be $tasks
    (git -C $new branch --list crew/b) | Should BeNullOrEmpty
  }

  It 'crew send tới terminal của crew: dừng với dòng gợi ý repair, 0 Send' {
    $old = New-MoveRepo 'sd1'; $new = Move-Project $old
    function Get-LiveTerminals { @() }
    function Get-HerdrSpaces { @{ Ok = $false; Spaces = @(); Error = 'x' } }
    $Name = 'app-w1'; $PromptFile = 'xin chào'; $Raw = [switch]$false
    Push-Location $new
    try { { Invoke-Send } | Should Throw 'chạy crew repair' } finally { Pop-Location }
    $script:Ops.State.Sent.Count | Should Be 0
  }
}

# hc / herdr-app giả ở mức LỆNH (đi qua adapter thật New-RepairOps → Get-LiveTerminals/Get-HerdrSpaces/Stop-Term).
# $script:Hc.LsAfterKill: 'ok' (JSON đúng) | 'fail' (exit 1, stdout rỗng) | 'bad' (JSON hỏng) | 'null' / 'object' (terminals không phải mảng) | 'nostate' / 'noaddr' (phần tử thiếu field), exit 0; $script:Hc.LateT9: thêm t9 lạ vào space sau kill.
function Set-FakeCli([string]$old, [string]$after, [bool]$lateT9) {
  $script:Hc = @{ Live = [Collections.Generic.List[object]]::new(); Killed = [Collections.Generic.List[string]]::new(); Closed = [Collections.Generic.List[string]]::new()
    LsAfterKill = $after; LateT9 = $lateT9; Up = 0; Sends = 0
    Spaces = [Collections.Generic.List[object]]::new() }
  foreach ($t in (Get-OldLive $old)) { $script:Hc.Live.Add($t) }
  $script:Hc.Spaces.Add((New-Space 'spcrewapp' $old @('t1', 't2')))
}

Describe 'crew repair: adapter thật (New-RepairOps) khi hc ls lỗi sau kill' {
  BeforeEach {
    function hc {
      $h = $script:Hc; $global:LASTEXITCODE = 0; $a1 = $args[1]  # $args trong Where-Object là của scriptblock đó
      switch ($args[0]) {
        'ls' {
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'fail') { $global:LASTEXITCODE = 1; return }
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'bad') { return '{"terminals": [' }
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'null') { return '{"terminals": null}' }
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'object') { return '{"terminals": {"unexpected": true}}' }
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'nostate') { return '{"terminals": [{"name": "la", "address": "t9", "cwd": "x"}]}' }
          if ($h.Killed.Count -and $h.LsAfterKill -eq 'noaddr') { return '{"terminals": [{"name": "la", "state": "live", "cwd": "x"}]}' }
          return (@{ terminals = @($h.Live) } | ConvertTo-Json -Depth 6)
        }
        'kill' {
          $h.Killed.Add($a1)
          foreach ($t in @($h.Live | Where-Object { $_.address -eq $a1 })) { [void]$h.Live.Remove($t) }
          if ($h.LateT9 -and -not @($h.Live | Where-Object { $_.address -eq 't9' }).Count) {
            $h.Live.Add([pscustomobject]@{ name = 'la'; address = 't9'; state = 'live'; cwd = 'x' })
            $sp = $h.Spaces[0]; $sp.tabs[0].terminals = @($sp.tabs[0].terminals) + [pscustomobject]@{ terminal = 't9' }
          }
          return
        }
        'rm' { return }
        'get' { $t = $h.Live | Where-Object { $_.name -eq $a1 } | Select-Object -First 1; if (-not $t) { $global:LASTEXITCODE = 1; return }; return ($t | ConvertTo-Json -Depth 6) }
        'send' { $h.Sends++; return '{"started":true}' }
        default { $global:LASTEXITCODE = 1; return }
      }
    }
    function herdr-app {
      $h = $script:Hc; $global:LASTEXITCODE = 0
      if ($args[0] -eq 'ls') { return (@{ spaces = @($h.Spaces) } | ConvertTo-Json -Depth 8) }
      $id = $args[3]
      if ($args[0] -eq 'do' -and $args[1] -eq 'space.close') { $h.Closed.Add($id); foreach ($x in @($h.Spaces | Where-Object { $_.id -eq $id })) { [void]$h.Spaces.Remove($x) }; return }
      $global:LASTEXITCODE = 1
    }
    function Invoke-Up { $script:Hc.Up++ }
  }

  foreach ($mode in 'fail', 'bad', 'null', 'object', 'nostate', 'noaddr') {
    It "hc ls $mode sau kill + t9 lạ vào space -> 0 Close, 0 Up, 0 Send, Human có dòng" {
      $old = New-MoveRepo "ad-$mode"; $new = Move-Project $old
      Set-FakeCli $old $mode $true
      $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false (New-RepairOps)
      (@($script:Hc.Killed) -join ',') | Should Be 't1,t2'
      $script:Hc.Closed.Count | Should Be 0
      $script:Hc.Up | Should Be 0
      $script:Hc.Sends | Should Be 0
      $h = @($res.Human) -join '|'
      $h | Should Match 'không đọc lại được hc ls sau kill'
      $h | Should Match 'space spcrewapp .*không đóng, không bật lại'
    }
  }

  It 'hc ls lỗi ngay từ đầu -> repair dừng, 0 Kill/Close/Up/Send/thay đổi' {
    $old = New-MoveRepo 'ad-first'; $new = Move-Project $old
    Set-FakeCli $old 'ok' $false
    $before = Get-Snapshot $new
    $script:Hc.Killed.Add('gia')  # ls lỗi ngay
    $script:Hc.LsAfterKill = 'fail'
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false (New-RepairOps)
    $script:Hc.Killed.Count | Should Be 1
    $script:Hc.Closed.Count | Should Be 0
    $script:Hc.Up | Should Be 0
    (@($res.Human) -join '|') | Should Match 'hc ls --json lỗi \(exit 1\).*repair dừng'
    $after = Get-Snapshot $new
    foreach ($k in $before.Keys) { $after[$k] | Should Be $before[$k] }
  }

  It 'hc ls thành công với terminals [] sau kill -> vẫn chạy bình thường: đóng space cũ, gọi crew up' {
    $old = New-MoveRepo 'ad-ok'; $new = Move-Project $old
    Set-FakeCli $old 'ok' $false
    $res = Invoke-RepairCore $new $Cfg 'app' 'main' $false (New-RepairOps)
    (@($script:Hc.Killed) -join ',') | Should Be 't1,t2'
    (@($script:Hc.Closed) -join ',') | Should Be 'spcrewapp'
    $script:Hc.Up | Should Be 1
    (@($res.Human) -join '|') | Should Not Match 'hc ls'
  }
}

Describe 'Get-LiveTerminals phân biệt thành công rỗng với lỗi' {
  It 'exit 1 rỗng / JSON hỏng / thiếu terminals -> throw có exit code; terminals [] -> mảng rỗng' {
    function hc { $global:LASTEXITCODE = 1 }
    { Get-LiveTerminals } | Should Throw 'hc ls --json lỗi (exit 1)'
    function hc { $global:LASTEXITCODE = 0; '{"terminals": [' }
    { Get-LiveTerminals } | Should Throw 'JSON hỏng (exit 0)'
    function hc { $global:LASTEXITCODE = 0; '{"x": 1}' }
    { Get-LiveTerminals } | Should Throw "thiếu mảng 'terminals'"
    function hc { $global:LASTEXITCODE = 0; '' }
    { Get-LiveTerminals } | Should Throw "thiếu mảng 'terminals'"
    function hc { $global:LASTEXITCODE = 0; '{"terminals": []}' }
    @(Get-LiveTerminals).Count | Should Be 0
    function hc { $global:LASTEXITCODE = 0; '{"terminals": [{"name": "a", "state": "live", "address": "t1"}, {"name": null, "state": "live", "address": "t2"}]}' }
    (Get-LiveTerminals)[0].name | Should Be 'a'
    @(Get-LiveTerminals).Count | Should Be 2
  }

  It 'terminal chưa đặt tên (hc bỏ khóa name, như pane tự mở trong herdr) -> không lỗi, name = null' {
    function hc { $global:LASTEXITCODE = 0; '{"hidden_finished":12,"terminals":[{"address":"t30","agent":"pwsh.exe","cwd":"C:\\x","state":"live","turn":0,"where":"Crewline / 1"},{"name":"a","state":"live","address":"t31"}]}' }
    $r = @(Get-LiveTerminals)
    $r.Count | Should Be 2
    $r[0].PSObject.Properties.Name -contains 'name' | Should Be $true
    $r[0].name | Should BeNullOrEmpty
    $r[1].name | Should Be 'a'
  }

  It 'exit 0 nhưng terminals không phải mảng / phần tử sai shape -> throw, không lọc thành rỗng' {
    $bad = @{
      '{"terminals": null}'                                                        = "'terminals' không phải mảng \(null"
      '{"terminals": {"unexpected": true}}'                                        = "'terminals' không phải mảng"
      '{"terminals": 5}'                                                           = "'terminals' không phải mảng"
      '{"terminals": [1]}'                                                         = 'terminals\[0\] không phải object'
      '{"terminals": [null]}'                                                      = 'terminals\[0\] không phải object'
      '{"terminals": [{"name": "a", "address": "t1"}]}'                            = "terminals\[0\] thiếu/sai 'state'"
      '{"terminals": [{"name": "a", "state": "live"}]}'                            = "terminals\[0\] thiếu/sai 'address'"
      '{"terminals": [{"name": "a", "state": "live", "address": 7}]}'              = "thiếu/sai 'address'"
      '{"terminals": [{"name": "a", "state": "live", "address": ""}]}'             = "thiếu/sai 'address'"
      '{"terminals": [{"name": {"x": 1}, "state": "live", "address": "t1"}]}'      = "thiếu/sai 'name'"
      '{"terminals": [{"name": "a", "state": "live", "address": "t1"}, {"x": 1}]}' = 'terminals\[1\]'
    }
    foreach ($k in $bad.Keys) {
      $script:Out = $k
      function hc { $global:LASTEXITCODE = 0; $script:Out }
      $err = try { Get-LiveTerminals | Out-Null; '' } catch { $_.Exception.Message }
      $err | Should Match $bad[$k]
      $err | Should Match 'exit 0'
    }
  }
}
