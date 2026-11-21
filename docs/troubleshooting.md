# Xử lý lỗi thường gặp (Troubleshooting)

Hướng dẫn cho Windows. Chạy các lệnh `crew` trong thư mục project; tên terminal có dạng `<tên crew>-planner`, `<tên crew>-w1`, `<tên crew>-rev`. Dùng `crew hot` để xem tên và trạng thái thực tế.

## Defender/antivirus chặn lệnh cài

Nếu Defender hoặc antivirus chặn lệnh cài một dòng, dùng cách cài khác trong PowerShell:

```powershell
git clone https://github.com/blake-ai-slop/crewline.git "$HOME/Crewline"
pwsh -NoProfile -File "$HOME/Crewline/install.ps1"
```

Đây là cùng repo, thư mục và installer mà bootstrap sử dụng. Nếu đã clone vào `~/Crewline`, chạy `git -C "$HOME/Crewline" pull --ff-only` rồi chạy lại dòng `pwsh`. Xem [Cách cài khác](../README.md#cách-cài-khác).

## Worker mới bật đang chờ trust thư mục (Folder trust)

Khi hiện `Chờ bạn bấm "trust thư mục" (crew không tự bấm)`, sang pane được liệt kê, kiểm tra đúng thư mục project rồi xác nhận: Claude dùng ↓ rồi Enter, Codex dùng Enter. Crew in phím tương ứng cho từng pane; trust một lần cho mỗi thư mục. Không gửi lại task khi hộp trust còn mở. Xem [trạng thái và hộp thoại trên Windows](herdr-windows.md#trạng-thái-và-hộp-thoại).

## Tin kẹt ở ô nhập (Stuck input)

Nếu `crew hot` hiện `tin kẹt`, hoặc `crew send` báo `có tin kẹt ở ô nhập, chưa gửi tin mới` và exit 1, sang đúng pane đó. Đọc nội dung rồi Enter để gửi hoặc xóa chữ đang có, sau đó gửi lại tin mới. `crew review` cũng chặn trường hợp này. Crew không tự gửi chồng hoặc xóa bản nháp; Codex đang working còn có cơ chế queue riêng, xem [tin kẹt ở ô nhập Codex](herdr-windows.md#tin-kẹt-ở-ô-nhập-codex).

## Crew không chắc tin đã vào ô nhập (Unsure send, crew confirm)

Dấu hiệu: `crew send`/`crew review` báo `không nhận ra ô nhập để kiểm tin`, `agent chưa chạy` hoặc review "chưa chắc Rev đã nhận". Crew không bấm Enter khi không chắc, vì Enter có thể trả lời hộ một hộp thoại. Xem màn hình: `hc read <terminal> --lines 20`. Tin nằm đúng ô nhập, agent rảnh, không có hộp thoại ⇒ `crew confirm <terminal>`: crew đọc màn hình 1 lần và bấm Enter đúng 1 lần; với Rev còn ghi review đã gửi (như `crew review <task> -Sent`). Có hộp thoại/ô trống ⇒ crew confirm từ chối, không bấm phím.

Thường gặp sau khi Claude Code/Codex cập nhật giao diện. Kiểm bản đang cài: `crew probe claude` hoặc `crew probe codex` mở một terminal tạm, thử các bước crew dùng (phiên mới, gõ tin + kiểm ô nhập + Enter, chờ xong lượt, `/clear`/`/new`), in bảng đạt/hụt và lưu màn hình ở `~/.crewline/probe/`. Có hụt ⇒ cập nhật Crewline; trong lúc chờ dùng `crew confirm`.

Planner hỗ trợ (`"assist"` trong `.crew/config.json`: `"ask"` mặc định, `"auto"`, `"off"`): khi crew không chắc, nó không bấm phím mà in khối `CẦN PLANNER XEM` gồm 20–40 dòng màn hình, agent + phiên bản, lý do và lệnh `crew confirm <terminal>`. Planner đọc khối đó: tin nằm đúng ô nhập, agent rảnh, không hộp thoại ⇒ `crew confirm <terminal>` (Enter 1 lần); khác (hộp xin duyệt, hộp lạ, ô còn chữ khác) ⇒ bạn xử lý trong pane rồi gửi lại. Ở `ask` planner hỏi bạn trước khi chạy; ở `auto` planner tự chạy rồi báo bạn 1 dòng; `off` như cũ (không khối).

Crew không học hay ghi nhớ kiểu màn hình nào: mọi nhận diện màn hình là ghi cứng trong code, bản agent mới chỉ được hỗ trợ khi cập nhật Crewline. Nhật ký: `.crew/assist.log` (shown/confirmed); `crew status` in số lần planner hỗ trợ hôm nay. Crew không tự gửi màn hình đi đâu — muốn Crewline hỗ trợ bản mới, bạn tự gửi màn hình mẫu.

## Gợi ý của Claude bị coi là tin kẹt (Claude prompt suggestion)

Dấu hiệu: `crew task`, `crew queue -Run` hoặc `crew repair` báo `có tin kẹt ở ô nhập` với pane Claude, nhưng không ai gõ dòng đó (vd. `❯ chạy tests rồi báo kết quả`). Đó là gợi ý câu kế tiếp, chữ mờ, của Claude Code; `hc read` không có màu nên chỉ đọc màn hình thì không phân biệt được với chữ thật. Gõ rồi xóa thì gợi ý hiện lại, nên xóa tay không gỡ được lâu.

Mặc định pane do crew bật tắt gợi ý bằng biến môi trường `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, chỉ trong pwsh của pane đó; crew không sửa `~/.claude/settings.json`. Pane bật trước bản này có thể còn gợi ý: bật lại bằng `crew up -Restart <vai>` (vd. `crew up -Restart w1`; worker đang có task cần thêm `-Force`).

Muốn giữ gợi ý (vd. ở planner bạn trò chuyện trực tiếp), đặt `"suggestions"` trong `.crew/config.json`: `"off"` (mặc định), `"planner"` (chỉ pane planner) hoặc `"all"`. Pane đang mở không đổi tới khi `crew up -Restart <vai>`.

Với pane Claude có chữ trong ô nhập, `crew send` và `crew task` thử bằng **một phím**: gõ đúng 1 dấu cách rồi đọc lại; crew không bao giờ bấm phím xóa. Gợi ý biến mất khi gõ dấu cách ⇒ ô thật trống, crew gửi tin bình thường (tin đứng sau dấu cách đó). Chữ còn ⇒ chữ bạn gõ, crew chặn như tin kẹt; chữ của bạn giữ nguyên, chỉ thêm 1 dấu cách ở cuối. Pane đổi trong lúc kiểm (bạn gõ tiếp, hộp duyệt hiện…) ⇒ crew dừng, không bấm thêm phím. Đây là phím duy nhất crew gõ ngoài tin của nó. `crew hot` chỉ đọc nên với pane bật gợi ý chỉ ghi `có chữ trong ô nhập (có thể là gợi ý Claude)`. Crew không tự xóa hoặc ghi đè ô nhập.

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
