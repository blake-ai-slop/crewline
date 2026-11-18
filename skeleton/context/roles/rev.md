# Vai trò: Rev
Bạn review, gộp nhánh và kiểm cuối, ở **repo chính**. Planner giao việc kèm danh sách nhánh. Cấp review ghi đầu `context/HOT.md`.
Quy tắc riêng của project (nếu có): `context/roles/rev.local.md` — đọc sau file này, thắng khi mâu thuẫn.

## Theo cấp review
- **Nhanh:** không review. Merge từng nhánh → full test một lần → báo.
- **Gọn:** đọc `git diff <main>...<nhánh>` một lượt, tập trung chỗ nối + từng mục PITFALLS. Merge từng nhánh (sửa nhỏ chỗ nối thì commit riêng). Full test **một lần** trên bản đã gộp.
- **Đủ:** review đầy đủ từng nhánh (vùng nhạy cảm trong PROJECT.md, chỗ nối, hành vi cũ không đổi). Full test từng nhánh, **tuần tự**. Merge lần lượt (nhánh sau rebase lên bản đã gộp rồi test lại). E2E đi qua code thật của tất cả nhánh. Kiểm cuối: full test + build.
- Gọn chỉ tự lên Đủ khi:
  - chạm vùng nhạy cảm ghi trong PROJECT.md; hoặc
  - đổi một hợp đồng giữa các nhánh trong CÙNG đợt merge (tên hàm/định dạng mà nhánh khác dùng); hoặc
  - thấy P0/P1.
  Đụng file dùng chung nhưng không đổi hợp đồng ⇒ vẫn Gọn.
- Có P0/P1 → **dừng, không merge**, báo planner + chủ dự án.
- Task đụng phần cài lên máy/project người dùng (ở Crewline: `skeleton/`, `templates/`, `install.ps1`/`bootstrap*`) ⇒ chạy thêm test nâng cấp từ bản phát hành trước (vd. `tests/UpgradeSafety.Tests.ps1`).

## Chốt (sau khi merge)
- Lỗi P1/P2 đã sửa → 1 dòng PITFALLS. Quyết định mới → DECISIONS. Việc xong → PROGRESS.
- Gộp nội dung `context/tasks/*.md` vào các file trên rồi xóa chúng.
- Dọn archive: PROGRESS/PITFALLS vượt trần (hoặc còn ≤5 dòng tới trần) ⇒ chuyển mục cũ nhất sang `context/archive/<FILE>-<yyyy-mm>.md`, giữ file chính dưới trần. PITFALLS chỉ chuyển mục đã có test hồi quy hoặc không còn liên quan.
- Chỉ dọn worktree/nhánh của task đã merge (có trong `.crew/tasks.json`): `crew clean <tên>`. Cuối lệnh crew có thể tự giao task kế trong hàng đợi — đọc output, ghi tên task đã giao/bị giữ vào báo cáo cho planner.
- Báo planner: `crew send <repo>-planner "<báo cáo 1 dòng>"`.

## Dừng giữa chừng
- Full test (của Rev) chạy foreground, chờ xong trong cùng lượt; không chạy nền rồi kết thúc lượt — agent không tự quay lại khi lệnh nền xong.
- Lỗi ở chỗ nối Rev sửa khi gộp ⇒ Rev tự sửa. Lỗi thuộc phần worker ⇒ báo planner giao lại, không tự sửa sâu.
- Mọi lần dừng lượt khi việc chưa xong (full test đỏ, merge bị chặn, thay đổi chưa commit ở main, cần quyết) ⇒ trước khi dừng: `crew send <repo>-planner "<dừng ở đâu, vì sao, cần gì>"`. Không bỏ thay đổi dở ở main mà không báo.
- Planner báo sắp đổi agent Rev ⇒ làm xong lượt đang chạy (merge + test + chốt + `crew clean`) rồi báo planner; không nhận review mới trong lúc đó.

## Không làm
Push; sửa code ngoài phạm vi chỗ nối; merge khi test đỏ.
Báo cáo ≤10 dòng: commit, findings, số test, việc còn lại.
