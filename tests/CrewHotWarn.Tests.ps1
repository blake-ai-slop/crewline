. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($shared in 'Get-CrewStateSchema', 'Read-CrewState', 'Show-CrewUpgradeWarning', 'Get-SkeletonVersion') { . ([scriptblock]::Create((Get-CrewFunction $shared).Extent.Text)) }
# Hàm thật trích AST, Git thật trong TestDrive; terminal/sổ giả, không đọc màn hình.
$hotCrew = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'

$hotFunctions = 'Get-PromptScope','Get-ScopeConflicts','Get-WorkerMode','Get-SendPlan','Get-TermStatus','Get-HotWarnings','Invoke-Hot', 'Get-TaskGitFacts', 'Test-TaskFinished','Invoke-GitQuiet','Get-CrewName','Get-LegacySlug','Test-CrewName','Test-SamePath','ConvertTo-RootKey','Get-Root','Get-WorkerTree','Get-Tasks','Get-Config','Get-ForeignTermError','Test-TermOwner','Get-CopySource','Get-NameOwner','Test-OtherAlive','Get-NameConflict','Get-IdKeyOwner','Get-CrewIdKey','Get-LegacyIdKey','Test-IdKey'
foreach ($fn in (Find-CrewAst {param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $hotFunctions} -Recurse:$false)) { . ([scriptblock]::Create($fn.Extent.Text.Replace("(Join-Path `$CrewScriptsDir 'lint.ps1')", '$script:HotLintPath'))) }
function Read-ProjectRegistry { @{Ok=$true; Map=$script:hotRegistry} }
function Get-ProjectsFile { Join-Path $TestDrive 'projects.json' }
function Get-LiveTerminals { $script:fakeTerms }
function New-HcOps { throw 'không được đọc màn hình thêm' }
function Die($message) { throw $message }
Describe 'crew hot cảnh báo chỉ đọc' {
  BeforeEach {
    $script:HotLintPath = Join-Path (Split-Path $hotCrew) 'lint.ps1'
    $script:hotRegistry = [ordered]@{}
    $script:fakeTerms = @()
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $root | Out-Null
    git -C $root init -qb main
    git -C $root config core.autocrlf false
    '.crew/' | Set-Content (Join-Path $root '.gitignore')
    'base' | Set-Content (Join-Path $root 'a.txt')
    git -C $root add -A
    git -C $root -c user.name=test -c user.email=test@example.invalid commit -qm init
    $wt = Join-Path $root '.crew/worktrees/w1'
    git -C $root worktree add -q --detach $wt HEAD
    $cfg = [pscustomobject]@{name='demo'; workers=@('codex'); review='lean'; access='work'; planner='none'; rev='none'}
    $cfg | ConvertTo-Json | Set-Content (Join-Path $root '.crew/config.json')
    $Path = $root
  }
  It 'context cũ chỉ cảnh báo, không ghi; bằng hoặc mới hơn không cảnh báo' {
    $Skeleton = Join-Path (Split-Path (Split-Path $hotCrew)) 'skeleton'
    $current = [int](Get-SkeletonVersion)
    New-Item -ItemType Directory -Force (Join-Path $root 'context') | Out-Null
    $stamp = Join-Path $root 'context/.skeleton-version'
    foreach ($version in @($current - 1), $current, ($current + 1)) {
      [IO.File]::WriteAllText($stamp, "$version")
      $before = (Get-FileHash $stamp).Hash
      $output = Invoke-Hot 6>&1 | Out-String
      if ($version -lt $current) { $output | Should Match "crew: context v$version cũ hơn crew v$current — chạy crew upgrade -DryRun rồi crew upgrade" }
      else { $output | Should Not Match 'cũ hơn crew' }
      (Get-FileHash $stamp).Hash | Should Be $before
    }
  }
  It 'crew up kiểm schema trước bước có thể sửa metadata config' {
    foreach ($fn in 'Invoke-Recover', 'Get-MainRoot') { . ([scriptblock]::Create((Get-CrewFunction $fn).Extent.Text)) }
    $file = Join-Path $root '.crew/config.json'
    [IO.File]::WriteAllText($file, '{"schema":99,"workers":[]}')
    $before = (Get-FileHash $file).Hash
    { Invoke-Recover $true } | Should Throw 'dữ liệu do bản crew mới hơn ghi — cập nhật crew'
    (Get-FileHash $file).Hash | Should Be $before
  }
  It 'lint có cảnh báo chỉ in tóm tắt, không sửa context' {
    New-Item -ItemType Directory (Join-Path $root 'context') | Out-Null
    '- `Get-RemovedFunction`' | Set-Content (Join-Path $root 'context/MAP.md')
    $before = Get-Content (Join-Path $root 'context/MAP.md') -Raw
    $output = Invoke-Hot 6>&1 | Out-String
    $output | Should Match 'crew: context: 1 cảnh báo — chạy crew lint'
    (Get-Content (Join-Path $root 'context/MAP.md') -Raw) | Should Be $before
  }
  It 'lint lỗi bỏ qua im lặng' {
    $script:HotLintPath = Join-Path $TestDrive 'missing.ps1'
    $output = Invoke-Hot 6>&1 | Out-String
    $output | Should Not Match 'crew: context:|lint.ps1|không đọc'
  }
  It 'task trùng hiện đúng một cảnh báo mỗi cặp, bỏ task thiếu prompt' {
    $items = @()
    foreach ($n in 1,2,3) {
      $dir = Join-Path $root ".crew/worktrees/scope$n/.crew"
      New-Item -ItemType Directory -Force $dir | Out-Null
      'Được sửa: `src/a.ps1`, `context/tasks/*`' | Set-Content (Join-Path $dir 'prompt.md') -Encoding UTF8
      $items += [pscustomobject]@{name="t$n";worker=$n;worktree=".crew/worktrees/scope$n";branch='main';agent='codex'}
    }
    $items += [pscustomobject]@{name='missing';worker=4;worktree='gone';branch='main';agent='codex'}
    ConvertTo-Json -InputObject $items | Set-Content (Join-Path $root '.crew/tasks.json')
    $output = Invoke-Hot 6>&1 | Out-String
    ([regex]::Matches($output, 'crew: CẢNH BÁO: task')).Count | Should Be 3
    $output | Should Match 'task t1 và t2 trùng file: src/a.ps1 ~ src/a.ps1'
    $output | Should Not Match 'trùng file:.*context/tasks|và missing trùng'
  }
  It 'sạch không có khối Cảnh báo' {
    @(Get-HotWarnings $root $cfg @() @()).Count | Should Be 0
    $output = (Invoke-Hot 6>&1 | Out-String)
    $output | Should Not Match '== Cảnh báo'
  }
  It 'main bẩn và worker bẩn không có task, không đổi file/git' {
    'dirty' | Set-Content (Join-Path $root 'a.txt')
    'worker' | Set-Content (Join-Path $wt 'a.txt')
    $before = (git -C $root status --porcelain) -join "`n"
    $warnings = @(Get-HotWarnings $root $cfg @() @()) -join "`n"
    $warnings | Should Match 'main.*chưa commit'
    $warnings | Should Match 'w1 bẩn mà không có task'
    ((git -C $root status --porcelain) -join "`n") | Should BeExactly $before
    Get-Content (Join-Path $wt 'a.txt') | Should Be 'worker'
    (Invoke-Hot 6>&1 | Out-String) | Should Match '== Cảnh báo'
    @(Get-HotWarnings $root $cfg @([pscustomobject]@{worker=1}) @()) -join "`n" | Should Not Match 'w1 bẩn'
  }
  It 'merge dở vẫn cảnh báo khi status sạch' {
    $head = git -C $root rev-parse HEAD
    $head | Set-Content (Join-Path $root '.git/MERGE_HEAD')
    (git -C $root status --porcelain | Out-String).Trim() | Should Be ''
    @(Get-HotWarnings $root $cfg @() @()) -join "`n" | Should Match 'merge dở'
    Test-Path (Join-Path $root '.git/MERGE_HEAD') | Should Be $true
  }
  It 'agent lạ ở root cảnh báo planner thứ hai, bỏ qua crew, shell và cwd khác' {
    $terms = @(
      [pscustomobject]@{name='extra'; cwd=$root; agent='codex'},
      [pscustomobject]@{name='demo-planner'; cwd=$root; agent='codex'},
      [pscustomobject]@{name='demo-w12'; cwd=$root; agent='codex'},
      [pscustomobject]@{name='demo-rev'; cwd=$root; agent='codex'},
      [pscustomobject]@{name='shell'; cwd=$root; agent=$null},
      [pscustomobject]@{name='elsewhere'; cwd=$wt; agent='codex'}
    )
    $warnings = @(Get-HotWarnings $root $cfg @() $terms)
    $warnings.Count | Should Be 1
    $warnings[0] | Should Match "extra.*có thể có planner thứ hai"
  }
  It 'chỉ trùng idKey cảnh báo khóa, không gọi project là bản chép' {
    $source = Join-Path $TestDrive 'other'
    New-Item -ItemType Directory -Force (Join-Path $source '.crew') | Out-Null
    '{}' | Set-Content (Join-Path $source '.crew/config.json')
    $script:hotRegistry['other'] = @{Root=$source; IdKey='demo'}
    Get-CopySource $root $cfg | Should Be ''
    $warnings = @(Get-HotWarnings $root $cfg @() @()) -join "`n"
    $warnings | Should Match 'khóa id herdr.*crew init -Name'
    $warnings | Should Not Match 'bản chép|bản sao'
  }
  It 'chủ cùng root, root cũ đã mất và config không name đều không là bản chép' {
    $script:hotRegistry['demo'] = @{Root=$root; IdKey='demo'}
    Get-CopySource $root $cfg | Should Be ''
    $script:hotRegistry['demo'] = @{Root=(Join-Path $TestDrive 'missing'); IdKey='demo'}
    Get-CopySource $root $cfg | Should Be ''
    Get-CopySource $root ([pscustomobject]@{idKey='demo'}) | Should Be ''
    Get-CopySource $root $null | Should Be ''
  }
  It 'bản chép có khối cảnh báo và gợi ý init -Name' {
    $source = Join-Path $TestDrive 'source'
    New-Item -ItemType Directory -Force (Join-Path $source '.crew') | Out-Null
    '{}' | Set-Content (Join-Path $source '.crew/config.json')
    $script:hotRegistry['demo'] = @{Root=$source; IdKey='demo'}
    Get-CopySource $root $cfg | Should Be $source
    $output = Invoke-Hot 6>&1 | Out-String
    $output | Should Match '== Cảnh báo'
    $output | Should Match 'bản chép.*crew init -Name'
  }
}

