. (Join-Path $PSScriptRoot 'CrewAst.ps1')
# Ghi state nguyên tử + khóa root (.crew/state.lock): trích hàm bằng AST, tiến trình pwsh con cho ca chạy song song. Không gọi hc.
$stateFns = 'Die', 'Get-CrewStateSchema', 'Read-CrewState', 'Get-Tasks', 'Save-Tasks', 'Update-Tasks', 'Get-QueueFile', 'Get-QueueItems',
  'Save-QueueItems', 'Update-QueueItems', 'Write-CrewStateFile', 'Use-CrewStateLock', 'Get-SessionsFile', 'New-SessionBook', 'Save-SessionBook'
foreach ($name in $stateFns) { . ([scriptblock]::Create((Get-CrewFunction $name).Extent.Text)) }
function Die($message) { throw $message }
function Say($message) { throw "không được cảnh báo: $message" }

function New-StateRoot {
  $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force (Join-Path $root '.crew') | Out-Null
  $root
}
function Get-TmpLeft([string]$root) { @(Get-ChildItem -LiteralPath (Join-Path $root '.crew') -Force -Filter '*.tmp') }
function Lock-State([string]$root) {
  [IO.File]::Open((Join-Path $root '.crew/state.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

Describe 'Write-CrewStateFile: ghi lỗi giữa chừng không hỏng file cũ' {
  Context 'Set-Content lỗi (Mock chỉ trong Context này)' {
  It 'ghi file tạm lỗi giữa chừng ⇒ tasks.json/queue.json còn nguyên byte, không sót file tạm' {
    $root = New-StateRoot
    Save-Tasks $root @([pscustomobject]@{ name = 'cu'; worker = 1 })
    Save-QueueItems $root @([pscustomobject]@{ name = 'q'; worker = 0 })
    $tasksFile = Join-Path $root '.crew/tasks.json'; $queueFile = Get-QueueFile $root
    $tb = [IO.File]::ReadAllBytes($tasksFile); $qb = [IO.File]::ReadAllBytes($queueFile)
    Mock Set-Content { [IO.File]::WriteAllText($LiteralPath, '[{"na'); throw 'đĩa đầy' }
    { Save-Tasks $root @([pscustomobject]@{ name = 'moi'; worker = 2 }) } | Should Throw 'đĩa đầy'
    { Save-QueueItems $root @() } | Should Throw 'đĩa đầy'
    { Update-Tasks $root { param($t) @($t) + [pscustomobject]@{ name = 'x'; worker = 3 } } } | Should Throw 'đĩa đầy'
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes($tasksFile))) | Should Be ([Convert]::ToBase64String($tb))
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes($queueFile))) | Should Be ([Convert]::ToBase64String($qb))
    (Get-TmpLeft $root).Count | Should Be 0
    # khóa đã nhả dù body ném lỗi
    $h = Lock-State $root; $h.Dispose()
  }
  }

  # Unix cho đổi tên đè file đang mở nên chỉ dựng được ca này trên Windows.
  It 'không đè được file đích (đang mở, không chia sẻ xóa) ⇒ thử lại rồi lỗi rõ, file cũ nguyên byte, không sót file tạm' -Skip:(-not $IsWindows) {
    $root = New-StateRoot
    Save-Tasks $root @([pscustomobject]@{ name = 'cu'; worker = 1 })
    $file = Join-Path $root '.crew/tasks.json'
    $before = [IO.File]::ReadAllBytes($file)
    $hold = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { { Save-Tasks $root @() } | Should Throw 'file cũ giữ nguyên' }
    finally { $hold.Dispose() }
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file))) | Should Be ([Convert]::ToBase64String($before))
    (Get-TmpLeft $root).Count | Should Be 0
  }

  It 'giữ định dạng: tasks/queue UTF-8 không BOM + xuống dòng như Set-Content cũ; sessions không xuống dòng cuối' {
    $root = New-StateRoot
    $items = @([pscustomobject]@{ name = 'á'; worker = 1 })
    Save-Tasks $root $items
    $old = Join-Path $root 'old.json'
    ConvertTo-Json -InputObject $items -Depth 100 | Set-Content $old -Encoding utf8
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root '.crew/tasks.json')))) | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($old)))
    $book = New-SessionBook; $book.Roles['w1'] = @{ agent = 'claude'; root = $root }
    Save-SessionBook $root $book
    $bytes = [IO.File]::ReadAllBytes((Get-SessionsFile $root))
    $bytes[0] | Should Be ([byte][char]'{')
    $bytes[-1] | Should Be ([byte][char]'}')
    (Get-TmpLeft $root).Count | Should Be 0
  }
}

