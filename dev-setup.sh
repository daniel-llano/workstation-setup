#!/usr/bin/env bash
# dev-setup.sh - Interactive development environment bootstrapper for Ubuntu.
#
# Portable across machines running the same Ubuntu release family. Designed to be
# re-run safely (idempotent where practical) and to keep going when one step fails
# instead of aborting the whole run.
#
# The git_gh step and the remote-access steps (remote_ssh, remote_gnome_desktop,
# remote_rustdesk, remote_dwservice) can all read their settings from a .env
# file next to this script - copy .env-sample to .env and fill it in before
# running them. Every step also still works without a .env: git_gh falls back
# to asking on the console, and the remote-access steps just get skipped.
#
# Usage:
#   ./dev-setup.sh                 interactive: ask before each step
#   ./dev-setup.sh -y              non-interactive: install everything
#   ./dev-setup.sh -n              dry-run: print what would happen, change nothing
#   ./dev-setup.sh --only=a,b      only run the given step ids
#   ./dev-setup.sh --skip=a,b      run everything except the given step ids
#   ./dev-setup.sh --profile=minimal   core toolchain only
#   ./dev-setup.sh --profile=server    console/server: skip GUI apps
#   ./dev-setup.sh --profile=desktop   force GUI apps even on a server image
#
set -Eeuo pipefail
# Deliberately left at the shell default (space/tab/newline): every expansion in
# this script is either quoted or an array, and a couple of spots below join
# "$@" with spaces for display, so a stricter IFS would silently break those.

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.6.1"
LOG_DIR="${HOME}/.dev-setup-logs"
LOG_FILE="${LOG_DIR}/dev-setup-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
ASSUME_YES=false
ONLY_LIST=""
SKIP_LIST=""
PROFILE=""
INSTALL_MODE=""
APT_UPDATED=false
NVM_DIR_DEFAULT="${HOME}/.nvm"
# Every installer/package this script downloads (not piped straight into a
# command) lands here, not /tmp - so if a step's own install/apt-get command
# fails partway, the file is still around under a normal, browsable folder
# to retry by hand instead of vanishing into /tmp.
DOWNLOAD_DIR="${HOME}/Downloads"
# Small bits of state dev-setup.sh needs to remember between runs (which
# RustDesk build is installed, which dock icons it's managing, hashes of
# secrets it has already applied) - never credentials themselves, just
# markers, so this directory is safe to keep even though .env is not.
STATE_DIR="${HOME}/.local/state/dev-setup"
# Settings (git identity / gh token, and SSH / GNOME Remote Desktop / RustDesk /
# DWService credentials) are read from a .env file sitting next to this
# script, never hardcoded and never fetched from anywhere - see .env-sample
# for the expected keys.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_LOADED=false
# Flaky networks (VPNs, proxies, transient DNS blips) are common on real dev
# machines; retry transient failures a few times before giving up.
CURL_RETRY="--retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 60"
# Exported so it's visible to run_sh's child `bash -c` process too, not just this shell.
export CURL_RETRY
export DOWNLOAD_DIR
# shellcheck disable=SC2206
CURL_RETRY_ARGS=($CURL_RETRY)

declare -A RESULTS=()

# ---------------------------------------------------------------------------
# Colors (only if attached to a tty)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$STATE_DIR"
log()      { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG_FILE"; }
log_info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; log "[INFO] $*"; }
log_ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "[OK] $*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "[WARN] $*"; }
log_err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; log "[FAIL] $*"; }
log_step() { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; log "==> $*"; }

# ---------------------------------------------------------------------------
# Error trap: report failing line but let the caller decide whether the whole
# script should die (top level) or just the current step (inside run_step).
# ---------------------------------------------------------------------------
on_err() {
  local exit_code=$? line_no=$1
  log_err "Unhandled error (exit ${exit_code}) at line ${line_no}"
}
trap 'on_err $LINENO' ERR

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Interprets a true/false-ish .env value; empty/unset falls back to $2
# (defaults to "true" so existing .env files with no PIN_* keys at all keep
# today's pin-everything-installed behavior unchanged).
flag_enabled() {
  local val="${1:-}" default="${2:-true}"
  [ -z "$val" ] && val="$default"
  case "$val" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

# True when $1 equals any of the remaining args.
array_contains() {
  local needle="$1" x
  shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# Ubuntu 26.04 ("Resolute Raccoon") shipped GNOME 50, which removed the
# GNOME-on-X11 session entirely - GNOME is Wayland-only there, with no X11
# fallback session to log into at all. Steps that behave differently when
# there is no X11 escape hatch (see step_remote_rustdesk) check this.
is_ubuntu_gnome_wayland_only() {
  local ver major
  ver=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-0}")
  major="${ver%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 26 ]
}

# Loads EMAIL/GIT_USER_NAME/GIT_USER_EMAIL/GH_TOKEN/REMOTE_USER/REMOTE_PASSWORD/
# RUSTDESK_PASSWORD/DWSERVICE_* from ${ENV_FILE} into the environment.
# Deliberately NOT sourced as shell - a credentials file is not a place
# arbitrary code should be able to run from - instead parsed as strict
# KEY=VALUE lines and only known keys are exported.
load_env_file() {
  $ENV_LOADED && return 0
  ENV_LOADED=true
  # Missing .env is normal. Returning 1 here aborts the script under set -e.
  [ -f "$ENV_FILE" ] || return 0

  local perms
  perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "600")
  if [ "${perms:1:1}" != "0" ] || [ "${perms:2:1}" != "0" ]; then
    log_warn "${ENV_FILE} is readable/writable by group or others (mode ${perms})."
    log_warn "It holds plaintext credentials - tightening it to 600."
    run chmod 600 "$ENV_FILE" || true
  fi

  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      case "$key" in
        EMAIL|GIT_USER_NAME|GIT_USER_EMAIL|GH_TOKEN|REMOTE_USER|REMOTE_PASSWORD|RUSTDESK_PASSWORD|RUSTDESK_WAYLAND_PREVIEW|DWSERVICE_KEY|DWSERVICE_USER|DWSERVICE_PASSWORD|BATTERY_CHARGE_LIMIT|TIMEZONE|NIGHT_LIGHT_STRENGTH|PACKAGEKIT_MODE|\
        PIN_VSCODE|PIN_CURSOR|PIN_CHATGPT|PIN_CHROME|PIN_LIBREOFFICE|PIN_POSTMAN|PIN_REMMINA|PIN_SLACK|PIN_TEAMS|PIN_NOTION|PIN_PUMBLE|PIN_LINEAR|PIN_CLOCKIFY|PIN_EDITOR_PDF)
          export "${key}=${value}"
          ;;
      esac
    fi
  done <"$ENV_FILE"

  # EMAIL is a single shared value; apps below default to it when their own
  # email-shaped key is left empty, so it only needs to be typed once.
  export GIT_USER_EMAIL="${GIT_USER_EMAIL:-${EMAIL:-}}"
  export DWSERVICE_USER="${DWSERVICE_USER:-${EMAIL:-}}"
  return 0
}

# True when this script can reach a graphical user session's D-Bus - needed
# for any gsettings/dconf write (dock pinning, idle/power gsettings).
has_session_bus() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
  [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]
}

# gsettings wrapper that fills in DBUS_SESSION_BUS_ADDRESS from XDG_RUNTIME_DIR
# when the invoking shell doesn't already have it set (e.g. a plain SSH shell
# into a box that also has an active graphical login).
user_gsettings() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus" gsettings "$@"
  else
    gsettings "$@"
  fi
}

# True when a graphical login is active for this user (or any seat). Used to
# avoid actions that tear down the desktop (e.g. restarting systemd-logind).
graphical_session_active() {
  if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    return 0
  fi
  if has_session_bus; then
    return 0
  fi
  if command -v loginctl >/dev/null 2>&1; then
    local sid type state
    while read -r sid _; do
      [ -n "$sid" ] || continue
      type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
      state=$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)
      case "$type" in
        wayland|x11|mir)
          case "$state" in
            active|online) return 0 ;;
          esac
          ;;
      esac
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  fi
  return 1
}

desktop_file_exists() {
  local id="$1" dir
  for dir in "/usr/share/applications" "/var/lib/snapd/desktop/applications" \
    "/var/lib/flatpak/exports/share/applications" \
    "${HOME}/.local/share/applications" \
    "${HOME}/.local/share/flatpak/exports/share/applications"; do
    [ -f "${dir}/${id}" ] && return 0
  done
  return 1
}

# Executes its arguments, or just prints them in dry-run mode.
run() {
  if $DRY_RUN; then
    printf '  %s[dry-run]%s' "$C_YELLOW" "$C_RESET"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# Like run(), but for a raw shell snippet (needed for pipes/redirects).
run_sh() {
  if $DRY_RUN; then
    printf '  %s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
    return 0
  fi
  # -e -o pipefail so a failed curl on the left of a pipe (e.g. `curl ... | bash`,
  # `curl ... | sudo tee ...`) is not masked by the right-hand command succeeding
  # on empty input - bash -c would otherwise run with none of the parent's set -o.
  bash -o errexit -o pipefail -c "$1"
}

apt_update_once() {
  wait_for_apt_lock || return 1
  if ! $APT_UPDATED; then
    log_info "Refreshing apt package index..."
    run sudo apt-get update -y
    APT_UPDATED=true
  fi
}

# Call after adding a new apt source, so the next install sees it.
apt_update_force() {
  wait_for_apt_lock || return 1
  log_info "Refreshing apt package index (new source added)..."
  run sudo apt-get update -y
  APT_UPDATED=true
}

apt_install() {
  wait_for_apt_lock || return 1
  apt_update_once
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Collect PIDs holding apt/dpkg locks (or known apt frontends). Prints one
# "pid cmdline" line per process to stdout; returns 0 if any holders found.
apt_lock_holders() {
  local lk pids="" pid cmd seen=" "
  for lk in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
    [ -e "$lk" ] || continue
    if command -v fuser >/dev/null 2>&1; then
      # fuser prints "lock:  1234 5678" on stderr/stdout mixed; normalize.
      pids="${pids} $(fuser "$lk" 2>/dev/null | tr -cs '0-9' ' ')"
    fi
  done
  # Also catch apt frontends that may not yet hold the lock file, and the
  # long-lived unattended-upgrade-shutdown waiter that often blocks setup.
  pids="${pids} $(pgrep -x apt-get 2>/dev/null || true)"
  pids="${pids} $(pgrep -x apt 2>/dev/null || true)"
  pids="${pids} $(pgrep -x aptitude 2>/dev/null || true)"
  pids="${pids} $(pgrep -x dpkg 2>/dev/null || true)"
  pids="${pids} $(pgrep -x packagekitd 2>/dev/null || true)"
  pids="${pids} $(pgrep -x unattended-upgr 2>/dev/null || true)"
  pids="${pids} $(pgrep -f '/usr/bin/unattended-upgrade' 2>/dev/null || true)"
  pids="${pids} $(pgrep -f 'unattended-upgrade-shutdown' 2>/dev/null || true)"
  pids="${pids} $(pgrep -f '/usr/bin/python3 /usr/share/unattended-upgrades' 2>/dev/null || true)"

  local any=1
  for pid in $pids; do
    [ -n "$pid" ] || continue
    case "$seen" in
      *" ${pid} "*) continue ;;
    esac
    seen="${seen}${pid} "
    cmd=""
    if [ -r "/proc/${pid}/cmdline" ]; then
      cmd=$(tr '\0' ' ' <"/proc/${pid}/cmdline" | sed 's/[[:space:]]*$//')
    fi
    [ -z "$cmd" ] && cmd=$(ps -p "$pid" -o args= 2>/dev/null || printf 'pid=%s' "$pid")
    printf '%s %s\n' "$pid" "$cmd"
    any=0
  done
  return "$any"
}

# Soft-clear PackageKit / apt-daily so terminal apt is the primary package
# manager for this run. Never delete lock files. Leave unattended-upgrades
# enabled (security updates); only stop its unit briefly if it is holding a
# lock. PACKAGEKIT_MODE from .env: auto|stop|mask|leave (default auto).
PACKAGEKIT_STOPS_THIS_RUN=0

stop_packagekit_soft() {
  $DRY_RUN && return 0
  local mode="${PACKAGEKIT_MODE:-auto}"
  case "$mode" in
    leave) return 0 ;;
  esac
  if systemctl is-active --quiet packagekit.service 2>/dev/null || pgrep -x packagekitd >/dev/null 2>&1; then
    log_info "Stopping PackageKit (packagekitd) so apt can take the locks, safer than killing PIDs or deleting lock files."
    sudo systemctl stop packagekit.service 2>/dev/null || true
    sudo systemctl stop packagekit-offline-update.service 2>/dev/null || true
    PACKAGEKIT_STOPS_THIS_RUN=$((PACKAGEKIT_STOPS_THIS_RUN + 1))
  fi
  # One-shot apt daily jobs (not the timer units themselves).
  sudo systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

  case "$mode" in
    mask)
      if ! systemctl is-enabled packagekit.service 2>/dev/null | grep -qi masked; then
        log_info "PACKAGEKIT_MODE=mask: masking packagekit.service (terminal apt is primary)."
        log_info "Restore later with: sudo systemctl unmask packagekit.service && sudo systemctl start packagekit.service"
        sudo systemctl mask packagekit.service 2>/dev/null || true
      fi
      ;;
    auto)
      # After PackageKit keeps waking up during this run, offer a permanent mask
      # on interactive desktop/server boxes that manage packages from the terminal.
      if [ "$PACKAGEKIT_STOPS_THIS_RUN" -ge 2 ] && ! $ASSUME_YES; then
        if ! systemctl is-enabled packagekit.service 2>/dev/null | grep -qi masked; then
          printf '\n'
          read -r -p "  PackageKit keeps reclaiming apt locks. Mask packagekit.service so it stays off? [y/N] " ans </dev/tty || ans="n"
          case "${ans:-n}" in
            [Yy]*)
              sudo systemctl mask packagekit.service 2>/dev/null || true
              log_ok "packagekit.service masked. Unmask later: sudo systemctl unmask packagekit.service"
              ;;
          esac
        fi
      fi
      ;;
  esac
}

# Ask (or under -y, refuse to auto-kill) to clear apt lock holders.
# Prefer systemctl stop PackageKit / apt-daily over kill. Never delete locks.
# Returns 0 if locks are clear, 1 if still blocked, 2 if caller should wait more.
resolve_apt_lock_holders() {
  local lines pid_list="" line pid rest ans
  local has_unattended_active=false
  lines=$(apt_lock_holders || true)
  if [ -z "$lines" ]; then
    return 0
  fi

  log_warn "These processes are holding apt/dpkg (or are apt frontends):"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pid="${line%% *}"
    rest="${line#* }"
    log_warn "  PID ${pid}: ${rest}"
    pid_list="${pid_list} ${pid}"
    case "$rest" in
      *packagekitd*|*PackageKit*|*apt-daily*|*unattended-upgrade-shutdown*) ;;
      *unattended-upgrade*)
        has_unattended_active=true
        ;;
    esac
  done <<<"$lines"

  if $DRY_RUN; then
    log_info "[dry-run] would stop PackageKit / apt-daily (not delete locks), then retry"
    return 1
  fi

  # Soft path first: PackageKit is the usual Ubuntu desktop lock holder.
  stop_packagekit_soft
  sleep 1
  if ! apt_lock_holders >/dev/null 2>&1; then
    log_ok "apt/dpkg locks are clear (PackageKit / apt-daily stopped)"
    return 0
  fi

  if $has_unattended_active; then
    log_warn "unattended-upgrades is actively updating, waiting (security updates stay enabled)."
    return 2
  fi

  if $ASSUME_YES; then
    log_err "apt/dpkg is still locked after stopping PackageKit, and -y will not kill other processes."
    log_err "Wait a minute and re-run, or without -y to choose Kill/Wait, or:"
    log_err "  sudo systemctl stop packagekit.service"
    log_err "  sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
    return 1
  fi

  printf '\n'
  log_info "Prefer [S]top PackageKit again / wait, do not delete lock files (that can corrupt dpkg)."
  read -r -p "  [S]top PackageKit & wait / [K]ill remaining PIDs / [W]ait more / [A]bort  [S/k/w/a] " ans </dev/tty || ans="a"
  case "${ans:-S}" in
    [Ww]*) return 2 ;;
    [Aa]*) return 1 ;;
    [Kk]*)
      log_info "Asking sudo to stop remaining holders (password may be required)..."
      sudo systemctl stop unattended-upgrades.service 2>/dev/null || true
      # shellcheck disable=SC2086
      sudo kill -TERM ${pid_list} 2>/dev/null || true
      sleep 2
      # shellcheck disable=SC2086
      sudo kill -KILL ${pid_list} 2>/dev/null || true
      sleep 1
      if apt_lock_holders >/dev/null 2>&1; then
        log_warn "Some apt lock holders are still present after kill."
        return 1
      fi
      log_ok "apt/dpkg locks are clear"
      return 0
      ;;
    *)
      stop_packagekit_soft
      sudo systemctl stop unattended-upgrades.service 2>/dev/null || true
      sleep 2
      if apt_lock_holders >/dev/null 2>&1; then
        return 2
      fi
      log_ok "apt/dpkg locks are clear"
      return 0
      ;;
  esac
}

