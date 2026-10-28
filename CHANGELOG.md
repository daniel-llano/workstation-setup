# Changelog

## 1.6.1

- **Timezone is opt-in:** `desktop_prefs` only changes the clock when `TIMEZONE` is set in `.env`. An empty value leaves the system timezone as it is.

## 1.6.0

- **Ubuntu apt locks / PackageKit:** stop `packagekit.service` (and apt-daily oneshots) before apt instead of killing PIDs or deleting lock files. Leave `unattended-upgrades` enabled. Interactive prompt can **mask** PackageKit if it keeps reclaiming locks; `.env` `PACKAGEKIT_MODE=auto|stop|mask|leave`.
- **Ubuntu power_management:** never `systemctl restart systemd-logind` while a graphical session is active (that killed GNOME/Wayland on Ubuntu 26). Write logind drop-in and apply on next login/reboot; softer idle-delay on Wayland (1h, not 0).
- **DWService Ubuntu:** always run `dwagent.sh -console` (GUI under sudo fails on Wayland); broader service detection; re-download corrupt installers.
- **DWService Windows:** `Unblock-File`, validate download size, launch with `-Verb RunAs` when not elevated, clearer SmartScreen/UAC guidance.

## 1.5.9

- **Night Light / blue-light filter (full day, 20% warm)** in `desktop_prefs` on Windows and Ubuntu. Windows writes the Night Light CloudStore schedule 00:00–23:45 + strength (~5440K). GNOME uses `night-light-*` gsettings for 0–24h. Override with `NIGHT_LIGHT_STRENGTH` in `.env` (0–100).

## 1.5.8

- **Teams missing after "successful" Windows install:** `win11_cleanup` was removing `MSTeams` / `MicrosoftTeams` Appx packages after `comms_teams` installed them, so Start search found nothing. Those IDs are no longer in the bloat list.
- **`comms_teams` hardened:** detect real presence via Appx/Start/`ms-teams.exe` (not winget list alone); prefer Microsoft Store product `XP8BT8DW290MPQ`, fall back to winget `Microsoft.Teams`, then try current-user Appx re-registration if the package is only staged machine-wide.

## 1.5.7

- **Apt/dpkg lock on Ubuntu:** identify holders (`fuser` / known apt frontends including `unattended-upgrade-shutdown`), show PID + cmdline, then prompt **[K]ill / [W]ait / [A]bort**. Kill uses `sudo` (password prompt). `-y` refuses to auto-kill and prints the `sudo kill` command. `psmisc` added to prereqs for `fuser`.
- **Windows installer busy:** same identify + **[K]/[W]/[A]** flow in `Wait-InstallerIdle` (msiexec / VS Installer / winget / Windows Update agents). Kill may elevate via UAC when not already Administrator.
- **MarkText** Markdown viewer/editor in `editor_pdf`, winget `MarkText.MarkText` on Windows; GitHub `.deb` (or local Downloads) on Ubuntu.

## 1.5.6

- **AI media/PDF CLI tools** (`ai_media`): FFmpeg, ImageMagick, Poppler (`pdftotext`/`pdfinfo`), QPDF, Tesseract OCR, plus `ocrmypdf` (pip/apt). Separate from GUI `media_apps` so server profiles can take them too.
- **Zoom is its own step** (`comms_zoom`), no longer bundled inside `media_apps`.
- **DWService: interactive wizard only.** Silent install is not available for normal/personal accounts; removed the silent step. `remote_dwservice` is the step-by-step installer (clipboard + wizard). Legacy `remote_dwservice_manual` aliases to it.

## 1.5.5

- **2026 paid / trial audit (Windows):** RealVNC Connect remains out (trial/account). **Sublime Text** removed from `editor_pdf` (paid evaluation nag), keep free Notepad++ + SumatraPDF. mRemoteNG already gone. Freemium SaaS installers (Notion, Linear, Slack, Zoom, Postman, Cursor, ChatGPT desktop) stay; they do not require a paid desktop license to install.
- **VNC split by machine role:** `vnc_viewer` = TightVNC Viewer only (client PCs). `remote_vnc` = TightVNC Server only (machines you share). Legacy `-Only rdp_client` maps to `vnc_viewer`. Ubuntu: `remmina` = client, `remote_vnc` = server; `--only=vnc_viewer` aliases to `remmina`.
- **OBS Studio** step (`obs` / `OBSProject.OBSStudio`; Ubuntu `obs-studio`).
- **Python on PATH:** winget install with `PrependPath=1`; `Ensure-PythonOnPath` / `path_check` add the install dir + `Scripts` + pip `--user` Scripts, and prefer the real `python.exe` over the WindowsApps Store stub in-session.
- **`win11_cleanup` expanded** (Win11Debloat / 25H2 noise list): News, Weather, Solitaire, Office Hub / Outlook trial, WhatsApp, LinkedIn, TikTok, Facebook/Instagram, Spotify, Netflix/Hulu/Amazon, Candy Crush family, Phone Link, Copilot/AI Hub, Xbox stack, Clipchamp, Photos, etc.

## 1.5.4

- **Windows remote clients:** drop **RealVNC Connect Viewer** (paid / account-gated) and **mRemoteNG** (too slow). `rdp_client` installs **TightVNC Viewer**; `remote_vnc` installs **TightVNC Server** only (same `GlavSoft.TightVNC` MSI, `ADDLOCAL` features; `--force` when adding the missing half). Built-in `mstsc` remains the RDP client. `PIN_REMMINA` now pins TightVNC Viewer.

## 1.5.3

- **Chrome false FAIL when Google Update is ahead of winget.** Log showed MSI Error 1722 / "already has a more recent version" (disk 153.x vs winget catalog 152.x) → exit `-1978335159`. `Test-WingetInstalled Google.Chrome` often misses a consumer/Google-Update install, so the chrome step tried a downgrade. Fix: skip when `chrome.exe` is on disk (same idea as Ubuntu `has_cmd google-chrome`); treat winget "more recent version" as OK on install; soft-OK Chrome upgrades when Chrome is present after a winget failure.
