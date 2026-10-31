# Hàm hỏi dùng chung cho setup.ps1 và crew.ps1 (dot-source). Chạy được trên PS 5.1 (file có BOM).
function New-Option([string]$Value, [string]$Label, [string]$Desc = '', [string[]]$Alias = @()) {
  [pscustomobject]@{ Value = $Value; Label = $Label; Desc = $Desc; Alias = $Alias }
}
# In danh sách đánh số, trả Value của lựa chọn. Enter = mặc định; EOF = mặc định (hoặc $null nếu -NullOnEof); nhận số, Value, Label hoặc Alias.
function Read-Choice([string]$Title, [object[]]$Options, [string]$Default, [switch]$NoStep, [switch]$NullOnEof) {
  $defaultIndex = 1
  for ($i = 0; $i -lt $Options.Count; $i++) { if ($Options[$i].Value -eq $Default) { $defaultIndex = $i + 1 } }
  Write-Host ''
  if ($NoStep) { Write-Host $Title } else { $script:step++; Write-Host "[$script:step] $Title" }
  $width = ($Options | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
  for ($i = 0; $i -lt $Options.Count; $i++) {
    $o = $Options[$i]
    # Mô tả bắt đầu bằng '—' hoặc '(' dính sau tên; còn lại căn cột.
    $line = "  $($i + 1). " + $(if (-not $o.Desc) { $o.Label } elseif ($o.Desc -match '^[—(]') { "$($o.Label) $($o.Desc)" } else { $o.Label.PadRight($width) + "   $($o.Desc)" })
    Write-Host $line
  }
  while ($true) {
    Write-Host "Lựa chọn [$defaultIndex]: " -NoNewline
    $answer = [Console]::ReadLine()
    if ($null -eq $answer) { Write-Host ''; if ($NullOnEof) { return $null }; return $Options[$defaultIndex - 1].Value }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Options[$defaultIndex - 1].Value }
    $answer = $answer.Trim().ToLowerInvariant()
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $Options[$n - 1].Value }
    foreach ($o in $Options) { if ($answer -eq $o.Value -or $answer -eq $o.Label.ToLowerInvariant() -or $o.Alias -contains $answer) { return $o.Value } }
    Write-Host "  Không hợp lệ — nhập số từ 1 đến $($Options.Count)."
  }
}
