# Changelog

Mới nhất ở trên. Cập nhật Crewline: chạy lại lệnh cài 1 dòng, rồi `crew upgrade` trong từng project.

## 2026-10-31

### Mới
- **`crew repair [-DryRun]`:** lỡ đóng pane planner/worker/Rev hoặc cả space trên herdr thì chạy lệnh này — chẩn đoán terminal, bàn worker `w<N>`, task; sửa phần an toàn (prune worktree hỏng, tạo lại `w<N>`, bật terminal thiếu); worker vừa bật lại mà có task dở thì được gửi lệnh "tiếp tục". Không bao giờ xóa nhánh, thay đổi chưa commit hay bản ghi task. Code và context nằm trên đĩa + git nên không mất.
- **`crew help [lệnh]`:** "Bắt đầu nhanh", mọi lệnh theo nhóm, mẹo (đổi model bằng `/model`, `-Restart`, `repair`); `crew help <lệnh>` có cú pháp, cờ, ví dụ.
- **Worker giữ phiên agent:** mỗi worker có một "bàn" cố định `.crew/worktrees/w<N>`; agent bật một lần và không tắt giữa các task (`crew task` tự `/clear` hoặc `/new` rồi giao việc trên nhánh mới từ main; `crew clean` giữ agent). Muốn đổi model/thinking: vào pane gõ `/model`, task sau vẫn giữ. Đổi agent/quyền: `crew up -Restart <w1|…|planner|rev|all>`.
- **Lệnh mới cho planner:** `crew send <terminal> "<tin>"` (gửi an toàn: tự Enter khi tin kẹt ở ô nhập, không bao giờ Enter khi agent đang chờ duyệt, gửi được vào shell), `crew review <task,…>` (soạn + giao Rev một lệnh), `crew task … -Review fast` (làn nhanh cho task nhỏ), `crew check <task>` (diff so với "Được sửa", parse pwsh + PS 5.1, chạy test phần đó), `crew selfcheck` (cài thử vào HOME giả, gọi bằng PS 5.1, init + upgrade, cả đường dẫn có dấu — chạy trước mỗi lần push).
- **`crew limits` — cân việc theo limit:** đọc một lần % limit 5h/tuần đã dùng của từng pane (Codex luôn hiện; Claude cần status line riêng của bạn). Limit tính theo tài khoản agent, pane bị cắt chữ thì mượn số pane cùng agent. Planner chia theo 3 cấp: 50% theo dõi · 70% hạn chế task lớn · 90% dừng (chỉ giao khi bạn nói rõ). Project cũ nhận quy tắc mới bằng `crew upgrade`.
- **README có mục "Cách crew chia việc":** mỗi task một git worktree + nhánh riêng, chia đều theo số worker, Rev merge, `crew clean` dọn.
- **Lệnh cài kiểm phần mềm cần thiết:** in bảng Bắt buộc (git, pwsh, herdr-app + hc) / Theo đội (claude, codex theo đội bạn chọn), mục thiếu có link tải hoặc lệnh cài. Agent cài được bằng npm/winget thì hỏi `1. Bỏ qua` (mặc định) / `2. Cài giúp` — chỉ cài khi bạn chọn 2. Thiếu herdr thì báo rõ "CHƯA dùng được" + https://herdr.dev/. `crew doctor` dùng cùng bảng.
- **`crew init` trong thư mục chưa có git** sẽ hỏi tạo repo mới (git init + commit đầu) thay vì báo lỗi; vẫn dùng được `-GitInit`.
- **`crew setup` dễ nhìn hơn:** mỗi câu là danh sách đánh số, mỗi lựa chọn một dòng kèm mô tả, mặc định hiện trong `Lựa chọn [1]:`, Enter để chọn; nhập sai thì hỏi lại; cuối có bảng tóm tắt. Vẫn gõ tên (vd `codex`) được.
- **Chọn đội lúc cài — `crew setup`.** Cài lần đầu sẽ hỏi: mẫu đội (standard / solo / large / custom); custom thì chọn planner, số worker (1–6) và agent từng worker, Rev; cuối cùng chọn cấp review và quyền agent. Tự dò máy có `claude`/`codex` để gợi ý mặc định. Đổi lại bất cứ lúc nào bằng `crew setup`. Cài không hỏi: `$env:CREWLINE_DEFAULTS=1`.
- **Đội tùy chỉnh trong config cá nhân** `~/.crewline/config.json`: thêm `planner`, `workers`, `rev` bên cạnh `team`, `review`, `access`. Mẫu đội nằm ở một chỗ: `scripts/teams.json`.
- **Cài bằng 1 dòng:** `irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex` — clone (hoặc pull) vào `~/Crewline` rồi chạy `install.ps1`. Chạy được cả trên Windows PowerShell 5.1.
- **`crew upgrade`:** cập nhật `roles/`, `context/README.md`, PITFALLS chung và khối crew trong CLAUDE.md/AGENTS.md của project cũ từ skeleton mới; không đụng PROJECT/HOT/DECISIONS/tasks. Có `-DryRun`, sao lưu file trước khi ghi đè. Xem `docs/upgrade.md`.

