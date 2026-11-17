# ---------------- upgrade ----------------
# Project cũ thiếu `name`/`idKey` ⇒ ghi name = slug cũ và idKey = khóa cũ (tên bỏ '-') vào .crew/config.json (gitignore,
# không commit) để KHÔNG đổi tên terminal và space/tab đang chạy; ghi sổ nếu tên/khóa còn trống (trùng ⇒ giữ chủ cũ, cảnh báo).
# Slug cũ rỗng ⇒ sinh tên mới + idKey mã hóa mới. Đủ cả hai ⇒ chỉ cảnh báo khi trùng project khác. $dry ⇒ chỉ in.
function Update-ConfigName([string]$root, [bool]$dry) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $cfg = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
  $names = @($cfg.PSObject.Properties.Name)
  $hasName = $names -contains 'name' -and $cfg.name
  $hasKey = $names -contains 'idKey' -and $cfg.idKey
  if ($hasName -and $hasKey) {
    $clash = Get-NameConflict $root $cfg
    if ($clash) { Say "cảnh báo: $clash" }
    return
  }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Say "cảnh báo: $($reg.Error) — không ghi sổ." }
  $n = if ($hasName) { Get-CrewName $root $cfg } else { Get-LegacySlug $root }
  $fresh = $false
  if (-not $n) { $n = Resolve-CrewName (Get-Slug $root) $root $reg.Map; $fresh = $true }
  $k = if ($hasKey) { Get-CrewIdKey $root $cfg } elseif ($fresh) { ConvertTo-IdKey $n } else { Get-LegacyIdKey $n }
  $what = @(if (-not $hasName) { "name '$n'" }) + @(if (-not $hasKey) { "idKey '$k'" }) -join ' + '
  if ($dry) {
    Say "sẽ ghi $what vào $f (giữ tên terminal và space/tab hiện có) + sổ tên crew nếu còn trống."
    $clash = Get-NameConflict $root ([pscustomobject]@{ name = $n; idKey = $k })
    if ($clash) { Say "cảnh báo: $clash" }
    return
  }
  $o = [ordered]@{ name = $n; idKey = $k }
  foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -notin 'name', 'idKey') { $o[$p.Name] = $p.Value } }
  $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f -Encoding utf8
  Say "ghi $what vào $f (giữ tên terminal và space/tab hiện có)."
  # Sổ còn ghi đúng tên + khóa này ở root cũ đã mất ⇒ project đã chuyển: giữ mục sổ làm dấu vết cho Get-MoveInfo, crew up/repair sẽ cập nhật.
  $moved = $reg.Ok -and $reg.Map.Contains($n) -and $reg.Map[$n].IdKey -ceq $k -and -not (Test-SamePath ([string]$reg.Map[$n].Root) $root) -and -not (Test-Path -LiteralPath (Join-Path ([string]$reg.Map[$n].Root) '.crew/config.json'))
  if ($moved) { Say "sổ còn ghi '$n' ở $($reg.Map[$n].Root) (không còn) — chưa ghi sổ, crew up sẽ xử lý chuyển thư mục." }
  elseif ($reg.Ok) { Register-CrewName $n $root $k | Out-Null }
}

