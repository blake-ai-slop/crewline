# Changelog

Mới nhất ở trên. Cập nhật Crewline: chạy lại lệnh cài 1 dòng, rồi `crew upgrade` trong từng project.

## 2026-11-18 (2) — Windows chắc hơn sau khi thử trên máy thật

### Mới
- **Agent tự thoát (`/quit`, `/exit`) thì `crew up` mở lại đúng hội thoại cũ,** gõ trong chính pane đó hay ở pane khác đều được; worker đang có task thì được giao lại. `crew up -Restart` vẫn mở hội thoại mới.
- **Crew biết chắc worker đã xong:** khi worker gửi `crew send <repo>-planner "XONG …"`, crew ghi nhận. Worker dừng giữa chừng (kể cả đã commit, worktree sạch) thì `crew up` giao lại với lời nhắc "tiếp tục"; `crew hot` chỉ hiện "đã xong, chờ planner" khi worker đã báo XONG. Task tạo bằng bản cũ giữ cách đoán cũ.
- **`crew up -All` không còn treo vì một project:** mỗi project tối đa 300 giây (`-Timeout <giây>`, `0` = không giới hạn), cuối lệnh in bảng kết quả/thời gian; mã thoát khác 0 nếu có project lỗi, hết giờ hoặc bị bỏ qua.
- **`crew upgrade` in sẵn lệnh xem khác biệt** (`git diff --no-index`) cho từng file được giữ bản của bạn (`.new`).
- **README có phần tiếng Anh;** thêm `docs/troubleshooting.md` (trust, tin kẹt ô nhập, danh tính git, `.new`, limit) và phần self-pane trong `docs/herdr-windows.md`.
- **Hướng dẫn agent (skeleton v12):** Rev và worker phải báo planner trước khi dừng giữa chừng (test đỏ, merge bị chặn, kẹt) và chạy test ở foreground. Project cũ nhận qua `crew upgrade`.
- **`crew queue <tên> <file-prompt>` với tên đã có trong hàng đợi cập nhật prompt** (giữ vị trí); `crew queue` cảnh báo khi file prompt gốc đã sửa sau lúc xếp hàng.
- **`crew hot` hiện `working (nền)`** khi agent đang chờ lệnh chạy nền, thay vì báo nhầm `done`.

### Sửa
- **Không còn mất task khi planner và Rev chạy lệnh crew cùng lúc:** `.crew/tasks.json`, `queue.json`, `sessions.json` và sổ project ghi nguyên tử, đọc-sửa-ghi tasks/queue có khóa (`.crew/state.lock`).
- **`crew send` tới Codex đang bận:** tin dài (nhiều dòng) hoặc tin thứ hai liên tiếp tự vào hàng đợi của Codex, không còn nằm lại ô nhập.
- **`crew send <codex> "/new"`** không còn báo nhầm "hộp thoại lạ"; tin gửi ngay sau đó không bị mất chữ đầu.
- **Gọi `crew` từ Windows PowerShell 5.1 với ≥3 tên task** (`crew review a,b,c`) không còn lỗi tham số. Cần chạy lại lệnh cài 1 dòng để nhận shim mới.
- **`crew task` và `crew repair` không gửi chồng lên tin còn kẹt trong ô nhập của worker** — dừng và chỉ chỗ cần xử lý, như `crew send`/`crew review`.
- **`crew send <claude> "/clear"`** chờ phiên mới sẵn sàng, tin gửi ngay sau đó không mất chữ.
- **`crew up -DryRun` trên project tạo bằng bản rất cũ** (chưa có tên crew) không còn báo lỗi.
- **Cảnh báo lặp của herdr-app** khi crew chờ space/tab chỉ in một lần.
- `crew help` hiển thị đúng trên console code page 437.

### Khác
- CI bỏ qua push/PR chỉ đổi tài liệu/context; lượt mới hủy lượt cũ cùng nhánh. `crew check` chạy cả test trong `tools/` được sửa; CI dùng `actions/checkout@v5`; công cụ kiểm phát hành chọn đúng Pester < 5.

### Chưa kiểm
- Linux/macOS (tạm ngưng). Reboot thật và gõ chữ Việt bằng IME chưa thử; đã thử giả lập reboot và các luồng trên trên herdr-app/hc/Claude/Codex thật.

## 2026-11-18 — hàng đợi chắc hơn, CI chỉ Windows

### Sửa
- **`crew up` lỗi thì hàng đợi không tự giao việc;** mã thoát của `crew up` giữ nguyên.
- **Không mất kết quả hàng đợi:** mỗi lượt tự giao (`crew clean`/`crew up`/`crew queue -Run`) ghi vào `.crew/queue.log` (giữ 200 dòng gần nhất); `crew queue` in thời điểm lượt chạy gần nhất. Khi `crew up` thay chính tab đang gõ, crew báo trước nơi xem kết quả.
- **`crew queue -Run -DryRun` xét trùng file giữa các mục sắp giao cùng lượt,** khớp với lượt chạy thật.

