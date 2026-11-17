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
# Hàm thuần: giữ nguyên các mục PATH thô, kể cả %VAR% và mục trống.
function Get-PrependedUserPath([string]$RawPath, [string]$Dir) {
  $key = $Dir.TrimEnd('\')
  foreach ($item in ($RawPath -split ';')) {
    if ($item.TrimEnd('\').Equals($key, [StringComparison]::OrdinalIgnoreCase)) { return $RawPath }
  }
  if ($RawPath) { return "$Dir;$RawPath" }
  $Dir
}
function New-UserPathOps {
  @{
    Read = {
      $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
      try { if ($key) { $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } }
      finally { if ($key) { $key.Dispose() } }
    }
    Write = {
      param($value, $kind)
      $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
      try { $key.SetValue('Path', $value, $kind) } finally { $key.Dispose() }
    }
    Notify = {
      if (-not ('Crewline.EnvironmentBroadcast' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Crewline {
  public static class EnvironmentBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wparam, string lparam, uint flags, uint timeout, out UIntPtr result);
  }
}
"@
      }
      $result = [UIntPtr]::Zero
      $null = [Crewline.EnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    }
  }
}
function Add-UserPath([string]$Dir, $Ops = $null) {
  if ($env:CREWLINE_NO_PATH -eq '1') { return $false }
  $os = Get-CrewOS
  if ($os -eq 'windows') {
    if (-not $Ops) { $Ops = New-UserPathOps }
    $userPath = [string](& $Ops.Read)
    $newPath = Get-PrependedUserPath $userPath $Dir
    if ($newPath -ceq $userPath) { return $false }
    & $Ops.Write $newPath ([Microsoft.Win32.RegistryValueKind]::ExpandString)
    & $Ops.Notify
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
