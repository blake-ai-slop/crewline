. (Join-Path $PSScriptRoot 'TestHome.ps1')
$versionRepo = Split-Path $PSScriptRoot -Parent

Describe 'crew version' {
  BeforeAll {
    $testHome = New-CrewTestHome
    $installRoot = Join-Path $TestDrive 'Crewline copy'
    New-Item -ItemType Directory -Force $installRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $versionRepo 'scripts') -Destination $installRoot -Recurse
    $entry = Join-Path $installRoot 'scripts/crew.ps1'
    $versionFile = Join-Path $installRoot 'VERSION'
  }

  It 'đọc VERSION cạnh scripts và in đúng thư mục bản đang chạy' {
    [IO.File]::WriteAllText($versionFile, "13`n")
    $r = Invoke-InTestHome -TestHome $testHome -File $entry -Arguments @('version')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Crewline v13'
    $r.Output | Should Match ([regex]::Escape($installRoot))
  }

  It 'in nguyên phiên bản vá gồm hai phần' {
    [IO.File]::WriteAllText($versionFile, '15.10')
    $r = Invoke-InTestHome -TestHome $testHome -File $entry -Arguments @('version')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match '(?m)^Crewline v15\.10$'
  }

  It 'bản cài cũ thiếu VERSION: v? + cảnh báo, exit 0' {
    Remove-Item -LiteralPath $versionFile -Force
    $r = Invoke-InTestHome -TestHome $testHome -File $entry -Arguments @('version')
    $r.ExitCode | Should Be 0
    $r.Output | Should Match 'Crewline v\?'
    $r.Output | Should Match 'Không đọc được VERSION'
  }

  foreach ($invalid in @('0', '-1', 'v13', '015', '0.1', '15.0', '15.01', '15.1.2', '15x1', "13`n14", '')) {
    It "VERSION sai '$invalid': v? + cảnh báo, exit 0" {
      [IO.File]::WriteAllText($versionFile, $invalid)
      $r = Invoke-InTestHome -TestHome $testHome -File $entry -Arguments @('version')
      $r.ExitCode | Should Be 0
      $r.Output | Should Match 'Crewline v\?'
      $r.Output | Should Match 'Không đọc được VERSION'
    }
  }
}
