# dev-setup.ps1

Windows 11 (64-bit) port of [`dev-setup.sh`](README.md). Same idea, same shape
(step-by-step, asks before each one unless told otherwise, keeps going past a
failed step, safe to re-run) - built on [winget](https://learn.microsoft.com/windows/package-manager/winget/)
(Windows Package Manager) in place of `apt`.

- [Quick start](#quick-start)
- [Command-line usage](#command-line-usage)
- [Steps](#steps)
- [Settings file (`.env`)](#settings-file-env)
- [Elevation: remote_ssh and remote_rdp](#elevation-remote_ssh-and-remote_rdp)
- [What doesn't map 1:1 from Linux](#what-doesnt-map-11-from-linux)
- [Logs and re-running](#logs-and-re-running)

## Quick start

On a **new Windows machine** do not run `.\dev-setup.ps1` directly, the default
execution policy (`Restricted`) blocks it. Use the launcher (same flags as the
`.ps1`):

```bat
dev-setup.cmd -List
dev-setup.cmd -DryRun
dev-setup.cmd
```

Elevated (needed the first time for nvm, OpenSSH, RDP), accept the UAC prompt:

```bat
dev-setup-admin.cmd
dev-setup-admin.cmd -Only node_nvm
```

You can also double-click `dev-setup.cmd`. That is enough; you do not need to
sign the script or type `-ExecutionPolicy Bypass` yourself.

```powershell
# optional, after copy
Copy-Item .env-sample .env
notepad .env
```

Needs [winget](https://aka.ms/getwinget) (ships with Windows 11 by default as
"App Installer" - if missing, install it from the Microsoft Store).

### Why not code-sign the `.ps1`?

Authenticode signing needs a paid certificate (or an enterprise PKI). A
self-signed cert still has to be trusted on **each** new machine, which is the
same chicken-and-egg as execution policy. The `.cmd` launcher applies Bypass
to **this file only** and leaves your user/machine policy unchanged. If you
later want scripts to run without a launcher:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Command-line usage

```
dev-setup.cmd                    interactive: ask before each step
dev-setup.cmd -Yes                non-interactive: install everything
dev-setup.cmd -DryRun             dry-run: print what would happen, change nothing
dev-setup.cmd -Only a,b           only run the given step ids
dev-setup.cmd -Skip a,b           run everything except the given step ids
dev-setup.cmd -List               list step ids and exit
dev-setup.cmd -Help               help
dev-setup-admin.cmd               same, after a UAC elevation prompt
```

| Flag | Description |
|---|---|
| `-Yes` | Assume yes for every step. |
| `-DryRun` | Print every command each step *would* run, without executing anything. |
| `-Only a,b,c` | Run only the listed step ids, no confirmation prompts. |
| `-Skip a,b,c` | Run every step except the listed ids. Confirmation prompts still apply unless combined with `-Yes`. |
| `-Profile minimal` | Core toolchain only. |
| `-Profile server` | Skip GUI/comms/media apps (Windows Server / headless). |
| `-Profile desktop` | Full GUI set (default). |
| `-List` | Print step ids and descriptions, then exit. |
| `-Help` | Print a short usage summary and the step list, then exit. |

`$env:NO_COLOR=1` before running disables colored output.

## Steps

Run `.\dev-setup.ps1 -List` for the authoritative, current list. Highlights
that differ from the Ubuntu step set:

| id | Installs | Notes |
|---|---|---|
| `cpp_build` | CMake + Ninja + LLVM/clang + ccache + Code::Blocks (MinGW) | light path; replaces Linux `build-essential` |
| `cpp_msvc` | **Optional (default no):** VS 2022 Build Tools C++ workload + Windows SDK | multi-GB; only if you need `cl.exe` / Win32 SDK |
| `java_scala` | Temurin JDK (LTS) + sbt | sbt bootstraps the Scala compiler itself; no separate Scala install needed |
| `node_nvm` | nvm-windows + Node LTS | needs an **elevated** PowerShell the first time (`nvm use` creates a symlink). This pass imports `NVM_HOME` into PATH before installing global npm libraries. |
| `php` | PHP + Composer (installed the same signature-verified way as the Linux script) + Laravel installer | |
| `chatgpt` | ChatGPT desktop, via the Microsoft Store | OpenAI ships Windows builds through the Store only - no standalone `.exe` like the Linux `.deb` |
| `editor_pdf` | Notepad++ + SumatraPDF + MarkText | Free only, Sublime Text removed (paid evaluation) |
| `vnc_viewer` | TightVNC Viewer | Client machines. Alias: `rdp_client`. Built-in `mstsc` for RDP. RealVNC dropped (trial). |
| `media_apps` | Paint.NET, IrfanView + PlugIns, AIMP, K-Lite Mega | GUI media only (no Zoom) |
| `obs` | OBS Studio | Screen recording / streaming |
| `ai_media` | FFmpeg, ImageMagick, Poppler, QPDF, Tesseract, ocrmypdf | Free CLI for AI / image / video / PDF |
| `comms_zoom` | Zoom | Optional; ask yes/no on its own |
| `docker` | Docker Desktop | needs WSL2 enabled first - see below |
| `remote_ssh` | OpenSSH Server | **Never creates an OS user unless you confirm** after an existence check; needs elevation |
| `remote_rdp` | Windows Remote Desktop | Uses the account you confirmed (current login by default); needs elevation |
| `remote_vnc` | TightVNC Server | Server / share-this-desktop machines only; password from `.env`. Skip on viewer-only PCs |
| `win11_cleanup` | Remove consumer Store noise | News, Weather, Solitaire, Office Hub trial, WhatsApp, LinkedIn, TikTok, Xbox, Spotify, Clipchamp, Photos, … (does **not** remove Microsoft Teams, that is `comms_teams`) |
| `remote_rustdesk` | RustDesk for Windows | Resolved from GitHub releases the same way as the Linux `.deb` |
| `battery_charge_limit` | Battery wear report + the free charge-limit tool for your vendor | Windows has no generic charge-threshold API; offers to install G-Helper / Vantage / Dell Optimizer / MSI Center, or points at the UEFI setting |
| `power_management` | Ultimate Performance | **Never turn off screen** (AC+DC), never sleep/hibernate, screensaver off, Fast Startup off |
| `desktop_prefs` | Desk appearance | Timezone from `TIMEZONE`, dark mode, **Night Light all day at 20% warm**, solid wallpaper, **local-only Start search**, **Smart App Control Off**, widgets/News/Game Bar/Spotlight/Copilot/Recall off |
| `perf_tuning` | NTFS last-access + Power Throttling off | Defender exclusions are printed, not applied |
| `pin_apps` | Start Menu shortcuts + best-effort taskbar layout | Windows 11 has no supported taskbar-pin API |

Not present on Windows (no equivalent step): `archive_tools` installs 7-Zip
only (Windows' built-in zip support covers the rest); there's no
`comms_teams`-vs-`teams-for-linux` split (`Microsoft.Teams` is the real app).

## Settings file (`.env`)

Uses the **same `.env` file and format** as `dev-setup.sh` - copy
`.env-sample`, fill in what you need. Same rules apply: never required, never
sourced/executed (strict `KEY=VALUE` parsing, only known keys read), never
uploaded anywhere. On Windows the lock-down step uses `icacls` instead of
`chmod 600` to restrict the file to your account.

Keys that behave differently here:

| Key | Windows behavior |
|---|---|
| `REMOTE_USER` / `REMOTE_PASSWORD` | Printed with an exists/not-exists check, then **asked `[y/N]`** before creating or resetting a local account. `-Yes` never creates/resets OS logins (uses the current user). TightVNC uses `REMOTE_PASSWORD` as the VNC password only. |
| `TIMEZONE` | Windows tzutil id, e.g. `Romance Standard Time`. Empty leaves the clock alone. |
| `RUSTDESK_WAYLAND_PREVIEW` | Ignored - Wayland/GNOME-specific, not applicable on Windows. |
| `PIN_*` | All 14 flags are wired up on Windows now (VS Code, Cursor, ChatGPT, Chrome, LibreOffice, Postman, `PIN_REMMINA`→TightVNC Viewer, Slack, Teams, Notion, Pumble, Linear, Clockify, `PIN_EDITOR_PDF`→Notepad++ + SumatraPDF + MarkText) - each drives both a Start Menu shortcut and a taskbar-layout pin entry. |

## Elevation: remote_ssh, remote_rdp, desktop_prefs (search policy)

`remote_ssh` and `remote_rdp` change Windows security-relevant settings (a
listening service + an inbound firewall rule). They check `Test-Admin` and
refuse to do anything if the shell isn't elevated, rather than silently
skipping. `desktop_prefs` still applies per-user Search/appearance keys without
elevation; the machine-wide "no web search" policies (`DisableWebSearch`,
`ConnectedSearchUseWeb`, `DisableSearchBoxSuggestions`) need Administrator so
Start stays local-only for every account.

```powershell
# Right-click PowerShell -> Run as administrator, then:
.\dev-setup.ps1 -Only remote_ssh,remote_rdp,desktop_prefs
```

## What doesn't map 1:1 from Linux

- **C++ toolchains are split.** `cpp_build` is the light default: CMake, Ninja,
  LLVM/clang, ccache, and Code::Blocks with MinGW, enough for MinGW/clang
  projects without a Windows SDK. `cpp_msvc` is optional (prompt defaults to
  **N**; skipped under `-Yes` unless you pass `-Only cpp_msvc`) and installs
  Visual Studio 2022 Build Tools with the C++ workload + recommended
  components (MSVC/`cl.exe` and typically the Windows SDK, multi-GB).
- **Docker** needs WSL2. Enabling a Windows optional feature is itself a
  system-level change with a required reboot, so `docker` warns and tells you
  to run `wsl --install` yourself first rather than doing it silently.
- **Battery charge limiting** has no OS-level control on Windows (unlike
  Linux's `charge_control_end_threshold` sysfs file). The cap lives in the
  embedded controller, so it can only come from UEFI firmware or the vendor's
  own tool. `battery_charge_limit` reports cell wear, matches your
  manufacturer, and offers to install the free tool where one exists
  (G-Helper for ASUS, Lenovo Vantage or Legion Toolkit, Dell Optimizer, MSI
  Center); otherwise it names the exact UEFI/vendor-app setting. It will not
  install WinRing0-style EC-register tools - those need per-model register
  discovery and that driver is on Microsoft's vulnerable-driver blocklist.
  See [README.md](README.md#windows) for the full vendor table.
- **DWService's installer never exits** when its wizard closes: it unpacks a
  Python runtime, re-launches itself elevated, and leaves the agent's systray
  process holding the process tree open. `remote_dwservice` polls for the
  `DWAgent` service and its uninstall key instead of waiting on the process
  (interactive wizard only, silent install is not available for personal accounts).
- **`health_check` cannot upgrade an app while it is running.** An Inno
  Setup/NSIS installer replacing a running binary waits on a "close the
  application" prompt that `--silent` suppresses, so the upgrade hangs. Those
  packages are skipped with the reason named (close VS Code/Cursor/Chrome and
  re-run `-Only health_check`), and every upgrade has a 15-minute timeout.
- **Taskbar pinning** has no supported scripting API since Windows 10 1809
  (Microsoft closed the old shell verb to stop adware abuse - confirmed
  directly: `Shell.Application`'s verb list for an installed app exposes
  "Pin to Start" but no "Pin to taskbar" at all). `pin_apps` always creates
  Start Menu shortcuts (fully reliable) and additionally writes a taskbar
  layout XML using Microsoft's own provisioning schema, applied outside its
  normal enterprise deployment path - a best-effort, unsupported use of a
  supported file format that needs a sign-out/sign-in (or `explorer.exe`
  restart) to apply, and isn't guaranteed on every Windows 11 build.
- **inotify/swappiness/zram tuning** has no Windows equivalent; `perf_tuning`
  only prints the closest available win (Defender exclusions for your repo
  folders) instead of applying it, since that's a real AV-coverage trade-off.

## Logs and re-running

Every run writes a timestamped log to `%USERPROFILE%\dev-setup-logs\`. Steps
are independent and safe to re-run individually - installed tools are
detected via `winget list --id` and skipped, not reinstalled. Downloaded
installers land in `%USERPROFILE%\Downloads`, matching the Linux script's
`~/Downloads` convention.

A run with failures exits non-zero and prints the exact `-Only` line to retry
just those steps, so the `.cmd` launchers and CI can tell a clean run from a
partial one without scraping the log.
