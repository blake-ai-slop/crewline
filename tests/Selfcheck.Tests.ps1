$SelfcheckScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
Describe 'crew selfcheck isolated user journey' {
  It 'passes install, PS 5.1 shim, init, upgrades and Vietnamese HOME without changing the caller' {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $before = @{}
    foreach ($key in 'USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'Path') { $before[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    $locationBefore = (Get-Location).Path
    $output = & pwsh -NoProfile -File $SelfcheckScript selfcheck 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ($output -join "`n") }
    $code | Should Be 0
    @($output | Where-Object { $_ -match '^PASS ' }).Count | Should Be 8
    ($output -join "`n") | Should Not Match '^FAIL '
    foreach ($key in $before.Keys) { [Environment]::GetEnvironmentVariable($key, 'Process') | Should Be $before[$key] }
    (Get-Location).Path | Should Be $locationBefore
  }
}
