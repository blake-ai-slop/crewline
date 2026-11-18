. "$PSScriptRoot/TestHome.ps1"
# Nâng cấp không bao giờ ghi đè thứ người dùng đã sửa (DECISIONS 2026-11-17 "Cập nhật không ghi đè").
# Tự chứa: bản phát hành trước là tests/fixtures/skeleton-v10 (chạy được ở repo public không có lịch sử).
$repoRoot = Split-Path $PSScriptRoot -Parent
$crewScript = Join-Path $repoRoot 'scripts/crew.ps1'
$skeletonDir = Join-Path $repoRoot 'skeleton'
$v10Dir = Join-Path $PSScriptRoot 'fixtures/skeleton-v10'
$newVersion = (Get-Content (Join-Path $skeletonDir 'VERSION') -Raw).Trim()

function Get-LfHash([string]$text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes(($text -replace "`r`n", "`n"))) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

# Bản Crewline giả: scripts/ hiện tại + skeleton chỉ định.
function New-CrewCopy([string]$dir, [string]$skeleton) {
  New-Item -ItemType Directory -Force $dir | Out-Null
  Copy-Item (Join-Path $repoRoot 'scripts') $dir -Recurse
  Copy-Item $skeleton (Join-Path $dir 'skeleton') -Recurse
  Join-Path $dir 'scripts/crew.ps1'
}

# Ảnh chụp mọi file ngoài .git: đường dẫn => sha256 byte.
function Get-TreeSnapshot([string]$root) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $map = @{}
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $map[$f.FullName.Substring($root.Length)] = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($f.FullName)) | ForEach-Object { $_.ToString('x2') })
  }
  $sha.Dispose()
  ($map.Keys | Sort-Object | ForEach-Object { "$_=$($map[$_])" }) -join "`n"
}