Describe 'Use-CrewStateLock: khóa theo root' {
  It 'khóa bị giữ quá hạn ⇒ lỗi rõ, không ghi tasks/queue' {
    $root = New-StateRoot
    Save-Tasks $root @([pscustomobject]@{ name = 'cu'; worker = 1 })
    Save-QueueItems $root @([pscustomobject]@{ name = 'q'; worker = 0 })
    $tb = [IO.File]::ReadAllBytes((Join-Path $root '.crew/tasks.json')); $qb = [IO.File]::ReadAllBytes((Get-QueueFile $root))
    $h = Lock-State $root
    try {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      { Update-Tasks $root { param($t) @() } -TimeoutMs 400 } | Should Throw 'đang bị lệnh crew khác giữ'
      $sw.ElapsedMilliseconds | Should BeGreaterThan 350
      { Update-QueueItems $root { param($q) @() } -TimeoutMs 300 } | Should Throw 'chưa ghi gì'
      { Use-CrewStateLock $root { $script:ranUnderLock = $true } 200 } | Should Throw 'state.lock'
      $script:ranUnderLock | Should Not Be $true
    } finally { $h.Dispose() }
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root '.crew/tasks.json')))) | Should Be ([Convert]::ToBase64String($tb))
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-QueueFile $root)))) | Should Be ([Convert]::ToBase64String($qb))
    # nhả khóa ⇒ ghi bình thường; lồng nhau trong cùng tiến trình (Update-Tasks gọi Save-Tasks) không tự chặn
    (Update-Tasks $root { param($t) @($t) + [pscustomobject]@{ name = 'moi'; worker = 2 } }).Count | Should Be 2
    (Get-Tasks $root).Count | Should Be 2
  }

  It 'change ném lỗi ⇒ không ghi, khóa được nhả' {
    $root = New-StateRoot
    Save-Tasks $root @([pscustomobject]@{ name = 'cu'; worker = 1; extra = @{ a = @{ b = 1 } } })
    $before = [IO.File]::ReadAllBytes((Join-Path $root '.crew/tasks.json'))
    { Update-Tasks $root { param($t) throw 'thôi' } } | Should Throw 'thôi'
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root '.crew/tasks.json')))) | Should Be ([Convert]::ToBase64String($before))
    $h = Lock-State $root; $h.Dispose()
  }

  It 'tasks.json hỏng ⇒ Update-Tasks dừng, không ghi đè, khóa được nhả' {
    $root = New-StateRoot
    $file = Join-Path $root '.crew/tasks.json'
    [IO.File]::WriteAllText($file, '{hỏng')
    $before = [IO.File]::ReadAllBytes($file)
    { Update-Tasks $root { param($t) @() } } | Should Throw 'hỏng'
    ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file))) | Should Be ([Convert]::ToBase64String($before))
    $h = Lock-State $root; $h.Dispose()
  }
}

Describe 'hai tiến trình pwsh ghi song song' {
  It 'cùng thêm task/mục hàng đợi nhiều lần vào một root ⇒ không mất bản ghi' {
    $root = New-StateRoot
    Save-Tasks $root @()
    Save-QueueItems $root @()
    $defs = $stateFns | ForEach-Object { (Get-CrewFunction $_).Extent.Text }
    $body = ($defs -join "`n") + @'

function Die($message) { Write-Host "DIE: $message"; exit 3 }
$ErrorActionPreference = 'Stop'
$root = $args[0]; $who = $args[1]
for ($i = 0; $i -lt 25; $i++) {
  $null = Update-Tasks $root { param($t) @($t) + [pscustomobject]@{ name = "$who-$i"; worker = $i } }
  $null = Update-QueueItems $root { param($q) @($q) + [pscustomobject]@{ name = "$who-$i"; worker = 0 } }
}
Write-Host "DONE $who"
'@
    $script = Join-Path $TestDrive 'state-writer.ps1'
    [IO.File]::WriteAllText($script, $body, [Text.UTF8Encoding]::new($true))
    $exe = (Get-Process -Id $PID).Path
    $procs = foreach ($who in 'a', 'b') {
      Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script, $root, $who) -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $TestDrive "out-$who.txt") -RedirectStandardError (Join-Path $TestDrive "err-$who.txt")
    }
    foreach ($p in $procs) { $p.WaitForExit(120000) | Should Be $true }
    foreach ($who in 'a', 'b') {
      $out = (Get-Content -Raw (Join-Path $TestDrive "out-$who.txt")) + (Get-Content -Raw (Join-Path $TestDrive "err-$who.txt"))
      $out | Should Match "DONE $who"
    }
    $want = @(foreach ($who in 'a', 'b') { foreach ($i in 0..24) { "$who-$i" } }) | Sort-Object
    (@(Get-Tasks $root | ForEach-Object { $_.name } | Sort-Object) -join ',') | Should Be ($want -join ',')
    (@(Get-QueueItems $root | ForEach-Object { $_.name } | Sort-Object) -join ',') | Should Be ($want -join ',')
    (Get-TmpLeft $root).Count | Should Be 0
  }
}
