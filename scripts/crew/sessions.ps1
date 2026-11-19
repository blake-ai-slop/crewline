# ---------------- sổ phiên (.crew/sessions.json) ----------------
# Chỉ ghi điều crew tự biết: vai, loại agent, root, UUID crew tạo. KHÔNG đọc file sessions/history của agent.
# roles.<vai> = { agent; root; sessionId? }. codexRootRoles = các vai đã chạy Codex ở gốc từ lần cuối gốc chỉ có một vai Codex:
# `resume --last` lấy phiên mới nhất theo thư mục, nên còn dấu vết vai khác là không phân biệt được.
function Get-SessionsFile([string]$root) { Join-Path $root '.crew/sessions.json' }
function New-SessionBook { @{ Roles = @{}; CodexRootRoles = @(); Warning = '' } }
function Test-SessionId($id) { $id -is [string] -and $id -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }

# Thiếu file ⇒ sổ trống; JSON hỏng/schema mới ⇒ dừng trước mọi ghi.
function Read-SessionBook([string]$root) {
  $book = New-SessionBook
  $file = Get-SessionsFile $root
  if (-not (Test-Path -LiteralPath $file)) { return $book }
  $j = Read-CrewState $file
  if ($j -isnot [pscustomobject] -or $j.roles -isnot [pscustomobject]) { Die "$file hỏng — thiếu roles; sửa JSON hoặc khôi phục bản sao." "mở $file sửa JSON (hoặc khôi phục bản sao) rồi chạy lại lệnh crew" }
  $book.State = $j
  foreach ($p in $j.roles.PSObject.Properties) {
    $v = $p.Value
    if ($v -isnot [pscustomobject] -or $v.agent -isnot [string] -or $v.root -isnot [string]) { continue }
    $book.Roles[$p.Name] = $v
  }
  $book.CodexRootRoles = @($j.codexRootRoles | Where-Object { $_ -is [string] })
  $book
}

function Save-SessionBook([string]$root, $book) {
  $file = Get-SessionsFile $root
  $state = if (Test-Path -LiteralPath $file) { Read-CrewState $file } else { [pscustomobject]@{ version = 1 } }
  if ((Test-Path -LiteralPath $file) -and ($state -isnot [pscustomobject] -or $state.roles -isnot [pscustomobject])) { Die "$file hỏng — thiếu roles; sửa JSON hoặc khôi phục bản sao." "mở $file sửa JSON (hoặc khôi phục bản sao) rồi chạy lại lệnh crew" }
  $roles = [ordered]@{}
  if ($state.roles) { foreach ($p in $state.roles.PSObject.Properties) { $roles[$p.Name] = $p.Value } }
  foreach ($k in @($book.Roles.Keys | Sort-Object)) {
    $r = $book.Roles[$k]
    $o = [ordered]@{}
    if ($state.roles -and $state.roles.PSObject.Properties[$k]) {
      foreach ($p in $state.roles.$k.PSObject.Properties) { $o[$p.Name] = $p.Value }
    }
    $o.Remove('sessionId')
    if ($r -is [System.Collections.IDictionary]) { foreach ($key in $r.Keys) { $o[$key] = $r[$key] } }
    else { foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value } }
    $roles[$k] = $o
  }
  $state | Add-Member NoteProperty schema (Get-CrewStateSchema) -Force
  $state | Add-Member NoteProperty roles $roles -Force
  $state | Add-Member NoteProperty codexRootRoles @($book.CodexRootRoles) -Force
  try {
    Write-CrewStateFile $file (ConvertTo-Json -InputObject $state -Depth 100)
  } catch { Say "cảnh báo: không ghi được sổ phiên $file ($($_.Exception.Message)); lần khôi phục sau sẽ mở hội thoại mới." }
}

