<#
Cài Crewline cho người dùng hiện tại (Windows/Linux/macOS, herdr-app + hc).
  - shim `crew` (Windows: PowerShell + Git Bash; Unix: pwsh thực thi) trong ~/.local/bin, trỏ về repo này
  - template hc crew-* trong %APPDATA%/herdr-core/templates (Windows) hoặc $XDG_CONFIG_HOME/herdr-core/templates (~/.config mặc định trên Unix) (sao lưu bản khác trước khi ghi đè)
  - jq nếu thiếu trên Windows: tải GitHub; Unix: dùng jq của hệ
  - thêm ~/.local/bin vào PATH người dùng nếu chưa có
  - thư mục ~/.crewline/ và chọn đội mặc định khi chưa có config
Chạy lại an toàn bao nhiêu lần cũng được.
  -NoDoctor             bỏ bước `crew doctor` cuối cùng
  CREWLINE_NO_PATH=1    không ghi PATH người dùng (registry hoặc shell profile)
  CREWLINE_NO_JQ=1      không tải jq
  CREWLINE_NO_INSTALL=1 không hỏi cài phần mềm còn thiếu (vẫn in bảng kiểm)
Sau bước chọn đội: in bảng kiểm phần mềm (scripts/prereq.ps1), hỏi cài giúp mục thiếu có lệnh cài (winget/npm).
#>
param([switch]$NoDoctor)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Repo = $PSScriptRoot
. (Join-Path $Repo 'scripts/platform.ps1')
$OS = Get-CrewOS
$Bin = Get-UserBinDir
$Today = Get-Date -Format 'yyyyMMdd'
function Say($m) { Write-Host "install: $m" }

New-Item -ItemType Directory -Force $Bin | Out-Null

# ~/.crewline: mặc định cá nhân
New-Item -ItemType Directory -Force (Join-Path $HOME '.crewline') | Out-Null

if ($OS -eq 'windows') {
# shim PowerShell
$crewPs1 = Join-Path $Repo 'scripts/crew.ps1'
# crew cần pwsh 7: shim gọi từ Windows PowerShell 5.1 thì chuyển sang pwsh. Ghi UTF-8 BOM để PS 5.1 đọc đúng đường dẫn Unicode.
$crewQ = $crewPs1.Replace("'", "''")
$shim = @"
# Crewline shim - sinh boi install.ps1
if (`$PSVersionTable.PSVersion.Major -lt 7) {
  `$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not `$pwshCmd) {
    Write-Host 'crew: LOI: crew can PowerShell 7 (pwsh). Cai tu https://aka.ms/powershell (hoac: winget install Microsoft.PowerShell), mo terminal moi roi chay lai.' -ForegroundColor Red
    exit 1
  }
  try { & `$pwshCmd.Source -NoLogo -NoProfile -File '$crewQ' @args }
  catch { Write-Host "crew: LOI: khong chay duoc pwsh (`$(`$pwshCmd.Source)): `$(`$_.Exception.Message)" -ForegroundColor Red; exit 1 }
  exit `$LASTEXITCODE
}
& '$crewQ' @args
exit `$LASTEXITCODE

"@ -replace "`r`n", "`n"

$dst = Join-Path $Bin 'crew.ps1'
if ((Test-Path $dst) -and ((Get-Content $dst -Raw) -ne $shim) -and -not ((Get-Content $dst -Raw) -match 'Crewline shim')) {
  Copy-Item $dst "$dst.bak-$Today"; Say "sao lưu $dst -> crew.ps1.bak-$Today"
}
[IO.File]::WriteAllText($dst, $shim, [Text.UTF8Encoding]::new($true))
Say "shim $dst -> $crewPs1"

# shim Git Bash (Claude Code chạy lệnh qua Git Bash)
$bashShim = "#!/usr/bin/env bash`n# Crewline shim - sinh bởi install.ps1`nexec pwsh -NoLogo -NoProfile -File '$crewPs1' `"`$@`"`n"
[IO.File]::WriteAllText((Join-Path $Bin 'crew'), $bashShim.Replace("`r`n", "`n"))
Say "shim $(Join-Path $Bin 'crew') (Git Bash)"

} else {
  $crewPs1 = Join-Path $Repo 'scripts/crew.ps1'
  $crewQ = $crewPs1.Replace("'", "''")
  # The args token belongs to the generated script, not this installer.
  $shim = '#!/usr/bin/env pwsh' + "`n# Crewline shim - sinh boi install.ps1`n& '$crewQ' @args`nexit " + '$LASTEXITCODE' + "`n"
  $dst = Join-Path $Bin 'crew'
  if ((Test-Path $dst) -and ([IO.File]::ReadAllText($dst) -notmatch 'Crewline shim')) {
    Copy-Item $dst "$dst.bak-$Today"
  }
  [IO.File]::WriteAllText($dst, $shim, [Text.UTF8Encoding]::new($false))
  # PATH không có chmod (PATH tối giản): đặt +x qua .NET 7+ (UnixFileMode).
  $unixMode = 'System.IO.UnixFileMode' -as [type]
  if (-not (Get-Command chmod -ErrorAction SilentlyContinue) -and $unixMode) {
    [IO.File]::SetUnixFileMode($dst, [Enum]::ToObject($unixMode, [int][IO.File]::GetUnixFileMode($dst) -bor 0x49)) # +x cho user/group/other (0o111)
  } else {
    & chmod +x $dst
    if ($LASTEXITCODE -ne 0) { throw "chmod failed: $dst" }
  }
  Say "shim $dst -> $crewPs1"
}

