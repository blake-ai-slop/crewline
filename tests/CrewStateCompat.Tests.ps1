. (Join-Path $PSScriptRoot 'CrewAst.ps1')
foreach ($name in 'Get-CrewStateSchema','Read-CrewState','Get-Config','Get-Tasks','Save-Tasks','Get-SessionsFile','New-SessionBook','Read-SessionBook','Save-SessionBook','Get-QueueFile','Get-QueueItems','Save-QueueItems') {
  . ([scriptblock]::Create((Get-CrewFunction $name).Extent.Text))
}
function Die($message) { throw $message }
function Say($message) { throw "unexpected write failure: $message" }

Describe 'crew state v10 compatibility' {
  BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
    Copy-Item "$PSScriptRoot/fixtures/crew-state-v10/*.json" (Join-Path $root '.crew')
  }
  It 'đọc fixture sinh từ init và writers thật bản v10, schema thiếu là 1' {
    Get-CrewStateSchema | Should Be 1
    (Get-Config $root).name | Should Be 'compat'
    (Get-Tasks $root)[0].name | Should Be 'sample'
    (Get-QueueItems $root)[0].name | Should Be 'waiting'
    (Read-SessionBook $root).Roles.planner.sessionId | Should Be '11111111-2222-4333-8444-555555555555'
  }
  It 'ghi tasks/queue giữ mảng và trường lạ sâu hơn 5 cấp' {
    foreach ($pair in @(@('tasks','Get-Tasks','Save-Tasks'), @('queue','Get-QueueItems','Save-QueueItems'))) {
      $items = & $pair[1] $root
      $items[0] | Add-Member NoteProperty unknown @{a=@{b=@{c=@{d=@{e=@{value=42}}}}}}
      & $pair[2] $root $items
      $back = & $pair[1] $root
      $back[0].unknown.a.b.c.d.e.value | Should Be 42
      ([IO.File]::ReadAllText((Join-Path $root ".crew/$($pair[0]).json"))).TrimStart().StartsWith('[') | Should Be $true
    }
  }
  It 'ghi sessions giữ trường lạ ở gốc và từng vai kể cả record được thay' {
    $file = Get-SessionsFile $root
    $j = Get-Content $file -Raw | ConvertFrom-Json
    $j | Add-Member NoteProperty custom @{value='keep'; a=@{b=@{c=@{d=@{e=@{value=42}}}}}}
    $j.roles.planner | Add-Member NoteProperty custom @{nested=@{value=7}; a=@{b=@{c=@{d=@{e=@{value=42}}}}}}
    $j | ConvertTo-Json -Depth 100 | Set-Content $file
    $book = Read-SessionBook $root
    $book.Roles.planner = @{agent='codex'; root='fixture-project'}
    Save-SessionBook $root $book
    $back = Get-Content $file -Raw | ConvertFrom-Json
    $back.custom.value | Should Be 'keep'
    $back.custom.a.b.c.d.e.value | Should Be 42
    $back.roles.planner.custom.nested.value | Should Be 7
    $back.roles.planner.custom.a.b.c.d.e.value | Should Be 42
    $back.roles.planner.agent | Should Be 'codex'
    $back.schema | Should Be 1
  }
  It 'Update-ConfigName và Save-ProjectRegistry giữ trường lạ sâu kể cả đăng ký lại' {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'scripts/crew/name.ps1')
    . (Join-Path $repo 'scripts/crew/herdr.ps1')
    . ([scriptblock]::Create((Get-CrewFunction 'Update-ConfigName').Extent.Text))
    function Say($message) { }
    $registryFile = Join-Path $TestDrive 'projects-deep.json'
    function Get-ProjectsFile { $registryFile }
    $file = Join-Path $root '.crew/config.json'
    $cfg = Get-Content $file -Raw | ConvertFrom-Json
    $cfg.PSObject.Properties.Remove('idKey')
    $deep = @{a=@{b=@{c=@{d=@{e=@{value=42}}}}}}
    $cfg | Add-Member NoteProperty unknown $deep
    $cfg | ConvertTo-Json -Depth 100 | Set-Content $file
    @{compat=@{root=$root; idKey='compat'; unknown=$deep}} | ConvertTo-Json -Depth 100 | Set-Content $registryFile
    Update-ConfigName $root $false
    $back = Get-Content $file -Raw | ConvertFrom-Json
    $back.idKey | Should Be 'compat'
    $back.unknown.a.b.c.d.e.value | Should Be 42
    $reg = Read-ProjectRegistry
    $reg.Map.compat.unknown.a.b.c.d.e.value | Should Be 42
    Save-ProjectRegistry $reg.Map
    $saved = Get-Content $registryFile -Raw | ConvertFrom-Json
    $saved.compat.unknown.a.b.c.d.e.value | Should Be 42
  }
  It 'schema mới hơn bị chặn, không sửa byte file' {
    foreach ($name in 'config','tasks','sessions','queue') {
      $file = Join-Path $root ".crew/$name.json"
      [IO.File]::WriteAllText($file, '{"schema":99,"roles":{}}')
      $before = (Get-FileHash $file).Hash
      { Read-CrewState $file } | Should Throw 'dữ liệu do bản crew mới hơn ghi — cập nhật crew'
      if ($name -eq 'tasks') { { Save-Tasks $root @() } | Should Throw 'crew mới hơn' }
      if ($name -eq 'queue') { { Save-QueueItems $root @() } | Should Throw 'crew mới hơn' }
      if ($name -eq 'sessions') { { Save-SessionBook $root (New-SessionBook) } | Should Throw 'crew mới hơn' }
      (Get-FileHash $file).Hash | Should Be $before
    }
  }
  It 'tasks/queue trắng, xuống dòng hoặc BOM -> mảng rỗng, đúng một cảnh báo, không ghi file' {
    foreach ($pair in @(@('tasks','Get-Tasks','task'), @('queue','Get-QueueItems','mục hàng đợi'))) {
      $file = Join-Path $root ".crew/$($pair[0]).json"
      foreach ($blank in '', " `t`r`n", ([string][char]0xFEFF), "$([char]0xFEFF) `r`n") {
        [IO.File]::WriteAllText($file, $blank)
        $before = (Get-FileHash $file).Hash
        $output = @(. { $items = & $pair[1] $root } 6>&1)
        ($items -is [array]) | Should Be $true
        $items.Count | Should Be 0
        $output.Count | Should Be 1
        "$($output[0])" | Should Be "crew: CẢNH BÁO: $file trống — coi như không có $($pair[2])."
        (Get-FileHash $file).Hash | Should Be $before
      }
    }
  }
  It 'config/sessions trống vẫn bị chặn và giữ nguyên byte' {
    foreach ($pair in @(@('config','Get-Config'), @('sessions','Read-SessionBook'))) {
      $file = Join-Path $root ".crew/$($pair[0]).json"
      foreach ($blank in '', " `t`r`n", ([string][char]0xFEFF)) {
        [IO.File]::WriteAllText($file, $blank)
        $before = (Get-FileHash $file).Hash
        { & $pair[1] $root } | Should Throw "$($pair[0]).json hỏng"
        (Get-FileHash $file).Hash | Should Be $before
      }
    }
  }
  It 'JSON hỏng bị chặn ở cả readers và writers, giữ nguyên byte' {
    foreach ($pair in @(@('config','Get-Config'), @('tasks','Get-Tasks'), @('sessions','Read-SessionBook'), @('queue','Get-QueueItems'))) {
      $file = Join-Path $root ".crew/$($pair[0]).json"
      foreach ($bad in '{broken', 'null', '42') {
        [IO.File]::WriteAllText($file, $bad)
        $before = (Get-FileHash $file).Hash
        { & $pair[1] $root } | Should Throw "$($pair[0]).json hỏng"
        if ($pair[0] -eq 'tasks') { { Save-Tasks $root @() } | Should Throw 'hỏng' }
        if ($pair[0] -eq 'queue') { { Save-QueueItems $root @() } | Should Throw 'hỏng' }
        if ($pair[0] -eq 'sessions') { { Save-SessionBook $root (New-SessionBook) } | Should Throw 'hỏng' }
        (Get-FileHash $file).Hash | Should Be $before
      }
    }
  }
}
