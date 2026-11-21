# ---------------- assist (v16 mục E): planner hỗ trợ khi crew không chắc ----------------
# Nguyên tắc: crew vẫn là code cứng, 0 token. Khi crew không chắc lúc gửi (không nhận ra ô nhập, ô còn chữ khác, hộp thoại lạ,
# phiên mới chưa xác nhận, agent chưa chạy) nó KHÔNG bấm phím, chỉ in khối "CẦN PLANNER XEM" (màn hình + lý do + crew confirm <terminal>).
# v16 assist-nolearn (chủ dự án + planner chốt 2026-11-21): KHÔNG có mẫu học — crew không đọc/ghi kho mẫu nào, mọi nhận diện màn hình
# là ghi cứng trong code. Không bao giờ: trả lời hộp xin duyệt, bấm phím khác Enter, tự gửi màn hình ra ngoài.
# Nhật ký: .crew/assist.log của repo chính (thời điểm, terminal, agent+phiên bản, lý do, hành động shown|confirmed).

# Chế độ assist của repo (config .crew/config.json "assist"); không ở repo crew ⇒ 'ask'. 'off' ⇒ không in khối.
function Get-AssistRepoMode([string]$root = '') {
  try {
    if (-not $root) { $root = Get-MainRoot (Get-Location).Path }
    if (-not $root) { return 'ask' }
    $file = Join-Path $root '.crew/config.json'
    if (-not (Test-Path -LiteralPath $file)) { return 'ask' }
    Get-AssistMode (Read-CrewState $file -ThrowOnError).assist
  } catch { 'ask' }
}

# ---- nhật ký .crew/assist.log ----
function Add-AssistLog([string]$root, [string]$term, [string]$agent, [string]$reason, [string]$action) {
  if (-not $root) { return }
  try {
    $file = Join-Path $root '.crew/assist.log'
    $line = (@((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'), $term, $agent, ("$reason" -replace '[\t\r\n]+', ' '), $action) -join "`t")
    Use-CrewStateLock $root {
      $old = if (Test-Path -LiteralPath $file) { @([IO.File]::ReadAllLines($file)) } else { @() }
      $all = @($old) + $line
      if ($all.Count -gt 500) { $all = $all[($all.Count - 500)..($all.Count - 1)] }
      Write-CrewStateFile $file (($all -join "`n") + "`n")
    }
  } catch { }
}

function Get-AssistLog([string]$root) {
  $file = Join-Path $root '.crew/assist.log'
  if (-not (Test-Path -LiteralPath $file)) { return @() }
  @([IO.File]::ReadAllLines($file) | Where-Object { $_ } | ForEach-Object {
      $f = $_ -split "`t"
      [pscustomobject]@{ At = $f[0]; Term = $f[1]; Agent = $f[2]; Reason = $f[3]; Action = $f[4] }
    })
}

# Số lần crew nhờ planner xem (shown) hôm nay (giờ máy).
function Get-AssistTodayCount([string]$root, [datetime]$now = (Get-Date)) {
  $day = $now.ToString('yyyy-MM-dd')
  @(Get-AssistLog $root | Where-Object { $_.Action -eq 'shown' -and "$($_.At)".StartsWith($day) }).Count
}

# crew confirm thành công sau một lần 'shown' ở cùng terminal (chưa có hành động sau đó) ⇒ ghi 'confirmed'.
function Add-AssistConfirmLog([string]$term) {
  $root = Get-MainRoot (Get-Location).Path
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) { return }
  $last = @(Get-AssistLog $root | Where-Object { $_.Term -ceq $term }) | Select-Object -Last 1
  if ($last -and $last.Action -eq 'shown') { Add-AssistLog $root $term $last.Agent $last.Reason 'confirmed' }
}

# ---- khối "CẦN PLANNER XEM" ----
# Hàm thuần: các dòng màn hình để in: bỏ '[hc] …', khoảng trắng cuối, gộp dòng trống liền nhau, lấy ≤30 dòng cuối (đủ 20–40 khi màn hình dài).
function Get-AssistScreenExcerpt([string]$screen, [int]$max = 30) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in @("$screen" -split '\r?\n')) {
    if ($l -match '^\[hc\]') { continue }
    $l = $l.TrimEnd()
    if (-not $l -and ($out.Count -eq 0 -or -not $out[$out.Count - 1])) { continue }
    $out.Add($l)
  }
  while ($out.Count -and -not $out[$out.Count - 1]) { $out.RemoveAt($out.Count - 1) }
  $a = @($out)
  if ($a.Count -gt $max) { $a = $a[($a.Count - $max)..($a.Count - 1)] }
  , [string[]]$a
}