wait_for_apt_lock() {
  $DRY_RUN && return 0
  # Proactively quiet PackageKit before the first wait, Ubuntu desktop
  # refreshes metadata shortly after boot and holds /var/lib/apt/lists/lock.
  stop_packagekit_soft
  local n=0 max=24 rc
  while true; do
    if ! apt_lock_holders >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 1))
    if [ "$n" -ge 3 ] || [ "$n" -gt "$max" ]; then
      resolve_apt_lock_holders
      rc=$?
      if [ "$rc" -eq 0 ]; then
        return 0
      fi
      if [ "$rc" -eq 2 ]; then
        n=0
        log_info "Waiting another round for apt/dpkg to free up..."
        sleep 5
        continue
      fi
      log_err "Another installer is still holding apt/dpkg. Close Software Updater, or:"
      log_err "  sudo systemctl stop packagekit.service"
      log_err "Do not delete lock files under /var/lib/apt or /var/lib/dpkg."
      return 1
    fi
    {
      local summary
      summary=$(apt_lock_holders 2>/dev/null | head -n 3 | tr '\n' '|' | sed 's/|$//')
      log_warn "Another installer is using apt/dpkg (${summary}); waiting 5s (${n}/${max})..."
    }
    sleep 5
  done
}

apt_pkg_available() {
  # No pipe to `grep -q` here on purpose: under `set -o pipefail`, grep exiting
  # early on its first match can SIGPIPE the producer, which then registers as
  # a pipeline failure even though the match itself succeeded.
  local policy
  policy=$(apt-cache policy "$1" 2>/dev/null || true)
  [[ "$policy" == *"Candidate:"* && "$policy" != *"Candidate: (none)"* ]]
}

# Append a guarded block to a shell rc file, skipping if already present.
append_rc_block() {
  local marker="$1" content="$2" rcfile="$3"
  [ -f "$rcfile" ] || run touch "$rcfile"
  if $DRY_RUN; then
    printf '  %s[dry-run]%s would ensure block "%s" in %s\n' "$C_YELLOW" "$C_RESET" "$marker" "$rcfile"
    return 0
  fi
  if ! grep -qF "# >>> dev-setup:${marker} >>>" "$rcfile" 2>/dev/null; then
    {
      printf '\n# >>> dev-setup:%s >>>\n' "$marker"
      printf '%s\n' "$content"
      printf '# <<< dev-setup:%s <<<\n' "$marker"
    } >>"$rcfile"
    log_ok "Added ${marker} block to $(basename "$rcfile")"
  fi
}

append_rc_all() {
  local marker="$1" content="$2"
  append_rc_block "$marker" "$content" "${HOME}/.bashrc"
  [ -f "${HOME}/.zshrc" ] && append_rc_block "$marker" "$content" "${HOME}/.zshrc"
  return 0
}

confirm() {
  local prompt="$1"
  $ASSUME_YES && return 0
  $DRY_RUN && { printf '%s [dry-run auto-yes]\n' "$prompt"; return 0; }
  local ans
  read -r -p "${prompt} [Y/n] " ans </dev/tty || ans="n"
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# Default-N prompt. Used for creating/resetting an OS login and for optional
# install steps that must never be implied by -y.
confirm_no() {
  local prompt="$1"
  if $DRY_RUN; then
    printf '%s [dry-run: optional / default skip]\n' "$prompt"
    return 1
  fi
  $ASSUME_YES && return 1
  local ans
  read -r -p "${prompt} [y/N] " ans </dev/tty || ans="n"
  [[ "$ans" =~ ^[Yy] ]]
}

# Decide which OS account remote_ssh may touch. Never creates a user unless the
# operator explicitly confirms after seeing whether REMOTE_USER already exists.
# -y/--yes never creates or resets accounts (would silently mint a login).
REMOTE_USER_EFFECTIVE=""
REMOTE_USER_CREATE=false
REMOTE_USER_UPDATE_PW=false
REMOTE_USER_DECIDED=false

ensure_remote_os_user() {
  $REMOTE_USER_DECIDED && return 0
  REMOTE_USER_DECIDED=true
  load_env_file
  local requested="${REMOTE_USER:-}"
  local current="$USER"

  log_info "Remote OS-user check (will not create an account unless you confirm):"
  log_info "  Current login: ${current}"
  if [ -z "$requested" ]; then
    log_info "  REMOTE_USER is empty in .env, using '${current}' (no new account)."
    REMOTE_USER_EFFECTIVE="$current"
    return 0
  fi
  log_info "  REMOTE_USER from .env: ${requested}"

  if id -u "$requested" >/dev/null 2>&1; then
    log_ok "  Account '${requested}' already exists on this machine."
    if $ASSUME_YES; then
      log_warn "  -y/--yes never resets OS passwords. Leaving '${requested}' unchanged."
      REMOTE_USER_EFFECTIVE="$requested"
      return 0
    fi
    if confirm_no "Update password for '${requested}' from .env and add it to the sudo group?"; then
      REMOTE_USER_EFFECTIVE="$requested"
      REMOTE_USER_UPDATE_PW=true
    else
      log_info "  Leaving account '${requested}' unchanged."
      REMOTE_USER_EFFECTIVE="$requested"
    fi
    return 0
  fi

  log_warn "  Account '${requested}' does NOT exist."
  if $ASSUME_YES; then
    log_warn "  -y/--yes never creates OS accounts. Using current login '${current}' instead."
    log_warn "  Re-run this step interactively (without -y) if you really want a new user."
    REMOTE_USER_EFFECTIVE="$current"
    return 0
  fi
  if confirm_no "Create a new Linux user '${requested}' for remote login?"; then
    REMOTE_USER_EFFECTIVE="$requested"
    REMOTE_USER_CREATE=true
    REMOTE_USER_UPDATE_PW=true
  else
    log_info "  Not creating '${requested}'. Using current login '${current}'."
    REMOTE_USER_EFFECTIVE="$current"
  fi
}

apply_remote_os_user() {
  ensure_remote_os_user
  if $DRY_RUN; then
    log_info "[dry-run] effective remote user would be '${REMOTE_USER_EFFECTIVE}' (create=${REMOTE_USER_CREATE}, update-password=${REMOTE_USER_UPDATE_PW})"
    return 0
  fi
  if $REMOTE_USER_CREATE; then
    run sudo useradd -m -s /bin/bash "$REMOTE_USER_EFFECTIVE" || return 1
    log_ok "Created Linux user '${REMOTE_USER_EFFECTIVE}'"
  fi
  if $REMOTE_USER_UPDATE_PW; then
    if [ -z "${REMOTE_PASSWORD:-}" ]; then
      log_warn "REMOTE_PASSWORD is empty; not changing the password for '${REMOTE_USER_EFFECTIVE}'"
    else
      printf '%s:%s\n' "$REMOTE_USER_EFFECTIVE" "$REMOTE_PASSWORD" | sudo chpasswd
      log_ok "Updated password for '${REMOTE_USER_EFFECTIVE}' from .env"
    fi
    run sudo usermod -aG sudo "$REMOTE_USER_EFFECTIVE" || true
  fi
  return 0
}

# Runs a step function, contains failures so one bad step doesn't kill the run.
run_step() {
  local id="$1" desc="$2" func="$3"
  log_step "${desc}"
  if $DRY_RUN; then
    if "$func"; then
      RESULTS["$id"]="dry-run"
    else
      RESULTS["$id"]="dry-run-error"
      log_warn "${desc}: dry-run reported a problem, see above"
    fi
    return 0
  fi
  if "$func"; then
    RESULTS["$id"]="OK"
    log_ok "${desc} done"
  else
    RESULTS["$id"]="FAILED"
    log_err "${desc} failed - continuing with the next step (see ${LOG_FILE})"
  fi
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
check_preconditions() {
  if [ "$(id -u)" -eq 0 ]; then
    log_err "Do not run this script as root. Run as a normal user with sudo rights;"
    log_err "per-user tools (nvm, sdkman, dotnet, pipx) must live under a real \$HOME."
    exit 1
  fi
  if ! has_cmd sudo; then
    log_err "sudo is required but not installed."
    exit 1
  fi
  if [ ! -r /etc/os-release ] || ! grep -qi ubuntu /etc/os-release; then
    log_warn "This does not look like Ubuntu. The script targets Ubuntu and may not work elsewhere."
    confirm "Continue anyway?" || exit 1
  fi
  if ! $DRY_RUN; then
    log_info "Requesting sudo access (you may be prompted for your password)..."
    if ! sudo -v; then
      log_err "Could not obtain sudo privileges. Run this script from an interactive"
      log_err "terminal (not piped/non-interactive), as a user with sudo rights."
      exit 1
    fi
    # Keep sudo alive for the duration of the script.
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
  fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step_prereqs() {
  # psmisc provides fuser, used to identify apt/dpkg lock holders.
  apt_install ca-certificates curl wget gnupg lsb-release software-properties-common \
    apt-transport-https tar psmisc
}

# Fixed directories other steps add tools into. nvm/sdkman are deliberately
# not listed here - their own installers manage their own rc blocks (version
# switching means there's no single fixed bin dir to add to PATH for them).
PATH_MANAGED_DIRS=(
  "${HOME}/.local/bin"
  "${HOME}/.dotnet"
  "${HOME}/.dotnet/tools"
  "${HOME}/.config/composer/vendor/bin"
)

step_path_check() {
  local dir fixed=0
  for dir in "${PATH_MANAGED_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *)
        log_warn "${dir} exists but isn't on PATH for this session; adding it now"
        if $DRY_RUN; then
          log_info "[dry-run] would export PATH=\"\$PATH:${dir}\" for this run"
        else
          export PATH="${PATH}:${dir}"
        fi
        fixed=$((fixed + 1))
        ;;
    esac
  done

  # Re-assert the rc blocks this script itself owns, in case they were
  # hand-edited or removed since the last run - append_rc_block is a no-op
  # if the block is already there.
  # shellcheck disable=SC2016
  append_rc_all "local-bin" 'export PATH="$HOME/.local/bin:$PATH"'
  if [ -x "${HOME}/.dotnet/dotnet" ]; then
    append_rc_all "dotnet" "export DOTNET_ROOT=\"${HOME}/.dotnet\"
export PATH=\"\$PATH:${HOME}/.dotnet:${HOME}/.dotnet/tools\""
  fi

  # nvm/sdkman manage their own rc blocks via their own installers - only
  # verify they're still there rather than risk writing a conflicting
  # duplicate block in a different format.
  if [ -s "${NVM_DIR_DEFAULT}/nvm.sh" ] && ! grep -qF 'NVM_DIR' "${HOME}/.bashrc" 2>/dev/null; then
    log_warn "nvm is installed but its shell init looks missing from ~/.bashrc; re-run the node_nvm step or add it by hand"
  fi
  if [ -s "${HOME}/.sdkman/bin/sdkman-init.sh" ] && ! grep -qF 'SDKMAN_DIR' "${HOME}/.bashrc" 2>/dev/null; then
    log_warn "SDKMAN is installed but its shell init looks missing from ~/.bashrc; re-run the java_scala step or add it by hand"
  fi

  local tool missing=()
  for tool in code docker kubectl rg fd bat fzf jq git gh php composer; do
    has_cmd "$tool" || missing+=("$tool")
  done
  [ "${#missing[@]}" -gt 0 ] && log_info "Not on PATH right now (fine if not installed yet, or needs a new shell): ${missing[*]}"

  log_ok "PATH check complete (${fixed} dir(s) added to this session's PATH)"
  return 0
}

step_git_gh() {
  apt_install git
  load_env_file

  if [ -n "${GIT_USER_NAME:-}" ] || [ -n "${GIT_USER_EMAIL:-}" ]; then
    log_info "Checking git identity against ${ENV_FILE}"
    local cur_name cur_email
    cur_name=$(git config --global user.name 2>/dev/null || true)
    cur_email=$(git config --global user.email 2>/dev/null || true)
    if [ -n "${GIT_USER_NAME:-}" ]; then
      if [ "$GIT_USER_NAME" != "$cur_name" ]; then
        log_info "git user.name changed: '${cur_name:-<unset>}' -> '${GIT_USER_NAME}'; publishing globally"
        run git config --global user.name "$GIT_USER_NAME"
      else
        log_info "git user.name already up to date globally"
      fi
    fi
    if [ -n "${GIT_USER_EMAIL:-}" ]; then
      if [ "$GIT_USER_EMAIL" != "$cur_email" ]; then
        log_info "git user.email changed: '${cur_email:-<unset>}' -> '${GIT_USER_EMAIL}'; publishing globally"
        run git config --global user.email "$GIT_USER_EMAIL"
      else
        log_info "git user.email already up to date globally"
      fi
    fi
  elif $ASSUME_YES; then
    :
  elif ! $DRY_RUN && [ -z "$(git config --global user.email 2>/dev/null || true)" ]; then
    if confirm "git user.name/user.email are not set globally. Configure them now?"; then
      local gname gmail
      read -r -p "  git user.name: " gname </dev/tty || gname=""
      read -r -p "  git user.email: " gmail </dev/tty || gmail=""
      [ -n "$gname" ] && run git config --global user.name "$gname"
      [ -n "$gmail" ] && run git config --global user.email "$gmail"
    fi
  fi

  if has_cmd gh; then
    log_info "gh already installed, skipping"
  else
    # shellcheck disable=SC2016  # $CURL_RETRY expands inside run_sh's child bash -c (CURL_RETRY is exported)
    run_sh 'curl -fsSL $CURL_RETRY https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg'
    run sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    run_sh "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null"
    apt_update_force
    apt_install gh
  fi

  if [ -n "${GH_TOKEN:-}" ]; then
    # Detect a rotated token even when gh already reports itself
    # authenticated - only the token's sha256 is ever kept on disk, never
    # the token itself, just to know whether the value in .env changed
    # since the last run.
    local token_hash_file="${STATE_DIR}/gh-token-sha256" new_hash old_hash=""
    new_hash=$(printf '%s' "$GH_TOKEN" | sha256sum | cut -d' ' -f1)
    [ -f "$token_hash_file" ] && old_hash=$(cat "$token_hash_file" 2>/dev/null || true)
    local token_changed=false
    [ "$new_hash" != "$old_hash" ] && token_changed=true

    if $DRY_RUN; then
      if $token_changed; then
        log_info "[dry-run] would authenticate gh via GH_TOKEN from ${ENV_FILE} (token changed since last run)"
      else
        log_info "[dry-run] GH_TOKEN unchanged since last run; would skip re-authenticating gh"
      fi
    elif gh auth status >/dev/null 2>&1 && ! $token_changed; then
      log_info "gh already authenticated and GH_TOKEN in .env is unchanged, skipping login"
    else
      $token_changed && log_info "GH_TOKEN in ${ENV_FILE} changed since the last run; re-authenticating gh"
      # Piped directly (not through run_sh's `bash -c`) so the token is never
      # re-parsed as shell.
      if printf '%s' "$GH_TOKEN" | gh auth login --with-token; then
        log_ok "gh authenticated via GH_TOKEN"
        printf '%s' "$new_hash" >"$token_hash_file"
      else
        log_warn "gh auth login --with-token failed; check GH_TOKEN in ${ENV_FILE}"
      fi
    fi
  fi
  return 0
}

step_cpp_build() {
  # Light toolchain (gcc via build-essential + CMake/Ninja/clang). There is no
  # Linux equivalent of the multi-GB Windows "VS Build Tools + Windows SDK"
  # install - that lives only on Windows as the optional cpp_msvc step.
  apt_install build-essential cmake ninja-build gdb clang lldb pkg-config ccache codeblocks
}

step_java_scala() {
  if [ ! -d "${HOME}/.sdkman" ]; then
    apt_install zip unzip
    # shellcheck disable=SC2016  # $CURL_RETRY expands inside run_sh's child bash -c (CURL_RETRY is exported)
    if ! run_sh 'curl -fsS $CURL_RETRY "https://get.sdkman.io" | bash'; then
      log_err "Could not reach get.sdkman.io (network/firewall issue?)."
      log_err "Install SDKMAN! manually later, see https://sdkman.io/install, then rerun this step."
      return 1
    fi
  else
    log_info "SDKMAN already installed, skipping installer"
  fi

  if $DRY_RUN; then
    log_info "[dry-run] would install Java (Temurin LTS), Scala and sbt via sdk"
    return 0
  fi

  if [ ! -s "${HOME}/.sdkman/bin/sdkman-init.sh" ]; then
    log_err "SDKMAN installation looks incomplete (sdkman-init.sh missing); aborting this step."
    return 1
  fi

  # SDKMAN's own scripts are not nounset-clean (they reference unset positional
  # params internally), so `set -u` has to stay off for every `sdk ...` call
  # below, not just the sourcing line - restored only once we're done with sdk.
  # shellcheck disable=SC1091
  set +u
  # shellcheck source=/dev/null
  source "${HOME}/.sdkman/bin/sdkman-init.sh"

  local ok=1 found=0
  local candidate
  for candidate in tem sapmchn; do
    local ver
    ver=$(sdk list java 2>/dev/null | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-${candidate}" | sort -Vr | head -n1 || true)
    if [ -n "$ver" ]; then
      found=1
      if sdk install java "$ver" </dev/null; then
        sdk default java "$ver" || true
        ok=0
        break
      fi
    fi
  done
  if [ "$ok" -ne 0 ]; then
    if [ "$found" -eq 1 ]; then
      log_warn "Found a Temurin/SAP LTS build but 'sdk install java' failed; install manually with 'sdk install java'"
    else
      log_warn "Could not find a Temurin/SAP LTS build in the SDKMAN catalog; install manually with 'sdk install java'"
    fi
  fi

  sdk install scala </dev/null || { log_warn "scala install failed"; ok=1; }
  sdk install sbt </dev/null || { log_warn "sbt install failed"; ok=1; }
  set -u

  # shellcheck disable=SC2016
  append_rc_all "sdkman" 'export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"'
  return "$ok"
}

step_dotnet() {
  local dotnet_root="${HOME}/.dotnet"
  if [ -x "${dotnet_root}/dotnet" ]; then
    log_info ".NET SDK already installed under ${dotnet_root}, skipping"
  else
    local installer="${DOWNLOAD_DIR}/dotnet-install.sh"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" https://dot.net/v1/dotnet-install.sh -o "$installer"; then
      log_warn "dot.net unreachable, falling back to the dotnet/install-scripts GitHub mirror"
      if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.sh -o "$installer"; then
        log_err "Could not download the .NET install script from either source."
        return 1
      fi
    fi
    run chmod +x "$installer"
    if ! run "$installer" --channel LTS --install-dir "$dotnet_root"; then
      log_err ".NET install script ran but reported failure."
      return 1
    fi
  fi
  append_rc_all "dotnet" "export DOTNET_ROOT=\"${dotnet_root}\"
export PATH=\"\$PATH:${dotnet_root}:${dotnet_root}/tools\""
  return 0
}

# Shared with step_health_check, which keeps these current on later runs.
PIPX_TOOLS=(poetry ruff black mypy httpie ipython pre-commit)

step_python() {
  local ok=0
  apt_install python3 python3-venv python3-pip python3-dev pipx || { log_err "apt install of python packages failed"; ok=1; }
  run python3 -m pipx ensurepath || true
  local tool
  for tool in "${PIPX_TOOLS[@]}"; do
    run pipx install --force "$tool" || { log_warn "pipx install $tool failed"; ok=1; }
  done
  return "$ok"
}

# Shared with step_health_check, which keeps these current on later runs.
# "npm" itself is special-cased to "npm@latest" below since it upgrades npm.
NPM_GLOBAL_TOOLS=(npm typescript eslint prettier pnpm yarn)

step_node_nvm() {
  export NVM_DIR="$NVM_DIR_DEFAULT"
  if [ -s "${NVM_DIR}/nvm.sh" ]; then
    log_info "nvm already installed, skipping installer"
  else
    local nvm_ver
    nvm_ver=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
      | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    [ -z "$nvm_ver" ] && nvm_ver="v0.40.1"
    log_info "Installing nvm ${nvm_ver}"
    run_sh "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh | bash"
    local t
    for t in 1 2 3 4 5 6; do
      [ -s "${NVM_DIR}/nvm.sh" ] && break
      sleep 1
    done
  fi

  if $DRY_RUN; then
    log_info "[dry-run] would install current Node LTS via nvm and set it default"
    return 0
  fi

  if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    log_err "nvm.sh not found at ${NVM_DIR}/nvm.sh after install; re-run the node_nvm step"
    return 1
  fi

  # nvm's own script is not nounset-clean either (same issue as SDKMAN above),
  # so `set -u` stays off for every nvm/npm call, not just the sourcing line.
  # shellcheck disable=SC1091
  set +u
  # shellcheck source=/dev/null
  \. "${NVM_DIR}/nvm.sh"

  if ! nvm install --lts; then
    log_err "nvm install --lts failed"
    set -u
    return 1
  fi
  nvm alias default 'lts/*' || log_warn "nvm alias default failed"
  nvm use default || log_warn "nvm use default failed"

  local npm_pkgs=() t
  for t in "${NPM_GLOBAL_TOOLS[@]}"; do
    [ "$t" = "npm" ] && npm_pkgs+=("npm@latest") || npm_pkgs+=("$t")
  done
  npm install -g "${npm_pkgs[@]}" || log_warn "some global npm packages failed to install"
  corepack enable 2>/dev/null || true
  set -u
  return 0
}

# Shared with step_health_check, which keeps these current on later runs.
COMPOSER_GLOBAL_PACKAGES=(laravel/installer)

step_php() {
  local ok=0
  apt_install php php-cli php-fpm php-common php-mysql php-pgsql php-sqlite3 \
    php-mbstring php-xml php-curl php-zip php-bcmath php-gd php-intl unzip || \
    { log_err "apt install of PHP packages failed"; ok=1; }

  if ! has_cmd php && ! $DRY_RUN; then
    log_err "php command not found after install; skipping Composer/Laravel setup"
    return 1
  fi

  run mkdir -p "${HOME}/.local/bin"
  local composer_bin="${HOME}/.local/bin/composer"
  if has_cmd composer || [ -x "$composer_bin" ]; then
    log_info "Composer already installed, skipping installer"
  else
    local installer="${DOWNLOAD_DIR}/composer-setup.php"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$installer" https://getcomposer.org/installer; then
      log_err "Could not download the Composer installer"
      ok=1
    elif $DRY_RUN; then
      log_info "[dry-run] would verify the installer's sha384 signature against"
      log_info "[dry-run] composer.github.io/installer.sig, then install it to ${composer_bin}"
    else
      # Verify against Composer's published sha384 signature before running it -
      # this installer is a PHP script that runs with the invoking user's
      # privileges, not something to pipe straight into php unchecked.
      local expected actual
      expected=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" https://composer.github.io/installer.sig 2>/dev/null || true)
      actual=$(php -r "echo hash_file('sha384', '${installer}');" 2>/dev/null || true)
      if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        log_err "Composer installer signature mismatch (expected '${expected:-<unavailable>}', got"
        log_err "'${actual:-<unavailable>}'); aborting install rather than running an unverified script"
        run rm -f "$installer"
        ok=1
      else
        run php "$installer" --quiet --install-dir="${HOME}/.local/bin" --filename=composer
        run rm -f "$installer"
      fi
    fi
  fi

  # shellcheck disable=SC2016
  append_rc_all "local-bin" 'export PATH="$HOME/.local/bin:$PATH"'
  # shellcheck disable=SC2016
  append_rc_all "composer" 'export PATH="$PATH:$HOME/.config/composer/vendor/bin"'

  if has_cmd composer || [ -x "$composer_bin" ] || $DRY_RUN; then
    run "${composer_bin:-composer}" global require --no-interaction "${COMPOSER_GLOBAL_PACKAGES[@]}" || \
      { log_warn "composer global require failed for: ${COMPOSER_GLOBAL_PACKAGES[*]}"; ok=1; }
  else
    log_warn "Composer not available; skipping ${COMPOSER_GLOBAL_PACKAGES[*]}"
    ok=1
  fi
  return "$ok"
}

step_vscode() {
  if has_cmd code; then
    log_info "VS Code already installed, skipping"
    return 0
  fi
  # shellcheck disable=SC2016  # $CURL_RETRY/$DOWNLOAD_DIR expand inside run_sh's child bash -c (both exported)
  run_sh 'curl -fsSL $CURL_RETRY https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "${DOWNLOAD_DIR}/packages.microsoft.gpg"'
  run sudo install -o root -g root -m 644 "${DOWNLOAD_DIR}/packages.microsoft.gpg" /usr/share/keyrings/packages.microsoft.gpg
  run_sh 'echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null'
  apt_update_force
  if apt_install code; then
    return 0
  fi
  log_warn "apt install of VS Code failed, falling back to snap"
  run sudo snap install code --classic
}

VSCODE_EXTENSIONS_CORE=(
  eamodio.gitlens
  mhutchie.git-graph
  editorconfig.editorconfig
  usernamehw.errorlens
  streetsidesoftware.code-spell-checker
  christian-kohler.path-intellisense
  redhat.vscode-yaml
  tomoki1207.pdf
  mechatroner.rainbow-csv
  anthropic.claude-code
)

# Is this stack part of this machine, so its VS Code extensions are wanted?
#
# --skip is an explicit opt-out and always wins. Answering "n" at a step's
# prompt is NOT: the usual reason to decline "Install Docker?" is that Docker
# is already there, and dropping its extensions for that would be backwards.
# So a declined step falls through to detection and counts as enabled if the
# toolchain is actually present. Mirrors Test-StackEnabled in dev-setup.ps1.
step_wanted() {
  local id="$1"
  if [ -n "$SKIP_LIST" ] && list_in "$id" "$SKIP_LIST"; then
    return 1
  fi
  case "${RESULTS[$id]:-}" in
    OK|FAILED|dry-run|dry-run-error) return 0 ;;
  esac
  case "$id" in
    docker) has_cmd docker ;;
    kubectl) has_cmd kubectl ;;
    python) has_cmd python3 || has_cmd python ;;
    java_scala) has_cmd java || has_cmd sbt ;;
    php) has_cmd php ;;
    dotnet) has_cmd dotnet ;;
    cpp_build) has_cmd cmake || has_cmd g++ ;;
    node_nvm) has_cmd npm || has_cmd node || [ -s "${NVM_DIR_DEFAULT}/nvm.sh" ] ;;
    playwright) has_cmd npm || has_cmd npx ;;
    *) return 0 ;;
  esac
}

