<#
.SYNOPSIS
    Install UFS Filesystem Driver on Windows 10/11

.DESCRIPTION
    Installs the UFS IFS driver with optional EV certificate signing.
    Supports installation via MSI, INF, or manual driver installation.

.PARAMETER MsiPath
    Path to UFS MSI installer (preferred method)

.PARAMETER InfPath
    Path to UFS INF file (fallback method)

.PARAMETER SignCertificate
    Path to EV code signing certificate (.pfx)

.PARAMETER CertificatePassword
    Password for the signing certificate

.PARAMETER TimestampServer
    RFC3161 timestamp server URL (default: http://timestamp.digicert.com)

.PARAMETER Force
    Skip confirmation prompts

.PARAMETER Uninstall
    Remove UFS driver instead of installing

.EXAMPLE
    .\Install-UFS.ps1 -MsiPath "UFS-1.0.0.msi"

.EXAMPLE
    .\Install-UFS.ps1 -InfPath "ufs.inf" -SignCertificate "cert.pfx" -CertificatePassword "secret"

.EXAMPLE
    .\Install-UFS.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [Parameter(ParameterSetName='MSI')]
    [string]$MsiPath = "UFS-1.0.0.msi",

    [Parameter(ParameterSetName='INF')]
    [string]$InfPath = "ufs.inf",

    [Parameter(ParameterSetName='INF')]
    [string]$SignCertificate,

    [Parameter(ParameterSetName='INF')]
    [securestring]$CertificatePassword,

    [string]$TimestampServer = "http://timestamp.digicert.com",

    [switch]$Force,

    [switch]$Uninstall
)

# Require Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script requires Administrator privileges. Re-run PowerShell as Administrator."
    exit 1
}

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-DriverSignature {
    param([string]$DriverPath)

    if (-not (Test-Path $DriverPath)) {
        Write-Log "Driver not found: $DriverPath" "ERROR"
        return $false
    }

    $sig = Get-AuthenticodeSignature $DriverPath
    if ($sig.Status -eq "Valid") {
        Write-Log "Driver signature: VALID ($($sig.SignerCertificate.Subject))" "SUCCESS"
        return $true
    } elseif ($sig.Status -eq "NotSigned") {
        Write-Log "Driver is NOT signed" "WARN"
        return $false
    } else {
        Write-Log "Driver signature: $($sig.Status) - $($sig.StatusMessage)" "ERROR"
        return $false
    }
}

function Sign-Driver {
    param(
        [string]$DriverPath,
        [string]$CertPath,
        [securestring]$CertPassword,
        [string]$TimestampUrl
    )

    if (-not (Test-Path $CertPath)) {
        Write-Log "Certificate not found: $CertPath" "ERROR"
        return $false
    }

    Write-Log "Signing driver: $DriverPath"
    $pwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword))

    $signTool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe"
    if (-not (Test-Path $signTool)) {
        $signTool = "signtool.exe"  # Assume in PATH
    }

    $args = @(
        "sign",
        "/f", $CertPath,
        "/p", $pwd,
        "/tr", $TimestampUrl,
        "/td", "SHA256",
        "/fd", "SHA256",
        "/d", "UFS Filesystem Driver",
        "/du", "https://ufs.example.com",
        $DriverPath
    )

    $result = & $signTool $args
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Driver signed successfully" "SUCCESS"
        return $true
    } else {
        Write-Log "Signing failed: $result" "ERROR"
        return $false
    }
}

function Create-Catalog {
    param([string]$InfPath, [string]$OutputDir)

    Write-Log "Creating catalog file..."
    $inf2cat = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\inf2cat.exe"
    if (-not (Test-Path $inf2cat)) {
        $inf2cat = "inf2cat.exe"
    }

    $args = @(
        "/driver:" + (Split-Path $InfPath -Parent),
        "/os:10_X64,10_ARM64,Server10_X64,Server10_ARM64"
    )

    $result = & $inf2cat $args
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Catalog created successfully" "SUCCESS"
        return $true
    } else {
        Write-Log "Catalog creation failed: $result" "WARN"
        return $false
    }
}

