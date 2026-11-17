# ---------------- tên crew ----------------
# Slug kiểu cũ (trước khi config có `name`): giữ Y HỆT để project cũ không đổi tên terminal đang chạy. Chỉ Get-CrewName/upgrade gọi.
function Get-LegacySlug([string]$root) {
  $s = (Split-Path $root -Leaf).ToLower() -replace '[^a-z0-9]+', '-'
  $s = $s.Trim('-')
  if ($s.Length -gt 12) { $s = $s.Substring(0, 12).TrimEnd('-') }
  return $s
}

# Sinh tên cho project mới: bỏ dấu (FormD, bỏ NonSpacingMark, đ→d), lowercase, ký tự lạ → '-', ≤12 ký tự; rỗng ⇒ crew-<6 hex từ hash root>.
function Get-Slug([string]$root) {
  $leaf = (Split-Path $root -Leaf).Normalize([Text.NormalizationForm]::FormD)
  $plain = -join @($leaf.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
  $s = $plain.Replace('đ', 'd').Replace('Đ', 'D').ToLowerInvariant() -creplace '[^a-z0-9]+', '-'
  $s = $s.Trim('-')
  if ($s.Length -gt 12) { $s = $s.Substring(0, 12).TrimEnd('-') }
  if (-not $s) {
    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-RootKey $root).ToLowerInvariant()))
    $s = 'crew-' + (-join @($bytes[0..2] | ForEach-Object { $_.ToString('x2') }))
  }
  return $s
}

# Tên crew hợp lệ: a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'.
function Test-CrewName([string]$n) { $n -cmatch '^[a-z0-9](?:[a-z0-9-]{0,10}[a-z0-9])?$' }

