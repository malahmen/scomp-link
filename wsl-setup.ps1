#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap script for gum-based tooling on Windows.
    Requires WSL to be installed with at least one distribution available.
    Delegates all bootstrapping to setup.sh inside WSL.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Helpers
function Write-Info  { param([string]$msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Fatal { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# Check WSL
Write-Info "Looking for WSL..."

$wslExe = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Fatal "WSL is not installed on this machine.
Please ask your administrator to enable WSL:
  https://learn.microsoft.com/en-us/windows/wsl/install"
}

$wslList = wsl.exe --list --quiet 2>&1
if ($LASTEXITCODE -ne 0 -or -not $wslList) {
    Write-Fatal "WSL is installed but no distributions are available.
Please install a WSL distribution (e.g. Ubuntu from the Microsoft Store):
  https://aka.ms/wslstore"
}

Write-Ok "WSL found with available distributions."

# Resolve setup.sh
$setupSh = Join-Path $scriptDir "setup.sh"
if (-not (Test-Path $setupSh)) {
    Write-Fatal "setup.sh not found next to wsl-setup.ps1 (expected: $setupSh)"
}

# Convert Windows path to WSL path (e.g. C:\foo\bar -> /mnt/c/foo/bar)
function ConvertTo-WslPath {
    param([string]$winPath)
    $winPath = $winPath.Replace("\", "/")
    if ($winPath -match "^([A-Za-z]):(.*)") {
        return "/mnt/" + $Matches[1].ToLower() + $Matches[2]
    }
    return $winPath
}

$wslSetupSh = ConvertTo-WslPath $setupSh

# Launch setup.sh inside WSL
Write-Info "Launching setup.sh inside WSL..."
wsl.exe bash -c "chmod +x '$wslSetupSh' && '$wslSetupSh'"

if ($LASTEXITCODE -ne 0) {
    Write-Fatal "setup.sh exited with code $LASTEXITCODE"
}