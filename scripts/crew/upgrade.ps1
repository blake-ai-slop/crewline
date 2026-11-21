# ---------------- upgrade ----------------
# Project cũ thiếu `name`/`idKey` ⇒ ghi name = slug cũ và idKey = khóa cũ (tên bỏ '-') vào .crew/config.json (gitignore,
# không commit) để KHÔNG đổi tên terminal và space/tab đang chạy; ghi sổ nếu tên/khóa còn trống (trùng ⇒ giữ chủ cũ, cảnh báo).
# Slug cũ rỗng ⇒ sinh tên mới + idKey mã hóa mới. Đủ cả hai ⇒ chỉ cảnh báo khi trùng project khác. $dry ⇒ chỉ in.
function Update-ConfigName([string]$root, [bool]$dry) {
  $f = Join-Path $root '.crew/config.json'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $cfg = Read-CrewState $f
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
  $o | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $f -Encoding utf8
  Say "ghi $what vào $f (giữ tên terminal và space/tab hiện có)."
  # Sổ còn ghi đúng tên + khóa này ở root cũ đã mất ⇒ project đã chuyển: giữ mục sổ làm dấu vết cho Get-MoveInfo, crew up/repair sẽ cập nhật.
  $moved = $reg.Ok -and $reg.Map.Contains($n) -and $reg.Map[$n].IdKey -ceq $k -and -not (Test-SamePath ([string]$reg.Map[$n].Root) $root) -and -not (Test-Path -LiteralPath (Join-Path ([string]$reg.Map[$n].Root) '.crew/config.json'))
  if ($moved) { Say "sổ còn ghi '$n' ở $($reg.Map[$n].Root) (không còn) — chưa ghi sổ, crew up sẽ xử lý chuyển thư mục." }
  elseif ($reg.Ok) { Register-CrewName $n $root $k | Out-Null }
}

# ---------------- dấu bản mẫu ----------------
# context/.skeleton-hashes.json: khóa = đường dẫn trong context/ (README.md, roles/<vai>.md) hoặc CLAUDE.md#crew / AGENTS.md#crew,
# giá trị = sha256 nội dung bản mẫu đã cài (CRLF→LF). Upgrade chỉ thay file/khối còn khớp dấu (hoặc khớp một bản đã phát hành
# trong skeleton/released-hashes.json); đã sửa tay ⇒ ghi <file>.new, không bao giờ ghi đè. *.local.md không bao giờ bị đụng.
function ConvertTo-Lf([string]$text) { $text -replace "`r`n", "`n" }

function Get-TextHash([string]$text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Lf $text))) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

# File skeleton theo quy tắc dấu: README.md và roles/*.md (trừ *.local.md).
function Test-HashedSkeletonPath([string]$rel) {
  ($rel -ceq 'README.md' -or $rel -cmatch '^roles/[^/]+\.md$') -and $rel -notmatch '\.local\.md$'
}

function Test-NewPath([string]$p) { (Split-Path $p -Leaf) -like '*.new' }

# .gitignore cho đúng các .new upgrade sinh ra (không ignore *.new chung: che file .new thật của project).
# Project đã có dòng *.new (bản dev cũ) ⇒ coi như đủ, không thêm.
function Get-NewIgnoreLines { @('context/**/*.new', '/CLAUDE.md.new', '/AGENTS.md.new') }

function Read-SkeletonHashes([string]$root) {
  $map = @{}
  $f = Join-Path $root 'context/.skeleton-hashes.json'
  if (-not (Test-Path -LiteralPath $f)) { return $map }
  try {
    $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) { if ($p.Value -is [string] -and $p.Value -cmatch '^[0-9a-f]{64}$') { $map[$p.Name] = $p.Value } }
  } catch { Say "cảnh báo: $f hỏng — coi như chưa có dấu bản mẫu." }
  $map
}

function Format-SkeletonHashes([hashtable]$map) {
  $keys = @($map.Keys | Sort-Object -CaseSensitive)
  $lines = for ($i = 0; $i -lt $keys.Count; $i++) { "  `"$($keys[$i])`": `"$($map[$keys[$i]])`"$(if ($i -lt $keys.Count - 1) { ',' })" }
  "{`n$(if ($keys.Count) { (@($lines) -join "`n") + "`n" })}`n"
}

function Test-SameHashes([hashtable]$a, [hashtable]$b) {
  if ($a.Count -ne $b.Count) { return $false }
  foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k) -or $b[$k] -cne $a[$k]) { return $false } }
  $true
}

