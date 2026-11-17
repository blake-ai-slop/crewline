# Parse source without executing crew dispatch or its dot-sourced scripts.
function Get-CrewSourceFiles {
  param([string]$Root = (Split-Path $PSScriptRoot -Parent))
  Join-Path $Root 'scripts/crew.ps1'
  $directory = Join-Path $Root 'scripts/crew'
  if (Test-Path -LiteralPath $directory -PathType Container) {
    Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File |
      Sort-Object Name | ForEach-Object { $_.FullName }
  }
}

function Get-CrewAsts {
  param([string]$Root = (Split-Path $PSScriptRoot -Parent))
  foreach ($file in (Get-CrewSourceFiles -Root $Root)) {
    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) {
      throw "Cannot parse '${file}': $($parseErrors.Message -join '; ')"
    }
    $sourceAst
  }
}

function Find-CrewAst {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Predicate,
    [bool]$Recurse = $true,
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
  )
  foreach ($sourceAst in (Get-CrewAsts -Root $Root)) {
    $sourceAst.FindAll($Predicate, $Recurse)
  }
}

function Get-CrewFunction {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
  )
  $matches = @(Find-CrewAst -Root $Root -Predicate {
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  })
  if ($matches.Count -ne 1) {
    throw "Expected one crew function '$Name'; found $($matches.Count)."
  }
  $matches[0]
}

function Get-CrewParamNames {
  param([string]$Root = (Split-Path $PSScriptRoot -Parent))
  $entryAst = @(Get-CrewAsts -Root $Root)[0]
  $entryAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
}
