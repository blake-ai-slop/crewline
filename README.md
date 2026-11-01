# Crewline

Đội agent trong **herdr-app + hc** trên Windows, Linux và macOS: 1 **planner** điều phối, các **worker** làm việc trong git worktree riêng, 1 **Rev** review và gộp nhánh, cùng một bộ **context chung** nằm trong git của project.

Mục tiêu: nhiều agent (Claude Code, Codex) cùng làm một dự án, song song, không giẫm file nhau và không mất context khi đổi phiên. Cài bằng một dòng lệnh, sau đó tự tinh chỉnh.

| Hệ | Trạng thái |
|---|---|
| Windows 10/11 | Dùng hằng ngày, đã chạy thật với agent |
| Linux (x86_64, ARM) | **Thử nghiệm:** test + CI xanh, chưa chạy thật herdr-app với agent |
| macOS (Apple Silicon) | **Thử nghiệm:** như Linux; Mac Intel chưa có herdr-app |

```
crew:<repo>  (space trong herdr-app)
├── planner   Claude — chia việc, viết prompt task, theo dõi, không viết code
├── workers   [w1 Claude | w2 Codex] — agent giữ phiên, mỗi worker một worktree cố định
└── rev       Codex — đọc diff, merge, full test, ghi PITFALLS/PROGRESS
```

## Bắt đầu nhanh

