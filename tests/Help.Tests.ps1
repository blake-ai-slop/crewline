[Console]::OutputEncoding = [Text.Encoding]::UTF8
$repo = Split-Path $PSScriptRoot -Parent
$helpScript = Join-Path $repo 'scripts/help.ps1'
$commandNames = @('setup', 'doctor', 'init', 'upgrade', 'up', 'repair', 'task', 'status', 'hot', 'limits', 'check', 'review', 'send', 'clean', 'selfcheck', 'help')

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
    (Invoke-HelpPage 'status').Text | Should Match 'Hiện pane có tin chờ'
    (Invoke-HelpPage '').Text | Should Not Match 'tin chờ/kẹt ô nhập'
    (Invoke-HelpPage 'hot').Text | Should Match 'hiện tin kẹt: sang đúng pane đó, Enter để gửi hoặc xóa chữ'
    (Invoke-HelpPage 'hot').Text | Should Not Match 'chưa nhận diện'
    (Invoke-HelpPage 'send').Text | Should Match 'Enter để gửi hoặc xóa chữ'
    (Invoke-HelpPage 'send').Text | Should Not Match 'Flush|Discard'
  }

  It 'dispatch crew help dùng help.ps1 thật cho danh sách, repair và topic lạ' {
    $crew = Join-Path $repo 'scripts/crew.ps1'
    $list = & pwsh -NoProfile -File $crew help 2>&1
    $LASTEXITCODE | Should Be 0
    ($list -join "`n") | Should Be (Invoke-HelpPage '').Text
    $default = & pwsh -NoProfile -File $crew 2>&1
    $LASTEXITCODE | Should Be 0
    ($default -join "`n") | Should Be ($list -join "`n")
    $agent = & pwsh -NoProfile -File $crew help agent 2>&1
    $LASTEXITCODE | Should Be 0
    ($agent -join "`n") | Should Be (Invoke-HelpPage 'agent').Text
    $repair = & pwsh -NoProfile -File $crew help repair 2>&1
    $LASTEXITCODE | Should Be 0
    ($repair -join "`n") | Should Match '^crew repair \[-Path \.\] \[-DryRun\]'
    $unknown = & pwsh -NoProfile -File $crew help khong-ton-tai 2>&1
    $LASTEXITCODE | Should Be 1
    ($unknown -join "`n") | Should Match "không có lệnh 'khong-ton-tai'"
  }

  It 'trang chính đúng nội dung và thứ tự đã duyệt, không có lệnh agent hay Mẹo' {
    $result = Invoke-HelpPage
    $result.ExitCode | Should Be 0
    $expected = @(
      'Crewline — đội agent làm việc song song trong herdr', '',
      'Dùng hằng ngày',
      '  crew up              dựng đội, khôi phục nếu mất (project mới: hỏi tạo)',
      '  crew up -All         như trên, cho mọi project (sau khi khởi động lại máy)',
      '  crew status          đội đang làm gì', '',
      'Rồi sang tab planner và nói việc muốn làm.', '',
      'Khi cần',
      '  crew up -Restart <vai>   bật lại agent (sau khi đổi agent hoặc quyền)',
      '  crew setup               đổi đội mặc định cho project mới',
      '  crew doctor              máy có thiếu gì không',
      '  crew upgrade             cập nhật khung context của project',
      '  crew init                tạo project với tùy chọn riêng (tên, đội)', '',
      'Chi tiết: crew help <lệnh>   ·   Lệnh agent dùng: crew help agent'
    ) -join "`n"
    $result.Text | Should Be $expected
    $result.Text | Should Not Match 'crew (task|check|review|send|clean|limits|selfcheck|repair)\b|Mẹo'
  }

  It 'agent liệt kê đủ tám lệnh theo nhóm và thứ tự' {
    $result = Invoke-HelpPage 'agent'
    $result.ExitCode | Should Be 0
    $result.Text | Should Match '^Đây là lệnh planner, Rev dùng; người dùng thường không cần gõ\.'
    $ordered = @('Giao việc', 'crew task', 'crew limits', 'crew send', 'Kiểm và gộp', 'crew check', 'crew review', 'crew clean', 'Chẩn đoán, phát hành', 'crew repair', 'crew selfcheck')
    $previous = -1
    foreach ($item in $ordered) {
      $index = $result.Text.IndexOf($item)
      ($index -gt $previous) | Should Be $true
      $previous = $index
    }
    ([regex]::Matches($result.Text, '(?m)^  crew ').Count) | Should Be 8
  }

  It 'status và hot dispatch cùng Invoke-Hot, không gọi hc thật' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/crew.ps1'), [ref]$null, [ref]$null)
    $dispatch = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -Last 1
    function Invoke-Hot { 'hot-path' }
    foreach ($name in @('status', 'hot')) {
      $clause = @($dispatch.Clauses | Where-Object { $_.Item1.Value -eq $name })
      $clause.Count | Should Be 1
      $clause[0].Item2.Extent.Text | Should Be '{ Invoke-Hot }'
      (& ([ScriptBlock]::Create($clause[0].Item2.Extent.Text.Trim('{}')))) | Should Be 'hot-path'
    }
    (Invoke-HelpPage 'hot').Text | Should Match 'tên cũ của status'
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
    $result.Text | Should Match 'Dùng hằng ngày'
    $result.Text | Should Match 'crew help agent'
  }

  It 'crew help send nói rõ agent bận thì tin nằm chờ' {
    $result = Invoke-HelpPage 'send'
    $result.ExitCode | Should Be 0
    $result.Text | Should Match 'agent đang bận'
    $result.Text | Should Match 'tin nằm chờ'
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

  It 'sau reboot chỉ hướng dẫn crew up -All, repair không còn -All, nói rõ khi nào mở lại hội thoại' {
    $main = (Invoke-HelpPage '').Text
    $main | Should Match 'crew up -All.*sau khi khởi động lại máy'
    (Invoke-HelpPage 'up').Text | Should Match 'Sau khi khởi động lại máy: crew up -All'
    $main | Should Not Match 'khởi động lại máy: crew repair'
    (Invoke-HelpPage 'repair').Text | Should Not Match '\[-All'
    (Invoke-HelpPage 'up').Text | Should Match 'mở lại đúng hội thoại cũ của vai khi chắc chắn'
  }

  It 'limits nói đúng nguồn số: trực tiếp, không tốn token, màn hình có thể cũ' {
    $text = (Invoke-HelpPage 'limits').Text
    $text | Should Match 'trực tiếp từ Codex/Claude'
    $text | Should Match 'không tốn token'
    $text | Should Match 'màn hình, có thể cũ'
  }

  It 'ghi đủ cờ theo hợp đồng, không bỏ sót khi thêm chi tiết' {
    $expected = @{
      task = @('Worker', 'Review'); up = @('Path', 'All', 'DryRun', 'Restart', 'Force'); clean = @('Force')
      init = @('Path', 'Name', 'Team', 'Review', 'Access', 'GitInit', 'NoCommit')
      upgrade = @('Path', 'DryRun', 'NoCommit', 'Force'); review = @('DryRun'); send = @('Raw')
      repair = @('Path', 'DryRun'); status = @('Path'); hot = @('Path'); limits = @('Path'); check = @('Path')
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
