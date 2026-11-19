# Xử lý lỗi thường gặp (Troubleshooting)

Hướng dẫn cho Windows. Chạy các lệnh `crew` trong thư mục project; tên terminal có dạng `<tên crew>-planner`, `<tên crew>-w1`, `<tên crew>-rev`. Dùng `crew hot` để xem tên và trạng thái thực tế.

## Worker mới bật đang chờ trust thư mục (Folder trust)

Khi hiện `Chờ bạn bấm "trust thư mục" (crew không tự bấm)`, sang pane được liệt kê, kiểm tra đúng thư mục project rồi xác nhận: Claude dùng ↓ rồi Enter, Codex dùng Enter. Crew in phím tương ứng cho từng pane; trust một lần cho mỗi thư mục. Không gửi lại task khi hộp trust còn mở. Xem [trạng thái và hộp thoại trên Windows](herdr-windows.md#trạng-thái-và-hộp-thoại).

## Tin kẹt ở ô nhập (Stuck input)

Nếu `crew hot` hiện `tin kẹt`, hoặc `crew send` báo `có tin kẹt ở ô nhập, chưa gửi tin mới` và exit 1, sang đúng pane đó. Đọc nội dung rồi Enter để gửi hoặc xóa chữ đang có, sau đó gửi lại tin mới. `crew review` cũng chặn trường hợp này. Crew không tự gửi chồng hoặc xóa bản nháp; Codex đang working còn có cơ chế queue riêng, xem [tin kẹt ở ô nhập Codex](herdr-windows.md#tin-kẹt-ở-ô-nhập-codex).

## Gợi ý của Claude bị coi là tin kẹt (Claude prompt suggestion)

Dấu hiệu: `crew task`, `crew queue -Run` hoặc `crew repair` báo `có tin kẹt ở ô nhập` với pane Claude, nhưng không ai gõ dòng đó (vd. `❯ chạy tests rồi báo kết quả`). Đó là gợi ý câu kế tiếp, chữ mờ, của Claude Code; `hc read` không có màu nên crew không phân biệt được với chữ thật. Gõ rồi xóa thì gợi ý hiện lại, nên xóa tay không gỡ được lâu.

Cách gỡ: bật lại pane đó bằng `crew up -Restart <vai>` (vd. `crew up -Restart w1`; worker đang có task cần thêm `-Force`). Pane do bản crew mới bật đã tự tắt gợi ý bằng biến môi trường `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, chỉ trong pwsh của pane đó; crew không sửa `~/.claude/settings.json`. Crew không tự xóa hoặc ghi đè ô nhập.

## Git chưa có tên hoặc email (Missing Git identity)

Crew hỏi các trường còn thiếu trước khi cần commit và lưu vào cấu hình Git toàn máy. Nếu thấy `git chưa có tên/email để commit và không có người để hỏi`, hoặc `chưa có tên/email (bỏ trống hai lần)`, đặt thông tin rồi chạy lại lệnh vừa dừng:

```powershell
git config --global user.name "Tên của bạn"
git config --global user.email "ban@example.com"
```

Thay hai giá trị mẫu bằng danh tính muốn ghi vào commit. Khi `crew up` khôi phục project đã init mà không có người để hỏi, crew có thể chỉ cảnh báo và chạy tiếp; agent vẫn cần danh tính để commit. `-DryRun` không hỏi và không ghi danh tính.

## Upgrade tạo file .new (Manual upgrade merge)

Thông báo `đã sửa tay — bản mới ở ...new` nghĩa là Crewline giữ bản bạn đã sửa và đặt bản mẫu mới cạnh nó. Chạy lệnh `git diff --no-index -- <file> <file>.new` mà phần tóm tắt in ra, từ thư mục gốc project. Ví dụ:

```powershell
git diff --no-index -- 'context/roles/worker.md' 'context/roles/worker.md.new'
```

Git trả mã 1 khi hai file khác nhau. Đọc diff, gộp phần cần dùng vào file gốc rồi xóa `.new`; chuyển quy tắc riêng sang `context/roles/<vai>.local.md` để upgrade giữ nguyên chúng. Với `crew upgrade -DryRun`, file `.new` sẽ có sau khi chạy thật. Nếu báo `context/ có thay đổi chưa commit`, commit việc đang làm trước rồi chạy lại upgrade. Xem [hướng dẫn nâng cấp](upgrade.md).

## Tên crew trùng (Crew name conflict)

Crew dừng trước mọi kill/bật/gửi khi tên crew, khóa id herdr (`spcrew<khóa>`) hoặc terminal `<tên>-…` đã thuộc một project khác còn tồn tại; thường do chép nguyên thư mục project hoặc hai project cùng tên thư mục. Đặt tên riêng cho project đang bị chặn, chạy trong thư mục của nó:

```powershell
crew init -Name <tên-khác>
```

Tên chỉ gồm a-z 0-9 `-`, 1–12 ký tự; lệnh sinh idKey mới và ghi sổ `~/.crewline/projects.json`. Cũng có thể sửa `"name"`/`"idKey"` trong `.crew/config.json`. Project cũ đã xóa thư mục thì không còn tính là trùng. Sau đó chạy lại `crew up`.

## Queue giữ task vì limit (Queue limit hold)

Chạy `crew queue` để xem cột `đang giữ (lần chạy gần nhất)`, và `crew limits` để kiểm limit. Theo % 5 giờ đã dùng: 70–89% giữ task size L (`hạn chế, không giao size L`), từ 90% giữ mọi task mới (`dừng`). Task S/M vẫn có thể được giao ở mức 70–89%; % tuần không tự chặn queue.

Đợi limit giảm hoặc dùng worker có loại agent còn limit phù hợp, rồi chạy `crew queue -Run` để thử giao lại. Queue cũng tự thử sau `crew up` hoặc `crew clean`. Đọc lý do giữ thực tế vì task còn có thể đang chờ phụ thuộc, worker rảnh hoặc phạm vi file hết trùng.

## Terminal bị báo thiếu (Missing terminal)

Trong pane herdr-app tại project, chạy `crew up` để bật lại vai thiếu và tiếp tục task dở khi phù hợp. Muốn xem chẩn đoán trước, chạy:

```powershell
crew repair -DryRun
```

Nếu có mục `CẦN NGƯỜI QUYẾT`, xử lý nguyên nhân được in rồi chạy lại `crew up`. Sau reboot, `crew up -All` khôi phục các project trong sổ. Gõ `crew up` ngay trong shell trống của một vai trên Windows có thể làm pane chuyển thành agent sau vài giây; xem [self-pane và log](herdr-windows.md#gõ-crew-up-ngay-trong-pane-shell-trống-của-một-vai) nếu pane chưa chuyển.
