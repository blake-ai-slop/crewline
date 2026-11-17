# ---------------- doctor ----------------
# Thêm dòng vào .gitignore của project nếu chưa có (so nguyên dòng sau trim). Trả $true nếu đã thêm.
function Add-GitIgnoreLine([string]$root, [string]$line, [string[]]$same = @()) {
  $gi = Join-Path $root '.gitignore'
  $text = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
  $have = @($text -split '\r?\n+' | ForEach-Object { $_.Trim() })
  foreach ($l in @($line) + $same) { if ($have -ccontains $l) { return $false } }
  $sep = if ($text -and -not $text.EndsWith("`n")) { "`n" } else { '' }
  [IO.File]::AppendAllText($gi, "$sep$line`n", [Text.UTF8Encoding]::new($false))
  Say "thêm $line vào .gitignore."
  return $true
}

# File sao lưu .bak-* là bản an toàn cục bộ, không commit.
function Test-BakPath([string]$p) { (Split-Path $p -Leaf) -like '*.bak-*' }

function Invoke-Doctor {
  $script:bad = 0
  function Check([string]$label, [bool]$ok, [string]$fix) {
    if ($ok) { Write-Host "  OK    $label" -ForegroundColor Green }
    else { Write-Host "  THIẾU $label  -> $fix" -ForegroundColor Yellow; $script:bad++ }
  }
  Write-Host "Môi trường"
  Check "trong pane herdr (HC_TERMINAL_ID=$env:HC_TERMINAL_ID)" ([bool]$env:HC_TERMINAL_ID) 'mở herdr-app và chạy trong một pane của nó'
  # Bảng phần mềm từ scripts/prereq.ps1; claude/codex chỉ cần khi đội (project > cá nhân > standard) dùng tới.
  . (Join-Path $CrewScriptsDir 'prereq.ps1')
  $root = Get-Root $Path
  $userCfg = if ($env:CREWLINE_USER_CONFIG) { $env:CREWLINE_USER_CONFIG } else { Join-Path $HOME '.crewline/config.json' }
  $files = @(if ($root) { Join-Path $root '.crew/config.json' }) + @($userCfg)
  $need = Get-TeamAgents (Get-PrereqTeam $files (Join-Path $CrewScriptsDir 'teams.json'))
  foreach ($p in Get-Prereqs) {
    if ($p.Group -eq 'team' -and $need -notcontains $p.Name) {
      Write-Host "  --    $($p.Label) (không dùng trong đội)" -ForegroundColor DarkGray
      continue
    }
    Check $p.Label (Test-Prereq $p) (Get-PrereqFix $p)
  }
  if (Get-GitIdentityError $root) {
    Write-Host '  GHI CHÚ git identity: chưa có tên/email; git yêu cầu để ghi vào commit, crew sẽ hỏi khi cần commit.' -ForegroundColor DarkGray
  } else {
    $at = @(if ($root) { '-C', $root })
    Check "git identity ($((Invoke-GitQuiet @at var GIT_AUTHOR_IDENT).Text -replace '\s+\d+\s+[+-]\d+$', ''))" $true ''
  }
  $tdir = Get-HcTemplateDir
  $tpl = @(Get-ChildItem $tdir -Filter 'crew-*.md' -ErrorAction SilentlyContinue).Count
  Check "template hc ($tpl trong $tdir)" ($tpl -ge 4) 'chạy install.ps1'
  Check "khung context ($Skeleton)" (Test-Path (Join-Path $Skeleton 'context/roles/planner.md')) 'repo Crewline thiếu skeleton/'
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.crew/config.json'))) {
    $pcfg = Get-Config $root
    $clash = Get-NameConflict $root $pcfg
    Check "tên crew '$(Get-CrewName $root $pcfg)' chỉ thuộc project này" (-not $clash) $clash
  }
  if (Get-Command hc -ErrorAction SilentlyContinue) {
    & { $ErrorActionPreference = 'Continue'; hc server status *> $null }
    Check 'herdr-core đang chạy' ($LASTEXITCODE -eq 0) 'mở herdr-app'
  }
  Write-Host "Nhắc: agent phải đã đăng nhập, crew không tự đăng nhập: $(($need | ForEach-Object { "$_ ($(Get-AgentLogin $_))" }) -join ', ')."
  if ($script:bad) { exit 1 }
}

