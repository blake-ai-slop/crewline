# ---------------- probe / confirm (v16 mục D) ----------------
# crew probe <claude|codex>: mở 1 terminal tạm của agent (thư mục tạm có git init, quyền như worker, tắt gợi ý Claude), đi qua các bước
# crew dùng thật (phiên mới sẵn sàng → gõ tin vào ô + Invoke-SendFlow so màn hình trước/sau rồi Enter → chờ xong lượt → /clear|/new +
# Test-SessionReady), in bảng đạt/hụt, lưu màn hình làm fixture. 0 token phía crew (agent chỉ trả lời 1 tin ngắn). Luôn đóng terminal tạm.
# crew confirm <terminal>: người/planner đã nhìn thấy tin nằm đúng ô nhập ⇒ đọc màn hình 1 lần, đủ điều kiện thì Enter 1 lần.

# Thư mục lưu màn hình probe: ~/.crewline/probe (CREWLINE_PROBE_DIR đổi đường dẫn, dùng cho test).
function Get-ProbeRoot {
  if ($env:CREWLINE_PROBE_DIR) { return $env:CREWLINE_PROBE_DIR }
  Join-Path $HOME '.crewline/probe'
}

# Tin thử: chữ thường ASCII + dấu cách vì crew GÕ từng phím (hc keys), không dán — hc send luôn kèm Enter nên không kiểm được ô nhập.
function Get-ProbeMessage { 'reply with just ok' }

# Tên phím hc keys cho từng ký tự; ký tự ngoài a-z 0-9 dấu cách ⇒ ném lỗi (không đoán tên phím).
function Get-ProbeKeys([string]$text) {
  , [string[]]@(foreach ($c in $text.ToCharArray()) {
    if ($c -eq ' ') { 'space' } elseif ("$c" -cmatch '^[a-z0-9]$') { "$c" } else { throw "ký tự '$c' không gõ được bằng hc keys" }
  })
}

# Hộp trust thư mục tạm của probe (crew vừa tạo, trống): phím để chọn "trust" — Enter khi dòng trust đang được chọn, ↑/↓ khi dòng kia
# đang chọn. Không nhận ra dòng đang chọn ⇒ @() (không bấm). Chỉ gọi khi Get-ScreenDialog = 'trust'.
function Get-ProbeTrustKeys([string]$kind, [string]$screen) {
  $rows = @("$screen" -split '\r?\n')
  $yesPat = if ($kind -eq 'codex') { 'Trust and continue' } else { 'Yes, I trust this folder' }
  $noPat = if ($kind -eq 'codex') { '\d\.\s*Quit\b' } else { 'No, exit' }
  $yes = -1; $no = -1; $sel = ''
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $isYes = $rows[$i] -match $yesPat
    $isNo = $rows[$i] -match $noPat
    if ($isYes) { $yes = $i } elseif ($isNo) { $no = $i } else { continue }
    if ($rows[$i] -match '^\s*[›❯>]') { $sel = if ($isYes) { 'yes' } else { 'no' } }
  }
  if ($sel -eq 'yes') { return @('enter') }
  if ($sel -eq 'no' -and $yes -ge 0 -and $no -ge 0) { return @($(if ($yes -lt $no) { 'up' } else { 'down' })) }
  @()
}

# Lệnh hc thật cho probe: New-HcOps + Start (hc run --bg), Type/Press (hc keys), Close (kill + rm). Test tiêm bảng giả cùng khóa.
function New-ProbeOps {
  $ops = New-HcOps
  $ops.Start = {
    param($name, $cwd, $cmdline)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmdline))
    $out = & { $ErrorActionPreference = 'Continue'; hc run --bg --json --name $name --no-notify --cwd $cwd --label 'crewline.probe=1' -- pwsh -NoLogo -NoProfile -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" } }
    @{ Ok = ($LASTEXITCODE -eq 0); Text = (@($out) -join "`n").Trim() }
  }
  $ops.Press = { param($term, [string[]]$keys) & { $ErrorActionPreference = 'Continue'; hc keys $term @keys 2>&1 } | Out-Null; $LASTEXITCODE -eq 0 }
  # Close($name, $address, $cwd): CHỈ theo address đã xác nhận; kill/rm chỉ khi hc get ở address đó đúng là terminal của lượt probe
  # (Test-ProbeTerm: address + tên + cwd thư mục tạm). Thiếu address, không đọc được, hay lệch ⇒ không đụng.
  $ops.Close = {
    param($name, $address, $cwd)
    if (-not $address) { return }
    $info = Get-TermInfo $address
    if (-not (Test-ProbeTerm $info $address $cwd $name)) { return }
    & { $ErrorActionPreference = 'Continue'; hc kill $address 2>&1 } | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
      $info = Get-TermInfo $address
      if (-not $info -or $info.state -ne 'live') { break }
      Start-Sleep -Milliseconds 250
    }
    if (-not (Test-ProbeTerm $info $address $cwd $name)) { return }
    & { $ErrorActionPreference = 'Continue'; hc rm $address 2>&1 } | Out-Null
  }
  $ops
}