step_vscode_ext() {
  if ! has_cmd code && ! $DRY_RUN; then
    log_warn "VS Code (code CLI) not found; install the vscode step first"
    return 1
  fi
  local ext failures=0 skipped_stacks=()
  local -a planned=("${VSCODE_EXTENSIONS_CORE[@]}")

  add_stack_exts() {
    local stack="$1"; shift
    if step_wanted "$stack"; then
      planned+=("$@")
    else
      skipped_stacks+=("$stack")
    fi
  }
  add_stack_exts node_nvm esbenp.prettier-vscode dbaeumer.vscode-eslint dsznajder.es7-react-js-snippets bradlc.vscode-tailwindcss
  add_stack_exts python ms-python.python ms-python.vscode-pylance charliermarsh.ruff ms-toolsai.jupyter
  add_stack_exts java_scala scalameta.metals
  add_stack_exts php bmewburn.vscode-intelephense-client onecentlin.laravel-blade
  add_stack_exts dotnet ms-dotnettools.csharp ms-dotnettools.csdevkit
  add_stack_exts cpp_build ms-vscode.cpptools ms-vscode.cmake-tools
  add_stack_exts docker ms-azuretools.vscode-docker ms-vscode-remote.remote-containers
  add_stack_exts kubectl ms-kubernetes-tools.vscode-kubernetes-tools
  add_stack_exts playwright ms-playwright.playwright

  if [ "${#skipped_stacks[@]}" -gt 0 ]; then
    log_info "Skipping VS Code extensions for stacks not present or skipped this run: ${skipped_stacks[*]}"
  fi
  for ext in "${planned[@]}"; do
    if run code --install-extension "$ext" --force; then
      :
    else
      log_warn "extension failed: ${ext}"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

step_cursor() {
  if has_cmd cursor; then
    log_info "Cursor already installed, skipping"
    return 0
  fi
  local arch platform_arch
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64) platform_arch="x64" ;;
    arm64) platform_arch="arm64" ;;
    *) log_warn "No Cursor Linux build for this architecture; skipping"; return 1 ;;
  esac

  local deb
  deb=$(ls "${DOWNLOAD_DIR}"/cursor_*_"${arch}".deb 2>/dev/null | sort -V | tail -n1 || true)
  if [ -z "$deb" ]; then
    log_info "No local cursor*.deb in ${DOWNLOAD_DIR}; resolving the current version from cursor.com"
    local json deb_url
    json=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" "https://www.cursor.com/api/download?platform=linux-${platform_arch}&releaseTrack=stable" 2>/dev/null || true)
    deb_url=$(printf '%s' "$json" | grep -oE '"debUrl" *: *"[^"]+"' | head -n1 | sed -E 's/.*"(https:[^"]+)"/\1/')
    if [ -z "$deb_url" ]; then
      log_err "Could not resolve the current Cursor .deb download URL from cursor.com/api/download"
      return 1
    fi
    deb="${DOWNLOAD_DIR}/$(basename "$deb_url")"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$deb_url"; then
      log_err "Could not download Cursor from ${deb_url}"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

step_chatgpt() {
  if has_cmd chatgpt; then
    log_info "ChatGPT desktop already installed, skipping"
    return 0
  fi
  # OpenAI's official Linux client (public preview since Aug 2026) - ships as
  # a .deb/.rpm that registers its own signed apt repo on install, so later
  # updates land through the normal 'sudo apt upgrade' (see health_check).
  local arch deb_url
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64|arm64) deb_url="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${arch}.deb" ;;
    *) log_warn "No ChatGPT desktop Linux build for this architecture; skipping"; return 1 ;;
  esac

  local deb
  deb=$(ls "${DOWNLOAD_DIR}"/chatgpt_"${arch}".deb 2>/dev/null | sort -V | tail -n1 || true)
  if [ -z "$deb" ]; then
    deb="${DOWNLOAD_DIR}/chatgpt_${arch}.deb"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$deb_url"; then
      log_err "Could not download the ChatGPT desktop app"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

step_editor_pdf() {
  local pkg
  for pkg in gnome-text-editor gedit; do
    if apt_pkg_available "$pkg"; then
      apt_install "$pkg"
      break
    fi
  done
  apt_install evince
  install_marktext || log_warn "MarkText (Markdown editor) install failed - continue without it"
}

# Free Markdown editor/viewer (MarkText). Prefer a local .deb in Downloads,
# else fetch the latest Linux .deb from GitHub releases (amd64 only).
install_marktext() {
  if has_cmd marktext || desktop_file_exists marktext.desktop || desktop_file_exists MarkText.desktop; then
    log_info "MarkText already installed, skipping"
    return 0
  fi
  local deb arch name url json
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  case "$arch" in
    amd64|x86_64) ;;
    *) log_warn "MarkText .deb is amd64-only (this host is ${arch}); skip"; return 1 ;;
  esac

  # Official asset name is marktext-linux-<ver>.deb (architecture not in the filename).
  deb=$(ls "${DOWNLOAD_DIR}"/marktext-linux-*.deb "${DOWNLOAD_DIR}"/marktext*.deb 2>/dev/null | head -n1 || true)
  if [ -z "$deb" ]; then
    if $DRY_RUN; then
      log_info "[dry-run] would download MarkText .deb from GitHub and apt-install it"
      return 0
    fi
    log_info "Resolving latest MarkText Linux .deb from GitHub releases..."
    json=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" \
      https://api.github.com/repos/marktext/marktext/releases/latest 2>/dev/null) || {
      log_warn "Could not query MarkText releases"
      return 1
    }
    name=$(printf '%s' "$json" \
      | grep -oE '"name": *"marktext-linux-[^"]+\.deb"' \
      | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
    if [ -z "$name" ]; then
      log_warn "Could not find a MarkText Linux .deb asset"
      return 1
    fi
    url=$(printf '%s' "$json" \
      | grep -oE '"browser_download_url": *"[^"]*/'"${name}"'"' \
      | head -n1 | sed -E 's/.*"(https:[^"]+)"/\1/')
    [ -z "$url" ] && { log_warn "No download URL for ${name}"; return 1; }
    deb="${DOWNLOAD_DIR}/${name}"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$url"; then
      log_warn "Could not download ${name}"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  apt_install "$deb" || run sudo apt-get install -f -y
}

step_libreoffice() {
  apt_install libreoffice
}

step_postman_newman() {
  if has_cmd postman; then
    log_info "Postman already installed, skipping"
  else
    run sudo snap install postman
  fi
  if has_cmd npm || $DRY_RUN; then
    run npm install -g newman newman-reporter-htmlextra
  else
    log_warn "npm not found (run the node_nvm step first); skipping newman"
    return 1
  fi
}

