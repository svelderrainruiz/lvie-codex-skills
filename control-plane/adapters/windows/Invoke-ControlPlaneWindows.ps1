param(
  [Parameter(Mandatory = $true)]
  [string]$Command,

  [Parameter(Mandatory = $false)]
  [string]$ArgsJson = '{}'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$entry = Join-Path $repoRoot 'control-plane/dist/index.js'

if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
  throw "control-plane entrypoint not found: $entry"
}

$nodeCandidates = @('node', 'C:\Program Files\nodejs\node.exe')
$nodePath = $null
foreach ($candidate in $nodeCandidates) {
  try {
    if ($candidate -like '*\\*') {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $nodePath = $candidate
        break
      }
    } else {
      $probe = Get-Command $candidate -ErrorAction SilentlyContinue
      if ($null -ne $probe) {
        $nodePath = $probe.Path
        break
      }
    }
  } catch {
  }
}

if ([string]::IsNullOrWhiteSpace($nodePath)) {
  throw 'node runtime not found. Install Node.js 20+.'
}

& $nodePath $entry $Command --args-json $ArgsJson
if ($LASTEXITCODE -ne 0) {
  throw "control-plane command '$Command' failed with exit code $LASTEXITCODE"
}
