# ---------------- send / review ----------------
# Trạng thái terminal: `hc get --json` trả status = {app; state}, `hc ls` trả chuỗi. Ra @{ App; State }.
function Get-TermStatus($info) {
  $st = if ($info) { $info.status } else { $null }
  if ($st -is [string]) { return @{ App = $null; State = $st } }
  if ($st) { return @{ App = $st.app; State = $st.state } }
  return @{ App = $null; State = $null }
}

# Hàm thuần quyết định bước gửi (không gọi hc). $info = object `hc get`; $result = object `hc send --json`
# ($null = chưa gửi); $turnBefore = turn trước khi gửi (-1 = không rõ).
# Ra: 'dead' | 'blocked' | 'send' (chưa gửi, gửi được) | 'ok' | 'press-enter'.
function Get-SendPlan($info, $result, [int]$turnBefore = -1) {
  if (-not $info -or $info.state -ne 'live') { return 'dead' }
  $st = Get-TermStatus $info
  if ($st.State -eq 'blocked') { return 'blocked' }
  if ($null -eq $result) { return 'send' }
  # shell không báo working/turn: hc send thành công là xong
  if (-not $st.App) { return 'ok' }
  if ($result.started -eq $true -or $st.State -eq 'working') { return 'ok' }
  if ($turnBefore -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turnBefore) { return 'ok' }
  return 'press-enter'
}

function Get-TermInfo([string]$term) {
  $out = & { $ErrorActionPreference = 'Continue'; hc get $term --json 2>$null }
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  try { return (@($out) -join "`n") | ConvertFrom-Json } catch { return $null }
}

# Các lệnh hc thật mà Invoke-SendFlow dùng. Test tiêm bảng giả cùng khóa (Get/Send/Keys/Read/Sleep), không gọi hc.
# Send($term, $text, $raw): $raw = gửi trần, không bọc <hc from=…>.
function New-HcOps {
  @{
    Get   = { param($term) Get-TermInfo $term }
    Send  = {
      param($term, $text, $raw)
      $saved = @{ Id = $env:HC_TERMINAL_ID; Socket = $env:HC_TERMINAL_SOCKET }
      try {
        # gửi từ pane agent thì hc bọc <hc from=…> ⇒ shell ParserError, /clear|/new thành câu chat; $raw ⇒ để trống 2 biến chỉ cho lệnh này
        if ($raw) { $env:HC_TERMINAL_ID = $null; $env:HC_TERMINAL_SOCKET = $null }
        $out = & { $ErrorActionPreference = 'Continue'; hc send $term $text --json 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
      } finally { $env:HC_TERMINAL_ID = $saved.Id; $env:HC_TERMINAL_SOCKET = $saved.Socket }
      @{ Code = $code; Text = (@($out) -join "`n").Trim() }
    }
    Keys  = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term enter 2>&1 } | Out-Null }
    Tab   = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term tab 2>&1 } | Out-Null }
    # Space: CHỈ dùng trong Test-GhostInput (phép thử gõ 1 phím, không có phím xóa). Trả $true khi hc keys thành công.
    Space = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term space 2>&1 } | Out-Null; $LASTEXITCODE -eq 0 }
    Read  = { param($term) (@(& { $ErrorActionPreference = 'Continue'; hc read $term --lines 15 2>$null }) -join "`n") }
    Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
  }
}

