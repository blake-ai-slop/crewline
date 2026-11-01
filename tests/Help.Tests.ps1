$repo = Split-Path $PSScriptRoot -Parent
$helpScript = Join-Path $repo 'scripts/help.ps1'
$commandNames = @('setup', 'doctor', 'init', 'upgrade', 'up', 'repair', 'task', 'hot', 'limits', 'check', 'review', 'send', 'clean', 'selfcheck', 'help')

# Help chỉ xuất văn bản, không chạy crew/hc hoặc ghi cấu hình người dùng.
function Invoke-HelpPage([string]$Topic) {
  $arguments = @('-NoProfile', '-File', $helpScript)
  if ($Topic) { $arguments += @('-Topic', $Topic) }
  $output = & pwsh @arguments 2>&1
  [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
}
function Get-HelpParameters([string]$File) {
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
  @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'crew help' {
  It 'hướng dẫn bản chép, chuyển thư mục và cảnh báo hot' {
    (Invoke-HelpPage 'init').Text | Should Match 'Chép thư mục.*crew init -Name'
    (Invoke-HelpPage 'repair').Text | Should Match 'đổi tên/chuyển thư mục.*git worktree repair, tasks.json, sổ, bật lại terminal'
    (Invoke-HelpPage 'hot').Text | Should Match 'Cảnh báo.*planner thứ hai'
  }

  It 'dispatch crew help dùng help.ps1 thật cho danh sách, repair và topic lạ' {
    $crew = Join-Path $repo 'scripts/crew.ps1'
    $list = & pwsh -NoProfile -File $crew help 2>&1
    $LASTEXITCODE | Should Be 0
    ($list -join "`n") | Should Match 'Bắt đầu nhanh'
    $repair = & pwsh -NoProfile -File $crew help repair 2>&1
    $LASTEXITCODE | Should Be 0
    ($repair -join "`n") | Should Match '^crew repair \[-Path \.\] \[-DryRun\]'
    $unknown = & pwsh -NoProfile -File $crew help khong-ton-tai 2>&1
    $LASTEXITCODE | Should Be 1
    ($unknown -join "`n") | Should Match "không có lệnh 'khong-ton-tai'"
  }

  It 'hiện bắt đầu nhanh và đủ 15 lệnh trong khoảng 45 dòng' {
    $result = Invoke-HelpPage
    $result.ExitCode | Should Be 0
    $result.Text | Should Match 'Bắt đầu nhanh'
    foreach ($name in $commandNames) { $result.Text | Should Match ("(?m)^  crew " + $name + '\b') }
    ($result.Text -split '\r?\n').Count -le 45 | Should Be $true
  }

  foreach ($name in $commandNames) {
    It "topic $name trả 0 và có cú pháp cùng ví dụ" {
      $result = Invoke-HelpPage $name
      $result.ExitCode | Should Be 0
      $result.Text | Should Match ('^crew ' + $name + '\b')
      $result.Text | Should Match 'Ví dụ'
    }
  }

  It 'topic lạ trả 1 kèm danh sách và thông báo' {
    $result = Invoke-HelpPage 'khong-ton-tai'
    $result.ExitCode | Should Be 1
    $result.Text | Should Match "không có lệnh 'khong-ton-tai'"
    foreach ($name in $commandNames) { $result.Text | Should Match ("(?m)^  crew " + $name + '\b') }
  }

  foreach ($topic in @('task', 'up', 'clean', 'init', 'upgrade', 'review', 'send')) {
    It "mọi cờ của $topic khớp param thật crew.ps1 qua AST" {
      $parameters = Get-HelpParameters (Join-Path $repo 'scripts/crew.ps1')
      $result = Invoke-HelpPage $topic
      $flags = @([regex]::Matches($result.Text, '(?m)(?:^|[\s\[])-([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
      $flags.Count -gt 0 | Should Be $true
      foreach ($flag in $flags) { ($parameters -contains $flag) | Should Be $true }
    }
  }

  It 'ghi đủ cờ theo hợp đồng, không bỏ sót khi thêm chi tiết' {
    $expected = @{
      task = @('Worker', 'Review'); up = @('Path', 'Restart', 'Force'); clean = @('Force')
      init = @('Path', 'Name', 'Team', 'Review', 'Access', 'GitInit', 'NoCommit')
      upgrade = @('Path', 'DryRun', 'NoCommit', 'Force'); review = @('DryRun'); send = @('Raw')
      repair = @('Path', 'DryRun'); hot = @('Path'); limits = @('Path'); check = @('Path')
    }
    foreach ($topic in $expected.Keys) {
      $result = Invoke-HelpPage $topic
      foreach ($flag in $expected[$topic]) { $result.Text | Should Match ("\[-" + $flag + '\b') }
    }
  }

  It 'cờ gọi trực tiếp setup/selfcheck tồn tại trong script tương ứng' {
    foreach ($entry in @(@{ Name = 'setup'; Flag = 'Defaults' }, @{ Name = 'selfcheck'; Flag = 'Keep' })) {
      $parameters = Get-HelpParameters (Join-Path $repo ("scripts/" + $entry.Name + '.ps1'))
      ($parameters -contains $entry.Flag) | Should Be $true
      (Invoke-HelpPage $entry.Name).Text | Should Match ('-' + $entry.Flag + '\b')
    }
  }
}