step_playwright() {
  if ! has_cmd npm && ! $DRY_RUN; then
    log_warn "npm not found (run the node_nvm step first); skipping playwright"
    return 1
  fi
  run npm install -g playwright
  log_info "Installing Playwright's OS-level dependencies (requires sudo)..."
  run sudo env "PATH=$PATH" npx --yes playwright install-deps || \
    log_warn "playwright OS dependency install had issues; you can rerun 'sudo npx playwright install-deps' later"
  # Deliberately NOT run under sudo: Playwright caches browsers under the
  # invoking user's $HOME (~/.cache/ms-playwright). Downloading them as root
  # would put them in /root instead, invisible to this user's test runs.
  log_info "Downloading Playwright browsers into this user's cache..."
  run npx --yes playwright install || \
    log_warn "playwright browser download had issues; you can rerun 'npx playwright install' later"
}

step_docker() {
  if has_cmd docker; then
    log_info "Docker already installed, skipping"
  else
    log_info "Adding Docker's official apt repository..."
    run sudo install -m 0755 -d /etc/apt/keyrings
    # shellcheck disable=SC2016  # $CURL_RETRY/$DOWNLOAD_DIR expand inside run_sh's child bash -c (both exported)
    run_sh 'curl -fsSL $CURL_RETRY https://download.docker.com/linux/ubuntu/gpg -o "${DOWNLOAD_DIR}/docker.asc"'
    run sudo install -o root -g root -m 644 "${DOWNLOAD_DIR}/docker.asc" /etc/apt/keyrings/docker.asc
    local codename arch
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    run_sh "echo \"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null"

    local docker_ok=1
    if $DRY_RUN; then
      docker_ok=0
    else
      apt_update_force
      if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
          docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        docker_ok=0
      fi
    fi

    if [ "$docker_ok" -ne 0 ]; then
      log_warn "Docker's upstream repo has no build for '${codename}' yet (common right after a new"
      log_warn "Ubuntu release). Falling back to Ubuntu's own docker.io package."
      run sudo rm -f /etc/apt/sources.list.d/docker.list
      apt_update_force
      if ! apt_install docker.io docker-compose-v2; then
        log_err "Docker install failed via both docker-ce and the docker.io fallback."
        return 1
      fi
    fi
  fi

  if ! $DRY_RUN; then
    if ! has_cmd docker; then
      log_err "docker command still not found after install."
      return 1
    fi
    local user_groups
    user_groups=$(id -nG "$USER")
    if [[ " ${user_groups} " != *" docker "* ]]; then
      run sudo usermod -aG docker "$USER"
      log_warn "Added $USER to the 'docker' group. Log out and back in (or run 'newgrp docker') for it to take effect."
    fi
    run sudo systemctl enable --now docker || true
  fi
  return 0
}

step_kubectl() {
  if has_cmd kubectl; then
    log_info "kubectl already installed, skipping"
    return 0
  fi
  run sudo snap install kubectl --classic
}

step_archive_tools() {
  apt_install unzip zip p7zip-full unrar-free xz-utils zstd
}

step_cli_tools() {
  # `apt-get install` fails the WHOLE batch atomically if even one package name
  # is wrong/renamed on this release - filter to what's actually available
  # first so one bad name (e.g. a package renamed between Ubuntu releases)
  # doesn't silently take out every tool in the list.
  local wanted=(ripgrep fd-find bat fzf jq htop ncdu tmux tree glances tealdeer direnv \
    iotop nethogs git-delta silversearcher-ag)
  local available=() pkg
  for pkg in "${wanted[@]}"; do
    if apt_pkg_available "$pkg"; then
      available+=("$pkg")
    else
      log_warn "apt package '${pkg}' is not available on this release; skipping it"
    fi
  done

  local ok=0
  if [ "${#available[@]}" -gt 0 ]; then
    apt_install "${available[@]}" || { log_warn "apt install of CLI tools failed"; ok=1; }
  fi

  run mkdir -p "${HOME}/.local/bin"
  if ! has_cmd fd && has_cmd fdfind; then
    run ln -sf "$(command -v fdfind)" "${HOME}/.local/bin/fd"
  fi
  if ! has_cmd bat && has_cmd batcat; then
    run ln -sf "$(command -v batcat)" "${HOME}/.local/bin/bat"
  fi
  # shellcheck disable=SC2016
  append_rc_all "local-bin" 'export PATH="$HOME/.local/bin:$PATH"'

  if has_cmd snap && ! has_cmd yq; then
    run sudo snap install yq || { log_warn "yq install failed"; ok=1; }
  fi
  if has_cmd snap && ! has_cmd glow; then
    run sudo snap install glow || { log_warn "glow install failed"; ok=1; }
  fi
  return "$ok"
}

step_chrome() {
  if has_cmd google-chrome; then
    log_info "Google Chrome already installed, skipping"
    return 0
  fi
  local deb
  deb=$(ls "${DOWNLOAD_DIR}"/google-chrome-stable_current_*.deb 2>/dev/null | head -n1 || true)
  if [ -z "$deb" ]; then
    deb="${DOWNLOAD_DIR}/google-chrome-stable_current_amd64.deb"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
      log_err "Could not download Google Chrome"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

step_remmina() {
  # Viewer / client machines (RDP+VNC+SSH). Server sharing is remote_vnc, pick one or both.
  apt_install remmina remmina-plugin-rdp remmina-plugin-vnc remmina-plugin-secret
}

step_obs() {
  if has_cmd obs; then
    log_info "OBS Studio already installed, skipping"
    return 0
  fi
  apt_install obs-studio
}

step_comms_slack() {
  has_cmd slack && { log_info "Slack already installed, skipping"; return 0; }
  run sudo snap install slack
}

step_comms_teams() {
  has_cmd teams-for-linux && { log_info "teams-for-linux already installed, skipping"; return 0; }
  log_info "Microsoft discontinued the native Teams Linux client; installing the"
  log_info "community 'teams-for-linux' client instead."
  run sudo snap install teams-for-linux
}

step_comms_notion() {
  if snap list notion-snap >/dev/null 2>&1 || snap list notion-snap-reborn >/dev/null 2>&1; then
    log_info "Notion already installed, skipping"
    return 0
  fi
  log_info "Notion has no official Linux client; trying community snaps."
  if run sudo snap install notion-snap; then
    return 0
  fi
  log_warn "notion-snap failed, trying notion-snap-reborn"
  run sudo snap install notion-snap-reborn
}

step_comms_pumble() {
  if has_cmd pumble; then
    log_info "Pumble already installed, skipping"
    return 0
  fi
  local deb
  deb=$(ls "${DOWNLOAD_DIR}"/Pumble-linux-*.deb "${DOWNLOAD_DIR}"/pumble*.deb 2>/dev/null | sort -V | tail -n1 || true)
  if [ -z "$deb" ]; then
    log_info "No local Pumble .deb in ${DOWNLOAD_DIR}; looking up the current version"
    local page deb_url
    page=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" https://pumble.com/apps 2>/dev/null || true)
    deb_url=$(printf '%s' "$page" | grep -oE 'https://pumble\.com/download/desktop/linux/Pumble-linux-[0-9.]+\.deb' | head -n1 || true)
    if [ -z "$deb_url" ]; then
      log_warn "Could not find a current Pumble .deb link on pumble.com/apps"
      log_warn "Install manually: download the .deb from https://pumble.com/apps and run 'sudo apt install ./Pumble*.deb'"
      return 1
    fi
    deb="${DOWNLOAD_DIR}/$(basename "$deb_url")"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$deb_url"; then
      log_err "Could not download Pumble from ${deb_url}"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

step_comms_clockify() {
  if has_cmd clockify || has_cmd clockify-desktop; then
    log_info "Clockify already installed, skipping"
    return 0
  fi
  local deb_url
  case "$(dpkg --print-architecture)" in
    amd64) deb_url="https://clockify.me/downloads/Clockify_Setup_x64.deb" ;;
    arm64) deb_url="https://clockify.me/downloads/Clockify_Setup_arm64.deb" ;;
    *) log_warn "No Clockify Linux build for this architecture; skipping"; return 1 ;;
  esac
  local deb="${DOWNLOAD_DIR}/Clockify_Setup.deb"
  if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$deb_url"; then
    log_err "Could not download Clockify"
    return 1
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

step_comms_linear() {
  local desktop_file="${HOME}/.local/share/applications/linear.desktop"
  run mkdir -p "${HOME}/.local/share/applications"
  if $DRY_RUN; then
    log_info "[dry-run] would write ${desktop_file} launching Linear as a browser app"
    return 0
  fi
  local browser_cmd=""
  if has_cmd google-chrome; then browser_cmd="google-chrome --app=https://linear.app"
  elif has_cmd chromium-browser; then browser_cmd="chromium-browser --app=https://linear.app"
  elif has_cmd chromium; then browser_cmd="chromium --app=https://linear.app"
  elif has_cmd firefox; then browser_cmd="firefox --new-window https://linear.app"
  fi
  if [ -z "$browser_cmd" ]; then
    log_warn "No Chromium/Firefox found to build an app-mode launcher; Linear is web-only anyway - just bookmark https://linear.app"
    return 0
  fi
  cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Linear
Comment=Linear (web app)
Exec=${browser_cmd}
Terminal=false
Categories=Office;
EOF
  log_ok "Created a Linear launcher at ${desktop_file}"
}

# ---------------------------------------------------------------------------
# Remote access: SSH, GNOME Remote Desktop (native Wayland RDP), RustDesk,
# DWService. All credentials come from ${ENV_FILE} - see .env-sample.
# ---------------------------------------------------------------------------

step_remote_ssh() {
  load_env_file
  if [ -z "${REMOTE_PASSWORD:-}" ]; then
    log_warn "No REMOTE_PASSWORD in ${ENV_FILE} (copy .env-sample to .env and fill it in)."
    log_warn "SSH can still be enabled for your current account; password auth from .env will be skipped."
  fi

  apt_install openssh-server
  run sudo systemctl enable --now ssh.service

  apply_remote_os_user || return 1
  log_info "SSH remote login will use OS account '${REMOTE_USER_EFFECTIVE}'"

  if $DRY_RUN; then
    log_info "[dry-run] would enable PasswordAuthentication via /etc/ssh/sshd_config.d/99-dev-setup-remote.conf"
  else
    local sshd_conf='PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
'
    printf '%s' "$sshd_conf" | sudo tee /etc/ssh/sshd_config.d/99-dev-setup-remote.conf >/dev/null
    if ! sudo sshd -t; then
      log_err "sshd config check failed after writing the password-auth drop-in; reverting it"
      run sudo rm -f /etc/ssh/sshd_config.d/99-dev-setup-remote.conf
      return 1
    fi
    run sudo systemctl restart ssh.service
  fi

  if has_cmd ufw && ! $DRY_RUN; then
    local ufw_line
    ufw_line=$(sudo ufw status 2>/dev/null | head -n1 || true)
    [[ "$ufw_line" == *"active"* ]] && run sudo ufw allow OpenSSH
  fi
  return 0
}

step_remote_gnome_desktop() {
  load_env_file
  if ! has_cmd grdctl; then
    apt_install gnome-remote-desktop || { log_err "could not install gnome-remote-desktop"; return 1; }
  fi
  if [ -z "${REMOTE_PASSWORD:-}" ]; then
    log_warn "No REMOTE_PASSWORD in ${ENV_FILE}; skipping GNOME Remote Desktop setup."
    return 1
  fi
  local rdp_user="${REMOTE_USER:-$USER}"
  log_info "GNOME RDP credentials will use login name '${rdp_user}' (this is the RDP protocol user, not a new OS account)."
  if ! has_session_bus; then
    log_warn "No desktop session bus found (running headless/over plain SSH?); skipping GNOME Remote Desktop."
    log_warn "Re-run this step from inside your graphical login session."
    return 1
  fi

  if $DRY_RUN; then
    log_info "[dry-run] would enable GNOME Remote Desktop (RDP) - both sharing this session and"
    log_info "[dry-run] remote login at the GDM screen - using credentials from ${ENV_FILE}"
    return 0
  fi

  local cert_dir="${HOME}/.local/share/gnome-remote-desktop/certificates"
  run mkdir -p "$cert_dir"
  if [ ! -s "${cert_dir}/rdp-tls.crt" ]; then
    run openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
      -keyout "${cert_dir}/rdp-tls.key" -out "${cert_dir}/rdp-tls.crt" \
      -subj "/CN=$(hostname)"
  fi

  # Share the already-logged-in desktop session - Wayland-native via PipeWire,
  # no xdg-desktop-portal prompt (unlike RustDesk/DWService screen capture).
  run grdctl rdp set-tls-cert "${cert_dir}/rdp-tls.crt"
  run grdctl rdp set-tls-key "${cert_dir}/rdp-tls.key"
  run grdctl rdp set-credentials "$rdp_user" "$REMOTE_PASSWORD"
  run grdctl rdp disable-view-only
  run grdctl rdp enable
  run systemctl --user enable --now gnome-remote-desktop.service

  # Also enable remote *login* at the GDM screen (--system), so the machine
  # is reachable by RDP even before anyone logs in locally. Best-effort: the
  # system daemon may run as a different user than the one owning the cert
  # under $HOME, so this is allowed to fail without failing the whole step.
  local sys_cert_dir="/etc/gnome-remote-desktop-certs"
  if run sudo mkdir -p "$sys_cert_dir" \
    && run sudo cp "${cert_dir}/rdp-tls.crt" "${cert_dir}/rdp-tls.key" "$sys_cert_dir/" \
    && run sudo chmod 644 "${sys_cert_dir}/rdp-tls.crt" "${sys_cert_dir}/rdp-tls.key" \
    && run sudo grdctl --system rdp set-tls-cert "${sys_cert_dir}/rdp-tls.crt" \
    && run sudo grdctl --system rdp set-tls-key "${sys_cert_dir}/rdp-tls.key" \
    && run sudo grdctl --system rdp set-credentials "$rdp_user" "$REMOTE_PASSWORD"; then
    run sudo grdctl --system rdp disable-view-only
    run sudo grdctl --system rdp enable
    run sudo systemctl enable --now gnome-remote-desktop.service
  else
    log_warn "System-level (GDM) remote login could not be fully configured; per-session RDP"
    log_warn "sharing is still enabled. Retry by hand later with: sudo grdctl --system rdp ..."
  fi

  if has_cmd ufw; then
    local ufw_line
    ufw_line=$(sudo ufw status 2>/dev/null | head -n1 || true)
    [[ "$ufw_line" == *"active"* ]] && run sudo ufw allow 3389/tcp
  fi
  return 0
}

RUSTDESK_STATE_DIR="${STATE_DIR}"
RUSTDESK_WAYLAND_MARKER="${RUSTDESK_STATE_DIR}/rustdesk-wayland-asset"

# RUSTDESK_WAYLAND_PREVIEW controls whether to install RustDesk's preview
# "unattended-wayland" build (see https://rustdesk.com/blog/unattended-remote-access-wayland/)
# instead of the regular stable release:
#   auto  (default) - only on Ubuntu 26+, where GNOME dropped its X11 session
#                      entirely and RustDesk's regular best-effort Wayland
#                      capture has no X11 fallback left to lean on.
#   true             - always use the preview build, any Ubuntu release.
#   false            - always use the regular stable release.
rustdesk_wayland_preview_wanted() {
  case "${RUSTDESK_WAYLAND_PREVIEW:-auto}" in
    true|yes|1) return 0 ;;
    false|no|0) return 1 ;;
    *) is_ubuntu_gnome_wayland_only ;;
  esac
}

# Resolves the current rustdesk-unattended-wayland-*-<arch>.deb asset from
# RustDesk's rolling "nightly" GitHub release (this preview build is not a
# numbered release - its filename's version segment moves independently of
# the "nightly" tag, so it has to be discovered each run rather than built
# from a version string). Echoes "<asset-name> <download-url>" on success.
rustdesk_wayland_preview_asset() {
  local asset_arch="$1" json name url
  json=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" \
    https://api.github.com/repos/rustdesk/rustdesk/releases/tags/nightly 2>/dev/null) || return 1
  name=$(printf '%s' "$json" \
    | grep -oE '"name": *"rustdesk-unattended-wayland-[^"]*-'"${asset_arch}"'\.deb"' \
    | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ -z "$name" ] && return 1
  url=$(printf '%s' "$json" \
    | grep -oE '"browser_download_url": *"[^"]*/'"${name}"'"' \
    | head -n1 | sed -E 's/.*"(https:[^"]+)"/\1/')
  [ -z "$url" ] && return 1
  printf '%s %s\n' "$name" "$url"
}

# Echoes whichever dpkg package currently provides RustDesk - "rustdesk" for
# the stable build, "rustdesk-unattended-wayland" for the preview build. The
# two ship the same `rustdesk` command under different package names, so a
# plain `dpkg -s rustdesk` misses the preview build once that's the one
# installed (as happens switching between the two, or across a preview
# version bump).
rustdesk_installed_package() {
  local pkg
  for pkg in rustdesk rustdesk-unattended-wayland; do
    if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status:.*installed$'; then
      printf '%s\n' "$pkg"
      return 0
    fi
  done
  return 1
}