# Dòng lệnh pwsh của terminal tạm: bỏ biến phiên cha (như Start-Term), tắt gợi ý Claude, agent với cờ quyền của worker.
function Get-ProbeCommandLine([string]$kind, [string]$access) {
  $clean = "foreach (`$v in 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN') { Remove-Item `"Env:`$v`" -ErrorAction Ignore }; "
  $exe = if ($kind -eq 'codex') { 'codex' } else { 'claude' }
  $clean + (Get-SuggestionEnvLine $false) + "$exe $(Get-Flags $kind $access)"
}

# Hàm thuần: $info (hc get) đúng là terminal tạm của lượt probe — cùng address, cwd là thư mục tạm của lượt (so đường dẫn đầy đủ,
# không phân biệt hoa thường trên Windows), và nếu có $name thì cùng tên.
function Test-ProbeTerm($info, [string]$address, [string]$cwd, [string]$name = '') {
  if (-not $info -or -not $address -or -not $cwd -or "$($info.address)" -cne $address -or -not $info.cwd) { return $false }
  if ($name -and "$($info.name)" -cne $name) { return $false }
  $norm = { param($p) try { [IO.Path]::GetFullPath("$p").TrimEnd('\', '/') } catch { '' } }
  $a = & $norm $info.cwd; $b = & $norm $cwd
  $cmp = if ($IsWindows -or $env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  [bool]($a -and [string]::Equals($a, $b, $cmp))
}

# Luồng probe (không Die, không in): trả @{ Steps = [@{ Step; Status = 'đạt'|'hụt'|'bỏ qua'; Reason }]; Ok; Screens = @{ tên = màn hình } }.
# $ops cần Start/Get/Read/Keys/Send/Press/Close/Sleep (Space tùy chọn); Get/Read/... nhận address. Terminal tạm đã xác nhận luôn được đóng
# (finally), kể cả khi ném lỗi; address/cwd lệch ⇒ dừng, không đóng.
# $tries: số vòng chờ ~2s cho từng bước (Ready, Turn); test đặt nhỏ.
function Invoke-Probe([string]$kind, [string]$name, [string]$cwd, [string]$cmdline, $ops, [hashtable]$tries = @{}) {
  $readyTries = if ($tries.Ready) { $tries.Ready } else { 45 }
  $turnTries = if ($tries.Turn) { $tries.Turn } else { 60 }
  $want = @{ claude = 'claude'; codex = 'codex' }[$kind]
  $slash = if ($kind -eq 'codex') { '/new' } else { '/clear' }
  $steps = [Collections.Generic.List[object]]::new()
  $screens = [ordered]@{}
  $add = { param($step, $ok, $why) $steps.Add([pscustomobject]@{ Step = $step; Status = $(if ($ok) { 'đạt' } else { 'hụt' }); Reason = $why }) }
  $names = 'bật terminal tạm', 'phiên mới sẵn sàng', "gõ tin + kiểm ô nhập (Invoke-SendFlow)", 'chờ xong lượt', "$slash + phiên mới (Test-SessionReady)"
  $finish = {
    foreach ($n in $names) { if (-not @($steps | Where-Object { $_.Step -eq $n }).Count) { $steps.Add([pscustomobject]@{ Step = $n; Status = 'bỏ qua'; Reason = 'bước trước hụt' }) } }
    @{ Steps = @($steps); Ok = -not @($steps | Where-Object { $_.Status -ne 'đạt' }).Count; Screens = $screens }
  }
  $started = $false; $address = ''; $verified = $false
  try {
    # 1. bật terminal
    $r = & $ops.Start $name $cwd $cmdline
    if (-not $r.Ok) { & $add $names[0] $false "hc run thất bại: $($r.Text)"; return & $finish }
    $started = $true
    $address = try { "$(($r.Text | ConvertFrom-Json).address)" } catch { '' }
    if (-not $address) { & $add $names[0] $false "hc run không trả address: $($r.Text) — không thao tác, không đóng theo tên (xem: hc ls)"; return & $finish }
    if (-not (Test-ProbeTerm (& $ops.Get $address) $address $cwd)) {
      & $add $names[0] $false "terminal ở $address không phải terminal tạm của lượt này (cwd khác $cwd) — dừng, không bấm, không đóng"; return & $finish
    }
    $verified = $true
    & $add $names[0] $true "terminal $name ($address), thư mục $cwd"
    # Mọi thao tác sau (kể cả trong Invoke-SendFlow/Test-GhostInput) đi qua bảng gác: dùng ADDRESS đã xác nhận, bỏ tên truyền vào;
    # trước mỗi lần đọc/bấm kiểm lại address + cwd (Test-ProbeTerm), lệch ⇒ ném PROBE-GUARD (dừng, 0 phím, không đóng).
    # Biến tên probe* riêng: các khối chạy bên trong hàm khác có $ops/$term, tra biến theo ngăn gọi.
    $probeRaw = $ops; $probeAddr = $address; $probeCwd = $cwd
    $probeCheck = {
      $i = & $probeRaw.Get $probeAddr
      if (-not (Test-ProbeTerm $i $probeAddr $probeCwd)) { throw "PROBE-GUARD: terminal $probeAddr không còn là terminal tạm của lượt này (address/cwd lệch hoặc mất)" }
      $i
    }
    $ops = @{
      Get = { param($t) & $probeCheck }
      Read = { param($t) $null = & $probeCheck; & $probeRaw.Read $probeAddr }
      Press = { param($t, [string[]]$keys) $null = & $probeCheck; & $probeRaw.Press $probeAddr $keys }
      Keys = { param($t) $null = & $probeCheck; & $probeRaw.Keys $probeAddr }
      Send = { param($t, $text, $raw) $null = & $probeCheck; & $probeRaw.Send $probeAddr $text $raw }
      Sleep = $probeRaw.Sleep
    }
    if ($probeRaw.Space) { $ops.Space = { param($t) $null = & $probeCheck; & $probeRaw.Space $probeAddr } }
    if ($probeRaw.Tab) { $ops.Tab = { param($t) $null = & $probeCheck; & $probeRaw.Tab $probeAddr } }

    # 2. phiên mới: trust thư mục tạm (crew vừa tạo) ⇒ tự chọn trust, tối đa 3 lần; hộp khác ⇒ hụt; sẵn sàng = agent đúng loại, rảnh,
    #    ô nhập trống nhận được bằng mẫu chữ (Get-InputBox); Codex thêm Test-SessionReady (nhận phiên mới).
    $why = 'agent chưa sẵn sàng'; $ready = $false; $trusted = 0; $screen = ''
    for ($i = 0; $i -lt $readyTries -and -not $ready; $i++) {
      if ($i -gt 0) { & $ops.Sleep 2000 }
      $info = & $ops.Get $name
      $screen = "$(& $ops.Read $name)"
      $dlg = Get-ScreenDialog $screen
      if ($dlg -eq 'trust') {
        $keys = @(Get-ProbeTrustKeys $kind $screen)
        if (-not $keys.Count -or $trusted -ge 3) { $why = 'hộp trust thư mục: không nhận ra dòng đang chọn'; break }
        $screens['00-trust'] = $screen
        & $ops.Press $name ([string[]]$keys) | Out-Null; $trusted++; continue
      }
      if ($dlg) { $why = "hộp thoại lạ ($dlg)"; break }
      $m = Get-WorkerMode $info $kind
      if ($m.Mode -eq 'dead') { $why = 'terminal không live (agent thoát?)'; continue }
      if ($m.Mode -eq 'wrong') { $why = "hc báo app $($m.App), cần $kind"; break }
      if ($m.Mode -eq 'blocked') { $why = 'agent đang chờ duyệt'; break }
      if ($m.Mode -eq 'agent' -and (Get-TermStatus $info).State -eq 'working') { $why = 'agent đang working'; continue }
      if ($m.Mode -eq 'shell' -and -not (Test-AgentScreen $kind $screen)) { $why = 'chưa thấy giao diện agent (hc chưa báo app)'; continue }
      $box = Get-InputBox $screen
      if (-not $box) {
        $gen = Get-SendBox $screen
        $why = if ($gen) { "mẫu chữ (Get-InputBox) không nhận ra ô nhập, chỉ nhận theo ký tự ô '$(if ($gen.Kind -eq 'codex') { '›' } else { '❯' })'" } else { 'không nhận ra ô nhập' }
        continue
      }
      if ($box.Kind -ne $want) { $why = "ô nhập kiểu $($box.Kind), cần $want"; continue }
      if ($box.Text) { $why = "ô nhập phiên mới có chữ: $($box.Text)"; continue }
      if ($kind -eq 'codex' -and -not (Test-SessionReady 'codex' $info $screen)) { $why = "Test-SessionReady chưa nhận phiên Codex mới ('>_ OpenAI Codex' + ô trống)"; continue }
      $ready = $true
    }
    $screens['01-fresh'] = $screen
    if (-not $ready) { & $add $names[1] $false $why; return & $finish }
    & $add $names[1] $true "ô nhập trống nhận bằng mẫu chữ$(if ($trusted) { '; đã chọn trust cho thư mục tạm' })"

    # 3. gõ tin (không Enter) rồi để Invoke-SendFlow thật quyết: so màn hình trước/sau (Compare-PasteScreens) + loại ô khớp app ⇒ Enter.
    $msg = Get-ProbeMessage
    $info0 = & $ops.Get $name
    $turn0 = if ($null -ne $info0.turn) { [int]$info0.turn } else { -1 }
    # Biến tên riêng (probeBase/probeRec): các khối dưới chạy bên trong Invoke-SendFlow/Test-GhostInput (có $ops riêng), tra biến theo ngăn gọi.
    $probeBase = $ops
    $probeRec = @{ Reads = [Collections.Generic.List[string]]::new(); AtEnter = ''; Enters = 0 }
    $rec = $probeRec
    $flow = @{}
    foreach ($k in @($ops.get_Keys())) { $flow[$k] = $ops[$k] }
    $flow.Read = { param($t) $s = "$(& $probeBase.Read $t)"; $probeRec.Reads.Add($s); $s }
    $flow.Keys = { param($t) $probeRec.Enters++; if ($probeRec.Reads.Count) { $probeRec.AtEnter = $probeRec.Reads[$probeRec.Reads.Count - 1] }; & $probeBase.Keys $t }
    $flow.Send = {
      param($t, $text, $raw)
      $ok = & $probeBase.Press $t (Get-ProbeKeys $text)
      # hc send dán cả tin một lần; gõ phím thì TUI vẽ dần (Codex 0.171 đọc thấy 'reply wit') ⇒ chờ ô hiện đủ tin (≤~5s) rồi mới
      # trả về như một lần dán. Đọc ở đây không vào $probeRec: Invoke-SendFlow vẫn tự chụp/so màn hình như gửi thật.
      for ($w = 0; $ok -and $w -lt 16; $w++) {
        $bx = Get-SendBox "$(& $probeBase.Read $t)"
        if ($bx -and (Test-SentInput $bx.Lines $text $true)) { break }
        & $probeBase.Sleep 300
      }
      @{ Code = $(if ($ok) { 0 } else { 1 }); Text = $(if ($ok) { '{"started":false}' } else { 'hc keys thất bại' }) }
    }
    $res = Invoke-SendFlow $name $msg $flow '' 6 $true
    if ($rec.Reads.Count) { $screens['02-before'] = $rec.Reads[0] }
    if ($rec.AtEnter) { $screens['02-typed'] = $rec.AtEnter }
    $cmpWhy = if ($rec.Reads.Count -and $rec.AtEnter) { (Compare-PasteScreens $rec.Reads[0] $rec.AtEnter $msg $true).Reason } else { '' }
    if (-not $res.Ok -or $rec.Enters -ne 1) {
      $detail = if ($res.Ok) { "Invoke-SendFlow báo '$($res.Message)' nhưng crew bấm Enter $($rec.Enters) lần (cần 1: kiểm ô nhập rồi Enter)" } else { $res.Message }
      & $add $names[2] $false $detail
      if ($rec.Reads.Count) { $screens['02-last'] = $rec.Reads[$rec.Reads.Count - 1] }
      return & $finish
    }
    & $add $names[2] $true "so trước/sau: $(if ($cmpWhy) { $cmpWhy } else { 'lớp mẫu chữ' }), Enter 1 lần — $($res.Message)"

    # 4. chờ xong lượt: turn tăng (hoặc đã thấy working) rồi hết working, ô nhập trống
    $done = $false; $seenWork = $false; $why = 'agent chưa xong lượt'
    for ($i = 0; $i -lt $turnTries -and -not $done; $i++) {
      if ($i -gt 0) { & $ops.Sleep 2000 }
      $info = & $ops.Get $name
      $st = Get-TermStatus $info
      if (-not $info -or $info.state -ne 'live') { $why = 'terminal tắt'; break }
      if ($st.State -eq 'blocked') { $why = 'agent đang chờ duyệt'; break }
      if ($st.State -eq 'working') { $seenWork = $true; continue }
      $newTurn = $turn0 -ge 0 -and $null -ne $info.turn -and [int]$info.turn -gt $turn0
      if (-not $newTurn -and -not $seenWork) { continue }
      $screen = "$(& $ops.Read $name)"
      if (Get-ScreenDialog $screen) { $why = 'hộp thoại sau lượt'; break }
      $box = Get-SendBox $screen
      if (-not $box -or -not $box.Text) { $done = $true } else { $why = "ô nhập còn chữ: $($box.Text)" }
    }
    $screens['03-reply'] = "$(& $ops.Read $name)"
    if (-not $done) { & $add $names[3] $false $why; return & $finish }
    & $add $names[3] $true "turn $turn0 → $($info.turn), ô nhập trống"

    # 5. /clear (Claude) hoặc /new (Codex) qua Invoke-SendFlow chế độ phiên mới (Test-SessionReady), gửi trần
    $res = Invoke-SendFlow $name $slash $ops $kind 10 $true
    $last = "$(& $ops.Read $name)"
    $screens['04-reset'] = $last
    if (-not $res.Ok) { & $add $names[4] $false $res.Message; return & $finish }
    & $add $names[4] $true $res.Message
    & $finish
  } catch {
    if ("$_" -notlike 'PROBE-GUARD:*') { throw }
    $verified = $false
    $cur = @($names | Where-Object { $n = $_; -not @($steps | Where-Object { $_.Step -eq $n }).Count }) | Select-Object -First 1
    & $add $cur $false "$("$_" -replace '^PROBE-GUARD:\s*', '') — dừng, không bấm thêm, không đóng (xem: hc ls)"
    return & $finish
  } finally {
    # chỉ đóng terminal đã xác nhận (address + cwd), và Close tự kiểm lại lần nữa
    if ($started -and $verified -and $address) { try { & $probeRaw.Close $name $address $cwd } catch { } }
  }
}

# Bảng kết quả: bước · đạt/hụt · lý do.
function Format-ProbeTable($steps) {
  $w = [Math]::Max(10, (@($steps | ForEach-Object { $_.Step.Length }) | Measure-Object -Maximum).Maximum)
  @(foreach ($s in @($steps)) { ("  {0,-$w}  {1,-6}  {2}" -f $s.Step, $s.Status, $s.Reason) })
}

# Lưu màn hình probe: <root>/<agent>-<phiên bản>-<yyyyMMdd-HHmmss>/<tên>.txt + steps.txt (UTF-8 không BOM). Trả thư mục.
# Thư mục HOME của người dùng ⇒ '~' (không phân biệt hoa thường, cả \ và /; chỉ khi hết tên thư mục: C:\Users\ann không ăn C:\Users\anna).
# Màn hình probe hay thành fixture trong tests/: không mang đường dẫn cá nhân.
function Hide-ProbeHome([string]$text, [string]$homeDir = $HOME) {
  $h = "$homeDir".TrimEnd('\', '/')
  if (-not $text -or $h.Length -lt 2) { return $text }
  $alts = @($h.Replace('/', '\'), $h.Replace('\', '/')) | Select-Object -Unique | ForEach-Object { [regex]::Escape($_) }
  [regex]::Replace($text, '(?:' + ($alts -join '|') + ')(?![\w.-])', '~', 'IgnoreCase')
}

function Save-ProbeScreens([string]$root, [string]$kind, [string]$version, $result, [datetime]$at = (Get-Date), [string]$homeDir = $HOME) {
  $ver = if ($version) { $version } else { 'unknown' }
  $dir = Join-Path $root ("{0}-{1}-{2}" -f $kind, $ver, $at.ToString('yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force $dir | Out-Null
  $utf8 = [Text.UTF8Encoding]::new($false)
  foreach ($k in $result.Screens.Keys) { [IO.File]::WriteAllText((Join-Path $dir "$k.txt"), (Hide-ProbeHome "$($result.Screens[$k])" $homeDir), $utf8) }
  [IO.File]::WriteAllText((Join-Path $dir 'steps.txt'), (Hide-ProbeHome (((Format-ProbeTable $result.Steps) -join "`n") + "`n") $homeDir), $utf8)
  $dir
}

# Đạt hết ⇒ ghi bản agent là đã kiểm trên máy này (agents.json, mục tested — Get-AgentTestedVersion lấy bản lớn hơn). Bản cũ hơn tested ⇒ giữ.
function Set-ProbeTested([string]$kind, [string]$version) {
  $key = Get-CrewAgentKey $kind
  if (-not $key -or -not $version) { return $false }
  $entry = (Read-CrewAgentsFile).Data[$key]
  if ($entry -is [hashtable] -and $entry.tested -and (Compare-CrewVersion $version "$($entry.tested)") -eq -1) { return $false }
  Set-CrewAgentsEntry $key @{ tested = $version }
  $true
}

# $ops/$tmpRoot: test tiêm hc giả và thư mục gốc tạm (mặc định thư mục tạm của hệ thống).
function Invoke-ProbeCommand($ops = $null, [string]$tmpRoot = '') {
  $kind = "$Name".ToLowerInvariant()
  if ($kind -notin 'claude', 'codex') { Die 'dùng: crew probe <claude|codex>' @('crew probe claude', 'crew probe codex') }
  if (-not (Get-Command hc -ErrorAction Ignore)) { Die 'không thấy hc trên PATH.' 'mở herdr-app (cài hc), rồi chạy lại: crew doctor' }
  if (-not (Get-Command $kind -ErrorAction Ignore)) { Die "không thấy $kind trên PATH." 'cài agent (xem: crew doctor), rồi chạy lại crew probe' }
  if (-not $ops) { $ops = New-ProbeOps }
  $version = ''
  if ("$(Invoke-AgentVersionCommand $kind 5000)" -match '(\d+(?:\.\d+)+)') { $version = $Matches[1] }
  $id = [guid]::NewGuid().ToString('N')
  $term = "crewprobe-$kind-$($id.Substring(0, 8))"
  # thư mục mới duy nhất (GUID đủ); chỉ xóa đệ quy khi chính lượt này tạo được nó (không -Force lên thư mục có sẵn)
  $cwd = Join-Path $(if ($tmpRoot) { $tmpRoot } else { [IO.Path]::GetTempPath() }) "crewline-probe-$kind-$id"
  $made = $false
  Say "probe $kind $(if ($version) { $version } else { '(không rõ phiên bản)' }): terminal tạm $term ở $cwd (agent sẽ trả lời 1 tin ngắn)"
  try {
    if (Test-Path -LiteralPath $cwd) { Die "thư mục tạm $cwd đã có sẵn — không dùng, không xóa." 'chạy lại crew probe (tên thư mục mới ngẫu nhiên)' }
    New-Item -ItemType Directory $cwd -ErrorAction Stop | Out-Null
    $made = $true
    $g = Invoke-GitQuiet -C $cwd init -q
    if ($g.Code -ne 0) { Die "git init thư mục tạm thất bại: $($g.Text)" 'kiểm git: git --version, rồi chạy lại crew probe' }
    $result = Invoke-Probe $kind $term $cwd (Get-ProbeCommandLine $kind $Access) $ops
  } finally {
    for ($i = 0; $made -and $i -lt 10 -and (Test-Path -LiteralPath $cwd); $i++) {
      try { Remove-Item -LiteralPath $cwd -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 500 }
    }
  }
  $dir = Save-ProbeScreens (Get-ProbeRoot) $kind $version $result
  Write-Host "crew probe $kind $version"
  Format-ProbeTable $result.Steps | ForEach-Object { Write-Host $_ }
  Say "màn hình đã lưu: $dir"
  if ($made -and (Test-Path -LiteralPath $cwd)) { Say "chưa xóa được thư mục tạm $cwd (agent còn giữ file?) — xóa tay sau." }
  if (-not $result.Ok) {
    Die "crew probe ${kind}: có bước hụt — crew có thể chưa nhận ra giao diện $kind $version." @(
      "cập nhật Crewline: $(Get-CrewInstallCommand)",
      'Tạm thời: khi crew send/review báo không chắc (nobox/stuck…), xem hc read <terminal> --lines 20; thấy tin nằm đúng ô nhập thì: crew confirm <terminal>',
      "Màn hình ở $dir (chỉ gửi người bảo trì Crewline khi bạn đồng ý)")
  }
  if (Set-ProbeTested $kind $version) { Say "đạt hết: ghi $kind $version là bản đã kiểm trên máy này ($(Get-CrewAgentsFile))." }
  elseif (-not $version) { Say 'đạt hết, nhưng không đọc được phiên bản agent nên không ghi bản đã kiểm.' }
  else { Say "đạt hết ($kind $version; bản đã kiểm trên máy này đã mới hơn hoặc bằng)." }
}

# ---- crew confirm ----
# Hàm thuần: Enter được không? $info = hc get, $screen = hc read (đọc 1 lần). Agent rảnh (không working/blocked), không hộp thoại
# (Get-ScreenDialog, kể cả trust/'other'), ô nhập nhận được (Get-SendBox) đúng loại app và có chữ. Ra @{ Ok; Reason; Kind; Text }.
function Get-ConfirmPlan($info, [string]$screen) {
  $no = { param($why) @{ Ok = $false; Reason = $why; Kind = ''; Text = '' } }
  if (-not $info -or $info.state -ne 'live') { return & $no 'terminal không live' }
  $st = Get-TermStatus $info
  if ($st.State -eq 'blocked') { return & $no 'agent đang chờ duyệt' }
  if ($st.State -eq 'working') { return & $no 'agent đang chạy (working), tin trong ô sẽ được đọc khi xong lượt' }
  $kind = @{ codex = 'codex'; 'claude-code' = 'claude'; claude = 'claude' }["$($st.App)"]
  if (-not $kind) {
    if ($st.App) { return & $no "app $($st.App) không phải Claude/Codex" }
    $kind = if (Test-AgentScreen 'codex' $screen) { 'codex' } elseif (Test-AgentScreen 'claude' $screen) { 'claude' } else { '' }
    if (-not $kind) { return & $no 'không phải agent (shell)' }
  }
  $dlg = Get-ScreenDialog $screen
  if ($dlg) { return & $no "màn hình có hộp thoại ($dlg)" }
  $box = Get-SendBox $screen
  if (-not $box) { return & $no 'không nhận ra ô nhập' }
  if ($box.Kind -ne $kind) { return & $no "ô nhập kiểu $($box.Kind), app $kind" }
  if (-not $box.Text) { return & $no 'ô nhập trống' }
  @{ Ok = $true; Reason = 'ok'; Kind = $kind; Text = $box.Text }
}

# Task chờ review mà crew review chưa chắc: reviewUnsure ⇒ bỏ (giữ reviewSentAt); chưa có reviewSentAt mà ô nhập Rev nhắc nhánh
# crew/<tên> của task ⇒ ghi reviewSentAt (như crew review -Sent). Trả tên task đã đổi.
# Hàm thuần: nhánh trong tin giao Rev do crew sinh (Format-ReviewMessage), hoặc @() nếu chữ không đúng khuôn đó:
# 'Rev <mức>: merge <nhánh> (<commit>)[ rồi <nhánh> (<commit>)…][ (đúng thứ tự này)]. Đọc <note>…. Full test, crew clean <tên>…, báo planner. Không push.'
# Chấp nhận một lớp vỏ <hc from="…">…</hc> và khoảng trắng gói dòng của TUI. Tin thường có nhắc crew/<tên> ⇒ @().
function Get-ReviewMessageBranches([string]$text) {
  $t = ("$text" -replace '\s+', ' ').Trim()
  $m = [regex]::Match($t, '^<hc\s+from="[^"]*">\s*(.*?)\s*</hc>$')
  if ($m.Success) { $t = $m.Groups[1].Value }
  $m = [regex]::Match($t, '^Rev (?:Gọn|Nhanh|Đủ): merge (?<list>.+?)(?: \(đúng thứ tự này\))?\. Đọc (?<notes>context/tasks/\S+\.md(?:, context/tasks/\S+\.md)*)(?: của từng task)?\. Full test, (?<clean>crew clean \S+(?:, crew clean \S+)*), báo planner\. Không push\.$')
  if (-not $m.Success) { return @() }
  $items = @($m.Groups['list'].Value -split ' rồi ')
  $branches = @(foreach ($it in $items) {
    $im = [regex]::Match($it, '^(?<b>\S+) \((?<c>[^()]*|\(đã merge\))\)$')
    if (-not $im.Success) { return @() }
    $im.Groups['b'].Value
  })
  $cleans = @([regex]::Matches($m.Groups['clean'].Value, 'crew clean (\S+)') | ForEach-Object { $_.Groups[1].Value })
  if ($cleans.Count -ne $branches.Count) { return @() }
  $branches
}

# Chỉ khi ô nhập Rev là ĐÚNG tin giao review crew sinh (Get-ReviewMessageBranches) — task có nhánh trong tin đó: bỏ reviewUnsure,
# chưa có reviewSentAt thì ghi (như crew review -Sent). Task khác giữ nguyên (kể cả reviewUnsure). Trả tên task đã đổi.
function Update-ConfirmReview([string]$root, [string]$boxText) {
  $changed = [Collections.Generic.List[string]]::new()
  $branches = @(Get-ReviewMessageBranches $boxText)
  if (-not $branches.Count) { return , [string[]]@() }
  $now = [DateTime]::UtcNow
  Update-Tasks $root { param($tasks)
    foreach ($t in $tasks) {
      if (-not $t.branch -or $branches -cnotcontains "$($t.branch)") { continue }
      $did = $false
      if ($t.PSObject.Properties['reviewUnsure']) { $t.PSObject.Properties.Remove('reviewUnsure'); $did = $true }
      if (-not $t.reviewSentAt) {
        $t | Add-Member -NotePropertyName reviewSentAt -NotePropertyValue $now.AddMilliseconds($changed.Count).ToString('o') -Force
        $did = $true
      }
      if ($did) { $changed.Add("$($t.name)") }
    }
    $tasks
  } | Out-Null
  , [string[]]@($changed)
}

function Invoke-ConfirmCore([string]$term, $ops, [string]$root = '', [string]$slug = '') {
  $info = & $ops.Get $term
  $screen = "$(& $ops.Read $term)"
  $plan = Get-ConfirmPlan $info $screen
  if (-not $plan.Ok) { return @{ Ok = $false; Message = "$term`: $($plan.Reason) — không bấm Enter."; Changed = @() } }
  # đọc lại trạng thái SÁT trước phím: phải vẫn live, không blocked/working, cùng address/app/turn (pane bị thay cùng tên, hộp duyệt
  # hiện lên, agent chạy lượt mới ⇒ không bấm)
  $now = & $ops.Get $term
  $a = Get-TermStatus $info; $b = Get-TermStatus $now
  if (-not $now -or $now.state -ne 'live' -or $b.State -in 'blocked', 'working' -or "$($now.address)" -cne "$($info.address)" -or
      "$($b.App)" -cne "$($a.App)" -or "$($now.turn)" -ne "$($info.turn)") {
    return @{ Ok = $false; Message = "$term đổi ngay trước khi bấm (trạng thái $($b.State), turn $($info.turn)→$($now.turn)) — không bấm Enter."; Changed = @() }
  }
  # Keys phải trả $true (hc keys exit 0); không chắc phím đã tới ⇒ không coi là đã gửi, không đổi task
  if ((& $ops.Keys $term) -ne $true) { return @{ Ok = $false; Message = "$term`: hc keys enter thất bại — không chắc Enter đã tới, không đổi trạng thái review."; Changed = @() } }
  $changed = if ($root -and $slug -and $term -ceq "$slug-rev") { Update-ConfirmReview $root $plan.Text } else { @() }
  $shown = if ($plan.Text.Length -gt 200) { $plan.Text.Substring(0, 200) + '…' } else { $plan.Text }
  @{ Ok = $true; Message = "đã bấm Enter 1 lần ở $term (ô nhập: $shown)"; Changed = @($changed) }
}

function Invoke-Confirm {
  if (-not $Name) { Die 'dùng: crew confirm <terminal>' @('xem tin còn nằm ô nhập: hc read <terminal> --lines 20', 'crew confirm <crew>-rev') }
  $ops = New-HcOps
  $ops.Keys = { param($term) & { $ErrorActionPreference = 'Continue'; hc keys $term enter 2>&1 } | Out-Null; $LASTEXITCODE -eq 0 }
  $root = Get-MainRoot (Get-Location).Path
  $slug = ''
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    $slug = Get-CrewName $root (Get-Config $root)
    if ($Name -like "$slug-*") {
      $why = Get-ForeignTermError $Name (& $ops.Get $Name) $root
      if ($why) { Die "$why Không bấm phím." 'xem mục "Tên crew trùng" trong docs/troubleshooting.md (thư mục cài Crewline)' }
    }
  } else { $root = '' }
  $r = Invoke-ConfirmCore $Name $ops $root $slug
  if (-not $r.Ok) { Die $r.Message @("xem: hc read $Name --lines 20", 'chỉ dùng crew confirm khi tin nằm đúng ô nhập và agent rảnh, không có hộp thoại') }
  Say $r.Message
  if ($r.Changed.Count) { Say "đánh dấu Rev đã nhận review: $($r.Changed -join ', ')" }
}
