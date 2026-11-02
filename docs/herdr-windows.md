# herdr-app + hc trên Windows: những chỗ khác

Kiểm thực tế với herdr-app và hc 0.1.15 trên Windows 10 LTSC (ngày 2026-10-31).

## Hai chương trình, không có lệnh `herdr`
- `herdr-app.exe`: cửa sổ, gồm space, tab, pane và layout. Điều khiển bằng `herdr-app do <lệnh>`, `herdr-app ls`, `herdr-app commands`.
- `hc.exe` (herdr-core): chạy và giữ terminal hay agent. Dùng `hc run / send / keys / read / wait / get / ls / kill`.
- Bản herdr cũ (TUI trên Linux) có `herdr` và `HERDR_ENV=1`. Bản này **không có** cả hai. Trong pane có `HC_TERMINAL_ID` (ví dụ `t2`) và `HC_TERMINAL_SOCKET`.

## Template hc
- Tài liệu ghi `~/.config/herdr-core/templates`, nhưng trên Windows hc đọc ở **`%APPDATA%\herdr-core\templates`**.
- Frontmatter gồm `name`, `description`, `command`. Phần thân cộng với task được gửi làm tin nhắn đầu tiên.

## Bật agent
- hc không chạy thẳng `codex` (npm shim `.cmd`/`.ps1`), sẽ báo `spawn_failed`. Dùng `codex.cmd`, hoặc chạy qua `pwsh`.
- crew bật mọi agent bằng `pwsh -NoLogo -NoExit -EncodedCommand <base64 UTF-16>`, nên prompt tiếng Việt không bị lỗi mã hóa và pane còn lại một shell khi agent thoát.
- Prompt đầu tiên được truyền qua tham số dòng lệnh (`claude "<dòng>"`, `codex ... "<dòng>"`), nên không bị mất khi agent còn đang khởi động hay đang hiện hộp trust.

## Worker giữ phiên
- Trước đây mỗi task dùng một worktree khác, phải tắt agent rồi bật lại vì cwd của agent chốt lúc bật.
- Giờ mỗi worker có bàn cố định `.crew/worktrees/w<N>`: mỗi task tạo nhánh `crew/<tên>` mới từ main trên bàn đó, giữ agent chạy giữa các task. `crew clean` về main và xóa nhánh, giữ agent + thư mục.
- `crew task` tự `/clear` cho Claude hoặc `/new` cho Codex trước khi gửi prompt. Codex cần chờ phiên mới sau `/new`; crew tự chờ, không gửi tay thêm.
- Đổi model/thinking bằng `/model` ngay trong pane, giữ qua các task. Đổi agent/quyền dùng `crew up -Restart <w1|…|planner|rev|all>`.

## Gắn terminal vào cửa sổ
- `hc run --label herdr.space=<id> --label herdr.tab=<id>`: id lạ thì herdr tạo space hoặc tab mới và **giữ đúng id đó**. crew dùng `spcrew<repo>` và `tbcrew<repo>planner|workersN|rev`.
- Terminal thứ hai cùng `herdr.tab` sẽ tự chia pane trong tab đó.
- Tab mới được chèn **sau tab đang active**, nên crew sắp lại bằng `herdr-app do tab.move --id <id> --index <n>`, với `index` đếm **từ 1**.
- Phải đợi herdr-app nhận terminal (`herdr-app ls`) rồi mới bật terminal kế tiếp, nếu không thứ tự pane sẽ bị đảo.
- Dùng `--no-parent --outlive-parent --keep` để agent không chết theo agent đã bật nó.
- `space.close --confirmed true` sẽ kill mọi terminal trong space.

## Sau khi khởi động lại máy
- Agent không sống qua reboot. Terminal có `--keep` được core tạo lại đúng tên và địa chỉ, nhưng chỉ là shell trống và không bao giờ chạy lại lệnh cũ. Trong `hc get`, `argv` không còn `-EncodedCommand` của crew. `crew up` mở lại hội thoại cũ theo mục bên dưới.
- `crew up -All` khôi phục mọi project trong sổ `~/.crewline/projects.json`, cộng project đang đứng nếu đã init mà chưa có trong sổ. Mỗi project chạy một tiến trình riêng, cuối lệnh có bảng kết quả (ok, cần người quyết, lỗi, bỏ qua); có lỗi hoặc cần người quyết thì exit 1. Xem trước: `crew up -All -DryRun`.
- Chỉ một project: `crew up`. Lệnh nhận ra các pane này, tắt rồi bật lại agent, giao lại task dở; chạy lại khi đã ổn thì không gửi gì thêm. Project cũ được ghi tên vào config và sổ, tên terminal và space/tab giữ nguyên.
- Crew chỉ nhận shell mất agent khi đủ 3 dấu hiệu: không có `status.app`/trạng thái blocked (foreground nếu có phải là shell); `argv[0]` là `pwsh`/`powershell`, có marker `__hc_prompt` của core và không có `-EncodedCommand`; dòng cuối màn hình là `PS ...>`. Ô nhập `❯` của Claude không phải dấu nhắc shell. Ngay trước khi tắt, crew đọc lại `hc get`, xác minh cwd thuộc project, tên/địa chỉ không đổi và vẫn đủ dấu hiệu shell trống; thiếu dữ liệu hoặc lỗi thì giữ pane và cảnh báo.
- Linux/macOS chưa xác minh nên crew không tự tắt shell trên các hệ này; dùng `crew up -Restart all`. Prompt shell tùy biến không khớp cũng cần bật lại bằng lệnh này.
- `hc ls --json` bỏ hẳn khóa `name` với terminal chưa đặt tên, là mọi pane tự mở trong herdr. Crew coi đó là `name = null`.

