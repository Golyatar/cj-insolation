param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^20\d\d$')]
  [string]$SketchUpVersion
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path.Replace('\', '/')
$pluginsPath = Join-Path $env:APPDATA "SketchUp\SketchUp $SketchUpVersion\SketchUp\Plugins"
New-Item -ItemType Directory -Path $pluginsPath -Force | Out-Null
$loaderPath = Join-Path $pluginsPath 'cj_bridge_loader.rb'
$rootLiteral = ConvertTo-Json -InputObject $projectRoot -Compress
$loader = @"
# CJ Bridge loader. This file is managed by tooling/install_bridge.ps1.
Kernel.load(File.join($rootLiteral, 'tooling', 'sketchup_bridge.rb'))
"@

if (Test-Path -LiteralPath $loaderPath) {
  $existing = Get-Content -LiteralPath $loaderPath -Raw
  if ($existing -notlike '*managed by tooling/install_bridge.ps1*') {
    $backup = "$loaderPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $loaderPath -Destination $backup
    Write-Output "Existing loader backed up to $backup"
  }
}

Set-Content -LiteralPath $loaderPath -Value $loader -Encoding UTF8
Write-Output "Installed CJ Bridge auto-loader for SketchUp ${SketchUpVersion}: $loaderPath"
Write-Output 'Restart SketchUp; each instance will register itself. The CJ Bridge menu can restart or stop its connection.'