# Codex đang working: Enter của hc send có lúc bị nuốt, tin nằm ở ô nhập dù hc báo started:true (đo thật 2026-11-02, codex-cli 0.166).
# Hàm thuần: ô nhập có ĐÚNG và CHỈ tin vừa gửi? Chỉ bỏ qua khoảng trắng tại chỗ xuống dòng của TUI, phân biệt hoa thường.
# $bare = tin gửi trần ⇒ không chấp nhận vỏ <hc from=…>; tin thường có thể có hoặc không có vỏ (hc chỉ bọc khi gửi từ pane agent), vỏ chỉ bỏ một lớp bọc kín cả ô.
function Test-SentInput([string[]]$lines, [string]$text, [bool]$bare = $false) {
  $want = "$text".Trim()
  if (-not $want -or -not @($lines).Count) { return $false }
  $same = {
    param($part)
    $want -cmatch ('^' + (@($part -split "`n" | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '\s*') + '$')
  }
  $raw = @($lines) -join "`n"
  if (& $same $raw) { return $true }
  if ($bare) { return $false }
  $m = [regex]::Match($raw, '^<hc\s+from="[^"]*">(.*)</hc>$', 'Singleline')
  $m.Success -and (& $same $m.Groups[1].Value)
}

# ---- So màn hình trước/sau khi dán (v16): không phụ thuộc chữ chân/gợi ý/cảnh báo của từng bản agent ----
# Dòng màn hình để so: bỏ BOM, dòng '[hc] …', khoảng trắng cuối (kể cả NBSP sau '❯' của Claude 2.1.329), dòng trống cuối.
function Get-ScreenRows([string]$screen) {
  [string[]]$rows = @(("$screen" -replace '^﻿', '') -split '\r?\n' | Where-Object { $_ -notmatch '^\[hc\]' } | ForEach-Object { $_.TrimEnd() })
  $n = $rows.Count - 1
  while ($n -ge 0 -and -not $rows[$n]) { $n-- }
  if ($n -lt 0) { return , [string[]]@() }
  , [string[]]$rows[0..$n]
}

# Hàm thuần: ô nhập chung cho Claude/Codex, chỉ dựa vào ký tự đầu ô '›'/'❯' gần cuối màn hình (không đọc chữ chân).
# Ô = dòng '›|❯ …' cuối cùng (không phải dòng chọn số '› 1.') + các dòng nối thụt ≥2. Dưới ô (Tail) chỉ được là chân/gợi ý/cảnh báo:
# ≤6 dòng có chữ, không dòng hội thoại (› ❯ • ● ⏺ └ ■ ↳ ✻, Worked for), không dòng chọn số. Không đạt ⇒ $null.
# Dialog = Tail có dấu hiệu hộp thoại (cùng danh sách Get-ScreenDialog). Ra @{ Start; End; Lines; Text; Char; Tail; Dialog }.
function Find-PromptBox([string[]]$rows) {
  $rows = @($rows)
  $i = $rows.Count - 1
  while ($i -ge 0 -and $rows.Count - 1 - $i -le 40 -and -not ($rows[$i] -match '^\s*[›❯](\s|$)' -and $rows[$i] -notmatch '^\s*[›❯]\s*\d+\.\s')) { $i-- }
  if ($i -lt 0 -or $rows.Count - 1 - $i -gt 40) { return $null }
  $e = $i
  while ($e + 1 -lt $rows.Count -and $rows[$e + 1] -match '^\s{2,}\S' -and $e - $i -lt 30) { $e++ }
  $tail = if ($e + 1 -lt $rows.Count) { @($rows[($e + 1)..($rows.Count - 1)]) } else { @() }
  $filled = @($tail | Where-Object { $_.Trim() })
  if ($filled.Count -gt 6) { return $null }
  if (@($filled | Where-Object { $_ -match '^\s*([›❯•●⏺└■↳✻]|─ Worked for|Worked for |\d+\.\s)' }).Count) { return $null }
  $marks = 'Where should the new conversation run', 'Do you want to', 'Allow command', '^\s*Allow\b', '\(y/n\)', 'enter select', 'esc back',
    'Esc to cancel', 'Yes, proceed', 'Trust this folder', 'trust this folder'
  $dialog = [bool]@($filled | Where-Object { $l = $_; @($marks | Where-Object { $l -match $_ }).Count }).Count
  $char = ([regex]::Match($rows[$i], '[›❯]')).Value
  [string[]]$lines = @(($rows[$i] -replace '^\s*[›❯]\s*', '').Trim())
  if ($e -gt $i) { $lines += @($rows[($i + 1)..$e] | ForEach-Object { $_.Trim() }) }
  if (-not $lines[0] -and $lines.Count -eq 1) { $lines = @() }
  @{ Start = $i; End = $e; Lines = $lines; Text = ($lines -join ' ').Trim(); Char = $char; Tail = $tail; Dialog = $dialog }
}

# Hai dòng phía trên ô nhập coi là như nhau: giống hệt, hoặc cả hai là dòng hay đổi và chỉ khác số / chữ spinner.
# Dòng hay đổi (liệt kê, có test CrewPasteVerify): '% left' (5h/weekly/Context, ⚠ limit), đồng hồ h:mm, thời gian chạy '(12s', '3m 41s',
# 'esc to interrupt', 'tokens', 'N warnings'; dòng spinner/trạng thái Claude-Codex ('✻ Baked for 18s · done 4:43 PM', '✶ Pondering… (…)',
# '• Working (…)'): cả hai cùng là dòng spinner thì coi như nhau dù chữ động từ khác.
function Test-SameScreenRow([string]$a, [string]$b) {
  if ($a -ceq $b) { return $true }
  $spin = '^\s*(?:[✻✽✶✳✢✺·*]\s+\S+(?:…|\s+for\s+\d)|•\s+Working\s+\()'
  if ($a -match $spin -and $b -match $spin) { return $true }
  $vol = '\d+% left|\b\d{1,2}:\d{2}\b|\(\d+[smh]\b|\b\d+m \d+s\b|esc to interrupt|\d+(\.\d+)?[kK]? tokens|\d+ warnings?'
  if ($a -match $vol -and $b -match $vol) { return (($a -replace '\d+', '#') -ceq ($b -replace '\d+', '#')) }
  $false
}

# Hàm thuần (hợp đồng v16, ghost-key dùng lại): tin vừa dán có nằm đúng ô nhập không, so màn hình trước/sau khi dán.
# Đạt khi: sau dán có ô nhập gần cuối (Find-PromptBox) mà nội dung ĐÚNG và CHỈ tin vừa dán (Test-SentInput: cho gói dòng, thụt dòng nối,
# vỏ <hc from> nếu không $bare), dưới ô không có dấu hộp thoại, trước dán cũng có ô, ô đã đổi, và KHÔNG có dòng mới nào ngoài khối ô:
# - phía trên ô: so từ dưới lên, bỏ dòng trống (dòng hay đổi theo Test-SameScreenRow); dòng nào của màn sau không so được theo vị trí
#   (mép cuộn: Codex 0.171 hc read ghép dòng đầu khác khi ô dài thêm; hay màn sau dài hơn) phải có y hệt ở màn trước;
#   hoặc màn sau chỉ MẤT dòng (phía trên ô là dãy con đúng thứ tự của màn trước);
# - dưới ô: mỗi dòng có chữ phải có ở dưới ô màn trước (chân/gợi ý được MẤT — Codex 0.171 ẩn '← for agents · ? for shortcuts' khi ô có chữ,
#   Claude 2.1.329 bỏ mục cuối ' · ← for agents' của dòng chân — không được THÊM).
# Ra @{ Ok; Reason; Box = các dòng ô nhập sau dán; Kind = 'codex' (ô '›') | 'claude' (ô '❯') | '' (không thấy ô) } — người gọi đối chiếu Kind với app.
# Reason: ok | no-box | empty | text-mismatch | dialog | no-box-before | unchanged | above-changed | below-changed | no-context.
function Compare-PasteScreens([string]$before, [string]$after, [string]$text, [bool]$bare = $false) {
  $kind = ''
  $out = { param($ok, $why, $box) @{ Ok = $ok; Reason = $why; Box = [string[]]@($box); Kind = $kind } }
  $A = Get-ScreenRows $after
  $pa = Find-PromptBox $A
  if ($pa) { $kind = if ($pa.Char -eq '›') { 'codex' } else { 'claude' } }
  if (-not $pa) { return & $out $false 'no-box' @() }
  if (-not $pa.Text) { return & $out $false 'empty' @() }
  if (-not (Test-SentInput $pa.Lines $text $bare)) { return & $out $false 'text-mismatch' $pa.Lines }
  if ($pa.Dialog) { return & $out $false 'dialog' $pa.Lines }
  $B = Get-ScreenRows $before
  $pb = Find-PromptBox $B
  if (-not $pb) { return & $out $false 'no-box-before' $pa.Lines }
  if (($pb.Lines -join "`n") -ceq ($pa.Lines -join "`n")) { return & $out $false 'unchanged' $pa.Lines }
  # dòng cảnh báo ⚠ ghi cứng của Codex (limit/warnings, căn phải nhiều khoảng trắng — thấy thật 0.171: tests/fixtures/codex-v0.171/warn-rightaligned.txt)
  # hiện/ẩn/tách khỏi dòng gợi ý theo lúc vẽ ⇒ không tính là dòng mới/mất, cả trên lẫn dưới ô. Mẫu lấy từ danh sách đóng của Get-SendBox.
  $warnRow = { param($l) $l.Trim().StartsWith('⚠') -and (Get-SendBox '' 'codex' $l) }
  $up = { param($rows, $end) if ($end -le 0) { return , @() }; , @($rows[0..($end - 1)] | Where-Object { $_.Trim() -and -not (& $warnRow $_) }) }
  $ua = & $up $A $pa.Start
  $ub = & $up $B $pb.Start
  $k = [math]::Min($ua.Count, $ub.Count)
  if (-not $k) { return & $out $false 'no-context' $pa.Lines }
  $d = 1
  while ($d -le $k -and (Test-SameScreenRow $ua[$ua.Count - $d] $ub[$ub.Count - $d])) { $d++ }
  # còn lại của màn sau (từ chỗ lệch lên tới đầu): chỉ chấp nhận khi chỉ là mép cuộn — đúng 1 dòng trên cùng và dòng đó có y hệt ở màn trước
  $rest = @(if ($d -le $ua.Count) { $ua[0..($ua.Count - $d)] })
  if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $B -cnotcontains $rest[0])) {
    # chỉ MẤT dòng phía trên ô (Codex 0.171 phiên mới: logo động biến mất khi ô có chữ; crew probe): các dòng của màn sau phải là
    # dãy con ĐÚNG THỨ TỰ của màn trước — dòng mới, hay dòng cũ hiện lại ở chỗ khác (hộp vẽ trên ô), vẫn là above-changed
    $j = 0
    foreach ($row in $ua) {
      while ($j -lt $ub.Count -and -not (Test-SameScreenRow $row $ub[$j])) { $j++ }
      if ($j -ge $ub.Count) { return & $out $false 'above-changed' $pa.Lines }
      $j++
    }
  }
  $tb = @($pb.Tail | Where-Object { $_.Trim() })
  foreach ($row in @($pa.Tail | Where-Object { $_.Trim() -and -not (& $warnRow $_) })) {
    # dòng chân chỉ MẤT mục cuối ' · …' (Claude 2.1.329 accept edits: '… (shift+tab to cycle) · ← for agents' mất '· ← for agents' khi ô có chữ) ⇒ vẫn là mất, không thêm
    if (-not @($tb | Where-Object { (Test-SameScreenRow $row $_) -or $_.StartsWith($row + ' · ', [StringComparison]::Ordinal) }).Count) { return & $out $false 'below-changed' $pa.Lines }
  }
  & $out $true 'ok' $pa.Lines
}

