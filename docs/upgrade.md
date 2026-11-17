# Nâng cấp context

Sau khi cập nhật bản Crewline đang cài, chạy trong dự án đã `crew init`:

```powershell
crew upgrade -DryRun
crew upgrade
crew upgrade -Path C:\du-an -NoCommit
```

Nguyên tắc: **upgrade không bao giờ ghi đè thứ bạn đã sửa.** File/khối bạn đã sửa được giữ nguyên từng byte; bản mới
ghi ra `<file>.new` bên cạnh (không commit), lệnh in `CẢNH BÁO: <file> đã sửa tay — bản mới ở <file>.new, gộp tay rồi xóa .new`.

`-DryRun` không ghi file, không commit; cuối lệnh (thật hoặc `-DryRun`) in khối tóm tắt:

```text
== crew upgrade: context v10 -> v11
Đã cập nhật (3): context/roles/rev.md, context/roles/worker.md, context/.skeleton-version (v10 -> v11)
Giữ bản của bạn, bản mới ở .new (1): context/roles/planner.md -> context/roles/planner.md.new
Giữ nguyên (3): context/README.md, CLAUDE.md (khối crew), AGENTS.md (khối crew)
Việc cần làm: mở từng cặp <file> và <file>.new, gộp phần mới vào bản của bạn rồi xóa .new; …
```

Không có gì thay đổi ⇒ một dòng `context đã ở v<N>, không có gì để cập nhật.` Bình thường lệnh commit
`chore: crew upgrade context -> v<N>`. `-NoCommit` để bạn kiểm tra và commit sau.
Nếu `context/` có thay đổi chưa commit (kể cả file mới, trừ `*.bak-*`/`*.new`), lệnh từ chối, nêu file và lệnh để làm tiếp;
`-Force` cho phép tiếp tục. Commit upgrade chỉ chứa các file được lệnh thay đổi; file đã stage ngoài phạm vi được giữ lại.

## Dấu bản mẫu

`crew init`/`crew upgrade` ghi `context/.skeleton-hashes.json` (commit cùng): khóa là đường dẫn trong `context/`
(`README.md`, `roles/planner.md`, …) hoặc `CLAUDE.md#crew` / `AGENTS.md#crew` (nội dung giữa `<!-- crew -->` và
`<!-- /crew -->`), giá trị là sha256 của bản mẫu đã cài (CRLF chuẩn hóa thành LF). Upgrade với từng file/khối đó:

| Hiện trạng | Kết quả |
|---|---|
| Giống hệt bản mới | Chỉ cập nhật dấu |
| Khớp dấu đã lưu, hoặc khớp một bản Crewline đã phát hành (`skeleton/released-hashes.json`) | Thay bằng bản mới, cập nhật dấu |
| Khác (bạn đã sửa), hoặc project cũ chưa có dấu mà không khớp bản phát hành nào | Không thay; ghi `<file>.new`; dấu giữ giá trị cũ |

Project init bằng bản cũ (chưa có dấu) vẫn được cập nhật bình thường nếu file còn đúng một bản đã phát hành.
Khi sửa `skeleton/context/README.md`, `roles/*.md` hoặc `Get-CrewBlock`: tăng `skeleton/VERSION` và thêm sha256 bản mới
vào `skeleton/released-hashes.json` (`tests/UpgradeSafety.Tests.ps1` kiểm).

## Quy tắc riêng: `*.local.md`

Đừng sửa thẳng `context/roles/<vai>.md` để thêm luật của project; đặt chúng ở `context/roles/<vai>.local.md`
(`planner.local.md`, `rev.local.md`, `worker.local.md`). Mỗi file vai nhắc agent đọc file `.local.md` sau nó, và
file `.local.md` thắng khi mâu thuẫn. `crew init`/`crew upgrade` không tạo, không sửa, không xóa `*.local.md`, nên
role chuẩn luôn cập nhật được. Đã lỡ sửa role: khi có `.new`, chuyển phần riêng sang `.local.md`, lấy bản `.new` thay
file role rồi xóa `.new`.

| File | Quy tắc |
|---|---|
| `context/README.md`, `context/roles/*.md` | Theo dấu bản mẫu ở trên; không còn tạo `.bak` |
| `context/roles/*.local.md` | Không bao giờ đụng |
| `PROJECT.md`, `HOT.md`, `DECISIONS.md`, `PROGRESS.md`, `ROADMAP.md`, `MAP.md` | Giữ nguyên nội dung đã có |
| `context/tasks/`, `context/archive/` | Không đụng |
| `context/PITFALLS.md` | Chỉ thêm bullet `- …` chưa có, so sánh nguyên dòng sau trim, phân biệt hoa/thường; giữ nguyên mọi dòng cũ |
| File skeleton mới mà dự án chưa có | Chép vào, trừ nội dung dưới `tasks/`, `archive/` |
| `CLAUDE.md`, `AGENTS.md` | Chỉ phần giữa `<!-- crew -->` và `<!-- /crew -->`, theo dấu bản mẫu; ngoài khối luôn giữ nguyên. Chưa có khối thì thêm vào. Có `<!-- crew -->` mà thiếu `<!-- /crew -->` (khối kiểu init cũ) ⇒ không ghi file đó, cảnh báo: thêm dòng `<!-- /crew -->` bằng tay ngay sau khối rồi chạy lại |
| `context/.skeleton-version` | Ghi version hiện tại; dự án chưa có file được coi là version 0 |

File `.bak-*` và `.new` chỉ là bản cục bộ, KHÔNG commit: `crew init`/`crew upgrade` thêm vào `.gitignore` nếu chưa có
(upgrade commit kèm `.gitignore`) `*.bak-*` và đúng các chỗ upgrade sinh `.new`: `context/**/*.new`, `/CLAUDE.md.new`,
`/AGENTS.md.new` — không ignore `*.new` chung để file `.new` thật của project vẫn hiện. Project đã có dòng `*.new` thì giữ nguyên. Lệnh không xóa file cũ đã biến mất khỏi skeleton.
`crew init` cũng ghi version và dấu bản mẫu vào dự án.

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