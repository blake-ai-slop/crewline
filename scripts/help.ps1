param([string]$Topic)
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Nguồn nội dung duy nhất cho danh sách lệnh và từng trang chi tiết.
$commands = @(
  @{
    Name = 'setup'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew setup'; Short = 'chọn đội mặc định cá nhân'
    Details = @('Chọn mẫu đội, agent, số worker, Rev, review và quyền; ghi ~/.crewline/config.json.', 'Chỉ áp dụng mặc định cho project mới; không sửa cấu hình project hiện có.', 'Chế độ mặc định không hỏi: pwsh -File <Crewline>/scripts/setup.ps1 -Defaults (cờ của script, không qua crew).')
    Examples = @('crew setup', 'pwsh -File ./scripts/setup.ps1 -Defaults')
  }
  @{
    Name = 'doctor'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew doctor'; Short = 'kiểm môi trường và phần mềm'
    Details = @('Kiểm herdr/hc, agent, git identity và template trên máy.', 'Báo phần mềm còn thiếu và cách cài; dùng sau khi cài Crewline hoặc đổi môi trường.')
    Examples = @('crew doctor')
  }
  @{
    Name = 'init'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew init [-Path .] [-Team standard|solo|large] [-Review lean|fast|full] [-Access work|wide] [-GitInit] [-NoCommit]'; Short = 'tạo context và cấu hình project'
    Details = @('Tạo context/, khối hướng dẫn agent và .crew/config.json; giữ file riêng, sao lưu trước khi sửa.', '-Path chọn project; -Team chọn mẫu đội; -Review chọn cấp review; -Access chọn quyền agent.', 'Thư mục chưa có git sẽ hỏi tạo; -GitInit đồng ý tạo git và commit đầu. -NoCommit bỏ commit khung.', 'Đội ưu tiên cờ dòng lệnh, rồi config cá nhân, rồi standard; quyền mặc định work, review lean.')
    Examples = @('crew init', 'crew init -Path D:/Projects/demo -Team solo -GitInit -NoCommit')
  }
  @{
    Name = 'upgrade'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew upgrade [-Path .] [-DryRun] [-NoCommit] [-Force]'; Short = 'cập nhật skeleton context'
    Details = @('Cập nhật khung context ở project -Path, giữ cấu hình riêng và sao lưu file cũ trên đĩa.', '-DryRun chỉ xem thay đổi; -NoCommit ghi file nhưng bỏ commit.', 'Context còn thay đổi chưa commit sẽ bị chặn; -Force cho phép tiếp tục khi bạn đã kiểm thay đổi đó.')
    Examples = @('crew upgrade -DryRun', 'crew upgrade -Path D:/Projects/demo -NoCommit')
  }
  @{
    Name = 'up'; Group = 'Dựng đội'; Syntax = 'crew up [-Path .] [-Restart w1|w2|…|planner|rev|all] [-Force]'; Short = 'mở đội theo cấu hình project'
    Details = @('Mở space và terminal theo .crew/config.json của -Path; terminal đang chạy được giữ lại.', '-Restart bật lại vai được chọn theo agent/quyền hiện tại; worker có bàn cố định .crew/worktrees/w<N>.', 'Worker còn task sẽ chặn restart; -Force cho phép bật lại và có thể mất phiên đang làm.')
    Examples = @('crew up', 'crew up -Restart w1')
  }
  @{
    Name = 'repair'; Group = 'Dựng đội'; Syntax = 'crew repair [-Path .] [-DryRun]'; Short = 'khôi phục terminal và bàn worker thiếu'
    Details = @('Chẩn đoán terminal, worktree w<N> và task của project -Path; -DryRun chỉ xem trước.', 'Sửa phần an toàn: prune worktree hỏng, tạo lại w<N>, bật terminal thiếu.', 'Worker vừa bật lại có task dở sẽ nhận lệnh tiếp tục; không xóa nhánh, thay đổi hay bản ghi.', 'Exit 1 nếu còn việc cần bạn quyết; đọc thông báo và xử lý trước khi chạy lại.')
    Examples = @('crew repair -DryRun', 'crew repair')
  }
  @{
    Name = 'task'; Group = 'Giao việc'; Syntax = 'crew task <tên> <file-prompt> [-Worker N] [-Review lean|fast|full]'; Short = 'giao task trên bàn worker rảnh'
    Details = @('Chạy trong repo crew; tên gồm a-z, 0-9 và dấu gạch ngang, tối đa 31 ký tự.', '-Worker chọn worker rảnh (bỏ cờ để tự chọn); bàn phải sạch, tạo nhánh crew/<tên> từ nhánh chính.', 'Chép prompt vào bàn worker, làm mới hội thoại bằng /clear hoặc /new, chờ rồi giao việc.', '-Review ghi cấp review riêng của task; bỏ cờ để dùng HOT/config khi giao Rev.')
    Examples = @('crew task login .crew/prompts/login.md', 'crew task help .crew/prompts/help.md -Worker 2 -Review fast')
  }
  @{
    Name = 'hot'; Group = 'Giao việc'; Syntax = 'crew hot [-Path .]'; Short = 'xem worktree, terminal và task'
    Details = @('Hiện cấu hình đội, git worktree, terminal và task đang chạy tại project -Path.', 'Dùng khi tiếp quản phiên hoặc theo dõi tiến độ; terminal thiếu thì xem crew repair.')
    Examples = @('crew hot', 'crew hot -Path D:/Projects/demo')
  }
  @{
    Name = 'limits'; Group = 'Giao việc'; Syntax = 'crew limits [-Path .]'; Short = 'đọc limit tài khoản một lần'
    Details = @('Đọc màn hình terminal của project -Path qua hc một lần, không theo dõi liên tục.', 'Hiện % đã dùng 5h/tuần; mốc chỉ theo 5h: ok (<50%), theo dõi (50–69%), hạn chế (70–89%), dừng (≥90%).', 'Tuần không vào mốc; tuần ≥90% thì có cảnh báo ⚠: báo chủ dự án trước khi giao cho agent đó.', 'Pane thiếu số có thể mượn pane cùng agent; không đọc được thì hiện không rõ.')
    Examples = @('crew limits')
  }
  @{
    Name = 'check'; Group = 'Giao việc'; Syntax = 'crew check <task> [-Path .]'; Short = 'kiểm phạm vi, cú pháp và test task'
    Details = @('Đọc task trong project -Path và so diff với danh sách Được sửa của prompt.', 'Kiểm cú pháp PowerShell và chạy test phần thay đổi; trả lỗi khi có kiểm tra không đạt.')
    Examples = @('crew check help', 'crew check help -Path D:/Projects/demo')
  }
  @{
    Name = 'review'; Group = 'Giao việc'; Syntax = 'crew review <task>[,<task2>…] [-DryRun]'; Short = 'gửi yêu cầu gộp task cho Rev'
    Details = @('Chạy trong repo crew; lấy các nhánh có commit mới và giữ đúng thứ tự task bạn đưa.', 'Cấp review: task > dòng đầu HOT > config > Gọn; nhiều task lấy cấp cao nhất.', '-DryRun chỉ in tin; bình thường gửi một dòng giao merge/test/dọn tới <repo>-rev.')
    Examples = @('crew review help -DryRun', 'crew review repair,help')
  }
  @{
    Name = 'send'; Group = 'Giao việc'; Syntax = 'crew send <terminal> "<tin>" [-Raw]'; Short = 'gửi tin hoặc lệnh tới terminal'
    Details = @('Gửi một dòng tới terminal; tự Enter nếu tin còn kẹt ở ô nhập và trạng thái cho phép.', 'Shell, lệnh /… và -Raw gửi trần; tin thông thường giữ metadata người gửi.', 'Không Enter khi blocked, dead hoặc gặp hộp thoại lạ; xử lý trạng thái terminal trước.')
    Examples = @('crew send demo-w1 "Tiếp tục task help theo prompt."', 'crew send demo-w1 "/model" -Raw')
  }
  @{
    Name = 'clean'; Group = 'Giao việc'; Syntax = 'crew clean <tên> [-Force]'; Short = 'dọn task đã gộp, giữ bàn worker'
    Details = @('Chạy trong repo crew; chỉ dọn task có trong .crew/tasks.json, nhánh phải đã merge vào HEAD repo chính.', 'Đưa w<N> về nhánh chính dạng detached, xóa nhánh task và bản ghi; giữ agent và thư mục.', '-Force cho phép bỏ task chưa merge và thay đổi chưa commit: chỉ dùng khi chắc chắn muốn bỏ.', 'Task kiểu cũ dùng worktree theo tên sẽ được gỡ worktree như trước.')
    Examples = @('crew clean help', 'crew clean abandoned -Force')
  }
  @{
    Name = 'selfcheck'; Group = 'Phát hành'; Syntax = 'crew selfcheck'; Short = 'cài thử và kiểm trước khi push'
    Details = @('Cài thử vào HOME giả, kiểm shim PS 5.1 (chỉ Windows) và luồng init/upgrade trước khi phát hành.', 'Không sửa HOME thật; lỗi kiểm tra trả exit 1.', 'Giữ thư mục thử: pwsh -File <Crewline>/scripts/selfcheck.ps1 -Keep (cờ của script, không qua crew).')
    Examples = @('crew selfcheck', 'pwsh -File ./scripts/selfcheck.ps1 -Keep')
  }
  @{
    Name = 'help'; Group = 'Khác'; Syntax = 'crew help [lệnh]'; Short = 'xem danh sách hoặc chi tiết lệnh'
    Details = @('Không có topic: hiện bắt đầu nhanh, nhóm lệnh và mẹo sử dụng.', 'Có tên lệnh: hiện cú pháp, hành vi và ví dụ; topic lạ hiện danh sách và trả exit 1.', 'Gọi script trực tiếp: pwsh -File <Crewline>/scripts/help.ps1 [-Topic <lệnh>].')
    Examples = @('crew help', 'crew help repair')
  }
)