# template hc
$tdir = Get-HcTemplateDir
New-Item -ItemType Directory -Force $tdir | Out-Null
foreach ($t in Get-ChildItem (Join-Path $Repo 'templates') -Filter '*.md') {
  $d = Join-Path $tdir $t.Name
  if ((Test-Path $d) -and ((Get-FileHash $d).Hash -ne (Get-FileHash $t.FullName).Hash)) {
    Copy-Item $d "$d.bak-$Today"; Say "sao lưu $($t.Name) -> $($t.Name).bak-$Today"
  }
  Copy-Item $t.FullName $d -Force
}
Say "template hc -> $tdir"

# jq
if ($env:CREWLINE_NO_JQ -eq '1') {
  Say "bỏ qua jq (CREWLINE_NO_JQ=1)"
} elseif ($OS -eq 'windows' -and -not (Get-Command jq -ErrorAction SilentlyContinue)) {
  Say "tải jq 1.8.1"
  Invoke-WebRequest 'https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-windows-amd64.exe' -OutFile (Join-Path $Bin 'jq.exe')
}

# PATH
$binPath = (Resolve-Path $Bin).Path
if ($env:CREWLINE_NO_PATH -eq '1') { Say 'bỏ qua PATH người dùng (CREWLINE_NO_PATH=1)' }
elseif (Add-UserPath $binPath) { Say "thêm $binPath vào PATH người dùng (mở terminal mới để nhận)." }
$separator = [IO.Path]::PathSeparator
if (-not (($env:Path -split [regex]::Escape("$separator")) -contains $binPath)) { $env:Path = "$binPath$separator$env:Path" }
$configFile = if ($env:CREWLINE_USER_CONFIG) { $env:CREWLINE_USER_CONFIG } else { Join-Path $HOME '.crewline/config.json' }
if (Test-Path -LiteralPath $configFile) {
  Say "đã có config cá nhân, chạy 'crew setup' để đổi"
} elseif ($env:CREWLINE_DEFAULTS -ne '1') {
  & (Join-Path $Repo 'scripts/setup.ps1')
}