# Ô nhập cho các bước gửi: Get-InputBox (mẫu chữ đã biết) trước; không nhận ra ⇒ Find-PromptBox (chỉ dựa ký tự đầu ô, Tail sạch, không hộp).
# Placeholder đã biết 'Ask Codex to do anything' / 'Try "…"' (Claude phiên mới) tính là ô trống. Ra @{ Kind; Text; Lines; Generic; KnownTail } hoặc $null.
# KnownTail (v16 knowntail-fix): ô nhận bằng mẫu chữ cũ (Get-InputBox) và TỪNG dòng từ ngay dưới ô (Claude: dưới đường kẻ đóng; Codex: từ dòng
# trống đóng ô) tới hết màn, sau khi trim, KHỚP TOÀN DÒNG một mẫu trong danh sách đóng bên dưới (hoặc trống). Lối Find-PromptBox luôn $false.
# Mọi phím KHÔNG phải tin (Tab hàng đợi Codex, Space ghost-key) đòi KnownTail. Danh sách mẫu chỉ ở đây; nơi khác hỏi qua
# Get-SendBox -rowKind 'claude'|'codex' -row '<dòng>' (ra $true/$false) — vd. Compare-PasteScreens bỏ qua dòng ⚠ ghi cứng.
function Get-SendBox([string]$screen, [string]$rowKind = '', [string]$row = '') {
  # Danh sách đóng (neo ^…$ trên dòng đã trim). Chân có thể bị cắt ở mục cuối: '<đầu mục>…' chỉ nhận khi là đầu của một mục đã biết (số chuẩn hóa).
  $warn = '⚠ (?:(?:5h|weekly) limit: \d+% left(?: · resets at \d{1,2}:\d{2} (?:AM|PM)(?: on \d{1,2} [A-Za-z]{3})?)?(?: · /status)?|\d+ warnings? · f2 to view)'
  $known = @{
    claude = @{
      Rows = @('^\? for shortcuts$',
        '^(?:Opus|Sonnet|Haiku|Fable) \d+(?:\.\d+)? - (?:low|medium|high|xhigh|max) - (?:\d+%|-)$')
      Head = '^(?:[⏵⏸]+ )?(?:bypass permissions|accept edits|auto mode|plan mode) on(?: \(shift\+tab to cycle\))?'
      Segs = @('← for agents', '\d+ background tasks?', '\d+ shells?', '↓ to view')
      Cut  = @('← for agents', '0 background tasks', '0 shells', '↓ to view')
      Free = $null
    }
    codex = @{
      Rows = @("^(?:esc to interrupt · )?(?:← for agents · )?(?:\? for shortcuts|tab to queue message)(?:\s{2,}$warn)?$", "^$warn$")
      Head = '^GPT-[\w.]+(?:-[\w.]+)* (?:minimal|low|medium|high|xhigh|max)'
      Segs = @('(?:5h|weekly) \d+% left', 'Context:? \d+% left', '(?:~|[A-Za-z]:)(?:[\\/][^\s·]*)*',
        '\d+(?:\.\d+)?[KkM]?(?: tokens)? used')
      Cut  = @('5h 0% left', 'weekly 0% left', 'Context 0% left', 'Context: 0% left', '0K used', '0 tokens used')
      # tên luồng do Codex vẽ trong chân (thấy thật: queue-wrap '… · Đọc vai trò rev và chờ giao việc · …'): đúng tối đa 1 đoạn tự do, chỉ khi có đầu GPT-,
      # chỉ sau đầu/đường dẫn và TRƯỚC mục số (5h/weekly/Context/used); không ở cuối, không sau mục số (knowntail-fix2, planner chọn B).
      # Giới hạn đã biết: chèn ' · <chữ> · ' giữa đường dẫn và mục số không phân biệt được với tên luồng thật.
      Free = '^[^·⚠›❯<>()\[\]{}?|…]{1,60}$'
      Pre  = '(?:~|[A-Za-z]:)(?:[\\/][^\s·]*)*'
      # mảnh mục số (không phân biệt hoa thường, dính liền/cách): tên luồng chứa mảnh này ⇒ không phải chân
      Frag = '\d\s*%|%\s*left|context|5h|weekly|\d\s*[km]?\s*(?:tokens\s*)?used'
    }
  }
  $isKnown = {
    param([string]$kind, [string]$line)
    $t = $line.Trim()
    if (-not $t) { return $true }
    $k = $known[$kind]
    if (-not $k) { return $false }
    foreach ($p in $k.Rows) { if ($t -cmatch $p) { return $true } }
    # chân: [đầu] (' · ' mục)*; Codex không đầu GPT- vẫn nhận khi mọi mục là mục số đã biết (status line bị bỏ model)
    $m = [regex]::Match($t, $k.Head)
    $rest = $t
    $hasHead = $m.Success
    if ($hasHead) { $rest = $t.Substring($m.Length); if (-not $rest) { return $true }; if (-not $rest.StartsWith(' · ')) { return $false }; $rest = $rest.Substring(3) }
    elseif ($kind -ne 'codex') { return $false }
    $segs = @($rest -split ' · ')
    $free = -1; $num = $false
    for ($i = 0; $i -lt $segs.Count; $i++) {
      $s = $segs[$i]
      if (@($k.Segs | Where-Object { $s -cmatch "^(?:$_)$" }).Count) {
        # đường dẫn (Pre) không tính là mục số; mục số khác chốt vùng tự do
        if (-not ($k.Pre -and $s -cmatch "^(?:$($k.Pre))$")) { $num = $true }
        continue
      }
      if ($i -eq $segs.Count - 1 -and $s.EndsWith('…')) {
        $c = ($s.Substring(0, $s.Length - 1)) -replace '\d+', '#'
        if (@($k.Cut | Where-Object { ($_ -replace '\d+', '#').StartsWith($c, [StringComparison]::Ordinal) }).Count) { $num = $true; continue }
      }
      # đoạn tự do: 1 lần, trước mọi mục số, không ở cuối (sau nó phải có mục số — kiểm ở cuối vòng)
      # đoạn bắt đầu bằng một mục đã biết + hậu tố dính ('Context 97% left Xác nhận…') không phải tên luồng
      # và không chứa mảnh nào giống mục số ở BẤT KỲ vị trí, dính liền hay cách (Rev: 'Context 97% leftXác…') — đoạn đó phải khớp toàn đoạn mục số
      $stuck = @($k.Segs | Where-Object { $s -cmatch "^(?:$_)\s" }).Count -or ($k.Frag -and $s -match $k.Frag)
      if ($hasHead -and $k.Free -and $free -lt 0 -and -not $num -and -not $stuck -and $i -lt $segs.Count - 1 -and $s -cmatch $k.Free) { $free = $i; continue }
      return $false
    }
    if ($free -ge 0 -and -not $num) { return $false }
    $true
  }
  if ($rowKind) { return [bool](& $isKnown $rowKind $row) }
  $box = Get-InputBox $screen
  if ($box) {
    # dòng dưới ô: Claude = After (dưới đường kẻ đóng). Codex = từ dòng trống đầu tiên sau dòng '›' cuối (ô Codex không có dòng trống giữa) tới hết.
    $tail = if ($box.Kind -eq 'claude') { @("$($box.After)" -split '\r?\n') } else {
      [string[]]$rows = Get-ScreenRows $screen
      $p = $rows.Count - 1
      while ($p -ge 0 -and -not ($rows[$p] -match '^\s*›(\s|$)' -and $rows[$p] -notmatch '^\s*›\s*\d+\.\s')) { $p-- }
      $q = $p + 1
      while ($q -lt $rows.Count -and $rows[$q].Trim()) { $q++ }
      if ($p -lt 0) { @('?') } elseif ($q -lt $rows.Count) { @($rows[$q..($rows.Count - 1)]) } else { @() }
    }
    $ok = -not @($tail | Where-Object { -not (& $isKnown $box.Kind $_) }).Count
    return @{ Kind = $box.Kind; Text = $box.Text; Lines = $(if ($box.Lines) { @($box.Lines) } else { @($box.Text) }); Generic = $false; KnownTail = [bool]$ok }
  }
  $pb = Find-PromptBox (Get-ScreenRows $screen)
  if (-not $pb -or $pb.Dialog) { return $null }
  $t = $pb.Text
  if ($t -eq 'Ask Codex to do anything' -or ($pb.Char -eq '❯' -and $t -match '^Try ".*"$')) { return @{ Kind = $(if ($pb.Char -eq '›') { 'codex' } else { 'claude' }); Text = ''; Lines = @(); Generic = $true; KnownTail = $false } }
  @{ Kind = $(if ($pb.Char -eq '›') { 'codex' } else { 'claude' }); Text = $t; Lines = @($pb.Lines); Generic = $true; KnownTail = $false }
}

