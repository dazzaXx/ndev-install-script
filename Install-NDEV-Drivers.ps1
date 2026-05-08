#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Install-NDEV-Drivers.ps1
    Installs the Nintendo NDEV (Wii devkit) USB drivers on 64-bit Windows 10/11
    by self-signing the driver catalog.

    See HOW-IT-WORKS.txt for a plain-language explanation of what this does.
#>

[CmdletBinding()]
param(
    [string]$BundleRoot = '',
    [string]$WorkDir    = ''
)

$ErrorActionPreference = 'Stop'

# Resolve script directory robustly. $PSScriptRoot is normally set when
# invoked via `powershell -File`, but we've seen edge cases where it isn't,
# so fall through several alternatives.
if (-not $BundleRoot) {
    if ($PSScriptRoot) {
        $BundleRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $BundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $BundleRoot = (Get-Location).Path
    }
}
if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP 'NDEV-Drivers-Signed'
}

function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok  ($m) { Write-Host "    OK: $m"            -ForegroundColor Green }
function Write-Warn($m) { Write-Host "    !  $m"             -ForegroundColor Yellow }

Write-Host "================================================================"
Write-Host " NDEV Wii Devkit Driver Installer (self-signed)"
Write-Host "================================================================"

# ----- Sanity checks ---------------------------------------------------------
Write-Step "Checking environment"

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "This bundle ships the 64-bit drivers; this OS is 32-bit."
}
Write-Ok "64-bit Windows"

$srcDrivers = Join-Path $BundleRoot 'drivers'
if (-not (Test-Path $srcDrivers)) {
    throw "Driver folder not found at: $srcDrivers`nExtract the whole bundle and re-run."
}

$required = @(
    'DITOUSB2.inf','EXITOUSB2.inf',
    'DITOUSB2.dll','EXITOUSB2.dll',
    'WdfCoInstaller01007.dll','WinUSBCoInstaller.dll','WUDFUpdate_01007.dll',
    'DPInst.exe'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $srcDrivers $f))) {
        throw "Missing required file: drivers\$f"
    }
}
Write-Ok "All driver files present"

# ----- Stage a working copy --------------------------------------------------
Write-Step "Staging working copy at $WorkDir"
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
Copy-Item $srcDrivers $WorkDir -Recurse
Write-Ok "Copied driver files"

# ----- Patch INFs to reference our catalog -----------------------------------
Write-Step "Patching INF files to reference ndev.cat"
foreach ($inf in 'DITOUSB2.inf','EXITOUSB2.inf') {
    $path = Join-Path $WorkDir $inf
    $text = [IO.File]::ReadAllText($path)

    if ($text -match 'CatalogFile=ndev\.cat') {
        Write-Warn "$inf already patched (continuing)"
        continue
    }
    if ($text -notmatch ';CatalogFile=wudf\.cat') {
        throw "Could not find ';CatalogFile=wudf.cat' line in $inf"
    }

    $text = $text -replace ';CatalogFile=wudf\.cat', 'CatalogFile=ndev.cat'
    [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII)
    Write-Ok "$inf patched"
}

