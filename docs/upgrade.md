# Nâng cấp context

Sau khi cập nhật bản Crewline đang cài, chạy trong dự án đã `crew init`:

```powershell
crew upgrade -DryRun
crew upgrade
crew upgrade -Path C:\du-an -NoCommit
```

`-DryRun` chỉ in thay đổi, gồm cả việc sẽ thêm `*.bak-*` vào `.gitignore` nếu thiếu, không ghi file hoặc commit.
Upgrade thay khối crew trong `CLAUDE.md`/`AGENTS.md` bằng bản mới, giữ nguyên nội dung ngoài khối. Bình thường lệnh commit
`chore: crew upgrade context -> v<N>`. `-NoCommit` để bạn kiểm tra và commit sau.
Nếu `context/` có thay đổi chưa commit (kể cả file mới), lệnh từ chối;
`-Force` cho phép tiếp tục. Hãy commit việc đang làm trước nếu muốn giữ lịch sử riêng.
Commit upgrade chỉ chứa các file được lệnh thay đổi; file đã stage ngoài phạm vi được giữ lại.

| File | Quy tắc |
|---|---|
| `context/README.md`, `context/roles/*.md` | Khác nội dung thì sao lưu `.bak-yyyyMMdd` rồi thay bằng skeleton; giống thì bỏ qua. Nếu trùng tên backup, thêm `-1`, `-2`, … |
| `PROJECT.md`, `HOT.md`, `DECISIONS.md`, `PROGRESS.md`, `ROADMAP.md`, `MAP.md` | Giữ nguyên nội dung đã có |
| `context/tasks/`, `context/archive/` | Không đụng |
| `context/PITFALLS.md` | Chỉ thêm bullet `- …` chưa có, so sánh nguyên dòng sau trim, phân biệt hoa/thường; giữ nguyên mọi dòng cũ |
| File skeleton mới mà dự án chưa có | Chép vào, trừ nội dung dưới `tasks/`, `archive/` |
| `CLAUDE.md`, `AGENTS.md` | Thay riêng khối `<!-- crew -->` đến `<!-- /crew -->`, giữ phần còn lại; nhận cả khối do init cũ tạo. Chưa có khối thì thêm vào |
| `context/.skeleton-version` | Ghi version hiện tại; dự án chưa có file được coi là version 0 |

File `.bak-*` chỉ là bản sao cục bộ, KHÔNG commit (lịch sử git đã giữ bản cũ): `crew init`/`crew upgrade`
thêm `*.bak-*` vào `.gitignore` nếu chưa có (upgrade commit kèm `.gitignore`). Lệnh không xóa file cũ đã biến mất
khỏi skeleton. Khi sửa skeleton, tăng số nguyên trong `skeleton/VERSION` (bản đầu là `1`).
`crew init` cũng ghi version vào dự án.

## Mặc định cá nhân

`crew setup` hỏi chọn đội rồi ghi `~/.crewline/config.json` (install tự gọi khi chưa có file).
Có thể sửa tay file này, hoặc đặt biến môi trường `CREWLINE_USER_CONFIG` trỏ tới file JSON khác:

```json
{
  "team": "standard",
  "planner": "claude",
  "workers": ["claude", "codex"],
  "rev": "codex",
  "review": "lean",
  "access": "work"
}
```

| Khóa | Giá trị |
|---|---|
| `team` | tên mẫu trong `scripts/teams.json` (`standard`, `solo`, `large`) hoặc `custom` |
| `planner`, `rev` | `claude`, `codex`, `none` |
| `workers` | mảng 1–6 phần tử, mỗi phần tử `claude` hoặc `codex` |
| `review` | `lean`, `fast`, `full` |
| `access` | `work`, `wide` |

Mẫu đội chỉ định nghĩa ở `scripts/teams.json`; `crew init` và `crew setup` cùng đọc file đó.
Ví dụ đội tùy chỉnh: không planner, ba worker, Claude làm Rev:

```json
{
  "team": "custom",
  "planner": "none",
  "workers": ["claude", "codex", "codex"],
  "rev": "claude",
  "review": "full",
  "access": "wide"
}
```

Các khóa đều tùy chọn. `crew init` chọn đội theo thứ tự:

1. Cờ `-Team <mẫu>` ⇒ dùng mẫu đó, bỏ qua `planner`/`workers`/`rev` trong file.
2. File có đủ `planner`, `workers`, `rev` ⇒ dùng đúng các vai đó.
3. File chỉ có `team` là tên mẫu ⇒ dùng mẫu đó. `team: custom` mà thiếu vai ⇒ init dừng.
4. Không có gì ⇒ `standard`.

`review`/`access`: cờ dòng lệnh > file cá nhân > mặc định `lean` / `work`.
Đội không có Rev (`rev: none`, như `solo`) luôn dùng review `fast`.
Ví dụ `crew init -Review full` chỉ ghi đè review, vẫn lấy đội/access từ file cá nhân.

File không tồn tại thì dùng mặc định; JSON hỏng hoặc giá trị khóa sai khiến init dừng
trước khi sửa dự án, lỗi nêu khóa sai và giá trị cho phép. `crew init` không tự tạo file
cấu hình cá nhân. Cấu hình này nằm ngoài repo, chỉ áp dụng khi init: init chép đội vào
`.crew/config.json` của dự án, upgrade không đổi thiết lập đó.

`.crew/config.json` còn có `"name"`: tên crew của dự án (tiền tố terminal `<tên>-planner`/`-w<N>`/`-rev`), chốt lúc init và ghi sổ `~/.crewline/projects.json`. Cạnh đó là `"idKey"`: khóa id space/tab herdr (`spcrew<idKey>`), mã hóa đơn ánh từ tên (`z`→`zz`, `-`→`zd`: `my-app`→`myzdapp`, `myapp`→`myapp`) để hai crew không dùng chung space. Dự án cũ thiếu `name`/`idKey`: `crew upgrade` ghi `name` = tên đang dùng và `idKey` = khóa cũ (tên bỏ `-`), nên không đổi tên terminal hay space/tab đang chạy; khóa cũ trùng project khác thì `crew up`/`doctor` báo; `-DryRun` chỉ in. Đổi tên: `crew init -Name <tên>` rồi `crew up` (terminal tên cũ không tự tắt).