# Ghi .skeleton-hashes.json khi bộ dấu đổi (so theo nội dung, không theo byte/CRLF). Trả $true nếu cần ghi; $dry ⇒ chỉ báo.
function Write-SkeletonHashes([string]$root, [hashtable]$map, [bool]$dry = $false) {
  if (Test-SameHashes (Read-SkeletonHashes $root) $map) { return $false }
  if (-not $dry) { [IO.File]::WriteAllText((Join-Path $root 'context/.skeleton-hashes.json'), (Format-SkeletonHashes $map), [Text.UTF8Encoding]::new($false)) }
  $true
}

# Hash các bản đã phát hành: skeleton/released-hashes.json { "<khóa>": ["<sha256>", …] } (khóa bắt đầu '_' là ghi chú).
function Get-ReleasedHashes {
  $map = @{}
  $f = Join-Path $Skeleton 'released-hashes.json'
  if (-not (Test-Path -LiteralPath $f)) { return $map }
  $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json
  foreach ($p in $o.PSObject.Properties) { if ($p.Name -notlike '_*') { $map[$p.Name] = @($p.Value) } }
  $map
}

# Khối crew: State none (chưa có <!-- crew -->), open (thiếu <!-- /crew -->), ok (Inner = nội dung giữa hai marker).
function Find-CrewBlock([string]$text) {
  $open = '<!-- crew -->'; $close = '<!-- /crew -->'
  $i = $text.IndexOf($open, [StringComparison]::Ordinal)
  if ($i -lt 0) { return @{ State = 'none' } }
  $j = $text.IndexOf($close, $i + $open.Length, [StringComparison]::Ordinal)
  if ($j -lt 0) { return @{ State = 'open' } }
  @{ State = 'ok'; Index = $i; Length = $j + $close.Length - $i; Inner = $text.Substring($i + $open.Length, $j - $i - $open.Length) }
}

# same: giống bản mới; replace: còn đúng bản crew đã cài (khớp dấu hoặc một bản đã phát hành); manual: người dùng đã sửa.
function Get-SkeletonAction([string]$key, [string]$current, [string]$new, [hashtable]$hashes, [hashtable]$released) {
  if ((ConvertTo-Lf $current) -ceq (ConvertTo-Lf $new)) { return 'same' }
  $h = Get-TextHash $current
  if (($hashes.ContainsKey($key) -and $hashes[$key] -ceq $h) -or ($released.ContainsKey($key) -and @($released[$key]) -ccontains $h)) { return 'replace' }
  'manual'
}

# init: ghi dấu cho file/khối đang giống hệt bản mẫu; giữ dấu cũ của file khác bản mẫu (người dùng đã sửa).
function Update-InitSkeletonHashes([string]$root) {
  $hashes = Read-SkeletonHashes $root
  $src = Join-Path $Skeleton 'context'
  foreach ($item in Get-ChildItem $src -Recurse -File -Force) {
    $rel = $item.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
    if (-not (Test-HashedSkeletonPath $rel)) { continue }
    $dst = Join-Path $root "context/$rel"
    $new = [IO.File]::ReadAllText($item.FullName)
    if ((Test-Path -LiteralPath $dst) -and (ConvertTo-Lf ([IO.File]::ReadAllText($dst))) -ceq (ConvertTo-Lf $new)) { $hashes[$rel] = Get-TextHash $new }
  }
  $inner = (Find-CrewBlock (Get-CrewBlock)).Inner
  foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
    $file = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $b = Find-CrewBlock ([IO.File]::ReadAllText($file))
    if ($b.State -eq 'ok' -and (ConvertTo-Lf $b.Inner) -ceq (ConvertTo-Lf $inner)) { $hashes["$name#crew"] = Get-TextHash $inner }
  }
  Write-SkeletonHashes $root $hashes | Out-Null
}