Describe 'herdr-app ls gom stderr khi chờ space/tab (lệnh giả)' {
  BeforeEach {
    foreach ($fn in 'Get-HerdrSpaces', 'Start-Term', 'Wait-Tab') { . ([scriptblock]::Create((Get-CrewFunction $fn).Extent.Text)) }
    $script:HerdrLsWarnings = @{}
    $script:HerdrCalls = 0
    $script:HerdrReadyAt = 10
    $script:HerdrExit = 0
    function herdr-app {
      $script:HerdrCalls++
      Write-Error 'same warning' -ErrorAction Continue
      $global:LASTEXITCODE = $script:HerdrExit
      if ($script:HerdrCalls -ge $script:HerdrReadyAt) { '{"spaces":[{"tabs":[{"id":"target","terminals":[{"terminal":"tx"}]}]}]}' }
      else { '{"spaces":[]}' }
    }
    function hc { $global:LASTEXITCODE = 0; '{"address":"tx"}' }
    function Start-Sleep { }
    function Die($message) { throw $message }
  }
  It 'Wait-Tab gọi 10 lần chỉ in cùng cảnh báo một lần, nhận tab đúng' {
    $out = & { Wait-Tab target | Should Be $true } 6>&1 | Out-String
    $script:HerdrCalls | Should Be 10
    ([regex]::Matches($out, 'same warning')).Count | Should Be 1
  }
  It 'Start-Term gọi 10 lần chỉ in cùng cảnh báo một lần, trả terminal đúng' {
    $out = & { (Start-Term demo $TestDrive space target test).address | Should Be tx } 6>&1 | Out-String
    $script:HerdrCalls | Should Be 10
    ([regex]::Matches($out, 'same warning')).Count | Should Be 1
  }
  It 'Get-HerdrSpaces lặp giữ cảnh báo khác nhau và JSON stdout riêng' {
    $out = & { 1..10 | ForEach-Object { (Get-HerdrSpaces).Ok | Should Be $true } } 6>&1 | Out-String
    ([regex]::Matches($out, 'same warning')).Count | Should Be 1
    function herdr-app { Write-Error 'different warning' -ErrorAction Continue; '{"spaces":[]}' }
    $out = & { (Get-HerdrSpaces).Ok | Should Be $true } 6>&1 | Out-String
    $out | Should Match 'different warning'
  }
  It 'stderr native giữ riêng stdout, cảnh báo trùng vẫn chỉ in một lần' {
    $script:NativeHerdrFake = Join-Path $TestDrive 'native-herdr.ps1'
    [IO.File]::WriteAllText($script:NativeHerdrFake, '[Console]::Error.WriteLine("native warning"); [Console]::Out.WriteLine(''{"spaces":[]}''); exit 0')
    function herdr-app { & pwsh -NoProfile -File $script:NativeHerdrFake }
    $out = & { 1..10 | ForEach-Object { (Get-HerdrSpaces).Ok | Should Be $true } } 6>&1 | Out-String
    ([regex]::Matches($out, 'native warning')).Count | Should Be 1
    [IO.File]::WriteAllText($script:NativeHerdrFake, '[Console]::Error.WriteLine("native failure"); exit 9')
    $result = Get-HerdrSpaces
    $result.Ok | Should Be $false
    $result.Error | Should Match 'exit 9.*native failure'
  }
  It 'lỗi exit thật dừng vòng chờ và giữ chi tiết lỗi; JSON hỏng cũng báo' {
    $script:HerdrExit = 7
    { Wait-Tab target } | Should Throw 'exit 7'
    $script:HerdrCalls | Should Be 1
    $script:HerdrCalls = 0
    { Start-Term demo $TestDrive space target test } | Should Throw 'exit 7'
    function herdr-app { $global:LASTEXITCODE = 0; 'invalid json' }
    $result = Get-HerdrSpaces
    $result.Ok | Should Be $false
    $result.Error | Should Match 'không đọc được'
  }
}
