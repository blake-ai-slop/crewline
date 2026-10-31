# Test phần git của crew clean (Remove-TaskGit): trích hàm bằng AST từ crew.ps1, chạy trên repo git tạm trong $TestDrive, không gọi hc.
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
$want = 'Say', 'Get-Tasks', 'Save-Tasks', 'Invoke-GitQuiet', 'Test-WorktreeListed', 'Remove-TaskGit', 'Remove-TaskBranch'
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in $want }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Say($msg) { }

# repo tạm có 1 commit + worktree nhánh crew/<name>; tasks.json có bản ghi task
function New-CleanRepo([string]$Name = 'demo') {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $root = Join-Path $TestDrive "repo-$id"
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  git -C $root init -q
  git -C $root config user.name t; git -C $root config user.email t@t
  '.crew/' | Set-Content (Join-Path $root '.gitignore')
  git -C $root add -A; git -C $root commit -q -m init
  $wt = Join-Path $TestDrive "wt-$id"
  git -C $root worktree add -q $wt -b "crew/$Name" HEAD 2>$null
  $task = [pscustomobject]@{ name = $Name; branch = "crew/$Name"; worktree = $wt; worker = 1 }
  Save-Tasks $root @($task)
  @{ Root = $root; Wt = $wt; Task = $task }
}

# như Invoke-Clean: lỗi ⇒ giữ bản ghi; thành công ⇒ xóa bản ghi
function Invoke-CleanGit($r, [bool]$force = $false) {
  $tasks = Get-Tasks $r.Root
  try { $warn = Remove-TaskGit $r.Root $r.Task $force } catch { return @{ Ok = $false; Error = $_.Exception.Message } }
  Save-Tasks $r.Root @($tasks | Where-Object { $_.name -ne $r.Task.name })
  @{ Ok = $true; Warn = $warn }
}

function Test-Branch($r) { git -C $r.Root show-ref --verify --quiet "refs/heads/$($r.Task.branch)"; $LASTEXITCODE -eq 0 }

Describe 'Remove-TaskGit' {
  It 'dọn thành công -> worktree + nhánh mất, bản ghi xóa' {
    $r = New-CleanRepo
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    @($res.Warn).Count | Should Be 0
    Test-Path $r.Wt | Should Be $false
    Test-WorktreeListed $r.Root $r.Wt | Should Be $false
    Test-Branch $r | Should Be $false
    (Get-Tasks $r.Root).Count | Should Be 0
  }

  It 'nhánh chưa merge, không -Force -> lỗi rõ, giữ bản ghi; chạy lại -Force dọn nốt' {
    $r = New-CleanRepo
    'x' | Set-Content (Join-Path $r.Wt 'a.txt')
    git -C $r.Wt add -A; git -C $r.Wt commit -q -m work
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $false
    $res.Error | Should Match "git branch"
    Test-Branch $r | Should Be $true
    (Get-Tasks $r.Root).Count | Should Be 1
    $res = Invoke-CleanGit $r $true
    $res.Ok | Should Be $true
    Test-Branch $r | Should Be $false
    (Get-Tasks $r.Root).Count | Should Be 0
  }

  It 'worktree đã mất sẵn (thư mục bị xóa) -> chạy lại vẫn dọn nhánh' {
    $r = New-CleanRepo
    Remove-Item -LiteralPath $r.Wt -Recurse -Force
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    Test-WorktreeListed $r.Root $r.Wt | Should Be $false
    Test-Branch $r | Should Be $false
    (Get-Tasks $r.Root).Count | Should Be 0
  }

  It 'worktree đã gỡ khỏi git sẵn -> bỏ qua, vẫn dọn nhánh' {
    $r = New-CleanRepo
    git -C $r.Root worktree remove $r.Wt
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    Test-Branch $r | Should Be $false
  }

  It 'nhánh đã mất sẵn -> không lỗi' {
    $r = New-CleanRepo
    git -C $r.Root worktree remove $r.Wt
    git -C $r.Root branch -q -D $r.Task.branch
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    (Get-Tasks $r.Root).Count | Should Be 0
  }

  It 'worktree bẩn, không -Force -> lỗi rõ, giữ worktree + nhánh + bản ghi' {
    $r = New-CleanRepo
    'dirty' | Set-Content (Join-Path $r.Wt 'b.txt')
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $false
    $res.Error | Should Match "git worktree remove"
    $res.Error | Should Match "-Force"
    Test-Path (Join-Path $r.Wt 'b.txt') | Should Be $true
    Test-WorktreeListed $r.Root $r.Wt | Should Be $true
    Test-Branch $r | Should Be $true
    (Get-Tasks $r.Root).Count | Should Be 1
  }

  It 'thư mục worktree rỗng còn sót sau khi git gỡ -> xóa, không cảnh báo' {
    $r = New-CleanRepo
    git -C $r.Root worktree remove $r.Wt
    New-Item -ItemType Directory $r.Wt | Out-Null
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    @($res.Warn).Count | Should Be 0
    Test-Path $r.Wt | Should Be $false
  }

  It 'thư mục worktree còn sót không xóa được -> cảnh báo đường dẫn, vẫn xóa bản ghi' {
    $r = New-CleanRepo
    git -C $r.Root worktree remove $r.Wt
    New-Item -ItemType Directory $r.Wt | Out-Null
    'giữ' | Set-Content (Join-Path $r.Wt 'left.txt')
    $res = Invoke-CleanGit $r
    $res.Ok | Should Be $true
    @($res.Warn).Count | Should Be 1
    $res.Warn[0] | Should Match ([regex]::Escape($r.Wt))
    $res.Warn[0] | Should Match 'xóa tay'
    Test-Path (Join-Path $r.Wt 'left.txt') | Should Be $true
    (Get-Tasks $r.Root).Count | Should Be 0
  }
}
