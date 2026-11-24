#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs or upgrades LHMService (LibreHardwareMonitor sensors as JSON on localhost)
    together with the PawnIO driver it needs, and removes the legacy WinRing0 driver.

.DESCRIPTION
    Safe to run repeatedly. Each run:
      1. Gets LHMService.exe, either from a GitHub release (-Version + -Sha256) or a local
         file (-ExePath), and refuses to continue if the SHA256 doesn't match.
      2. Installs PawnIO from its official release if it is missing or older than the
         pinned version, after checking the installer's SHA256 and Authenticode signer.
      3. Removes the WinRing0 driver registered by LHMService 0.9.4 and earlier
         (R0LHMService / *.sys in the install folder). Other software's WinRing0 is
         reported, not touched.
      4. Installs or updates the "LibreHardwareMonitor" service, URL ACLs and EventLog source.
      5. Starts the service and checks /health and /api/hardware.

    Exit codes: 0 = OK, 3010 = OK but a reboot is needed to finish WinRing0 removal,
    1 = failed.

.EXAMPLE
    # From a release (what the endpoint rollout does)
    .\Install-LHMService.ps1 -Version 1.1.0 -Sha256 <hash from SHA256SUMS.txt>

.EXAMPLE
    # From a local copy of the exe
    .\Install-LHMService.ps1 -ExePath .\LHMService.exe -Sha256 <hash>
#>
[CmdletBinding(DefaultParameterSetName = 'Release')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Release')]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [string] $ExePath,

    # Expected SHA256 of LHMService.exe. Mandatory for release downloads.
    [Parameter(Mandatory, ParameterSetName = 'Release')]
    [Parameter(ParameterSetName = 'Local')]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $Sha256,

    [string] $Repo         = 'whizz-bang-technology/lhmservice',
    [string] $InstallDir   = "$env:ProgramFiles\LHMService",
    [ValidateRange(1, 65535)] [int] $Port         = 8085,
    [ValidateRange(1, 3600)]  [int] $PollInterval = 5,
    [switch] $SkipPawnIO
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Pinned dependencies ────────────────────────────────────────────────────
# Update these together when moving to a new PawnIO release. The hash is the
# digest GitHub publishes on the release page for PawnIO_setup.exe.
$PawnIO = @{
    Version = [version]'2.2.0'
    Url     = 'https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe'
    Sha256  = '1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'
    Signer  = 'CN=namazso.eu'
}

$ServiceName  = 'LibreHardwareMonitor'
$DisplayName  = 'LibreHardwareMonitor Service'
$Description  = 'Headless hardware monitoring service powered by LibreHardwareMonitorLib.'
$ExeTarget    = Join-Path $InstallDir 'LHMService.exe'
$LegacyDrivers = @('R0LHMService')   # name LHM 0.9.x gave WinRing0 when hosted in LHMService.exe

$WorkDir = Join-Path $env:ProgramData 'LHMService'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Start-Transcript -Path (Join-Path $WorkDir 'install.log') -Append | Out-Null

$RebootRequired = $false

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "    $msg" }

function Get-Sha256($path) { (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToUpperInvariant() }

function Get-PawnIOVersion {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $entry = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
             Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'PawnIO' } |
             Select-Object -First 1
    if ($entry -and (Get-Service -Name PawnIO -ErrorAction SilentlyContinue)) {
        try { return [version]$entry.DisplayVersion } catch { return [version]'0.0' }
    }
    return $null
}

