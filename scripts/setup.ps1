param([switch]$Defaults)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$automatic = $Defaults -or $env:CREWLINE_DEFAULTS -eq '1'
$file = if ($env:CREWLINE_USER_CONFIG) { $env:CREWLINE_USER_CONFIG } else { Join-Path $HOME '.crewline/config.json' }
# Console cũ của PS 5.1 thường không có glyph ✓/✗, nên dùng chữ.
$fancy = $PSVersionTable.PSEdition -eq 'Core'
$script:step = 0
. (Join-Path $PSScriptRoot 'ui.ps1')

function New-AgentOptions([string[]]$Names, [switch]$None) {
  $list = @(foreach ($n in $Names) { New-Option $n $n $(if ($n -notin $available) { '(chưa cài)' } else { '' }) })
  if ($None) { $list += New-Option 'none' 'không dùng' }
  $list
}
function Get-TeamDesc($t) {
  $parts = @()
  $absent = @()
  if ($t.planner -eq 'none') { $absent += 'không planner' } else { $parts += "planner $($t.planner)" }
  $w = @($t.workers)
  $parts += $(if ($w.Count -eq 1) { "1 worker $($w[0])" } else { "worker $($w -join ', ')" })
  if ($t.rev -eq 'none') { $absent += 'không Rev' } else { $parts += "Rev $($t.rev)" }
  if ($absent.Count) { $parts += $absent -join ', ' }
  $parts -join ' · '
}

if (Test-Path -LiteralPath $file) {
  if ($automatic) { Write-Host "Giữ config cá nhân: $file"; return }
  $keep = @((New-Option 'keep' 'Giữ nguyên' -Alias 'n', 'no'), (New-Option 'overwrite' 'Ghi đè' -Alias 'y', 'yes'))
  if ((Read-Choice "Config cá nhân đã có: $file" $keep 'keep' -NoStep) -ne 'overwrite') { return }
}
$teams = Get-Content (Join-Path $PSScriptRoot 'teams.json') -Raw -Encoding utf8 | ConvertFrom-Json
$available = @('claude', 'codex' | Where-Object { [bool](Get-Command $_ -ErrorAction SilentlyContinue) })
$status = @(foreach ($a in 'claude', 'codex') {
  $ok = $a -in $available
  "$a " + $(if ($fancy) { if ($ok) { '✓' } else { '✗ chưa cài' } } else { if ($ok) { 'có' } else { 'chưa cài' } })
})
Write-Host ''
Write-Host 'Crewline setup — chọn đội mặc định cho các project mới'
Write-Host "Agent trên máy: $($status -join '   ')"
if ($available.Count -eq 0) { Write-Host 'Cảnh báo: chưa có agent, hãy cài claude/codex trước khi dùng crew.' }

$team = if ($available.Count -eq 1) { 'custom' } else { 'standard' }
$agents = @(if ($available.Count) { $available } else { @('claude', 'codex') })
$count = 2
$rev = if ($team -eq 'custom') { $agents[($agents.Count - 1)] } else { $teams.$team.rev }
if (-not $automatic) {
  $teamOptions = @(foreach ($name in 'standard', 'solo', 'large') { New-Option $name $name (Get-TeamDesc $teams.$name) })
  $teamOptions += New-Option 'custom' 'custom' 'tự chọn từng vai'
  $team = Read-Choice 'Mẫu đội' $teamOptions $team
}
if ($team -eq 'custom') {
  $planner = $agents[0]
  $rev = $agents[($agents.Count - 1)]
  if (-not $automatic) {
    $planner = Read-Choice 'Planner' (New-AgentOptions 'claude', 'codex' -None) $planner
    $countOptions = @(1..6 | ForEach-Object { New-Option "$_" "$_" })
    $count = [int](Read-Choice 'Số worker' $countOptions '2')
  }
  $workers = @(for ($i = 0; $i -lt $count; $i++) {
    $agent = $agents[$i % $agents.Count]
    if (-not $automatic) { $agent = Read-Choice "Worker $($i + 1)" (New-AgentOptions 'claude', 'codex') $agent }
    $agent
  })
  if (-not $automatic) { $rev = Read-Choice 'Rev' (New-AgentOptions 'claude', 'codex' -None) $rev }
} else {
  $planner = $teams.$team.planner
  $workers = @($teams.$team.workers)
  $rev = $teams.$team.rev
}
$missing = @(@($planner) + @($workers) + @($rev) | Where-Object { $_ -ne 'none' -and $_ -notin $available } | Select-Object -Unique)
if ($missing.Count) {
  Write-Host "Cảnh báo: đội dùng agent chưa cài: $($missing -join ', ')."
  if (-not $automatic) {
    $confirm = @((New-Option 'yes' 'Vẫn dùng đội này' -Alias 'y'), (New-Option 'no' 'Hủy, không đổi config' -Alias 'n'))
    if ((Read-Choice 'Tiếp tục?' $confirm 'yes' -NoStep) -eq 'no') { Write-Host 'Đã hủy, config không đổi.'; return }
  }
}
$reviewNames = @{ lean = 'Gọn'; fast = 'Nhanh'; full = 'Đủ' }
$accessNames = @{ work = 'Làm việc'; wide = 'Mở rộng' }
$review = if ($rev -eq 'none') { 'fast' } else { 'lean' }
$access = 'work'
if (-not $automatic) {
  if ($rev -ne 'none') {
    $review = Read-Choice 'Review' @(
      (New-Option 'lean' 'lean' '— Gọn: Rev xem diff + chỗ nối, full test 1 lần'),
      (New-Option 'fast' 'fast' '— Nhanh: merge rồi test, không review'),
      (New-Option 'full' 'full' '— Đủ: review kỹ từng nhánh, full test tuần tự')) 'lean'
  }
  $access = Read-Choice 'Quyền agent' @(
    (New-Option 'work' 'work' '— Làm việc: agent hỏi duyệt lệnh vượt quyền'),
    (New-Option 'wide' 'wide' '— Mở rộng: agent không hỏi duyệt (bypass), chỉ khi bạn ngồi xem')) 'work'
}
$config = [ordered]@{ team = $team; planner = $planner; workers = @($workers); rev = $rev; review = $review; access = $access }
$parent = Split-Path -Parent $file
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding utf8
$show = { param($v) if ($v -eq 'none') { 'không dùng' } else { $v } }
Write-Host ''
Write-Host 'Đã chọn:'
Write-Host "  Mẫu      $team"
Write-Host "  Planner  $(& $show $planner)"
Write-Host "  Worker   $($workers -join ', ')"
Write-Host "  Rev      $(& $show $rev)"
Write-Host "  Review   $review — $($reviewNames[$review])"
Write-Host "  Quyền    $access — $($accessNames[$access])"
Write-Host "Đã ghi config cá nhân: $file"
Write-Host 'Đổi lại: crew setup'
