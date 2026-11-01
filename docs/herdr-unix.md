# herdr-app + hc trên Linux/macOS: những chỗ khác

Crewline dùng chung một bộ code pwsh 7 cho cả ba hệ; chỗ khác hệ gom về `scripts/platform.ps1`.
Trang này ghi khác biệt đã biết so với Windows ([`herdr-windows.md`](herdr-windows.md)) và phần **chưa kiểm** trên máy thật.

## Đã biết (theo tài liệu herdr + code Crewline)
- **Cài:** `curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh`. Thiếu `pwsh` thì bootstrap tải PowerShell 7 vào `~/.local` (không sudo). herdr-app + hc cài bằng `curl -fsSL https://releases.herdr.dev/app/install.sh | sh`, chỉ chạy khi chọn "Cài giúp".
- **Template hc:** `~/.config/herdr-core/templates` (hoặc `$XDG_CONFIG_HOME/herdr-core/templates`), đúng như tài liệu hc. Windows thì ở `%APPDATA%\herdr-core\templates`. `crew doctor` kiểm đúng thư mục theo hệ (`Get-HcTemplateDir`).
- **Shim + PATH:** shim là `~/.local/bin/crew` (script `#!/usr/bin/env pwsh`), không có `crew.ps1` hay shim Git Bash. `install.ps1` thêm dòng `export PATH="$HOME/.local/bin:$PATH" # crewline` vào `~/.profile`, cùng `~/.zshrc` (macOS) hoặc `~/.bashrc` (Linux, nếu có). Mở terminal mới (hoặc `. ~/.profile`) để có lệnh `crew`.
- **PS 5.1:** không có trên Unix. Chốt chặn "gọi từ PS 5.1 thì chuyển sang pwsh" và các bước PS 5.1 của `crew selfcheck` chỉ chạy trên Windows.
- **Bật agent:** cùng một đường như Windows — `hc run ... -- pwsh -NoLogo -NoExit -EncodedCommand <base64>`; pwsh tìm `claude`/`codex` trên PATH (Unix không có npm shim `.cmd`, nên không gặp `spawn_failed` như Windows). Codex vẫn chỉ một `--no-daemon`.
- **Mac Intel:** herdr-app không có bản dựng sẵn ⇒ `crew doctor` báo thiếu herdr-app + hc kèm link build từ mã nguồn; không chặn cài crew.
- **jq:** không tự tải trên Unix; cài bằng trình quản lý gói nếu cần (không bắt buộc).

## Chưa kiểm (cần máy có giao diện: Linux VM/WSLg, Mac Apple Silicon)
- `crew up` thật: herdr-app nhận `herdr.space`/`herdr.tab`, thứ tự tab/pane, `tab.move` — **chưa kiểm** trên Linux/macOS.
- `HC_TERMINAL_ID`/`HC_TERMINAL_SOCKET` trong pane, `hc send` bọc `<hc from=...>`, gửi trần — **chưa kiểm**.
- PATH trong pane herdr ngay sau cài (pane có đọc `~/.profile`/`~/.zshrc` không) — **chưa kiểm**.
- `crew task` (`/clear`, `/new`), `crew limits` đọc màn hình, `crew repair` với agent thật — **chưa kiểm**.
- Bootstrap trên máy trắng (không có pwsh) — **chưa kiểm** ngoài test giả lập.

CI (`.github/workflows/test.yml`) chạy cú pháp + Pester trên Ubuntu mỗi push/PR và macOS khi chạy tay; CI không có herdr nên không thay cho smoke thật.
