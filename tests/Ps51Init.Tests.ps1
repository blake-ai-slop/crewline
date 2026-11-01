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
}
