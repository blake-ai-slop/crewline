<#
crew (Crewline) - dựng và điều khiển "đội agent" trong herdr-app + hc (Windows, Linux, macOS; pwsh 7).

  Dùng hằng ngày
  crew up                  dựng đội, khôi phục nếu mất (project mới: hỏi tạo)
  crew up -All             như trên, cho mọi project (sau khi khởi động lại máy)
  crew status [-Path .]     đội đang làm gì

  Rồi sang tab planner và nói việc muốn làm.

  Khi cần
  crew up -Restart <vai>    bật lại agent (sau khi đổi agent hoặc quyền)
  crew setup               đổi đội mặc định cho project mới
  crew doctor              máy có thiếu gì không
  crew upgrade             cập nhật khung context của project
  crew init                tạo project với tùy chọn riêng (tên, đội)

  Chi tiết: crew help <lệnh>   ·   Lệnh agent dùng: crew help agent
  Tên cũ vẫn dùng được: crew hot [-Path .] = crew status.
Khung context lấy từ <Crewline>/skeleton.
#>
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string[]]$Name,
  [Parameter(Position = 2)][string]$PromptFile,
  [string]$Path = '.',
  [string]$Team,
  [ValidateSet('lean', 'fast', 'full')][string]$Review = 'lean',
  [ValidateSet('work', 'wide')][string]$Access = 'work',
  [int]$Worker = 0,
  [string]$Restart,
  [switch]$GitInit,
  [switch]$NoCommit,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$Raw,
  [switch]$All,
  [switch]$NoTest,
  [switch]$Strict,
  [string]$After,
  [ValidateSet('S', 'M', 'L')][string]$Size = 'M',
  [switch]$Run,
  [switch]$Remove
)

# Chốt chặn: crew cần pwsh 7. Gọi bằng Windows PowerShell 5.1 (powershell.exe) thì chạy lại chính file này bằng pwsh.
# Chỉ Windows tới được nhánh này (Linux/macOS chỉ có pwsh 7) nên thông báo winget đúng hệ.
# Phần này phải chạy được trên 5.1: ở 5.1 + EAP Stop, stderr của lệnh native thành lỗi chặn (NativeCommandError).
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if (-not $pwshCmd) {
    Write-Host 'crew: LỖI: crew cần PowerShell 7 (pwsh), máy chưa có. Cài từ https://aka.ms/powershell (hoặc winget install Microsoft.PowerShell), mở terminal mới rồi chạy lại.' -ForegroundColor Red
    exit 1
  }
  $argv = @()
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argv += "-$k" } }
    elseif ($v -is [array]) { $argv += "-$k"; $argv += ($v -join ',') }
    else { $argv += "-$k"; $argv += "$v" }
  }
  try { & $pwshCmd.Source -NoLogo -NoProfile -File $PSCommandPath @argv }
  catch { Write-Host "crew: LỖI: không chạy được pwsh ($($pwshCmd.Source)): $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
  exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'platform.ps1')
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Skeleton = Join-Path (Split-Path $PSScriptRoot -Parent) 'skeleton'
$Today = Get-Date -Format 'yyyyMMdd'
$InitParameters = $PSBoundParameters
# Biến cho các hàm ở scripts/crew/*.ps1: $PSScriptRoot/$PSCommandPath trong hàm trỏ tới file định nghĩa hàm, không phải crew.ps1.
$CrewScriptsDir = $PSScriptRoot
$CrewScriptPath = $PSCommandPath
# Các nhóm hàm (thứ tự cố định, không glob).
foreach ($crewPart in 'core', 'identity', 'name', 'herdr', 'sessions', 'init', 'upgrade', 'up', 'task', 'queue', 'hot', 'repair', 'move', 'selfpane', 'limits', 'clean', 'send') {
  . (Join-Path $PSScriptRoot "crew/$crewPart.ps1")
}
Remove-Variable crewPart