# Vai vừa bật hội thoại mới. Hội thoại mới của vai Codex duy nhất ở gốc là phiên mới nhất ở đó nên xóa được dấu vết vai cũ.
function Set-SessionRecord($book, [string]$root, $cfg, [string]$role, [string]$kind, $session) {
  $rec = @{ agent = $kind; root = $root }
  if ($session -and $session.Id) { $rec.sessionId = $session.Id }
  $book.Roles[$role] = $rec
  if ($role -notlike 'w*' -and $kind -eq 'codex') {
    $count = @(@($cfg.planner, $cfg.rev) | Where-Object { $_ -eq 'codex' }).Count
    $book.CodexRootRoles = if ($count -le 1) { @($role) } else { @(@($book.CodexRootRoles) + $role | Select-Object -Unique) }
  }
}

function Get-NewSessionPlan([string]$role, [string]$kind, [string]$reason, [bool]$warn = $false) {
  $session = if ($role -notlike 'w*' -and $kind -eq 'claude') { @{ Mode = 'new-id'; Id = [guid]::NewGuid().ToString() } } else { $null }
  @{ Resume = $false; Session = $session; Reason = $reason; Warn = $warn }
}

# Chọn phiên cho một vai sắp bật. $blocked khác rỗng ⇒ tình huống không khôi phục (-Restart), là lý do. Không ghi gì (DryRun dùng chung).
function Get-SessionPlan($book, [string]$root, $cfg, [string]$role, [string]$kind, [string]$blocked = '') {
  if ($blocked) { return Get-NewSessionPlan $role $kind $blocked }
  $rec = $book.Roles[$role]
  if (-not $rec) { return Get-NewSessionPlan $role $kind 'chưa có ghi nhận phiên' }
  if ($rec.agent -cne $kind) { return Get-NewSessionPlan $role $kind "đã đổi agent $($rec.agent) sang $kind" }
  if (-not (Test-SamePath $rec.root $root)) { return Get-NewSessionPlan $role $kind "sổ ghi root khác ($($rec.root))" }
  $resume = { param($mode, $id, $why) @{ Resume = $true; Session = @{ Mode = $mode; Id = $id }; Reason = $why; Warn = $false } }
  if ($role -like 'w*') {
    if ($kind -eq 'codex') { return & $resume 'resume-last' $null 'phiên Codex mới nhất của worktree' }
    return & $resume 'continue' $null 'phiên Claude mới nhất của worktree'
  }
  if ($kind -eq 'claude') {
    if (Test-SessionId $rec.sessionId) { return & $resume 'resume-id' $rec.sessionId "phiên $($rec.sessionId)" }
    return Get-NewSessionPlan $role $kind 'sổ không có id phiên hợp lệ' $true
  }
  $count = @(@($cfg.planner, $cfg.rev) | Where-Object { $_ -eq 'codex' }).Count
  if ($count -gt 1) { return Get-NewSessionPlan $role $kind 'hai vai Codex cùng chạy ở thư mục gốc, không phân biệt được phiên' $true }
  $others = @(@($book.CodexRootRoles) | Where-Object { $_ -cne $role })
  if ($others.Count -or @($book.CodexRootRoles) -cnotcontains $role) { return Get-NewSessionPlan $role $kind 'thư mục gốc từng có vai Codex khác, không phân biệt được phiên' $true }
  & $resume 'resume-last' $null 'vai Codex duy nhất ở thư mục gốc'
}

function Format-SessionPlan($plan) { "$(if ($plan.Resume) { 'mở lại hội thoại' } else { 'hội thoại mới' }) ($($plan.Reason))" }

