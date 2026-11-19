# ---------------- danh tính git ----------------
# Lỗi của git khi dựng danh tính, rỗng là commit được. Hỏi chính git, cần cả hai: chỉ có GIT_COMMITTER_* thì committer qua mà author vẫn lỗi.
# $with: thêm '-c k=v' để thử giá trị chưa lưu.
function Get-GitIdentityError([string]$dir, [string[]]$with = @()) {
  $at = @(if ($dir) { '-C', $dir }) + $with
  foreach ($v in 'GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT') {
    $r = Invoke-GitQuiet @at var $v
    if ($r.Code -ne 0) { return (@($r.Text -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 1) -replace '^fatal:\s*', '' }
  }
  ''
}

function Get-GitIdentityFix { @('git config --global user.name "Tên của bạn"', 'git config --global user.email "ban@example.com"') }

# Dừng khi bắt buộc phải có danh tính mà không có: in đúng 2 lệnh tự đặt, không ghi gì.
function Stop-GitIdentity([string]$why) {
  Write-Host "crew: LỖI: $why Đặt bằng 2 lệnh này rồi chạy lại:" -ForegroundColor Red
  Get-GitIdentityFix | ForEach-Object { Write-Host "  $_" }
  Write-Host '  → Làm tiếp: chạy 2 lệnh trên (thay tên/email của bạn) rồi chạy lại lệnh crew; xem mục "Git chưa có tên hoặc email" trong docs/troubleshooting.md (thư mục cài Crewline)'
  exit 1
}

# Một dòng từ người dùng; $null khi stdin hết. Console Windows đọc theo code page nên chữ Việt thành '?' nếu không chuyển sang đọc Unicode.
function Read-GitIdentityLine([string]$label) {
  Write-Host "${label}: " -NoNewline
  $saved = $null
  try {
    if ($IsWindows -ne $false -and -not [Console]::IsInputRedirected) {
      $before = [Console]::InputEncoding
      [Console]::InputEncoding = [Text.Encoding]::Unicode
      $saved = $before
    }
  } catch { $saved = $null }
  try { [Console]::ReadLine() }
  finally { if ($saved) { try { [Console]::InputEncoding = $saved } catch { $null = $_ } } }
}

# Giá trị đã nhập; '' khi trống hai lần; $null khi stdin hết.
function Read-GitIdentityField([string]$label) {
  for ($i = 0; $i -lt 2; $i++) {
    $line = Read-GitIdentityLine $label
    if ($null -eq $line) { Write-Host ''; return $null }
    if ($line.Trim()) { return $line.Trim() }
    if ($i -eq 0) { Write-Host '  Không được bỏ trống, nhập lại.' }
  }
  ''
}

# Lưu các khóa vào cấu hình git toàn máy rồi kiểm lại bằng git. Trả lỗi hoặc ''; lỗi thì gỡ đúng những khóa vừa ghi (trước đó chúng còn thiếu).
function Save-GitIdentity([string]$dir, $values) {
  $written = @()
  $why = ''
  foreach ($k in @($values.Keys)) {
    $r = Invoke-GitQuiet config --global $k $values[$k]
    if ($r.Code -ne 0) { $why = $r.Text; break }
    $written += $k
  }
  if (-not $why) { $why = Get-GitIdentityError $dir }
  if ($why) { foreach ($k in $written) { Invoke-GitQuiet config --global --unset $k | Out-Null } }
  $why
}

# Bảo đảm git có danh tính trước việc cần commit; gọi trước khi tạo/ghi bất cứ gì. Đã có ⇒ im lặng, không ghi.
# $required: việc này commit ngay, không có danh tính thì dừng. Không $required (crew up project đã init): không có người thì cảnh báo và chạy tiếp.
function Confirm-GitIdentity([string]$dir, [bool]$required, [bool]$dry) {
  # Con của crew up -All không đọc được stdin qua pipe của cha; cha đã hỏi hoặc cảnh báo một lần cho cả lượt.
  if (-not $required -and $env:CREWLINE_UP_ALL_CHILD -eq '1') { return }
  if (-not (Get-GitIdentityError $dir)) { return }
  if ($dry) { Say 'git chưa có tên/email: khi chạy thật crew sẽ hỏi rồi lưu vào cấu hình git toàn máy (DryRun không hỏi, không ghi).'; return }
  $noOne = {
    if ($required) { Stop-GitIdentity 'git chưa có tên/email để commit và không có người để hỏi, crew không tạo gì.' }
    Say "cảnh báo: git chưa có tên/email nên agent chưa commit được; đặt bằng: $((Get-GitIdentityFix) -join ' ; ')"
  }
  # Tiến trình nền không có người ngồi trước màn hình, đọc stdin sẽ treo.
  if ($env:CREWLINE_DEFAULTS -eq '1' -or $Command -like 'self-pane-*') { & $noOne; return }
  $fields = [ordered]@{}
  foreach ($k in 'user.name', 'user.email') {
    $r = Invoke-GitQuiet -C $dir config --get $k
    if ($r.Code -ne 0 -or -not $r.Text) { $fields[$k] = @{ 'user.name' = 'Tên'; 'user.email' = 'Email' }[$k] }
  }
  if (-not $fields.Count) {
    # Config đã đủ mà git vẫn từ chối (giá trị hỏng, biến môi trường rỗng): không ghi đè giá trị có sẵn.
    $why = "git từ chối danh tính hiện có: $(Get-GitIdentityError $dir)."
    if ($required) { Stop-GitIdentity $why }
    Say "cảnh báo: $why Agent chưa commit được."
    return
  }
  Write-Host 'Git cần tên và email để ghi vào commit trong project này.'
  Write-Host 'Đây là yêu cầu của git, không phải của Crewline: crew cần commit để'
  Write-Host 'tạo worktree riêng cho từng worker. Crewline không thu thập hay gửi'
  Write-Host 'thông tin này đi đâu. Tên và email không cần là tài khoản thật.'
  for ($try = 1; ; $try++) {
    $values = [ordered]@{}
    $with = @()
    foreach ($k in @($fields.Keys)) {
      $v = Read-GitIdentityField $fields[$k]
      if ($null -eq $v) { & $noOne; return }
      if (-not $v) { Stop-GitIdentity 'chưa có tên/email (bỏ trống hai lần), crew không tạo gì.' }
      $values[$k] = $v
      $with += '-c', "$k=$v"
    }
    # Thử bằng -c trước để giá trị git loại không bao giờ nằm lại trong cấu hình toàn máy.
    $why = Get-GitIdentityError $dir $with
    if (-not $why) { $why = Save-GitIdentity $dir $values }
    if (-not $why) {
      Say "đã lưu $(@($values.Keys | ForEach-Object { "$_=$($values[$_])" }) -join ', ') vào cấu hình git toàn máy; đổi bằng git config --global user.name/user.email."
      return
    }
    Write-Host "  Git không nhận giá trị này: $why" -ForegroundColor Yellow
    if ($try -ge 3) { Stop-GitIdentity 'git từ chối các giá trị đã nhập, crew không tạo gì.' }
    Write-Host '  Nhập lại.'
  }
}
