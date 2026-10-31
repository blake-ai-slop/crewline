# Test Get-AgentCommand: trích hàm bằng AST từ crew.ps1, không chạy phần dispatch cuối file (không gọi hc).
$crewScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($crewScript, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-Flags', 'Quote', 'Get-AgentCommand' }, $false)) {
  . ([scriptblock]::Create($fn.Extent.Text))
}

$expected = @{
  'claude|work' = "claude --permission-mode acceptEdits"
  'claude|wide' = "claude --permission-mode bypassPermissions"
  'codex|work'  = "codex --no-daemon --sandbox workspace-write --ask-for-approval on-request"
  'codex|wide'  = "codex --no-daemon --sandbox danger-full-access --ask-for-approval never"
}
$lines = @{
  planner = 'Bạn là planner của crew này. Đọc context/README.md rồi context/roles/planner.md; làm đúng vai trò đó và chờ chủ dự án giao việc.'
  worker  = 'Bạn là worker. Đọc context/roles/worker.md, rồi làm đúng file C:\x\.crew\prompt.md. Thư mục làm việc: C:\x (nhánh crew/x); mọi lệnh chạy trong thư mục này.'
  rev     = 'Bạn là rev của crew này. Đọc context/README.md rồi context/roles/rev.md; làm đúng vai trò đó và chờ planner giao việc.'
}

Describe 'Get-AgentCommand dựng lệnh theo agent và access' {
  foreach ($kind in 'claude', 'codex') {
    foreach ($access in 'work', 'wide') {
      foreach ($role in 'planner', 'worker', 'rev') {
        It "$kind / $access / $role" {
          $cmd = Get-AgentCommand $kind $access $lines[$role]
          $cmd | Should BeExactly ("$($expected["$kind|$access"]) '" + $lines[$role] + "'")
          ([regex]::Matches($cmd, '--no-daemon')).Count | Should Be ([int]($kind -eq 'codex'))
        }
      }
    }
  }

  It "dấu ' và tiếng Việt được quote đúng, chạy lại ra đúng chuỗi" {
    $line = "Đọc file 'kế hoạch' của Rev's task"
    $cmd = Get-AgentCommand 'claude' 'wide' $line
    $cmd | Should BeExactly "claude --permission-mode bypassPermissions 'Đọc file ''kế hoạch'' của Rev''s task'"
    $arg = $cmd.Substring('claude --permission-mode bypassPermissions '.Length)
    (Invoke-Expression $arg) | Should BeExactly $line
  }
}

Describe 'crew.ps1 dùng Get-AgentCommand cho planner, Rev, worker' {
  It 'không còn tự ghép exe/cờ riêng' {
    $src = Get-Content $crewScript -Raw
    ([regex]::Matches($src, 'Get-AgentCommand \$cfg\.planner \$cfg\.access')).Count | Should Be 1
    ([regex]::Matches($src, 'Get-AgentCommand \$cfg\.rev \$cfg\.access')).Count | Should Be 1
    ([regex]::Matches($src, 'Get-AgentCommand \$kind \$cfg\.access')).Count | Should Be 1
    $src -match "'codex --no-daemon'" | Should Be $false
  }
}
