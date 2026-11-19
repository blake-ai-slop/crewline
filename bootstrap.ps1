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
  function Fail($m, [string]$next = '') {
    Write-Host "bootstrap: LOI: $m" -ForegroundColor Red
    if ($next) { Write-Host "  -> Lam tiep: $next" }
    return 1
  }

  if (-not $Dir) { $Dir = $env:CREWLINE_DIR }
  if (-not $Dir) { $Dir = '~/Crewline' }
  if (-not $Repo) { $Repo = $env:CREWLINE_REPO }
  if (-not $Repo) { $Repo = 'https://github.com/blake-ai-slop/crewline.git' }
  if (-not $Branch) { $Branch = $env:CREWLINE_BRANCH }
  if (-not $Branch) { $Branch = 'main' }
  $Dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir)

  # VERSION = so phien ban Crewline; skeleton/VERSION = so khung context cua project.
  function Read-VersionFile([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $v = ([IO.File]::ReadAllText($file)).Trim()
    if ($v -match '^[0-9]+$') { return $v }
    return ''
  }
  function Get-CrewlineVersion([string]$root) {
    $v = Read-VersionFile (Join-Path $root 'VERSION')
    if ($v) { return "v$v" }
    return 'ban cu'
  }
  function Get-ContextVersion([string]$root) {
    $v = Read-VersionFile (Join-Path $root 'skeleton/VERSION')
    if ($v) { return $v }
    return '?'
  }

  # Bat buoc: git + pwsh
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    return (Fail "thieu git." "cai Git: winget install Git.Git (hoac https://git-scm.com/download/win), mo terminal moi roi chay lai lenh cai Crewline")
  }
  if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    return (Fail "thieu pwsh (PowerShell 7)." "cai PowerShell 7: winget install Microsoft.PowerShell (hoac https://aka.ms/powershell-release?tag=stable), mo terminal moi roi chay lai lenh cai Crewline")
  }
  # herdr/hc/claude/codex: install.ps1 in bang kiem phan mem va hoi cai giup.

  $isCrewline = (Test-Path (Join-Path $Dir 'scripts/crew.ps1')) -and (Test-Path (Join-Path $Dir 'install.ps1'))
  $isEmpty = -not (Test-Path $Dir) -or -not (Get-ChildItem -Force $Dir -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($isCrewline) {
    $dirty = git -C $Dir status --porcelain
    if ($LASTEXITCODE -ne 0) { return (Fail "$Dir co file Crewline nhung khong phai repo git." "doi ten thu muc do (kiem truoc khi xoa), hoac dat CREWLINE_DIR sang thu muc khac, roi chay lai lenh cai") }
    $before = (git -C $Dir rev-parse --short HEAD | Out-String).Trim()
    $beforeCrew = Get-CrewlineVersion $Dir
    $beforeContext = Get-ContextVersion $Dir
    if ($dirty) {
      Say "canh bao: $Dir co thay doi chua commit => bo qua git pull, may van o ban cu Crewline $beforeCrew (commit $before, khung context v$beforeContext), van chay install. Xem: git -C `"$Dir`" status; cat thay doi: git -C `"$Dir`" stash."
    } else {
      Say "cap nhat $Dir (git pull --ff-only)"
      git -C $Dir pull --ff-only -q | Out-Host
      if ($LASTEXITCODE -ne 0) { return (Fail "git pull --ff-only that bai trong $Dir. Xu ly tay roi chay lai." "xem loi: git -C `"$Dir`" status ; git -C `"$Dir`" pull --ff-only, sua xong chay lai lenh cai") }
      $after = (git -C $Dir rev-parse --short HEAD | Out-String).Trim()
      $afterCrew = Get-CrewlineVersion $Dir
      $afterContext = Get-ContextVersion $Dir
      if ($before -eq $after) { Say "da o ban moi nhat: Crewline $afterCrew (commit $after, khung context v$afterContext)" }
      else {
        $contextLine = if ($beforeContext -eq $afterContext) { "khung context v$afterContext" } else { "khung context v$beforeContext -> v$afterContext" }
        Say "cap nhat Crewline $beforeCrew -> $afterCrew (commit $before -> $after, $contextLine)"
      }
    }
  } elseif ($isEmpty) {
    Say "clone $Repo ($Branch) -> $Dir"
    git clone -q --branch $Branch $Repo $Dir | Out-Host
    if ($LASTEXITCODE -ne 0) { return (Fail "git clone that bai." "doc loi git o tren; kiem mang/URL: git ls-remote $Repo ; roi chay lai lenh cai") }
  } else {
    return (Fail "$Dir da co va khong phai Crewline (thieu scripts/crew.ps1 hoac install.ps1). Khong ghi de." "dat CREWLINE_DIR hoac -Dir sang thu muc trong khac, roi chay lai lenh cai Crewline; giu nguyen thu muc hien co")
  }

  $install = Join-Path $Dir 'install.ps1'
  Say "chay $install"
  # Native child inherits console stdin (also through iex) and CREWLINE_DEFAULTS.
  try { & pwsh -NoProfile -File $install | Out-Host }
  catch { return (Fail "khong chay duoc pwsh: $($_.Exception.Message)" "kiem pwsh: pwsh -NoProfile -Command '`$PSVersionTable.PSVersion' ; loi thi cai lai: winget install Microsoft.PowerShell") }
  if ($LASTEXITCODE -ne 0) { return (Fail "install.ps1 loi (ma $LASTEXITCODE)." "doc loi o tren, sua roi chay lai: pwsh -NoProfile -File `"$install`"") }
  return 0
}

$code = Invoke-CrewlineBootstrap -Dir $Dir -Repo $Repo -Branch $Branch
# {}.File chi co khi code nam trong file; qua iex la $null (ke ca khi iex duoc goi tu mot script khac)
if ({}.File) { exit $code }
