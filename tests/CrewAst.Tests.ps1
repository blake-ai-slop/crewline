. (Join-Path $PSScriptRoot 'CrewAst.ps1')

Describe 'Crew source AST helpers' {
  BeforeEach {
    $fixtureRoot = Join-Path $TestDrive 'fixture'
    $parts = Join-Path $fixtureRoot 'scripts/crew'
    New-Item -ItemType Directory -Path $parts -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'scripts/crew.ps1') -Value 'param($First, $Second); function Entry { function Nested {} }; throw "must not execute"'
    # Deliberately create b before a; enumeration must sort by filename.
    Set-Content -LiteralPath (Join-Path $parts 'b.ps1') -Value 'param($Other); function Bee {}'
    Set-Content -LiteralPath (Join-Path $parts 'a.ps1') -Value 'function Aye {}'
    Set-Content -LiteralPath (Join-Path $parts 'ignore.txt') -Value 'not PowerShell'
    New-Item -ItemType Directory -Path (Join-Path $parts 'nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $parts 'nested/ignore.ps1') -Value 'function Ignored {}'
  }

  It 'returns the entry script then immediate ps1 files sorted by name' {
    $files = @(Get-CrewSourceFiles -Root $fixtureRoot)
    $files.Count | Should Be 3
    $files[0] | Should Be (Join-Path $fixtureRoot 'scripts/crew.ps1')
    $files[1] | Should Be (Join-Path $parts 'a.ps1')
    $files[2] | Should Be (Join-Path $parts 'b.ps1')
    $asts = @(Get-CrewAsts -Root $fixtureRoot)
    $asts.Count | Should Be 3
    foreach ($sourceAst in $asts) {
      ($sourceAst -is [System.Management.Automation.Language.ScriptBlockAst]) | Should Be $true
    }
    ($asts.Extent.File -join '|') | Should Be ($files -join '|')
  }

  It 'merges matches in file order and defaults to recursive searches' {
    $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    $functions = @(Find-CrewAst $predicate -Root $fixtureRoot)
    ($functions.Name -join ',') | Should Be 'Entry,Nested,Aye,Bee'
    $functions = @(Find-CrewAst $predicate -Recurse:$false -Root $fixtureRoot)
    ($functions.Name -join ',') | Should Be 'Entry,Aye,Bee'
    @(Find-CrewAst { param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] } -Root $fixtureRoot).Count | Should Be 0
  }

  It 'returns one function and throws for missing or duplicate names' {
    (Get-CrewFunction Aye -Root $fixtureRoot).Name | Should Be 'Aye'
    { Get-CrewFunction Missing -Root $fixtureRoot } | Should Throw 'Missing'
    Add-Content -LiteralPath (Join-Path $parts 'b.ps1') -Value 'function Aye {}'
    { Get-CrewFunction Aye -Root $fixtureRoot } | Should Throw 'Aye'
  }

  It 'reads only the entry script parameter block' {
    ((Get-CrewParamNames -Root $fixtureRoot) -join ',') | Should Be 'First,Second'
  }

  It 'works when the crew directory is absent' {
    # Use a separate fixture, avoiding deletion of the shared BeforeEach fixture.
    $singleRoot = Join-Path $TestDrive 'single'
    New-Item -ItemType Directory -Path (Join-Path $singleRoot 'scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $singleRoot 'scripts/crew.ps1') -Value 'param($Only); function Solo {}'
    @(Get-CrewSourceFiles -Root $singleRoot).Count | Should Be 1
    @(Get-CrewAsts -Root $singleRoot).Count | Should Be 1
    (Get-CrewFunction Solo -Root $singleRoot).Name | Should Be 'Solo'
    (Get-CrewParamNames -Root $singleRoot) | Should Be 'Only'
  }

  It 'throws with the source filename on parse errors' {
    Set-Content -LiteralPath (Join-Path $parts 'b.ps1') -Value 'function Broken {'
    { Get-CrewAsts -Root $fixtureRoot } | Should Throw 'b.ps1'
  }

  It 'defaults to this repository root' {
    @(Get-CrewSourceFiles)[0] | Should Be (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/crew.ps1')
    (Get-CrewFunction Get-Tasks).Name | Should Be 'Get-Tasks'
    @(Get-CrewParamNames) -contains 'Path' | Should Be $true
  }
}
