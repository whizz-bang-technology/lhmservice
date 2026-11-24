#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes LHMService. PawnIO is left installed unless -RemovePawnIO is given,
    because other software (e.g. FanControl, LibreHardwareMonitor GUI) may use it.
#>
[CmdletBinding()]
param(
    [int]    $Port       = 8085,
    [string] $InstallDir = "$env:ProgramFiles\LHMService",
    [switch] $KeepFiles,
    [switch] $RemovePawnIO
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ServiceName = 'LibreHardwareMonitor'

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $ServiceName | Out-Null
    Write-Host 'Service removed'
} else {
    Write-Host 'Service not found'
}

foreach ($u in "http://localhost:$Port/", "http://127.0.0.1:$Port/") {
    & netsh http delete urlacl url=$u 2>&1 | Out-Null
}
Write-Host 'URL ACLs removed'

if ([Diagnostics.EventLog]::SourceExists('LibreHardwareMonitor')) {
    [Diagnostics.EventLog]::DeleteEventSource('LibreHardwareMonitor')
    Write-Host 'EventLog source removed'
}

# Legacy WinRing0 driver from LHMService 0.9.4 and earlier
if (Get-CimInstance Win32_SystemDriver -Filter "Name='R0LHMService'" -ErrorAction SilentlyContinue) {
    & sc.exe stop R0LHMService | Out-Null
    & sc.exe delete R0LHMService | Out-Null
    Write-Host 'Legacy R0LHMService driver removed (may need a reboot to unload)'
}

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
    Start-Sleep -Seconds 2
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Continue
    Write-Host "Deleted $InstallDir"
}

if ($RemovePawnIO) {
    $u = Join-Path $env:ProgramFiles 'PawnIO\uninstall.exe'
    if (Test-Path $u) {
        $p = Start-Process -FilePath $u -ArgumentList '-uninstall', '-silent' -Wait -PassThru
        Write-Host "PawnIO uninstaller exit code $($p.ExitCode)"
    } else { Write-Host 'PawnIO not installed' }
}

Write-Host 'Uninstall complete.' -ForegroundColor Green
