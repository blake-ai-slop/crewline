. "$PSScriptRoot/CrewAst.ps1"
. "$PSScriptRoot/TestHome.ps1"
$uxCrew = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
Describe 'crew messages users can act on' {
  BeforeEach {
    $h = New-CrewTestHome
    $repo = Join-Path $h.Home 'project'
    New-Item -ItemType Directory -Force (Join-Path $repo '.crew') | Out-Null
    git -C $repo init -q -b main
    git -C $repo -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    '{"name":"demo","planner":"claude","workers":["codex","claude"],"rev":"codex"}' | Set-Content (Join-Path $repo '.crew/config.json')
  }
  It 'unknown commands fail, a unique close command is suggested, help succeeds' {
    foreach ($command in 'lamgi','hott','hpt') {
      $r = Invoke-InTestHome -TestHome $h -File $uxCrew -WorkingDirectory $repo -Arguments @($command)
      $r.ExitCode | Should Be 1
      $r.Output | Should Match ([regex]::Escape("không có lệnh '$command'"))
      $r.Output | Should Match 'xem danh sách: crew help'
      if ($command -ne 'lamgi') { $r.Output | Should Match 'ý bạn là: crew hot\?' }
    }
    foreach ($arguments in @(@()), @('help')) {
      $r = Invoke-InTestHome -TestHome $h -File $uxCrew -WorkingDirectory $repo -Arguments $arguments
      $r.ExitCode | Should Be 0
    }
  }
  It 'task and queue check the project before a missing prompt, including uninitialized git repos' {
    foreach ($where in $h.Home, $repo) {
      Remove-Item -LiteralPath (Join-Path $repo '.crew/config.json') -ErrorAction SilentlyContinue
      foreach ($command in 'task','queue') {
        $r = Invoke-InTestHome -TestHome $h -File $uxCrew -WorkingDirectory $where -Arguments @($command,'abc','missing.md')
        $r.ExitCode | Should Be 1
        $r.Output | Should Match 'không ở trong project crew'
        $r.Output | Should Not Match 'không thấy file prompt'
        $r.Output | Should Match '→ Làm tiếp:\r?\n    cd <project>\r?\n    crew init'
      }
    }
  }
  It 'missing terminals outside the configured roles list valid names, while a missing role suggests up' {
    $wrapper = Join-Path $h.Home 'send.ps1'
    $source = 'param($Target)' + "`nfunction hc { `$global:LASTEXITCODE=1 }`n& '" + $uxCrew.Replace("'", "''") + "' send `$Target 'hello'`nexit `$LASTEXITCODE"
    [IO.File]::WriteAllText($wrapper, $source, [Text.UTF8Encoding]::new($true))
    foreach ($target in 'demo-w9','other','demo-w1') {
      $r = Invoke-InTestHome -TestHome $h -File $wrapper -WorkingDirectory $repo -Arguments @($target)
      $r.ExitCode | Should Be 1
      if ($target -eq 'demo-w1') { $r.Output | Should Match '    crew up'; $r.Output | Should Not Match 'không có terminal' }
      else {
        $r.Output | Should Match ([regex]::Escape("không có terminal $target trong crew demo"))
        $r.Output | Should Match 'Tên terminal: demo-planner, demo-w1, demo-w2, demo-rev'
        $r.Output | Should Not Match 'crew up'
      }
    }
  }
  It 'Die accepts an array and newline strings and prints every step on its own line' {
    $file = Join-Path $h.Home 'die.ps1'
    [IO.File]::WriteAllText($file, (Get-CrewFunction 'Die').Extent.Text + "`nDie 'lỗi thử' @('crew hot', `"crew upgrade -DryRun``ncrew upgrade`")", [Text.UTF8Encoding]::new($true))
    $r = Invoke-InTestHome -TestHome $h -File $file
    $r.ExitCode | Should Be 1
    $r.Output | Should Be "crew: LỖI: lỗi thử`n  → Làm tiếp:`n    crew hot`n    crew upgrade -DryRun`n    crew upgrade"
  }
  It 'upgrade summary offers planner help and keeps DryRun instructions on separate lines' {
    . ([scriptblock]::Create((Get-CrewFunction 'Write-UpgradeSummary').Extent.Text))
    $output = Write-UpgradeSummary 12 13 @() @('context/roles/worker.md') @() @() $true $false '16' 6>&1 | Out-String
    $output | Should Match '== crew upgrade -DryRun \(Crewline v16\): khung context v12 -> v13'
    $output | Should Match 'hoặc nói với planner: gộp các file .new trong context/roles rồi xóa .new'
    $output | Should Match '\r?\n  crew upgrade\r?\n'
  }
  It 'upgrade distinguishes product v14, installed framework v12 and project framework v13' {
    $install = Join-Path $h.Home 'install'
    New-Item -ItemType Directory -Force (Join-Path $install 'skeleton') | Out-Null
    Copy-Item (Split-Path $uxCrew) (Join-Path $install 'scripts') -Recurse
    '14' | Set-Content (Join-Path $install 'VERSION')
    '12' | Set-Content (Join-Path $install 'skeleton/VERSION')
    New-Item -ItemType Directory (Join-Path $repo 'context') | Out-Null
    '13' | Set-Content (Join-Path $repo 'context/.skeleton-version')
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $install 'scripts/crew.ps1') -Arguments @('upgrade','-Path',$repo)
    $r.ExitCode | Should Be 1
    $r.Output | Should Match ([regex]::Escape('project này đã được cập nhật bằng Crewline mới hơn bản đang cài (v14, khung v12 < khung v13 của project)'))
    $r.Output | Should Match '→ Làm tiếp:\r?\n    [^\r\n]+\r?\n    crew upgrade'
  }
}
