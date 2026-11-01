# Init bản chép dùng HOME giả, Git thật, hc/herdr giả.
. "$PSScriptRoot/TestHome.ps1"
$copyCrew = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
Describe 'crew init bản chép' {
  BeforeEach {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $h = New-CrewTestHome
    Set-Content (Join-Path $h.Home 'gitconfig') "[user]`n name = test`n email = test@example.invalid`n[core]`n autocrlf = false"
    $wrapper = Join-Path $h.Home 'crew-fake.ps1'
    @"
function hc { throw 'không được gọi hc' }
function herdr-app { '{"spaces":[]}' }
& '$copyCrew' @args
exit `$LASTEXITCODE
"@ | Set-Content $wrapper -Encoding utf8
    $original = Join-Path $h.Home 'original'
    New-Item -ItemType Directory $original | Out-Null
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$original,'-Name','source','-GitInit','-NoCommit')
    $r.ExitCode | Should Be 0
    git -C $original config core.autocrlf false
    git -C $original add -A
    git -C $original -c user.name=test -c user.email=test@example.invalid commit -qm skeleton
    foreach ($n in 1,2) { git -C $original worktree add -q --detach (Join-Path $original ".crew/worktrees/w$n") HEAD }
    '[{"name":"old","worker":1}]' | Set-Content (Join-Path $original '.crew/tasks.json')
    $copy = Join-Path $h.Home 'copy'
    Copy-Item -LiteralPath $original -Destination $copy -Recurse -Force
    $registry = Join-Path $h.Home '.crewline/projects.json'
    $beforeRegistry = Get-Content $registry -Raw
    $beforeTasks = Get-Content (Join-Path $original '.crew/tasks.json') -Raw
    $beforeTrees = (git -C $original worktree list --porcelain) -join "`n"
  }
  It '-Name mới dọn bản chép, giữ bản gốc và chủ cũ trong sổ' {
    # Worktree thực sự của bản chép phải được giữ lại dù mang tên w3.
    $real = Join-Path $copy '.crew/worktrees/w3'
    git -C $copy worktree add -q --detach $real HEAD
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$copy,'-Name','copy','-NoCommit')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'đã dọn.*tasks.json'
    $r.Output | Should Match 'đã dọn worktree chép theo'
    Test-Path (Join-Path $copy '.crew/tasks.json') | Should Be $false
    foreach ($n in 1,2) { Test-Path (Join-Path $copy ".crew/worktrees/w$n") | Should Be $false }
    Test-Path (Join-Path $real '.git') | Should Be $true
    $cfg = Get-Content (Join-Path $copy '.crew/config.json') -Raw | ConvertFrom-Json
    $cfg.name | Should Be 'copy'
    $cfg.idKey | Should Be 'copy'
    $reg = Get-Content $registry -Raw | ConvertFrom-Json
    $reg.source.root | Should Be $original
    $reg.source.idKey | Should Be 'source'
    $reg.copy.root | Should Be $copy
    Get-Content (Join-Path $original '.crew/tasks.json') -Raw | Should BeExactly $beforeTasks
    ((git -C $original worktree list --porcelain) -join "`n") | Should BeExactly $beforeTrees
  }
  It 'project độc lập legacy chỉ trùng idKey: init -Name mới giữ tasks và worktree' {
    # my-app dùng khóa legacy myapp; project độc lập myapp giữ khóa đó trong sổ.
    $legacyCfgFile = Join-Path $original '.crew/config.json'
    $legacy = Get-Content $legacyCfgFile -Raw | ConvertFrom-Json
    $legacy.name = 'my-app'; $legacy.idKey = 'myapp'
    $legacy | ConvertTo-Json | Set-Content $legacyCfgFile -Encoding utf8
    $other = Join-Path $h.Home 'myapp'
    New-Item -ItemType Directory -Force (Join-Path $other '.crew') | Out-Null
    '{"name":"myapp","idKey":"myapp"}' | Set-Content (Join-Path $other '.crew/config.json')
    @{myapp=@{root=$other; idKey='myapp'}} | ConvertTo-Json -Depth 4 | Set-Content $registry
    # Không -Name vẫn chạy theo hành vi crew-name, chỉ cảnh báo xung đột khóa.
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$original,'-NoCommit')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'khóa id herdr.*trùng project'
    $r.Output | Should Not Match 'đã dọn|project là bản chép'
    Get-Content (Join-Path $original '.crew/tasks.json') -Raw | Should BeExactly $beforeTasks
    # Đổi tên thực sự để giải quyết trùng idKey tuyệt đối không dọn task.
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$original,'-Name','renamed','-NoCommit')
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'đã dọn'
    (Get-Content $legacyCfgFile -Raw | ConvertFrom-Json).name | Should Be 'renamed'
    Get-Content (Join-Path $original '.crew/tasks.json') -Raw | Should BeExactly $beforeTasks
    foreach ($n in 1,2) { Test-Path (Join-Path $original ".crew/worktrees/w$n/.git") | Should Be $true }
    ((git -C $original worktree list --porcelain) -join "`n") | Should BeExactly $beforeTrees
    (Get-Content $registry -Raw | ConvertFrom-Json).myapp.root | Should Be $other
  }
  It 'không -Name dừng, không thay đổi bất kỳ file nào' {
    $before = @(Get-ChildItem -LiteralPath $copy -Recurse -File -Force | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join "`n"
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$copy,'-NoCommit')
    $r.ExitCode | Should Be 1
    $r.Output | Should Match 'bản chép.*crew init -Name'
    $after = @(Get-ChildItem -LiteralPath $copy -Recurse -File -Force | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join "`n"
    $after | Should BeExactly $before
    Get-Content $registry -Raw | Should BeExactly $beforeRegistry
  }
  It 'init lại project thường không dọn tasks hoặc worker' {
    $r = Invoke-InTestHome $h $wrapper -Arguments @('init','-Path',$original,'-NoCommit')
    $r.ExitCode | Should Be 0
    $r.Output | Should Not Match 'đã dọn'
    Get-Content (Join-Path $original '.crew/tasks.json') -Raw | Should BeExactly $beforeTasks
    foreach ($n in 1,2) { Test-Path (Join-Path $original ".crew/worktrees/w$n/.git") | Should Be $true }
    ((git -C $original worktree list --porcelain) -join "`n") | Should BeExactly $beforeTrees
  }
}