# Khối tóm tắt cuối crew upgrade (thật và -DryRun).
function Write-UpgradeSummary([string]$old, [string]$version, $replace, $manual, $keep, $openBlocks, [bool]$dry, [bool]$other, [string]$crew = '?') {
  Write-Host ''
  Write-Host "== crew upgrade$(if ($dry) { ' -DryRun' }) (Crewline v$crew): khung context v$old -> v$version"
  if (-not $replace.Count -and -not $manual.Count -and -not $openBlocks.Count -and -not $other) {
    Write-Host "khung context đã ở v$version, không có gì để cập nhật."
    return
  }
  $join = { param($list) $s = @($list) -join ', '; if ($s.Length -gt 160) { $s.Substring(0, 157) + '...' } else { $s } }
  Write-Host "$(if ($dry) { 'Sẽ cập nhật' } else { 'Đã cập nhật' }) ($($replace.Count)): $(if ($replace.Count) { & $join $replace } else { '-' })"
  $pairs = @($manual | ForEach-Object { "$_ -> $_.new" })
  Write-Host "Giữ bản của bạn, bản mới $(if ($dry) { 'sẽ ' })ở .new ($($manual.Count)): $(if ($pairs.Count) { $pairs -join ', ' } else { '-' })" -ForegroundColor $(if ($pairs.Count) { 'Yellow' } else { 'Gray' })
  if ($manual.Count -and $dry) { Write-Host 'Xem khác biệt sau khi chạy crew upgrade thật (.new sẽ có sau khi chạy thật):' }
  foreach ($file in $manual) {
    $quoted = "'" + $file.Replace("'", "''") + "'"
    $quotedNew = "'" + ($file + '.new').Replace("'", "''") + "'"
    Write-Host "  git diff --no-index -- $quoted $quotedNew"
  }
  $kept = @($keep) + @($openBlocks | ForEach-Object { "$_ (thiếu <!-- /crew -->)" })
  Write-Host "Giữ nguyên ($($kept.Count)): $(if ($kept.Count) { & $join $kept } else { '-' })"
  $todo = @()
  if ($manual.Count) {
    $todo += 'mở từng cặp <file> và <file>.new, gộp phần mới vào bản của bạn rồi xóa .new; quy tắc riêng nên chuyển sang context/roles/<vai>.local.md (upgrade không bao giờ đụng).'
    $todo += 'hoặc nói với planner: gộp các file .new trong context/roles rồi xóa .new'
  }
  if ($openBlocks.Count) { $todo += "thêm dòng <!-- /crew --> ngay sau khối crew trong $(@($openBlocks) -join ', ') rồi chạy lại crew upgrade." }
  if ($dry) { $todo += 'crew upgrade' }
  if ($todo.Count) { Write-Host "Việc cần làm:`n  $($todo -join "`n  ")" -ForegroundColor $(if ($manual.Count -or $openBlocks.Count) { 'Yellow' } else { 'Gray' }) }
}

function Invoke-Upgrade {
  $root = Get-Root (Resolve-Path $Path).Path
  if (-not $root) { Die 'không phải repo git.' 'cd vào thư mục project rồi chạy lại: crew upgrade' }
  $context = Join-Path $root 'context'
  if (-not (Test-Path $context -PathType Container)) { Die 'chưa có context/.' 'chạy crew init trước' }
  $version = Get-SkeletonVersion
  $crew = (Get-CrewVersion).Version
  $old = '0'
  $versionFile = Join-Path $context '.skeleton-version'
  if (Test-Path -LiteralPath $versionFile) {
    $old = ([IO.File]::ReadAllText($versionFile)).Trim()
    $oldNumber = 0
    if ($old -notmatch '^[0-9]+$' -or -not [int]::TryParse($old, [ref]$oldNumber) -or $oldNumber -le 0) {
      Die 'context/.skeleton-version hỏng (phải là số nguyên dương) — không ghi gì.' @('git log -- context/.skeleton-version', 'Khôi phục file từ commit đúng.', 'git restore --source=<commit> -- context/.skeleton-version', 'crew upgrade')
    }
    if ($oldNumber -gt [int]$version) {
      Die "project này đã được cập nhật bằng Crewline mới hơn bản đang cài (v$crew, khung v$version < khung v$old của project)" @((Get-CrewInstallCommand), 'crew upgrade')
    }
  }
  # Kiểm JSON/schema .crew/config.json trước mọi ghi (Update-ConfigName chạy sau khi đã ghi context).
  $cfgFile = Join-Path $root '.crew/config.json'
  if (Test-Path -LiteralPath $cfgFile) { $null = Read-CrewState $cfgFile }
  $st =Invoke-GitQuiet -C $root status --porcelain --untracked-files=all -- context
  if ($st.Code -ne 0) { Die 'không kiểm tra được trạng thái context/.' @('git status -- context', 'sửa lỗi ở trên', 'crew upgrade') }
  # Bỏ qua file .bak-* / .new (kể cả khi project chưa ignore chúng).
  $dirty = @($st.Text -split '\r?\n+' | Where-Object { $_ } | ForEach-Object { $_.Substring(3).Trim('"') } | Where-Object { -not (Test-BakPath $_) -and -not (Test-NewPath $_) })
  if ($dirty.Count -and -not $Force) {
    $shown = @($dirty | Select-Object -First 5) -join ', '
    if ($dirty.Count -gt 5) { $shown += ", … (+$($dirty.Count - 5))" }
    Die "context/ có thay đổi chưa commit: $shown. Upgrade từ chối để không trộn việc của bạn vào commit upgrade." @("git -C `"$root`" add context", "git -C `"$root`" commit -m `"context: việc đang làm`"", "crew upgrade -DryRun", "crew upgrade", "Hoặc chạy luôn nếu chắc chắn:", "crew upgrade -Force")
  }
  Say "upgrade khung context v$old -> v$version"
  $changed = [Collections.Generic.List[string]]::new()
  $groupReplace = [Collections.Generic.List[string]]::new()
  $groupManual = [Collections.Generic.List[string]]::new()
  $groupKeep = [Collections.Generic.List[string]]::new()
  $openBlocks = [Collections.Generic.List[string]]::new()
  $hashes = Read-SkeletonHashes $root
  $released = Get-ReleasedHashes
  $relOf = { param($f) $f.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/' }
  # Chỉ biết có commit khi gặp file đầu tiên cần ghi: hỏi danh tính ngay trước lần ghi đó.
  $script:UpgradeWillWrite = $false
  $needCommit = {
    if ($script:UpgradeWillWrite) { return }
    $script:UpgradeWillWrite = $true
    if (-not $DryRun -and -not $NoCommit) { Confirm-GitIdentity $root $true $false }
  }
  function Write-UpgradeFile([string]$file, [string]$content) {
    if ((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -ceq $content) { return $false }
    & $needCommit
    Say "$(if ($DryRun) { 'sẽ ghi' } else { 'ghi' }) $file"
    if ($DryRun) { return $true }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($false))
    $changed.Add($file)
    $true
  }
  # Người dùng đã sửa: bản mới ra <file>.new (không commit), file gốc giữ nguyên từng byte.
  function Write-NewCopy([string]$file, [string]$content) {
    $rel = & $relOf $file
    $groupManual.Add($rel)
    if ($DryRun) { Write-Host "crew: CẢNH BÁO: $rel đã sửa tay — sẽ ghi bản mới ra $rel.new (DryRun chưa ghi), gộp tay rồi xóa .new" -ForegroundColor Yellow; return }
    $new = "$file.new"
    if (-not ((Test-Path -LiteralPath $new) -and [IO.File]::ReadAllText($new) -ceq $content)) {
      [IO.File]::WriteAllText($new, $content, [Text.UTF8Encoding]::new($false))
    }
    Write-Host "crew: CẢNH BÁO: $rel đã sửa tay — bản mới ở $rel.new, gộp tay rồi xóa .new" -ForegroundColor Yellow
  }
  $src = Join-Path $Skeleton 'context'
  foreach ($item in Get-ChildItem $src -Recurse -File -Force) {
    $rel = $item.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
    $dst = Join-Path $context $rel
    $exists = Test-Path -LiteralPath $dst
    # tasks/archive và file riêng của dự án (*.local.md) luôn được giữ nguyên, kể cả khi thiếu.
    if ($rel -match '^(tasks|archive)/' -or $rel -match '\.local\.md$') { continue }
    $new = [IO.File]::ReadAllText($item.FullName)
    if (Test-HashedSkeletonPath $rel) {
      if (-not $exists) {
        Write-UpgradeFile $dst $new | Out-Null; $groupReplace.Add("context/$rel (thêm)"); $hashes[$rel] = Get-TextHash $new; continue
      }
      switch (Get-SkeletonAction $rel ([IO.File]::ReadAllText($dst)) $new $hashes $released) {
        'same' { $groupKeep.Add("context/$rel"); $hashes[$rel] = Get-TextHash $new }
        'replace' { Write-UpgradeFile $dst $new | Out-Null; $groupReplace.Add("context/$rel"); $hashes[$rel] = Get-TextHash $new }
        default { Write-NewCopy $dst $new }
      }
      continue
    }
    if (-not $exists) { if (Write-UpgradeFile $dst $new) { $groupReplace.Add("context/$rel (thêm)") }; continue }
    if ($rel -eq 'PITFALLS.md') {
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
      if ($add.Count) {
        Write-UpgradeFile $dst ($text + $(if ($text.EndsWith("`n")) { '' } else { "`n" }) + ($add -join "`n") + "`n") | Out-Null
        $groupReplace.Add("context/PITFALLS.md (thêm $($add.Count) dòng)")
      }
    }
  }
  # Khối crew: chỉ phần giữa <!-- crew --> và <!-- /crew -->; ngoài khối luôn giữ nguyên.
  $block = Get-CrewBlock
  $blockInner = (Find-CrewBlock $block).Inner
  foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
    $file = Join-Path $root $name
    $key = "$name#crew"
    $text = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '' }
    $b = Find-CrewBlock $text
    if ($b.State -eq 'open') {
      $openBlocks.Add($name)
      Write-Host "crew: CẢNH BÁO: $name có <!-- crew --> nhưng thiếu <!-- /crew --> — không sửa file này. Thêm dòng <!-- /crew --> bằng tay ngay sau khối crew rồi chạy lại crew upgrade." -ForegroundColor Yellow
      continue
    }
    if ($b.State -eq 'none') {
      Write-UpgradeFile $file ($text + $(if ($text) { "`n" } else { '' }) + $block + "`n") | Out-Null
      $groupReplace.Add("$name (thêm khối crew)"); $hashes[$key] = Get-TextHash $blockInner; continue
    }
    $next = $text.Substring(0, $b.Index) + $block + $text.Substring($b.Index + $b.Length)
    switch (Get-SkeletonAction $key $b.Inner $blockInner $hashes $released) {
      'same' { $groupKeep.Add("$name (khối crew)"); $hashes[$key] = Get-TextHash $blockInner }
      'replace' { Write-UpgradeFile $file $next | Out-Null; $groupReplace.Add("$name (khối crew)"); $hashes[$key] = Get-TextHash $blockInner }
      default { Write-NewCopy $file $next }
    }
  }
  # Cùng version (kể cả file CRLF do init ghi) ⇒ không ghi lại.
  $other = $false
  if ($old -cne $version -or -not (Test-Path -LiteralPath $versionFile)) {
    $other = Write-UpgradeFile $versionFile "$version`n"
    if ($other) { $groupReplace.Add("context/.skeleton-version (v$old -> v$version)") }
  }
  $hashFile = Join-Path $context '.skeleton-hashes.json'
  if (Write-SkeletonHashes $root $hashes $true) {
    & $needCommit
    $other = $true
    $groupReplace.Add('context/.skeleton-hashes.json (dấu bản mẫu)')
    Say "$(if ($DryRun) { 'sẽ ghi' } else { 'ghi' }) $hashFile"
    if (-not $DryRun) { Write-SkeletonHashes $root $hashes | Out-Null; $changed.Add($hashFile) }
  }
  $gi = Join-Path $root '.gitignore'
  $ignoreText = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
  $ignoreLines = @($ignoreText -split '\r?\n+' | ForEach-Object { $_.Trim() })
  $ignoreAdd = @(@('*.bak-*') + @(if ($ignoreLines -cnotcontains '*.new') { Get-NewIgnoreLines }) | Where-Object { $ignoreLines -cnotcontains $_ })
  if ($ignoreAdd.Count) { & $needCommit; $other = $true; $groupReplace.Add(".gitignore (thêm $($ignoreAdd -join ', '))") }
  Update-ConfigName $root ([bool]$DryRun)
  if ($DryRun) {
    foreach ($l in $ignoreAdd) { Say "sẽ thêm $l vào .gitignore." }
    if ($script:UpgradeWillWrite -and -not $NoCommit) { Confirm-GitIdentity $root $true $true }
    Say 'DryRun: không ghi file, không commit.'
    Write-UpgradeSummary $old $version $groupReplace $groupManual $groupKeep $openBlocks $true ([bool]$other) $crew
    return
  }
  foreach ($l in $ignoreAdd) {
    if (Add-GitIgnoreLine $root $l @(if ($l -ne '*.bak-*') { '*.new' })) {
      if (-not $changed.Contains((Join-Path $root '.gitignore'))) { $changed.Add((Join-Path $root '.gitignore')) }
      if ($NoCommit) { Say "đã thêm $l vào .gitignore (chưa commit)" }
    }
  }
  # Phòng thủ: không bao giờ add file .bak-* / .new hay file bị git ignore (chưa track).
  $files = @($changed.ToArray() | Where-Object {
      -not (Test-BakPath $_) -and -not (Test-NewPath $_) -and (Invoke-GitQuiet -C $root check-ignore -q -- $_).Code -ne 0 })
  if ($NoCommit) { Say 'bỏ qua commit (-NoCommit).' }
  elseif (-not $files.Count) { Say 'không có gì mới để commit.' }
  else {
    Invoke-GitOrDie 'git add' -C $root add -- @files | Out-Null
    # Chỉ commit file upgrade, không kéo theo các file đã stage ngoài phạm vi.
    Invoke-GitOrDie 'commit upgrade' -C $root commit -q --only -m "chore: crew upgrade (Crewline v$crew) context -> v$version" -- @files | Out-Null
  }
  Write-UpgradeSummary $old $version $groupReplace $groupManual $groupKeep $openBlocks $false ([bool]$other) $crew
}