# ----- Self-signed code-signing cert -----------------------------------------
Write-Step "Creating self-signed code-signing certificate"
$certSubject = "CN=NDEV Driver Bundle (Self-Signed)"
$cert = New-SelfSignedCertificate `
    -Type             CodeSigningCert `
    -Subject          $certSubject `
    -KeyUsage         DigitalSignature `
    -KeyAlgorithm     RSA `
    -KeyLength        2048 `
    -HashAlgorithm    SHA256 `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter         (Get-Date).AddYears(10)
Write-Ok "Cert thumbprint: $($cert.Thumbprint)"

# ----- Trust the cert system-wide --------------------------------------------
Write-Step "Installing certificate into Trusted Root and Trusted Publisher"
foreach ($storeName in 'Root','TrustedPublisher') {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store $storeName, 'LocalMachine'
    $store.Open('ReadWrite')
    $store.Add($cert)
    $store.Close()
    Write-Ok "Added to LocalMachine\$storeName"
}

# ----- Build the catalog ------------------------------------------------------
Write-Step "Generating ndev.cat"
$catPath = Join-Path $WorkDir 'ndev.cat'
$filesToHash = @(
    'DITOUSB2.inf','EXITOUSB2.inf',
    'DITOUSB2.dll','EXITOUSB2.dll',
    'WdfCoInstaller01007.dll','WinUSBCoInstaller.dll','WUDFUpdate_01007.dll'
) | ForEach-Object { Join-Path $WorkDir $_ }

# Pass an explicit file list so the catalog doesn't try to hash itself.
New-FileCatalog -Path $filesToHash -CatalogFilePath $catPath -CatalogVersion 2.0 | Out-Null
Write-Ok "Catalog created ($((Get-Item $catPath).Length) bytes)"

# ----- Sign the catalog -------------------------------------------------------
Write-Step "Signing catalog"
$sig = Set-AuthenticodeSignature -FilePath $catPath -Certificate $cert -HashAlgorithm SHA256
if ($sig.Status -ne 'Valid') {
    throw "Catalog signature status: $($sig.Status) - $($sig.StatusMessage)"
}
Write-Ok "Catalog signed (status: Valid)"

# ----- Patch dpinst.xml for system language -----------------------------------
Write-Step "Checking dpinst.xml for system language compatibility"
$dpinstXml = Join-Path $WorkDir 'dpinst.xml'
if (Test-Path $dpinstXml) {
    $uiCulture = [System.Globalization.CultureInfo]::CurrentUICulture
    $lcid      = $uiCulture.LCID
    $lcidHex   = '0x{0:X4}' -f $lcid

    $xml = New-Object System.Xml.XmlDocument; $xml.Load($dpinstXml)
    $langNodes = $xml.SelectNodes('//language')

    $match = $langNodes | Where-Object {
        $_.GetAttribute('code') -eq $lcidHex
    } | Select-Object -First 1

    if ($match) {
        Write-Ok "Language $lcidHex ($($uiCulture.Name)) already present in dpinst.xml"
    } else {
        Write-Warn "Language $lcidHex ($($uiCulture.Name)) not found in dpinst.xml - patching"

        # Prefer English (0x0409) as the template; fall back to the first entry
        $template = ($langNodes | Where-Object { $_.GetAttribute('code') -eq '0x0409' } | Select-Object -First 1)
        if (-not $template) { $template = $langNodes | Select-Object -First 1 }

        if ($template) {
            $newLang = $template.CloneNode($true)
            $newLang.SetAttribute('code', $lcidHex)
            $xml.DocumentElement.AppendChild($newLang) | Out-Null
            try {
                $xml.Save($dpinstXml)
                Write-Ok "Added language $lcidHex to dpinst.xml (cloned from $($template.GetAttribute('code')))"
            } catch {
                Write-Warn "Could not save patched dpinst.xml: $_"
                Write-Warn "DPInst may silently fail if language $lcidHex is not listed"
            }
        } else {
            Write-Warn "dpinst.xml contains no <language> nodes - cannot patch; DPInst may silently fail"
        }
    }
} else {
    Write-Ok "No dpinst.xml in working copy - DPInst will use built-in defaults"
}

# ----- Run DPInst -------------------------------------------------------------
Write-Step "Running DPInst.exe to install drivers"
$dpinst = Join-Path $WorkDir 'DPInst.exe'
$p = Start-Process -FilePath $dpinst `
    -ArgumentList '/Q','/SW','/SA','/SE','/LM','/F' `
    -Wait -PassThru -NoNewWindow -WorkingDirectory $WorkDir
$ec = $p.ExitCode

# DPInst exit code is a bitmask:
#   bit 31         (0x80000000) = fatal error
#   bits 0-6       drivers that could NOT be installed
#   bits 8-14      drivers added to store but not installed (no matching device)
#   bits 16-22     drivers installed on a device
$fatal       = ($ec -band 0x80000000) -ne 0
$failed      =  ($ec -band 0x0000007F)
$inStoreOnly = (($ec -band 0x00007F00) -shr 8)
$installed   = (($ec -band 0x007F0000) -shr 16)

Write-Host ("    DPInst exit code           : 0x{0:X8}" -f $ec)
Write-Host  "    Drivers installed on device: $installed"
Write-Host  "    Drivers added to store only: $inStoreOnly"
Write-Host  "    Drivers that failed to add : $failed"

# ----- Verify -----------------------------------------------------------------
Write-Step "Verifying drivers landed in the Windows driver store"
$enum = (& pnputil /enum-drivers) -join "`n"
$found = $enum -match 'DITOUSB|EXITOUSB|Nintendo'

if ($found) {
    Write-Ok "NDEV drivers are present in the driver store."
} else {
    Write-Warn "NDEV drivers NOT found in driver store - install may have failed."
    Write-Warn "Check setupapi log: notepad C:\Windows\INF\setupapi.dev.log"
    if ($fatal -and $installed -eq 0 -and $inStoreOnly -eq 0) { exit 1 }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " DONE." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Plug in the NDEV devkit and turn it on - Windows will bind the"
Write-Host "drivers to USB devices VID_057E&PID_0301 and VID_057E&PID_0302"
Write-Host "automatically."
Write-Host ""
Write-Host "Working copy preserved at: $WorkDir"
Write-Host "Certificate thumbprint   : $($cert.Thumbprint)"
