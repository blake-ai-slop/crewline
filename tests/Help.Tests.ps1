. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# Không phụ thuộc code page của console: cả file chạy dưới IBM437 (console mặc định khi pwsh đầu tiên mở từ Git Bash),
# output của pwsh con đọc bằng UTF-8 cố định (help.ps1/crew.ps1 tự ghi UTF-8). Khôi phục mã hóa cũ ở cuối file.
$savedHelpEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437)
$repo = Split-Path $PSScriptRoot -Parent
$helpScript = Join-Path $repo 'scripts/help.ps1'
$commandNames = @('version', 'setup', 'doctor', 'init', 'upgrade', 'up', 'repair', 'task', 'queue', 'status', 'hot', 'lint', 'limits', 'check', 'review', 'send', 'clean', 'selfcheck', 'probe', 'confirm', 'help')

# Chạy pwsh con, đọc stdout+stderr bằng UTF-8 qua ProcessStartInfo (không qua [Console]::OutputEncoding của tiến trình cha).
function Invoke-PwshText([string[]]$Arguments) {
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
  foreach ($a in $Arguments) { $info.ArgumentList.Add($a) }
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $text = ($stdout.Result + $stderr.Result) -replace "`r`n", "`n"
  $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Text = $text.TrimEnd("`n") }
  $process.Dispose()
  $result
}
# Help chỉ xuất văn bản, không chạy crew/hc hoặc ghi cấu hình người dùng.
function Invoke-HelpPage([string]$Topic) {
  $arguments = @('-NoProfile', '-File', $helpScript)
  if ($Topic) { $arguments += @('-Topic', $Topic) }
  Invoke-PwshText $arguments
}
function Get-HelpParameters([string]$File) {
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
  @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

Describe 'crew help' {
  It 'review giải thích -Sent và dấu review không chắc' {
    $text = (Invoke-HelpPage 'review').Text
    $text | Should Match '-Sent'
    $text | Should Match 'reviewUnsure'
    $text | Should Match 'không gửi tin'
    $text | Should Match 'hc read <repo>-rev --lines 20'
  }
  It 'chạy dưới console IBM437 mà vẫn đọc đúng tiếng Việt' {
    [Console]::OutputEncoding.CodePage | Should Be 437
    (Invoke-HelpPage 'up').Text | Should Match 'mặc định 300 giây'
  }

  It 'up giải thích timeout mỗi project và mã thoát tổng hợp' {
    $text = (Invoke-HelpPage 'up').Text
    $text | Should Match '-Timeout <giây>'
    $text | Should Match 'mặc định 300 giây, 0 = không giới hạn'
    $text | Should Match 'dừng cây tiến trình con'
    $text | Should Match 'Exit 0 chỉ khi mọi project ok'
    $text | Should Match 'thời gian'
  }

  It 'task giải thích chặn trùng file và -Force' {
    $text = (Invoke-HelpPage 'task').Text
    $text | Should Match '\[-Force\]'
    $text | Should Match 'Chặn giao.*Được sửa:.*trùng file.*-Force vẫn giao kèm cảnh báo'
  }

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

  It 'crew help up nói rõ hành vi gõ trong pane của một vai và task đã xong' {
    $up = (Invoke-HelpPage 'up').Text
    $up | Should Match 'tab tự chuyển thành agent sau vài giây'
    $up | Should Match 'chữ đã in mất cùng pane'
    $up | Should Match '\.crew/self-pane\.log'
    $up | Should Match 'Linux/macOS.*mở tab khác rồi chạy lại'
    $up | Should Match 'Task mới:.*XONG.*worktree sạch.*không giao lại'
    $up | Should Match 'chưa báo XONG.*giao lại Tiếp tục dù đã commit note'
    $up | Should Match 'Task cũ giữ cách đoán'
    (Invoke-HelpPage 'status').Text | Should Match 'đã xong, chờ planner'
  }

  It 'dispatch crew help dùng help.ps1 thật cho danh sách, repair và topic lạ' {
    $crew = Join-Path $repo 'scripts/crew.ps1'
    $list = Invoke-PwshText @('-NoProfile', '-File', $crew, 'help')
    $list.ExitCode | Should Be 0
    $list.Text | Should Be (Invoke-HelpPage '').Text
    $default = Invoke-PwshText @('-NoProfile', '-File', $crew)
    $default.ExitCode | Should Be 0
    $default.Text | Should Be $list.Text
    $agent = Invoke-PwshText @('-NoProfile', '-File', $crew, 'help', 'agent')
    $agent.ExitCode | Should Be 0
    $agent.Text | Should Be (Invoke-HelpPage 'agent').Text
    $repair = Invoke-PwshText @('-NoProfile', '-File', $crew, 'help', 'repair')
    $repair.ExitCode | Should Be 0
    $repair.Text | Should Match '^crew repair \[-Path \.\] \[-DryRun\]'
    $unknown = Invoke-PwshText @('-NoProfile', '-File', $crew, 'help', 'khong-ton-tai')
    $unknown.ExitCode | Should Be 1
    $unknown.Text | Should Match "không có lệnh 'khong-ton-tai'"
  }

  It 'trang chính đúng nội dung và thứ tự đã duyệt, không có lệnh agent hay Mẹo' {
    $result = Invoke-HelpPage
    $result.ExitCode | Should Be 0
    $installCommand = if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { 'irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex' } else { 'curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh' }
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
      '  crew version             xem phiên bản Crewline đang cài',
      '  crew upgrade             cập nhật khung context của project (sau khi cập nhật Crewline)',
      '  crew init                tạo project với tùy chọn riêng (tên, đội)',
      '  Cập nhật Crewline: chạy lại lệnh cài một dòng',
      "    $installCommand", '',
      'Chi tiết: crew help <lệnh>   ·   Lệnh agent dùng: crew help agent'
    ) -join "`n"
    $result.Text | Should Be $expected
    $result.Text | Should Not Match 'crew (task|check|review|send|clean|limits|selfcheck|repair)\b|Mẹo'
  }

  It 'agent liệt kê đủ mười hai lệnh theo nhóm và thứ tự' {
    $result = Invoke-HelpPage 'agent'
    $result.ExitCode | Should Be 0
    $result.Text | Should Match '^Đây là lệnh planner, Rev dùng; người dùng thường không cần gõ\.'
    $ordered = @('Giao việc', 'crew task', 'crew queue', 'crew limits', 'crew send', 'crew confirm', 'Kiểm và gộp', 'crew check', 'crew review', 'crew clean', 'crew lint', 'Chẩn đoán, phát hành', 'crew repair', 'crew selfcheck', 'crew probe')
    $previous = -1
    foreach ($item in $ordered) {
      $index = $result.Text.IndexOf($item)
      ($index -gt $previous) | Should Be $true
      $previous = $index
    }
    ([regex]::Matches($result.Text, '(?m)^  crew ').Count) | Should Be 12
  }

  It 'status và hot dispatch cùng Invoke-Hot, không gọi hc thật' {
    $entryAst = @(Get-CrewAsts)[0]
    $dispatch = $entryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -Last 1
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

  It 'crew help upgrade mô tả .new, .local.md và 3 nhóm của -DryRun' {
    $text = (Invoke-HelpPage 'upgrade').Text
    $text | Should Match 'không bao giờ ghi đè'
    $text | Should Match ([regex]::Escape('<file>.new'))
    $text | Should Match ([regex]::Escape('context/roles/<vai>.local.md'))
    $text | Should Match ([regex]::Escape('<!-- /crew -->'))
    $text | Should Match '-DryRun in 3 nhóm'
    $text | Should Not Match 'sao lưu'
  }

  It 'up/hot/send nhắc config suggestions và phép thử gõ 1 phím' {
    $up = (Invoke-HelpPage 'up').Text
    $up | Should Match 'suggestions'
    $up | Should Match 'off \(mặc định'
    $up | Should Match 'crew up -Restart <vai>'
    (Invoke-HelpPage 'hot').Text | Should Match 'có thể là gợi ý Claude'
    (Invoke-HelpPage 'send').Text | Should Match 'gõ đúng 1 dấu cách để thử, không bao giờ bấm phím xóa'
  }

  It 'probe/confirm: terminal tạm, lưu màn hình, ghi bản đã kiểm; confirm chỉ Enter 1 lần khi không hộp thoại' {
    $p = (Invoke-HelpPage 'probe').Text
    $p | Should Match '^crew probe <claude\|codex>'
    $p | Should Match 'terminal hc tạm'
    $p | Should Match '~/\.crewline/probe/<agent>-<phiên bản>-<thời điểm>/'
    $p | Should Match 'Luôn đóng terminal tạm'
    $p | Should Match '~/\.crewline/agents\.json'
    $p | Should Match 'crew confirm <terminal>'
    $c = (Invoke-HelpPage 'confirm').Text
    $c | Should Match '^crew confirm <terminal>'
    $c | Should Match 'Enter đúng 1 lần'
    $c | Should Match 'không bấm phím'
    $c | Should Match 'crew review <task> -Sent'
    (Invoke-HelpPage '').Text | Should Not Match 'crew (probe|confirm)'
  }

  It 'v16 assist-nolearn: không còn crew assist; confirm nói khối CẦN PLANNER XEM, 3 chế độ, không học mẫu' {
    $c = (Invoke-HelpPage 'confirm').Text
    $c | Should Match 'CẦN PLANNER XEM'
    $c | Should Match 'off \(như cũ\) \| ask .* \| auto'
    $c | Should Match 'không học kiểu màn hình'
    $c | Should Match '\.crew/assist\.log'
    $c | Should Not Match 'assist learn'
    $r = Invoke-HelpPage 'assist'
    $r.ExitCode | Should Be 1
    (Invoke-HelpPage 'agent').Text | Should Not Match 'crew assist'
  }

  It 'crew help send nói rõ agent bận thì tin nằm chờ' {
    $result = Invoke-HelpPage 'send'
    $result.ExitCode | Should Be 0
    $result.Text | Should Match 'agent đang bận'
    $result.Text | Should Match 'tin nằm chờ'
  }

  foreach ($topic in @('task', 'queue', 'up', 'clean', 'init', 'upgrade', 'review', 'send', 'lint')) {
    It "mọi cờ của $topic khớp param thật crew.ps1 qua AST" {
      $parameters = Get-CrewParamNames
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

  It 'queue: giữ theo After/trùng file/limit, tự chạy sau clean và up' {
    $text = (Invoke-HelpPage 'queue').Text
    $text | Should Match '\.crew/queue\.json'
    $text | Should Match 'mốc hạn chế với -Size L, hoặc mốc dừng'
    $text | Should Match 'trùng file Được sửa'
    $text | Should Match 'dừng giao tiếp'
    $text | Should Match '\.crew/queue\.log'
    $text | Should Match 'tối đa 200 dòng'
    $text | Should Match 'thành công \(exit 0\)'
    $text | Should Match 'trùng file giữa các mục sắp giao cùng lượt'
    (Invoke-HelpPage 'clean').Text | Should Match 'tự giao mục trong hàng đợi'
    (Invoke-HelpPage 'up').Text | Should Match 'tự giao mục trong hàng đợi'
  }

  It 'limits nói đúng nguồn số: trực tiếp, không tốn token, màn hình có thể cũ' {
    $text = (Invoke-HelpPage 'limits').Text
    $text | Should Match 'trực tiếp từ Codex/Claude'
    $text | Should Match 'không tốn token'
    $text | Should Match 'màn hình, có thể cũ'
  }

  It 'ghi đủ cờ theo hợp đồng, không bỏ sót khi thêm chi tiết' {
    $expected = @{
      task = @('Worker', 'Review'); queue = @('Worker', 'Review', 'After', 'Size', 'Remove', 'Run', 'DryRun'); up = @('Path', 'All', 'DryRun', 'Restart', 'Force'); clean = @('Force')
      init = @('Path', 'Name', 'Team', 'Review', 'Access', 'GitInit', 'NoCommit')
      upgrade = @('Path', 'DryRun', 'NoCommit', 'Force'); review = @('DryRun'); send = @('Raw')
      lint = @('Path', 'Strict'); repair = @('Path', 'DryRun'); status = @('Path'); hot = @('Path'); limits = @('Path'); check = @('Path', 'NoTest')
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
[Console]::OutputEncoding = $savedHelpEncoding
