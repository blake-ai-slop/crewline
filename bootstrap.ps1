<#
Cai Crewline bang 1 dong (Windows PowerShell 5.1 hoac pwsh):
  irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex
Hoac chay truc tiep:
  ./bootstrap.ps1 [-Dir <thu muc>] [-Repo <url>] [-Branch main]
Qua iex khong truyen duoc tham so => dung bien moi truong CREWLINE_DIR, CREWLINE_REPO, CREWLINE_BRANCH.
Thu tu uu tien: tham so > bien moi truong > mac dinh.

File nay giu ASCII: Windows PowerShell 5.1 doc file khong BOM theo ma ANSI.
Khong dung `exit` o ngoai che do chay file: chay qua iex thi `exit` dong luon cua so cua nguoi dung.
#>
param(
  [string]$Dir,
  [string]$Repo,
  [string]$Branch
)

function Invoke-CrewlineBootstrap {
  param([string]$Dir, [string]$Repo, [string]$Branch)

  function Say($m) { Write-Host "bootstrap: $m" }
  function Fail($m) { Write-Host "bootstrap: LOI: $m" -ForegroundColor Red; return 1 }

  if (-not $Dir) { $Dir = $env:CREWLINE_DIR }
  if (-not $Dir) { $Dir = '~/Crewline' }
  if (-not $Repo) { $Repo = $env:CREWLINE_REPO }
  if (-not $Repo) { $Repo = 'https://github.com/blake-ai-slop/crewline.git' }
  if (-not $Branch) { $Branch = $env:CREWLINE_BRANCH }
  if (-not $Branch) { $Branch = 'main' }
  $Dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir)

  # Bat buoc: git + pwsh
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    return (Fail "thieu git. Cai Git for Windows: https://git-scm.com/download/win (hoac 'winget install Git.Git'), mo terminal moi roi chay lai.")
  }
  if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    return (Fail "thieu pwsh (PowerShell 7). Cai: https://aka.ms/powershell-release?tag=stable (hoac 'winget install Microsoft.PowerShell'), mo terminal moi roi chay lai.")
  }
  # herdr/hc/claude/codex: install.ps1 in bang kiem phan mem va hoi cai giup.

  $isCrewline = (Test-Path (Join-Path $Dir 'scripts/crew.ps1')) -and (Test-Path (Join-Path $Dir 'install.ps1'))
  $isEmpty = -not (Test-Path $Dir) -or -not (Get-ChildItem -Force $Dir -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($isCrewline) {
    $dirty = git -C $Dir status --porcelain
    if ($LASTEXITCODE -ne 0) { return (Fail "$Dir co file Crewline nhung khong phai repo git.") }
    if ($dirty) {
      Say "canh bao: $Dir co thay doi chua commit => bo qua git pull, van chay install."
    } else {
      Say "cap nhat $Dir (git pull --ff-only)"
      git -C $Dir pull --ff-only -q | Out-Host
      if ($LASTEXITCODE -ne 0) { return (Fail "git pull --ff-only that bai trong $Dir. Xu ly tay roi chay lai.") }
    }
  } elseif ($isEmpty) {
    Say "clone $Repo ($Branch) -> $Dir"
    git clone -q --branch $Branch $Repo $Dir | Out-Host
    if ($LASTEXITCODE -ne 0) { return (Fail "git clone that bai.") }
  } else {
    return (Fail "$Dir da co va khong phai Crewline (thieu scripts/crew.ps1 hoac install.ps1). Khong ghi de. Dat CREWLINE_DIR hoac -Dir sang thu muc khac.")
  }

  $install = Join-Path $Dir 'install.ps1'
  Say "chay $install"
  # Native child inherits console stdin (also through iex) and CREWLINE_DEFAULTS.
  try { & pwsh -NoProfile -File $install | Out-Host }
  catch { return (Fail "khong chay duoc pwsh: $($_.Exception.Message)") }
  if ($LASTEXITCODE -ne 0) { return (Fail "install.ps1 loi (ma $LASTEXITCODE).") }
  return 0
}

$code = Invoke-CrewlineBootstrap -Dir $Dir -Repo $Repo -Branch $Branch
# {}.File chi co khi code nam trong file; qua iex la $null (ke ca khi iex duoc goi tu mot script khac)
if ({}.File) { exit $code }