# Màn hình đang là TUI của agent? Sau khi mở lại phiên mà chưa có lượt mới, hc có thể chưa báo status.app.
# Chân màn hình chỉ agent mới có; dòng cuối là dấu nhắc shell thì agent đã thoát dù chữ cũ còn trên màn hình.
function Test-AgentScreen([string]$kind, [string]$screen) {
  $last = @("$screen" -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\[hc\]' }) | Select-Object -Last 1
  if ("$last" -match '(^\s*PS .*>|[$#])\s*$') { return $false }
  # Codex: chân có thể không có 'Context N% left' (status_line của user, bị cắt '…') ⇒ nhận thêm đầu phiên, chân GPT-…/limit, gợi ý.
  if ($kind -eq 'codex') { return "$screen" -match 'Context \d+% left|>_ OpenAI Codex|(?m)^\s*GPT-\S+\s.*·|(?m)^\s*(5h|weekly) \d+% left|(?m)^\s*\? for shortcuts' }
  "$screen" -match '(accept edits|bypass permissions|auto mode|plan mode) on|shift\+tab to cycle'
}

# Trạng thái pane vừa mở lại phiên: 'ready' | 'exited' (CLI thoát, về shell) | 'dialog' (hộp thoại/chờ duyệt, không bấm) | '' (chưa rõ).
function Get-ResumeState([string]$term, [string]$kind, $ops) {
  $info = & $ops.Get $term
  if (-not $info) { return '' }
  if ($info.state -ne 'live') { return 'exited' }
  $screen = & $ops.Read $term
  if ((Get-TermStatus $info).State -eq 'blocked' -or (Get-ScreenDialog $screen)) { return 'dialog' }
  if ((Get-TermShellState $info { $screen }) -eq 'exited') { return 'exited' }
  $mode = (Get-WorkerMode $info $kind).Mode
  if ($mode -eq 'agent' -or ($mode -eq 'shell' -and (Test-AgentScreen $kind $screen))) { return 'ready' }
  ''
}

# Chờ các pane vừa mở lại phiên, tối đa ~30s, không gửi hay bấm phím. Trả map Term -> trạng thái cuối.
function Wait-ResumeStates($roles, $ops, [int]$tries = 15) {
  $out = @{}; $pending = @($roles)
  for ($i = 0; $i -lt $tries -and $pending.Count; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $next = @()
    foreach ($role in $pending) {
      $s = Get-ResumeState $role.Term $role.Kind $ops
      $out[$role.Term] = $s
      if (-not $s) { $next += $role }
    }
    $pending = $next
  }
  $out
}

# Terminal từ `hc ls --json`. Thành công rỗng (terminals: []) ⇒ @(); exit≠0, JSON hỏng hoặc thiếu mảng 'terminals' ⇒ throw
# (không bao giờ trả [] khi lỗi). Chỗ ra quyết định (up, repair) coi lỗi là dừng; chỗ hiển thị (hot, limits, gợi ý chuyển) chỉ cảnh báo.
function Get-LiveTerminals {
  $out = & { $ErrorActionPreference = 'Continue'; hc ls --json 2>$null }
  $code = $LASTEXITCODE
  if ($code -ne 0) { throw "hc ls --json lỗi (exit $code)" }
  $text = (@($out) -join "`n").Trim()
  try { $j = $text | ConvertFrom-Json } catch { throw "hc ls --json trả JSON hỏng (exit $code): $($_.Exception.Message)" }
  if ($null -eq $j -or $j -isnot [pscustomobject] -or $j.PSObject.Properties.Name -notcontains 'terminals') { throw "hc ls --json thiếu mảng 'terminals' (exit $code)" }
  # terminals phải là mảng JSON; từng phần tử phải có address/state (chuỗi khác rỗng) + name (chuỗi, null nếu chưa đặt tên).
  # Sai shape ⇒ ném lỗi, KHÔNG lọc thành rỗng (rỗng = "0 terminal" ⇒ repair sẽ đóng space còn terminal lạ).
  $arr = $j.terminals
  if ($arr -isnot [array]) { $kind = if ($null -eq $arr) { 'null' } else { $arr.GetType().Name }; throw "hc ls --json: 'terminals' không phải mảng ($kind, exit $code)" }
  for ($i = 0; $i -lt $arr.Count; $i++) {
    $t = $arr[$i]
    if ($t -isnot [pscustomobject]) { throw "hc ls --json: terminals[$i] không phải object (exit $code)" }
    $p = $t.PSObject.Properties.Name
    foreach ($k in 'address', 'state') { if ($p -notcontains $k -or $t.$k -isnot [string] -or -not $t.$k) { throw "hc ls --json: terminals[$i] thiếu/sai '$k' (exit $code)" } }
    # hc bỏ hẳn khóa name với terminal chưa đặt tên (mọi pane người dùng tự mở trong herdr) ⇒ coi như name = null.
    if ($p -notcontains 'name') { $t | Add-Member -NotePropertyName name -NotePropertyValue $null }
    elseif ($null -ne $t.name -and $t.name -isnot [string]) { throw "hc ls --json: terminals[$i] thiếu/sai 'name' (exit $code)" }
  }
  return @($arr)
}

# Terminal cùng tên còn live nhưng agent không còn trong đó? $info = object `hc get`; $read = scriptblock trả chữ màn hình (chỉ gọi khi cần).
# 'lost'   = shell PowerShell do core tạo lại, có marker __hc_prompt và không còn -EncodedCommand.
# 'exited' = crew bật nhưng agent đã thoát, pane còn shell của -NoExit.
# ''       = còn agent hoặc không chắc. status null KHÔNG đủ: Claude chưa qua lượt đầu cũng null, nên phải thấy dấu nhắc shell ở dòng cuối.
function Get-TermShellState($info, [scriptblock]$read) {
  if (-not $info -or $info.state -ne 'live') { return '' }
  $st = Get-TermStatus $info
  if ($st.App -or $st.State -eq 'blocked') { return '' }
  $argv = @($info.argv | Where-Object { $_ })
  if (-not $argv.Count) { return '' }
  # Chỉ tin shell PowerShell đã xác minh; foreground khác shell có thể là agent chưa báo status.
  $shellName = { param($exe) (([string]$exe -split '[\\/]')[-1] -replace '(?i)\.exe$', '') -in 'pwsh', 'powershell' }
  $foreground = @($info.foreground.argv | Where-Object { $_ })
  if ($foreground.Count -and -not (& $shellName $foreground[0])) { return '' }
  $encoded = $argv -contains '-EncodedCommand'
  # Chưa xác minh shell core sau reboot trên Linux/macOS: không tự tắt ở các hệ đó.
  if (-not $encoded -and $IsWindows -eq $false) { return '' }
  if (-not $encoded -and (-not (& $shellName $argv[0]) -or ($argv -join ' ') -notmatch '__hc_prompt')) { return '' }
  $last = @("$(& $read)" -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\[hc\]' }) | Select-Object -Last 1
  if ("$last" -notmatch '(^\s*PS .*>|[$#])\s*$') { return '' }
  if ($encoded) { return 'exited' }
  if ("$last" -notmatch '^\s*PS .*>\s*$') { return '' }
  'lost'
}

# Terminal của một vai đang chạy chính lệnh crew này (HC_TERMINAL_ID kế thừa qua shim và tiến trình con của -All). Không có biến/không khớp ⇒ $null.
function Get-SelfTerm($liveTerms, [string[]]$names) {
  if (-not $env:HC_TERMINAL_ID) { return $null }
  @($liveTerms | Where-Object { $_.address -ceq $env:HC_TERMINAL_ID -and $names -ccontains $_.name }) | Select-Object -First 1
}

# Pane đang chạy crew là gì, không đòi dòng cuối là dấu nhắc vì crew đang in. $info = object `hc get`.
# 'lost' = shell core (cùng argv với Get-TermShellState) | 'exited' = crew bật, agent đã thoát | 'unix-shell' = shell chưa xác minh trên Linux/macOS | '' = còn agent hoặc không chắc.
function Get-SelfPaneState($info, [bool]$windows = ($IsWindows -ne $false)) {
  if (-not $info -or $info.state -ne 'live') { return '' }
  $st = Get-TermStatus $info
  if ($st.App -or $st.State -in 'blocked', 'working') { return '' }
  $argv = @($info.argv | Where-Object { $_ })
  if (-not $argv.Count) { return '' }
  $exe = { param($x) ([string]$x -split '[\\/]')[-1] -replace '(?i)\.exe$', '' }
  # Crew đang chạy nên foreground có thể là shell hoặc chính các lệnh crew gọi; thứ khác có thể là agent chưa báo status.
  $foreground = @($info.foreground.argv | Where-Object { $_ })
  if ($foreground.Count -and (& $exe $foreground[0]) -notin 'pwsh', 'powershell', 'hc', 'git', 'herdr-app', 'bash', 'sh', 'zsh', 'fish') { return '' }
  if ($argv -contains '-EncodedCommand') { return 'exited' }
  if (-not $windows) { return 'unix-shell' }
  if ((& $exe $argv[0]) -in 'pwsh', 'powershell' -and ($argv -join ' ') -match '__hc_prompt') { return 'lost' }
  ''
}

# Id herdr của crew từ khóa id (Get-CrewIdKey) — không tự bỏ ký tự nào nữa.
function Get-Ids([string]$k) {
  return @{ Space = "spcrew$k"; Planner = "tbcrew${k}planner"; Rev = "tbcrew${k}rev"; Workers = { param($n) "tbcrew${k}workers$n" }.GetNewClosure() }
}

# Chạy một chương trình trong pwsh (giữ shell khi chương trình thoát) thành terminal hc có tên, gắn vào tab herdr.
function Start-Term([string]$name, [string]$cwd, [string]$space, [string]$tab, [string]$cmdline) {
  $argv = @('run', '--bg', '--json', '--name', $name, '--keep', '--outlive-parent', '--no-parent', '--no-notify',
    '--cwd', $cwd, '--label', "herdr.space=$space", '--label', "herdr.tab=$tab", '--', 'pwsh', '-NoLogo')
  if ($cmdline) {
    # crew up chạy từ pane agent có thể truyền biến phiên cha; Claude thấy CLAUDE_CODE_CHILD_SESSION thì không lưu transcript nên không resume được.
    $clean = "foreach (`$v in 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN') { Remove-Item `"Env:`$v`" -ErrorAction Ignore }; "
    # Gợi ý câu kế tiếp (chữ mờ) của Claude Code nằm trong ô nhập, hc read không có màu ⇒ crew tưởng tin kẹt; chỉ tắt trong pwsh của pane này.
    $clean += "`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'; "
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clean + $cmdline))
    $argv += @('-NoExit', '-EncodedCommand', $enc)
  }
  $out = hc @argv
  if ($LASTEXITCODE -ne 0) { Die "không bật được $name : $out" 'kiểm hc còn chạy: hc ls (lỗi ⇒ mở lại herdr-app), rồi chạy lại: crew up' }
  $r = $out | ConvertFrom-Json
  # chờ herdr-app nhận terminal để tab/pane hiện đúng thứ tự
  for ($i = 0; $i -lt 40; $i++) {
    $ls = Get-HerdrSpaces
    if (-not $ls.Ok) { throw $ls.Error }
    if ($ls.spaces.tabs.terminals.terminal -contains $r.address) { break }
    Start-Sleep -Milliseconds 250
  }
  return $r
}

