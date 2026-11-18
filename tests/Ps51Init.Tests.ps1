. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows

# Real install -> generated shim -> Windows PowerShell 5.1 -> pwsh -> init.
# No fake crew script, no hc calls, and all profile writes stay in TestDrive.
# Windows PowerShell 5.1 only exists on Windows: the whole file is skipped on Linux/macOS.
if ($OnWindows) {
Describe 'installed shim initializes a project from Windows PowerShell 5.1' {
  $savedEncoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  try {
    BeforeEach {
      $h = New-CrewTestHome
      Set-Content (Join-Path $h.Home 'gitconfig') "[user]`n`tname = test`n`temail = test@example.invalid`n[core]`n`tautocrlf = false"
      $dir = Join-Path $h.Home 'new project'
      New-Item -ItemType Directory $dir | Out-Null
      Set-Content (Join-Path $dir 'note.txt') 'existing content'
      $r = Invoke-InTestHome -TestHome $h -File (Join-Path $RepoRoot 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_NO_JQ = '1' }
      $r.ExitCode | Should Be 0 | Out-Null
      $shim = Join-Path $h.Home '.local/bin/crew.ps1'
      # Let PS 5.1 resolve the Store alias instead of the package-private exe.
      $ps51Path = (($env:Path -split ';') | Where-Object { $_ -and ($PSHOME -notmatch '\\WindowsApps\\' -or $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\')) }) -join ';'
    }

    It 'stdin 1 creates Git and context through the installed real shim' {
      $r = Invoke-InTestHome -TestHome $h -File $shim -Shell powershell -Arguments 'init' -WorkingDirectory $dir -Env @{ Path = $ps51Path; CREWLINE_DEFAULTS = '' } -InputText "1`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'NativeCommandError'
      $r.Output | Should Match 'Lựa chọn \[1\]'
      Test-Path (Join-Path $dir '.git') | Should Be $true
      Test-Path (Join-Path $dir 'context/README.md') | Should Be $true
      $cfg = Get-Content (Join-Path $dir '.crew/config.json') -Raw | ConvertFrom-Json
      $cfg.planner | Should Be 'claude'
      ($cfg.workers -join ',') | Should Be 'claude,codex'
      $cfg.rev | Should Be 'codex'
      $log = @(git -C $dir log --format=%s)
      $log.Count | Should Be 2
      $log[-1] | Should Be 'chore: initial commit'
      $log[0] | Should Be 'chore: crew context skeleton'
      git -C $dir ls-files note.txt | Should Be 'note.txt'
      (Get-Content (Join-Path $dir 'note.txt') -Raw).Trim() | Should Be 'existing content'
    }

    It 'DEFAULTS refuses creation with a GitInit hint and no NativeCommandError' {
      $r = Invoke-InTestHome -TestHome $h -File $shim -Shell powershell -Arguments 'init' -WorkingDirectory $dir -Env @{ Path = $ps51Path; CREWLINE_DEFAULTS = '1' } -InputText "1`n"
      $r.ExitCode | Should Be 1
      $r.Output | Should Not Match 'NativeCommandError'
      $r.Output | Should Not Match 'Lựa chọn'
      $r.Output | Should Match '-GitInit'
      @(Get-ChildItem -Force $dir | ForEach-Object { $_.Name }) -join ',' | Should Be 'note.txt'
    }

    It 'real install in a Vietnamese path produces a shim usable from PS 5.1' {
      $unicodeRepo = Join-Path $h.Home 'đội'
      New-Item -ItemType Directory $unicodeRepo | Out-Null
      Copy-Item (Join-Path $RepoRoot 'install.ps1') $unicodeRepo
      foreach ($folder in 'scripts', 'templates', 'skeleton') { Copy-Item (Join-Path $RepoRoot $folder) $unicodeRepo -Recurse }
      $r = Invoke-InTestHome -TestHome $h -File (Join-Path $unicodeRepo 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_NO_JQ = '1' }
      $r.ExitCode | Should Be 0
      $r = Invoke-InTestHome -TestHome $h -File $shim -Shell powershell -Arguments 'init' -WorkingDirectory $dir -Env @{ Path = $ps51Path; CREWLINE_DEFAULTS = '' } -InputText "1`n"
      $r.ExitCode | Should Be 0
      $r.Output | Should Not Match 'ParserError|NativeCommandError'
      Test-Path (Join-Path $dir 'context/README.md') | Should Be $true
    }
  } finally {
    [Console]::OutputEncoding = $savedEncoding
  }
}
Describe 'installed shim passes arguments from Windows PowerShell 5.1 to pwsh' {
  BeforeAll {
    $h = New-CrewTestHome
    # Repo giả: install.ps1 thật + scripts/crew.ps1 giả ghi đối số nhận được (JSON UTF-8) vào CREW_ARGS_OUT.
    $fakeRepo = Join-Path $h.Home 'repo'
    New-Item -ItemType Directory $fakeRepo | Out-Null
    Copy-Item (Join-Path $RepoRoot 'install.ps1') $fakeRepo
    foreach ($folder in 'scripts', 'templates', 'skeleton') { Copy-Item (Join-Path $RepoRoot $folder) $fakeRepo -Recurse }
    $fakeCrew = @'
$list = @($args | ForEach-Object { [pscustomobject]@{ Value = "$_"; Type = $_.GetType().Name } })
[IO.File]::WriteAllText($env:CREW_ARGS_OUT, (ConvertTo-Json -InputObject $list -Compress), [Text.UTF8Encoding]::new($false))
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $fakeRepo 'scripts/crew.ps1'), $fakeCrew, [Text.UTF8Encoding]::new($true))
    $r = Invoke-InTestHome -TestHome $h -File (Join-Path $fakeRepo 'install.ps1') -Arguments '-NoDoctor' -Env @{ CREWLINE_NO_JQ = '1' }
    $r.ExitCode | Should Be 0
    $shim = Join-Path $h.Home '.local/bin/crew.ps1'
    $ps51Path = (($env:Path -split ';') | Where-Object { $_ -and ($PSHOME -notmatch '\\WindowsApps\\' -or $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\')) }) -join ';'
    $outFile = Join-Path $h.Home 'args.json'
    # Lệnh gõ trong PS 5.1 thật: driver chạy bằng powershell.exe gọi shim qua &, nên a,b,c là mảng như khi gõ tay.
    function Invoke-ShimFrom51([string]$CommandLine) {
      if (Test-Path $outFile) { Remove-Item $outFile }
      $driver = Join-Path $h.Home 'driver.ps1'
      $text = "if (`$PSVersionTable.PSVersion.Major -ge 7) { 'driver không chạy trong 5.1'; exit 9 }`n& '$($shim.Replace("'", "''"))' $CommandLine`nexit `$LASTEXITCODE`n"
      [IO.File]::WriteAllText($driver, $text, [Text.UTF8Encoding]::new($true))
      $r = Invoke-InTestHome -TestHome $h -File $driver -Shell powershell -Env @{ Path = $ps51Path; CREW_ARGS_OUT = $outFile }
      $r.ExitCode | Should Be 0 | Out-Null
      $r.Output | Should Not Match 'positional parameter|NativeCommandError' | Out-Null
      Test-Path $outFile | Should Be $true | Out-Null
      @([IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) | ConvertFrom-Json | ForEach-Object { $_ })
    }
  }

  It '1 tên' {
    $got = Invoke-ShimFrom51 'review a -DryRun'
    ($got | ForEach-Object Value) -join '|' | Should Be 'review|a|-DryRun'
  }

  It '2 tên không ngoặc -> một đối số a,b' {
    $got = Invoke-ShimFrom51 'review a,b -DryRun'
    ($got | ForEach-Object Value) -join '|' | Should Be 'review|a,b|-DryRun'
  }

  It '3 tên không ngoặc -> một đối số a,b,c (lỗi L1)' {
    $got = Invoke-ShimFrom51 'review a,b,c -DryRun'
    ($got | ForEach-Object Value) -join '|' | Should Be 'review|a,b,c|-DryRun'
    $got.Count | Should Be 3
  }

  It 'chuỗi có dấu cách và chữ Việt giữ nguyên một đối số' {
    $got = Invoke-ShimFrom51 "send w1 'sửa lỗi ở đội một' x,y,z"
    $got.Count | Should Be 4
    $got[0].Value | Should Be 'send'
    $got[1].Value | Should Be 'w1'
    $got[2].Value | Should Be 'sửa lỗi ở đội một'
    $got[3].Value | Should Be 'x,y,z'
  }
}
}
