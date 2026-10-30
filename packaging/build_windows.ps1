#Requires -Version 5.1
<#
.SYNOPSIS
  Windows to Windows package for the configuration-scan host.
  Official CPython only. Prefer one timestamped exe; otherwise a flat folder
  zipped without _internal.
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Test-IsCondaPrefix([string]$Prefix) {
  $t = $Prefix.ToLower().Replace("/", "\")
  return ($t -match '\\miniconda') -or ($t -match '\\anaconda') -or ($t -match '\\conda\\')
}

function Stop-ConfigScanSafe {
  Get-Process | Where-Object {
    $_.ProcessName -eq "ConfigScan" -or $_.ProcessName -like "ConfigScan-*"
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

function Invoke-PyInstaller([string]$Mode, [string]$Stamp) {
  $env:CCS_PACK_MODE = $Mode
  $env:CCS_PACK_STAMP = $Stamp
  Write-Host "[build] pyinstaller mode=$Mode stamp=$Stamp"
  & $script:VenvPy -m PyInstaller `
    --noconfirm `
    --clean `
    --distpath $script:Out `
    --workpath $script:Work `
    (Join-Path $Root "packaging\config-scan.spec")
  if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed ($Mode)" }
}

function Test-Deliverable([string]$ExePath) {
  if (-not (Test-Path $ExePath)) { return $false }
  Write-Host "[build] smoke: $ExePath"
  $oldPath = $env:PATH
  $env:PATH = "C:\Windows\System32;C:\Windows"
  @("PYTHONPATH", "QT_PLUGIN_PATH", "QT_QPA_PLATFORM_PLUGIN_PATH") | ForEach-Object {
    Remove-Item "Env:$_" -ErrorAction SilentlyContinue
  }
  Get-ChildItem Env:CONDA* -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue
  }
  $p = $null
  try {
    $p = Start-Process -FilePath $ExePath -WorkingDirectory "C:\Windows" -PassThru
    $healthy = $false
    for ($i = 0; $i -lt 45; $i++) {
      Start-Sleep -Seconds 1
      if ($p.HasExited) {
        Write-Warning "[build] smoke exited early code=$($p.ExitCode)"
        return $false
      }
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:7040/api/health" -UseBasicParsing -TimeoutSec 1
        if ($r.StatusCode -eq 200) { $healthy = $true; break }
      } catch {}
    }
    Write-Host "[build] smoke health=$healthy"
    return [bool]$healthy
  } finally {
    if ($p -and -not $p.HasExited) {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      Get-Process | Where-Object { $_.ProcessName -like "ConfigScan*" } | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    }
    $env:PATH = $oldPath
  }
}

function New-LaunchBats([string]$Dir, [string]$ExeName) {
  $web = @"
@echo off
cd /d "%~dp0"
start "" "%~dp0$ExeName"
"@
  $desk = @"
@echo off
cd /d "%~dp0"
start "" "%~dp0$ExeName" --ui
"@
  Set-Content -Path (Join-Path $Dir "start_web.bat") -Value $web -Encoding ASCII
  Set-Content -Path (Join-Path $Dir "start_desktop.bat") -Value $desk -Encoding ASCII
}

function New-ConfigScanZip([string]$Dir, [string]$Stamp) {
  $zipPath = Join-Path $script:Out ("ConfigScan-" + $Stamp + ".zip")
  if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($Dir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
  return $zipPath
}

function Assert-LastExit([string]$Step) {
  if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE)" }
}

function Test-PythonModule([string]$Python, [string]$Name) {
  & $Python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$Name') else 1)"
  return ($LASTEXITCODE -eq 0)
}

function Get-PipScript {
  $getPip = Join-Path $Build "get-pip.py"
  if (-not (Test-Path $getPip)) {
    Write-Host "[build] downloading get-pip.py"
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing
  }
  return $getPip
}

function Install-PipInto([string]$Python) {
  $getPip = Get-PipScript
  Write-Host "[build] bootstrapping pip into $Python"
  & $Python $getPip --no-warn-script-location
  Assert-LastExit "get-pip ($Python)"
}

$Build = Join-Path $Root "build"
$Cpython = Join-Path $Build "cpython"
$PackVenv = Join-Path $Build "packvenv"
$PyExe = Join-Path $Cpython "python.exe"
$script:VenvPy = Join-Path $PackVenv "Scripts\python.exe"
$script:Out = Join-Path $Root "dist"
$script:Work = Join-Path $Build "pyi"
$ver = "3.12.8"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

New-Item -ItemType Directory -Force -Path $Build, $script:Out, $script:Work | Out-Null

$baseCheck = $null

if (-not (Test-Path $PyExe)) {
  $zip = Join-Path $Build "python-$ver-embed-amd64.zip"
  $url = "https://www.python.org/ftp/python/$ver/python-$ver-embed-amd64.zip"
  Write-Host "[build] downloading embeddable $url"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  if (Test-Path $Cpython) { Remove-Item -Recurse -Force $Cpython }
  New-Item -ItemType Directory -Force -Path $Cpython | Out-Null
  Expand-Archive -Path $zip -DestinationPath $Cpython -Force
  $pth = Get-ChildItem $Cpython -Filter "python*._pth" | Select-Object -First 1
  if ($pth) {
    $text = Get-Content $pth.FullName -Raw
    if ($text -notmatch "(?m)^import site\s*$") {
      $text = $text -replace "(?m)^#import site\s*$", "import site"
      if ($text -notmatch "(?m)^import site\s*$") { $text = $text.TrimEnd() + "`r`nimport site`r`n" }
    }
    if ($text -notmatch "Lib\\site-packages") {
      $text = $text.TrimEnd() + "`r`nLib\\site-packages`r`n"
    }
    Set-Content -Path $pth.FullName -Value $text -Encoding ASCII
  }
  $getPip = Join-Path $Build "get-pip.py"
  Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing
  & $PyExe $getPip --no-warn-script-location
  if ($LASTEXITCODE -ne 0) { throw "get-pip failed" }
}

$basePrefix = & $PyExe -c "import sys; print(sys.base_prefix)"
if (Test-IsCondaPrefix $basePrefix) {
  throw "Refuse conda/miniconda prefix: $basePrefix"
}

# %LOCALAPPDATA%\pypa\virtualenv is not writable here (WinError 5). Keep
# virtualenv's app-data inside the project, and do not seed pip from that cache.
$env:VIRTUALENV_APP_DATA = Join-Path $Build "virtualenv-appdata"
New-Item -ItemType Directory -Force -Path $env:VIRTUALENV_APP_DATA | Out-Null

$venvBroken = (Test-Path $script:VenvPy) -and -not (Test-PythonModule $script:VenvPy "pip")
if ($venvBroken) {
  Write-Host "[build] packvenv has no pip; removing the failed environment"
  Remove-Item -Recurse -Force $PackVenv
}

if (-not (Test-Path $script:VenvPy)) {
  Write-Host "[build] creating packvenv without the user virtualenv wheel cache"
  & $PyExe -m pip install -U pip setuptools wheel virtualenv --no-warn-script-location
  Assert-LastExit "install virtualenv"
  & $PyExe -m virtualenv --without-pip --app-data $env:VIRTUALENV_APP_DATA $PackVenv
  Assert-LastExit "virtualenv"
  if (-not (Test-Path $script:VenvPy)) { throw "packvenv python missing: $script:VenvPy" }
  Install-PipInto $script:VenvPy
}

Write-Host "[build] pip install deps ($script:VenvPy)"
& $script:VenvPy -m pip install -U pip setuptools wheel pillow --no-warn-script-location
Assert-LastExit "pip install pillow"
& $script:VenvPy -m pip install -e "$Root" --no-warn-script-location
Assert-LastExit "pip install host"
& $script:VenvPy -m pip install "pyinstaller>=6.3" "PyQtWebEngine>=5.15" --no-warn-script-location
Assert-LastExit "pip install pyinstaller"

$ico = Join-Path $Root "packaging\config-scan.ico"
& $script:VenvPy -c @"
from PIL import Image, ImageDraw
p = r'$ico'
img = Image.new('RGBA', (256, 256), (11, 16, 24, 255))
d = ImageDraw.Draw(img)
d.rounded_rectangle((16, 16, 240, 240), radius=36, outline=(61, 214, 198, 255), width=10)
d.ellipse((168, 168, 210, 210), fill=(240, 180, 41, 255))
img.save(p, sizes=[(16, 16), (32, 32), (48, 48), (256, 256)])
"@
if ($LASTEXITCODE -ne 0) { throw "icon generation failed" }

Stop-ConfigScanSafe
Invoke-PyInstaller -Mode "onefile" -Stamp $Stamp
$oneExe = Join-Path $script:Out ("ConfigScan-" + $Stamp + ".exe")
New-LaunchBats -Dir $script:Out -ExeName ("ConfigScan-" + $Stamp + ".exe")
$oneOk = Test-Deliverable -ExePath $oneExe
if ($oneOk) {
  Write-Host "[build] DONE (onefile) -> $oneExe"
  Write-Host "Double-click start_web.bat in dist\ for the browser. start_desktop.bat adds --ui."
  exit 0
}

Write-Warning "[build] onefile smoke failed — falling back to flat onedir + zip"
Stop-ConfigScanSafe
Invoke-PyInstaller -Mode "onedir" -Stamp $Stamp
$Dir = Join-Path $script:Out "ConfigScan"
if (-not (Test-Path (Join-Path $Dir "ConfigScan.exe"))) {
  throw "missing dist/ConfigScan/ConfigScan.exe after onedir build"
}
if (Test-Path (Join-Path $Dir "_internal")) {
  throw "onedir contains _internal"
}
New-LaunchBats -Dir $Dir -ExeName "ConfigScan.exe"
$zipOut = New-ConfigScanZip -Dir $Dir -Stamp $Stamp
Write-Host "[build] DONE (zip) -> $zipOut"
Write-Host "Deliver the zip. Extract, then run start_web.bat (browser) or start_desktop.bat (PyQt)."