if ($Topic) {
  $entry = $commands | Where-Object { $_.Name -eq $Topic } | Select-Object -First 1
  if ($entry) {
    Write-Output $entry.Syntax
    Write-Output ''
    $entry.Details | ForEach-Object { Write-Output "  $_" }
    Write-Output ''
    Write-Output 'Ví dụ'
    $entry.Examples | ForEach-Object { Write-Output "  $_" }
    exit 0
  }
}
Write-Output 'Crewline — đội agent trong herdr (planner chia việc · worker làm trong worktree riêng · Rev review/merge)'
Write-Output ''
Write-Output 'Bắt đầu nhanh'
Write-Output '  1. crew setup        chọn đội mặc định (chỉ cần 1 lần)'
Write-Output '  2. cd <project>; crew init   tạo context/ chung (thư mục chưa có git sẽ hỏi tạo)'
Write-Output '  3. crew up           mở planner / workers / rev trong herdr'
Write-Output '  4. Sang tab planner, nói việc muốn làm.'
Write-Output ''
foreach ($group in @($commands.Group | Select-Object -Unique)) {
  $names = @($commands | Where-Object { $_.Group -eq $group } | ForEach-Object { $_.Name })
  Write-Output ('{0,-23} {1}' -f $group, ($names -join ' · '))
}
Write-Output ''
foreach ($entry in $commands) {
  $brief = [regex]::Replace($entry.Syntax, '\s+\[-[^\]]+\]', '')
  Write-Output ('  {0,-36} {1}' -f $brief, $entry.Short)
}
Write-Output ''
Write-Output 'Mẹo'
Write-Output '  - Lần đầu ở project mới, mỗi agent hỏi trust thư mục — crew up liệt kê pane cần bấm.'
Write-Output '  - Đổi model/thinking: vào pane worker gõ /model — giữ qua các task.'
Write-Output '  - Đổi agent hoặc quyền: crew up -Restart <w1|…|planner|rev|all>.'
Write-Output '  - Lỡ đóng pane/space: crew repair (xem trước: crew repair -DryRun).'
Write-Output '  - Chi tiết một lệnh: crew help <lệnh>'
if ($Topic) { Write-Output "không có lệnh '$Topic'"; exit 1 }
exit 0