function Invoke-Upgrade {
  $root = Get-Root (Resolve-Path $Path).Path
  if (-not $root) { Die 'không phải repo git.' }
  $context = Join-Path $root 'context'
  if (-not (Test-Path $context -PathType Container)) { Die "chưa có context/ — chạy 'crew init' trước." }
  $st = Invoke-GitQuiet -C $root status --porcelain --untracked-files=all -- context
  if ($st.Code -ne 0) { Die 'không kiểm tra được trạng thái context/.' }
  # Bỏ qua file .bak-* (kể cả khi project chưa ignore chúng).
  $dirty = @($st.Text -split '\r?\n+' | Where-Object { $_ -and -not (Test-BakPath ($_.Substring(3).Trim('"'))) })
  if ($dirty.Count -and -not $Force) { Die 'context/ có thay đổi chưa commit; commit trước hoặc dùng -Force.' }
  $version = Get-SkeletonVersion
  $old = '0'
  $versionFile = Join-Path $context '.skeleton-version'
  if (Test-Path $versionFile) { $old = (Get-Content $versionFile -Raw -Encoding utf8).Trim() }
  Say "upgrade context v$old -> v$version"
  $changed = [Collections.Generic.List[string]]::new()
  # Chỉ biết có commit khi gặp file đầu tiên cần ghi: hỏi danh tính ngay trước lần ghi đó.
  $script:UpgradeWillWrite = $false
  $needCommit = {
    if ($script:UpgradeWillWrite) { return }
    $script:UpgradeWillWrite = $true
    if (-not $DryRun -and -not $NoCommit) { Confirm-GitIdentity $root $true $false }
  }
  function Write-UpgradeFile([string]$file, [string]$content, [bool]$backup = $false) {
    if ((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -ceq $content) { return }
    & $needCommit
    Say "$(if ($backup) { 'sao lưu + cập nhật' } else { 'ghi' }) $file"
    if ($DryRun) { return }
    if ($backup) {
      $bak = "$file.bak-$Today"
      $n = 1
      while (Test-Path -LiteralPath $bak) { $bak = "$file.bak-$Today-$n"; $n++ }
      Copy-Item -LiteralPath $file -Destination $bak
      Say "  bản sao lưu (không commit): $bak"
    }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($false))
    $changed.Add($file)
  }
  $src = Join-Path $Skeleton 'context'
  foreach ($item in Get-ChildItem $src -Recurse -File -Force) {
    $rel = $item.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
    $dst = Join-Path $context $rel
    $exists = Test-Path -LiteralPath $dst
    # tasks/archive và file riêng của dự án luôn được giữ nguyên, kể cả khi thiếu.
    if ($rel -match '^(tasks|archive)/') { continue }
    if (-not $exists) { Write-UpgradeFile $dst ([IO.File]::ReadAllText($item.FullName)); continue }
    if ($rel -eq 'README.md' -or $rel -match '^roles/[^/]+\.md$') {
      Write-UpgradeFile $dst ([IO.File]::ReadAllText($item.FullName)) $true
    } elseif ($rel -eq 'PITFALLS.md') {
      $text = [IO.File]::ReadAllText($dst)
      $lines = @($text -split '\r?\n' | ForEach-Object { $_.Trim() })
      # Dòng đã chuyển sang context/archive/PITFALLS-*.md coi như đã có: không thêm lại. Dòng (trim) bằng hoặc bắt đầu bằng dòng skeleton (nguyên văn, phân biệt hoa thường) ⇒ đã có.
      $archive = Join-Path $context 'archive'
      if (Test-Path -LiteralPath $archive -PathType Container) {
        foreach ($a in Get-ChildItem -LiteralPath $archive -Filter 'PITFALLS-*.md' -File -Force) {
          $lines += @([IO.File]::ReadAllText($a.FullName) -split '\r?\n' | ForEach-Object { $_.Trim() })
        }
      }
      $add = @()
      foreach ($line in Get-Content $item.FullName -Encoding utf8) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith('- ')) { continue }
        if (@($lines | Where-Object { $_.StartsWith($trimmed, [StringComparison]::Ordinal) }).Count) { continue }
        $add += $trimmed; $lines += $trimmed
      }
      if ($add.Count) { Write-UpgradeFile $dst ($text + $(if ($text.EndsWith("`n")) { '' } else { "`n" }) + ($add -join "`n") + "`n") }
    }
  }
  foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
    $file = Join-Path $root $name
    $text = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    $block = Get-CrewBlock
    # Bản mới có marker kết thúc; bản init cũ gồm heading, dòng đọc context và các bullet.
    $pattern = '(?s)<!-- crew -->.*?<!-- /crew -->'
    if ($text -notmatch $pattern) { $pattern = '<!-- crew -->\r?\n## [^\r\n]*\r?\n[^\r\n]*(?:\r?\n- [^\r\n]*)*' }
    if ($text -match $pattern) { $next = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1) }
    elseif ($text.Contains('<!-- crew -->')) { Die "khối crew trong $name không nhận diện được; cần marker <!-- /crew -->." }
    else { $next = $text + $(if ($text) { "`n" } else { '' }) + $block + "`n" }
    Write-UpgradeFile $file $next
  }
  Write-UpgradeFile $versionFile "$version`n"
  $gi = Join-Path $root '.gitignore'
  $ignoreText = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
  $ignoreLines = @($ignoreText -split '\r?\n+' | ForEach-Object { $_.Trim() })
  $ignoreMissing = $ignoreLines -cnotcontains '*.bak-*'
  if ($ignoreMissing) { & $needCommit }
  Update-ConfigName $root ([bool]$DryRun)
  if ($DryRun) {
    if ($ignoreMissing) { Say 'sẽ thêm *.bak-* vào .gitignore.' }
    if ($script:UpgradeWillWrite -and -not $NoCommit) { Confirm-GitIdentity $root $true $true }
    Say 'DryRun: không ghi file, không commit.'; return
  }
  if (Add-GitIgnoreLine $root '*.bak-*') {
    $changed.Add((Join-Path $root '.gitignore'))
    if ($NoCommit) { Say 'đã thêm *.bak-* vào .gitignore (chưa commit)' }
  }
  if ($NoCommit) { Say 'bỏ qua commit (-NoCommit).'; return }
  # Phòng thủ: không bao giờ add file .bak-* hay file bị git ignore (chưa track).
  $files = @($changed.ToArray() | Where-Object {
      -not (Test-BakPath $_) -and (Invoke-GitQuiet -C $root check-ignore -q -- $_).Code -ne 0 })
  if (-not $files.Count) { Say 'không có gì mới để commit.'; return }
  Invoke-GitOrDie 'git add' -C $root add -- @files | Out-Null
  # Chỉ commit file upgrade, không kéo theo các file đã stage ngoài phạm vi.
  Invoke-GitOrDie 'commit upgrade' -C $root commit -q --only -m "chore: crew upgrade context -> v$version" -- @files | Out-Null
}