# Tên crew của project — chỗ DUY NHẤT mọi lệnh lấy tên (terminal <tên>-planner|-w<N>|-rev, space spcrew<tên>).
# Config có `name` ⇒ dùng; chưa có (project cũ) ⇒ slug cũ y hệt.
function Get-CrewName([string]$root, $cfg) {
  if ($cfg -and $cfg.PSObject.Properties.Name -contains 'name' -and $null -ne $cfg.name) {
    $n = [string]$cfg.name
    if (-not (Test-CrewName $n)) { Die "tên crew '$n' trong .crew/config.json không hợp lệ (a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'). Sửa `"name`" hoặc chạy: crew init -Name <tên>" }
    return $n
  }
  $s = Get-LegacySlug $root
  if (-not $s) { Die "không suy ra được tên crew từ thư mục '$(Split-Path $root -Leaf)'. Chạy 'crew upgrade' (tự ghi name) hoặc 'crew init -Name <tên>'." }
  return $s
}

# Đường dẫn chuẩn hóa để so: tuyệt đối, bỏ dấu tách cuối, '/' và '\' như nhau trên Windows.
function ConvertTo-RootKey([string]$p) {
  $f = [IO.Path]::GetFullPath($p)
  if ($f.Length -gt 3 -or -not $IsWindows) { $f = $f.TrimEnd('\', '/') }
  if (-not $f) { $f = '/' }
  return $f
}

# So hai đường dẫn đã chuẩn hóa; Windows không phân biệt hoa thường.
function Test-SamePath([string]$a, [string]$b) {
  $cmp = if ($IsWindows -or $PSVersionTable.PSEdition -ne 'Core') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  [string]::Equals((ConvertTo-RootKey $a), (ConvertTo-RootKey $b), $cmp)
}

# Terminal (object `hc ls --json` / `hc get --json`) thuộc project $root: cwd là root hoặc <root>/.crew/worktrees/w<N>.
function Test-TermOwner($term, [string]$root) {
  $cwd = if ($term -and $term.cwd) { [string]$term.cwd } else { '' }
  if (-not $cwd) { return $false }
  if (Test-SamePath $cwd $root) { return $true }
  $key = ConvertTo-RootKey $cwd
  (Split-Path $key -Leaf) -match '^w\d+$' -and (Test-SamePath (Split-Path $key -Parent) (Join-Path $root '.crew/worktrees'))
}

# Lý do chặn khi terminal $name đang live mà thuộc project khác; '' khi của mình, không live, hoặc hc không báo cwd (không kiểm được).
function Get-ForeignTermError([string]$name, $term, [string]$root) {
  if (-not $term -or $term.state -ne 'live' -or -not $term.cwd) { return '' }
  if (Test-TermOwner $term $root) { return '' }
  "terminal $name đang chạy ở project khác (cwd $($term.cwd)), không phải $root — trùng tên crew. Đặt tên khác: crew init -Name <tên> trong project này, hoặc sửa `"name`" trong .crew/config.json."
}

# Khóa id herdr (space/tab) của crew: mã hóa đơn ánh từ tên [a-z0-9-]: 'z'→'zz', '-'→'zd' (my-app→myzdapp, myapp→myapp).
function ConvertTo-IdKey([string]$n) { $n.Replace('z', 'zz').Replace('-', 'zd') }
# Khóa kiểu cũ (trước idKey): tên bỏ '-' — chỉ để giữ space/tab của project cũ.
function Get-LegacyIdKey([string]$n) { $n -replace '-', '' }
function Test-IdKey([string]$k) { $k -cmatch '^[a-z0-9]{1,24}$' }

# Khóa id của project — chỗ DUY NHẤT: config có idKey ⇒ dùng; thiếu (project cũ) ⇒ khóa cũ từ tên như trước.
function Get-CrewIdKey([string]$root, $cfg) {
  if ($cfg -and $cfg.PSObject.Properties.Name -contains 'idKey' -and $null -ne $cfg.idKey) {
    $k = [string]$cfg.idKey
    if (-not (Test-IdKey $k)) { Die "idKey '$k' trong .crew/config.json không hợp lệ (a-z 0-9, 1–24 ký tự). Sửa `"idKey`" hoặc chạy: crew init -Name <tên>" }
    return $k
  }
  Get-LegacyIdKey (Get-CrewName $root $cfg)
}

# Sổ tên crew toàn máy: ~/.crewline/projects.json = { "<tên>": { "root": "<root tuyệt đối>", "idKey": "<khóa>" } }.
# Bản đầu ghi { "<tên>": "<root>" } — vẫn đọc được, idKey coi như khóa cũ (tên bỏ '-').
function Get-ProjectsFile { Join-Path $HOME '.crewline/projects.json' }

# Đọc sổ: @{ Ok; Map (tên -> @{ Root; IdKey }); Error }. Hỏng ⇒ Ok = $false (người gọi cảnh báo, không chặn).
function Read-ProjectRegistry {
  $f = Get-ProjectsFile
  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $f)) { return @{ Ok = $true; Map = $map; Error = '' } }
  try {
    $text = [IO.File]::ReadAllText($f)
    if (-not $text.Trim()) { return @{ Ok = $true; Map = $map; Error = '' } }
    $j = $text | ConvertFrom-Json
    if ($j -isnot [pscustomobject]) { throw 'cần một JSON object' }
    foreach ($p in $j.PSObject.Properties) {
      $v = $p.Value
      if ($v -is [string] -and $v) { $map[$p.Name] = @{ Root = $v; IdKey = (Get-LegacyIdKey $p.Name) }; continue }
      if ($v -isnot [pscustomobject] -or $v.root -isnot [string] -or -not $v.root) { throw "mục '$($p.Name)' cần root là đường dẫn" }
      $k = if ($v.idKey -is [string] -and $v.idKey) { $v.idKey } else { Get-LegacyIdKey $p.Name }
      $map[$p.Name] = @{ Root = $v.root; IdKey = $k }
    }
    return @{ Ok = $true; Map = $map; Error = '' }
  } catch { return @{ Ok = $false; Map = [ordered]@{}; Error = "sổ tên crew $f hỏng ($($_.Exception.Message))" } }
}

function Save-ProjectRegistry($map) {
  $f = Get-ProjectsFile
  New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  $o = [ordered]@{}
  foreach ($k in @($map.Keys | Sort-Object)) { $o[$k] = [ordered]@{ root = $map[$k].Root; idKey = $map[$k].IdKey } }
  [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
}

# Mục sổ thuộc root khác còn tồn tại (có .crew/config.json)?
function Test-OtherAlive($entry, [string]$root) {
  $other = [string]$entry.Root
  -not (Test-SamePath $other $root) -and (Test-Path -LiteralPath (Join-Path $other '.crew/config.json'))
}

# Root khác đang giữ tên $n trong sổ (còn .crew/config.json); '' khi trống, của chính $root, hoặc root cũ không còn.
function Get-NameOwner($map, [string]$n, [string]$root) {
  if (-not $map.Contains($n)) { return '' }
  if (Test-OtherAlive $map[$n] $root) { return [string]$map[$n].Root }
  ''
}

# Root khác còn tồn tại đang dùng khóa id $k (space/tab herdr); ''.
function Get-IdKeyOwner($map, [string]$k, [string]$root) {
  foreach ($n in @($map.Keys)) {
    if ($map[$n].IdKey -ceq $k -and (Test-OtherAlive $map[$n] $root)) { return [string]$map[$n].Root }
  }
  ''
}

# Tên trống gần nhất: $base, rồi $base-2, -3… (cắt phần gốc để ≤12 ký tự). Trống = tên chưa ai giữ và idKey mới của nó chưa ai dùng.
# $takenKeys: khóa id đang bị space herdr live của project khác dùng (Get-TakenIdKeys), kể cả project chưa vào sổ.
function Resolve-CrewName([string]$base, [string]$root, $map, [string[]]$takenKeys = @()) {
  $free = { param($c) $k = ConvertTo-IdKey $c; -not (Get-NameOwner $map $c $root) -and -not (Get-IdKeyOwner $map $k $root) -and $takenKeys -cnotcontains $k }
  if (& $free $base) { return $base }
  for ($i = 2; $i -lt 1000; $i++) {
    $suffix = "-$i"; $b = $base
    if ($b.Length + $suffix.Length -gt 12) { $b = $b.Substring(0, 12 - $suffix.Length).TrimEnd('-') }
    $c = "$b$suffix"
    if (& $free $c) { return $c }
  }
  Die "không tìm được tên crew trống từ '$base' — chạy: crew init -Name <tên>"
}
