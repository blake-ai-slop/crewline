# ---------------- agents: bản Claude Code / Codex đã kiểm + kiểm bản Crewline public ----------------
# Bản agent mà lần phát hành Crewline này đã kiểm (chỗ duy nhất; sửa khi phát hành).
function Get-CrewTestedAgents { @{ claude = '2.1.330'; codex = '0.171.0' } }

# Cache theo ngày: ~/.crewline/agents.json
#   { claude: { version, checkedAt, tested? }, codex: {…}, crewline: { latest, checkedAt } }
#   version = bản đang cài (claude/codex --version), checkedAt = yyyy-MM-dd lần đọc; tested (tùy chọn) = bản đã kiểm thêm trên máy này
#   (bản đã kiểm hiệu lực = bản lớn hơn giữa tested và Get-CrewTestedAgents). crewline.latest = VERSION của repo public.
# CREWLINE_AGENTS_FILE đổi đường dẫn (test). File hỏng ⇒ không ghi đè (giữ byte), vẫn tính được nhưng không cache.
function Get-CrewAgentsFile {
  if ($env:CREWLINE_AGENTS_FILE) { return $env:CREWLINE_AGENTS_FILE }
  Join-Path $HOME '.crewline/agents.json'
}

function Read-CrewAgentsFile {
  $file = Get-CrewAgentsFile
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @{ Ok = $true; Data = @{} } }
  try {
    $text = [IO.File]::ReadAllText($file)
    if (-not $text.Trim()) { return @{ Ok = $true; Data = @{} } }
    $data = $text | ConvertFrom-Json -AsHashtable
    if ($data -isnot [hashtable]) { throw 'cần một JSON object' }
    @{ Ok = $true; Data = $data }
  } catch { @{ Ok = $false; Data = @{} } }
}

# Đọc-sửa-ghi một mục dưới khóa ~/.crewline/agents.lock (lệnh crew song song không ghi đè mục của nhau); lỗi ⇒ bỏ qua (chỉ là cache).
function Set-CrewAgentsEntry([string]$key, [hashtable]$fields) {
  $file = Get-CrewAgentsFile
  $lock = $null
  try {
    $dir = Split-Path -Parent $file
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $lockPath = Join-Path $dir 'agents.lock'
    for ($i = 0; -not $lock; $i++) {
      try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
      catch { if ($i -ge 25) { return }; Start-Sleep -Milliseconds 40 }
    }
    $read = Read-CrewAgentsFile
    if (-not $read.Ok) { return }
    $entry = if ($read.Data[$key] -is [hashtable]) { $read.Data[$key] } else { @{} }
    foreach ($k in $fields.Keys) { $entry[$k] = $fields[$k] }
    $read.Data[$key] = $entry
    Write-CrewStateFile $file (($read.Data | ConvertTo-Json -Depth 100) + "`n")
  } catch { }
  finally { if ($lock) { $lock.Dispose() } }
}

# So hai phiên bản dạng số chấm (15, 15.1, 0.171.0); thiếu đoạn = 0. Trả -1/0/1; chuỗi không hợp lệ ⇒ $null.
# (Gộp với hàm so sánh của task version-xy khi cả hai đã merge.)
function Compare-CrewVersion([string]$a, [string]$b) {
  if ("$a".Trim() -notmatch '^\d+(\.\d+)*$' -or "$b".Trim() -notmatch '^\d+(\.\d+)*$') { return $null }
  $x = @("$a".Trim() -split '\.' | ForEach-Object { [long]$_ })
  $y = @("$b".Trim() -split '\.' | ForEach-Object { [long]$_ })
  for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
    $p = if ($i -lt $x.Count) { $x[$i] } else { 0 }
    $q = if ($i -lt $y.Count) { $y[$i] } else { 0 }
    if ($p -ne $q) { return $(if ($p -gt $q) { 1 } else { -1 }) }
  }
  0
}

