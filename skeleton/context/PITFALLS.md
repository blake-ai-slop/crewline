# Pitfalls

Lỗi đã gặp, phải kiểm (≤40 dòng).

- Agent mở ở thư mục của terminal, thường là `~`, nên lệnh git/npm dễ chạy nhầm repo. Luôn bật với `--cwd <worktree>` (crew task đã làm), và prompt vẫn phải nhắc thư mục.
- Gửi prompt nhiều dòng vào TUI dễ bị Enter giữa chừng. Chỉ gửi MỘT dòng trỏ tới file prompt.
- Mỗi task mới phải bắt đầu hội thoại mới: `crew task` tự `/clear` cho Claude hoặc `/new` cho Codex, giữ agent trong worktree cố định `.crew/worktrees/w<N>`; đừng gửi tay thêm.
- Sau `/new` cho Codex cần chờ phiên mới rồi mới gửi prompt; `crew task` tự chờ và gửi, đừng gửi `/new` hay prompt tay trong lúc crew đang chạy.
- Phím hộp thoại: Claude nhận `1`; hộp trust thư mục của Claude dùng `hc keys <t> down enter`, không dùng mỗi `enter`. Codex trust nhận `enter`, duyệt lệnh nhận `y`. Sau khi trả lời, `hc wait <t>` vì có thể còn trạng thái `blocked` cũ.
- `hc run <template> "<task>"`: kiểm `first_message.sent`. Nếu false, task CHƯA gửi: `hc read <t>`, xử lý hộp trust rồi mới `hc send`. Không gửi lại mù quáng.
- Trạng thái `blocked` = cần người duyệt. `hc send` sẽ từ chối; không dùng `--force` để vượt quyết định duyệt.
- Worktree đặt trong repo (`.crew/worktrees/<tên>`) để kế thừa trust thư mục.
- Prompt nằm ngoài worktree khiến Claude xin quyền Read. Chép prompt vào `<worktree>/.crew/prompt.md` (đã gitignore).
- Test của worker dùng bản giả của phía bên kia không chứng minh được chỗ nối. Rev phải có test e2e đi qua code thật của cả hai nhánh.
- Hai bộ full test chạy cùng lúc trên một máy gây timeout giả, nên chạy tuần tự.
- Đọc báo cáo worker chưa đủ: planner phải grep đối chiếu chỗ nối trên code thật trước khi giao Rev.
- Hai bên tự viết hai bản cho cùng một quy tắc sẽ lệch nhau. Gom về một hàm dùng chung.
- Prompt giao việc có đổi hành vi phải cho phép worker sửa các test cũ đang khẳng định hành vi đó.
- Tên terminal hc là duy nhất trên toàn server, nên dùng tiền tố repo (`<repo>-planner`, `<repo>-rev`, `<repo>-w1`).
- Codex dưới hc phải chạy với `--no-daemon`, không thì lệnh của nó chạy ngoài hc.
- Không bao giờ `hc server stop/restart` core của người dùng. Test cần `HC_SESSION` riêng.
- Allowlist lệnh chỉ chống nhầm lẫn, không chống cố ý. Ranh giới thật là worktree cộng với review, hoặc sandbox của hệ điều hành.