# Regular stable RustDesk release (best-effort Wayland unattended capture).
step_remote_rustdesk_stable() {
  local asset_arch="$1"
  if has_cmd rustdesk; then
    log_info "RustDesk already installed, skipping package install"
    return 0
  fi
  local deb
  deb=$(ls "${DOWNLOAD_DIR}"/rustdesk-*.deb 2>/dev/null | sort -V | tail -n1 || true)
  if [ -z "$deb" ]; then
    log_info "No local rustdesk*.deb in ${DOWNLOAD_DIR}; downloading the latest release"
    local ver
    ver=$(curl -fsSL "${CURL_RETRY_ARGS[@]}" https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null \
      | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -z "$ver" ]; then
      log_err "Could not determine the latest RustDesk version from GitHub"
      return 1
    fi
    deb="${DOWNLOAD_DIR}/rustdesk-${ver}-${asset_arch}.deb"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" \
      "https://github.com/rustdesk/rustdesk/releases/download/${ver}/rustdesk-${ver}-${asset_arch}.deb"; then
      log_err "Could not download RustDesk ${ver} for ${asset_arch}"
      return 1
    fi
  else
    log_info "Using local package: $(basename "$deb")"
  fi
  run sudo apt-get install -y "$deb" || run sudo apt-get install -f -y
}

# RustDesk's preview build for true unattended access on Wayland (reachable
# even from the GDM login screen after reboot, per the blog post above).
# Verifies what's currently installed against the latest preview asset and
# removes+reinstalls when they differ, since the preview build reuses the
# "rustdesk" package name/version scheme so a plain `apt install` of the new
# .deb over an old one (stable or a stale preview) can silently no-op.
step_remote_rustdesk_wayland_preview() {
  local asset_arch="$1"
  log_info "Ubuntu 26+ (GNOME Wayland-only) or RUSTDESK_WAYLAND_PREVIEW=true: using RustDesk's"
  log_info "unattended-Wayland preview build (rustdesk.com/blog/unattended-remote-access-wayland)."
  log_warn "This is a RustDesk preview/nightly build (still under real-world testing upstream),"
  log_warn "not a stable release - set RUSTDESK_WAYLAND_PREVIEW=false to stay on stable instead."

  if $DRY_RUN; then
    log_info "[dry-run] would resolve the current rustdesk-unattended-wayland-*-${asset_arch}.deb"
    log_info "[dry-run] asset from the 'nightly' GitHub release, remove any existing rustdesk"
    log_info "[dry-run] package if it doesn't match what's already installed, then install it"
    return 0
  fi

  local info name url
  if ! info=$(rustdesk_wayland_preview_asset "$asset_arch"); then
    log_err "Could not resolve the rustdesk-unattended-wayland preview asset from GitHub."
    log_warn "Falling back to the regular stable RustDesk release."
    step_remote_rustdesk_stable "$asset_arch"
    return $?
  fi
  name="${info%% *}"
  url="${info#* }"

  run mkdir -p "$RUSTDESK_STATE_DIR"
  local installed_marker=""
  [ -f "$RUSTDESK_WAYLAND_MARKER" ] && installed_marker=$(cat "$RUSTDESK_WAYLAND_MARKER" 2>/dev/null || true)

  if has_cmd rustdesk && [ "$installed_marker" = "$name" ]; then
    log_info "RustDesk unattended-Wayland preview (${name}) already installed and up to date, skipping"
    return 0
  fi

  local existing_pkg
  if existing_pkg=$(rustdesk_installed_package); then
    log_info "Removing the existing RustDesk package (${existing_pkg}) before installing ${name}"
    run sudo apt-get remove -y "$existing_pkg" || log_warn "Could not cleanly remove ${existing_pkg}; continuing anyway"
  fi

  local deb="${DOWNLOAD_DIR}/${name}"
  if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$deb" "$url"; then
    log_err "Could not download ${name} from ${url}"
    return 1
  fi
  if ! run sudo apt-get install -y "$deb"; then
    run sudo apt-get install -f -y || { log_err "Failed to install ${name}"; return 1; }
  fi
  printf '%s' "$name" >"$RUSTDESK_WAYLAND_MARKER"
  log_ok "Installed RustDesk unattended-Wayland preview build: ${name}"
}

step_remote_rustdesk() {
  load_env_file
  local arch asset_arch
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64) asset_arch="x86_64" ;;
    arm64) asset_arch="aarch64" ;;
    *) log_err "Unsupported architecture for RustDesk: ${arch}"; return 1 ;;
  esac

  if rustdesk_wayland_preview_wanted; then
    step_remote_rustdesk_wayland_preview "$asset_arch" || return 1
  else
    step_remote_rustdesk_stable "$asset_arch" || return 1
  fi

  local pw="${RUSTDESK_PASSWORD:-${REMOTE_PASSWORD:-}}"
  if [ -n "$pw" ]; then
    if $DRY_RUN; then
      log_info "[dry-run] would set the RustDesk permanent password (value withheld from this log)"
    else
      # The .deb (stable and preview builds alike) registers RustDesk as a
      # root systemd service, so the permanent password has to be set with
      # sudo - without it, `rustdesk --password` still exits 0 but silently
      # does nothing, printing "Installation and administrative privileges
      # required!" instead (confirmed: it never returns non-zero for this).
      local pw_out
      pw_out=$(sudo rustdesk --password "$pw" 2>&1)
      if printf '%s' "$pw_out" | grep -qi "administrative privileges required"; then
        log_err "Could not set the RustDesk permanent password - rustdesk reported:"
        log_err "  ${pw_out}"
        log_err "Set it by hand with: sudo rustdesk --password <password>"
        return 1
      fi
      log_ok "RustDesk permanent password set."
    fi
    log_info "Verify unattended access with a real remote connection, and treat the"
    log_info "remote_gnome_desktop step (GNOME's own RDP) as the guaranteed portal-free"
    log_info "fallback if RustDesk capture ever misbehaves."
  else
    log_warn "No RUSTDESK_PASSWORD/REMOTE_PASSWORD in ${ENV_FILE}; RustDesk is installed but has"
    log_warn "no permanent access password set - set one with: sudo rustdesk --password <password>"
  fi
  return 0
}

# Interactive DWService install only. Silent/unattended install is a
# business/org-account feature and is not available for normal/personal
# accounts, there is no silent step anymore.
step_remote_dwservice() {
  if has_cmd dwagent || [ -x /usr/share/dwagent/native/dwagent ] || \
    [ -x /usr/share/dwagent/dwagent.sh ] || \
    systemctl list-unit-files 2>/dev/null | grep -qiE '^dwagent'; then
    log_info "DWService agent already installed, skipping"
    return 0
  fi

  # Skip under unattended -y full runs unless explicitly --only=remote_dwservice
  if $ASSUME_YES && [ -z "$ONLY_LIST" ]; then
    log_warn "Skipping - DWService needs the interactive installer wizard and can't"
    log_warn "run under an unattended -y full run. Run it on its own:"
    log_warn "  ./dev-setup.sh --only=remote_dwservice"
    return 1
  fi

  load_env_file
  local code="" code_label=""
  if [ -n "${DWSERVICE_KEY:-}" ]; then
    code="$DWSERVICE_KEY"; code_label="installation code (DWSERVICE_KEY)"
  elif [ -n "${DWSERVICE_PASSWORD:-}" ]; then
    code="$DWSERVICE_PASSWORD"; code_label="agent installation password (DWSERVICE_PASSWORD)"
  else
    log_warn "No DWSERVICE_KEY or DWSERVICE_PASSWORD in ${ENV_FILE} to copy to the clipboard;"
    log_warn "you'll need to enter one by hand when the installer asks for it."
  fi

  local installer="${DOWNLOAD_DIR}/dwagent.sh"
  # Re-download if missing, empty, or looks like an HTML error page.
  local need_dl=true
  if [ -s "$installer" ] && [ "$(wc -c <"$installer")" -gt 10000 ]; then
    if head -n1 "$installer" | grep -qE '^#!|^#'; then
      need_dl=false
      log_info "Using existing installer: ${installer}"
    fi
  fi
  if $need_dl; then
    rm -f "$installer"
    if ! run curl -fsSL "${CURL_RETRY_ARGS[@]}" -o "$installer" https://www.dwservice.net/download/dwagent.sh; then
      log_err "Could not download the DWService installer"
      return 1
    fi
  fi
  run chmod +x "$installer"

  if $DRY_RUN; then
    log_info "[dry-run] would copy the DWService code to the clipboard, then run the"
    log_info "[dry-run] interactive console installer (dwagent.sh -console)"
    return 0
  fi

  if [ -n "$code" ]; then
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
      log_warn "No graphical session detected in this shell; skipping clipboard copy."
      log_warn "Copy the ${code_label} from ${ENV_FILE} by hand when the wizard asks."
    else
      if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if ! has_cmd wl-copy; then
          apt_install wl-clipboard || log_warn "Could not install wl-clipboard; skipping clipboard copy."
        fi
        if has_cmd wl-copy; then
          printf '%s' "$code" | wl-copy
          log_ok "Copied the DWService ${code_label} to your clipboard (wl-copy)."
        fi
      elif has_cmd xclip; then
        printf '%s' "$code" | xclip -selection clipboard
        log_ok "Copied the DWService ${code_label} to your clipboard (xclip)."
      elif has_cmd xsel; then
        printf '%s' "$code" | xsel --clipboard --input
        log_ok "Copied the DWService ${code_label} to your clipboard (xsel)."
      else
        log_warn "No clipboard tool; paste the ${code_label} from ${ENV_FILE} by hand."
      fi
    fi
  fi

  # Always use -console: the GUI under sudo fails on Wayland (root has no
  # access to the user Wayland socket), which is Ubuntu 26's only GNOME session.
  # Official docs endorse: sudo bash dwagent.sh -console
  log_info "Launching DWService console wizard (dwagent.sh -console)."
  log_info "GUI under sudo does not work on Wayland. Use #BACK / #EXIT in the prompts."
  log_info "Choose Install, confirm path, then enter code or create agent with credentials."
  if ! sudo bash "$installer" -console; then
    log_warn "The installer exited non-zero; checking what it left behind anyway."
  fi

  log_info "Waiting up to 60s for the dwagent service to come up..."
  local waited=0
  while [ "$waited" -lt 60 ]; do
    if sudo systemctl is-active --quiet dwagent.service 2>/dev/null \
      || sudo systemctl is-active --quiet dwagentd 2>/dev/null \
      || sudo systemctl is-active --quiet dwagent 2>/dev/null; then
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done

  log_info "Checking the resulting DWService status..."
  dwservice_status
}

# Checks (and logs) current DWService agent status - shared by remote_check.
dwservice_status() {
  if [ -x /usr/share/dwagent/native/dwagent ] || [ -x /usr/share/dwagent/dwagent.sh ] \
    || systemctl list-unit-files 2>/dev/null | grep -qiE '^dwagent'; then
    if ! $DRY_RUN; then
      if sudo systemctl is-active --quiet dwagent.service 2>/dev/null \
        || sudo systemctl is-active --quiet dwagentd 2>/dev/null \
        || sudo systemctl is-active --quiet dwagent 2>/dev/null; then
        log_ok "dwagent service is active"
        return 0
      fi
    fi
    log_warn "dwagent installed but its service state could not be confirmed active"
    return 1
  fi
  log_warn "DWService (dwagent) not installed"
  return 1
}

step_remote_vnc() {
  # Same role as Windows remote_vnc (TightVNC Server): share this desktop on
  # port 5900 with REMOTE_PASSWORD. Prefer GNOME Remote Desktop's native VNC
  # (Wayland-safe, same stack as remote_gnome_desktop); fall back to TigerVNC
  # x0vncserver on X11.
  load_env_file
  local pw="${REMOTE_PASSWORD:-}"
  if [ -z "$pw" ]; then
    log_warn "No REMOTE_PASSWORD in ${ENV_FILE}; VNC server would be passwordless, skipping."
    return 1
  fi
  log_info "VNC uses REMOTE_PASSWORD as the VNC secret only (no new Linux login)."

  if ! has_cmd grdctl; then
    apt_install gnome-remote-desktop || true
  fi

  local used_grd=false
  if has_cmd grdctl && grdctl --help 2>/dev/null | grep -qiE '(^|[[:space:]])vnc'; then
    if $DRY_RUN; then
      log_info "[dry-run] would enable GNOME Remote Desktop VNC (port 5900) with REMOTE_PASSWORD"
      used_grd=true
    elif has_session_bus; then
      run grdctl vnc set-auth-method password || true
      run grdctl vnc set-password "$pw" || log_warn "grdctl vnc set-password failed"
      run grdctl vnc disable-view-only || true
      if run grdctl vnc enable; then
        used_grd=true
        run systemctl --user enable --now gnome-remote-desktop.service || true
        log_ok "GNOME Remote Desktop VNC enabled (shares this session, port 5900)"
      fi
      if run sudo grdctl --system vnc set-auth-method password \
        && run sudo grdctl --system vnc set-password "$pw" \
        && run sudo grdctl --system vnc disable-view-only \
        && run sudo grdctl --system vnc enable; then
        run sudo systemctl enable --now gnome-remote-desktop.service || true
        log_ok "System-level (GDM) VNC login enabled"
      else
        log_warn "System-level VNC (GDM) could not be fully configured; per-session VNC may still work"
      fi
    else
      log_warn "No desktop session bus; cannot enable GNOME VNC from this shell."
    fi
  fi

  if ! $used_grd && ! $DRY_RUN; then
    log_info "GNOME VNC is not available here; installing TigerVNC scraping server (X11 current display)"
    apt_install tigervnc-scraping-server tigervnc-common || {
      log_err "Could not install a VNC server"
      return 1
    }
    run mkdir -p "${HOME}/.vnc"
    local passfile="${HOME}/.vnc/passwd"
    if $DRY_RUN; then
      log_info "[dry-run] would write ${passfile} via vncpasswd and enable x0vncserver"
    else
      printf '%s\n' "$pw" | vncpasswd -f >"$passfile"
      chmod 600 "$passfile"
      local unit_dir="${HOME}/.config/systemd/user"
      run mkdir -p "$unit_dir"
      cat >"${unit_dir}/x0vncserver.service" <<EOF
[Unit]
Description=TigerVNC scraping server (share existing display)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/x0vncserver -display :0 -rfbport 5900 -PasswordFile %h/.vnc/passwd -localhost no
Restart=on-failure

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload || true
      systemctl --user enable --now x0vncserver.service || log_warn "Could not start x0vncserver (needs an X11 graphical session)"
    fi
  elif $DRY_RUN && ! $used_grd; then
    log_info "[dry-run] would enable GNOME VNC if grdctl supports it, else TigerVNC x0vncserver"
  fi

  if has_cmd ufw; then
    local ufw_line
    ufw_line=$(sudo ufw status 2>/dev/null | head -n1 || true)
    [[ "$ufw_line" == *"active"* ]] && run sudo ufw allow 5900/tcp
  fi
  return 0
}