try {
    # ── 1. Get and verify LHMService.exe ───────────────────────────────────
    Write-Step 'Getting LHMService.exe'
    if ($PSCmdlet.ParameterSetName -eq 'Release') {
        $url    = "https://github.com/$Repo/releases/download/v$Version/LHMService.exe"
        $source = Join-Path $WorkDir "LHMService-$Version.exe"
        Write-Note "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $source -UseBasicParsing
    } else {
        $source = (Resolve-Path $ExePath).Path
        Write-Note "Using $source"
    }

    $actual = Get-Sha256 $source
    if ($Sha256) {
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            throw "SHA256 mismatch for LHMService.exe. Expected $($Sha256.ToUpperInvariant()), got $actual"
        }
        Write-Note "SHA256 verified ($actual)"
    } else {
        Write-Warning "No -Sha256 given; installing unverified local file ($actual)"
    }

    # ── 2. PawnIO ──────────────────────────────────────────────────────────
    if ($SkipPawnIO) {
        Write-Step 'Skipping PawnIO (-SkipPawnIO)'
    } else {
        Write-Step 'Checking PawnIO driver'
        $current = Get-PawnIOVersion
        if ($current -and $current -ge $PawnIO.Version) {
            Write-Note "PawnIO $current already installed"
        } else {
            Write-Note $(if ($current) { "Upgrading PawnIO $current -> $($PawnIO.Version)" } else { "Installing PawnIO $($PawnIO.Version)" })
            $setup = Join-Path $WorkDir "PawnIO_setup-$($PawnIO.Version).exe"
            if (-not (Test-Path $setup) -or (Get-Sha256 $setup) -ne $PawnIO.Sha256) {
                Invoke-WebRequest -Uri $PawnIO.Url -OutFile $setup -UseBasicParsing
            }
            if ((Get-Sha256 $setup) -ne $PawnIO.Sha256) { throw "PawnIO installer SHA256 mismatch" }
            $sig = Get-AuthenticodeSignature -FilePath $setup
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch [regex]::Escape($PawnIO.Signer)) {
                throw "PawnIO installer signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))"
            }
            $p = Start-Process -FilePath $setup -ArgumentList '-install', '-silent' -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "PawnIO installer exited with $($p.ExitCode)" }
            $current = Get-PawnIOVersion
            if (-not $current) { throw 'PawnIO did not register after install' }
            Write-Note "PawnIO $current installed"
        }
    }

    # ── 3. Stop LHMService before touching files or drivers ────────────────
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $installedHash = if (Test-Path $ExeTarget) { Get-Sha256 $ExeTarget } else { $null }
    $needsCopy = ($installedHash -ne $actual)

    if ($svc -and $svc.Status -ne 'Stopped' -and $needsCopy) {
        Write-Step 'Stopping service'
        Stop-Service -Name $ServiceName -Force
        (Get-Service $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }

    # ── 4. Remove legacy WinRing0 driver ───────────────────────────────────
    Write-Step 'Checking for legacy WinRing0 driver'
    $installDirPattern = [regex]::Escape($InstallDir.TrimEnd('\'))
    $drivers = Get-CimInstance Win32_SystemDriver |
               Where-Object { $LegacyDrivers -contains $_.Name -or ($_.PathName -and $_.PathName -match $installDirPattern) }
    foreach ($d in $drivers) {
        Write-Note "Removing driver service $($d.Name) ($($d.State)) -> $($d.PathName)"
        & sc.exe stop $d.Name | Out-Null
        & sc.exe delete $d.Name | Out-Null
    }
    Start-Sleep -Seconds 2
    foreach ($d in $drivers) {
        $still = Get-CimInstance Win32_SystemDriver -Filter "Name='$($d.Name)'" -ErrorAction SilentlyContinue
        if ($still -and $still.State -ne 'Stopped') {
            Write-Warning "$($d.Name) is still loaded; it will unload on the next reboot"
            $RebootRequired = $true
        }
    }
    if (Test-Path $InstallDir) {
        foreach ($sys in Get-ChildItem -Path $InstallDir -Filter *.sys -File) {
            try { Remove-Item $sys.FullName -Force; Write-Note "Deleted $($sys.FullName)" }
            catch { Write-Warning "Could not delete $($sys.FullName) (in use); re-run after reboot"; $RebootRequired = $true }
        }
    }
    $other = Get-CimInstance Win32_SystemDriver |
             Where-Object { $_.PathName -match 'WinRing0' -and $LegacyDrivers -notcontains $_.Name }
    foreach ($o in $other) {
        Write-Warning "Another WinRing0 driver is registered by other software: $($o.Name) -> $($o.PathName). Left in place."
    }
    if (-not $drivers) { Write-Note 'None found' }

    # ── 5. Files ───────────────────────────────────────────────────────────
    Write-Step 'Installing files'
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ($needsCopy) {
        if ($installedHash) { Copy-Item $ExeTarget "$ExeTarget.previous" -Force; Write-Note 'Previous exe kept as LHMService.exe.previous' }
        Copy-Item $source $ExeTarget -Force
        Write-Note "Installed $ExeTarget"
    } else {
        Write-Note 'LHMService.exe already up to date'
    }

    $settingsPath = Join-Path $InstallDir 'appsettings.json'
    $settings = [ordered]@{
        LHMService = [ordered]@{ Port = $Port; PollIntervalSeconds = $PollInterval }
        Logging    = [ordered]@{
            LogLevel = [ordered]@{ Default = 'Information'; 'Microsoft.Hosting.Lifetime' = 'Warning' }
            EventLog = [ordered]@{ LogLevel = [ordered]@{ Default = 'Information' } }
        }
    } | ConvertTo-Json -Depth 5
    $existing = if (Test-Path $settingsPath) { [string](Get-Content $settingsPath -Raw) } else { '' }
    $settingsChanged = ($existing.Trim() -ne $settings.Trim())
    if ($settingsChanged) {
        [IO.File]::WriteAllText($settingsPath, $settings, (New-Object Text.UTF8Encoding $false))
        Write-Note "Wrote appsettings.json (Port=$Port, PollIntervalSeconds=$PollInterval)"
    }

    # ── 6. Service registration ────────────────────────────────────────────
    Write-Step 'Configuring service'
    $binPath = "`"$ExeTarget`""
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        New-Service -Name $ServiceName -DisplayName $DisplayName -Description $Description `
                    -BinaryPathName $binPath -StartupType Automatic | Out-Null
        Write-Note 'Service created'
    } else {
        & sc.exe config $ServiceName binPath= $binPath start= auto | Out-Null
        & sc.exe description $ServiceName $Description | Out-Null
    }
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

    if (-not [Diagnostics.EventLog]::SourceExists('LibreHardwareMonitor')) {
        [Diagnostics.EventLog]::CreateEventSource('LibreHardwareMonitor', 'Application')
        Write-Note 'EventLog source created'
    }

    foreach ($u in "http://localhost:$Port/", "http://127.0.0.1:$Port/") {
        $show = & netsh http show urlacl url=$u 2>&1 | Out-String
        if ($show -notmatch [regex]::Escape($u)) {
            & netsh http add urlacl url=$u user='NT AUTHORITY\SYSTEM' | Out-Null
            Write-Note "URL ACL added: $u"
        }
    }

    # ── 7. Start and verify ────────────────────────────────────────────────
    Write-Step 'Starting service'
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -eq 'Running' -and $settingsChanged) { Restart-Service -Name $ServiceName -Force }
    elseif ($svc.Status -ne 'Running') { Start-Service -Name $ServiceName }

    $healthy = $false
    for ($i = 0; $i -lt 30 -and -not $healthy; $i++) {
        Start-Sleep -Seconds 2
        try { $healthy = ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 5).status -eq 'ok') } catch {}
    }
    if (-not $healthy) { throw "Service did not answer http://127.0.0.1:$Port/health within 60 seconds" }

    # First poll may still be in progress; give it one interval.
    Start-Sleep -Seconds ($PollInterval + 1)
    $hw = Invoke-RestMethod "http://127.0.0.1:$Port/api/hardware" -TimeoutSec 10
    function Measure-Sensors($items) { $n = 0; foreach ($h in $items) { $n += @($h.sensors).Count + (Measure-Sensors $h.subHardware) }; $n }
    function Measure-Temps($items) { $n = 0; foreach ($h in $items) { $n += @($h.sensors | Where-Object { $_.type -eq 'Temperature' -and $null -ne $_.value }).Count + (Measure-Temps $h.subHardware) }; $n }
    $sensors = Measure-Sensors $hw
    $temps   = Measure-Temps $hw

    $ver = (Get-Item $ExeTarget).VersionInfo.ProductVersion
    Write-Host ''
    Write-Host 'LHMService installed' -ForegroundColor Green
    Write-Note "Version      : $ver"
    Write-Note "SHA256       : $actual"
    Write-Note "Endpoint     : http://localhost:$Port/api/hardware"
    Write-Note "Sensors      : $sensors ($temps temperatures with values)"
    if (-not $SkipPawnIO -and $temps -eq 0) {
        Write-Warning 'No temperature readings. Check the PawnIO driver is running (sc.exe query PawnIO).'
    }
    if ($RebootRequired) {
        Write-Warning 'Reboot required to finish removing the WinRing0 driver. Re-run this script afterwards to clean up.'
        $code = 3010
    } else { $code = 0 }
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $code = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $code
