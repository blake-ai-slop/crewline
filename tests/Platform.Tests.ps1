. "$PSScriptRoot/TestHome.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent
Describe 'platform helpers' {
  It 'dot-source produces no output' {
    $out = & { . "$RepoRoot/scripts/platform.ps1" }
    $out | Should BeNullOrEmpty
  }
  It 'detects this host' {
    . "$RepoRoot/scripts/platform.ps1"
    $expected = if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    Get-CrewOS | Should Be $expected
  }
  It 'uses platform paths including XDG override in a child with fake HOME' {
    $runner = Join-Path $TestDrive 'platform-paths.ps1'
    @'
param($Platform, $Source)
. $Source
function Get-CrewOS { $Platform }
@{ config = Get-HcConfigDir; templates = Get-HcTemplateDir; bin = Get-UserBinDir; home = $HOME } | ConvertTo-Json -Compress
'@ | Set-Content $runner
    foreach ($os in 'windows', 'linux', 'macos') {
      $h = New-CrewTestHome
      $xdg = Join-Path $h.Home 'custom-config'
      foreach ($override in '', $xdg) {
        $r = Invoke-InTestHome $h $runner -Arguments $os, "$RepoRoot/scripts/platform.ps1" -Env @{ XDG_CONFIG_HOME = $override }
        $r.ExitCode | Should Be 0
        $data = $r.Output | ConvertFrom-Json
        $base = if ($os -eq 'windows') { $h.AppData } elseif ($override) { $override } else { Join-Path $h.Home '.config' }
        $data.home | Should Be $h.Home
        $data.config | Should Be (Join-Path $base 'herdr-core')
        $data.templates | Should Be (Join-Path $base 'herdr-core/templates')
        $data.bin | Should Be (Join-Path $h.Home '.local/bin')
      }
    }
  }
  It 'writes Unix startup files once, preserves text, and honors NO_PATH' {
    $runner = Join-Path $TestDrive 'platform-write.ps1'
    @'
param($Platform, $Source)
. $Source
function Get-CrewOS { $Platform }
Set-Content (Join-Path $HOME '.bashrc') '# existing'
$dir = Join-Path $HOME 'bin with spaces'
$env:CREWLINE_NO_PATH = '1'
$skip = Add-UserPath $dir
$env:CREWLINE_NO_PATH = ''
$first = Add-UserPath $dir
$second = Add-UserPath $dir
@{ skip = $skip; first = $first; second = $second } | ConvertTo-Json -Compress
'@ | Set-Content $runner
    foreach ($os in 'linux', 'macos') {
      $h = New-CrewTestHome
      $r = Invoke-InTestHome $h $runner -Arguments $os, "$RepoRoot/scripts/platform.ps1"
      $r.ExitCode | Should Be 0
      $data = $r.Output | ConvertFrom-Json
      $data.skip | Should Be $false
      $data.first | Should Be $true
      $data.second | Should Be $false
      $files = @('.profile') + $(if ($os -eq 'linux') { '.bashrc' } else { '.zshrc' })
      foreach ($file in $files) {
        $content = Get-Content (Join-Path $h.Home $file) -Raw
        ([regex]::Matches($content, '# crewline')).Count | Should Be 1
        $content | Should Match 'export PATH=".+bin with spaces:\$PATH" # crewline'
      }
      Get-Content (Join-Path $h.Home '.bashrc') -Raw | Should Match '# existing'
      if ($os -eq 'linux') { Test-Path (Join-Path $h.Home '.zshrc') | Should Be $false }
    }
  }
}
