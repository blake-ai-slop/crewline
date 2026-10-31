# Test Get-Tasks/Save-Tasks: trích hàm bằng AST từ crew.ps1, không chạy phần dispatch cuối file (task/hot/clean gọi hc thật).
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-Tasks', 'Save-Tasks' }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

function New-TaskRepo([object[]]$Names) {
  $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  if ($null -ne $Names) {
    $items = @($Names | ForEach-Object { [pscustomobject]@{ name = $_; worker = 1 } })
    ConvertTo-Json -InputObject $items -Depth 5 | Set-Content (Join-Path $root '.crew/tasks.json') -Encoding utf8
  }
  $root
}

Describe 'Get-Tasks luôn trả mảng' {
  It 'không có tasks.json -> mảng rỗng' {
    $root = New-TaskRepo $null
    $t = Get-Tasks $root
    ($t -is [array]) | Should Be $true
    $t.Count | Should Be 0
  }

  foreach ($n in 0, 1, 2) {
    It "tasks.json có $n phần tử -> mảng $n phần tử, += thêm được" {
      $names = @(1..$n | Where-Object { $n -gt 0 } | ForEach-Object { "t$_" })
      $root = New-TaskRepo $names
      $t = Get-Tasks $root
      ($t -is [array]) | Should Be $true
      $t.Count | Should Be $n
      $t += [pscustomobject]@{ name = 'moi'; worker = 2 }
      $t.Count | Should Be ($n + 1)
      $t[-1].name | Should Be 'moi'
    }
  }

  It 'tasks.json rỗng -> mảng rỗng' {
    $root = New-TaskRepo $null
    '' | Set-Content (Join-Path $root '.crew/tasks.json')
    $t = Get-Tasks $root
    ($t -is [array]) | Should Be $true
    $t.Count | Should Be 0
  }

  It 'Where-Object lọc còn 1 phần tử rồi Save-Tasks vẫn ghi mảng (như crew clean)' {
    $root = New-TaskRepo @('a', 'b')
    $tasks = Get-Tasks $root
    Save-Tasks $root @($tasks | Where-Object { $_.name -ne 'a' })
    $t = Get-Tasks $root
    ($t -is [array]) | Should Be $true
    $t.Count | Should Be 1
    $t[0].name | Should Be 'b'
  }
}

Describe 'Save-Tasks ghi mảng JSON' {
  foreach ($n in 0, 1, 2) {
    It "$n phần tử -> [...]" {
      $root = New-TaskRepo $null
      $items = @(1..$n | Where-Object { $n -gt 0 } | ForEach-Object { [pscustomobject]@{ name = "t$_"; worker = $_ } })
      Save-Tasks $root $items
      $raw = (Get-Content (Join-Path $root '.crew/tasks.json') -Raw).Trim()
      $raw.StartsWith('[') | Should Be $true
      $raw.EndsWith(']') | Should Be $true
      (Get-Tasks $root).Count | Should Be $n
    }
  }

  It '$null -> []' {
    $root = New-TaskRepo $null
    Save-Tasks $root $null
    (Get-Content (Join-Path $root '.crew/tasks.json') -Raw).Trim() | Should Be '[]'
  }

  It 'chu trình như crew task lần 2: 1 task + 1 task mới -> 2 task' {
    $root = New-TaskRepo @('dau')
    $tasks = Get-Tasks $root
    $tasks = @($tasks) + [pscustomobject]@{ name = 'hai'; worker = 2 }
    Save-Tasks $root $tasks
    $t = Get-Tasks $root
    $t.Count | Should Be 2
    ($t | ForEach-Object { $_.name }) -join ',' | Should Be 'dau,hai'
  }
}
