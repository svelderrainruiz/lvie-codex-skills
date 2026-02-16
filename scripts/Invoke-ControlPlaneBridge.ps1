Set-StrictMode -Version Latest

function Resolve-NodePath {
  $candidates = @('node', 'C:\Program Files\nodejs\node.exe')
  foreach ($candidate in $candidates) {
    if ($candidate -like '*\*') {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
      }
      continue
    }

    $probe = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $probe) {
      return $probe.Path
    }
  }

  throw 'Node.js runtime not found. Install Node.js 20+ for control-plane execution.'
}

function Invoke-ControlPlaneBridge {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [hashtable]$Arguments
  )

  $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  $entryPath = Join-Path $repoRoot 'control-plane/dist/index.js'
  if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
    throw "Control-plane entrypoint not found: $entryPath"
  }

  $nodePath = Resolve-NodePath
  $argsJson = $Arguments | ConvertTo-Json -Depth 20 -Compress

  & $nodePath $entryPath $Command --args-json $argsJson
  if ($LASTEXITCODE -ne 0) {
    throw "Control-plane command '$Command' failed with exit code $LASTEXITCODE."
  }
}
