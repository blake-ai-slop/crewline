# Context dùng chung (crew)

Thứ tự đọc: **PROJECT → HOT → PITFALLS → DECISIONS → MAP**. Vai trò của bạn nằm trong `roles/`.

## Ai ghi gì
| File | Nội dung | Ai ghi |
|---|---|---|
| PROJECT.md | mục tiêu, phạm vi, lệnh, vùng nhạy cảm | chủ dự án / planner |
| HOT.md | đang kẹt, chờ chủ dự án, tiếp theo (≤30 dòng; việc đang chạy xem `crew hot`) | planner (dòng đầu: chế độ review + quyền) |
| DECISIONS.md | quyết định còn hiệu lực (≤30 dòng) | Rev khi merge, planner khi chủ dự án chốt |
| PITFALLS.md | lỗi đã gặp, phải kiểm (≤40 dòng) | Rev khi merge |
| PROGRESS.md | việc đã xong, mới nhất trước (≤50 dòng) | Rev khi merge |
| ROADMAP.md | việc sắp làm | chủ dự án / planner |
| MAP.md | bản đồ code | planner |
| CHANGELOG.md (gốc repo) | thay đổi người dùng thấy, ghi khi push | planner |
| roles/ | vai trò | chủ dự án / planner |
| tasks/<tên>.md | ghi chú một task | **chỉ worker của task đó** |
| archive/ | phần cũ được dọn | Rev |

## Lệnh crew (máy này: herdr-app + hc trên Windows)
- `crew hot` — worktree, terminal của crew, task đang chạy.
- `crew task <tên> <file-prompt> [-Worker N] [-Review fast]` — tạo worktree `crew/<tên>`, chép prompt, bật worker.
- `crew send <terminal> "<1 dòng>"` — gửi tin cho agent/shell (thay `hc send` + `hc keys enter`).
- `crew check <task>` — planner kiểm phạm vi/parse/test sau khi worker báo XONG.
- `crew review <task,…>` — giao Rev.
- `crew selfcheck` — tự thử trước khi push.
- `crew clean <tên>` — dọn worktree/nhánh/terminal của task đã merge.
- Theo dõi agent: `hc get <địa chỉ|tên>`, `hc read <t> --lines 80`, `hc wait <t>`.
