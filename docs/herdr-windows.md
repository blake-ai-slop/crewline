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

## Trạng thái và hộp thoại
- `hc wait` ngay sau khi duyệt có thể trả trạng thái `blocked` cũ. Đọc lại bằng `hc get` hoặc `hc read`.
- Hộp duyệt lệnh của Claude, khi màn hình đang cuộn ("Jump to bottom"), không nhận phím `1`. Bấm `ctrl+end` rồi `enter`.
- `hc send` từ chối khi terminal `blocked`. Đừng dùng `--force` để vượt qua một quyết định duyệt.

## Khác
- Máy LTSC không có winget, nên jq được tải thẳng từ GitHub vào `~/.local/bin`.
- Git Bash và PowerShell đều cần lệnh `crew`. install.ps1 tạo cả `crew.ps1` lẫn shim bash `crew`.

## Linux/macOS
Khác biệt trên Linux/macOS (template ở `~/.config/herdr-core/templates`, shim `~/.local/bin/crew`, PATH qua `~/.profile`) và phần chưa kiểm: xem [`herdr-unix.md`](herdr-unix.md).
