# Khung test: HOME/APPDATA gia cho script ghi vao ho so nguoi dung.
# Dot-source trong file test: . "$PSScriptRoot/TestHome.ps1"
# $HOME cua pwsh lay tu USERPROFILE luc khoi dong, nen script can chay trong pwsh con (Invoke-InTestHome).

function New-CrewTestHome {
  param([string]$Name = 'home')
  $base = if ($TestDrive) { $TestDrive } else { [IO.Path]::GetTempPath() }
  $root = Join-Path $base "$Name-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  $h = @{
    Home         = Join-Path $root 'user'
    AppData      = Join-Path $root 'user/AppData/Roaming'
    LocalAppData = Join-Path $root 'user/AppData/Local'
  }
  foreach ($d in $h.Values) { New-Item -ItemType Directory -Force $d | Out-Null }
  $h
}

# Chay `<Shell> -NoProfile -File <File> <Arguments>` (Shell mac dinh pwsh; powershell de thu 5.1) voi ho so nguoi dung tro vao $TestHome.
# Luon dat CREWLINE_NO_PATH=1. -Env them bien moi truong khac. Tra @{ ExitCode; Output } (Output la chuoi gop stdout+stderr).
function Invoke-InTestHome {
  param(
    [Parameter(Mandatory)][hashtable]$TestHome,
    [Parameter(Mandatory)][string]$File,
    [string[]]$Arguments = @(),
    [hashtable]$Env = @{},
    [string]$WorkingDirectory,
    [string]$Shell = 'pwsh',
    [AllowEmptyString()][string]$InputText = ''
  )
  $vars = @{
    USERPROFILE      = $TestHome.Home
    HOME             = $TestHome.Home
    APPDATA          = $TestHome.AppData
    LOCALAPPDATA     = $TestHome.LocalAppData
    CREWLINE_NO_PATH = '1'
    CREWLINE_DEFAULTS = '1'
    CREWLINE_USER_CONFIG = $null
    GIT_CONFIG_GLOBAL = Join-Path $TestHome.Home 'gitconfig'
    GIT_CONFIG_NOSYSTEM = '1'
  }
  foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
  $shellPath = (Get-Command $Shell -ErrorAction Stop).Source
  $saved = @{}
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
  $savedLoc = Get-Location
  $savedInputEncoding = [Console]::InputEncoding
  try {
    # InputText is piped as UTF-8; the child must decode it with the same code page.
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    if ($WorkingDirectory) { Set-Location $WorkingDirectory }
    $out = $InputText | & $shellPath -NoProfile -NonInteractive -File $File @Arguments 2>&1 | ForEach-Object { "$_" }
    @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
  } finally {
    [Console]::InputEncoding = $savedInputEncoding
    Set-Location $savedLoc
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
}
