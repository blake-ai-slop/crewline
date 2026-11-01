. (Join-Path $PSScriptRoot 'platform.ps1')
# Phần mềm Crewline cần: nguồn duy nhất cho install.ps1 và crew doctor (dot-source; chỉ định nghĩa hàm, không chạy gì).
# Group: required (bắt buộc) / team (theo đội: chỉ cần khi đội dùng agent đó) / optional (không bắt buộc).
function Get-Prereqs {
  @(
    [pscustomobject]@{ Name = 'git'; Label = 'git'; Commands = @('git'); Group = 'required'; Url = $(if ((Get-CrewOS) -eq 'windows') { 'https://git-scm.com/download/win' } else { 'https://git-scm.com/downloads' }); Winget = 'Git.Git'; Npm = $null; Fix = $null }
    [pscustomobject]@{ Name = 'pwsh'; Label = 'pwsh'; Commands = @('pwsh'); Group = 'required'; Url = 'https://aka.ms/powershell-release?tag=stable'; Winget = 'Microsoft.PowerShell'; Npm = $null; Fix = $null }
    [pscustomobject]@{ Name = 'herdr'; Label = 'herdr-app + hc'; Commands = @('herdr-app', 'hc'); Group = 'required'; Url = 'https://herdr.dev/'; Winget = $null; Npm = $null; Fix = $null }
    [pscustomobject]@{ Name = 'claude'; Label = 'claude'; Commands = @('claude'); Group = 'team'; Url = 'https://docs.claude.com/en/docs/claude-code'; Winget = $null; Npm = '@anthropic-ai/claude-code'; Fix = $null }
    [pscustomobject]@{ Name = 'codex'; Label = 'codex'; Commands = @('codex'); Group = 'team'; Url = 'https://github.com/openai/codex'; Winget = $null; Npm = '@openai/codex'; Fix = $null }
    [pscustomobject]@{ Name = 'jq'; Label = 'jq (không bắt buộc)'; Commands = @('jq'); Group = 'optional'; Url = $null; Winget = $null; Npm = $null; Fix = $(if ((Get-CrewOS) -eq 'windows') { 'install.ps1 tự tải' } else { 'cài jq bằng trình quản lý gói của hệ' }) }
  )
}

function Test-Prereq($p) {
  foreach ($c in $p.Commands) { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { return $false } }
  $true
}

# Lệnh cài tự động dùng được trên máy này: @{ Exe; Args; Text } hoặc $null (winget chỉ khi có winget, npm chỉ khi có npm).
function Get-PrereqInstall($p) {
  $os = Get-CrewOS
  if ($os -ne 'windows' -and $p.Name -eq 'herdr') {
    $hint = Get-HerdrInstallHint
    if ($hint -notlike 'curl *') { return $null }
    return [pscustomobject]@{ Exe = 'sh'; Args = @('-c', $hint); Text = $hint }
  }
  if ($os -eq 'macos' -and $p.Name -in @('git', 'pwsh', 'jq') -and (Get-Command brew -ErrorAction SilentlyContinue)) {
    $package = if ($p.Name -eq 'pwsh') { 'powershell' } else { $p.Name }
    return [pscustomobject]@{ Exe = 'brew'; Args = @('install', $package); Text = "brew install $package" }
  }
  if ($os -eq 'windows' -and $p.Winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    $a = @('install', $p.Winget)
    return [pscustomobject]@{ Exe = 'winget'; Args = $a; Text = "winget $($a -join ' ')" }
  }
  if ($p.Npm -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    $a = @('install', '-g', $p.Npm)
    return [pscustomobject]@{ Exe = 'npm'; Args = $a; Text = "npm $($a -join ' ')" }
  }
  $null
}

# Cách sửa khi thiếu (không có chữ "chưa cài"): lệnh cài nếu có, không thì link (kèm Node.js nếu cần npm).
function Get-PrereqFix($p) {
  $os = Get-CrewOS
  if ($p.Name -eq 'herdr') { return (Get-HerdrInstallHint) }
  if ($os -eq 'linux' -and $p.Name -in @('git', 'pwsh', 'jq')) {
    $package = if ($p.Name -eq 'pwsh') { 'powershell' } else { $p.Name }
    $extra = if ($p.Name -eq 'pwsh') { ' (cần kho Microsoft: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)' } else { '' }
    return "sudo apt install $package / sudo dnf install $package$extra"
  }
  $i = Get-PrereqInstall $p
  if ($i) { return $i.Text }
  if ($p.Fix) { return $p.Fix }
  $s = "tải: $($p.Url)"
  if ($p.Npm) { $s += " (cần Node.js: https://nodejs.org)" }
  $s
}

# Đội đang dùng: config đầu tiên đọc được trong $ConfigFiles (có planner/workers/rev, hoặc team có trong teams.json), không có thì standard.
function Get-PrereqTeam([string[]]$ConfigFiles, [string]$TeamsFile) {
  $teams = $null
  try { $teams = Get-Content -LiteralPath $TeamsFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
  foreach ($f in $ConfigFiles) {
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
    try { $c = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { continue }
    if ($null -eq $c -or $c -isnot [pscustomobject]) { continue }
    $names = $c.PSObject.Properties.Name
    if ($names -contains 'planner' -and $names -contains 'workers' -and $names -contains 'rev') {
      return [pscustomobject]@{ planner = "$($c.planner)"; workers = @($c.workers | ForEach-Object { "$_" }); rev = "$($c.rev)" }
    }
    if ($c.team -is [string] -and $teams -and $teams.PSObject.Properties.Name -contains $c.team) {
      $t = $teams.($c.team)
      return [pscustomobject]@{ planner = "$($t.planner)"; workers = @($t.workers); rev = "$($t.rev)" }
    }
  }
  if ($teams -and $teams.standard) {
    return [pscustomobject]@{ planner = "$($teams.standard.planner)"; workers = @($teams.standard.workers); rev = "$($teams.standard.rev)" }
  }
  [pscustomobject]@{ planner = 'claude'; workers = @('claude', 'codex'); rev = 'codex' }
}

# Agent đội cần (bỏ none, không lặp).
function Get-TeamAgents($team) {
  @(@($team.planner) + @($team.workers) + @($team.rev) | Where-Object { $_ -and $_ -ne 'none' } | Select-Object -Unique)
}

# "planner claude · worker claude, codex · Rev codex"
function Get-TeamLine($team) {
  $parts = @()
  if ($team.planner -and $team.planner -ne 'none') { $parts += "planner $($team.planner)" }
  $parts += "worker $(@($team.workers | Select-Object -Unique) -join ', ')"
  if ($team.rev -and $team.rev -ne 'none') { $parts += "Rev $($team.rev)" }
  $parts -join ' · '
}

# Cách đăng nhập agent (crew không tự đăng nhập).
function Get-AgentLogin([string]$name) {
  @{ claude = 'chạy `claude` một lần để đăng nhập'; codex = '`codex login`' }[$name]
}


