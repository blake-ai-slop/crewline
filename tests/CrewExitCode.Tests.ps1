. "$PSScriptRoot/CrewAst.ps1"
. "$PSScriptRoot/TestHome.ps1"
$crew = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1'
Describe 'crew command exit codes' {
  It 'real queue add and update return 0 after missing git ref; invalid command returns 1' {
    $h=New-CrewTestHome
    $repo=Join-Path $h.Home 'project'
    New-Item -ItemType Directory -Force (Join-Path $repo '.crew') | Out-Null
    git -C $repo init -q -b main
    git -C $repo -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    '{"name":"qt","idKey":"qt","planner":"none","workers":["codex"],"rev":"none"}' | Set-Content (Join-Path $repo '.crew/config.json')
    $prompt=Join-Path $repo 'prompt.md'; 'prompt 1' | Set-Content $prompt
    $r=Invoke-InTestHome -TestHome $h -File $crew -WorkingDirectory $repo -Arguments @('queue','fix',$prompt)
    $r.Output | Should Match 'đã xếp fix'
    $r.ExitCode | Should Be 0
    'prompt 2' | Set-Content $prompt
    $r=Invoke-InTestHome -TestHome $h -File $crew -WorkingDirectory $repo -Arguments @('queue','fix',$prompt)
    $r.Output | Should Match 'đã cập nhật fix'
    $r.ExitCode | Should Be 0
    (Get-Content (Join-Path $repo '.crew/queue/fix.md') -Raw).Trim() | Should Be 'prompt 2'
    $r=Invoke-InTestHome -TestHome $h -File $crew -WorkingDirectory $repo -Arguments @('queue','Bad_Name',$prompt)
    $r.ExitCode | Should Be 1
    $r.Output | Should Match '→ Làm tiếp:'
    foreach ($command in 'version','lint') {
      $r=Invoke-InTestHome -TestHome $h -File $crew -WorkingDirectory $repo -Arguments @($command)
      $r.ExitCode | Should Be 0
    }
  }
  # Execute the real dispatch AST with isolated handlers: no hc/agent calls.
  $tokens=$null; $errors=$null
  $ast=[System.Management.Automation.Language.Parser]::ParseFile($crew,[ref]$tokens,[ref]$errors)
  $dispatch=$ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.SwitchStatementAst] } | Select-Object -Last 1
  $tail=$ast.EndBlock.Statements[-1].Extent.Text
  foreach ($command in 'task','queue','send','review','clean','hot','version','doctor','upgrade','repair','limits') {
    It "$command normal return clears stale native exit; explicit exit and throw survive" {
      $h=New-CrewTestHome
      $file=Join-Path $h.Home 'dispatch.ps1'
      $function=if ($command -eq 'repair') { 'Invoke-Recover' } else { 'Invoke-'+$command }
      foreach ($body in 'return','exit 7',"throw 'failed'") {
        $script='param($Command)' + "`nfunction $function { $body }`n`$global:LASTEXITCODE=9`n" + $dispatch.Extent.Text + "`n$tail"
        [IO.File]::WriteAllText($file,$script,[Text.UTF8Encoding]::new($true))
        $r=Invoke-InTestHome -TestHome $h -File $file -Arguments @($command)
        $expected=if ($body -eq 'return') { 0 } elseif ($body -eq 'exit 7') { 7 } else { 1 }
        $r.ExitCode | Should Be $expected
      }
    }
  }
}
