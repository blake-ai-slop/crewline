# Chỉ đọc repo/context; không phụ thuộc crew hoặc hc.
function Get-LintLimits {
  @{ Lines = @{ 'HOT.md' = 30; 'DECISIONS.md' = 30; 'PITFALLS.md' = 40; 'PROGRESS.md' = 50 }; ItemChars = 300; FileBytes = 6KB }
}

function Get-ContextLint([string]$root) {
  $root = [IO.Path]::GetFullPath($root)
  $limits = Get-LintLimits
  $context = Join-Path $root 'context'
  if (-not (Test-Path -LiteralPath $context -PathType Container)) { return }
  $allTracked = @(git -C $root -c core.quotepath=false ls-files 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'Không đọc được danh sách file git track.' }
  $trackedNames = @($allTracked | ForEach-Object { Split-Path $_ -Leaf })
  $pathWarnings = @()
  $code = foreach ($path in @($allTracked | Where-Object { $_ -notlike 'context/*' })) {
    $full = Join-Path $root $path
    if (Test-Path -LiteralPath $full -PathType Leaf) { [IO.File]::ReadAllText($full) }
  }
  $codeText = $code -join "`n"
  $seen = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
  foreach ($file in @(Get-ChildItem -LiteralPath $context -Recurse -File -Filter '*.md' | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($context.Length).TrimStart('\', '/') -replace '\\', '/'
    if ($relative -match '^(archive|tasks)/') { continue }
    $name = "context/$relative"
    $lines = [IO.File]::ReadAllLines($file.FullName)
    if ($file.Length -gt $limits.FileBytes) { @{ File=$name; Line=1; Rule='file-size'; Message="file > $($limits.FileBytes) byte" } }
    $nonempty = @($lines | Where-Object { $_.Trim() }).Count
    if ($limits.Lines.ContainsKey($relative) -and $nonempty -gt $limits.Lines[$relative]) {
      @{ File=$name; Line=1; Rule='line-limit'; Message="$nonempty dòng không rỗng > $($limits.Lines[$relative])" }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*-\s+') {
        $item = $lines[$i].Trim(); $j = $i + 1
        while ($j -lt $lines.Count -and $lines[$j] -match '^\s+\S' -and $lines[$j] -notmatch '^\s*-\s+') { $item += ' ' + $lines[$j].Trim(); $j++ }
        if ($item.Length -gt $limits.ItemChars) { @{ File=$name; Line=$i+1; Rule='item-length'; Message="mục $($item.Length) ký tự > $($limits.ItemChars)" } }
        if ($seen.ContainsKey($item)) {
          if ($seen[$item] -ne $name) { @{ File=$name; Line=$i+1; Rule='duplicate'; Message="mục trùng trong $($seen[$item])" } }
        } else { $seen[$item] = $name }
      }
      if ($relative -notin 'MAP.md','PITFALLS.md','DECISIONS.md') { continue }
      foreach ($match in [regex]::Matches($lines[$i], '`([^`]+)`')) {
        $token = $match.Groups[1].Value
        if ($token -cmatch '^[A-Z][a-z]+-[A-Z][A-Za-z0-9]*$' -and $codeText -notmatch ('(?<![\w-])' + [regex]::Escape($token) + '(?![\w-])')) {
          @{ File=$name; Line=$i+1; Rule='missing-function'; Message="$token : tên không còn trong code" }
        }
        if ($token -match '[<*~%$\s]|^/|[A-Za-z]:|^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }
        if (($token.Contains('/') -or $token -match '\.(ps1|md|json)$') -and -not (Test-Path -LiteralPath (Join-Path $root $token))) {
          if (Test-Path -LiteralPath (Join-Path $context $token)) { continue }
          if (-not $token.Contains('/') -and $trackedNames -contains $token) { continue }
          $pathWarnings += @{ Token=$token; Warning=@{ File=$name; Line=$i+1; Rule='missing-path'; Message="$token : đường dẫn không tồn tại" } }
        }
      }
    }
  }
  if ($pathWarnings.Count) {
    # Một lần cho cả lô; check-ignore cũng nhận ra thư mục cha bị ignore.
    $paths = @($pathWarnings | ForEach-Object { $_.Token; "context/$($_.Token)" } | Select-Object -Unique)
    $ignoredText = (($paths -join "`0") + "`0") | git -C $root check-ignore -z --stdin 2>$null
    $ignored = @(("$ignoredText" -split "`0") | Where-Object { $_ })
    if ($LASTEXITCODE -gt 1) { throw 'Không kiểm tra được đường dẫn git ignore.' }
    foreach ($candidate in $pathWarnings) {
      if ($ignored -notcontains $candidate.Token -and $ignored -notcontains "context/$($candidate.Token)") { $candidate.Warning }
    }
  }
}