function Get-CrewAgentKey([string]$kind) { @{ claude = 'claude'; 'claude-code' = 'claude'; codex = 'codex' }["$kind"] }

# Chạy `<lệnh> --version` có giới hạn thời gian (mặc định 2s): hết giờ ⇒ kill cả cây tiến trình, trả ''. Không ném lỗi.
# Cùng thư mục có nhiều bản (npm: x.ps1/x.cmd/x) ⇒ ưu tiên .exe, rồi .cmd/.bat (không tốn khởi động pwsh), rồi .ps1, rồi bản không đuôi.
function Invoke-AgentVersionCommand([string]$name, [int]$timeoutMs = 2000) {
  $proc = $null
  try {
    $all = @(Get-Command $name -CommandType Application, ExternalScript -All -ErrorAction Ignore | Where-Object { $_.Source })
    if (-not $all.Count) { return '' }
    $dir = Split-Path -Parent $all[0].Source
    $same = @($all | Where-Object { (Split-Path -Parent $_.Source) -eq $dir })
    $rank = { param($c) switch ([IO.Path]::GetExtension($c.Source).ToLowerInvariant()) { '.exe' { 0 } '.cmd' { 1 } '.bat' { 1 } '.ps1' { 2 } default { 3 } } }
    $src = ($same | Sort-Object { & $rank $_ } | Select-Object -First 1).Source
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $ext = [IO.Path]::GetExtension($src).ToLowerInvariant()
    if ($ext -eq '.ps1') {
      $psi.FileName = [Environment]::ProcessPath
      foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $src) { $psi.ArgumentList.Add($a) }
    } elseif ($ext -in '.cmd', '.bat') {
      $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
      # /s + cả dòng trong ngoặc kép: cmd chỉ bỏ cặp ngoặc ngoài, đường dẫn giữ trong "…" nên & ( ) dấu cách là chữ thường
      # (đường dẫn Windows không chứa "). Không dùng ArgumentList: .NET thoát ngoặc kiểu C, cmd không hiểu.
      $psi.Arguments = '/d /s /c ""' + $src + '" --version"'
    } else { $psi.FileName = $src }
    if ($ext -ne '.cmd' -and $ext -ne '.bat') { $psi.ArgumentList.Add('--version') }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeoutMs)) {
      try { $proc.Kill($true) } catch { }
      return ''
    }
    if (-not $out.Wait(500)) { return '' }
    "$($out.Result)"
  } catch { '' }
  finally { if ($proc) { $proc.Dispose() } }
}

# Bản agent đang cài: cache theo ngày trong agents.json, hết hạn ⇒ `<agent> --version` (1 lần/ngày, ≤2s). Không có lệnh/không đọc được/hết giờ ⇒ ''
# (vẫn cache ngày đó, không cảnh báo).
function Get-AgentInstalledVersion([string]$kind) {
  $key = Get-CrewAgentKey $kind
  if (-not $key) { return '' }
  $today = Get-Date -Format 'yyyy-MM-dd'
  $entry = (Read-CrewAgentsFile).Data[$key]
  if ($entry -is [hashtable] -and "$($entry.checkedAt)" -eq $today) { return "$($entry.version)" }
  $version = ''
  $out = Invoke-AgentVersionCommand $key
  if ($out -match '(\d+(?:\.\d+)+)') { $version = $Matches[1] }
  Set-CrewAgentsEntry $key @{ version = $version; checkedAt = $today }
  $version
}

# Bản đã kiểm hiệu lực: hằng số của bản Crewline này, hoặc `tested` trong agents.json nếu lớn hơn.
function Get-AgentTestedVersion([string]$kind) {
  $key = Get-CrewAgentKey $kind
  if (-not $key) { return '' }
  $tested = (Get-CrewTestedAgents)[$key]
  $entry = (Read-CrewAgentsFile).Data[$key]
  if ($entry -is [hashtable] -and $entry.tested -and (Compare-CrewVersion "$($entry.tested)" $tested) -eq 1) { $tested = "$($entry.tested)" }
  $tested
}