# Chuẩn hóa tên: PowerShell biến `a,b` / `a, b` thành mảng, Git Bash truyền chuỗi "a,b" ⇒ nối bằng ',' rồi tách, trim, bỏ rỗng.
function Get-NameArg($value) {
  @((@($value) -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$NameList = @(Get-NameArg $Name)
# review không dùng PromptFile: Git Bash `crew review a, b` tách thành "a," + "b" ⇒ gộp lại.
if ($Command -eq 'review' -and $PromptFile) { $NameList = @($NameList) + @(Get-NameArg $PromptFile) }
if ($Command -ne 'review' -and $NameList.Count -gt 1) { Die "crew $Command chỉ nhận một tên, nhận $($NameList.Count): $($NameList -join ', ')." }
# Các lệnh 1 tên dùng $Name là chuỗi (kể cả -Name sang check.ps1): bỏ ràng buộc [string[]] của param.
Remove-Variable -Name Name
$Name = if ($NameList.Count) { [string]$NameList[0] } else { '' }

if ($All -and $Command -ne 'up') { Die "-All chỉ dùng với crew up (crew up -All [-DryRun]), không dùng với crew $Command." }
if ($Command -eq 'up' -and $Restart -and $All) { Die '-All không đi với -Restart: -Restart bật lại terminal của một project.' }
if ($Command -eq 'up' -and $Restart -and $DryRun) { Die '-DryRun không đi với -Restart: -Restart luôn tắt và bật lại terminal.' }
if ($Command -ne 'queue' -and ($After -or $Run -or $Remove -or $InitParameters.ContainsKey('Size'))) { Die "-After, -Size, -Run, -Remove chỉ dùng với crew queue, không dùng với crew $Command." }

switch ($Command) {
  'setup' { & (Join-Path $PSScriptRoot 'setup.ps1'); exit $LASTEXITCODE }
  'doctor' { Invoke-Doctor }
  'init' { Invoke-Init; Say 'xong. Bật đội: crew up' }
  'upgrade' { Invoke-Upgrade }
  'up' {
    if (-not $All) {
      $warnRoot = Get-MainRoot (Resolve-Path -LiteralPath $Path).Path
      if ($warnRoot) { Show-CrewUpgradeWarning $warnRoot }
    }
    if ($All) { Invoke-UpAll } elseif ($Restart) { Invoke-Up }
    else {
      # Biên script con bắt exit của Recover, giữ nguyên scope hàm và mã thoát.
      $recoverFile = Join-Path ([IO.Path]::GetTempPath()) ("crew-recover-$([guid]::NewGuid().ToString('N')).ps1")
      try {
        [IO.File]::WriteAllText($recoverFile, 'Invoke-Recover $true')
        $global:LASTEXITCODE = 0
        & $recoverFile
        $recoverExit = $LASTEXITCODE
      } finally { Remove-Item -LiteralPath $recoverFile -Force -ErrorAction SilentlyContinue }
      if ($recoverExit -eq 0 -and -not $DryRun -and $env:CREWLINE_UP_ALL_CHILD -ne '1') { Invoke-QueueAuto $Path 'up' }
      exit $recoverExit
    }
  }
  'task' { Invoke-Task }
  'queue' { Invoke-Queue }
  'status' { Invoke-Hot }
  'hot' { Invoke-Hot }
  'lint' {
    . (Join-Path $PSScriptRoot 'lint.ps1')
    $root = Get-Root (Resolve-Path -LiteralPath $Path).Path
    if (-not $root) { Die 'không phải repo git.' }
    $lint = @(Get-ContextLint $root)
    foreach ($warning in $lint) { Write-Host "$($warning.File):$($warning.Line) $($warning.Rule): $($warning.Message)" }
    if ($lint.Count) { Write-Host "context: $($lint.Count) cảnh báo" } else { Write-Host 'context sạch' }
    if ($Strict -and $lint.Count) { exit 1 }; exit 0
  }
  'limits' { Invoke-Limits }
  'clean' { Invoke-Clean }
  'send' { Invoke-Send }
  'review' { Invoke-Review }
  'check' { & (Join-Path $PSScriptRoot 'check.ps1') -Name $Name -Path $Path -NoTest:$NoTest; exit $LASTEXITCODE }
  'selfcheck' { & (Join-Path $PSScriptRoot 'selfcheck.ps1'); exit $LASTEXITCODE }
  'repair' { Invoke-Recover $false }
  'self-pane-run' { Invoke-SelfPaneRun }
  'self-pane-work' { Invoke-SelfPaneWork }
  default {
    # 'help' và lệnh lạ ⇒ scripts/help.ps1 (-Topic = tên đầu tiên hoặc rỗng)
    $helpScript = Join-Path $PSScriptRoot 'help.ps1'
    if (-not (Test-Path -LiteralPath $helpScript)) {
      # chưa có help.ps1 ⇒ in tham chiếu ngắn ở khối đầu file
      Write-Host "crew: chưa có $helpScript — tham chiếu ngắn:"
      @(Get-Content $PSCommandPath -Encoding utf8 | Select-Object -Skip 1 | ForEach-Object -Begin { $on = $true } -Process { if ($_ -eq '#>') { $on = $false }; if ($on) { $_ } }) -join "`n" | Write-Host
      exit 0
    }
    & $helpScript -Topic $Name; exit $LASTEXITCODE
  }
}