1. **Cần có:** herdr-app đang mở (tải: https://herdr.dev/), `git`, PowerShell 7 (`pwsh`), `claude` và/hoặc `codex` đã đăng nhập. Lệnh cài sẽ kiểm và hỏi cài giúp agent còn thiếu (mặc định `[1]` là bỏ qua; gõ `2` rồi Enter để cài giúp).
2. **Cài** (trong một pane PowerShell của herdr-app):
   ```powershell
   irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex
   ```
   Linux/macOS (trong một pane shell của herdr-app): `curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh` — xem [Cài trên Linux/macOS](#cài-trên-linuxmacos).
   Lúc cài, bạn sẽ được hỏi chọn đội, agent, số worker, Rev, review và quyền: mỗi câu là danh sách đánh số, gõ số rồi Enter (Enter trống = mặc định trong `[ ]`). Đổi sau bằng `crew setup`. Cài không hỏi: đặt `$env:CREWLINE_DEFAULTS=1` trước lệnh cài (không tạo config cá nhân).
   Mở terminal mới để có lệnh `crew`, rồi chạy `crew doctor` để kiểm.
3. **Bật crew cho một project** (chạy trong một pane của herdr-app, để `crew up` mở được tab):
   ```powershell
   cd <project>
   crew init     # tạo context/ chung + .crew/config.json
   crew up       # mở tab planner / workers / rev trong herdr
   ```
   Lần đầu ở project mới, mỗi agent hỏi trust thư mục; `crew up` liệt kê pane cần bạn bấm xác nhận.
   Thư mục mới chưa có git: `crew init` sẽ hỏi có tạo repo git (git init + commit đầu) không, gõ `1` rồi Enter. Không muốn hỏi thì dùng `crew init -GitInit`.
4. **Làm việc:** sang tab **planner**, nói việc muốn làm. Planner chia việc, đưa bảng chia cho bạn duyệt, rồi giao cho worker. Worker xong thì Rev review và merge. Theo dõi bằng `crew hot`.
5. **Cập nhật Crewline:** chạy lại lệnh cài ở bước 2, rồi trong mỗi project chạy `crew upgrade`. Có gì mới: xem [`CHANGELOG.md`](CHANGELOG.md).

Mặc định của riêng bạn (đội, cấp review, quyền agent) đặt trong `~/.crewline/config.json`, xem [`docs/upgrade.md`](docs/upgrade.md). Cấu hình, skill và memory của Claude/Codex vẫn là của riêng từng người, Crewline không đụng tới.

## Cách crew chia việc

```text
main ──┬── bàn w1: .crew/worktrees/w1 → crew/task-a → main → crew/task-c
       ├── bàn w2: .crew/worktrees/w2 → crew/task-b → main → crew/task-d
       └── …            (mỗi task một nhánh mới từ main trên bàn của worker)
worker commit → crew check + planner đối chiếu → crew review (Rev merge)
→ Rev chạy full test + crew clean
planner: crew selfcheck + CHANGELOG → push khi bạn cho phép
```

- **Mỗi worker một bàn cố định:** worktree `.crew/worktrees/w<N>` gắn với vị trí worker.
  `crew task` kiểm worktree sạch, tạo nhánh mới `crew/<tên>` từ `main` trên bàn đó,
  rồi tự gửi `/clear` (Claude) hoặc `/new` (Codex), chờ phiên mới và gửi prompt.
  Agent của worker chỉ làm trong worktree của mình, nên nhiều worker chạy song song không giẫm file nhau.
- **Giữ agent giữa các task:** pane worker luôn có agent, chỉ làm mới hội thoại giữa task.
  Muốn đổi model/thinking: vào pane gõ `/model`; lựa chọn vẫn giữ ở task sau.
  Đổi agent hoặc quyền thì chạy `crew up -Restart w<N>` (hoặc `planner`, `rev`, `all`).
- **Task độc lập:** planner chia để các task không sửa chung file;
  chỗ nối giữa hai task được ghi thành hợp đồng trong prompt của cả hai.
- **Chia đều:** đội có 1–6 worker; việc được chấm S=1 / M=2 / L=3,
  tổng điểm mỗi worker chênh nhau ≤1, số task song song ≤ số worker.
  Bạn duyệt bảng chia trước khi planner giao việc.
- **Cân theo limit:** lúc sắp giao task, planner chạy `crew limits` để hỏi số trực tiếp
  từ Codex/Claude một lần, không tốn token, không theo dõi liên tục. Mốc chỉ theo % 5h đã dùng,
  chia 3 cấp: dưới 50% `ok`; 50–69% `theo dõi` (giao bình thường,
  planner đọc lại limit mỗi khi worker báo xong); 70–89% `hạn chế` (không nhận task L,
  chỉ việc nhỏ/vừa, ưu tiên agent khác); từ 90% `dừng` (không nhận task mới trừ khi bạn
  nói rõ "vẫn giao"; đang có task thì planner báo bạn ngay).
  % tuần không vào mốc; tuần ≥90% thì bảng có cảnh báo ⚠ và planner báo bạn trước khi
  giao cho agent đó (không tự chặn). Không đọc được 5h thì mốc là `không rõ`.
  Không hỏi được (thiếu CLI, chưa đăng nhập, đổi format) thì lấy từ màn hình terminal qua `hc read`,
  bảng ghi `(màn hình, có thể cũ)`. Trên màn hình, Codex luôn hiện limit; Claude chỉ đọc được nếu bạn
  tự bật status line có 5h/tuần, crew không bật hộ. Cũng không đọc được thì hiện `không rõ` và chia theo điểm như cũ.
  Limit tính theo tài khoản agent: các pane cùng agent dùng chung số (kể cả worker Codex và Rev Codex).
  Khi phải lấy từ màn hình mà pane hẹp không hiện limit, `crew limits` lấy số từ pane khác cùng agent.
  Khi tài khoản Claude và Codex lệch limit, planner dồn việc sang agent còn nhiều trong đội trộn cả hai.
- **Làn nhanh:** gom các task S hoặc dùng `crew task … -Review fast` để giảm lượt review.
- **Gộp và dọn:** chỉ Rev merge ở repo chính và chạy full test theo cấp review.
  Sau đó `crew clean <tên>` đưa bàn về `main`, xóa nhánh task, giữ agent và thư mục;
  nhánh chưa merge vào `HEAD`
  của repo chính thì từ chối, trừ khi dùng `-Force` để bỏ task.
- **Context chung:** `context/` nằm trong git nên mọi worktree đều đọc được;
  worker chỉ ghi `context/tasks/<tên>.md`, Rev gom vào PROGRESS/PITFALLS/DECISIONS khi merge.
  Planner ghi mục **Tiếp theo** trong HOT để planner mới tiếp quản được.
- **Push khi bạn cho phép:** planner chạy `crew selfcheck`, cập nhật CHANGELOG rồi mới push khi được bạn cho phép.

## Cài

**Cách 1 dòng** (PowerShell 7 hoặc Windows PowerShell 5.1):

```powershell
irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex
```

Lệnh này kiểm `git` và `pwsh` (thiếu thì báo cách cài rồi dừng), clone Crewline vào `~/Crewline` (đã có thì `git pull --ff-only`; thư mục có sẵn mà không phải Crewline thì dừng, không ghi đè), rồi chạy `install.ps1`. Muốn cài chỗ khác, đặt biến trước khi chạy: `$env:CREWLINE_DIR = 'D:\Tools\Crewline'` (thêm `CREWLINE_REPO`, `CREWLINE_BRANCH` nếu dùng bản fork). Chạy file trực tiếp thì truyền tham số: `./bootstrap.ps1 -Dir <thư mục> -Repo <url> -Branch main`.

**Cách clone tay**, trong một pane của herdr-app (PowerShell):

```powershell
git clone https://github.com/blake-ai-slop/crewline.git ~/Crewline
cd ~/Crewline
./install.ps1
```

`install.ps1` cài shim `crew` vào `~/.local/bin` (dùng được từ PowerShell và Git Bash), chép template `hc` vào `%APPDATA%\herdr-core\templates`, tải `jq` nếu thiếu, tạo thư mục `~/.crewline/`, rồi chạy `crew doctor` (bỏ qua bằng `-NoDoctor`). Bạn có thể chạy lại bao nhiêu lần cũng được.

### Cài trên Linux/macOS

```sh
curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh
```

- **Cần có:** `git`, `curl`, `tar`. Chưa có `pwsh` thì `bootstrap.sh` tải PowerShell 7 vào `~/.local` (không cần sudo); có rồi thì dùng bản sẵn có. Sau đó clone vào `~/Crewline` và chạy `install.ps1` bằng `pwsh`.
- `install.ps1` trên Unix: shim `~/.local/bin/crew` (script `pwsh` thực thi), template `hc` vào `~/.config/herdr-core/templates` (theo `XDG_CONFIG_HOME` nếu có), thêm `~/.local/bin` vào PATH qua `~/.profile` (+ `~/.zshrc` trên macOS, `~/.bashrc` nếu có). Không tải `jq`: cài bằng trình quản lý gói nếu cần.
- **herdr-app + hc:** cài bằng `curl -fsSL https://releases.herdr.dev/app/install.sh | sh`; lệnh cài chỉ chạy khi bạn chọn "Cài giúp".
- **Mac Intel:** herdr-app không có bản dựng sẵn cho Mac Intel — `crew doctor` báo thiếu và chỉ cách build từ mã nguồn, không chặn cài crew. Mac Apple Silicon dùng bản dựng sẵn bình thường.
- Shim PS 5.1 và Git Bash chỉ có trên Windows. Khác biệt herdr/hc trên Unix: [`docs/herdr-unix.md`](docs/herdr-unix.md).

Nâng cấp context của dự án cũ khi Crewline đổi: xem [`docs/upgrade.md`](docs/upgrade.md).

Trước khi dùng cần có: herdr-app (đang mở), `claude` và `codex` đã đăng nhập, `git` đã đặt `user.name` và `user.email`.

## Dùng cho một project

```powershell
cd <project>
crew init          # khung context/, CLAUDE.md + AGENTS.md, .crew/config.json, commit
crew up            # space crew:<tên crew> với tab planner / workers / rev
```

**Tên crew.** `crew init` chốt một tên crew cho project vào `"name"` của `.crew/config.json` (từ tên thư mục, bỏ dấu, ≤12 ký tự) và ghi sổ `~/.crewline/projects.json`. Terminal mang tên `<tên>-planner`, `<tên>-w<N>`, `<tên>-rev`. Hai project trùng tên thư mục (`D:\work\app`, `E:\client\app`) sẽ thành `app` và `app-2`, nên chạy nhiều project song song không lẫn terminal. Muốn tự đặt: `crew init -Name <tên>` (a-z 0-9 -). `crew up`/`task`/`send`/`review`/`repair` dừng nếu terminal cùng tên đang chạy ở project khác; chép nguyên thư mục project thì `crew up`/`doctor` báo trùng và gợi ý đổi `name`. Project cũ chưa có `name` giữ tên cũ; `crew upgrade` ghi tên đó vào config.

Sau đó sang tab **planner** và nói bằng lời việc muốn làm. Planner sẽ hỏi để điền `context/PROJECT.md`, chia việc, trình bảng chia cho bạn duyệt, rồi giao task:

```powershell
crew task <tên> .crew/prompts/<tên>.md [-Worker N]   # nhánh mới trên bàn worker, làm mới hội thoại + gửi prompt
crew hot                                            # worktree, terminal, task đang chạy
crew clean <tên>                                    # sau khi Rev merge: về main, xóa nhánh, giữ agent + thư mục
```

| Lệnh | Tác dụng |
|---|---|
| `crew doctor` | kiểm herdr/hc, agent, git identity, template |
| `crew setup` | chọn đội, agent, số worker, Rev, review và quyền mặc định cá nhân |
| `crew init [-Name <tên>] [-Team standard\|solo\|large] [-Review lean\|fast\|full] [-Access work\|wide] [-GitInit] [-NoCommit]` | dựng khung, giữ nguyên file đã có, sao lưu `<file>.bak-<ngày>` trước khi sửa |
| `crew upgrade [-DryRun] [-NoCommit] [-Force]` | cập nhật skeleton context của project, giữ cấu hình riêng |
| `crew repair [-DryRun]` | chẩn đoán và khôi phục terminal/worktree thiếu, giữ nhánh và task |
| `crew help [lệnh]` | xem bắt đầu nhanh, danh sách lệnh hoặc hướng dẫn chi tiết |
| `crew up` | bật agent theo `.crew/config.json`; terminal nào đang chạy thì bỏ qua |
| `crew up -Restart <w1\|…\|planner\|rev\|all>` | bật lại vai được chọn sau khi đổi agent/quyền |
| `crew task <tên> <file-prompt> [-Worker N] [-Review fast\|lean\|full]` | kiểm bàn worker sạch, tạo nhánh `crew/<tên>` từ main, tự `/clear` hoặc `/new`, chờ rồi gửi prompt với cấp review của task |
| `crew send <terminal> "<tin>"` | gửi tin, tự Enter nếu tin kẹt ở ô nhập và gửi lệnh trần tới shell |
| `crew review <task,…> [-DryRun]` | soạn một dòng giao Rev merge các task theo thứ tự, gửi tới `<tên crew>-rev` |
| `crew check <task>` | đối chiếu diff với "Được sửa", kiểm cú pháp và chạy test phần đó |
| `crew selfcheck` | cài thử vào HOME giả, kiểm PS 5.1 (chỉ Windows) và init/upgrade trước khi push |
| `crew hot` | tình hình nhanh cho planner |
| `crew limits` | hỏi limit trực tiếp từ Codex/Claude một lần, không tốn token; không hỏi được thì lấy từ màn hình, có thể cũ: terminal · agent · 5h dùng · tuần dùng · mốc theo 5h (`ok` / `theo dõi` / `hạn chế` / `dừng` / `không rõ`, thêm ⚠ khi tuần ≥90%) · reset 5h · task |
| `crew clean <tên> [-Force]` | về main, xóa nhánh task, giữ agent + thư mục; chỉ dọn task có trong `.crew/tasks.json`, nhánh chưa merge thì từ chối nếu không có `-Force` |

## Lỡ đóng pane hoặc cả space

Code và context nằm trên đĩa và trong git nên không mất khi đóng pane/space. Chạy `crew repair` để chẩn đoán và khôi phục phần an toàn; có thể xem trước bằng `crew repair -DryRun`. Nếu còn việc cần bạn quyết, lệnh sẽ báo để bạn xử lý.

## Nhiều project, đổi tên, chép thư mục

Mỗi project có một crew và tên riêng: `crew init -Name <tên>`. Đổi tên hoặc chuyển thư mục project thì chạy `crew repair` để sửa đường dẫn, sổ và bật lại terminal.

Khi chép nguyên thư mục, chạy `crew init -Name <tên mới>` trong bản chép: crew dọn tasks.json và các thư mục worker chép theo không đăng ký trong git của bản chép, giữ nguyên bản gốc. Nên dùng `git clone` để tạo bản riêng sạch.

Crew không tự chặn commit thẳng main lúc Rev merge, sửa file trong `.crew/worktrees`, hoặc tự mở planner thứ hai. `crew hot` cảnh báo khi root có thay đổi chưa commit/merge dở, worker bẩn không có task, agent lạ chạy ở root hoặc tên crew thuộc bản gốc còn tồn tại.

## Mẫu đội

| Mẫu | Planner | Worker | Rev |
|---|---|---|---|
| **standard** (mặc định) | Claude | Claude, Codex | Codex |
| **solo** | — | Claude | — (review Nhanh, bạn tự xem) |
| **large** | Claude | Claude, Codex, Claude, Codex | Codex |

Muốn chọn từng vai, sửa `.crew/config.json` (`"claude"`, `"codex"` hoặc `"none"`) rồi chạy `crew up`.

## Cấp review

Cấp review được ghi ở dòng đầu `context/HOT.md`.

- **Nhanh (fast):** worker typecheck và test phần mình. Rev không review, chỉ merge từng nhánh rồi chạy full test một lần.
- **Gọn (lean, mặc định):** worker như trên và ghi task note ≤15 dòng. Rev đọc `git diff main...<nhánh>` một lượt, tập trung vào chỗ nối giữa các nhánh và từng mục PITFALLS, merge, rồi chạy full test **một lần**.
- **Đủ (full):** review đầy đủ từng nhánh và chạy full test **tuần tự**. Nhánh sau rebase lên bản đã gộp, test e2e phải đi qua code thật. Kiểm cuối bằng full test và build.
- Gọn tự lên Đủ khi việc chạm vùng nhạy cảm, chạm interface dùng chung, hoặc có P0/P1. Có P0/P1 thì **dừng, không merge**.
- Tham khảo: Đủ tốn khoảng 44% quota Codex 5h cho một tính năng, Gọn khoảng 17%.

## Quyền agent

| Mức | Claude | Codex | Khi nào |
|---|---|---|---|
| **Làm việc** (work) | `--permission-mode acceptEdits` | `--sandbox workspace-write --ask-for-approval on-request` | mặc định; lệnh vượt quyền (kể cả `git commit`) vẫn hỏi |
| **Mở rộng** (wide) | `--permission-mode bypassPermissions` | `--sandbox danger-full-access --ask-for-approval never` | chỉ khi bạn ngồi xem tab |

Mức quyền (`access` của project) áp dụng cho planner, worker và Rev khi bật bằng `crew up` / `crew task`.

Nguyên tắc: thoáng bên trong worktree, chặt ở ranh giới (dữ liệu thật, bí mật, mạng, push). Agent không ai theo dõi thì không bao giờ chạy Mở rộng. Codex luôn chạy kèm `--no-daemon` để lệnh của nó nằm trong hc.

## Khi agent cần bạn

`crew hot` hoặc thanh bên của herdr-app sẽ hiện `blocked`:

- Hộp trust thư mục: Claude dùng `hc keys <tên> down enter`, Codex dùng `hc keys <tên> enter`. Chỉ hỏi lần đầu ở mỗi repo, vì worktree kế thừa trust.
- Duyệt lệnh: bấm trong tab, hoặc `hc keys <tên> enter`. Nếu hộp đang cuộn thì `ctrl+end` trước.
- Planner không bấm duyệt thay bạn.

## Cấu trúc repo

```
bootstrap.ps1          cài 1 dòng (Windows): kiểm git/pwsh, clone hoặc pull, chạy install.ps1
bootstrap.sh           cài 1 dòng (Linux/macOS): cài pwsh vào ~/.local nếu thiếu, clone/pull, chạy install.ps1
.github/workflows/     CI: Windows + Linux mỗi push/PR; macOS chạy tay (repo public: cả khi phát hành)
install.ps1            cài shim, template, jq, PATH, ~/.crewline/
tests/                 Pester 3.4; TestHome.ps1 = HOME/APPDATA giả cho test
scripts/crew.ps1       lệnh crew
skeleton/context/      khung chép vào project (README, PROJECT, HOT, PITFALLS, DECISIONS, PROGRESS, ROADMAP, MAP, roles/, tasks/, archive/)
templates/             template hc: crew-planner, crew-rev, crew-worker-claude, crew-worker-codex
PROMPT.md              prompt dán vào agent để nó cài và dựng crew giúp bạn
docs/herdr-windows.md  herdr-app + hc trên Windows khác tài liệu/bản Linux ở đâu
docs/herdr-unix.md     herdr-app + hc trên Linux/macOS: đường dẫn, PATH, phần chưa kiểm
```

Sửa vai trò hoặc PITFALLS dùng chung thì sửa trong `skeleton/`. Project đã `crew init` giữ bản riêng trong `context/` của nó.