# Ô nhập đúng và chỉ có tin vừa gửi (Test-SentInput) ⇒ Tab 1 lần để vào hàng đợi thật của Codex: Tab gửi cả ô, nên chữ thêm, chữ sửa, bản nháp cùng đầu tin ⇒ không bấm.
# Đọc lại màn hình + trạng thái ngay trước phím; không live, không phải Codex, hết working, blocked, hộp thoại ⇒ không bấm.
# Tin dài gói nhiều dòng và có dòng trống cuối ô (Enter bị đổi thành xuống dòng) vẫn nhận qua Get-InputBox; khối queued phía trên không ảnh hưởng.
# v16: nhận ô qua Get-SendBox; hộp thoại vẫn theo Get-ScreenDialog (kể cả 'other').
# v16 assist-nolearn (đổi hành vi có chủ ý, planner chốt): Tab chỉ khi dưới ô toàn dòng ghi cứng đã biết (KnownTail). Chân/dòng lạ (vd. hộp
# không đánh số dưới chân) ⇒ 0 phím, kết quả không chắc mang Assist ⇒ khối CẦN PLANNER XEM; Codex xong lượt mà tin còn ở ô ⇒ crew confirm.
function Send-CodexQueue([string]$term, [string]$text, $ops, [bool]$bare = $false) {
  $unsure = @{ Ok = $true; Unsure = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin có thể nằm lại ô nhập, xem crew hot" }
  if (-not $ops.Read -or -not $ops.Tab) { return $unsure }
  # tin dài: TUI có thể chưa vẽ xong ô nhập ở lần đọc đầu ⇒ đọc lại tối đa 3 lần; MỖI lần kiểm lại trạng thái + hộp thoại, Tab ngay sau lần đọc khớp
  $match = $false
  for ($k = 0; $k -lt 3 -and -not $match; $k++) {
    & $ops.Sleep $(if ($k) { 500 } else { 700 })
    $screen = & $ops.Read $term
    $info = & $ops.Get $term
    $st = Get-TermStatus $info
    if (-not $info -or $info.state -ne 'live' -or $st.App -ne 'codex' -or $st.State -ne 'working' -or (Get-ScreenDialog $screen)) { return $unsure }
    $box = Get-SendBox $screen
    if ($box -and $box.Kind -eq 'codex' -and -not $box.Text) { return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: Codex đang bận đã nhận tin khỏi ô nhập (xem: crew hot)" } }
    $match = $box -and $box.Kind -eq 'codex' -and (Test-SentInput $box.Lines $text $bare)
    if ($match -and -not $box.KnownTail) {
      $unsure.Message = "đã gửi -> $term nhưng Codex đang bận và dưới ô nhập có dòng lạ — không bấm Tab (0 phím); tin có thể nằm lại ô nhập. Codex xong lượt mà tin còn trong ô: crew confirm $term"
      $unsure.Assist = 'queue-unknown-tail'; $unsure.Why = 'dòng lạ dưới ô nhập, Codex đang bận'; $unsure.Screen = "$screen"
      return $unsure
    }
  }
  if (-not $match) { return $unsure }
  & $ops.Tab $term
  for ($i = 0; $i -lt 3; $i++) {
    & $ops.Sleep 500
    $after = Get-SendBox (& $ops.Read $term)
    if ($after -and $after.Kind -eq 'codex' -and -not $after.Text) {
      return @{ Ok = $true; Queued = $true; Message = "đã gửi -> ${term}: tin vào hàng đợi của Codex, chạy khi xong lượt (xem: crew hot)" }
    }
  }
  $unsure
}

# Điều phối gửi tin (không Die, không in): trả @{ Ok; Message }.
# Đọc lại hc get NGAY SAU send và NGAY TRƯỚC MỖI lần Enter; blocked/dead ⇒ dừng, không Enter (Enter có thể duyệt hộ hộp duyệt).
# $session = 'claude'|'codex' khi gửi /clear|/new: chỉ coi là xong khi Test-SessionReady (đọc màn hình qua $ops.Read);
# agent đang chạy lệnh thì chờ, không Enter. Màn hình có hộp thoại: ĐÚNG hộp chọn Codex /new ⇒ Enter 1 lần (chọn worktree
# hiện tại), hộp khác ⇒ dừng, không Enter. $tries = số vòng chờ ~2s.
# Gửi trần (không bọc <hc from>) khi: terminal là shell, tin là lệnh slash ('/…'), hoặc $raw.
function Invoke-SendFlow([string]$term, [string]$text, $ops, [string]$session = '', [int]$tries = 6, [bool]$raw = $false) {
  $sent = $false
  $fail = { param($m, $n = '') @{ Ok = $false; Unsure = $sent; Message = $m; Next = $n } }
  $info = & $ops.Get $term
  switch (Get-SendPlan $info $null) {
    'dead' { return & $fail "terminal $term không live (hc get không thấy hoặc đã tắt)." @('crew up', 'gửi lại tin bằng crew send') }
    'blocked' { return & $fail "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." "sang pane $term trả lời hộp chờ duyệt (xem: hc read $term --lines 20), rồi gửi lại" }
  }
  $st0 = Get-TermStatus $info
  $bare = $raw -or (-not $st0.App) -or $text.StartsWith('/')
  # agent đang chạy lượt TRƯỚC khi gửi (tin thường): tin nằm chờ trong ô nhập, agent đọc khi xong lượt ⇒ báo rõ, không Enter thêm
  $busy = (-not $session) -and $st0.App -and $st0.State -eq 'working'
  $turn = if ($null -ne $info.turn) { [int]$info.turn } else { -1 }
  # màn hình TRƯỚC khi dán (agent rảnh, tin thường): Enter thêm của crew chỉ bấm khi so trước/sau xác nhận tin nằm đúng ô nhập
  # (Compare-PasteScreens). Agent đang bận: phía trên ô đổi liên tục, không chụp — giữ luồng Send-CodexQueue / lớp mẫu chữ.
  $before = if ($ops.Read -and $st0.App -and -not $session -and -not $busy) { "$(& $ops.Read $term)" } else { $null }
  $r = & $ops.Send $term $text $bare
  if ($r.Code -ne 0) { return & $fail "hc send tới $term thất bại: $($r.Text)" "kiểm terminal: hc ls (thiếu thì crew up), rồi gửi lại" }
  $sent = $true
  # v16 screen-assist: kết quả KHÔNG CHẮC (crew không bấm gì) mang thêm lý do + màn hình để in khối "CẦN PLANNER XEM" (Show-AssistNeeded).
  # Chỉ để planner/chủ dự án xem; không có mẫu học nào được áp (v16 assist-nolearn).
  $unsure = { param($res, $why) $res.Assist = $why; $res.Why = $seen.Why; $res.Screen = $seen.Screen; $res }
  $result = try { $r.Text | ConvertFrom-Json } catch { [pscustomobject]@{ started = $null } }
  $verdict = {
    param($plan, $info)
    switch ($plan) {
      'ok' {
        $s = Get-TermStatus $info
        # chỉ còn chờ khi vẫn working cùng lượt và chưa bấm Enter; turn tăng/đã Enter/hết working ⇒ agent đã nhận hoặc rảnh, báo như cũ
        $newTurn = $turn -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turn
        if ($busy -and $s.State -eq 'working' -and $enter -eq 0 -and -not $newTurn) {
          if ($s.App -eq 'codex') { return Send-CodexQueue $term $text $ops $bare }
          return @{ Ok = $true; Queued = $true; Message = "đã gửi -> $term nhưng agent đang bận: tin nằm chờ, agent đọc khi xong lượt (xem: crew hot)" }
        }
        # Codex không chạy lượt mà ô nhập còn chữ ⇒ tin chưa đi (vd. phiên chưa sẵn sàng nuốt mất đầu tin): báo kẹt, không Enter
        if (-not $session -and -not $busy -and $s.App -eq 'codex' -and $s.State -ne 'working' -and $ops.Read) {
          $left = Get-InputBox (& $ops.Read $term)
          if ($left -and $left.Kind -eq 'codex' -and $left.Text) { $seen.Text = $left.Text; return & $verdict 'stuck' $info }
        }
        return @{ Ok = $true; Message = "đã gửi -> $term ($(if ($s.App) { $s.State } else { 'shell' }))" }
      }
      'stuck' {
        $shown = if ($seen.Text.Length -gt 200) { $seen.Text.Substring(0, 200) + '…' } else { $seen.Text }
        $where = if ((Get-TermStatus $info).App -eq 'codex') { 'ô nhập Codex' } else { 'ô nhập' }
        return & $unsure (& $fail "đã gửi tới $term nhưng $where còn chữ khác tin vừa gửi: $shown — không bấm Enter. Xử lý: sang pane $term, xóa chữ (hoặc Enter nếu đúng), rồi gửi lại." 'xem mục "Tin kẹt ở ô nhập" trong docs/troubleshooting.md (thư mục cài Crewline)') 'stuck'
      }
      'nobox' {
        $where = if ((Get-TermStatus $info).App -eq 'codex') { 'ô nhập Codex' } else { 'ô nhập' }
        return & $unsure (& $fail "đã gửi tới $term nhưng không nhận ra $where để kiểm tin (so màn hình trước/sau khi dán: $($seen.Why)) — không bấm Enter; xem: hc read $term --lines 20" @("sang pane ${term}: tin còn trong ô thì Enter, không có thì gửi lại", "Hoặc sau khi xem hc read $term --lines 20 thấy tin nằm đúng ô nhập: crew confirm $term", $(try { Get-AgentVersionHint (Get-TermStatus $info).App } catch { '' }))) 'nobox'
      }
      'ghost-changed' { return & $fail "đã gửi tới $term nhưng pane đổi trong lúc crew kiểm ô nhập (crew đã gõ 1 dấu cách, không bấm thêm phím, không Enter) — có thể còn 1 dấu cách thừa ở ô nhập; xem: hc read $term --lines 20" "sang pane ${term}: tin còn trong ô thì Enter, không có thì gửi lại" }
      'dead' { return & $fail "terminal $term tắt sau khi gửi." 'crew up (bật lại terminal) rồi gửi lại' }
      'blocked' { return & $fail "đã gửi tới $term nhưng nó đang chờ duyệt — chủ dự án xử lý (không bấm Enter)." "sang pane $term trả lời hộp chờ duyệt (xem: hc read $term --lines 20)" }
      'dialog' { return & $unsure (& $fail "$term đang hiện một hộp thoại lạ sau '$text' — không bấm phím; xem: hc read $term --lines 20") 'dialog' }
    }
    $null
  }
  # kế hoạch sau gửi; chế độ phiên mới: 'ok' chỉ khi phiên mới sẵn sàng, agent đang chạy ⇒ 'wait' (không Enter);
  # màn hình đọc lại mỗi lần, hộp thoại xét TRƯỚC mọi kiểm sẵn sàng: hộp lạ ⇒ 'dialog' (dừng, 0 Enter);
  # hộp chọn Codex /new ⇒ 'pick' (1 lần, sau đó 'wait'). Tin thường: chỉ đọc màn hình ngay trước Enter (có $ops.Read).
  # Tin thường, cả Claude và Codex (v16): Enter khi so màn hình trước/sau dán đạt (Compare-PasteScreens), hoặc lớp mẫu chữ cũ thấy ô
  # nhập ĐÚNG tin (Get-InputBox + Test-SentInput). Hộp thoại trên màn sau ⇒ 'dialog' trước mọi lối; ô có chữ khác ⇒ 'stuck', ô trống ⇒ 'wait', còn lại ⇒ 'nobox'.
  # Không chắc ⇒ không Enter. Bảng hc không có Read ⇒ như cũ (chỉ theo trạng thái).
  $picked = 0
  $seen = @{ Text = ''; Why = ''; Screen = '' }
  $ghost = @{ Tried = $null; Is = '' }
  $check = {
    param($screen, $app)
    $seen.Screen = "$screen"
    # hộp thoại/xin duyệt trên MÀN SAU (Get-ScreenDialog, kể cả 'other') xét TRƯỚC cả hai lối Enter: Enter có thể duyệt hộ
    if (Get-ScreenDialog $screen) { return 'dialog' }
    # loại ô phải khớp app của terminal (codex ↔ ô '›', claude/claude-code ↔ ô '❯') ở CẢ HAI lối; lệch hoặc app lạ ⇒ không Enter
    $kind = @{ codex = 'codex'; 'claude-code' = 'claude'; claude = 'claude' }["$app"]
    $cmp = if ($null -ne $before) { Compare-PasteScreens $before $screen $text $bare } else { $null }
    if ($cmp -and $cmp.Ok) {
      if ($kind -and $cmp.Kind -eq $kind) { return 'press-enter' }
      $seen.Why = "kind-mismatch (ô $($cmp.Kind), app $app)"; return 'nobox'
    }
    # so trước/sau thấy dòng mới ngoài khối ô (hộp hiện phía trên ô nhập: Get-ScreenDialog coi là lịch sử) ⇒ cấm cả lối mẫu chữ cũ
    if ($cmp -and $cmp.Reason -in 'above-changed', 'below-changed', 'dialog') { $seen.Why = $cmp.Reason; return 'nobox' }
    $box = Get-SendBox $screen
    if ($box -and $box.Kind -ne $kind) { $seen.Why = "kind-mismatch (ô $($box.Kind), app $app)"; return 'nobox' }
    if ($box -and $box.Text) {
      if (-not $box.Generic -and (Test-SentInput $box.Lines $text $bare)) { return 'press-enter' }
      if (-not (Test-SentInput $box.Lines $text $bare)) {
        # Claude: chữ khác tin có thể là gợi ý mờ ⇒ phép thử gõ 1 phím (mỗi chữ thử 1 lần); gợi ý ⇒ ô thật trống ⇒ 'wait'
        if ($box.Kind -eq 'claude' -and $ops.Space) {
          if ($ghost.Tried -cne $box.Text -and $ghost.Is -ne 'changed') { $ghost.Tried = $box.Text; $ghost.Is = Test-GhostInput $term $ops }
          if ($ghost.Is -eq 'changed') { return 'ghost-changed' }
          if ($ghost.Is -eq 'ghost' -and $ghost.Tried -ceq $box.Text) { return 'wait' }
          if ($ghost.Is -eq 'unknown') { $seen.Why = 'không thử gõ 1 phím (dòng lạ dưới ô hoặc không đọc được)' }
        }
        $seen.Text = $box.Text
        if ($ghost.Is -eq 'real' -and $ghost.Tried -ceq $box.Text) { $seen.Text += ' (crew đã thêm 1 dấu cách để kiểm, không xóa gì)' }
        return 'stuck'
      }
    }
    if ($box -and -not $box.Text) { return 'wait' }
    $seen.Why = if ($cmp) { $cmp.Reason } else { 'không có màn hình trước khi dán' }
    'nobox'
  }
  $judge = {
    param($info)
    $plan = Get-SendPlan $info $result $turn
    if (-not $session) {
      if ($plan -eq 'press-enter' -and $ops.Read -and (Get-TermStatus $info).App) { return & $check "$(& $ops.Read $term)" (Get-TermStatus $info).App }
      return $plan
    }
    if ($plan -notin 'ok', 'press-enter') { return $plan }
    $screen = & $ops.Read $term
    $seen.Screen = "$screen"
    $dlg = Get-ScreenDialog $screen
    if ($dlg -eq 'codex-new' -and $session -eq 'codex') { if ($picked -ge 1) { return 'wait' } return 'pick' }
    if ($dlg) { return 'dialog' }
    if (Test-SessionReady $session $info $screen) { return 'ok' }
    if ($result.started -eq $true -or (Get-TermStatus $info).State -eq 'working') { return 'wait' }
    'press-enter'
  }
  # tin kẹt ở ô nhập ⇒ Enter (tối đa 2 lần); tổng ≤ ~15s (mặc định 6 vòng)
  $enter = 0
  for ($i = 0; $i -lt $tries; $i++) {
    if ($i -gt 0) { & $ops.Sleep 2000 }
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -eq 'wait' -or ($plan -eq 'press-enter' -and $enter -ge 2)) { continue }
    $want = $plan
    & $ops.Sleep 700
    # đọc lại trạng thái + màn hình NGAY TRƯỚC phím: vẫn đúng kế hoạch cũ mới bấm
    $info = & $ops.Get $term
    $plan = & $judge $info
    $v = & $verdict $plan $info; if ($v) { return $v }
    if ($plan -ne $want) { continue }
    & $ops.Keys $term
    if ($plan -eq 'pick') { $picked++; continue }
    $enter++
    $result = [pscustomobject]@{ started = $false }
  }
  if ($session) {
    $what = if ($session -eq 'codex') { "phiên Codex mới trống (đầu phiên '>_ OpenAI Codex', ô nhập trống, không còn tin cũ)" } else { "màn hình đã xóa ('❯ /clear' rồi ô nhập trống)" }
    return & $unsure (& $fail "chưa xác nhận được $what sau '$text' tới $term (~$(2 * $tries)s); xem: hc read $term --lines 20") 'fresh-session'
  }
  & $unsure (& $fail "đã gửi tới $term nhưng agent chưa chạy (vẫn $((Get-TermStatus $info).State)); xem: hc read $term --lines 20" "sau khi xem hc read $term --lines 20 thấy tin nằm đúng ô nhập: crew confirm $term") 'not-started'
}

# ---- Phép thử "gõ 1 phím" (v16 ghost-key): chữ trong ô nhập Claude là gợi ý mờ hay chữ thật? ----
# ĐÂY LÀ CÁCH DUY NHẤT crew gõ phím không phải tin của mình (Enter/Tab khác chỉ bấm sau khi kiểm đúng tin crew vừa gửi):
# ĐÚNG 1 dấu cách, KHÔNG BAO GIỜ phím xóa. hc read không có màu nên không phân biệt được chữ mờ; đo thật (Claude Code 2.1.329,
# context/tasks/suggest-probe.md): gõ dấu cách ⇒ gợi ý biến mất (dòng ô chỉ còn '❯' + khoảng trắng/NBSP); chữ thật + dấu cách ⇒ chữ còn.
# Không Backspace (Rev v16): hc read không có vị trí con trỏ và cắt khoảng trắng cuối — người dùng bấm ←/gõ chữ trong lúc chờ, hoặc pane
# bị thay cùng tên, thì Backspace có thể xóa chữ người dùng / trả lời hộp thoại. Hệ quả: ô còn 1 dấu cách của crew
# (gợi ý ⇒ tin dán sau dấu cách, Find-PromptBox/Test-SentInput bỏ khoảng trắng đầu; chữ thật ⇒ chữ người dùng +1 dấu cách, crew dừng).
# Chỉ Claude (Codex giữ nguyên). Chỉ gõ khi: terminal live, app claude, không blocked/working, màn hình không hộp thoại, ô '❯' có chữ.
# Đọc lại sau dấu cách phải cùng address/app/turn, live, không blocked/working, không hộp thoại, nhận ra ô '❯'; không thì 'changed'.
# $ops cần Get/Read/Sleep/Space; thiếu Space (bảng hc giả cũ) ⇒ 'unknown', 0 phím. Space thất bại ⇒ 'unknown'.
# Ra: 'ghost' (ô thật trống) | 'real' (chữ thật, đã +1 dấu cách) | 'unknown' (không thử, 0 phím) | 'changed' (đã gõ dấu cách, pane đổi).
function Test-GhostInput([string]$term, $ops) {
  if (-not $ops -or -not $ops.Space -or -not $ops.Read -or -not $ops.Get) { return 'unknown' }
  $info = & $ops.Get $term
  $st = Get-TermStatus $info
  if (-not $info -or $info.state -ne 'live' -or $st.App -notin 'claude', 'claude-code' -or $st.State -in 'blocked', 'working') { return 'unknown' }
  $screen = "$(& $ops.Read $term)"
  if (Get-ScreenDialog $screen) { return 'unknown' }
  $box = Get-SendBox $screen
  if (-not $box -or $box.Kind -ne 'claude') { return 'unknown' }
  if (-not $box.Text) { return 'ghost' }
  # v16 assist-nolearn: Space không phải tin ⇒ chỉ khi dưới ô toàn dòng ghi cứng đã biết; dòng lạ ⇒ không thử (0 phím), người gọi báo không chắc
  if (-not $box.KnownTail) { return 'unknown' }
  $before = $box.Text
  if ((& $ops.Space $term) -ne $true) { return 'unknown' }
  & $ops.Sleep 300
  try {
    $info2 = & $ops.Get $term
    $after = "$(& $ops.Read $term)"
  } catch { return 'changed' }
  $st2 = Get-TermStatus $info2
  if (-not $info2 -or $info2.state -ne 'live' -or "$($info2.address)" -cne "$($info.address)" -or $st2.App -ne $st.App -or
      $st2.State -in 'blocked', 'working' -or "$($info2.turn)" -ne "$($info.turn)") { return 'changed' }
  if (Get-ScreenDialog $after) { return 'changed' }
  $box = Get-SendBox $after
  if (-not $box -or $box.Kind -ne 'claude') { return 'changed' }
  if (-not $box.Text) { return 'ghost' }
  if ($box.Text -ceq $before) { return 'real' }
  'changed'
}

# Câu báo theo kết quả phép thử (crew đã gõ 1 dấu cách, không xóa): 'real' ⇒ chữ người dùng; 'changed' ⇒ pane đổi giữa chừng.
function Get-GhostProbeMessage([string]$term, [string]$probe, [string]$text = '') {
  $shown = if ($text.Length -gt 200) { $text.Substring(0, 200) + '…' } else { $text }
  if ($probe -eq 'real') {
    return "$term`: ô nhập Claude có chữ bạn gõ (crew đã thêm 1 dấu cách để kiểm, không xóa gì), chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại."
  }
  "$term đổi trong lúc crew kiểm ô nhập (crew đã gõ 1 dấu cách, không bấm thêm phím) — chưa gửi tin mới. Xem: hc read $term --lines 20; có thể còn 1 dấu cách thừa ở ô nhập, rồi gửi lại."
}

# Task/repair không được xóa bản nháp khi reset phiên; kiểm ô nhập thật của cả Claude và Codex.
# hc không phân biệt được chữ gợi ý mờ của Claude: có $ops ⇒ phép thử gõ 1 phím (Test-GhostInput): gợi ý ⇒ coi ô trống;
# chữ thật ⇒ giữ ô có chữ để người dùng xử lý trong pane (không tự xóa/ghi đè). Không thử được ⇒ câu báo chỉ cách bật lại pane.
function Get-WorkerInputError([string]$term, [string]$screen, $ops = $null) {
  if (Get-ScreenDialog $screen) { return '' }
  $box = Get-InputBox $screen
  if (-not $box -or -not $box.Text) { return '' }
  $probe = if ($box.Kind -eq 'claude' -and $ops -and $ops.Space) { Test-GhostInput $term $ops } else { 'unknown' }
  if ($probe -eq 'ghost') { return '' }
  if ($probe -in 'changed', 'real') { return (Get-GhostProbeMessage $term $probe $box.Text) }
  $shown = if ($box.Text.Length -gt 200) { $box.Text.Substring(0, 200) + '…' } else { $box.Text }
  $msg = "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại."
  if ($box.Kind -eq 'claude') {
    # vai = phần sau '<crew>-' trong tên terminal
    $role = if ($term -match '-(planner|rev|w\d+)$') { $Matches[1] } else { '<vai>' }
    $msg += "`n  Nếu không ai gõ dòng này, đó là gợi ý mờ của Claude Code (pane bật trước bản sửa) — bật lại: crew up -Restart $role (worker có task cần -Force; xem docs/troubleshooting.md mục Gợi ý của Claude)."
  }
  $msg
}

# Gửi tin tới terminal, dùng chung cho crew send/review. Lỗi ⇒ Die (exit 1). Agent bận ⇒ báo tin nằm chờ (exit 0).
# $root khác rỗng ⇒ kiểm chủ project; $ops = $null ⇒ New-HcOps.
function Send-CrewMessage([string]$term, [string]$text, [bool]$raw = $false, [string]$root = '', $ops = $null, [switch]$PassResult) {
  if (-not $ops) { $ops = New-HcOps }
  if ($root) {
    $why = Get-ForeignTermError $term (& $ops.Get $term) $root
    if ($why) { Die "$why Không gửi." 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
  }
  # tin cũ còn ở ô nhập: gửi nữa sẽ dính vào nó, Enter sẽ gửi cả hai ⇒ để người quyết
  # Codex rảnh: chỉ gửi khi màn hình có ô nhập thật và không có hộp thoại (vừa /new: hộp chọn worktree hoặc phiên chưa vẽ xong
  # ⇒ phím gõ vào hộp, '1' trong '<hc from="t1…' chọn hộ dòng 1). Chờ tối đa ~10s, vẫn chưa ⇒ Die, không gửi.
  $st = Get-TermStatus (& $ops.Get $term)
  for ($w = 0; $ops.Read -and $st.App -eq 'codex' -and $st.State -in 'idle', 'done'; $w++) {
    $screen = & $ops.Read $term
    # v16: chân/gợi ý lạ không còn chặn gửi — Get-SendBox lùi về ô nhận theo ký tự đầu ô khi mẫu chữ không khớp; hộp thoại (kể cả 'other') vẫn chặn
    $dlg = Get-ScreenDialog $screen
    $box = Get-SendBox $screen
    if (-not $dlg -and $box -and $box.Kind -eq 'codex') {
      if ($box.Text) {
        $shown = if ($box.Text.Length -gt 200) { $box.Text.Substring(0, 200) + '…' } else { $box.Text }
        Die "$term có tin kẹt ở ô nhập, chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại." 'xem mục "Tin kẹt ở ô nhập" trong docs/troubleshooting.md (thư mục cài Crewline)'
      }
      break
    }
    if ($w -ge 5) {
      $why = if ($dlg -eq 'codex-new') { "đang mở hộp chọn của /new" } elseif ($dlg) { 'đang hiện hộp thoại' } else { 'chưa hiện ô nhập sẵn sàng' }
      if ($dlg -ne 'codex-new') { try { Show-AssistNeeded $term @{ Assist = $(if ($dlg) { 'dialog' } else { 'nobox' }); Why = $why; Screen = "$screen" } $st.App } catch { } }
      Die "$term $why, chưa gửi (không bấm phím)." @("xem: hc read $term --lines 20, xử lý xong rồi gửi lại", $(try { Get-AgentVersionHint $st.App } catch { '' }))
    }
    & $ops.Sleep 2000
    $st = Get-TermStatus (& $ops.Get $term)
  }
  # Claude rảnh mà ô nhập có chữ: hc send dán + Enter sẽ gửi chồng chữ đó ⇒ phép thử gõ 1 phím (Test-GhostInput):
  # gợi ý mờ ⇒ gửi như ô trống (ô còn 1 dấu cách của crew, tin dán sau nó); chữ thật / pane đổi / không chắc ⇒ chặn, không phím xóa nào.
  # Bảng hc không có Space (bảng giả cũ) ⇒ như trước, không kiểm.
  if ($ops.Space -and $ops.Read -and $st.App -in 'claude', 'claude-code' -and $st.State -notin 'working', 'blocked') {
    $screen = & $ops.Read $term
    $box = if (Get-ScreenDialog $screen) { $null } else { Get-SendBox $screen }
    $probe = if ($box -and $box.Kind -eq 'claude' -and $box.Text) { Test-GhostInput $term $ops } else { 'ghost' }
    $next = 'xem mục "Tin kẹt ở ô nhập" trong docs/troubleshooting.md (thư mục cài Crewline)'
    if ($probe -in 'changed', 'real') { Die (Get-GhostProbeMessage $term $probe $box.Text) $next }
    if ($probe -ne 'ghost') {
      $shown = if ($box.Text.Length -gt 200) { $box.Text.Substring(0, 200) + '…' } else { $box.Text }
      Die "$term có chữ ở ô nhập Claude (không kiểm được là gợi ý hay chữ thật), chưa gửi tin mới: $shown`n  Xử lý: sang pane $term, Enter để gửi hoặc xóa chữ, rồi gửi lại." $next
    }
  }
  # /new tới Codex, /clear tới Claude: chờ phiên mới như crew task (Test-SessionReady).
  $session = if ($st.App -eq 'codex' -and $text.Trim() -ceq '/new') { 'codex' }
    elseif ($st.App -in 'claude', 'claude-code' -and $text.Trim() -ceq '/clear') { 'claude' } else { '' }
  $r = Invoke-SendFlow $term $text $ops $session $(if ($session) { 10 } else { 6 }) $raw
  # crew không chắc (không bấm gì) ⇒ khối "CẦN PLANNER XEM" (config assist ≠ off), rồi báo lỗi như cũ. Suite trích AST không nạp assist.ps1 ⇒ try.
  if ($r.Assist -and (-not $r.Ok -or $r.Unsure)) { try { Show-AssistNeeded $term $r $st.App } catch { } }
  if ($PassResult) { return $r }
  if (-not $r.Ok) { Die $r.Message $r.Next }
  Say $r.Message
}

function Invoke-Send {
  if (-not $Name -or -not $PromptFile) { Die 'dùng: crew send <terminal> "<tin>" [-Raw]' @('crew hot', 'crew send <crew>-w1 "tiếp tục"') }
  # gọi trong repo crew và terminal mang tên crew này ⇒ kiểm chủ; tên khác / ngoài repo ⇒ gửi như cũ
  $root = Get-MainRoot (Get-Location).Path
  $guard = ''
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    $cfg = Get-Config $root
    $slug = Get-CrewName $root $cfg
    $roles = @()
    if ($cfg.planner -and $cfg.planner -ne 'none') { $roles += "$slug-planner" }
    for ($i = 1; $i -le @($cfg.workers).Count; $i++) { $roles += "$slug-w$i" }
    if ($cfg.rev -and $cfg.rev -ne 'none') { $roles += "$slug-rev" }
    if ($Name -notin $roles) {
      $target = Get-TermInfo $Name
      if (-not $target -or $target.state -ne 'live') {
        Die "không có terminal $Name trong crew $slug" @("Tên terminal: $($roles -join ', ')", 'crew hot')
      }
    }
    if ($Name -like "$slug-*") { $guard = $root }
    if ($guard) { try { $mv = Get-MoveInfo $root (Get-Config $root) } catch { $mv = $null }; if ($mv -and $mv.Moved) { Die $mv.Hint @('crew repair', 'gửi lại tin bằng crew send') } }
  }
  # Chụp người gửi trước khi gửi (-Raw tạm xóa biến HC); không tin tên terminal từ nội dung tin.
  $sender = if ($root -and $env:HC_TERMINAL_ID) { Get-TermInfo $env:HC_TERMINAL_ID } else { $null }
  Send-CrewMessage $Name $PromptFile $Raw.IsPresent $guard
  # Chỉ cập nhật sau khi luồng gửi xác nhận thành công; lỗi gửi không đổi task.
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json')) -and
      $sender -and $sender.state -eq 'live' -and $sender.address -ceq $env:HC_TERMINAL_ID) {
    Update-TaskDone $root $sender.name $Name $PromptFile $Raw.IsPresent (Get-CrewName $root (Get-Config $root))
  }
}