# Read-only status report, and it deliberately separates "you did not enable
# this" (informational - skipping remote_rdp is a legitimate choice, and this
# step used to report FAILED for it) from "installed but not working", which
# is the only condition worth failing the step over. Mirrors
# Step_remote_check in dev-setup.ps1.
step_remote_check() {
  local broken=() off=()

  log_info "=== SSH ==="
  if has_cmd sshd; then
    if $DRY_RUN; then
      log_info "[dry-run] would check ssh.service status, port 22, and password auth"
    else
      if sudo systemctl is-active --quiet ssh.service; then
        log_ok "ssh.service is active"
      else
        log_warn "ssh.service is not active"
        broken+=("SSH (installed but stopped)")
      fi
      if sudo ss -tuln 2>/dev/null | grep -q ':22 '; then
        log_ok "listening on port 22"
      else
        log_warn "nothing listening on port 22"
        broken+=("SSH (nothing on port 22)")
      fi
      local pwauth
      pwauth=$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
      if [ "$pwauth" = "yes" ]; then
        log_ok "PasswordAuthentication is enabled"
      else
        log_info "PasswordAuthentication is off (value: ${pwauth:-unknown}) - fine if you use keys only"
      fi
    fi
  else
    log_info "openssh-server not installed (remote_ssh not run)"
    off+=("SSH")
  fi

  log_info "=== GNOME Remote Desktop (RDP) ==="
  if has_cmd grdctl; then
    run grdctl status
    if ! $DRY_RUN; then
      sudo grdctl --system status 2>/dev/null || log_warn "System-level (GDM) remote login is not configured/enabled"
    fi
  else
    log_info "grdctl / gnome-remote-desktop not installed (remote_gnome_desktop not run)"
    off+=("RDP")
  fi

  log_info "=== RustDesk ==="
  if has_cmd rustdesk; then
    log_ok "rustdesk installed"
    if [ -f "${HOME}/.config/rustdesk/RustDesk.toml" ]; then
      log_ok "RustDesk has a local config (password likely set)"
    else
      log_warn "No RustDesk.toml found yet - run it once or set a password"
      broken+=("RustDesk (installed, no config/password)")
    fi
  else
    log_info "rustdesk not installed (remote_rustdesk not run)"
    off+=("RustDesk")
  fi

  log_info "=== VNC ==="
  if $DRY_RUN; then
    log_info "[dry-run] would check port 5900 and grdctl VNC status"
  elif sudo ss -tuln 2>/dev/null | grep -q ':5900 '; then
    log_ok "listening on port 5900"
  elif has_cmd x0vncserver || has_cmd grdctl; then
    log_warn "a VNC server is installed but nothing is listening on port 5900"
    broken+=("VNC (installed but not listening)")
  else
    log_info "no VNC server installed (remote_vnc not run)"
    off+=("VNC")
  fi

  log_info "=== DWService ==="
  if dwservice_status; then
    :
  elif [ -x /usr/share/dwagent/dwagent.sh ]; then
    broken+=("DWService (installed but not active)")
  else
    off+=("DWService")
  fi

  if has_cmd ufw && ! $DRY_RUN; then
    log_info "=== Firewall (ufw) ==="
    sudo ufw status verbose 2>/dev/null || true
  fi

  if ! $DRY_RUN; then
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ip" ] && log_info "Reachable at ${ip} - SSH: ssh ${REMOTE_USER_EFFECTIVE:-${REMOTE_USER:-<user>}}@${ip} | RDP: ${ip}:3389 | VNC: ${ip}:5900"
  fi

  log_info "=== Result ==="
  if [ "${#off[@]}" -gt 0 ]; then
    log_info "Not enabled (fine if that was deliberate): ${off[*]}"
  fi
  if [ "${#broken[@]}" -gt 0 ]; then
    log_err "Enabled but not working: ${broken[*]}"
    return 1
  fi
  log_ok "Nothing is half-configured: everything installed here is running."
  return 0
}

# ---------------------------------------------------------------------------
# Battery charge limiting: caps charging around BATTERY_CHARGE_LIMIT%
# (default 80) on laptops whose kernel driver exposes a charge-threshold
# sysfs control (ThinkPad's thinkpad_acpi, and increasingly ASUS/Dell/
# Lenovo IdeaPad/Huawei/System76 models on a recent kernel). Keeping a
# lithium battery below ~80-90% instead of always topping it up to 100% is
# one of the best-documented ways to slow its long-term wear.
# ---------------------------------------------------------------------------

# Echoes the first writable charge-threshold sysfs path found across all
# BAT* power supplies, trying both attribute names different drivers use.
# Empty/failure means this hardware/kernel doesn't expose the control.
battery_charge_threshold_path() {
  local bat attr
  for bat in /sys/class/power_supply/BAT*; do
    [ -d "$bat" ] || continue
    for attr in charge_control_end_threshold charge_stop_threshold; do
      [ -f "${bat}/${attr}" ] && { printf '%s\n' "${bat}/${attr}"; return 0; }
    done
  done
  return 1
}

# Design vs current full-charge capacity, straight from the battery firmware.
# Read-only. Worth printing because a heavily worn cell is the reason to
# start capping in the first place (mirrors Write-BatteryWearReport in the
# PowerShell script). Drivers publish either energy_* (uWh) or charge_*
# (uAh); either ratio is equally valid.
battery_wear_report() {
  local bat design full unit
  for bat in /sys/class/power_supply/BAT*; do
    [ -d "$bat" ] || continue
    for unit in energy charge; do
      [ -r "${bat}/${unit}_full_design" ] && [ -r "${bat}/${unit}_full" ] || continue
      design=$(cat "${bat}/${unit}_full_design")
      full=$(cat "${bat}/${unit}_full")
      [ "${design:-0}" -gt 0 ] 2>/dev/null || continue
      local health=$(( 100 * full / design ))
      log_info "Battery health ($(basename "$bat")): ${health}% of original capacity"
      [ "$health" -lt 80 ] && log_warn "This cell has already lost over 20% of its design capacity."
      return 0
    done
  done
  return 0
}

# No sysfs threshold on this machine. That is unsupported hardware, not a
# script failure, so this reports the free options that remain and returns
# success - same posture as Step_battery_charge_limit in dev-setup.ps1.
battery_charge_limit_guidance() {
  local limit="$1" vendor=""
  has_cmd dmidecode && vendor=$(sudo dmidecode -s system-manufacturer 2>/dev/null || true)
  [ -z "$vendor" ] && [ -r /sys/class/dmi/id/sys_vendor ] && vendor=$(cat /sys/class/dmi/id/sys_vendor)

  log_warn "This kernel/driver exposes no charge-threshold control under"
  log_warn "/sys/class/power_supply/BAT*/ (checked charge_control_end_threshold and"
  log_warn "charge_stop_threshold), so there is nothing to write directly."
  log_info "Vendor: ${vendor:-unknown}. Free options that remain, best first:"
  log_info "  1. UEFI/firmware. A cap set there survives OS reinstalls and applies while the"
  log_info "     machine is asleep or off. Look for 'Battery Charge Threshold', 'FlexiCharger',"
  log_info "     'Battery Health Manager', or 'Charge Limit' in setup."
  case "$vendor" in
    *LENOVO*|*Lenovo*)
      log_info "  2. ThinkPads expose the sysfs control through thinkpad_acpi's natacpi path:"
      log_info "     check 'sudo modprobe thinkpad_acpi' and a kernel >= 5.17, then re-run this step."
      ;;
    *ASUS*|*ASUSTeK*)
      log_info "  2. ASUS models need the asus-nb-wmi / asus_wmi_battery driver:"
      log_info "     'sudo modprobe asus_nb_wmi' then re-run this step."
      ;;
    *Dell*|*Alienware*)
      log_info "  2. Dell exposes start/stop levels only in BIOS setup (Power > Battery"
      log_info "     Configuration > Custom), not through sysfs - use option 1."
      ;;
    *)
      log_info "  2. Check whether a vendor kernel module for your model publishes the"
      log_info "     threshold: 'ls /sys/class/power_supply/BAT0/' after loading it."
      ;;
  esac
  log_info "  3. TLP (free, in Ubuntu's archive) manages START/STOP_CHARGE_THRESH_BAT0, but it"
  log_info "     drives the same sysfs attributes this step uses - so it adds persistence, not"
  log_info "     hardware support, and it will not help here either. This script deliberately"
  log_info "     does not install it: TLP conflicts with power-profiles-daemon, which the"
  log_info "     power_management step relies on for its AC/battery profile switching."
  log_info "Target from .env was ${limit}%; nothing was changed."
}

step_battery_charge_limit() {
  if ! ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    log_info "No battery detected (desktop); nothing to cap. Re-run this step on a laptop:"
    log_info "  ./dev-setup.sh --only=battery_charge_limit"
    return 0
  fi

  load_env_file
  local limit="${BATTERY_CHARGE_LIMIT:-80}"
  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -lt 20 ] || [ "$limit" -gt 100 ]; then
    log_warn "BATTERY_CHARGE_LIMIT='${limit}' looks invalid (expected 20-100); using 80 instead"
    limit=80
  fi
  battery_wear_report

  local threshold_path
  if ! threshold_path=$(battery_charge_threshold_path); then
    battery_charge_limit_guidance "$limit"
    return 0
  fi
  log_info "Found charge-threshold control: ${threshold_path}"

  if $DRY_RUN; then
    log_info "[dry-run] would set it to ${limit} now, and install a boot-time service so it's"
    log_info "[dry-run] reapplied every boot (some drivers forget it across a power cycle)"
    return 0
  fi

  if ! printf '%s' "$limit" | sudo tee "$threshold_path" >/dev/null; then
    log_err "Could not write to ${threshold_path}"
    return 1
  fi
  log_ok "Battery charge threshold set to ${limit}%"

  # ThinkPads and a few other drivers also expose a start threshold, and will
  # refuse to stop charging (or oscillate around the cap) unless it sits
  # below the stop value. Best-effort: absent on drivers that only have a
  # stop threshold, which is fine.
  local start_path start_value
  start_value=$(( limit > 25 ? limit - 5 : limit ))
  for start_path in "$(dirname "$threshold_path")/charge_control_start_threshold" \
                    "$(dirname "$threshold_path")/charge_start_threshold"; do
    if [ -f "$start_path" ]; then
      if printf '%s' "$start_value" | sudo tee "$start_path" >/dev/null 2>&1; then
        log_ok "Charge start threshold set to ${start_value}% (resumes charging below that)"
      fi
      break
    fi
  done

  local hook="/usr/local/bin/dev-setup-battery-charge-limit.sh"
  # shellcheck disable=SC2016  # single-quoted on purpose: $1/${bat}/${attr} must stay literal in the written script
  local hook_content='#!/bin/sh
# Written by dev-setup.sh - reapplies the battery charge-stop threshold
# (passed as $1) at boot; not every driver remembers it across a power
# cycle the way ThinkPads typically do.
limit="$1"
for bat in /sys/class/power_supply/BAT*; do
  for attr in charge_control_end_threshold charge_stop_threshold; do
    [ -f "${bat}/${attr}" ] && echo "$limit" > "${bat}/${attr}" 2>/dev/null
  done
done
'
  printf '%s' "$hook_content" | sudo tee "$hook" >/dev/null
  run sudo chmod 755 "$hook"

  local unit="/etc/systemd/system/dev-setup-battery-charge-limit.service"
  local unit_content="[Unit]
Description=Reapply dev-setup.sh battery charge threshold
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${hook} ${limit}

[Install]
WantedBy=multi-user.target
"
  printf '%s' "$unit_content" | sudo tee "$unit" >/dev/null
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now dev-setup-battery-charge-limit.service
  return 0
}

# ---------------------------------------------------------------------------
# Power management: never sleep / never blank the screen while on AC power,
# max performance while plugged in. Battery-only behavior is left at its
# defaults unless there's no battery at all (desktop).
# ---------------------------------------------------------------------------