### Lưu ý
- **Linux/macOS tạm ngưng kiểm:** CI chỉ chạy Windows. `crew upgrade` trên Linux đang có lỗi đã biết (từ bản 2026-11-17 (4)); dùng Windows hoặc chờ bản sửa.

## 2026-11-17 (4) — cập nhật không mất dữ liệu

### Mới
- **`crew upgrade` không ghi đè file bạn đã sửa:** `context/README.md`, `context/roles/*.md` và khối `<!-- crew -->` trong `CLAUDE.md`/`AGENTS.md` chỉ được thay khi còn đúng bản crew đã cài. Đã sửa tay thì giữ nguyên bản của bạn, bản mới ghi ra `<file>.new` để bạn gộp tay rồi xóa. Cuối lệnh có tóm tắt: đã cập nhật / giữ bản của bạn (.new) / giữ nguyên, kèm việc cần làm. `-DryRun` in cùng tóm tắt.
- **Quy tắc riêng của project:** đặt trong `context/roles/<vai>.local.md` (planner/rev/worker). Agent đọc sau file role, file này thắng khi mâu thuẫn; `crew upgrade` không bao giờ đụng tới.
- **Cập nhật bằng lệnh cài 1 dòng nói rõ chuyện gì xảy ra:** bản cũ → bản mới, template hc nào được cập nhật hay giữ bản của bạn (.new), config cá nhân và PATH giữ nguyên, và **danh sách project trên máy cần chạy `crew upgrade`**.
- **`crew hot`/`crew up` nhắc khi project cần `crew upgrade`.**

### Sửa
- **Template hc `crew-*` đã sửa tay không còn bị ghi đè** khi cài lại (bản mới ở `.new`). Lệnh lạ trùng tên `~/.local/bin/crew` được sao lưu trước khi ghi.
- **PATH Windows giữ nguyên `%USERPROFILE%`, `%JAVA_HOME%`…** khi crew thêm `~/.local/bin` (trước đây các biến bị bung thành đường dẫn cố định).
- **Dữ liệu `.crew/` và `~/.crewline/` không còn bị làm hỏng:** trường lồng sâu được giữ khi ghi lại; file do bản crew mới hơn ghi, hoặc JSON hỏng, thì crew dừng và nói rõ, không ghi đè. `tasks.json`/`queue.json` rỗng được coi là không có task (kèm cảnh báo).
- **Project tạo bằng bản init cũ** có khối crew thiếu `<!-- /crew -->`: upgrade không còn đoán ranh giới (từng xóa danh sách của bạn ngay dưới khối) mà dừng ở file đó và hướng dẫn thêm dấu kết thúc.

### Lưu ý khi nâng cấp
- Lần upgrade đầu lên v11, file role bạn đã sửa sẽ thành `.new` thay vì bị ghi đè — chuyển phần sửa riêng sang `<vai>.local.md`, rồi thay file role bằng bản `.new`.
- `.gitignore` của project được thêm `context/**/*.new`, `/CLAUDE.md.new`, `/AGENTS.md.new`.

### Chưa kiểm
- Đợt này chỉ chạy đủ test trên Windows.

## 2026-11-17 (3)

### Khác
- **Hướng dẫn planner/Rev (skeleton v10):** planner giao `crew task` khi còn worker rảnh, việc dư hoặc phải chờ task khác thì `crew queue … -After … -Size …`; cố ý cho hai task sửa chung file thì giao tay bằng `crew task -Force` (hàng đợi luôn giữ task trùng file). Rev đọc phần hàng đợi in ra sau `crew clean` và báo planner. README context có thêm `crew queue`, `crew lint`. Project cũ nhận qua `crew upgrade`.

## 2026-11-17 (2)

### Mới
- **`crew queue`:** xếp sẵn task để crew tự giao khi có worker rảnh. `crew queue <tên> <file-prompt> [-Worker N] [-Review x] [-After <task>] [-Size S|M|L]` thêm, `crew queue` liệt kê, `crew queue <tên> -Remove` bỏ, `crew queue -Run [-DryRun]` giao ngay. Tự chạy sau `crew clean` và `crew up`; không có tiến trình nền. Task bị giữ khi task phải chờ chưa xong, trùng file với task đang chạy, không có worker rảnh, hoặc limit ≥70% (task L) / ≥90%. `crew hot` hiện số task đang đợi.
- **Chặn file trùng:** `crew task` dừng khi danh sách "Được sửa:" trong prompt trùng với task đang chạy; thêm `-Force` để vẫn giao. `crew hot` cảnh báo các task đang chạy trùng file.

### Khác
- `scripts/crew.ps1` tách thành `scripts/crew/*.ps1` theo nhóm; hành vi không đổi.