# '' hoặc "Codex 0.172.0 mới hơn bản Crewline này đã kiểm (0.171.0)". Không bao giờ ném lỗi.
function Get-AgentVersionNotice([string]$kind) {
  try {
    $key = Get-CrewAgentKey $kind
    if (-not $key) { return '' }
    $installed = Get-AgentInstalledVersion $kind
    $tested = Get-AgentTestedVersion $kind
    if (-not $installed -or (Compare-CrewVersion $installed $tested) -ne 1) { return '' }
    $label = @{ claude = 'Claude Code'; codex = 'Codex' }[$key]
    "$label $installed mới hơn bản Crewline này đã kiểm ($tested)"
  } catch { '' }
}

# Hợp đồng cho send/task: '' hoặc một bước "→ Làm tiếp:" (chuỗi) để THÊM vào next của Die. Không bao giờ ném lỗi.
function Get-AgentVersionHint([string]$kind) {
  try {
    $notice = Get-AgentVersionNotice $kind
    if (-not $notice) { return '' }
    "$notice — có thể crew chưa nhận ra giao diện mới: cập nhật Crewline ($(Get-CrewInstallCommand)) hoặc báo planner"
  } catch { '' }
}

function Get-CrewPublicVersionUrl { 'https://raw.githubusercontent.com/blake-ai-slop/crewline/main/VERSION' }

# Đọc text qua mạng, timeout ngắn; lỗi ⇒ ném (người gọi im lặng). Tách riêng để test thay bằng bản giả.
function Invoke-CrewFetch([string]$url) {
  (Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop).Content
}

# Bản Crewline public (cache 1 lần/ngày, kể cả khi lỗi mạng). CREWLINE_NO_UPDATE_CHECK=1 ⇒ không kiểm.
# '' hoặc "Có Crewline v16: cập nhật bằng <lệnh cài>".
function Get-CrewUpdateNotice {
  try {
    if ($env:CREWLINE_NO_UPDATE_CHECK -eq '1') { return '' }
    $installed = (Get-CrewVersion 3>$null).Version
    if (-not $installed -or $installed -eq '?') { return '' }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $entry = (Read-CrewAgentsFile).Data['crewline']
    if ($entry -is [hashtable] -and "$($entry.checkedAt)" -eq $today) { $latest = "$($entry.latest)" }
    else {
      $latest = ''
      try {
        $text = "$(Invoke-CrewFetch (Get-CrewPublicVersionUrl))".Trim()
        if ($text -match '\A[1-9][0-9]*(\.[1-9][0-9]*)?\z') { $latest = $text }
      } catch { }
      Set-CrewAgentsEntry 'crewline' @{ latest = $latest; checkedAt = $today }
    }
    if ($latest -and (Compare-CrewVersion $latest $installed) -eq 1) { return "Có Crewline v${latest}: cập nhật bằng $(Get-CrewInstallCommand)" }
    ''
  } catch { '' }
}

# crew hot: mỗi loại agent trong config mới hơn bản đã kiểm ⇒ 1 dòng vàng; public mới hơn ⇒ 1 dòng vàng. Không chặn, không ném lỗi.
function Show-CrewAgentNotices($cfg) {
  $kinds = @(@($cfg.planner) + @($cfg.rev) + @($cfg.workers) | ForEach-Object { Get-CrewAgentKey "$_" } | Where-Object { $_ } | Select-Object -Unique)
  foreach ($kind in $kinds) {
    $notice = Get-AgentVersionNotice $kind
    if ($notice) { Write-Host "crew: $notice — nếu crew không gửi được tin: cập nhật Crewline ($(Get-CrewInstallCommand)) hoặc báo planner" -ForegroundColor Yellow }
  }
  $update = Get-CrewUpdateNotice
  if ($update) { Write-Host "crew: $update" -ForegroundColor Yellow }
}