Describe 'crew upgrade an toàn' {
  BeforeEach {
    $h = New-CrewTestHome
    $testEnv = @{ CREWLINE_USER_CONFIG = (Join-Path $h.Home 'config.json') }
    $repo = Join-Path $h.Home 'project'
    New-Item -ItemType Directory $repo | Out-Null
    git -C $repo init -q
    git -C $repo config core.autocrlf false
    git -C $repo config user.name 'Crew Test'
    git -C $repo config user.email 'crew@example.invalid'
    git -C $repo commit -q --allow-empty -m initial
    $run = {
      param([string]$script, [string[]]$extra = @())
      $r = Invoke-InTestHome -TestHome $h -File $script -Env $testEnv -Arguments (@('upgrade', '-Path', $repo) + $extra)
      $r | Add-Member -NotePropertyName Text -NotePropertyValue ($r.Output -join "`n") -PassThru
    }
  }

  It 'project v10 (chưa có dấu) đã sửa tay: không mất byte nào, .new đúng chỗ, file chưa sửa được thay, chạy lần 2 không làm gì' {
    $v10Crew = New-CrewCopy (Join-Path $h.Home 'crewline-v10') $v10Dir
    $r = Invoke-InTestHome -TestHome $h -File $v10Crew -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be '10'
    # bản v10 thật không có dấu và không ignore .new
    Remove-Item -Force "$repo/context/.skeleton-hashes.json"
    [IO.File]::WriteAllText("$repo/.gitignore", ".crew/`n*.bak-*`n")
    # người dùng sửa
    $planner = [IO.File]::ReadAllText("$repo/context/roles/planner.md") + "- Quy tắc riêng: luôn hỏi trước khi xóa dữ liệu.`n"
    [IO.File]::WriteAllText("$repo/context/roles/planner.md", $planner)
    [IO.File]::WriteAllText("$repo/context/roles/planner.local.md", "# Planner riêng`n- Không giao task vào thứ Sáu.`n")
    $claude = [IO.File]::ReadAllText("$repo/CLAUDE.md")
    $claude = "# Ghi chú của tôi`r`nDòng trước khối.`r`n`r`n" + $claude.Replace("- Bản đồ code: context/MAP.md.", "- Bản đồ code: context/MAP.md.`n- Luật riêng trong khối.") + "`nDòng sau khối.`n"
    [IO.File]::WriteAllText("$repo/CLAUDE.md", $claude)
    $agents = "# Agents`n<!-- crew -->`n## Context dùng chung (crew)`nĐọc ``context/README.md`` trước.`n- Luật crew cũ.`n- Bullet riêng của tôi ngay dưới khối.`n`nĐoạn riêng cuối file.`n"
    [IO.File]::WriteAllText("$repo/AGENTS.md", $agents)
    git -C $repo add -A
    git -C $repo commit -q -m 'v10 + sửa tay'
    $userFiles = 'context/roles/planner.md', 'context/roles/planner.local.md', 'CLAUDE.md', 'AGENTS.md', 'context/PROJECT.md', 'context/HOT.md'
    $before = @{}
    foreach ($f in $userFiles) { $before[$f] = [IO.File]::ReadAllBytes("$repo/$f") }

    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    foreach ($f in $userFiles) { [Convert]::ToBase64String([IO.File]::ReadAllBytes("$repo/$f")) | Should BeExactly ([Convert]::ToBase64String($before[$f])) }
    # .new đúng chỗ
    [IO.File]::ReadAllText("$repo/context/roles/planner.md.new") | Should BeExactly ([IO.File]::ReadAllText("$skeletonDir/context/roles/planner.md"))
    $claudeNew = [IO.File]::ReadAllText("$repo/CLAUDE.md.new")
    $claudeNew.StartsWith("# Ghi chú của tôi`r`nDòng trước khối.`r`n`r`n") | Should Be $true
    $claudeNew.EndsWith("`nDòng sau khối.`n") | Should Be $true
    $claudeNew | Should Match ([regex]::Escape('<!-- /crew -->'))
    $claudeNew | Should Not Match 'Luật riêng trong khối'
    Test-Path "$repo/AGENTS.md.new" | Should Be $false
    @(Get-ChildItem "$repo/context/roles" -Filter '*.new').Count | Should Be 1
    Test-Path "$repo/context/roles/planner.local.md.new" | Should Be $false
    # file chưa sửa (khớp bản v10 đã phát hành) được thay
    foreach ($f in 'roles/rev.md', 'roles/worker.md', 'README.md') {
      [IO.File]::ReadAllText("$repo/context/$f") | Should BeExactly ([IO.File]::ReadAllText("$skeletonDir/context/$f"))
    }
    (Get-Content "$repo/context/.skeleton-version" -Raw).Trim() | Should Be $newVersion
    $hashes = Get-Content "$repo/context/.skeleton-hashes.json" -Raw | ConvertFrom-Json
    $hashes.'roles/rev.md' | Should Be (Get-LfHash ([IO.File]::ReadAllText("$skeletonDir/context/roles/rev.md")))
    @($hashes.PSObject.Properties.Name) -ccontains 'roles/planner.md' | Should Be $false
    @($hashes.PSObject.Properties.Name) -ccontains 'CLAUDE.md#crew' | Should Be $false
    @($hashes.PSObject.Properties.Name) -ccontains 'AGENTS.md#crew' | Should Be $false
    # .new không commit, worktree sạch
    @(git -C $repo ls-files '*.new').Count | Should Be 0
    @(git -C $repo status --porcelain --untracked-files=all).Count | Should Be 0
    (git -C $repo log -1 --format=%s) | Should Be "chore: crew upgrade context -> v$newVersion"
    # khối tóm tắt
    $r.Text | Should Match ([regex]::Escape("== crew upgrade: context v10 -> v$newVersion"))
    $r.Text | Should Match 'Đã cập nhật \(\d+\): .*context/roles/rev\.md'
    $r.Text | Should Match ([regex]::Escape('Giữ bản của bạn, bản mới ở .new (2): context/roles/planner.md -> context/roles/planner.md.new, CLAUDE.md -> CLAUDE.md.new'))
    $r.Text | Should Match ([regex]::Escape("git diff --no-index -- 'context/roles/planner.md' 'context/roles/planner.md.new'"))
    $r.Text | Should Match ([regex]::Escape("git diff --no-index -- 'CLAUDE.md' 'CLAUDE.md.new'"))
    $r.Text | Should Match ([regex]::Escape('AGENTS.md (thiếu <!-- /crew -->)'))
    $r.Text | Should Match 'Việc cần làm: mở từng cặp .*context/roles/<vai>\.local\.md'
    $r.Text | Should Match ([regex]::Escape('thêm dòng <!-- /crew --> ngay sau khối crew trong AGENTS.md rồi chạy lại crew upgrade'))
    $r.Text | Should Match ([regex]::Escape('CẢNH BÁO: AGENTS.md có <!-- crew --> nhưng thiếu <!-- /crew -->'))

    # chạy lần 2: không đổi file, không commit
    $head = git -C $repo rev-parse HEAD
    $snap = Get-TreeSnapshot $repo
    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    $r.Text | Should Match 'không có gì mới để commit'
    (git -C $repo rev-parse HEAD) | Should Be $head
    Get-TreeSnapshot $repo | Should BeExactly $snap
  }

  It 'DryRun in 3 nhóm và không ghi gì' {
    $v10Crew = New-CrewCopy (Join-Path $h.Home 'crewline-v10') $v10Dir
    $r = Invoke-InTestHome -TestHome $h -File $v10Crew -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    Remove-Item -Force "$repo/context/.skeleton-hashes.json"
    Add-Content "$repo/context/roles/planner.md" '- sửa tay'
    git -C $repo add -A
    git -C $repo commit -q -m v10
    $head = git -C $repo rev-parse HEAD
    $snap = Get-TreeSnapshot $repo
    $r = & $run $crewScript @('-DryRun')
    $r.ExitCode | Should Be 0
    $r.Text | Should Match ([regex]::Escape("== crew upgrade -DryRun: context v10 -> v$newVersion"))
    $r.Text | Should Match 'Sẽ cập nhật \(\d+\): .*context/roles/worker\.md'
    $r.Text | Should Match ([regex]::Escape('Giữ bản của bạn, bản mới sẽ ở .new (1): context/roles/planner.md -> context/roles/planner.md.new'))
    $r.Text | Should Match ([regex]::Escape("git diff --no-index -- 'context/roles/planner.md' 'context/roles/planner.md.new'"))
    $r.Text | Should Match ([regex]::Escape('.new sẽ có sau khi chạy thật'))
    $r.Text | Should Match 'Giữ nguyên \(\d+\): .*context/README\.md'
    (git -C $repo rev-parse HEAD) | Should Be $head
    Get-TreeSnapshot $repo | Should BeExactly $snap
  }

  It 'không có gì thay đổi: một dòng "context đã ở v<mới>"' {
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    $head = git -C $repo rev-parse HEAD
    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    $r.Text | Should Match ([regex]::Escape("context đã ở v$newVersion, không có gì để cập nhật."))
    $r.Text | Should Not Match 'Đã cập nhật|Giữ bản của bạn'
    (git -C $repo rev-parse HEAD) | Should Be $head
  }

  It 'project init bằng bản mới (có dấu), không sửa ⇒ bản sau thay bình thường; sửa tay ⇒ .new' {
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    $hashes = Get-Content "$repo/context/.skeleton-hashes.json" -Raw | ConvertFrom-Json
    foreach ($k in 'README.md', 'roles/planner.md', 'roles/rev.md', 'roles/worker.md', 'CLAUDE.md#crew', 'AGENTS.md#crew') {
      @($hashes.PSObject.Properties.Name) -ccontains $k | Should Be $true
    }
    @(git -C $repo ls-files 'context/.skeleton-hashes.json').Count | Should Be 1
    $ignore = @(Get-Content "$repo/.gitignore" | ForEach-Object { $_.Trim() })
    foreach ($l in 'context/**/*.new', '/CLAUDE.md.new', '/AGENTS.md.new') { $ignore -ccontains $l | Should Be $true }
    $ignore -ccontains '*.new' | Should Be $false
    Add-Content "$repo/context/roles/rev.md" '- luật riêng của Rev'
    git -C $repo commit -qam 'sửa rev'
    # bản phát hành kế tiếp giả: đổi README + roles, VERSION+1
    $next = Join-Path $h.Home 'skeleton-next'
    Copy-Item $skeletonDir $next -Recurse
    foreach ($f in 'README.md', 'roles/planner.md', 'roles/rev.md', 'roles/worker.md') { Add-Content "$next/context/$f" '- dòng mới của bản sau' -Encoding utf8 }
    [IO.File]::WriteAllText("$next/VERSION", "$([int]$newVersion + 1)`n")
    $nextCrew = New-CrewCopy (Join-Path $h.Home 'crewline-next') $next
    $r = & $run $nextCrew
    $r.ExitCode | Should Be 0
    foreach ($f in 'README.md', 'roles/planner.md', 'roles/worker.md') {
      [IO.File]::ReadAllText("$repo/context/$f") | Should BeExactly ([IO.File]::ReadAllText("$next/context/$f"))
      Test-Path "$repo/context/$f.new" | Should Be $false
    }
    [IO.File]::ReadAllText("$repo/context/roles/rev.md") | Should Match 'luật riêng của Rev'
    [IO.File]::ReadAllText("$repo/context/roles/rev.md.new") | Should BeExactly ([IO.File]::ReadAllText("$next/context/roles/rev.md"))
    $hashes = Get-Content "$repo/context/.skeleton-hashes.json" -Raw | ConvertFrom-Json
    $hashes.'roles/worker.md' | Should Be (Get-LfHash ([IO.File]::ReadAllText("$next/context/roles/worker.md")))
    $hashes.'roles/rev.md' | Should Be (Get-LfHash ([IO.File]::ReadAllText("$skeletonDir/context/roles/rev.md")))
    @(git -C $repo status --porcelain --untracked-files=all).Count | Should Be 0
  }

  It '.gitignore chỉ che .new do upgrade sinh; file .new của project vẫn hiện; đã có *.new thì giữ nguyên' {
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    New-Item -ItemType Directory "$repo/src" | Out-Null
    Set-Content "$repo/src/data.new" 'project file'
    Set-Content "$repo/README.new" 'project file'
    Set-Content "$repo/context/roles/rev.md.new" 'upgrade output'
    Set-Content "$repo/CLAUDE.md.new" 'upgrade output'
    Set-Content "$repo/AGENTS.md.new" 'upgrade output'
    $untracked = @(git -C $repo status --porcelain --untracked-files=all | ForEach-Object { $_.Substring(3) })
    $untracked -ccontains 'src/data.new' | Should Be $true
    $untracked -ccontains 'README.new' | Should Be $true
    @($untracked | Where-Object { $_ -in 'context/roles/rev.md.new', 'CLAUDE.md.new', 'AGENTS.md.new' }).Count | Should Be 0
    Remove-Item "$repo/src", "$repo/README.new" -Recurse -Force
    # project đã có *.new (bản dev cũ): không thêm dòng hẹp, không xóa *.new
    [IO.File]::WriteAllText("$repo/.gitignore", ".crew/`n*.bak-*`n*.new`n")
    git -C $repo commit -qam 'ignore *.new'
    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/.gitignore") | Should BeExactly ".crew/`n*.bak-*`n*.new`n"
  }

  It 'config legacy thiếu idKey: upgrade ghi idKey, giữ custom.a.b.c.d.e.f.value' {
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    $cfgFile = "$repo/.crew/config.json"
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $cfg.PSObject.Properties.Remove('idKey')
    $cfg | Add-Member NoteProperty custom ([pscustomobject]@{ a = @{ b = @{ c = @{ d = @{ e = @{ f = @{ value = 'sâu' } } } } } } })
    [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 100))
    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    $back = Get-Content $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json
    $back.idKey | Should Not BeNullOrEmpty
    $back.name | Should Be $cfg.name
    $back.custom.a.b.c.d.e.f.value | Should Be 'sâu'
  }

  It 'config schema cao hơn: upgrade dừng, không ghi gì' {
    $v10Crew = New-CrewCopy (Join-Path $h.Home 'crewline-v10') $v10Dir
    $r = Invoke-InTestHome -TestHome $h -File $v10Crew -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    Remove-Item -Force "$repo/context/.skeleton-hashes.json"
    git -C $repo add -A; git -C $repo commit -qm v10
    $cfgFile = "$repo/.crew/config.json"
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    $cfg | Add-Member NoteProperty schema 99 -Force
    [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 100))
    $head = git -C $repo rev-parse HEAD
    $snap = Get-TreeSnapshot $repo
    foreach ($extra in @(@(), @('-DryRun'))) {
      $r = & $run $crewScript $extra
      $r.ExitCode | Should Be 1
      $r.Text | Should Match 'bản crew mới hơn'
      (git -C $repo rev-parse HEAD) | Should Be $head
      Get-TreeSnapshot $repo | Should BeExactly $snap
    }
  }

  It 'không tạo/sửa/xóa *.local.md' {
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    if ($r.ExitCode -ne 0) { throw "$($r.Output)" }
    @(Get-ChildItem "$repo/context/roles" -Filter '*.local.md').Count | Should Be 0
    [IO.File]::WriteAllText("$repo/context/roles/worker.local.md", "riêng`r`n")
    git -C $repo add -A; git -C $repo commit -qm local
    $r = & $run $crewScript
    $r.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/context/roles/worker.local.md") | Should BeExactly "riêng`r`n"
    $r = Invoke-InTestHome -TestHome $h -File $crewScript -Env $testEnv -Arguments @('init', '-Path', $repo)
    $r.ExitCode | Should Be 0
    [IO.File]::ReadAllText("$repo/context/roles/worker.local.md") | Should BeExactly "riêng`r`n"
  }

  It 'skeleton/released-hashes.json có hash của bản v10 và bản hiện tại (sửa skeleton/khối crew ⇒ thêm hash)' {
    $released = Get-Content (Join-Path $skeletonDir 'released-hashes.json') -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($f in 'README.md', 'roles/planner.md', 'roles/rev.md', 'roles/worker.md') {
      @($released.$f) -ccontains (Get-LfHash ([IO.File]::ReadAllText("$v10Dir/context/$f"))) | Should Be $true
      @($released.$f) -ccontains (Get-LfHash ([IO.File]::ReadAllText("$skeletonDir/context/$f"))) | Should Be $true
    }
    . (Join-Path $repoRoot 'scripts/crew/core.ps1')
    $block = Get-CrewBlock
    $inner = $block.Substring($block.IndexOf('<!-- crew -->') + 13, $block.IndexOf('<!-- /crew -->') - $block.IndexOf('<!-- crew -->') - 13)
    foreach ($k in 'CLAUDE.md#crew', 'AGENTS.md#crew') { @($released.$k) -ccontains (Get-LfHash $inner) | Should Be $true }
  }
}