step_power_management() {
  local has_battery=false
  ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && has_battery=true
  log_info "Detected: $(hostnamectl chassis 2>/dev/null || echo unknown) chassis, battery present: ${has_battery}"

  # systemd-logind: authoritative for the physical lid switch. Write the drop-in
  # always, but NEVER restart systemd-logind while a graphical session is active , 
  # that tears down GNOME/Wayland (session hang / forced re-login on Ubuntu 26).
  local logind_dir="/etc/systemd/logind.conf.d" logind_conf
  if $has_battery; then
    # Laptop: never suspend on lid-close while charging; leave the normal
    # suspend-on-lid-close behavior in place when running on battery.
    logind_conf='[Login]
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
'
  else
    logind_conf='[Login]
IdleAction=ignore
'
  fi
  if $DRY_RUN; then
    log_info "[dry-run] would write ${logind_dir}/99-dev-setup-power.conf (no logind restart on active desktop):"
    printf '%s\n' "$logind_conf"
  else
    run sudo mkdir -p "$logind_dir"
    printf '%s' "$logind_conf" | sudo tee "${logind_dir}/99-dev-setup-power.conf" >/dev/null
    if graphical_session_active; then
      log_warn "Graphical session detected, not restarting systemd-logind (that would kill this desktop)."
      log_info "Lid/idle logind rules are on disk; they apply after reboot or next login."
    else
      # Headless / SSH-only: reload if supported, else restart.
      if systemctl show systemd-logind.service -p CanReload --value 2>/dev/null | grep -qx yes; then
        run sudo systemctl reload systemd-logind || \
          log_warn "Could not reload systemd-logind; rules apply on next boot"
      else
        run sudo systemctl restart systemd-logind || \
          log_warn "Could not restart systemd-logind; rules apply on next boot"
      fi
    fi
  fi

  # GNOME settings-daemon: idle-triggered suspend + screen blank. Needs a
  # desktop session bus; skip gracefully when run headless (logind rules
  # above still apply either way). Avoid aggressive settings that crash
  # Ubuntu 26 Wayland, only change AC idle/suspend and screensaver enable.
  if ! has_session_bus; then
    log_warn "No desktop session bus found; skipping GNOME idle/suspend gsettings."
  else
    run user_gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
    run user_gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0 || true
    # Prefer a long idle delay over 0 on Wayland: some Ubuntu 26 builds mishandle
    # idle-delay=0 together with session inhibitors.
    if [ -n "${WAYLAND_DISPLAY:-}" ] || graphical_session_active; then
      run user_gsettings set org.gnome.desktop.session idle-delay "uint32 3600" || true
      log_info "Wayland/desktop: screen idle-delay set to 1h (not 0) to avoid compositor lockups."
    else
      run user_gsettings set org.gnome.desktop.session idle-delay "uint32 0" || true
    fi
    run user_gsettings set org.gnome.desktop.screensaver idle-activation-enabled false || true
    if $has_battery; then
      run user_gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing' || true
      log_info "Battery sleep/lid settings left at their defaults - only plugged-in behavior changed."
    fi
  fi

  # power-profiles-daemon doesn't auto-switch profiles on its own; add a udev
  # rule that forces 'performance' while on AC and 'balanced' on battery.
  if has_cmd powerprofilesctl; then
    local hook="/usr/local/bin/dev-setup-power-profile.sh"
    # shellcheck disable=SC2016  # single-quoted on purpose: $1 must stay literal in the written script
    local hook_content='#!/bin/sh
if [ "$1" = "ac" ]; then
  powerprofilesctl set performance 2>/dev/null || true
else
  powerprofilesctl set balanced 2>/dev/null || true
fi
'
    local rule="/etc/udev/rules.d/99-dev-setup-power-profile.rules"
    local rule_content='SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/local/bin/dev-setup-power-profile.sh ac"
SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/local/bin/dev-setup-power-profile.sh battery"
'
    if $DRY_RUN; then
      log_info "[dry-run] would install ${hook} and ${rule} to force 'performance' on AC power"
    else
      printf '%s' "$hook_content" | sudo tee "$hook" >/dev/null
      run sudo chmod 755 "$hook"
      printf '%s' "$rule_content" | sudo tee "$rule" >/dev/null
      run sudo udevadm control --reload-rules
      if [ -e /sys/class/power_supply/ADP0/online ] && [ "$(cat /sys/class/power_supply/ADP0/online 2>/dev/null)" = "1" ]; then
        run sudo powerprofilesctl set performance || true
      elif ! $has_battery; then
        run sudo powerprofilesctl set performance || true
      fi
    fi
  else
    log_warn "power-profiles-daemon not found; skipping automatic performance-on-AC hook"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# General dev-workstation performance tuning.
# ---------------------------------------------------------------------------

step_perf_tuning() {
  local sysctl_conf='# Written by dev-setup.sh - raised file-watcher limits (VS Code, webpack,
# Docker, JetBrains all register inotify watches) and a lower swappiness,
# since this is a dev workstation with fast SSD/NVMe storage rather than a
# memory-constrained server.
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
vm.swappiness=10
'
  if $DRY_RUN; then
    log_info "[dry-run] would write /etc/sysctl.d/99-dev-setup.conf:"
    printf '%s\n' "$sysctl_conf"
  else
    printf '%s' "$sysctl_conf" | sudo tee /etc/sysctl.d/99-dev-setup.conf >/dev/null
    run sudo sysctl --system
  fi

  if apt_pkg_available systemd-zram-generator; then
    apt_install systemd-zram-generator
    local zram_conf='[zram0]
zram-size = ram / 2
compression-algorithm = zstd
'
    if $DRY_RUN; then
      log_info "[dry-run] would write /etc/systemd/zram-generator.conf (zram = half of RAM, zstd)"
    else
      printf '%s' "$zram_conf" | sudo tee /etc/systemd/zram-generator.conf >/dev/null
      run sudo systemctl restart systemd-zram-setup@zram0.service || \
        log_info "zram swap will start on next boot"
    fi
  else
    log_warn "systemd-zram-generator not available on this release; skipping zram setup."
  fi

  # Quiet the desktop file-indexer (tracker/localsearch, whichever name this
  # release ships) so it isn't competing with builds/watchers for I/O. Masking
  # a unit that doesn't exist is a harmless no-op, so mask both names.
  if has_session_bus && ! $DRY_RUN; then
    user_gsettings set org.freedesktop.Tracker3.Miner.Files crawling-interval -2 2>/dev/null || true
    user_gsettings set org.freedesktop.Tracker3.Miner.Files enable-monitors false 2>/dev/null || true
    systemctl --user mask tracker-miner-fs-3.service localsearch-3.service 2>/dev/null || true
  fi
  return 0
}

step_desktop_prefs() {
  load_env_file
  local tz="${TIMEZONE:-}"
  local night_strength="${NIGHT_LIGHT_STRENGTH:-20}"
  local night_kelvin=5440
  if [[ "$night_strength" =~ ^[0-9]+$ ]]; then
    # 0% = 6500K (cool), 100% = 1200K (warm), same mapping as Windows Night Light.
    night_kelvin=$(awk -v p="$night_strength" 'BEGIN{ if(p<0)p=0; if(p>100)p=100; printf "%d", 6500 - (p/100.0)*5300 }')
  else
    night_strength=20
  fi
  if $DRY_RUN; then
    log_info "[dry-run] would set timezone ${tz:-(unchanged)}, GNOME dark mode, solid-color wallpaper, Night Light all day at ${night_strength}% (~${night_kelvin}K), Chrome as default browser"
    return 0
  fi
  if [ -n "$tz" ] && has_cmd timedatectl; then
    if run sudo timedatectl set-timezone "$tz"; then
      log_ok "Timezone set to ${tz}"
    else
      log_warn "Could not set timezone to ${tz}"
    fi
  fi
  if has_session_bus && has_cmd gsettings; then
    run user_gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    run user_gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' || true
    run user_gsettings set org.gnome.desktop.background picture-uri ''
    run user_gsettings set org.gnome.desktop.background picture-uri-dark ''
    run user_gsettings set org.gnome.desktop.background picture-options 'none'
    run user_gsettings set org.gnome.desktop.background primary-color '#202020'
    run user_gsettings set org.gnome.desktop.background secondary-color '#202020'
    run user_gsettings set org.gnome.desktop.screensaver picture-uri ''
    run user_gsettings set org.gnome.desktop.screensaver primary-color '#202020'
    log_ok "GNOME dark mode + solid #202020 wallpaper (no image)"

    # Night Light / blue-light filter for the full day at the requested warmth.
    if user_gsettings list-keys org.gnome.settings-daemon.plugins.color 2>/dev/null | grep -qx 'night-light-enabled'; then
      run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
      run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false || true
      run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from 0.0 || true
      run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to 24.0 || true
      run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature "uint32 ${night_kelvin}" || \
        run user_gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature "$night_kelvin" || true
      log_ok "GNOME Night Light on all day (0-24h), warmth ${night_strength}% (~${night_kelvin}K)"
    else
      log_warn "GNOME Night Light schema not available; skipped blue-light filter"
    fi
  else
    log_warn "No desktop session bus; skipped GNOME appearance settings"
  fi
  if has_cmd google-chrome || desktop_file_exists google-chrome.desktop; then
    run xdg-settings set default-web-browser google-chrome.desktop || true
    log_ok "Default web browser set to Chrome"
  fi
  return 0
}

step_desktop_cleanup() {
  local drop=(
    aisleriot gnome-mahjongg gnome-mines gnome-sudoku
    gnome-games
    gnome-weather gnome-maps gnome-tour gnome-clocks
    gnome-music gnome-contacts shotwell
    rhythmbox totem cheese
    thunderbird
  )
  local installed=() pkg
  for pkg in "${drop[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
      installed+=("$pkg")
    fi
  done
  if [ "${#installed[@]}" -eq 0 ]; then
    log_info "No Ubuntu games/weather/maps/tour/rhythmbox/totem/thunderbird packages from the cleanup list are installed"
    return 0
  fi
  log_info "Removing: ${installed[*]}"
  apt_update_once
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" || true
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  return 0
}

step_comms_zoom() {
  if snap list zoom-client >/dev/null 2>&1 || has_cmd zoom; then
    log_info "Zoom already installed, skipping"
    return 0
  fi
  run sudo snap install zoom-client
}

step_ai_media() {
  local ok=0
  # Free CLI tools for AI / local image+video+PDF work
  apt_install ffmpeg imagemagick poppler-utils qpdf tesseract-ocr tesseract-ocr-eng || ok=1
  if apt_pkg_available ocrmypdf; then
    apt_install ocrmypdf || ok=1
  elif has_cmd pipx || has_cmd python3; then
    if $DRY_RUN; then
      log_info "[dry-run] would pipx/pip install ocrmypdf"
    else
      if has_cmd pipx; then
        run pipx install ocrmypdf || run python3 -m pip install --user --upgrade ocrmypdf || ok=1
      else
        run python3 -m pip install --user --upgrade ocrmypdf || ok=1
      fi
    fi
  else
    log_warn "ocrmypdf package not available and no python3/pipx, skip searchable-PDF OCR CLI"
  fi
  return "$ok"
}

step_media_apps() {
  local ok=0
  # GUI media only (ffmpeg/OCR live in ai_media; Zoom is comms_zoom)
  apt_install vlc libavcodec-extra || ok=1
  if apt_pkg_available ubuntu-restricted-extras; then
    if $DRY_RUN; then
      log_info "[dry-run] would pre-accept the mscorefonts EULA and install ubuntu-restricted-extras"
    else
      echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' | sudo debconf-set-selections || true
      apt_install ubuntu-restricted-extras || log_warn "ubuntu-restricted-extras failed (optional codecs)"
    fi
  fi
  return "$ok"
}

# ---------------------------------------------------------------------------
# Health check: apt/snap packages this script can install, across every step
# above - looks for broken (half-installed) state to fix and updates to
# apply, and keeps the npm/pipx tool sets current too. Static lists here
# deliberately mirror what the install steps above actually install, rather
# than trying to derive them dynamically.
# ---------------------------------------------------------------------------

MANAGED_APT_PACKAGES=(
  ca-certificates curl wget gnupg lsb-release software-properties-common apt-transport-https tar psmisc
  git gh
  build-essential cmake ninja-build gdb clang lldb pkg-config ccache codeblocks
  zip unzip
  python3 python3-venv python3-pip python3-dev pipx
  php php-cli php-fpm php-common php-mysql php-pgsql php-sqlite3 php-mbstring php-xml php-curl php-zip php-bcmath php-gd php-intl
  code
  cursor chatgpt
  gnome-text-editor gedit evince marktext
  libreoffice
  remmina remmina-plugin-rdp remmina-plugin-vnc remmina-plugin-secret
  obs-studio
  vlc libavcodec-extra
  ffmpeg imagemagick poppler-utils qpdf tesseract-ocr tesseract-ocr-eng ocrmypdf
  tigervnc-scraping-server tigervnc-common
  p7zip-full unrar-free xz-utils zstd
  ripgrep fd-find bat fzf jq htop ncdu tmux tree glances tealdeer direnv iotop nethogs git-delta silversearcher-ag
  google-chrome-stable
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose-v2
  openssh-server gnome-remote-desktop
  rustdesk rustdesk-unattended-wayland
)

MANAGED_SNAP_PACKAGES=(kubectl yq glow postman slack teams-for-linux notion-snap notion-snap-reborn code zoom-client)

apt_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# True only for a genuinely broken dpkg state (reinstall-required, or stuck
# mid-install/mid-configure) - NOT for a package that was simply never
# installed or cleanly removed. dpkg keeps a status line ("unknown ok
# not-installed") for any package name it has ever seen in the apt cache,
# whether or not it was ever installed, so checking for "non-empty and not
# 'install ok installed'" alone would wrongly flag every never-installed
# package as broken.
apt_pkg_broken_status() {
  local st flag status
  st=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)
  [ -z "$st" ] && return 1
  flag=$(awk '{print $2}' <<<"$st")
  status=$(awk '{print $3}' <<<"$st")
  [ "$flag" = "reinstreq" ] && return 0
  case "$status" in
    half-installed|unpacked|half-configured|triggers-awaited|triggers-pending) return 0 ;;
    *) return 1 ;;
  esac
}

# Snap/GUI apps that commonly hold their own binary open during refresh.
# Same problem as Windows winget: upgrading while the app is running fails
# or leaves a half-updated install. Ask to close/kill, or skip.
declare -A SNAP_REFRESH_BLOCKERS=(
  [code]="code"
  [cursor]="cursor"
  [chromium]="chrome chromium"
  [firefox]="firefox"
  [slack]="slack"
  [postman]="postman"
)

resolve_snap_running_apps() {
  local snap="$1"
  local procs="${SNAP_REFRESH_BLOCKERS[$snap]:-}"
  [ -z "$procs" ] && return 0

  local running=() p
  for p in $procs; do
    pgrep -x "$p" >/dev/null 2>&1 && running+=("$p")
  done
  [ "${#running[@]}" -eq 0 ] && return 0

  log_warn "${snap} cannot refresh while these processes are running: ${running[*]}"
  if $DRY_RUN; then
    log_info "[dry-run] would ask: close/kill and refresh, or skip"
    return 0
  fi

  if $ASSUME_YES; then
    log_info "-y: sending TERM to ${running[*]} so ${snap} can refresh..."
    for p in "${running[@]}"; do
      pkill -TERM -x "$p" 2>/dev/null || true
    done
    sleep 2
    local left=()
    for p in "${running[@]}"; do
      if pgrep -x "$p" >/dev/null 2>&1; then
        pkill -KILL -x "$p" 2>/dev/null || true
        sleep 1
        pgrep -x "$p" >/dev/null 2>&1 && left+=("$p")
      fi
    done
    if [ "${#left[@]}" -gt 0 ]; then
      log_warn "Still running (${left[*]}) - skipping snap refresh for ${snap}"
      return 1
    fi
    return 0
  fi

  local ans
  read -r -p "  ${snap} is open. [C]lose/kill and refresh, [S]kip? [C/s] " ans </dev/tty || ans="s"
  [[ -z "$ans" || "$ans" =~ ^[Cc] ]] || {
    log_info "Skipping snap refresh for ${snap}"
    return 1
  }
  for p in "${running[@]}"; do
    pkill -TERM -x "$p" 2>/dev/null || true
  done
  sleep 2
  for p in "${running[@]}"; do
    pgrep -x "$p" >/dev/null 2>&1 && pkill -KILL -x "$p" 2>/dev/null || true
  done
  sleep 1
  for p in "${running[@]}"; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      log_warn "Could not stop ${p} - skipping ${snap}"
      return 1
    fi
  done
  log_ok "Processes closed; refreshing ${snap}"
  return 0
}