function Install-ViaMsi {
    param([string]$MsiPath, [switch]$Uninstall)

    if (-not (Test-Path $MsiPath)) {
        Write-Log "MSI not found: $MsiPath" "ERROR"
        return $false
    }

    if ($Uninstall) {
        Write-Log "Uninstalling UFS via MSI..."
        $result = msiexec.exe /x $MsiPath /qn /norestart
    } else {
        Write-Log "Installing UFS via MSI..."
        $result = msiexec.exe /i $MsiPath /qn /norestart
    }

    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {  # 3010 = reboot required
        Write-Log "MSI $($Uninstall ? 'uninstall' : 'install') complete" "SUCCESS"
        if ($LASTEXITCODE -eq 3010) {
            Write-Log "REBOOT REQUIRED" "WARN"
        }
        return $true
    } else {
        Write-Log "MSI $($Uninstall ? 'uninstall' : 'install') failed with exit code $LASTEXITCODE" "ERROR"
        return $false
    }
}

function Install-ViaInf {
    param([string]$InfPath, [switch]$Uninstall)

    if (-not (Test-Path $InfPath)) {
        Write-Log "INF not found: $InfPath" "ERROR"
        return $false
    }

    $pnputil = "pnputil.exe"

    if ($Uninstall) {
        Write-Log "Uninstalling UFS via INF..."
        # Find the published driver
        $drivers = pnputil.exe /enum-drivers | Select-String "ufs"
        if ($drivers) {
            $oids = $drivers | ForEach-Object { $_ -match "Published Name :\s*(oem\d+\.inf)" } | ForEach-Object { $matches[1] }
            foreach ($oid in $oids) {
                $result = & $pnputil /delete-driver $oid /uninstall /force
            }
        }
        Write-Log "INF uninstall complete" "SUCCESS"
        return $true
    } else {
        Write-Log "Installing UFS via INF..."
        $result = & $pnputil /add-driver $InfPath /install
        if ($LASTEXITCODE -eq 0) {
            Write-Log "INF install complete" "SUCCESS"
            return $true
        } else {
            Write-Log "INF install failed: $result" "ERROR"
            return $false
        }
    }
}

function Verify-Installation {
    Write-Log "Verifying UFS installation..."

    # Check if driver service exists
    $service = Get-Service -Name "ufs" -ErrorAction SilentlyContinue
    if ($service) {
        Write-Log "UFS service found: $($service.Status)" "SUCCESS"
    } else {
        Write-Log "UFS service NOT found" "WARN"
    }

    # Check driver in DriverStore
    $driver = pnputil.exe /enum-drivers | Select-String "ufs"
    if ($driver) {
        Write-Log "UFS driver found in DriverStore" "SUCCESS"
    } else {
        Write-Log "UFS driver NOT in DriverStore" "WARN"
    }

    # Try to load
    $loaded = Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -eq "ufs" }
    if ($loaded) {
        Write-Log "UFS driver loaded: $($loaded.State)" "SUCCESS"
    }
}

# Main
Write-Log "=== UFS Windows Installer ==="

if ($Uninstall) {
    if (-not $Force) {
        $confirm = Read-Host "Uninstall UFS driver? (y/N)"
        if ($confirm -notmatch '^y$') {
            Write-Log "Aborted"
            exit 0
        }
    }

    if (Test-Path $MsiPath) {
        Install-ViaMsi -MsiPath $MsiPath -Uninstall
    } else {
        Install-ViaInf -InfPath $InfPath -Uninstall
    }

    Verify-Installation
    Write-Log "Uninstall complete"
    exit 0
}

# Install
if (Test-Path $MsiPath) {
    Write-Log "Found MSI installer: $MsiPath"
    if (-not $Force) {
        $confirm = Read-Host "Install UFS via MSI? (y/N)"
        if ($confirm -notmatch '^y$') {
            Write-Log "Aborted"
            exit 0
        }
    }
    Install-ViaMsi -MsiPath $MsiPath
}
elseif (Test-Path $InfPath) {
    Write-Log "Found INF installer: $InfPath"

    # Sign if certificate provided
    if ($SignCertificate) {
        $driverDir = Split-Path $InfPath -Parent
        $sysFile = Join-Path $driverDir "x64\Release\ufs.sys"
        if (Test-Path $sysFile) {
            Sign-Driver -DriverPath $sysFile -CertPath $SignCertificate -CertPassword $CertificatePassword -TimestampUrl $TimestampServer
            Create-Catalog -InfPath $InfPath -OutputDir $driverDir
        }
    }

    if (-not $Force) {
        $confirm = Read-Host "Install UFS via INF? (y/N)"
        if ($confirm -notmatch '^y$') {
            Write-Log "Aborted"
            exit 0
        }
    }
    Install-ViaInf -InfPath $InfPath
}
else {
    Write-Log "No installer found (MSI or INF)" "ERROR"
    exit 1
}

Verify-Installation
Write-Log "=== Installation Complete ==="