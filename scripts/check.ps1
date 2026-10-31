param([string]$Name, [string]$Path = '.')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Invoke-CheckGit {
  $ErrorActionPreference = 'Continue'
  $result = @(& git @args 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
  $result
}
function Run-CheckChild([string]$Shell, [string]$Code, [string]$Directory) {
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = (Get-Command $Shell -ErrorAction Stop).Source
  $info.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
  $info.WorkingDirectory = $Directory
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = [Text.Encoding]::UTF8
  $info.StandardErrorEncoding = [Text.Encoding]::UTF8
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $result = [pscustomobject]@{ Code = $process.ExitCode; Text = $stdout.Result + $stderr.Result }
  $process.Dispose()
  $result
}
$state = [ordered]@{ 'phạm vi' = 'bỏ qua'; parse = 'bỏ qua'; test = 'bỏ qua' }
$failed = $false
try {
  if (-not $Name) { throw 'cần tên task: crew check <task>' }
  $trees = @(Invoke-CheckGit -C $Path worktree list --porcelain)
  $root = ($trees | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1).Substring(9)
  $tasksFile = Join-Path $root '.crew/tasks.json'
  if (-not (Test-Path -LiteralPath $tasksFile)) { throw "không có task ${Name}: thiếu $tasksFile" }
  $tasks = @(Get-Content -LiteralPath $tasksFile -Raw -Encoding UTF8 | ConvertFrom-Json)
  $task = $tasks | Where-Object { $_.name -eq $Name } | Select-Object -First 1
  if (-not $task) { throw "task $Name không có trong .crew/tasks.json" }
  $worktree = $task.worktree
  if (-not [IO.Path]::IsPathRooted($worktree)) { $worktree = Join-Path $root $worktree }
  $prompt = Get-Content -LiteralPath (Join-Path $worktree '.crew/prompt.md') -Raw -Encoding UTF8
  $line = [regex]::Match($prompt, '(?m)^Được sửa:[^\r\n]*')
  $allowed = @("context/tasks/$Name.md")
  if ($line.Success) {
    $allowed += @([regex]::Matches($line.Value, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') })
    $state['phạm vi'] = 'OK'
  } else { Write-Host 'Cảnh báo: không có danh sách Được sửa; bỏ qua phạm vi.' }
  $main = (Invoke-CheckGit -C $root symbolic-ref --short HEAD) -join ''
  $range = "$main...$($task.branch)"
  $files = @(Invoke-CheckGit -c core.quotepath=false -C $root diff --name-only $range)
  Invoke-CheckGit -C $root diff --stat $range | Out-Host
  if ($line.Success) {
    foreach ($file in $files) {
      $match = $false
      foreach ($rule in $allowed) {
        if ($rule.EndsWith('/')) { if ($file.StartsWith($rule, [StringComparison]::OrdinalIgnoreCase)) { $match = $true } }
        elseif ($file -like $rule) { $match = $true }
      }
      if (-not $match) { Write-Host "NGOÀI PHẠM VI: $file"; $state['phạm vi'] = 'LỖI'; $failed = $true }
    }
  }
  $scripts = @($files | Where-Object { $_ -like '*.ps1' -and (Test-Path -LiteralPath (Join-Path $worktree $_) -PathType Leaf) })
  $shells = @('pwsh')
  if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { $shells += 'powershell.exe' }
  else { Write-Host 'parse PS 5.1: bỏ qua (không có powershell.exe)' }
  if ($scripts.Count) { $state.parse = 'OK' }
  foreach ($shell in $shells) {
    foreach ($file in $scripts) {
      $quoted = (Join-Path $worktree $file).Replace("'", "''")
      $code = @"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
`$tokens = `$null; `$errors = `$null
[System.Management.Automation.Language.Parser]::ParseFile('$quoted', [ref]`$tokens, [ref]`$errors) | Out-Null
foreach (`$e in `$errors) { Write-Output ('$file' + ':' + `$e.Extent.StartLineNumber + ': ' + `$e.Message) }
if (`$errors.Count) { exit 1 }
"@
      $r = Run-CheckChild $shell $code $worktree
      if ($r.Code -ne 0) { Write-Host "$shell parse: $($r.Text)"; $state.parse = 'LỖI'; $failed = $true }
    }
  }
  $tests = @($files | Where-Object { $_ -match '^tests/[^/]+\.Tests\.ps1$' -and (Test-Path -LiteralPath (Join-Path $worktree $_) -PathType Leaf) })
  if ($tests.Count) {
    $list = ($tests | ForEach-Object { "'" + (Join-Path $worktree $_).Replace("'", "''") + "'" }) -join ','
    $code = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; `$ErrorActionPreference = 'Stop'; try { `$r = Invoke-Pester -Script @($list) -PassThru; if (`$r.FailedCount -gt 0) { exit 1 } } catch { Write-Output `$_; exit 1 }"
    $r = Run-CheckChild 'pwsh' $code $worktree
    Write-Host $r.Text
    $state.test = 'OK'
    if ($r.Code -ne 0) { $state.test = 'LỖI'; $failed = $true }
  } else { Write-Host 'không có test thay đổi' }
} catch { Write-Host "check: LỖI: $($_.Exception.Message)"; $failed = $true }
foreach ($key in $state.Keys) { Write-Host "$key : $($state[$key])" }
if ($failed) { exit 1 }
exit 0