# Kiểm phần mềm: bắt buộc + agent theo đội (không có config => standard).
. (Join-Path $Repo 'scripts/prereq.ps1')
. (Join-Path $Repo 'scripts/ui.ps1')
# Console cũ của PS 5.1 thường không có glyph ✓/✗ (giống setup.ps1).
$fancy = $PSVersionTable.PSEdition -eq 'Core'
$arrow = if ($fancy) { '→' } else { '->' }
$team = Get-PrereqTeam @($configFile) (Join-Path $Repo 'scripts/teams.json')
$need = Get-TeamAgents $team
$items = @(Get-Prereqs | Where-Object { $_.Group -eq 'required' -or ($_.Group -eq 'team' -and $need -contains $_.Name) -or ($OS -ne 'windows' -and $_.Name -eq 'jq') })
$ok = @{}
foreach ($p in $items) { $ok[$p.Name] = Test-Prereq $p }
$width = ($items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
Write-Host ''
Write-Host 'Kiểm phần mềm'
foreach ($g in @(@('optional', 'Không bắt buộc'), @('required', 'Bắt buộc'), @('team', "Theo đội của bạn ($(Get-TeamLine $team))"))) {
  $list = @($items | Where-Object { $_.Group -eq $g[0] })
  if (-not $list.Count) { continue }
  Write-Host "  $($g[1])"
  foreach ($p in $list) {
    if ($ok[$p.Name]) {
      Write-Host $(if ($fancy) { "    ✓ $($p.Label)" } else { "    OK    $($p.Label)" }) -ForegroundColor Green
    } else {
      $mark = if ($fancy) { '✗ ' } else { 'THIẾU ' }
      Write-Host "    $mark$($p.Label.PadRight($width))   chưa cài $arrow $(Get-PrereqFix $p)" -ForegroundColor Yellow
    }
  }
}
# Hỏi cài giúp: mặc định [1] Bỏ qua; chỉ cài khi chọn rõ 2 / 'Cài giúp' (Enter trống, EOF không cài). Herdr trên Unix chỉ cài khi chọn rõ.
if ($env:CREWLINE_NO_INSTALL -eq '1') {
  Say "bỏ qua hỏi cài (CREWLINE_NO_INSTALL=1)"
} elseif ($env:CREWLINE_DEFAULTS -ne '1') {
  foreach ($p in @($items | Where-Object { -not $ok[$_.Name] -and $_.Group -ne 'optional' })) {
    $inst = Get-PrereqInstall $p
    if (-not $inst) { continue }
    $choice = Read-Choice "Cài $($p.Label) bằng: $($inst.Text)" @(
      (New-Option 'no' 'Bỏ qua, tôi tự cài' -Alias 'n', 'no', 'bỏ qua'),
      (New-Option 'yes' 'Cài giúp' -Alias 'y', 'yes', 'cài')) 'no' -NoStep -NullOnEof
    if ($null -eq $choice) { Say 'không hỏi được (hết stdin) => không cài gì.'; break }
    if ($choice -ne 'yes') { continue }
    Say "chạy: $($inst.Text)"
    $code = 1
    try { & $inst.Exe @($inst.Args) | Out-Host; $code = $LASTEXITCODE }
    catch { Say "lỗi khi chạy $($inst.Exe): $($_.Exception.Message)" }
    if ($code -eq 0) {
      $ok[$p.Name] = $true
      if (Test-Prereq $p) { Say "đã cài $($p.Label)." }
      else { Say "đã cài $($p.Label); mở terminal mới để PATH nhận lệnh." }
    } else {
      Say "cài $($p.Label) thất bại (mã $code). Tự cài: $($p.Url)"
    }
  }
}
$missReq = @($items | Where-Object { $_.Group -eq 'required' -and -not $ok[$_.Name] })
if ($missReq.Count) {
  Write-Host ''
  Write-Host '!!! Crew đã cài nhưng CHƯA dùng được: thiếu ' -ForegroundColor Red -NoNewline
  Write-Host (($missReq | ForEach-Object { "$($_.Label) $arrow $($_.Url)" }) -join '; ') -ForegroundColor Red
  Write-Host '    Cài xong, mở terminal mới rồi chạy: crew doctor' -ForegroundColor Red
}
$missTeam = @($items | Where-Object { $_.Group -eq 'team' -and -not $ok[$_.Name] })
if ($missTeam.Count) {
  Write-Host "Nhắc: đội của bạn cần agent chưa cài: $(($missTeam | ForEach-Object { "$($_.Label) $arrow $(Get-PrereqFix $_)" }) -join '; ')" -ForegroundColor Yellow
}
Write-Host "Nhắc đăng nhập: $(($need | ForEach-Object { "$_ ($(Get-AgentLogin $_))" }) -join ', ')."

if ($NoDoctor) { Say "xong (bỏ qua crew doctor)."; return }
Say "xong. Kiểm môi trường:"
& $crewPs1 doctor