# Chỉ crew send đổi tín hiệu worker xong; review dùng reviewSentAt riêng.
function Update-TaskDone([string]$root, [string]$sender, [string]$target, [string]$text, [bool]$raw, [string]$slug) {
  if (-not $sender) { return }
  $done = $text -match '^XONG'
  $reopen = $sender -ceq "$slug-planner" -and -not $raw -and $text -notmatch '^/'
  if (-not $done -and -not $reopen) { return }
  $current = Get-Tasks $root
  $candidate = @($current | Where-Object { ($done -and $_.terminal -and $sender -ceq $_.terminal) -or ($reopen -and $_.terminal -and $target -ceq $_.terminal -and $_.doneAt) })
  if (-not $candidate.Count) { return }
  Update-Tasks $root { param($tasks)
    foreach ($t in $tasks) {
      if ($done -and $t.terminal -and $sender -ceq $t.terminal) {
        $t | Add-Member -NotePropertyName doneAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
      }
      elseif ($reopen -and $t.terminal -and $target -ceq $t.terminal -and $t.doneAt) {
        $t.PSObject.Properties.Remove('doneAt')
      }
    }
    $tasks
  } | Out-Null
}
# Repo chính, kể cả khi gọi từ trong worktree: thư mục cha của git common dir.
function Get-MainRoot([string]$p) {
  $r = Invoke-GitQuiet -C $p rev-parse --path-format=absolute --git-common-dir
  if ($r.Code -ne 0 -or -not $r.Text) { return $null }
  return (Resolve-Path (Split-Path $r.Text -Parent)).Path
}