## Mở lại hội thoại
`crew up` và `crew up -All` mở lại hội thoại khi pane là shell trống sau reboot, hoặc terminal thiếu mà không có `-Restart`. `crew up -Restart` và lần dựng đầu luôn là hội thoại mới. `crew up` in từng vai "mở lại hội thoại" hay "hội thoại mới" kèm lý do; `-DryRun` chỉ báo, không ghi sổ.

| Vai | Claude | Codex |
|---|---|---|
| Worker (mỗi worker một thư mục, đổi phiên khi `/clear`, `/new`) | `--continue` | `resume --last` |
| Planner, Rev (cùng ở thư mục gốc) | `--session-id <uuid>` lúc bật, `--resume <uuid>` khi mở lại | `resume --last` khi chỉ có một vai Codex ở gốc; hai vai thì hội thoại mới và cảnh báo |

- Sổ `.crew/sessions.json` (không commit) chỉ ghi vai, loại agent, root và UUID do crew tạo; crew không đọc file sessions/history của agent. Chưa có ghi nhận, đổi agent, đổi root hoặc sổ hỏng thì mở hội thoại mới. Project bật trước khi có sổ cũng chưa có ghi nhận, nên lần khôi phục đầu là hội thoại mới.
- Lệnh mở lại không kèm prompt nên agent không tự chạy và không tốn token. Worker có task dở nhận đúng một dòng "Tiếp tục task" sau khi sẵn sàng.
- Claude không tìm thấy phiên thì thoát (`No conversation found…`), pane về shell: crew bật hội thoại mới một lần và cảnh báo nêu tên vai. Codex không báo lỗi mà mở phiên trống (`Context 100% left`): crew cảnh báo là hội thoại mới.
- Phiên mở lại chưa có lượt mới thì `hc` có thể chưa báo `status.app`; crew nhận agent theo chân màn hình (`accept edits on`/`bypass permissions on`, `Context N% left`).
- Claude bật từ bên trong phiên Claude khác (có `CLAUDE_CODE_CHILD_SESSION`) không lưu transcript nên không mở lại được. Lệnh bật pane của crew xóa các biến phiên này trước.
- `resume --last` và `--continue` lấy phiên mới nhất của thư mục: phiên bạn tự mở tay ở cùng thư mục sẽ được chọn thay phiên của crew.

## Trạng thái và hộp thoại
- `hc wait` ngay sau khi duyệt có thể trả trạng thái `blocked` cũ. Đọc lại bằng `hc get` hoặc `hc read`.
- Hộp duyệt lệnh của Claude, khi màn hình đang cuộn ("Jump to bottom"), không nhận phím `1`. Bấm `ctrl+end` rồi `enter`.
- `hc send` từ chối khi terminal `blocked`. Đừng dùng `--force` để vượt qua một quyết định duyệt.

## Tin kẹt ở ô nhập Codex
- Đo trên hc 0.1.16, codex-cli 0.166.0 (2026-11-02): Enter của `hc send` có lúc không gửi tin đi, cả khi Codex rảnh lẫn working, và `started:true` của hc không chứng minh tin đã rời ô nhập. Khi rảnh `crew send` bấm thêm Enter như cũ. Khi working, tin nằm ở ô nhập, và xong lượt Codex không tự gửi.
- Codex working: Enter chèn tin vào lượt đang chạy, Tab đưa tin vào hàng đợi thật (`Queued follow-up inputs`, chạy khi xong lượt). Ô nhập đúng và chỉ có tin vừa gửi (đối chiếu toàn bộ, chỉ bỏ qua chỗ xuống dòng và vỏ `<hc from=…>`) thì crew đọc lại trạng thái rồi bấm Tab đúng 1 lần, vì Tab gửi cả ô. Chữ thêm, chữ sửa, bản nháp cùng đầu tin, không live, không phải Codex, hết working, blocked hoặc hộp thoại thì không bấm và báo tin có thể nằm lại ô nhập, xem `crew hot`.
- Codex rảnh mà ô nhập còn chữ là tin kẹt, kể cả chữ người dùng đang gõ dở. `crew hot` hiện `tin kẹt`; `crew send`/`crew review` không gửi chồng, in tin đang kẹt, exit 1. Crew không tự xử lý: sang đúng pane đó, Enter để gửi hoặc xóa chữ.
- Chỉ nhận khi cuối màn hình đúng khung `› chữ`, dòng trống, chân `GPT-…` hoặc `Context N% left`. Chân bị cắt ở pane hẹp vẫn nhận theo `GPT-…`. Không chắc thì coi như không kẹt. Claude không báo tin kẹt: hc không phân biệt được gợi ý mờ với chữ thật, và Claude tự đọc tin khi xong lượt.
- `crew task`/`crew repair` chưa chặn tin kẹt.
- Hộp thoại: cuối màn hình đúng là ô nhập thường thì chữ phía trên là lịch sử, kể cả `Allow command`. Không xác định chắc ô nhập thì vẫn quét cả màn hình và coi là hộp thoại, không bấm.

## Khác
- Máy LTSC không có winget, nên jq được tải thẳng từ GitHub vào `~/.local/bin`.
- Git Bash và PowerShell đều cần lệnh `crew`. install.ps1 tạo cả `crew.ps1` lẫn shim bash `crew`.

## Linux/macOS
Khác biệt trên Linux/macOS (template ở `~/.config/herdr-core/templates`, shim `~/.local/bin/crew`, PATH qua `~/.profile`) và phần chưa kiểm: xem [`herdr-unix.md`](herdr-unix.md).
