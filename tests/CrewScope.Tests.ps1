. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($shared in 'Get-CrewStateSchema', 'Read-CrewState', 'Get-CrewVersion', 'Show-CrewUpgradeWarning', 'Get-SkeletonVersion') { . ([scriptblock]::Create((Get-CrewFunction $shared).Extent.Text)) }
foreach ($name in 'Get-PromptScope', 'Get-ScopeConflicts', 'Invoke-Task', 'New-TaskRecord') {
  . ([scriptblock]::Create((Get-CrewFunction $name).Extent.Text))
}

Describe 'Phạm vi prompt và các cặp trùng' {
  BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $wt = Join-Path $root 'worker'
    New-Item -ItemType Directory -Force (Join-Path $wt '.crew') | Out-Null
    $tasks = @([pscustomobject]@{name='old'; worktree='worker'})
  }
  It 'chỉ lấy backtick trên đúng dòng, chuẩn hóa slash và phân biệt thiếu với rỗng' {
    $s = Get-PromptScope "Được sửa: ``src\a.ps1``, ``src/``.`nKhông sửa: ``other``"
    ($s -is [string[]]) | Should Be $true
    ($s -join ',') | Should Be 'src/a.ps1,src/'
    ($null -eq (Get-PromptScope 'không có')) | Should Be $true
    $s = Get-PromptScope 'Được sửa: không có backtick'
    ($null -eq $s) | Should Be $false
    $s.Count | Should Be 0
  }
  It 'so sánh bằng nhau không phân biệt hoa thường và bỏ context/tasks' {
    'Được sửa: `SRC/a.ps1`, `context/tasks/*`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding UTF8
    $c = Get-ScopeConflicts $root $tasks @('src\a.ps1', 'context/tasks/new.md')
    ($c -is [array]) | Should Be $true
    $c.Count | Should Be 1
    $c[0].Task | Should Be 'old'
    ($c[0].Pairs -join ',') | Should Be 'src/a.ps1 ~ SRC/a.ps1'
  }
  It 'nhận thư mục tiền tố và wildcard ở cả hai chiều' {
    'Được sửa: `src/`, `tests/A.Tests.ps1`, `docs/*.md`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding UTF8
    $c = Get-ScopeConflicts $root $tasks @('src/a.ps1', 'tests/*.Tests.ps1', 'docs/a.md')
    $c[0].Pairs.Count | Should Be 3
    'Được sửa: `src/a.ps1`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding UTF8
    (Get-ScopeConflicts $root $tasks @('SRC/'))[0].Pairs.Count | Should Be 1
    (Get-ScopeConflicts $root $tasks @('sr/')).Count | Should Be 0
  }
  It 'bỏ task loại trừ, thiếu prompt, thiếu dòng và scope rỗng' {
    'Được sửa: `a`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding UTF8
    (Get-ScopeConflicts $root $tasks @('a') 'old').Count | Should Be 0
    (Get-ScopeConflicts $root $tasks $null).Count | Should Be 0
    (Get-ScopeConflicts $root $tasks @()).Count | Should Be 0
    'không có dòng' | Set-Content (Join-Path $wt '.crew/prompt.md')
    (Get-ScopeConflicts $root $tasks @('a')).Count | Should Be 0
    (Get-ScopeConflicts $root @([pscustomobject]@{name='gone';worktree='missing'}) @('a')).Count | Should Be 0
  }
  It 'scope trên bản ghi thắng prompt cũ, dùng được không worktree, giữ scope rỗng' {
    'Được sửa: `old.ps1`' | Set-Content (Join-Path $wt '.crew/prompt.md') -Encoding UTF8
    $record = [pscustomobject]@{ name='planned'; worktree='worker'; scope=@('src\', 'docs/*.md') }
    (Get-ScopeConflicts $root @($record) @('old.ps1')).Count | Should Be 0
    (Get-ScopeConflicts $root @($record) @('src/a.ps1', 'docs/a.md'))[0].Pairs.Count | Should Be 2
    $record.scope = @()
    (Get-ScopeConflicts $root @($record) @('old.ps1')).Count | Should Be 0
    $record = [pscustomobject]@{ name='planned'; scope=@('a.ps1') }
    (Get-ScopeConflicts $root @($record) @('a.ps1'))[0].Task | Should Be 'planned'
  }
  It 'đọc worktree tuyệt đối, trả mọi task và không đổi prompt' {
    $file = Join-Path $wt '.crew/prompt.md'
    'Được sửa: `a`' | Set-Content $file -Encoding UTF8
    $before = Get-Content $file -Raw
    $both = @([pscustomobject]@{name='old';worktree='worker'}, [pscustomobject]@{name='second';worktree=(Resolve-Path $wt).ProviderPath})
    (Get-ScopeConflicts $root $both @('a')).Count | Should Be 2
    (Get-Content $file -Raw) | Should BeExactly $before
  }
}

Describe 'Invoke-Task kiểm trùng trước khi giao' {
  BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    '{}' | Set-Content (Join-Path $root '.crew/config.json')
    New-Item -ItemType Directory -Force (Join-Path $root 'old/.crew') | Out-Null
    'Được sửa: `src/a.ps1`' | Set-Content (Join-Path $root 'old/.crew/prompt.md') -Encoding UTF8
    $PromptFile = Join-Path $root 'new.md'
    'Được sửa: `src/`' | Set-Content $PromptFile -Encoding UTF8
    $Name = 'new'; $Worker = 2; $Force = $false; $InitParameters = @{}
    $script:scopeRoot = $root; $script:scopeStarted = 0; $script:scopeOps = 0; $script:scopeMessages = @()
    function Get-MainRoot { $script:scopeRoot }
    function Get-Config { [pscustomobject]@{workers=@('codex','codex');access='work'} }
    function Get-CrewName { 'demo' }
    function Get-Tasks { ,@([pscustomobject]@{name='old';worktree='old';worker=1}) }
    function Get-MoveInfo { $null }
    function Get-WorkerTree { Join-Path $script:scopeRoot 'w2' }
    function Invoke-GitQuiet { @{Code=1;Text=''} }
    function Get-MainBranch { 'main' }
    function New-HcOps { $script:scopeOps++; @{} }
    function Start-WorkerTask { $script:scopeStarted++; @{Ok=$true;Message='sent'} }
    function Die($message) { throw $message }
    function Say($message) { $script:scopeMessages += $message }
  }
  It 'chặn kèm tên task, cặp mẫu và cách tiếp tục, chưa gọi hc hay tạo task' {
    { Invoke-Task } | Should Throw 'trùng file với task old: src/ ~ src/a.ps1'
    $script:scopeStarted | Should Be 0
    $script:scopeOps | Should Be 0
  }
  It '-Force vẫn cảnh báo rồi giao' {
    $Force = $true
    Invoke-Task
    $script:scopeStarted | Should Be 1
    ($script:scopeMessages -join "`n") | Should Match 'CẢNH BÁO: trùng file.*old.*-Force'
  }
  It 'không có phạm vi vẫn giao kèm cảnh báo' {
    'nội dung không có phạm vi' | Set-Content $PromptFile -Encoding UTF8
    Invoke-Task
    $script:scopeStarted | Should Be 1
    ($script:scopeMessages -join "`n") | Should Match 'không kiểm được trùng file'
  }
  It 'không trùng giao bình thường' {
    'Được sửa: `other.ps1`' | Set-Content $PromptFile -Encoding UTF8
    Invoke-Task
    $script:scopeStarted | Should Be 1
    ($script:scopeMessages -join "`n") | Should Not Match 'CẢNH BÁO'
  }
}
