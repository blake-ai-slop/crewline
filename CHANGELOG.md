# Changelog

Mới nhất ở trên. Cập nhật Crewline: chạy lại lệnh cài 1 dòng, rồi `crew upgrade` trong từng project.

## 2026-11-02

### Mới
- **`crew up` là lệnh duy nhất cần nhớ:** tự dựng đội và khôi phục khi mất. Project chưa init thì hỏi tạo ngay trong cùng lệnh; thư mục chưa có git thì hỏi rõ trước khi `git init` và commit tất cả file (mặc định Thôi). Không chạy init ở thư mục HOME hay gốc ổ đĩa.
- **`crew up -All`:** sau khi khởi động lại máy, khôi phục mọi project trong sổ.
- **Mở lại đúng hội thoại:** `crew up` và `crew up -All` mở lại hội thoại cũ của từng vai và in rõ từng vai là "mở lại hội thoại" hay "hội thoại mới". Không chắc đúng phiên thì mở hội thoại mới, không đoán. Đội đang chạy từ trước bản này chưa có sổ phiên nên lần khôi phục đầu là hội thoại mới. Worker và Codex dùng phiên mới nhất của thư mục, nên phiên bạn tự mở ở đó có thể được chọn.
- **`crew help` gọn lại:** trang chính chỉ còn lệnh người dùng cần, xếp theo việc; lệnh agent dùng chuyển sang `crew help agent`.
- **`crew status`:** đội đang làm gì. `crew hot` vẫn chạy như tên cũ.
- **Báo tin kẹt ở ô nhập Codex:** `crew status` hiện pane có tin kẹt; `crew send`/`crew review` không gửi chồng mà bảo sang pane đó bấm Enter hoặc xóa chữ. Chữ bạn đang gõ dở trong ô Codex cũng được tính là tin kẹt.
- **Tin gửi cho Codex đang chạy vào hàng đợi thật:** crew bấm Tab, chỉ khi toàn bộ ô nhập đúng là tin vừa gửi.

### Sửa
- **Sau khi khởi động lại máy:** `crew up` nhận ra pane chỉ còn shell trống và bật lại agent, đọc lại ngay trước khi tắt pane để không đụng nhầm.
- **Pane chưa đặt tên trong herdr không còn làm `crew up` báo lỗi.**
- **Chữ cũ trên màn hình** (như "Allow command" trong lịch sử) không còn bị nhận nhầm là hộp thoại khi xác định chắc được ô nhập.
- **Mẫu giao việc của planner** yêu cầu đặt tên file trong backtick ở dòng `Được sửa:`, tránh `crew check` báo nhầm ngoài phạm vi. Project cũ nhận qua `crew upgrade`.

### Chưa kiểm
- Khôi phục và mở lại hội thoại mới thử với `hc` giả, cộng thử riêng Claude/Codex thật ngoài herdr; chưa qua reboot thật. Tab vào hàng đợi: phím đã đo trên Codex thật, bản code cuối mới thử với `hc` giả. Linux/macOS chưa thử trên máy có giao diện.

## 2026-11-01