step_health_check() {
  log_info "Checking apt package state for everything this script manages..."
  apt_update_once

  local pkg broken=() installed=() upgradable=()
  for pkg in "${MANAGED_APT_PACKAGES[@]}"; do
    if apt_pkg_broken_status "$pkg"; then
      broken+=("$pkg")
    elif apt_pkg_installed "$pkg"; then
      installed+=("$pkg")
    fi
  done

  if [ "${#broken[@]}" -gt 0 ]; then
    log_warn "Broken/partially-installed apt packages found: ${broken[*]}"
    if $DRY_RUN; then
      log_info "[dry-run] would run: sudo apt-get install -y --reinstall ${broken[*]}"
    else
      run sudo apt-get install -y --reinstall "${broken[@]}" || \
        run sudo apt-get install -f -y || \
        log_warn "Could not automatically fix all broken packages; try 'sudo apt --fix-broken install' by hand"
    fi
  else
    log_ok "No broken apt packages among those this script manages"
  fi

  if [ "${#installed[@]}" -gt 0 ]; then
    local upgradable_out
    upgradable_out=$(apt list --upgradable 2>/dev/null || true)
    for pkg in "${installed[@]}"; do
      printf '%s' "$upgradable_out" | grep -q "^${pkg}/" && upgradable+=("$pkg")
    done
  fi

  if [ "${#upgradable[@]}" -gt 0 ]; then
    log_info "Updates available for: ${upgradable[*]}"
    if $DRY_RUN; then
      log_info "[dry-run] would run: sudo apt-get install -y --only-upgrade ${upgradable[*]}"
    else
      run sudo apt-get install -y --only-upgrade "${upgradable[@]}" || log_warn "Some apt upgrades failed"
    fi
  else
    log_ok "All managed apt packages are already up to date"
  fi

  if has_cmd snap; then
    log_info "Checking snap-managed apps..."
    local s notes snap_broken=() snap_installed=()
    for s in "${MANAGED_SNAP_PACKAGES[@]}"; do
      snap list "$s" >/dev/null 2>&1 || continue
      snap_installed+=("$s")
      notes=$(snap list "$s" 2>/dev/null | awk 'NR==2{print $NF}')
      [[ "$notes" == *broken* ]] && snap_broken+=("$s")
    done
    if [ "${#snap_broken[@]}" -gt 0 ]; then
      log_warn "Broken snaps found: ${snap_broken[*]}"
      for s in "${snap_broken[@]}"; do
        if $DRY_RUN; then
          log_info "[dry-run] would remove and reinstall broken snap: ${s}"
        else
          run sudo snap remove "$s" || true
          run sudo snap install "$s" || log_warn "Could not reinstall snap: ${s}"
        fi
      done
    fi
    if [ "${#snap_installed[@]}" -gt 0 ]; then
      if $DRY_RUN; then
        log_info "[dry-run] would refresh installed snaps: ${snap_installed[*]} (ask close/kill if running)"
        for s in "${snap_installed[@]}"; do
          resolve_snap_running_apps "$s" || true
        done
      else
        for s in "${snap_installed[@]}"; do
          resolve_snap_running_apps "$s" || continue
          run sudo snap refresh "$s" || log_warn "snap refresh failed: ${s}"
        done
      fi
    fi
  fi

  if has_cmd npm; then
    log_info "Updating global npm tools this script manages (${NPM_GLOBAL_TOOLS[*]})..."
    run npm update -g "${NPM_GLOBAL_TOOLS[@]}" || log_warn "npm update -g had issues"
  fi

  if has_cmd pipx; then
    log_info "Upgrading pipx-managed tools..."
    run pipx upgrade-all || log_warn "pipx upgrade-all had issues"
  fi

  if has_cmd composer; then
    log_info "Updating global composer tools this script manages (${COMPOSER_GLOBAL_PACKAGES[*]})..."
    run composer global update "${COMPOSER_GLOBAL_PACKAGES[@]}" || log_warn "composer global update had issues"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Pin the tools this script installs to the dock, skipping any that aren't
# actually present (so a partial run doesn't leave broken icons behind).
# ---------------------------------------------------------------------------

PIN_STATE_FILE="${STATE_DIR}/pinned-apps"

step_pin_apps() {
  if ! has_session_bus; then
    log_warn "No desktop session bus found (running headless/over SSH?); skipping dock pinning."
    return 1
  fi
  if ! has_cmd gsettings; then
    log_warn "gsettings not found; skipping dock pinning."
    return 1
  fi
  load_env_file

  # Not gated by a PIN_* flag - dev-setup.sh doesn't install these itself
  # (Terminal ships with Ubuntu), so always try to keep it pinned.
  local always_groups=(
    "Terminal:org.gnome.Ptyxis.desktop,org.gnome.Terminal.desktop,gnome-terminal.desktop"
  )
  # label:desktop-id-candidates:PIN_* env var - see .env-sample. Kept pinned
  # only while the matching flag is true (default true when unset, so an
  # .env with no PIN_* keys at all behaves exactly like before this feature).
  local flagged_groups=(
    "VS Code:code.desktop:PIN_VSCODE"
    "Cursor:cursor.desktop:PIN_CURSOR"
    "ChatGPT:chatgpt.desktop,ChatGPT.desktop,com.openai.chatgpt.desktop:PIN_CHATGPT"
    "Chrome:google-chrome.desktop,com.google.Chrome.desktop:PIN_CHROME"
    "LibreOffice:libreoffice-startcenter.desktop:PIN_LIBREOFFICE"
    "Postman:postman_postman.desktop,postman.desktop:PIN_POSTMAN"
    "Remmina:org.remmina.Remmina.desktop,remmina.desktop:PIN_REMMINA"
    "Slack:slack_slack.desktop,slack.desktop:PIN_SLACK"
    "Teams:teams-for-linux_teams-for-linux.desktop,com.github.IsmaelMartinez.teams_for_linux.desktop:PIN_TEAMS"
    "Notion:notion-snap_notion-snap.desktop,notion-snap-reborn_notion-snap-reborn.desktop:PIN_NOTION"
    "Pumble:pumble.desktop,Pumble.desktop:PIN_PUMBLE"
    "Linear:linear.desktop:PIN_LINEAR"
    "Clockify:clockify.desktop,Clockify.desktop,clockify-desktop.desktop:PIN_CLOCKIFY"
    "Text Editor:org.gnome.TextEditor.desktop,gnome-text-editor.desktop,gedit.desktop:PIN_EDITOR_PDF"
    "PDF Viewer:org.gnome.Evince.desktop,evince.desktop:PIN_EDITOR_PDF"
  )

  local desired=() group label ids envvar id id_list found
  for group in "${always_groups[@]}"; do
    label="${group%%:*}"; ids="${group#*:}"
    found=""
    IFS=',' read -r -a id_list <<<"$ids"
    for id in "${id_list[@]}"; do
      desktop_file_exists "$id" && { found="$id"; break; }
    done
    if [ -n "$found" ]; then
      desired+=("$found")
    else
      log_warn "${label}: no installed .desktop file found, skipping in dock"
    fi
  done

  for group in "${flagged_groups[@]}"; do
    IFS=':' read -r label ids envvar <<<"$group"
    found=""
    IFS=',' read -r -a id_list <<<"$ids"
    for id in "${id_list[@]}"; do
      desktop_file_exists "$id" && { found="$id"; break; }
    done
    if [ -z "$found" ]; then
      log_warn "${label}: no installed .desktop file found, skipping in dock"
      continue
    fi
    if flag_enabled "${!envvar:-}" true; then
      desired+=("$found")
    else
      log_info "${label}: ${envvar}=false in .env, will not be (re)pinned"
    fi
  done

  # Merge with what's on the dock right now, touching only what this script
  # itself has pinned before (tracked in PIN_STATE_FILE) - anything else
  # already there (Files, Settings, apps you pinned by hand) is left alone.
  local prev_managed=()
  [ -f "$PIN_STATE_FILE" ] && mapfile -t prev_managed <"$PIN_STATE_FILE"

  local current_raw current=()
  current_raw=$(user_gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
  while IFS= read -r id; do
    [ -n "$id" ] && current+=("$id")
  done < <(printf '%s' "$current_raw" | grep -oE "'[^']+'" | tr -d "'")

  local final=()
  for id in "${current[@]}"; do
    if array_contains "$id" "${prev_managed[@]}"; then
      array_contains "$id" "${desired[@]}" && final+=("$id")
    else
      final+=("$id")
    fi
  done
  for id in "${desired[@]}"; do
    array_contains "$id" "${final[@]}" || final+=("$id")
  done

  if [ "${#final[@]}" -eq 0 ]; then
    log_warn "No candidate apps found installed; leaving dock favorites unchanged."
    return 1
  fi

  if $DRY_RUN; then
    log_info "[dry-run] dock favorites would become: ${final[*]}"
    return 0
  fi

  local gvariant entry
  gvariant="["
  for entry in "${final[@]}"; do
    gvariant+="'${entry}', "
  done
  gvariant="${gvariant%, }]"
  run user_gsettings set org.gnome.shell favorite-apps "$gvariant"
  printf '%s\n' "${desired[@]}" >"$PIN_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Step registry
# ---------------------------------------------------------------------------
STEP_IDS=(prereqs path_check git_gh cpp_build java_scala dotnet python node_nvm php \
  docker kubectl \
  vscode vscode_ext \
  playwright postman_newman \
  cursor chatgpt \
  editor_pdf libreoffice archive_tools cli_tools ai_media \
  chrome remmina media_apps obs \
  comms_zoom comms_slack comms_teams comms_notion comms_pumble comms_linear comms_clockify \
  remote_ssh remote_gnome_desktop remote_vnc remote_rustdesk remote_dwservice remote_check \
  battery_charge_limit power_management perf_tuning desktop_prefs desktop_cleanup health_check pin_apps)

# Optional steps: default N, and skipped under -y unless --only=. Windows has
# cpp_msvc here; Linux has no multi-GB SDK twin (gcc/clang from cpp_build is
# already the light path), so this list stays empty unless something niche
# is added later.
OPT_IN_STEPS=()

is_opt_in_step() {
  local id="$1" s
  for s in "${OPT_IN_STEPS[@]+"${OPT_IN_STEPS[@]}"}"; do
    [ "$s" = "$id" ] && return 0
  done
  return 1
}

declare -A STEP_DESC=(
  [prereqs]="Base prerequisites (curl, wget, gnupg, ca-certificates...)"
  [path_check]="Verify PATH has this script's tool dirs, fixing/re-adding what's missing"
  [git_gh]="Git + GitHub CLI (gh); reads identity/token from .env, re-applies globally on change"
  [cpp_build]="C++ light toolchain (build-essential/gcc, cmake, ninja, gdb, clang, Code::Blocks) - no Windows-SDK-sized install on Linux"
  [java_scala]="Java + Scala + sbt via SDKMAN!"
  [dotnet]=".NET SDK (current LTS)"
  [python]="Python 3 + pipx + poetry/ruff/black/mypy/httpie/ipython"
  [node_nvm]="Node.js via nvm (current LTS) + npm/pnpm/yarn/typescript/eslint/prettier"
  [php]="PHP + Composer + Laravel installer (Laravel/CodeIgniter development)"
  [vscode]="Visual Studio Code"
  [vscode_ext]="VS Code extensions for the stacks present on this machine (--skip=docker,java_scala,... drops theirs)"
  [cursor]="Cursor (AI code editor)"
  [chatgpt]="ChatGPT desktop app (official OpenAI Linux client, public preview)"
  [editor_pdf]="Text editor + PDF reader + MarkText (Markdown)"
  [libreoffice]="LibreOffice"
  [postman_newman]="Postman + Newman CLI"
  [playwright]="Playwright (CLI + browsers)"
  [docker]="Docker Engine + Compose"
  [kubectl]="kubectl"
  [archive_tools]="Archive tools (zip, unzip, 7z, unrar, zstd)"
  [cli_tools]="CLI productivity/research tools (ripgrep, fd, bat, fzf, jq, yq, htop, glances, tmux, delta...)"
  [chrome]="Google Chrome"
  [remmina]="Remmina RDP/VNC/SSH client (viewer machines; Windows twin: vnc_viewer / TightVNC Viewer)"
  [media_apps]="VLC + extra codecs (GUI; ffmpeg/OCR in ai_media; Zoom is comms_zoom)"
  [obs]="OBS Studio (screen recording / streaming)"
  [ai_media]="AI/media CLI: ffmpeg, ImageMagick, poppler-utils, qpdf, tesseract, ocrmypdf"
  [comms_zoom]="Zoom (optional; separate from media_apps)"
  [desktop_prefs]="Timezone from TIMEZONE, GNOME dark mode, Night Light all day (20% warm), solid wallpaper, Chrome default"
  [desktop_cleanup]="Remove Ubuntu games, weather, maps, tour, Rhythmbox/Totem, Thunderbird"
  [remote_vnc]="VNC server on port 5900 only (GNOME Remote Desktop VNC or TigerVNC; password from .env). Skip on viewer-only machines"
  [comms_slack]="Slack"
  [comms_teams]="Microsoft Teams (community client)"
  [comms_notion]="Notion (community client)"
  [comms_pumble]="Pumble"
  [comms_linear]="Linear (web-app launcher)"
  [comms_clockify]="Clockify (time tracking)"
  [remote_ssh]="SSH remote login (openssh-server + password auth from .env). Never creates an OS user unless you confirm after an existence check."
  [remote_gnome_desktop]="GNOME Remote Desktop (native Wayland RDP, session + GDM login)"
  [remote_rustdesk]="RustDesk (stable, or the unattended-Wayland preview build on Ubuntu 26+; permanent password from .env)"
  [remote_dwservice]="DWService agent, interactive console wizard (-console); copies code to clipboard"
  [remote_check]="Verify remote access is enabled and configured"
  [battery_charge_limit]="Battery health: report wear, cap charging at BATTERY_CHARGE_LIMIT% where the driver allows it"
  [power_management]="Power: never sleep on AC; logind drop-in without killing desktop session"
  [perf_tuning]="Dev-workstation performance tuning (inotify limits, swappiness, zram)"
  [health_check]="Check managed apt/snap packages for broken/outdated state and fix/update them; refresh npm/pipx tools"
  [pin_apps]="Pin installed tools to the dock per PIN_* flags in .env, unpinning any that were turned off"
)

DESKTOP_STEPS=(
  vscode vscode_ext cursor chatgpt editor_pdf libreoffice postman_newman
  chrome remmina media_apps obs
  comms_zoom comms_slack comms_teams comms_notion comms_pumble comms_linear comms_clockify
  remote_gnome_desktop remote_vnc desktop_prefs desktop_cleanup pin_apps
)

detect_install_mode() {
  local p
  for p in ubuntu-desktop ubuntu-desktop-minimal ubuntu-gnome-desktop gnome-shell; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
      printf '%s\n' desktop
      return 0
    fi
  done
  if [ -d /usr/share/xsessions ] && ls /usr/share/xsessions/*.desktop >/dev/null 2>&1; then
    printf '%s\n' desktop
    return 0
  fi
  printf '%s\n' server
}

is_desktop_step() {
  local s
  for s in "${DESKTOP_STEPS[@]}"; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

append_skip() {
  local id="$1"
  if [ -z "$SKIP_LIST" ]; then
    SKIP_LIST="$id"
    return
  fi
  list_in "$id" "$SKIP_LIST" && return
  SKIP_LIST="${SKIP_LIST},${id}"
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
print_help() {
  cat <<EOF
dev-setup.sh v${SCRIPT_VERSION} - Ubuntu development environment bootstrapper

Installs a full dev workstation (languages, editors, Docker, CLI tools,
comms apps, remote access, power/perf tuning) in one run, step by step and
safe to re-run. See README.md for full details.

Usage: $0 [options]

Settings (git identity/token, remote-access credentials) are read from a
.env file next to this script - copy .env-sample to .env and fill it in.
Every step still works without one: git_gh falls back to asking on the
console, and the remote-access steps just get skipped.

Options:
  -y, --yes          Non-interactive: assume yes for every step
  -n, --dry-run       Print what would happen without changing anything
      --only=a,b,c    Only run these step ids
      --skip=a,b,c    Run everything except these step ids
      --profile=minimal  Core toolchain only
      --profile=server   Console/server: skip GUI apps (Chrome, Slack, VS Code, GNOME RDP/VNC...)
      --profile=desktop  Force GUI apps even on a server image
      --list          List step ids and descriptions, then exit
  -h, --help          Show this help

Step ids:
EOF
  local id
  for id in "${STEP_IDS[@]}"; do
    printf '  %-16s %s\n' "$id" "${STEP_DESC[$id]}"
  done
}

list_in() {
  local needle="$1" hay="$2" item
  IFS=',' read -r -a arr <<<"$hay"
  for item in "${arr[@]}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Windows uses vnc_viewer; Linux client step is remmina. Accept both (+ legacy rdp_client).
# remote_dwservice_manual was the old interactive id; silent step is gone, alias to remote_dwservice.
normalize_step_aliases() {
  local list="$1" out="" item
  [ -z "$list" ] && { printf '\n'; return 0; }
  IFS=',' read -r -a arr <<<"$list"
  for item in "${arr[@]}"; do
    item="${item// /}"
    [ -z "$item" ] && continue
    case "$item" in
      rdp_client|vnc_viewer) item=remmina ;;
      remote_dwservice_manual) item=remote_dwservice ;;
    esac
    if [ -n "$out" ]; then out="${out},${item}"; else out="$item"; fi
  done
  printf '%s\n' "$out"
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    --only=*) ONLY_LIST="${arg#*=}" ;;
    --skip=*) SKIP_LIST="${arg#*=}" ;;
    --profile=*)
      PROFILE="${arg#*=}"
      case "$PROFILE" in
        minimal)
          ONLY_LIST="prereqs,path_check,git_gh,dotnet,python,node_nvm,vscode,docker,cli_tools"
          ;;
        server|desktop) ;;
        *)
          echo "Unknown profile: ${PROFILE}" >&2; exit 1
          ;;
      esac
      ;;
    --list)
      for id in "${STEP_IDS[@]}"; do printf '%-16s %s\n' "$id" "${STEP_DESC[$id]}"; done
      exit 0
      ;;
    -h|--help) print_help; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      print_help
      exit 1
      ;;
  esac
done

ONLY_LIST="$(normalize_step_aliases "$ONLY_LIST")"
SKIP_LIST="$(normalize_step_aliases "$SKIP_LIST")"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "dev-setup.sh v${SCRIPT_VERSION} - log file: ${LOG_FILE}"
  $DRY_RUN && log_warn "DRY RUN: no changes will be made"
  load_env_file
  check_preconditions

  if [ "$PROFILE" = "desktop" ]; then
    INSTALL_MODE="desktop"
  elif [ "$PROFILE" = "server" ]; then
    INSTALL_MODE="server"
    local ds
    for ds in "${DESKTOP_STEPS[@]}"; do
      append_skip "$ds"
    done
  else
    INSTALL_MODE="$(detect_install_mode)"
  fi
  # Terminal/server boxes: prefer masking PackageKit so apt is not fought by the GUI stack.
  if [ "$INSTALL_MODE" = "server" ] && [ "${PACKAGEKIT_MODE:-auto}" = "auto" ]; then
    PACKAGEKIT_MODE=mask
    log_info "Server/console mode: PACKAGEKIT_MODE=mask (apt is primary; unattended-upgrades stays on)"
  fi
  log_info "Install mode: ${INSTALL_MODE} (desktop UI vs server/console)"
  if [ "$INSTALL_MODE" = "server" ]; then
    log_info "Console/server: desktop GUI steps default to skip. Use --profile=desktop to install them, or --profile=server to skip without asking."
  fi

  local id
  for id in "${STEP_IDS[@]}"; do
    if [ -n "$ONLY_LIST" ] && ! list_in "$id" "$ONLY_LIST"; then continue; fi
    if [ -n "$SKIP_LIST" ] && list_in "$id" "$SKIP_LIST"; then continue; fi

    # Only skip extensions when VS Code genuinely is not on this machine.
    # Declining "Install VS Code?" because it is already installed used to
    # silently skip vscode_ext too, which is the opposite of what answering
    # "n" there means.
    if [ "$id" = "vscode_ext" ] && [ "${RESULTS[vscode]:-}" = "skipped" ] && ! has_cmd code; then
      log_info "VS Code is not installed and the vscode step was skipped; skipping vscode_ext"
      RESULTS["$id"]="skipped"
      continue
    fi

    if [ -z "$ONLY_LIST" ]; then
      if is_opt_in_step "$id"; then
        if $ASSUME_YES; then
          log_info "Skipping optional step ${id} (default off under -y; pass --only=${id} to install)"
          RESULTS["$id"]="skipped"
          continue
        fi
        if ! confirm_no "Install (optional, default no): ${STEP_DESC[$id]}?"; then
          RESULTS["$id"]="skipped"
          continue
        fi
      elif is_desktop_step "$id" && [ "$INSTALL_MODE" = "server" ] && [ "$PROFILE" != "desktop" ]; then
        if $ASSUME_YES; then
          log_info "Server/console mode: skipping desktop step ${id} (pass --profile=desktop to install it)"
          RESULTS["$id"]="skipped"
          continue
        fi
        if ! confirm_no "Install (desktop UI, default skip on server): ${STEP_DESC[$id]}?"; then
          RESULTS["$id"]="skipped"
          continue
        fi
      elif ! confirm "Install: ${STEP_DESC[$id]}?"; then
        RESULTS["$id"]="skipped"
        continue
      fi
    fi

    run_step "$id" "${STEP_DESC[$id]}" "step_${id}"
  done

  printf '\n%s=== Summary ===%s\n' "$C_BOLD" "$C_RESET"
  local failed=()
  for id in "${STEP_IDS[@]}"; do
    local status="${RESULTS[$id]:-not run}"
    local color="$C_YELLOW"
    case "$status" in
      OK|dry-run) color="$C_GREEN" ;;
      FAILED|dry-run-error) color="$C_RED"; failed+=("$id") ;;
    esac
    printf '  %-16s %s%s%s\n' "$id" "$color" "$status" "$C_RESET"
  done
  printf '\nLog file: %s\n' "$LOG_FILE"
  if [ "${#failed[@]}" -gt 0 ]; then
    log_warn "Failed step(s): ${failed[*]}"
    log_warn "Re-run just those: ./dev-setup.sh --only=$(IFS=,; echo "${failed[*]}")"
  fi
  MAIN_FAILED_COUNT="${#failed[@]}"

  if ! $DRY_RUN; then
    cat <<'EOF'

Next steps:
  - Run `source ~/.bashrc` (or open a new terminal) to pick up nvm/sdkman/dotnet/PATH changes.
  - If Docker was installed, log out and back in (or run `newgrp docker`) to use it without sudo.
  - GUI apps installed via snap appear in your application launcher.
  - Log out and back in (or reboot) for power/idle and dock-pinning changes to fully apply.
  - If you set up remote access: run `./dev-setup.sh --only=remote_check` any time to verify
    SSH/RDP/RustDesk/DWService status. Your .env file holds plaintext credentials - keep it out
    of version control and delete it if you no longer need unattended password-based access.
EOF
  fi
}

# Non-zero on failure so CI and any wrapper can tell a clean run from a
# partial one without scraping the log (matches dev-setup.ps1).
MAIN_FAILED_COUNT=0
main "$@"
exit "$MAIN_FAILED_COUNT"