# ---------------- init ----------------
# Tên crew + khóa id cho init: -Name > `name` đã có trong config > slug cũ (config cũ chưa có name) > Get-Slug; tên tự sinh mà trùng ⇒ -2, -3…
# idKey: giữ khóa đang dùng khi tên không đổi (project cũ ⇒ khóa cũ, không đổi space/tab); tên mới ⇒ ConvertTo-IdKey. Trả @{ Name; IdKey }.
function Select-InitName([string]$root, [string]$cfgFile) {
  $prev = $null
  if (Test-Path -LiteralPath $cfgFile) { try { $prev = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json } catch { $prev = $null } }
  $prevName = ''; $prevKey = ''
  if ($prev) {
    $prevName = if ($prev.PSObject.Properties.Name -contains 'name' -and (Test-CrewName ([string]$prev.name))) { [string]$prev.name } else { Get-LegacySlug $root }
    $prevKey = if ($prev.PSObject.Properties.Name -contains 'idKey' -and (Test-IdKey ([string]$prev.idKey))) { [string]$prev.idKey } elseif ($prevName) { Get-LegacyIdKey $prevName } else { '' }
  }
  $keyFor = { param($n) if ($prevName -and $n -ceq $prevName -and $prevKey) { $prevKey } else { ConvertTo-IdKey $n } }
  if ($Name) { return @{ Name = $Name; IdKey = (& $keyFor $Name) } }
  if ($prev -and $prev.PSObject.Properties.Name -contains 'name' -and $prevName -ceq [string]$prev.name) {
    $clash = Get-NameConflict $root $prev
    if ($clash) { Say "cảnh báo: $clash" }
    return @{ Name = $prevName; IdKey = $prevKey }
  }
  $base = if ($prevName) { $prevName } else { Get-Slug $root }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { Say "cảnh báo: $($reg.Error) — không kiểm được tên trùng với project khác (crew up vẫn kiểm cwd terminal)." }
  $hs = Get-HerdrSpaces
  $taken = if ($hs.Ok) { Get-TakenIdKeys $hs.Spaces $root } else { @() }
  $chosen = Resolve-CrewName $base $root $reg.Map $taken
  if ($chosen -ne $base) {
    $who = Get-NameOwner $reg.Map $base $root
    if (-not $who) { $who = Get-IdKeyOwner $reg.Map (ConvertTo-IdKey $base) $root }
    if (-not $who) { $who = "(space herdr spcrew$(ConvertTo-IdKey $base) đang chạy)" }
    Say "tên '$base' (hoặc khóa id của nó) đã thuộc project $who — dùng tên '$chosen'."
  }
  @{ Name = $chosen; IdKey = (& $keyFor $chosen) }
}

# Trùng idKey không chứng minh bản chép: chỉ tên trong sổ thuộc root khác còn sống.
function Get-CopySource([string]$root, $cfg) {
  if (-not $cfg -or -not $cfg.name) { return '' }
  $reg = Read-ProjectRegistry
  if (-not $reg.Ok) { return '' }
  Get-NameOwner $reg.Map ([string]$cfg.name) $root
}

# Chỉ dọn trạng thái mang theo từ root khác còn tồn tại; không sửa metadata git.
function Clear-CopiedCrewState([string]$root, $cfg) {
  if (-not (Get-CopySource $root $cfg)) { return }
  $listed = Invoke-GitOrDie 'đọc worktree trước khi dọn bản chép' -C $root worktree list --porcelain
  $paths = @($listed.Text -split "`n" | Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9).TrimEnd("`r") })
  $parent = Join-Path (ConvertTo-RootKey $root) '.crew/worktrees'
  foreach ($path in @((Join-Path $root '.crew'), $parent, (Join-Path $root '.crew/config.json'))) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Die "không dọn tự động đường dẫn liên kết: $path"
    }
  }
  $remove = @()
  if (Test-Path -LiteralPath $parent) {
    foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory -Force) {
      if ($dir.Name -notmatch '^w\d+$') { continue }
      if (@($paths | Where-Object { Test-SamePath $_ $dir.FullName }).Count) { Say "giữ worktree git đã đăng ký: $($dir.FullName)"; continue }
      # Kiểm đường dẫn tuyệt đối trước xóa đệ quy; không đi theo junction/symlink.
      if (-not (Test-SamePath (Split-Path $dir.FullName -Parent) $parent) -or
          ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
          @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        Die "không dọn tự động đường dẫn liên kết/ngoài phạm vi: $($dir.FullName)"
      }
      $remove += $dir.FullName
    }
  }
  foreach ($dir in $remove) {
    Remove-Item -LiteralPath $dir -Recurse -Force
    Say "đã dọn worktree chép theo (không đăng ký trong git bản chép): $dir"
  }
  $tasksFile = Join-Path $root '.crew/tasks.json'
  if (Test-Path -LiteralPath $tasksFile) { Remove-Item -LiteralPath $tasksFile -Force; Say 'đã dọn .crew/tasks.json của bản gốc.' }
  $cfg.PSObject.Properties.Remove('name')
  $cfg.PSObject.Properties.Remove('idKey')
  $cfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $root '.crew/config.json') -Encoding utf8
  Say 'đã bỏ name/idKey của bản gốc; khởi tạo crew mới cho bản chép.'
}