# Hàm thuần: khối in cho planner. $mode 'ask' | 'auto'.
function Format-AssistBlock([string]$term, [string]$agent, [string]$tested, [string]$reason, [string]$screen, [string]$mode) {
  $lines = @("==== CẦN PLANNER XEM: crew không chắc ở $term ====")
  $lines += "agent: $(if ($agent) { $agent } else { '(không rõ)' })$(if ($tested) { " · Crewline đã kiểm $tested" })"
  $lines += "lý do: $reason"
  $ex = Get-AssistScreenExcerpt $screen
  $lines += "--- màn hình ($($ex.Count) dòng cuối, hc read $term --lines 40) ---"
  $lines += @($ex | ForEach-Object { "| $_" })
  $lines += '---'
  $lines += "Tin nằm đúng ô nhập, agent rảnh, không hộp thoại:  crew confirm $term   (Enter 1 lần)"
  $lines += 'Khác (hộp thoại, ô còn chữ khác, màn hình lạ): không chạy gì — chủ dự án xử lý trong pane rồi gửi lại.'
  if ($mode -eq 'auto') { $lines += 'Chế độ auto: planner tự quyết có chạy crew confirm không rồi báo chủ dự án 1 dòng.' }
  else { $lines += 'Chế độ ask: planner đề xuất (crew confirm hoặc để chủ dự án xử lý), hỏi chủ dự án trước khi chạy.' }
  $lines += 'Không được: trả lời hộp xin duyệt, bấm phím khác Enter, sửa code crew/~/.claude/settings.json/~/.codex/config.toml, đụng task/nhánh. Hộp xin duyệt ⇒ chủ dự án xử lý.'
  $lines += 'Muốn gửi màn hình này cho Crewline không? (chỉ khi chủ dự án đồng ý; crew không tự gửi đi đâu)'
  $lines += '===='
  $lines
}

# Lý do ngắn từ kết quả gửi: Assist (verdict) + chi tiết.
function Get-AssistReason($r) { "$($r.Assist)$(if ($r.Why) { " ($($r.Why))" })" }

# In khối + ghi nhật ký 'shown'. $r: kết quả không chắc của Invoke-SendFlow/Send-CrewMessage (@{ Assist; Why; Screen }).
# $reader: test tiêm. Không bao giờ ném lỗi, không bấm phím, không đọc/ghi mẫu nào.
function Show-AssistNeeded([string]$term, $r, [string]$app = '', [scriptblock]$reader = $null) {
  try {
    if (-not $r -or -not $r.Assist) { return }
    $root = Get-MainRoot (Get-Location).Path
    if ($root -and -not (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) { $root = '' }
    $mode = Get-AssistRepoMode $root
    if ($mode -eq 'off') { return }
    $key = Get-CrewAgentKey $app
    $ver = if ($key) { try { Get-AgentInstalledVersion $key } catch { '' } } else { '' }
    $tested = if ($key) { try { (Get-CrewTestedAgents)[$key] } catch { '' } } else { '' }
    $label = if ($key) { "$(@{ claude = 'Claude Code'; codex = 'Codex' }[$key]) $(if ($ver) { $ver } else { '(bản ?)' })" } else { "$app" }
    $screen = ''
    try { $screen = if ($reader) { "$(& $reader $term)" } else { (@(& { $ErrorActionPreference = 'Continue'; hc read $term --lines 40 2>$null }) -join "`n") } } catch { }
    if (-not "$screen".Trim()) { $screen = "$($r.Screen)" }
    $reason = Get-AssistReason $r
    Format-AssistBlock $term $label $tested $reason $screen $mode | ForEach-Object { Write-Host $_ }
    if ($root) { Add-AssistLog $root $term $(if ($key) { "$key $ver" } else { "$app" }) $reason 'shown' }
  } catch { }
}
