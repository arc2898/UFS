# UFS Windows Driver Build Setup
# Run in PowerShell as Administrator

#Requires -RunAsAdministrator

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "UFS Windows Driver Build Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$ErrorActionPreference = "Stop"

$UFS_ROOT = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ZIG_PROJECT = "$UFS_ROOT\core\zig"
$WDK_VERSION = "10.0.22621.2428"
$ZIG_VERSION = "0.13.0"  # Windows 11 22H2 WDK

# ============================================================================
# 1. INSTALL CHOCOLATEY (if not present)
# ============================================================================
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..." -ForegroundColor Yellow
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    refreshenv
}

# ============================================================================
# 2. INSTALL BUILD TOOLS
# ============================================================================
Write-Host "Installing build tools..." -ForegroundColor Yellow

choco install -y zig --version=$ZIG_VERSION --allow-downgrade
choco install -y \
    git \
    cmake \
    wget \
    7zip \
    visualstudio2022buildtools \
    --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

# Windows SDK
choco install -y windows-sdk-10-version-2004-all --version 10.0.19041.1

# WDK (requires manual download from Microsoft)
Write-Host "WDK must be downloaded manually from:" -ForegroundColor Yellow
Write-Host "https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk" -ForegroundColor Cyan
Write-Host "Download WDK $WDK_VERSION and run the installer" -ForegroundColor Yellow

# WiX Toolset for MSI
choco install -y wixtoolset

# ============================================================================
# 3. BUILD ZIG CORE
# ============================================================================
Write-Host "Building Zig core..." -ForegroundColor Yellow
Set-Location $ZIG_PROJECT
zig build -Doptimize=ReleaseFast

if (Test-Path "$ZIG_PROJECT\zig-out\lib\libufs_core.lib") {
    Write-Host "Zig core library built: $ZIG_PROJECT\zig-out\lib\libufs_core.lib" -ForegroundColor Green
} else {
    Write-Host "Zig core library not found!" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 4. PREPARE WINDOWS DRIVER BUILD
# ============================================================================
$WIN_DRIVER_DIR = "$ZIG_PROJECT\drivers\windows"

# Copy Zig library and headers
New-Item -ItemType Directory -Force -Path "$WIN_DRIVER_DIR\lib" | Out-Null
New-Item -ItemType Directory -Force -Path "$WIN_DRIVER_DIR\include" | Out-Null

Copy-Item "$ZIG_PROJECT\zig-out\lib\libufs_core.lib" "$WIN_DRIVER_DIR\lib\" -Force
Copy-Item "$ZIG_PROJECT\src\ufs.h" "$WIN_DRIVER_DIR\include\" -Force

# Generate .inf and .wxs paths for WiX
Write-Host "Windows driver files prepared in $WIN_DRIVER_DIR" -ForegroundColor Green

# ============================================================================
# 5. BUILD WITH MSVC (requires VS Developer Command Prompt)
# ============================================================================
Write-Host "To build the Windows IFS driver:" -ForegroundColor Yellow
Write-Host "1. Open 'Developer Command Prompt for VS 2022'" -ForegroundColor Cyan
Write-Host "2. Run: cd $WIN_DRIVER_DIR" -ForegroundColor Cyan
Write-Host "3. Run: nmake /f Makefile" -ForegroundColor Cyan
Write-Host "" -ForegroundColor Cyan
Write-Host "To build MSI installer:" -ForegroundColor Yellow
Write-Host "1. Ensure WiX is in PATH" -ForegroundColor Cyan
Write-Host "2. Run: candle.exe ufs.wxs" -ForegroundColor Cyan
Write-Host "3. Run: light.exe ufs.wixobj -ext WixUIExtension -o ufs.msi" -ForegroundColor Cyan

# ============================================================================
# 6. TEST SIGNING SETUP (for development)
# ============================================================================
Write-Host "For TEST signing (development only):" -ForegroundColor Yellow
Write-Host "bcdedit /set testsigning on" -ForegroundColor Cyan
Write-Host "Restart required" -ForegroundColor Cyan
Write-Host "" -ForegroundColor Cyan
Write-Host "For PRODUCTION signing (requires EV certificate):" -ForegroundColor Yellow
Write-Host "signtool sign /v /ac cross.cer /s My /n \"Your Company\" /t http://timestamp.digicert.com ufs.sys" -ForegroundColor Cyan

# ============================================================================
# 7. SUMMARY
# ============================================================================
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Windows Build Environment Prepared" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Key paths:" -ForegroundColor White
Write-Host "  UFS Root:       $UFS_ROOT" -ForegroundColor White
Write-Host "  Zig Project:    $ZIG_PROJECT" -ForegroundColor White
Write-Host "  Windows Driver: $WIN_DRIVER_DIR" -ForegroundColor White
Write-Host "  Zig Library:    $ZIG_PROJECT\zig-out\lib\libufs_core.lib" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Install WDK manually from Microsoft" -ForegroundColor White
Write-Host "  2. Open VS Developer Command Prompt" -ForegroundColor White
Write-Host "  3. Build driver with nmake" -ForegroundColor White
Write-Host "  4. Build MSI with WiX" -ForegroundColor White
Write-Host "  5. Sign with EV certificate for production" -ForegroundColor White