# Mức review (chữ Việt) của task: review của task > dòng đầu HOT > config.review > Gọn.
function Get-ReviewLevel($task, [string]$hotText, [string]$cfgReview) {
  $vi = @{ fast = 'Nhanh'; lean = 'Gọn'; full = 'Đủ' }
  if ($task -and $task.review -and $vi.ContainsKey([string]$task.review)) { return $vi[[string]$task.review] }
  if ($hotText -match 'Chế độ review: \*\*(Gọn|Nhanh|Đủ)\*\*') { return $Matches[1] }
  if ($cfgReview -and $vi.ContainsKey($cfgReview)) { return $vi[$cfgReview] }
  return 'Gọn'
}

# Hàm thuần soạn tin giao Rev. $items: mảng @{ Name; Branch; Commits } theo thứ tự merge.
function Format-ReviewMessage([string]$level, $items) {
  $items = @($items)
  $merge = ($items | ForEach-Object { "$($_.Branch) ($(@($_.Commits) -join ','))" }) -join ' rồi '
  $notes = ($items | ForEach-Object { "context/tasks/$($_.Name).md" }) -join ', '
  $clean = ($items | ForEach-Object { "crew clean $($_.Name)" }) -join ', '
  $multi = $items.Count -gt 1
  $order = if ($multi) { ' (đúng thứ tự này)' } else { '' }
  $each = if ($multi) { ' của từng task' } else { '' }
  "Rev ${level}: merge $merge$order. Đọc $notes$each. Full test, $clean, báo planner. Không push."
}

