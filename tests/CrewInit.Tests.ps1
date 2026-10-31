. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$CrewScript = Join-Path $RepoRoot 'scripts/crew.ps1'

function New-InitEnv([hashtable]$Extra = @{}) {
  $e = @{}
  # pwsh dat $PSHOME dau PATH cho tien trinh con; pwsh ban Store goi thang tu do bi Access denied khi ho so nguoi dung la gia.
  # Bo $PSHOME de PS 5.1 tim pwsh qua alias nhu may that.
  $e.Path = (($env:Path -split ';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\') }) -join ';'
  foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
  $e
}

Describe 'crew init trong thư mục chưa có git' {
  $savedEncoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try {
    BeforeEach {
      $h = New-CrewTestHome
      # Git identity qua gitconfig cua HOME gia (GIT_CONFIG_GLOBAL tro vao day); khong dat bien GIT_* vi helper khoi phuc thanh chuoi rong.
      Set-Content (Join-Path $h.Home 'gitconfig') "[user]`n`tname = test`n`temail = test@example.invalid`n[core]`n`tautocrlf = false"
      $dir = Join-Path $h.Home 'agentslimitview'
      New-Item -ItemType Directory $dir | Out-Null
      Set-Content (Join-Path $dir 'note.txt') 'du lieu cu'
    }

    It 'PS 5.1 gọi thẳng crew.ps1: không NativeCommandError, báo lỗi crew gợi ý -GitInit' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Shell powershell -Arguments @('init', '-Path', $dir, '-NoCommit') -Env (New-InitEnv)
      $r.ExitCode | Should Be 1
      $r.Output | Should Not Match 'NativeCommandError'
      $r.Output | Should Match 'crew: LỖI: .*không phải repo git.*-GitInit'
      Test-Path (Join-Path $dir '.git') | Should Be $false
    }

    It 'CREWLINE_DEFAULTS=1: không hỏi, lỗi gợi ý -GitInit' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $dir) -Env (New-InitEnv) -InputText "1`n"
      $r.ExitCode | Should Be 1
      $r.Output | Should Not Match 'Lựa chọn'
      $r.Output | Should Match '-GitInit'
      Test-Path (Join-Path $dir '.git') | Should Be $false
    }

    It 'stdin hết (EOF): giữ hành vi cũ, lỗi gợi ý -GitInit' {
      # '' | pwsh gui mot dong trong; $null | pwsh moi dong stdin ngay (EOF).
      $wrap = Join-Path $h.Home 'eof.ps1'
      Set-Content $wrap "`$null | & (Get-Process -Id `$PID).Path -NoProfile -NonInteractive -File '$CrewScript' init -Path '$dir'; exit `$LASTEXITCODE"
      $r = Invoke-InTestHome -TestHome $h -File $wrap -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' })
      $r.ExitCode | Should Be 1
      $r.Output | Should Match '-GitInit'
      Test-Path (Join-Path $dir '.git') | Should Be $false
    }

    It 'stdin 1: hỏi như crew setup rồi git init + commit đầu + context/' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $dir) -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' }) -InputText "1`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'chưa là repo git\.\s+1\. Tạo repo git mới ở đây \(git init \+ commit đầu\)\s+2\. Thôi\s+Lựa chọn \[1\]: '
      Test-Path (Join-Path $dir '.git') | Should Be $true
      Test-Path (Join-Path $dir 'context/README.md') | Should Be $true
      $log = @(git -C $dir log --format=%s)
      $log[-1] | Should Be 'chore: initial commit'
      $log[0] | Should Be 'chore: crew context skeleton'
      git -C $dir ls-files note.txt | Should Be 'note.txt'
      $gi = @(Get-Content (Join-Path $dir '.gitignore') | ForEach-Object { $_.Trim() })
      $gi -ccontains '.crew/' | Should Be $true
      $gi -ccontains '*.bak-*' | Should Be $true
      foreach ($name in 'CLAUDE.md', 'AGENTS.md') {
        $block = Get-Content (Join-Path $dir $name) -Raw -Encoding utf8
        $block | Should Match '<!-- crew -->'
        $block | Should Match '<!-- /crew -->'
        $block | Should Match ([regex]::Escape('- Bản đồ code: context/MAP.md.'))
        $block | Should Match ([regex]::Escape('- Không push (chỉ planner push khi chủ dự án cho phép). Mặc định chế độ gọn: worker chạy test của phần mình, không tự review.'))
      }
      @(git -C $dir status --porcelain).Count | Should Be 0
    }

    It 'PS 5.1 + stdin 1: chuyển sang pwsh, vẫn hỏi và tạo repo' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Shell powershell -Arguments @('init', '-Path', $dir, '-NoCommit') -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' }) -InputText "1`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'NativeCommandError'
      Test-Path (Join-Path $dir '.git') | Should Be $true
      Test-Path (Join-Path $dir '.crew/config.json') | Should Be $true
    }

    It 'stdin 2: thôi, không tạo gì' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $dir) -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' }) -InputText "2`n"
      $r.ExitCode | Should Be 1
      $r.Output | Should Match 'thôi, không tạo gì'
      @(Get-ChildItem -Force $dir | ForEach-Object { $_.Name }) -join ',' | Should Be 'note.txt'
    }

    It '-GitInit: không hỏi, tạo repo' {
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $dir, '-GitInit') -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' }) -InputText "2`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'Lựa chọn'
      Test-Path (Join-Path $dir 'context/README.md') | Should Be $true
      (@(git -C $dir log --format=%s))[-1] | Should Be 'chore: initial commit'
    }

    It 'repo chưa có commit + stdin 1: tạo commit đầu' {
      git -C $dir init -q -b main
      $r = Invoke-InTestHome -TestHome $h -File $CrewScript -Arguments @('init', '-Path', $dir, '-NoCommit') -Env (New-InitEnv @{ CREWLINE_DEFAULTS = '' }) -InputText "1`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'chưa có commit nào\.\s+1\. Tạo commit đầu với các file đang có\s+2\. Thôi'
      (@(git -C $dir log --format=%s))[-1] | Should Be 'chore: initial commit'
    }
  } finally {
    [Console]::OutputEncoding = $savedEncoding
  }
}
