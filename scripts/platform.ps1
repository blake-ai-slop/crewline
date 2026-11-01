# Platform helpers: dot-source only defines functions.
function Get-CrewOS {
  if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { return 'windows' }
  if ($IsMacOS) { return 'macos' }
  return 'linux'
}
function Get-HcConfigDir {
  if ((Get-CrewOS) -eq 'windows') { return (Join-Path $env:APPDATA 'herdr-core') }
  $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
  Join-Path $config 'herdr-core'
}
function Get-HcTemplateDir { Join-Path (Get-HcConfigDir) 'templates' }
function Get-UserBinDir { Join-Path $HOME '.local/bin' }
function Add-UserPath([string]$Dir) {
  if ($env:CREWLINE_NO_PATH -eq '1') { return $false }
  $os = Get-CrewOS
  if ($os -eq 'windows') {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -contains $Dir) { return $false }
    [Environment]::SetEnvironmentVariable('Path', ((@($Dir) + @($userPath -split ';' | Where-Object { $_ })) -join ';'), 'User')
    return $true
  }
  # Escape shell interpolation in the literal directory, preserving only the final $PATH.
  $escaped = $Dir.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
  $line = 'export PATH="' + $escaped + ':$PATH" # crewline'
  $files = @(Join-Path $HOME '.profile')
  if ($os -eq 'macos') { $files += Join-Path $HOME '.zshrc' }
  elseif (Test-Path (Join-Path $HOME '.bashrc')) { $files += Join-Path $HOME '.bashrc' }
  $changed = $false
  foreach ($file in $files) {
    $content = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    if (($content -split '\r?\n') -contains $line) { continue }
    $prefix = if ($content -and -not $content.EndsWith("`n")) { "`n" } else { '' }
    [IO.File]::AppendAllText($file, "$prefix$line`n", [Text.UTF8Encoding]::new($false))
    $changed = $true
  }
  return $changed
}
function Get-HerdrInstallHint {
  $os = Get-CrewOS
  if ($os -eq 'windows') { return 'tải: https://herdr.dev/' }
  if ($os -eq 'macos' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'X64') {
    return 'Mac Intel: không có herdr-app; build from source: https://github.com/herdrdev/herdr-app#build-from-source'
  }
  return 'curl -fsSL https://releases.herdr.dev/app/install.sh | sh'
}
