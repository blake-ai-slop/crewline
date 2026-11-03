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
    Name = 'init'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew init [-Path .] [-Name <tên>] [-Team standard|solo|large] [-Review lean|fast|full] [-Access work|wide] [-GitInit] [-NoCommit]'; Short = 'tạo context và cấu hình project'
    Details = @('Tạo context/, khối hướng dẫn agent và .crew/config.json; giữ file riêng, sao lưu trước khi sửa.', '-Path chọn project; -Team chọn mẫu đội; -Review chọn cấp review; -Access chọn quyền agent.', 'Thư mục chưa có git sẽ hỏi tạo; -GitInit đồng ý tạo git và commit đầu. -NoCommit bỏ commit khung.', 'Đội ưu tiên cờ dòng lệnh, rồi config cá nhân, rồi standard; quyền mặc định work, review lean.', 'Tên crew (tiền tố terminal <tên>-planner/-w<N>/-rev) chốt vào "name" của .crew/config.json và sổ ~/.crewline/projects.json; trùng project khác thì tự thêm -2, -3…', '-Name <tên> đặt tên crew: a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng -.', 'Chép thư mục project: crew init -Name <tên mới> dọn tasks.json và worktree chép theo chưa đăng ký trong git; không có -Name sẽ dừng.')
    Examples = @('crew init', 'crew init -Name shop-web', 'crew init -Path D:/Projects/demo -Team solo -GitInit -NoCommit')
  }
  @{
    Name = 'upgrade'; Group = 'Cài đặt & cấu hình'; Syntax = 'crew upgrade [-Path .] [-DryRun] [-NoCommit] [-Force]'; Short = 'cập nhật skeleton context'
    Details = @('Cập nhật khung context ở project -Path, giữ cấu hình riêng và sao lưu file cũ trên đĩa.', '-DryRun chỉ xem thay đổi; -NoCommit ghi file nhưng bỏ commit.', 'Context còn thay đổi chưa commit sẽ bị chặn; -Force cho phép tiếp tục khi bạn đã kiểm thay đổi đó.')
    Examples = @('crew upgrade -DryRun', 'crew upgrade -Path D:/Projects/demo -NoCommit')
  }
  @{
    Name = 'up'; Group = 'Dựng đội'; Syntax = 'crew up [-Path .] [-All] [-DryRun] [-Restart w1|w2|…|planner|rev|all] [-Force]'; Short = 'mở đội hoặc khôi phục sau reboot/herdr reset'
    Details = @('Chạy crew up trong một pane của herdr-app để mở được tab.', 'Lần đầu ở project mới, mỗi agent hỏi trust thư mục; crew up liệt kê pane cần bạn bấm xác nhận.', 'Lỡ đóng pane/space: crew up (xem trước: crew up -DryRun). Sau khi khởi động lại máy: crew up -All (xem trước: crew up -All -DryRun).', 'Chưa init: crew up hỏi tạo context/, CLAUDE.md, AGENTS.md, .crew/, sửa .gitignore và commit, rồi dựng đội ngay; mặc định Có. Chưa có git/commit: hỏi một lần về git init và commit tất cả file, mặc định Thôi. HOME/gốc chưa có commit và worktree phụ chưa init bị chặn. Không hỏi được thì chạy crew init.', '-DryRun ở project chưa init chỉ báo sẽ hỏi; -Restart và -All không hỏi init.', 'Project mới: mở space, tab và terminal theo .crew/config.json của -Path; worker có bàn cố định .crew/worktrees/w<N>.', 'Project đang dở: bật agent thiếu hoặc mất, sửa worktree, giao lại task dở, in việc cần bạn quyết (có thì exit 1). Đã ổn thì không làm gì và không gửi lại task.', 'Bật lại agent thiếu hoặc mất: mở lại đúng hội thoại cũ của vai khi chắc chắn (sổ .crew/sessions.json), không thì hội thoại mới; in rõ từng vai kèm lý do. -Restart luôn là hội thoại mới.', 'Project cũ chưa có tên trong config được ghi tên vào config và sổ; tên terminal và space/tab giữ nguyên.', '-All: chạy cho mọi project trong sổ ~/.crewline/projects.json, cộng project ở -Path (mặc định thư mục hiện tại) nếu đã init mà chưa có trong sổ; mỗi project một tiến trình riêng, project lỗi không chặn project khác.', '-All in bảng tên, đường dẫn, kết quả (ok, cần người quyết, lỗi, bỏ qua). Mục sổ mất thư mục hoặc mất .crew/config.json thì bỏ qua và giữ nguyên trong sổ. Có lỗi hoặc cần người quyết thì exit 1; sổ hỏng thì báo lỗi, không ghi đè.', 'Gõ crew up trong pane của một vai đang là shell trống: tab tự chuyển thành agent sau vài giây, chữ đã in mất cùng pane; có chuyện thì xem .crew/self-pane.log. Linux/macOS không tự thay: mở tab khác rồi chạy lại.', 'Task đã xong (nhánh có commit, worktree sạch, có context/tasks/<tên>.md trong nhánh) thì không giao lại, chỉ in thông báo; còn việc thì crew send.', '-DryRun chỉ báo sẽ làm gì: không ghi, không bật, không gửi.', '-Restart bật lại vai được chọn theo agent/quyền hiện tại, không đi với -All hay -DryRun. Worker còn task sẽ chặn restart; -Force cho phép bật lại và có thể mất phiên đang làm.')
    Examples = @('crew up', 'crew up -DryRun', 'crew up -All', 'crew up -All -DryRun', 'crew up -Restart w1')
  }
  @{
    Name = 'repair'; Group = 'Dựng đội'; Syntax = 'crew repair [-Path .] [-DryRun]'; Short = 'chẩn đoán terminal, worktree và task một project'
    Details = @('Chẩn đoán terminal, worktree w<N> và task của project -Path; -DryRun chỉ xem trước.', 'Sửa phần an toàn: prune worktree hỏng, tạo lại w<N>, bật terminal thiếu.', 'Worker vừa bật lại có task dở sẽ nhận lệnh tiếp tục, task đã xong thì không; không xóa nhánh, thay đổi hay bản ghi.', 'repair cũng xử lý project đã đổi tên/chuyển thư mục (git worktree repair, tasks.json, sổ, bật lại terminal).', 'Exit 1 nếu còn việc cần bạn quyết; đọc thông báo và xử lý trước khi chạy lại.', 'Khôi phục thường ngày không cần lệnh này: crew up làm cùng việc đó.')
    Examples = @('crew repair -DryRun', 'crew repair')
  }
  @{
    Name = 'task'; Group = 'Giao việc'; Syntax = 'crew task <tên> <file-prompt> [-Worker N] [-Review lean|fast|full]'; Short = 'giao task trên bàn worker rảnh'
    Details = @('Chạy trong repo crew; tên gồm a-z, 0-9 và dấu gạch ngang, tối đa 31 ký tự.', '-Worker chọn worker rảnh (bỏ cờ để tự chọn); bàn phải sạch, tạo nhánh crew/<tên> từ nhánh chính.', 'Chép prompt vào bàn worker, làm mới hội thoại bằng /clear hoặc /new, chờ rồi giao việc.', 'Đổi model/thinking: vào pane worker gõ /model; giữ qua các task.', '-Review ghi cấp review riêng của task; bỏ cờ để dùng HOT/config khi giao Rev.')
    Examples = @('crew task login .crew/prompts/login.md', 'crew task help .crew/prompts/help.md -Worker 2 -Review fast')
  }
  @{
    Name = 'status'; Group = 'Dùng hằng ngày'; Syntax = 'crew status [-Path .]'; Short = 'xem worktree, terminal và task; hiện pane có tin chờ'
    Details = @('Hiện pane có tin chờ khi agent đang bận.', 'Hiện cấu hình đội, git worktree, terminal và task đang chạy tại project -Path; task worker đã làm xong có nhãn đã xong, chờ planner.', 'Khối Cảnh báo hiện khi main chưa commit/merge dở, worker bẩn không có task, agent lạ ở root (có thể có planner thứ hai), hoặc project là bản chép.', 'Pane Codex rảnh mà ô nhập còn chữ hiện tin kẹt: sang đúng pane đó, Enter để gửi hoặc xóa chữ.', 'Dùng khi tiếp quản phiên hoặc theo dõi tiến độ; terminal thiếu thì chạy crew up.')
    Examples = @('crew status', 'crew status -Path D:/Projects/demo')
  }
  @{
    Name = 'hot'; Group = 'Giao việc'; Syntax = 'crew hot [-Path .]'; Short = 'xem worktree, terminal và task; hiện pane có tin chờ'
    Details = @('Đây là tên cũ của status; dùng crew status để xem đội đang làm gì.', 'Hiện cấu hình đội, git worktree, terminal và task đang chạy tại project -Path; task worker đã làm xong có nhãn đã xong, chờ planner.', 'Khối Cảnh báo hiện khi main chưa commit/merge dở, worker bẩn không có task, agent lạ ở root (có thể có planner thứ hai), hoặc project là bản chép.', 'Pane Codex rảnh mà ô nhập còn chữ hiện tin kẹt: sang đúng pane đó, Enter để gửi hoặc xóa chữ.', 'Dùng khi tiếp quản phiên hoặc theo dõi tiến độ; terminal thiếu thì chạy crew up.')
    Examples = @('crew hot', 'crew hot -Path D:/Projects/demo')
  }
  @{
    Name = 'limits'; Group = 'Giao việc'; Syntax = 'crew limits [-Path .]'; Short = 'hỏi limit tài khoản một lần'
    Details = @('Hỏi số trực tiếp từ Codex/Claude một lần cho mỗi loại agent trong config của project -Path, không tốn token, không theo dõi liên tục.', 'Không hỏi được (thiếu CLI, chưa đăng nhập, đổi format) thì lấy từ màn hình terminal qua hc và ghi (màn hình, có thể cũ); pane thiếu số có thể mượn pane cùng agent, không đọc được thì hiện không rõ.', 'Hiện % đã dùng 5h/tuần và giờ reset 5h; mốc chỉ theo 5h: ok (<50%), theo dõi (50–69%), hạn chế (70–89%), dừng (≥90%).', 'Tuần không vào mốc; tuần ≥90% thì có cảnh báo ⚠: báo chủ dự án trước khi giao cho agent đó.')
    Examples = @('crew limits')
  }
  @{
    Name = 'check'; Group = 'Giao việc'; Syntax = 'crew check <task> [-Path .] [-NoTest]'; Short = 'kiểm phạm vi, cú pháp và test task'
    Details = @('Đọc task trong project -Path và so diff với danh sách Được sửa của prompt.', 'Kiểm cú pháp PowerShell và chạy test phần thay đổi; trả lỗi khi có kiểm tra không đạt.', '-NoTest: chỉ kiểm phạm vi và cú pháp, mục test in bỏ qua, exit theo 2 mục kia. Không có cờ thì vẫn chạy test.')
    Examples = @('crew check help', 'crew check help -NoTest', 'crew check help -Path D:/Projects/demo')
  }
  @{
    Name = 'review'; Group = 'Giao việc'; Syntax = 'crew review <task>[,<task2>…] [-DryRun]'; Short = 'gửi yêu cầu gộp task cho Rev'
    Details = @('Chạy trong repo crew; lấy các nhánh có commit mới và giữ đúng thứ tự task bạn đưa.', 'Cấp review: task > dòng đầu HOT > config > Gọn; nhiều task lấy cấp cao nhất.', '-DryRun chỉ in tin; bình thường gửi một dòng giao merge/test/dọn tới <repo>-rev.', 'Rev có tin kẹt ở ô nhập ⇒ không gửi, exit 1: sang pane Rev, Enter để gửi hoặc xóa chữ, rồi chạy lại.')
    Examples = @('crew review help -DryRun', 'crew review repair,help')
  }
  @{
    Name = 'send'; Group = 'Giao việc'; Syntax = 'crew send <terminal> "<tin>" [-Raw]'; Short = 'gửi tin/lệnh tới terminal; agent bận ⇒ báo tin nằm chờ'
    Details = @('Gửi một dòng tới terminal; tự Enter nếu tin còn kẹt ở ô nhập và trạng thái cho phép.', 'Shell, lệnh /… và -Raw gửi trần; tin thông thường giữ metadata người gửi.', 'Không Enter khi blocked, dead hoặc gặp hộp thoại lạ; xử lý trạng thái terminal trước.', 'Agent đang bận (working): Claude ⇒ tin nằm chờ, agent đọc khi xong lượt. Codex ⇒ tin còn ở ô nhập thì crew bấm Tab đưa vào hàng đợi của Codex; không xác nhận được thì báo tin có thể nằm lại ô nhập. Vẫn exit 0, xem: crew hot.', 'Pane có tin kẹt ở ô nhập ⇒ không gửi chồng, in tin đang kẹt, exit 1: sang đúng pane đó, Enter để gửi hoặc xóa chữ, rồi gửi lại.')
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
    Details = @('Không có topic: hiện lệnh dùng hằng ngày và khi cần; crew help agent liệt kê lệnh planner, Rev dùng.', 'Có tên lệnh: hiện cú pháp, hành vi và ví dụ; topic lạ hiện danh sách và trả exit 1.', 'Gọi script trực tiếp: pwsh -File <Crewline>/scripts/help.ps1 [-Topic <lệnh>].')
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
if ($Topic -eq 'agent') {
  Write-Output 'Đây là lệnh planner, Rev dùng; người dùng thường không cần gõ.'
  foreach ($group in @(
    @{ Title = 'Giao việc'; Names = @('task', 'limits', 'send') },
    @{ Title = 'Kiểm và gộp'; Names = @('check', 'review', 'clean') },
    @{ Title = 'Chẩn đoán, phát hành'; Names = @('repair', 'selfcheck') }
  )) {
    Write-Output ''
    Write-Output $group.Title
    foreach ($name in $group.Names) {
      $entry = $commands | Where-Object { $_.Name -eq $name } | Select-Object -First 1
      Write-Output ('  {0,-16} {1}' -f "crew $name", $entry.Short)
    }
  }
  exit 0
}
Write-Output @'
Crewline — đội agent làm việc song song trong herdr

Dùng hằng ngày
  crew up              dựng đội, khôi phục nếu mất (project mới: hỏi tạo)
  crew up -All         như trên, cho mọi project (sau khi khởi động lại máy)
  crew status          đội đang làm gì

Rồi sang tab planner và nói việc muốn làm.

Khi cần
  crew up -Restart <vai>   bật lại agent (sau khi đổi agent hoặc quyền)
  crew setup               đổi đội mặc định cho project mới
  crew doctor              máy có thiếu gì không
  crew upgrade             cập nhật khung context của project
  crew init                tạo project với tùy chọn riêng (tên, đội)

Chi tiết: crew help <lệnh>   ·   Lệnh agent dùng: crew help agent
'@
if ($Topic) { Write-Output "không có lệnh '$Topic'"; exit 1 }
exit 0
