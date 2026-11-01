# Hàm thật trích AST, Git thật trong TestDrive; terminal/sổ giả, không đọc màn hình.
$hotCrew = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$hotAst = [System.Management.Automation.Language.Parser]::ParseFile($hotCrew,[ref]$null,[ref]$null)
$hotFunctions = 'Get-HotWarnings','Invoke-Hot','Invoke-GitQuiet','Get-CrewName','Get-LegacySlug','Test-CrewName','Test-SamePath','ConvertTo-RootKey','Get-Root','Get-WorkerTree','Get-Tasks','Get-Config','Get-ForeignTermError','Test-TermOwner','Get-CopySource','Get-NameOwner','Test-OtherAlive','Get-NameConflict','Get-IdKeyOwner','Get-CrewIdKey','Get-LegacyIdKey','Test-IdKey'
foreach ($fn in $hotAst.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $hotFunctions},$false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Read-ProjectRegistry { @{Ok=$true; Map=$script:hotRegistry} }
function Get-ProjectsFile { Join-Path $TestDrive 'projects.json' }
function Get-LiveTerminals { $script:fakeTerms }
function New-HcOps { throw 'không được đọc màn hình thêm' }
function Die($message) { throw $message }
Describe 'crew hot cảnh báo chỉ đọc' {
  BeforeEach {
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