function Wait-Tab([string]$tab) {
  for ($i = 0; $i -lt 40; $i++) {
    $ls = Get-HerdrSpaces
    if (-not $ls.Ok) { throw $ls.Error }
    foreach ($sp in $ls.spaces) { foreach ($t in $sp.tabs) { if ($t.id -eq $tab) { return $true } } }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

# ---------------- worker giữ phiên ----------------
# Worktree cố định của worker N — chỗ DUY NHẤT dựng đường dẫn này (up/task/clean/hot đều gọi).
function Get-WorkerTree([string]$root, [int]$n) {
  [IO.Path]::GetFullPath((Join-Path $root ".crew/worktrees/w$n"))
}

# Nhánh chính = nhánh hiện tại của repo chính. Detached HEAD ⇒ Die.
function Get-MainBranch([string]$root) {
  $b = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
  if (-not $b) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD) — checkout nhánh chính trước." "git -C '$root' switch <nhánh chính>, rồi chạy lại lệnh crew" }
  $b
}

# Đảm bảo worktree của worker N tồn tại (tạo detached tại nhánh chính khi thiếu). Trả đường dẫn.
function Initialize-WorkerTree([string]$root, [int]$n, [string]$main) {
  $wt = Get-WorkerTree $root $n
  $listed = Test-WorktreeListed $root $wt
  if ($listed -and (Test-Path -LiteralPath $wt)) { return $wt }
  if ($listed) { Invoke-GitOrDie 'git worktree prune' -C $root worktree prune | Out-Null }
  Say "git worktree add --detach $wt $main"
  Invoke-GitOrDie "tạo worktree w$n" -Next "git -C '$root' worktree prune; còn thư mục $wt không phải worktree thì kiểm rồi xóa nó; sau đó chạy lại lệnh crew" -C $root worktree add -q --detach $wt $main | Out-Null
  $wt
}

# Kill + gỡ một terminal hc (để bật lại cùng tên).
function Stop-Term([string]$address) {
  hc kill $address | Out-Null
  & { $ErrorActionPreference = 'Continue'; hc rm $address 2>&1 } | Out-Null
}

# Hàm thuần: giá trị -Restart ⇒ danh sách vai ('planner' | 'rev' | 'w<N>'). Sai ⇒ throw nêu giá trị cho phép.
function Get-RestartTargets([string]$value, [int]$workers, [bool]$planner, [bool]$rev) {
  $all = @()
  if ($planner) { $all += 'planner' }
  $all += @(1..$workers | ForEach-Object { "w$_" })
  if ($rev) { $all += 'rev' }
  $v = "$value".Trim().ToLower()
  if ($v -eq 'all') { return $all }
  if ($all -cnotcontains $v) { throw "-Restart phải là: $(($all + 'all') -join ', ') (nhận '$value')." }
  $v
}

# Danh sách file từ `git status --porcelain` (Invoke-GitQuiet đã Trim nên dòng đầu có thể mất khoảng trắng đầu).
function Format-DirtyFiles([string]$porcelain) {
  @($porcelain -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_ -replace '^\s*\S{1,2}\s+', '' }) -join ', '
}

