# LHMService

A headless Windows service that wraps [LibreHardwareMonitorLib](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
and serves a live JSON snapshot of every hardware sensor on `http://localhost:8085`.
It runs at boot without a logged-in user and is polled by the Zabbix
**Template LHM Hardware Sensors** (kept in `zabbix-config`).

From v1.1.0 it uses LibreHardwareMonitorLib 0.9.6, which talks to hardware through the
signed **PawnIO** driver instead of WinRing0. WinRing0 is blocked by Microsoft's
vulnerable driver blocklist and flagged by Defender as `VulnerableDriver:WinNT/Winring0`.

## Install on an endpoint

Run as Administrator. Take the version and hash from the release's `SHA256SUMS.txt`.

```powershell
$v = '1.1.0'
Invoke-WebRequest "https://github.com/whizz-bang-technology/lhmservice/releases/download/v$v/Install-LHMService.ps1" -OutFile "$env:TEMP\Install-LHMService.ps1" -UseBasicParsing
& "$env:TEMP\Install-LHMService.ps1" -Version $v -Sha256 '<LHMService.exe sha256>'
```

The script is safe to re-run. It:

1. downloads `LHMService.exe` from the release and stops if the SHA256 doesn't match
2. installs PawnIO 2.2.0 from its official release if missing (pinned SHA256 + signer check)
3. removes the legacy `R0LHMService` WinRing0 driver left by older builds
4. installs or updates the `LibreHardwareMonitor` service, URL ACLs and EventLog source
5. starts the service and checks `/health` and `/api/hardware`

Exit codes: `0` OK, `3010` OK but reboot needed to finish WinRing0 removal (re-run after), `1` failed.
Log: `C:\ProgramData\LHMService\install.log`.

Options: `-Port`, `-PollInterval`, `-InstallDir`, `-ExePath` (install a local exe instead of downloading), `-SkipPawnIO`.

### Upgrading

Run the installer again with the new `-Version` and `-Sha256`. The previous exe is kept as
`LHMService.exe.previous`.

### Uninstall

```powershell
.\Uninstall-LHMService.ps1              # leaves PawnIO, which other tools may use
.\Uninstall-LHMService.ps1 -RemovePawnIO
```

## HTTP endpoints

| Path | Description |
|---|---|
| `GET /api/hardware` (also `/`, `/api`) | JSON array of hardware, each with `sensors` and `subHardware` |
| `GET /health` | `{"status":"ok"}` |

Sensor objects: `identifier`, `name`, `type`, `value`, `min`, `max`. Only `localhost` and
`127.0.0.1` are bound; nothing is exposed to the network.

### Identifier changes from 0.9.3 builds

LibreHardwareMonitorLib 0.9.5+ changed some identifiers. Zabbix LLD picks up the new ones
automatically and the old items expire after the discovery rule's lifetime (7 days):

- Network adapters: `/nic/{GUID}` → `/nic/%7BGUID%7D`
- Intel iGPU identifiers are URL-encoded
- Virtual memory moved from `/ram` to `/vram`; per-DIMM sensors appear under `/memory/dimm/N`
- NVMe and some storage sensors were renumbered

## Releasing

1. Update the code, merge to `main` (CI builds every push and PR).
2. Release it, any of these ways:
   - GitHub → Actions → **Build and release** → **Run workflow**, enter the version (e.g. `1.2.0`)
   - push a tag: `git tag v1.2.0 && git push origin v1.2.0`
   - create a release with a new `v1.2.0` tag in the GitHub UI (the workflow attaches the files)
3. The workflow builds on `windows-latest`, publishes a release containing `LHMService.exe`,
   `appsettings.json`, the install/uninstall scripts and `SHA256SUMS.txt`, and attaches a
   build provenance attestation to the exe. Check it with:
   `gh attestation verify LHMService.exe --repo whizz-bang-technology/lhmservice`
4. Test on a test machine, then update the version and hash in the rollout script.

## Building locally

```powershell
dotnet publish src/LHMService.csproj -c Release -o publish
```

Needs the .NET 8 SDK. The output is a self-contained single-file exe (~75 MB).

## Licences

LibreHardwareMonitorLib is MPL-2.0. PawnIO is distributed by its author under its own
licence and is downloaded from its official release, not redistributed here.