### Sửa
- **Hộp "trust thư mục" lần đầu:** ở project mới, mỗi agent hỏi trust thư mục và đứng chờ. `crew up` nay liệt kê đúng pane nào đang chờ kèm phím cần bấm (Claude: ↓ rồi Enter; Codex: Enter); `crew hot` hiện `chờ trust`. Crew không bao giờ tự bấm hộp này.
- **`crew repair` khôi phục cả Rev:** Rev bị đóng giữa lúc review thì repair bật lại và giao lại đúng lệnh review còn dở (`crew review` nay ghi lại lúc đã giao). Repo chính đang merge/rebase dở thì repair báo rõ và nhắc Rev xử lý tiếp; không bao giờ tự hủy merge.
- `crew repair -DryRun` nay báo cả việc sẽ giao lại task dở và sẽ chép lại prompt (trước đây chỉ báo bật terminal thiếu). `crew repair` đã thử với agent thật: đóng pane Codex giữa task, repair bật lại và agent làm tiếp đúng phần còn lại.
- Worker giữ phiên: `/clear` (Claude) và `/new` (Codex) trước đây tới agent như câu chat nên không xóa context; nay lệnh slash gửi trần, hộp chọn worktree của Codex `/new` được chọn tự động — chỉ khi đúng hộp đó và không có hộp nào khác trên màn hình (hộp duyệt quyền thì dừng, không bấm). Đã thử với Claude và Codex thật.
- `crew check` báo nhầm "ngoài phạm vi" khi đường dẫn được phép nằm trong ngoặc ở dòng "Được sửa".
- `crew review a,b` gõ từ PowerShell (không ngoặc) bị lỗi và không gửi gì; nay nhận `a,b`, `"a,b"`, `a, b` từ PowerShell lẫn Git Bash. Lệnh chỉ nhận 1 tên (`task`, `clean`, `check`, `send`) báo lỗi rõ nếu truyền 2 tên.
- `crew upgrade` không tự commit được khi project có file sao lưu `.bak-*` bị ignore; nay file `.bak` chỉ để trên máy (không commit), `init`/`upgrade` tự thêm `*.bak-*` vào `.gitignore`.
- Gõ `crew` từ Windows PowerShell 5.1 bị lỗi `NativeCommandError`; nay shim và `crew.ps1` tự chuyển sang pwsh 7 (kể cả khi repo nằm ở đường dẫn có dấu). Cần chạy lại lệnh cài để nhận shim mới.
- Planner bật bằng `crew up` giờ nhận quyền theo `access` (trước đây chỉ worker và Rev nhận); dựng lệnh agent dùng chung một hàm.
- `crew task` lần thứ 2 lỗi `op_Addition` và không ghi task vào `.crew/tasks.json`.
- `crew clean` bỏ qua lỗi git mà vẫn báo đã dọn; nay báo đúng bước lỗi, giữ bản ghi để chạy lại, cảnh báo thư mục worktree bị khóa.
- `install.ps1` không ghi cứng đường dẫn, chạy lại an toàn.

### Khác
- **Repo public chỉ còn phần sản phẩm:** bỏ context nội bộ của việc phát triển Crewline, lịch sử làm lại từ đầu. Ai đã cài trước đó mà lệnh cài 1 dòng báo `git pull --ff-only that bai` thì xóa thư mục `~/Crewline` rồi chạy lại lệnh cài (cấu hình `~/.crewline` và các project không bị ảnh hưởng).
- **Role v4 (`crew upgrade` để nhận):** planner dùng `crew send`/`review`/`check`/`selfcheck`, gửi worker sửa tiếp trước khi giao Rev, làn nhanh cho việc nhỏ, push chỉ khi bạn cho phép (kèm selfcheck + CHANGELOG), đóng đợt bằng mục "Tiếp theo" trong HOT để planner mới tiếp quản; HOT bỏ "Đang làm" (`crew hot` là nguồn); MAP vào thứ tự đọc; Rev chỉ nâng Gọn→Đủ khi chạm vùng nhạy cảm, đổi hợp đồng giữa nhánh cùng đợt, hoặc gặp P0/P1; Rev dọn `archive/` khi PROGRESS/PITFALLS gần trần.
- Khối crew trong CLAUDE.md/AGENTS.md: "chỉ planner push khi chủ dự án cho phép" + dòng MAP. `crew upgrade -DryRun` báo trước cả việc thêm `*.bak-*` vào `.gitignore`.
- `context/MAP.md`: bản đồ code để worker mới tìm đúng file nhanh, đỡ phải dò cả repo.
- Bộ test Pester (chạy trên Pester 3.4 có sẵn trong Windows), luôn trên HOME/APPDATA giả.
