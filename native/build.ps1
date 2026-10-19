$ErrorActionPreference = 'Stop'
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Install Visual Studio C++ Build Tools.' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
$output = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $output -Force | Out-Null
# Both paths are fixed files/directories; no filesystem deletion or shell-composed user input.
Push-Location $output
try {
  $batch = @((('@call "' + $vcvars + '" >nul')), '@if errorlevel 1 exit /b 1', '@cl /nologo /O2 /std:c++17 /EHsc /MT /W4 ..\engine.cpp /Fe:cj_engine.exe /link /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup', '@exit /b %errorlevel%')
  Set-Content -LiteralPath (Join-Path $output 'build.cmd') -Value $batch -Encoding ascii
  & cmd.exe /d /c build.cmd
  if ($LASTEXITCODE -ne 0) { throw 'C++ compilation failed.' }
} finally { Pop-Location }
