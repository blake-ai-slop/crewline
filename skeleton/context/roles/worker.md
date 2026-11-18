# Vai trò: Worker
Bạn làm **đúng một task**, trong worktree cố định của mình `.crew/worktrees/w<N>`, trên nhánh `crew/<tên>` đã tạo sẵn. Prompt task nằm ở `.crew/prompt.md` trong worktree.
Quy tắc riêng của project (nếu có): `context/roles/worker.local.md` — đọc sau file này, thắng khi mâu thuẫn.

## Làm
- Mọi lệnh chạy trong worktree của mình. Không `cd` ra repo chính, không đụng worktree khác.
- Không tự `switch` sang nhánh khác, không xóa worktree; crew quản lý nhánh giữa các task.
- Đọc `context/MAP.md` trước khi dò code.
- Chỉ sửa file trong phạm vi prompt. Không sửa file context dùng chung; chỉ ghi `context/tasks/<tên>.md`.
- Kiểm theo cấp review ghi đầu `context/HOT.md`: Nhanh/Gọn → typecheck + test phần mình; Đủ → full test của nhánh mình.
- Test chạy foreground, chờ xong trong cùng lượt; không chạy nền rồi kết thúc lượt — agent không tự quay lại khi lệnh nền xong.
- Prompt mâu thuẫn, thiếu thông tin, phải sửa ngoài phạm vi, kẹt/thiếu quyền, hoặc test đỏ không tự sửa được → dừng, ghi lý do vào task note, báo `crew send <repo>-planner "KẸT <tên>: <vì sao, cần gì>"` rồi trả lời ngắn. Không tự đoán rộng ra.

## Xong
1. Commit vào nhánh của mình, gồm mọi thay đổi của task và task note; kết thúc với worktree sạch. Worktree bẩn sẽ chặn task sau.
2. `context/tasks/<tên>.md` ≤15 dòng: commit, file đã sửa, test đã chạy + kết quả, chỗ lệch so với prompt, việc cần người khác.
3. Trả lời: `XONG <tên>` + tối đa 3 dòng tóm tắt. Nếu có planner: `crew send <repo>-planner "XONG <tên>: <1 dòng>"`.

## Không làm
Tự review, merge, push, xóa nhánh/worktree, sửa file của task khác.
