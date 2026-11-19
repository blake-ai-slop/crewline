. (Join-Path $PSScriptRoot 'CrewAst.ps1')
. "$PSScriptRoot/TestHome.ps1"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# U14: crew task / crew queue chặn tên task đã merge vào nhánh chính (commit merge "Merge crew/<tên>"), -Force chỉ cảnh báo.
# Hàm Get-MergedTaskInfo trích bằng AST, git thật trong thư mục tạm; e2e chạy crew.ps1 thật với hc/claude giả trong HOME giả.
$repo = Split-Path $PSScriptRoot -Parent
$crewScript = Join-Path $repo 'scripts/crew.ps1'
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
foreach ($fn in (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Invoke-GitQuiet', 'Get-MergedTaskInfo' } -Recurse:$false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

function Invoke-TGit([string]$root) { & git -C $root -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git $args lỗi" } }
# Tạo nhánh crew/<tên> có một commit, merge --no-ff vào main với tiêu đề $title (body tùy chọn), xóa nhánh như crew clean.
function Add-Merge([string]$root, [string]$name, [string]$title, [string]$body = '') {
  Invoke-TGit $root switch -q -c "crew/$name"
  "$name" | Set-Content (Join-Path $root "$name.txt")
  Invoke-TGit $root add -A
  Invoke-TGit $root commit -qm "work $name"
  Invoke-TGit $root switch -q main
  $msg = if ($body) { "$title`n`n$body" } else { $title }
  Invoke-TGit $root merge -q --no-ff "crew/$name" -m $msg
  Invoke-TGit $root branch -q -D "crew/$name"
}
function New-TRepo {
  $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $root | Out-Null
  Invoke-TGit $root init -q -b main
  'x' | Set-Content (Join-Path $root 'a.txt')
  Invoke-TGit $root add -A
  Invoke-TGit $root commit -qm init
  $root
}

Describe 'Get-MergedTaskInfo (git thật)' {
  It 'đúng tên ⇒ hash ngắn + ngày của merge mới nhất; không khớp tiền tố; tiêu đề có/không đuôi' {
    $root = New-TRepo
    Add-Merge $root 'neg-num' 'Merge crew/neg-num: số âm'
    Add-Merge $root 'plain' 'Merge crew/plain'
    $m = Get-MergedTaskInfo $root main 'neg-num'
    $m | Should Not BeNullOrEmpty
    $m.Hash | Should Be (git -C $root log -1 --format=%h --grep 'neg-num' --merges)
    $m.Date | Should Match '^\d{4}-\d{2}-\d{2}$'
    Get-MergedTaskInfo $root main 'neg' | Should BeNullOrEmpty
    Get-MergedTaskInfo $root main 'num' | Should BeNullOrEmpty
    Get-MergedTaskInfo $root main 'neg-nu' | Should BeNullOrEmpty
    (Get-MergedTaskInfo $root main 'plain').Hash | Should Be (git -C $root log -1 --format=%h)
    Get-MergedTaskInfo $root main 'other' | Should BeNullOrEmpty
  }

  It 'chỉ tính tiêu đề merge: dòng body "Merge crew/<tên>" hay commit thường không chặn' {
    $root = New-TRepo
    Add-Merge $root 'a' 'Merge crew/a: xong' "Merge crew/hidden ở body"
    Get-MergedTaskInfo $root main 'hidden' | Should BeNullOrEmpty
    'y' | Set-Content (Join-Path $root 'b.txt'); Invoke-TGit $root add -A; Invoke-TGit $root commit -qm 'Merge crew/fake (commit thường)'
    Get-MergedTaskInfo $root main 'fake' | Should BeNullOrEmpty
  }

  It 'tiêu đề merge mặc định của git (branch / remote-tracking, có/không " into <nhánh>") ⇒ chặn; vẫn đúng tên' {
    $root = New-TRepo
    Add-Merge $root 'cube-num' "Merge branch 'crew/cube-num'"
    $h1 = git -C $root log -1 --format=%h
    Add-Merge $root 'neg-num' "Merge branch 'crew/neg-num' into main"
    $h2 = git -C $root log -1 --format=%h
    Add-Merge $root 'far' "Merge remote-tracking branch 'origin/crew/far'"
    $h3 = git -C $root log -1 --format=%h
    Add-Merge $root 'far-x' "Merge remote-tracking branch 'origin/crew/far-x' into main"
    $h4 = git -C $root log -1 --format=%h
    (Get-MergedTaskInfo $root main 'cube-num').Hash | Should Be $h1
    (Get-MergedTaskInfo $root main 'neg-num').Hash | Should Be $h2
    (Get-MergedTaskInfo $root main 'far').Hash | Should Be $h3
    (Get-MergedTaskInfo $root main 'far-x').Hash | Should Be $h4
    foreach ($n in 'cube', 'neg', 'num', 'cube-nu', 'cube-num-x', 'fa') { Get-MergedTaskInfo $root main $n | Should BeNullOrEmpty }
    # nhánh không phải crew/ hay remote khác origin không tính
    Add-Merge $root 'zz' "Merge branch 'feature/zz'"
    Get-MergedTaskInfo $root main 'zz' | Should BeNullOrEmpty
  }

  It 'merge --no-ff không -m (tiêu đề thật git tự đặt) ⇒ chặn' {
    $root = New-TRepo
    Invoke-TGit $root switch -q -c 'crew/cube-num'
    'c' | Set-Content (Join-Path $root 'c.txt'); Invoke-TGit $root add -A; Invoke-TGit $root commit -qm 'work'
    Invoke-TGit $root switch -q main
    & git -C $root -c user.name=t -c user.email=t@t merge -q --no-ff --no-edit 'crew/cube-num' 2>&1 | Out-Null
    (git -C $root log -1 --format=%s) | Should Be "Merge branch 'crew/cube-num'"
    (Get-MergedTaskInfo $root main 'cube-num').Hash | Should Be (git -C $root log -1 --format=%h)
    Get-MergedTaskInfo $root main 'cube' | Should BeNullOrEmpty
  }

  It 'repo chưa có commit / không có merge / không phải repo / nhánh không có ⇒ $null' {
    $empty = Join-Path $TestDrive "empty-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    New-Item -ItemType Directory -Force $empty | Out-Null
    Get-MergedTaskInfo $empty main 'a' | Should BeNullOrEmpty
    Invoke-TGit $empty init -q -b main
    Get-MergedTaskInfo $empty main 'a' | Should BeNullOrEmpty
    $root = New-TRepo
    Get-MergedTaskInfo $root main 'a' | Should BeNullOrEmpty
    Get-MergedTaskInfo $root 'khong-co-nhanh' 'a' | Should BeNullOrEmpty
  }
}

# ---------------- e2e: crew.ps1 thật, HOME giả, hc/claude/herdr-app giả ----------------
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
# crew queue -Run hỏi limit qua claude: bản giả trả 12% (không chạm CLI thật).
$FakeClaude = @'
#!/usr/bin/env pwsh
if ($args[0] -ne '-p' -or $args[1] -ne '/usage') { exit 2 }
[ordered]@{ type = 'result'; is_error = $false; num_turns = 0; result = "Current session: 12% used`nCurrent week (all models): 30% used" } | ConvertTo-Json -Compress
exit 0
'@

function New-E2E {
  $h = New-CrewTestHome
  [IO.File]::WriteAllText((Join-Path $h.Home 'gitconfig'), "[user]`n`tname = t`n`temail = t@t`n[core]`n`tautocrlf = false`n")
  $bin = Join-Path $h.Home 'fakebin'; $state = Join-Path $h.Home 'fakestate'
  New-Item -ItemType Directory -Force $bin, $state | Out-Null
  foreach ($pair in @(@('hc', $FakeHc), @('herdr-app', $FakeHerdr), @('claude', $FakeClaude), @('codex', $FakeClaude))) {
    $file = Join-Path $bin $(if ($OnWindows) { "$($pair[0]).ps1" } else { $pair[0] })
    [IO.File]::WriteAllText($file, ($pair[1] -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    if (-not $OnWindows) { & chmod +x $file }
  }
  $path = "$bin$([IO.Path]::PathSeparator)$env:PATH"
  $saved = $env:PATH
  try {
    $env:PATH = $path
    foreach ($c in 'hc', 'herdr-app', 'claude') {
      $src = (Get-Command $c -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1).Source
      if (-not $src.StartsWith($bin)) { throw "PATH test trỏ tới $c thật: $src" }
    }
  } finally { $env:PATH = $saved }
  $root = Join-Path $h.Home 'proj'
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root = (Resolve-Path $root).Path
  Invoke-TGit $root init -q -b main
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  Invoke-TGit $root add -A
  Invoke-TGit $root commit -qm init
  ConvertTo-Json -InputObject ([ordered]@{ name = 'qt'; idKey = 'qt'; planner = 'none'; workers = @('claude'); rev = 'none'; review = 'lean'; access = 'work' }) |
    Set-Content (Join-Path $root '.crew/config.json') -Encoding utf8
  $wt = Join-Path $root '.crew/worktrees/w1'
  ConvertTo-Json -InputObject @([ordered]@{ name = 'qt-w1'; address = 't1'; state = 'live'; cwd = $wt; turn = 1 }) | Set-Content (Join-Path $state 'terminals.json') -Encoding utf8
  $p = Join-Path $root 'p.md'; "prompt`nĐược sửa: ``x.ps1``" | Set-Content $p -Encoding utf8
  @{ Home = $h; Root = $root; State = $state; Wt = $wt; Script = $crewScript; Prompt = $p
    Env = @{ PATH = $path; FAKE_HC_DIR = $state; HC_SESSION = "crew-test-$([guid]::NewGuid().ToString('N'))"; HC_TERMINAL_ID = $null; HC_TERMINAL_SOCKET = $null; CREWLINE_UP_ALL_CHILD = $null; CREWLINE_QUEUE_SPAWN = $null } }
}
function Run-Crew($c, [string[]]$argv) {
  $r = Invoke-InTestHome -TestHome $c.Home -File $c.Script -Arguments $argv -Env $c.Env -WorkingDirectory $c.Root
  [pscustomobject]@{ Code = $r.ExitCode; Text = $r.Output }
}
function Assert-NothingLeft($c, [string]$name) {
  (git -C $c.Root branch --list "crew/$name") | Should BeNullOrEmpty
  Test-Path (Join-Path $c.Root '.crew/tasks.json') | Should Be $false
  Test-Path $c.Wt | Should Be $false
  Test-Path (Join-Path $c.State 'sends.log') | Should Be $false
  Test-Path (Join-Path $c.Root '.crew/queue.json') | Should Be $false
  Test-Path (Join-Path $c.Root ".crew/queue/$name.md") | Should Be $false
}

# Task thật trên worktree cố định; merge ff-only không tạo tiêu đề merge để dò.
function Add-FastTask($c, [string]$name, [bool]$merged = $true) {
  Invoke-TGit $c.Root worktree add -q $c.Wt -b "crew/$name" HEAD
  'work' | Set-Content (Join-Path $c.Wt "$name.txt")
  Invoke-TGit $c.Wt add -A
  Invoke-TGit $c.Wt commit -qm "work $name"
  if ($merged) { Invoke-TGit $c.Root merge -q --ff-only "crew/$name" }
  ConvertTo-Json -InputObject @([ordered]@{ name = $name; branch = "crew/$name"; worktree = $c.Wt; worker = 1; terminal = 'qt-w1' }) |
    Set-Content (Join-Path $c.Root '.crew/tasks.json') -Encoding utf8
}

Describe 'Sổ task đã xong qua clean thật' {
  It 'ff-only rồi clean ⇒ task/queue chặn đúng tên, nêu hash/ngày; -Force vẫn giao' {
    $c = New-E2E
    Add-FastTask $c 'neg-num'
    $hash = git -C $c.Root rev-parse --short 'crew/neg-num'
    $clean = Run-Crew $c @('clean', 'neg-num')
    $clean.Code | Should Be 0
    $done = @(Get-Content (Join-Path $c.Root '.crew/done-tasks.json') -Raw | ConvertFrom-Json)
    $done.Count | Should Be 1
    $done[0].head | Should Be $hash
    $date = ([DateTime]$done[0].cleanedAt).ToString('yyyy-MM-dd')
    (git -C $c.Root branch --list 'crew/neg-num') | Should BeNullOrEmpty
    foreach ($cmd in 'task', 'queue') {
      $blocked = Run-Crew $c @($cmd, 'neg-num', $c.Prompt)
      $blocked.Code | Should Be 1
      $blocked.Text | Should Match ([regex]::Escape("(merge $hash, $date)"))
      $blocked.Text | Should Match "→ Làm tiếp:"
      $blocked.Text | Should Match "crew $cmd neg-num .* -Force"
    }
    $queued = Run-Crew $c @('queue', 'neg-num', $c.Prompt, '-Force')
    $queued.Code | Should Be 0
    $queued.Text | Should Match 'CẢNH BÁO: tên neg-num đã dùng .*\(-Force vẫn xếp\)'
    (Run-Crew $c @('queue', 'neg-num', '-Remove')).Code | Should Be 0
    $ok = Run-Crew $c @('task', 'neg', $c.Prompt)
    $ok.Code | Should Be 0
    $ok.Text | Should Not Match 'đã dùng cho task đã xong'
    (Run-Crew $c @('clean', 'neg', '-Force')).Code | Should Be 0
    $forced = Run-Crew $c @('task', 'neg-num', $c.Prompt, '-Force')
    $forced.Code | Should Be 0
    $forced.Text | Should Match 'CẢNH BÁO: tên neg-num đã dùng .*\(-Force vẫn giao\)'
  }

  It 'clean -Force nhánh chưa merge ⇒ không ghi sổ và cho dùng lại tên' {
    $c = New-E2E
    Add-FastTask $c 'abandoned' $false
    (Run-Crew $c @('clean', 'abandoned', '-Force')).Code | Should Be 0
    Test-Path (Join-Path $c.Root '.crew/done-tasks.json') | Should Be $false
    $ok = Run-Crew $c @('task', 'abandoned', $c.Prompt)
    $ok.Code | Should Be 0
    $ok.Text | Should Not Match 'đã dùng cho task đã xong'
  }

  It 'sổ hỏng/trống ⇒ không chặn task/queue, vẫn dò merge cũ và clean ghi lại được' {
    foreach ($raw in '', '{broken') {
      $c = New-E2E
      [IO.File]::WriteAllText((Join-Path $c.Root '.crew/done-tasks.json'), $raw)
      Add-Merge $c.Root 'old' 'Merge crew/old'
      $blocked = Run-Crew $c @('task', 'old', $c.Prompt)
      $blocked.Code | Should Be 1
      $blocked.Text | Should Match 'tên old đã dùng cho task đã xong'
      (Run-Crew $c @('queue', 'fresh', $c.Prompt)).Code | Should Be 0
      (Run-Crew $c @('queue', 'fresh', '-Remove')).Code | Should Be 0
      Add-FastTask $c 'new'
      (Run-Crew $c @('clean', 'new')).Code | Should Be 0
      $done = @(Get-Content (Join-Path $c.Root '.crew/done-tasks.json') -Raw | ConvertFrom-Json)
      $done[0].name | Should Be 'new'
    }
  }
}

Describe 'crew task / queue: tên đã merge (e2e)' {
  It 'crew task tên đã merge ⇒ exit 1, nêu merge + hai bước tiếp, không để lại gì; -DryRun cũng chặn; tên tiền tố không bị chặn' {
    $c = New-E2E
    Add-Merge $c.Root 'neg-num' 'Merge crew/neg-num: số âm'
    $hash = git -C $c.Root log -1 --format=%h
    $date = git -C $c.Root log -1 --format=%ad --date=short
    $r = Run-Crew $c @('task', 'neg-num', $c.Prompt)
    $r.Code | Should Be 1
    $r.Text | Should Match ([regex]::Escape("crew: LỖI: tên neg-num đã dùng cho task đã xong (merge $hash, $date)."))
    $r.Text | Should Match '→ Làm tiếp:\s*\r?\n\s+đặt tên khác\s*\r?\n\s+hoặc vẫn dùng lại: crew task neg-num .*p\.md -Force'
    Assert-NothingLeft $c 'neg-num'
    # crew task không có -DryRun ⇒ chặn trước mọi việc (trước cả kiểm tên đã merge), không giao thật.
    $dry = Run-Crew $c @('task', 'neg-num', $c.Prompt, '-DryRun')
    $dry.Code | Should Be 1
    $dry.Text | Should Match 'crew task không có -DryRun'
    Assert-NothingLeft $c 'neg-num'
    # 'neg' chỉ là tiền tố của neg-num ⇒ giao bình thường
    $ok = Run-Crew $c @('task', 'neg', $c.Prompt)
    $ok.Code | Should Be 0
    $ok.Text | Should Not Match 'đã dùng cho task đã xong'
    (git -C $c.Wt branch --show-current) | Should Be 'crew/neg'
  }

  It 'crew task -Force ⇒ CẢNH BÁO rồi giao như cũ' {
    $c = New-E2E
    Add-Merge $c.Root 'neg-num' 'Merge crew/neg-num'
    $r = Run-Crew $c @('task', 'neg-num', $c.Prompt, '-Force')
    $r.Code | Should Be 0
    $r.Text | Should Match 'CẢNH BÁO: tên neg-num đã dùng cho task đã xong \(merge [0-9a-f]+, \d{4}-\d{2}-\d{2}\)\. \(-Force vẫn giao\)'
    $r.Text | Should Match 'task neg-num -> qt-w1'
    (git -C $c.Wt branch --show-current) | Should Be 'crew/neg-num'
    @(Get-Content (Join-Path $c.Root '.crew/tasks.json') -Raw | ConvertFrom-Json)[0].name | Should Be 'neg-num'
  }

  It 'crew queue tên đã merge ⇒ chặn lúc xếp; -Force xếp kèm cảnh báo, xếp lại để cập nhật không chặn; -Run tự giao không chặn lại' {
    $c = New-E2E
    Add-Merge $c.Root 'neg-num' 'Merge crew/neg-num: số âm'
    $r = Run-Crew $c @('queue', 'neg-num', $c.Prompt)
    $r.Code | Should Be 1
    $r.Text | Should Match 'crew: LỖI: tên neg-num đã dùng cho task đã xong \(merge [0-9a-f]+, \d{4}-\d{2}-\d{2}\)\.'
    $r.Text | Should Match '→ Làm tiếp:\s*\r?\n\s+đặt tên khác\s*\r?\n\s+hoặc vẫn dùng lại: crew queue neg-num .*p\.md -Force'
    Assert-NothingLeft $c 'neg-num'

    $f = Run-Crew $c @('queue', 'neg-num', $c.Prompt, '-Force')
    $f.Code | Should Be 0
    $f.Text | Should Match 'CẢNH BÁO: tên neg-num đã dùng .* \(-Force vẫn xếp\)'
    $f.Text | Should Match 'đã xếp neg-num vào hàng đợi'
    $u = Run-Crew $c @('queue', 'neg-num', $c.Prompt)
    $u.Code | Should Be 0
    $u.Text | Should Match 'đã cập nhật neg-num trong hàng đợi'

    $run = Run-Crew $c @('queue', '-Run')
    $run.Code | Should Be 0
    $run.Text | Should Match 'neg-num: đã giao → w1'
    (git -C $c.Wt branch --show-current) | Should Be 'crew/neg-num'
    @(Get-Content (Join-Path $c.Root '.crew/tasks.json') -Raw | ConvertFrom-Json)[0].name | Should Be 'neg-num'
  }
}

Describe 'Spawn của hàng đợi đánh dấu tiến trình con' {
  It 'New-QueueOps.Spawn đặt CREWLINE_QUEUE_SPAWN=1 cho crew task con rồi trả lại giá trị cũ' {
    $text = (Find-CrewAst { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'New-QueueOps' } -Recurse:$false)[0].Extent.Text
    $text | Should Match "\`$env:CREWLINE_QUEUE_SPAWN = '1'"
    $text | Should Match '\$env:CREWLINE_QUEUE_SPAWN = \$savedSpawn'
  }
}