function Invoke-Init {
  $teams = Get-Teams
  $defaults = Get-UserDefaults $teams
  $t = Select-Team $teams $defaults
  foreach ($key in 'Review', 'Access') {
    if (-not $InitParameters.ContainsKey($key) -and $defaults.ContainsKey($key.ToLower())) {
      Set-Variable -Name $key -Value $defaults[$key.ToLower()]
    }
  }
  $p = (Resolve-Path $Path).Path
  $root = Get-Root $p
  $copyRoot = if ($root) { $root } else { $p }
  $copyConfig = Join-Path $copyRoot '.crew/config.json'
  $copied = $null
  if (Test-Path -LiteralPath $copyConfig) {
    $previous = Get-Content -LiteralPath $copyConfig -Raw | ConvertFrom-Json
    if (Get-CopySource $copyRoot $previous) {
      if (-not $Name) { Die 'project là bản chép (bản sao) của crew còn tồn tại; chạy crew init -Name <tên mới> để dọn trạng thái chép theo và tạo crew riêng.' }
      $copied = $previous
    }
  }
  # -Name kiểm ngay, trước khi đụng git
  if ($Name) {
    if (-not (Test-CrewName $Name)) { Die "-Name '$Name' không hợp lệ: chỉ a-z 0-9 -, 1–12 ký tự, không bắt đầu/kết thúc bằng '-'." }
    $reg = Read-ProjectRegistry
    $here = if ($root) { $root } else { $p }
    $other = if ($reg.Ok) { Get-NameOwner $reg.Map $Name $here } else { '' }
    if ($other) { Die "tên crew '$Name' đã thuộc project $other — chọn tên khác." }
    $other = if ($reg.Ok) { Get-IdKeyOwner $reg.Map (ConvertTo-IdKey $Name) $here } else { '' }
    if ($other) { Die "khóa id herdr của tên '$Name' ($(ConvertTo-IdKey $Name)) đã thuộc project $other — chọn tên khác." }
    $hs = Get-HerdrSpaces
    if ($hs.Ok -and (Get-TakenIdKeys $hs.Spaces $here) -ccontains (ConvertTo-IdKey $Name)) { Die "space herdr spcrew$(ConvertTo-IdKey $Name) đang thuộc project khác — chọn tên khác cho -Name." }
  }
  $hasHead = [bool]$root -and (Invoke-GitQuiet -C $root rev-parse --verify -q HEAD).Code -eq 0
  if (-not $hasHead -and -not $GitInit) {
    if ($root) {
      $fail = 'repo chưa có commit nào. Chạy lại với -GitInit để tạo commit đầu.'
      $answer = Read-GitInitChoice "Repo $root chưa có commit nào." 'Tạo commit đầu với các file đang có'
    } else {
      $fail = "$p không phải repo git. Chạy lại với -GitInit để git init + commit đầu."
      $answer = Read-GitInitChoice "Thư mục $p chưa là repo git." 'Tạo repo git mới ở đây (git init + commit đầu)'
    }
    if ($null -eq $answer) { Die $fail }
    if ($answer -ne 'yes') { Say 'thôi, không tạo gì.'; exit 1 }
  }
  if (-not $hasHead -or -not $NoCommit) { Confirm-GitIdentity $(if ($root) { $root } else { $p }) $true $false }
  if (-not $root) {
    Say "git init $p"
    Invoke-GitOrDie 'git init' -C $p init -q -b main | Out-Null
    $root = (Resolve-Path $p).Path
  }
  if (-not $hasHead) {
    if ($copied) { Clear-CopiedCrewState $root $copied; $copied = $null }
    Say "tạo commit đầu với các file đang có."
    Invoke-GitOrDie 'git add' -C $root add -A | Out-Null
    Invoke-GitOrDie 'commit đầu' -C $root commit -q --allow-empty -m 'chore: initial commit' | Out-Null
    $hasHead = $true
  }

  if ($copied) { Clear-CopiedCrewState $root $copied }
  # không có Rev thì không ai review ⇒ ép chế độ nhanh
  $rv = $Review; if ($t.rev -eq 'none') { $rv = 'fast' }
  $reviewVi = @{ fast = 'Nhanh'; lean = 'Gọn'; full = 'Đủ' }[$rv]
  $accessVi = @{ work = 'Làm việc'; wide = 'Mở rộng' }[$Access]
  $hotLine = "Chế độ review: **$reviewVi**. Quyền agent: $accessVi."

  # khung context: chép file chưa có
  $src = Join-Path $Skeleton 'context'
  Get-ChildItem $src -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
    $dst = Join-Path $root "context/$rel"
    # *.local.md là quy tắc riêng của project: init không tạo/sửa/xóa.
    if ((Test-Path $dst) -or $rel -match '\.local\.md$') { return }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $_.FullName $dst
  }
  $hot = Join-Path $root 'context/HOT.md'
  $hotText = Get-Content $hot -Raw
  if ($hotText -match '__HOTLINE__') {
    Set-Content $hot ($hotText -replace '__HOTLINE__', $hotLine) -Encoding utf8 -NoNewline
  } elseif (-not ($hotText -match '^Chế độ review')) {
    Copy-Item $hot "$hot.bak-$Today"
    Set-Content $hot "$hotLine`n`n$hotText" -Encoding utf8 -NoNewline
  }
  Say "khung context/ sẵn sàng (giữ nguyên file đã có)."
  Set-Content (Join-Path $root 'context/.skeleton-version') (Get-SkeletonVersion) -Encoding utf8

  $block = Get-CrewBlock
  Add-Block (Join-Path $root 'CLAUDE.md') $block
  Add-Block (Join-Path $root 'AGENTS.md') $block
  # Dấu bản mẫu (context/.skeleton-hashes.json): upgrade chỉ thay file/khối còn đúng bản đã cài.
  Update-InitSkeletonHashes $root

  Add-GitIgnoreLine $root '.crew/' @('.crew') | Out-Null
  Add-GitIgnoreLine $root '*.bak-*' | Out-Null
  foreach ($l in Get-NewIgnoreLines) { Add-GitIgnoreLine $root $l @('*.new') | Out-Null }

  New-Item -ItemType Directory -Force (Join-Path $root '.crew/prompts') | Out-Null
  $cfgFile = Join-Path $root '.crew/config.json'
  $sel = Select-InitName $root $cfgFile; $crewName = $sel.Name
  $cfg = [ordered]@{ name = $crewName; idKey = $sel.IdKey; planner = $t.planner; workers = @($t.workers); rev = $t.rev; review = $rv; access = $Access }
  $cfg | ConvertTo-Json -Depth 100 | Set-Content $cfgFile -Encoding utf8
  Say "ghi .crew/config.json: $(($cfg | ConvertTo-Json -Compress))"
  Register-CrewName $crewName $root $sel.IdKey | Out-Null
  Say "tên crew: $crewName (terminal $crewName-planner, $crewName-w<N>, $crewName-rev; đổi: crew init -Name <tên>)"

  if ($NoCommit) { Say "bỏ qua commit (-NoCommit)."; return }
  Invoke-GitQuiet -C $root add context CLAUDE.md AGENTS.md .gitignore | Out-Null
  if ((Invoke-GitQuiet -C $root diff --cached --quiet).Code -eq 0) { Say "không có gì mới để commit."; return }
  Invoke-GitOrDie 'commit khung context' -C $root commit -q -m 'chore: crew context skeleton' | Out-Null
  Say "commit: $(git -C $root log -1 --format='%h %s')"
}