function Get-WorkerStartLine([int]$n) {
  "Bạn là worker w$n của crew này. Đọc context/README.md rồi context/roles/worker.md; chờ planner giao task."
}

# Bật agent của worker N ngay trong worktree cố định (cờ quyền theo access).
function Start-WorkerTerm([string]$root, $cfg, $ids, [string]$slug, [int]$n, [string]$main, $session = $null) {
  $kind = @($cfg.workers)[$n - 1]
  $wt = Initialize-WorkerTree $root $n $main
  $tab = & $ids.Workers ([math]::Ceiling($n / 2))
  Start-Term "$slug-w$n" $wt $ids.Space $tab (Get-AgentCommand $kind $cfg.access (Get-WorkerStartLine $n) $session)
}

function Add-Block([string]$file, [string]$block) {
  if (Test-Path $file) {
    if ((Get-Content $file -Raw) -match '<!-- crew -->') { Say "$(Split-Path $file -Leaf) đã có khối crew, bỏ qua."; return }
    Copy-Item $file "$file.bak-$Today"
    Say "sao lưu $(Split-Path $file -Leaf) -> $(Split-Path $file -Leaf).bak-$Today, nối khối crew."
    Add-Content $file "`n$block" -Encoding utf8
  } else {
    Say "tạo $(Split-Path $file -Leaf) với khối crew."
    Set-Content $file $block -Encoding utf8
  }
}