### Chưa kiểm
- Hàng đợi vẫn tự chạy sau `crew up` kể cả khi `crew up` lỗi; khi `crew up` thay chính tab đang gõ, phần in của hàng đợi mất theo. `crew queue -Run -DryRun` chưa xét trùng file giữa các mục sắp giao cùng lượt.
- Đợt này chỉ chạy đủ test trên Windows.

## 2026-11-17

### Mới
- **`crew lint`:** kiểm `context/` của project, chỉ cảnh báo: file vượt số dòng tối đa, mục quá 300 ký tự, file quá 6 KB, tên hàm hoặc đường dẫn nhắc trong MAP/PITFALLS/DECISIONS không còn trong code, mục trùng giữa các file. Thêm `-Strict` để trả lỗi khi có cảnh báo. `crew hot` in một dòng tóm tắt khi có cảnh báo.
- **`crew hot` cảnh báo tab chạy agent khác config** và gợi ý `crew up -Restart <vai>`.
- **`crew limits` lấy số theo agent đang chạy thật trong tab;** khác config thì đánh dấu `*`.

### Sửa
- **`crew upgrade` không còn thêm lại dòng PITFALLS đã chuyển vào `context/archive/`,** kể cả khi dòng đó đã được viết dài thêm.
- **`crew review` không gửi khi Rev không nhận được:** Rev = none, tab tắt, đang chờ duyệt, chạy sai agent hoặc chỉ còn shell thì dừng và nói cách xử lý.
- **`crew up -Restart` không tắt planner đang chạy hoặc Rev đang có task chờ review** trừ khi thêm `-Force`.

### Chưa kiểm
- Đợt này chỉ chạy đủ test trên Windows; CI Linux/macOS chưa đợi.

## 2026-11-04

### Mới
- **`crew check <task> -NoTest`:** chỉ kiểm phạm vi file và cú pháp, không chạy test. `crew check <task>` không có cờ vẫn chạy test như cũ.

## 2026-11-03

### Mới
- **Gõ `crew up` ngay trong tab của một vai:** sau khi khởi động lại máy, gõ `crew up` hoặc `crew up -All` trong tab planner (hay tab vai khác) là đủ. Crew bật xong các vai và project khác, báo vài giây, rồi tự thay tab đó bằng agent, mở lại hội thoại cũ. Chữ đã in trong tab mất theo; nếu có lỗi, xem `.crew/self-pane.log`. Linux/macOS chưa tự thay: crew in hướng dẫn mở tab khác rồi chạy lại.
- **Planner tự giao việc:** không còn chờ bạn duyệt bảng chia, chỉ hỏi khi quyết định thuộc về bạn (đổi hành vi sản phẩm có nhiều hướng, dữ liệu nhạy cảm hoặc project thật, push/phát hành, limit ≥90%). Project cũ nhận qua `crew upgrade`.

### Sửa
- **`crew up -Restart` từ chính tab của vai đó không còn tự tắt giữa chừng:** tab shell được thay sau cùng; tab đang có agent sống thì crew từ chối và không tắt gì.
- **Không giao lại task đã xong:** sau khi khởi động lại, worker đã commit xong và có ghi chú task không còn nhận "Tiếp tục task"; `crew status` hiện nhãn "đã xong, chờ planner".
- **Cảnh báo "có thể có planner thứ hai"** không còn báo nhầm với tab shell thường.
- **Máy chưa đặt tên/email git không còn bị dừng với lỗi khó hiểu:** `crew init`, `crew up` và `crew upgrade` hỏi tên và email ngay trong lệnh, nói rõ đây là yêu cầu của git để commit, Crewline không thu thập gì, không cần là tài khoản thật. Giá trị được lưu vào cấu hình git toàn máy nên chỉ hỏi một lần. Bỏ trống hai lần thì lệnh dừng và không tạo gì; không có người để hỏi thì `crew init`/`crew upgrade` dừng kèm 2 lệnh tự đặt, `crew up` cảnh báo rồi chạy tiếp.

### Lưu ý
- **`crew upgrade` ghi đè file role:** nếu bạn đã tự sửa `context/roles/`, phần sửa không còn trong role và không có cảnh báo; chỉ còn ở file `.bak-<ngày>` (không commit) và lịch sử git.

### Chưa kiểm
- Việc tự thay tab mới thử với `hc` thật và Claude, herdr-app giả, cộng bộ test giả; chưa qua herdr-app thật, Claude/Codex thật và reboot thật. Nếu tab không tự chuyển, mở tab khác rồi chạy lại `crew up`.
- Máy cấm tiến trình tách khỏi job (như máy Windows của GitHub Actions): crew giữ nguyên tab, báo rõ và không tắt gì; mở tab khác rồi chạy lại `crew up`. CI Windows vì vậy không phủ đường tự thay tab thành công, phần này chỉ được test trên máy thật với `hc` giả.

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
- CI Linux/macOS: 2 test chỉ đúng trên Windows giờ chỉ chạy trên Windows.

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
