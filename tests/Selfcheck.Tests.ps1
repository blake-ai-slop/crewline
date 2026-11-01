$SelfcheckScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
Describe 'crew selfcheck isolated user journey' {
  It 'passes install, PS 5.1 shim (Windows), init, upgrades and Vietnamese HOME without changing the caller' {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $before = @{}
    foreach ($key in 'USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'Path') { $before[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    $locationBefore = (Get-Location).Path
    $output = & pwsh -NoProfile -File $SelfcheckScript selfcheck 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ($output -join "`n") }
    $code | Should Be 0
    # Windows: 2 install + 2 help PS 5.1 + init + 3 upgrade; Linux/macOS không có PS 5.1 nên bỏ 2 bước help.
    $expected = if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { 8 } else { 6 }
    @($output | Where-Object { $_ -match '^PASS ' }).Count | Should Be $expected
    ($output -join "`n") | Should Not Match '^FAIL '
    foreach ($key in $before.Keys) { [Environment]::GetEnvironmentVariable($key, 'Process') | Should Be $before[$key] }
    (Get-Location).Path | Should Be $locationBefore
  }
}
