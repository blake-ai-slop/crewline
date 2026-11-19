. "$PSScriptRoot/CrewAst.ps1"
. "$PSScriptRoot/TestHome.ps1"
$root = Split-Path $PSScriptRoot -Parent

function Get-MissingNext($ast, [string]$command) {
  @($ast.FindAll({ param($a)
    $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq $command
  }, $true) | Where-Object {
    $e = $_.CommandElements
    $e.Count -lt 3 -or
      ($e[2] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]::IsNullOrWhiteSpace($e[2].Value)) -or
      ($e[2] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $e[2].NestedExpressions.Count -eq 0 -and [string]::IsNullOrWhiteSpace($e[2].Value))
  })
}

Describe 'Every error has a next step (AST only)' {
  $files = @((Get-CrewSourceFiles -Root $root)) + @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' -File | ForEach-Object { $_.FullName }) + @(Join-Path $root 'install.ps1')
  foreach ($file in @($files | Sort-Object -Unique)) {
    It "Die has a nonempty second argument: $([IO.Path]::GetFileName($file))" {
      $tokens=$null; $errors=$null
      $ast=[System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
      $errors.Count | Should Be 0
      $missing = @(Get-MissingNext $ast 'Die')
      ($missing | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join "`n" | Should Be ''
    }
  }
  It 'bootstrap Fail always supplies Lam tiep' {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'bootstrap.ps1'),[ref]$tokens,[ref]$errors)
    @(Get-MissingNext $ast 'Fail').Count | Should Be 0
    $fn=$ast.Find({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Fail'},$true)
    $fn.Extent.Text | Should Match 'Lam tiep:'
  }
  It 'guard detects omitted, empty and whitespace next, accepts a real next' {
    $ast=[scriptblock]::Create('Die "bad"; Die "bad" ''''; Die "bad" "  "; Die "bad" "do this"').Ast
    @(Get-MissingNext $ast 'Die').Count | Should Be 3
  }
  It 'Die prints a separate next-step line and exits 1' {
    $h=New-CrewTestHome
    $file=Join-Path $h.Home 'die.ps1'
    [IO.File]::WriteAllText($file, (Get-CrewFunction 'Die').Extent.Text + "`nDie 'lỗi thử' 'crew hot'", [Text.UTF8Encoding]::new($true))
    $r=Invoke-InTestHome -TestHome $h -File $file
    $r.ExitCode | Should Be 1
    $r.Output | Should Be "crew: LỖI: lỗi thử`n  → Làm tiếp:`n    crew hot"
  }
  It 'install command follows the platform' {
    . ([scriptblock]::Create((Get-CrewFunction 'Get-CrewInstallCommand').Extent.Text))
    foreach ($os in 'windows','linux','macos') {
      function Get-CrewOS { $os }
      $expected=if ($os -eq 'windows') { 'irm https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.ps1 | iex' } else { 'curl -fsSL https://raw.githubusercontent.com/blake-ai-slop/crewline/main/bootstrap.sh | sh' }
      Get-CrewInstallCommand | Should Be $expected
    }
  }
}