# Hàm thuần: Rev có nhận được tin review không. $info = `hc get` của terminal Rev (đọc 1 lần, 0 phím). Ra lý do, '' = gửi được.
# Không live/chờ duyệt Send-CrewMessage cũng chặn; ở đây thêm gợi ý cách xử lý và áp được cho -DryRun.
# $readScreen: scriptblock trả màn hình Rev, chỉ gọi khi hc báo shell (Rev mở lại phiên chưa báo app ⇒ nhận theo màn hình, như Start-WorkerTask).
function Get-RevGuard($cfg, [string]$term, $info, [scriptblock]$readScreen = $null) {
  if (-not $cfg.rev -or $cfg.rev -eq 'none') { return 'config Rev=none nên không có pane rev để gửi review. Dùng mức review fast (planner tự merge) hoặc đặt rev trong config rồi crew up.' }
  $m = Get-WorkerMode $info $cfg.rev
  switch ($m.Mode) {
    'dead' { return "$term không chạy — chạy crew up rồi gửi lại." }
    'blocked' { return "$term đang chờ duyệt — chủ dự án xử lý (không gửi, không dùng --force)." }
    'wrong' { return "rev đang chạy $($m.App), config là $($cfg.rev) — crew up -Restart rev" }
    'shell' { if (-not ($readScreen -and (Test-AgentScreen $cfg.rev (& $readScreen)))) { return 'rev chỉ còn shell — crew up -Restart rev' } }
  }
  ''
}

