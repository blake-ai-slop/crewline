# Prompt: dựng crew bằng Crewline

Dán phần dưới vạch vào một agent (Claude Code hoặc Codex) **đang chạy trong một pane của herdr-app**.

---

Bạn là agent cài đặt. Dùng Crewline (`~/Crewline`) để dựng đội agent trong herdr-app cho project của tôi: 1 planner, các worker trong git worktree riêng, 1 Rev, cùng context chung trong git. Đọc `~/Crewline/README.md` trước. Trả lời tôi bằng tiếng Việt.

## Quy tắc
- Trước mỗi bước có tác dụng (ghi file, bật agent, commit), nói việc sắp làm.
- Không push. Không xóa thứ mình không tạo. Không `hc server stop/restart`. Muốn dừng terminal thì dừng đúng terminal mình tạo (`hc kill <tên>`).
- Thiếu thông tin thì hỏi tôi một lần (tối đa 4 câu), rồi làm tiếp.

## Bước 1: Kiểm
Chạy `crew doctor`. Nếu chưa có lệnh `crew`, chạy `pwsh ~/Crewline/install.ps1` trước. Báo mục THIẾU kèm cách sửa. Thiếu git identity thì hỏi tôi tên và email rồi đặt `--global`. Chưa đăng nhập claude/codex thì nhắc tôi; bạn không tự đăng nhập.

## Bước 2: Hỏi tôi (một lần)
1. Đường dẫn project. Project phải là repo git có ít nhất 1 commit; nếu chưa có thì hỏi tôi có cho `-GitInit` không.
2. Mẫu đội: standard (mặc định) / solo / large / tự chọn từng vai.
3. Cấp review: Gọn (mặc định) / Nhanh / Đủ.
4. Quyền worker/Rev: Làm việc (mặc định) / Mở rộng.

## Bước 3: Dựng
```powershell
cd <project>
crew init -Team <mẫu> -Review <lean|fast|full> -Access <work|wide>
# tự chọn từng vai: sửa .crew/config.json, rồi
crew up
```
Nếu agent nào hỏi trust thư mục, chỉ cho tôi tab đó và phím cần bấm (Claude: `down` rồi `enter`; Codex: `enter`). Chỉ bấm thay khi tôi cho phép.

## Bước 4: Báo cáo (≤10 dòng)
File đã ghi hoặc sao lưu, commit, bố cục tab/pane (`crew hot`), mẫu đội, cấp review, quyền, và việc tôi làm tiếp. Việc tiếp thường là sang tab planner rồi nói việc muốn làm bằng lời.
