param([switch]$Keep)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$repo = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('crew-selfcheck-' + [guid]::NewGuid().ToString('N'))
$failed = $false

# Child-only environment: never change the caller's profile, PATH or Git config.
function Invoke-SelfChild {
  param([string]$Code, [string]$Profile, [string]$Directory, [string]$Shell = 'pwsh', [string]$InputText = '', [switch]$InteractiveInit)
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = (Get-Command $Shell -ErrorAction Stop).Source
  $prefix = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::InputEncoding = [Text.UTF8Encoding]::new($false); $ErrorActionPreference = ''Stop''; '
  $info.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix + $Code))
  $info.WorkingDirectory = $Directory
  $info.UseShellExecute = $false
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = [Text.Encoding]::UTF8
  $info.StandardErrorEncoding = [Text.Encoding]::UTF8
  $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  $vars = @{
    USERPROFILE = $Profile; HOME = $Profile
    APPDATA = (Join-Path $Profile 'AppData/Roaming'); LOCALAPPDATA = (Join-Path $Profile 'AppData/Local')
    CREWLINE_DEFAULTS = '1'; CREWLINE_NO_PATH = '1'; CREWLINE_NO_JQ = '1'; CREWLINE_NO_INSTALL = '1'
    CREWLINE_USER_CONFIG = (Join-Path $Profile '.crewline/config.json')
    GIT_CONFIG_GLOBAL = (Join-Path $Profile 'gitconfig'); GIT_CONFIG_NOSYSTEM = '1'
    GIT_AUTHOR_NAME = 'Crew Selfcheck'; GIT_AUTHOR_EMAIL = 'selfcheck@example.invalid'
    GIT_COMMITTER_NAME = 'Crew Selfcheck'; GIT_COMMITTER_EMAIL = 'selfcheck@example.invalid'
    GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = 'core.autocrlf'; GIT_CONFIG_VALUE_0 = 'false'
  }
  if ($InteractiveInit) { $vars.CREWLINE_DEFAULTS = '' }
  # Store pwsh: let Windows PowerShell resolve the public alias.
  if ($Shell -eq 'powershell.exe') {
    $vars.Path = (($env:Path -split ';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $PSHOME.TrimEnd('\') }) -join ';'
  }
  foreach ($key in $vars.Keys) { $info.EnvironmentVariables[$key] = $vars[$key] }
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.StandardInput.Write($InputText)
  $process.StandardInput.Close()
  $process.WaitForExit()
  $result = [pscustomobject]@{ Code = $process.ExitCode; Text = $stdout.Result + $stderr.Result }
  $process.Dispose()
  $result
}
function Assert-Child($Result) {
  if ($Result.Code -ne 0 -or $Result.Text -match 'NativeCommandError|ParserError') { throw "exit $($Result.Code): $($Result.Text)" }
}
function Step([string]$Label, [scriptblock]$Action) {
  try { & $Action; Write-Host "PASS $Label" }
  catch { $script:failed = $true; Write-Host "FAIL ${Label}: $($_.Exception.Message)" }
}
function Get-SelfSnapshot([string]$Directory) {
  # Include ignored files too, so a DryRun cannot silently create backups.
  (@(Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
    if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force } else { $_ }
  }) | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
}
function Quote-Self([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  foreach ($variant in @('home', 'thử-crew')) {
    $profile = Join-Path $tempRoot $variant
    foreach ($dir in @($profile, (Join-Path $profile 'AppData/Roaming'), (Join-Path $profile 'AppData/Local'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $shim = Join-Path $profile '.local/bin/crew.ps1'
    Step "install ($variant): shim trong HOME giả" {
      $r = Invoke-SelfChild -Profile $profile -Directory $repo -Code ("& " + (Quote-Self (Join-Path $repo 'install.ps1')) + ' -NoDoctor; exit $LASTEXITCODE')
      Assert-Child $r
      if (-not (Test-Path -LiteralPath $shim)) { throw 'thiếu shim crew.ps1' }
    }
    Step "help PS 5.1 ($variant): exit 0, không lỗi parser/native" {
      $r = Invoke-SelfChild -Profile $profile -Directory $repo -Shell powershell.exe -Code ("& " + (Quote-Self $shim) + ' help; exit $LASTEXITCODE')
      Assert-Child $r
    }
    if ($variant -ne 'home') { continue }
    $project = Join-Path $profile 'new project'
    New-Item -ItemType Directory -Path $project | Out-Null
    Step 'init PS 5.1: stdin 1 tạo git, context và commit đầu' {
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Shell powershell.exe -InteractiveInit -InputText "1`n" -Code ("& " + (Quote-Self $shim) + ' init; exit $LASTEXITCODE')
      Assert-Child $r
      if (-not (Test-Path "$project/.git") -or -not (Test-Path "$project/context/roles/worker.md")) { throw 'thiếu .git/context' }
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git log --format=%s; exit $LASTEXITCODE'
      Assert-Child $r
      if ($r.Text -notmatch 'chore: initial commit') { throw 'thiếu commit đầu' }
    }
    Step 'upgrade DryRun: giữ nguyên file và HEAD' {
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Code "Set-Content context/roles/worker.md 'old worker role'; git add context/roles/worker.md; if (`$LASTEXITCODE) { exit 1 }; git commit -qm old; exit `$LASTEXITCODE"
      Assert-Child $r
      $beforeFiles = Get-SelfSnapshot $project
      $before = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git rev-parse HEAD; git status --porcelain --untracked-files=all'
      Assert-Child $before
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Code ("& " + (Quote-Self $shim) + ' upgrade -DryRun; exit $LASTEXITCODE')
      Assert-Child $r
      $after = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git rev-parse HEAD; git status --porcelain --untracked-files=all'
      Assert-Child $after
      if ($before.Text -ne $after.Text -or $beforeFiles -ne (Get-SelfSnapshot $project)) { throw 'DryRun đã thay đổi file/HEAD/status' }
    }
    Step 'upgrade: commit mới, role cập nhật, status sạch' {
      $before = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git rev-parse HEAD'
      Assert-Child $before
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Code ("& " + (Quote-Self $shim) + ' upgrade; exit $LASTEXITCODE')
      Assert-Child $r
      $after = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git rev-parse HEAD'
      $status = Invoke-SelfChild -Profile $profile -Directory $project -Code 'git status --porcelain; exit $LASTEXITCODE'
      Assert-Child $after; Assert-Child $status
      if ($before.Text -eq $after.Text -or $status.Text.Trim()) { throw 'thiếu commit upgrade hoặc status bẩn' }
      if ([IO.File]::ReadAllText("$project/context/roles/worker.md") -ne [IO.File]::ReadAllText("$repo/skeleton/context/roles/worker.md")) { throw 'role chưa cập nhật' }
    }
    Step 'upgrade lần hai: không có gì mới' {
      $r = Invoke-SelfChild -Profile $profile -Directory $project -Code ("& " + (Quote-Self $shim) + ' upgrade; exit $LASTEXITCODE')
      Assert-Child $r
      if ($r.Text -notmatch 'không có gì mới') { throw $r.Text }
    }
  }
} catch { $failed = $true; Write-Host "FAIL selfcheck: $($_.Exception.Message)" }
finally {
  if ($Keep) { Write-Host "Giữ thư mục: $tempRoot" }
  elseif (Test-Path -LiteralPath $tempRoot) {
    try {
      $resolved = [IO.Path]::GetFullPath($tempRoot)
      $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
      if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'crew-selfcheck-*') { throw 'đường dẫn xóa không hợp lệ' }
      Remove-Item -LiteralPath $resolved -Recurse -Force
    } catch { Write-Host "Không xóa được thư mục tạm: $tempRoot ($($_.Exception.Message))" }
  }
}
if ($failed) { exit 1 }
exit 0