function Invoke-Review {
  $names = @($NameList)
  if (-not $names.Count) { Die 'dùng: crew review <task>[,<task2>…] [-DryRun|-Sent]' @('crew hot', 'crew review fix-login') }
  $root = Get-MainRoot (Get-Location).Path; if (-not $root) { Die 'chạy trong repo của crew.' @('cd <project>', 'crew init') }
  $cfg = Get-Config $root; $slug = Get-CrewName $root $cfg; $tasks = Get-Tasks $root
  $sel = @(foreach ($n in $names) {
    $t = $tasks | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $t) { Die "không có task tên $n." 'xem tên task đang có: crew hot' }
    $t
  })
  if ($Sent -and $DryRun) { Die '-Sent không đi với -DryRun.' 'chạy: crew review <task> -Sent' }
  $r = $null
  if (-not $Sent) {
    $main = (Invoke-GitOrDie 'lấy nhánh hiện tại' -C $root branch --show-current).Text
    if (-not $main) { Die "repo chính $root không đứng trên nhánh nào (detached HEAD)." @("git -C '$root' switch <nhánh chính>", "crew review <task>") }
    $rl = Get-ReviewLine $root $main $sel $cfg.review
    if ($rl.Error) { Die $rl.Error $rl.Next }
    $revTerm = "$slug-rev"
    $revInfo = if ($cfg.rev -and $cfg.rev -ne 'none') { Get-TermInfo $revTerm } else { $null }
    $why = Get-RevGuard $cfg $revTerm $revInfo { & (New-HcOps).Read $revTerm }
    if ($DryRun) {
      Write-Host $rl.Msg
      if ($why) { Say "cảnh báo: $why" }
      return
    }
    if ($why) { Die "$why Không gửi." "xử lý theo lỗi ở trên rồi chạy lại: crew review $($names -join ',')" }
    $r = Send-CrewMessage $revTerm $rl.Msg $false $root -PassResult
    if ($r -and -not $r.Ok -and -not $r.Unsure) { Die $r.Message $r.Next }
  }
  # gửi được ⇒ đánh dấu chờ review (crew repair giao lại khi Rev bị đóng giữa chừng); +i ms giữ thứ tự gửi
  $now = [DateTime]::UtcNow
  for ($i = 0; $i -lt $sel.Count; $i++) {
    $sel[$i] | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $now.AddMilliseconds($i).ToString('o') -Force
  }
  Update-Tasks $root { param($current)
    foreach ($item in $sel) {
      $found = $current | Where-Object { $_.name -eq $item.name }
      if ($found) {
        $found | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $item.reviewSentAt -Force
        if ($r -and $r.Unsure) { $found | Add-Member -NotePropertyName reviewUnsure -NotePropertyValue $true -Force }
        else { $found.PSObject.Properties.Remove('reviewUnsure') }
      }
    }
    $current
  } | Out-Null
  if ($r -and $r.Unsure) {
    Die "$($r.Message) — chưa chắc Rev đã nhận review $($names -join ',')." @("hc read $revTerm --lines 20", "thấy tin nằm đúng ô nhập: crew confirm $revTerm (Enter 1 lần + đánh dấu đã gửi)", "Hoặc bấm Enter tay rồi: crew review $($names -join ',') -Sent")
  }
  if ($r) { Say $r.Message }
}