### Mới
- **`crew limits` lấy số mới trực tiếp:** hỏi thẳng Codex (`codex app-server`) và Claude (`claude -p /usage`) thay vì đọc màn hình, nên limit vừa reset là thấy ngay; bảng có thêm giờ reset 5h. Mỗi loại agent hỏi một lần. Đo trên Claude: 0 token; Codex không chạy lượt model, 3 lần gọi liền số không tăng. Không hỏi được thì đọc màn hình như cũ và ghi `màn hình, có thể cũ`. Crew không đọc file đăng nhập, không lưu phản hồi. Tạo thư mục `~/.crewline/limits-cwd`; Claude tạo thêm một thư mục rỗng trong `~/.claude/projects`. Chưa thử với CLI thật trên Linux/macOS.
- **Báo tin chờ:** `crew send`/`crew review` tới agent đang bận giờ báo rõ tin đang nằm chờ, agent đọc khi xong lượt; `crew hot` hiện `tin chờ` ở pane có tin xếp hàng. Chưa nhận ra tin kẹt ở ô nhập khi agent rảnh.
- **Mỗi project một tên crew duy nhất:** `crew init` chốt tên vào `.crew/config.json` (`crew init -Name <tên>` để tự đặt: a-z, 0-9, `-`, tối đa 12 ký tự). Hai thư mục cùng tên (vd `D:\work\app` và `E:\client\app`) không còn dùng chung terminal/space herdr: tên thứ hai tự thêm `-2`; tên tiếng Việt bỏ dấu, tên không chữ Latin thành `crew-<mã>`. Sổ `~/.crewline/projects.json` ghi tên → thư mục. `crew up`/`task`/`send`/`review`/`repair` dừng nếu terminal hoặc space cùng tên thuộc project khác (không gửi gì); `hot`/`limits` cảnh báo. Project cũ: `crew upgrade` ghi tên hiện tại vào config, không đổi tên terminal đang chạy.
- **Chép thư mục project:** bản chép mang theo `.crew/` của bản gốc ⇒ crew báo là bản chép; `crew init -Name <tên mới>` trong bản chép dọn task và bàn worker chép theo rồi tạo crew mới, bản gốc không bị đụng (nên dùng `git clone` thay vì chép).
- **Đổi tên / chuyển thư mục project:** `crew repair` tự nhận ra và sửa: `git worktree repair`, đường dẫn trong task, sổ, tắt terminal ở thư mục cũ, đóng space cũ (chỉ khi space đó chỉ còn terminal của crew), bật lại và giao lại task dở. Lỗi ở bất kỳ bước nào ⇒ dừng, không đóng/bật gì, báo bạn quyết. `up`/`task`/`send`/`hot` gặp project đã chuyển thì in một dòng gợi ý `crew repair`.
- **`crew hot` có khối "Cảnh báo":** main có thay đổi chưa commit hoặc merge dở, bàn `w<N>` bẩn mà không có task, agent lạ chạy ở thư mục project (có thể có planner thứ hai), project là bản chép.
- **Linux và macOS (thử nghiệm):** cài 1 dòng `curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh` — tự cài pwsh 7 vào `~/.local` nếu thiếu (không cần sudo), clone vào `~/Crewline` rồi chạy `install.ps1`. Template hc vào `~/.config/herdr-core/templates`, lệnh `crew` vào `~/.local/bin`, PATH thêm vào `~/.profile` (macOS thêm `~/.zshrc`). Bảng kiểm phần mềm gợi ý brew (macOS) / apt-dnf (Linux, không tự chạy sudo); herdr cài bằng lệnh chính thức chỉ khi bạn chọn "Cài giúp". Mac Intel chưa có herdr-app. Windows không đổi: vẫn `irm … | iex`. Chưa thử với herdr-app thật trên Linux/macOS — xem `docs/herdr-unix.md`.
- **CI GitHub Actions:** test tự chạy trên Windows + Linux mỗi lần push; macOS chạy tay (`workflow_dispatch`) hoặc khi phát hành. Đã xanh cả 3 hệ (Windows 340 test; Ubuntu/macOS 330, bỏ qua 6 test chỉ dành cho Windows).

### Sửa
- **`crew limits` chỉ xếp mốc theo limit 5h:** limit tuần dài hơn nên không còn đẩy mốc lên `theo dõi`/`hạn chế`/`dừng`; tuần dùng ≥90% thì hiện `⚠` kèm nhắc báo chủ dự án trước khi giao cho agent đó (không tự chặn). Project cũ nhận quy tắc mới cho planner bằng `crew upgrade`.
- **`crew check` báo sai khi máy có Pester 4/5:** trước đây đọc dòng tổng kết theo chữ của Pester 3.4; nay tự đếm kết quả nên chạy đúng với Pester 3.4, 4 và 5.
- **hc lỗi không còn bị hiểu là "không có terminal":** khi `hc ls` lỗi hoặc trả dữ liệu sai, `crew up`/`repair` dừng thay vì bật trùng hay đóng space; `hot`/`limits` chỉ cảnh báo.
- Lệnh cài trên Linux/macOS: shim `crew` vẫn được đặt quyền chạy khi PATH không có `chmod`.

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
