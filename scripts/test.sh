#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Workstation Setup =="
bash -n dev-setup.sh
list="$(./dev-setup.sh --list)"
printf '%s\n' "$list"
for need in remote_vnc remmina obs ai_media comms_zoom desktop_prefs desktop_cleanup media_apps vscode_ext docker node_nvm cpp_build; do
  grep -q "^${need}" <<<"$list" || { echo "Missing step id in --list: $need" >&2; exit 1; }
done
if grep -qE '^remote_dwservice_manual' <<<"$list"; then
  echo "remote_dwservice_manual should not be a listed step (alias only)" >&2
  exit 1
fi
grep -q 'normalize_step_aliases' dev-setup.sh
grep -q 'step_obs' dev-setup.sh
grep -q 'step_ai_media' dev-setup.sh
grep -q 'step_comms_zoom' dev-setup.sh
grep -q 'obs-studio' dev-setup.sh
# Silent DWService path must be gone
if grep -qE 'step_remote_dwservice_manual|-silent "key=' dev-setup.sh; then
  echo "DWService silent/manual dual path should be removed" >&2
  exit 1
fi
grep -q 'resolve_snap_running_apps' dev-setup.sh
grep -q 'SNAP_REFRESH_BLOCKERS' dev-setup.sh
grep -q 'is_opt_in_step' dev-setup.sh
grep -q 'OPT_IN_STEPS' dev-setup.sh
# Linux must not grow a fake Windows-SDK step.
if grep -qE '^\s*cpp_msvc\)|step_cpp_msvc' dev-setup.sh; then
  echo "cpp_msvc is Windows-only; do not add it to dev-setup.sh" >&2
  exit 1
fi
docker_at="$(awk '/^docker/{print NR; exit}' <<<"$list")"
ext_at="$(awk '/^vscode_ext/{print NR; exit}' <<<"$list")"
if [ -z "$docker_at" ] || [ -z "$ext_at" ] || [ "$docker_at" -ge "$ext_at" ]; then
  echo "docker must run before vscode_ext" >&2
  exit 1
fi
for need in wait_for_apt_lock apt_lock_holders resolve_apt_lock_holders \
            stop_packagekit_soft graphical_session_active \
            install_marktext step_wanted detect_install_mode \
            battery_wear_report battery_charge_limit_guidance MAIN_FAILED_COUNT; do
  grep -q "$need" dev-setup.sh || { echo "Missing helper: $need" >&2; exit 1; }
done
grep -q 'marktext' <<<"$list" || grep -qi 'MarkText' <<<"$list" || {
  echo "editor_pdf list description should mention MarkText" >&2; exit 1
}
grep -q 'night-light-enabled' dev-setup.sh
grep -q 'NIGHT_LIGHT_STRENGTH' dev-setup.sh
grep -q 'PACKAGEKIT_MODE' dev-setup.sh
grep -q 'dwagent.sh -console' dev-setup.sh
grep -q 'not restarting systemd-logind' dev-setup.sh
grep -qi 'Night Light' <<<"$list" || {
  echo "desktop_prefs list description should mention Night Light" >&2; exit 1
}
# Must not restart logind unconditionally (kills desktop sessions).
if ! grep -q 'graphical_session_active' dev-setup.sh; then
  echo "power_management must guard logind restart with graphical_session_active" >&2
  exit 1
fi
# Prefer stopping PackageKit over deleting lock files.
if grep -qE 'rm -f .*/(lock|lock-frontend)' dev-setup.sh; then
  echo "Must not delete apt/dpkg lock files" >&2
  exit 1
fi
# Restart of logind may exist only inside the non-graphical branch.
if grep -nE 'systemctl restart systemd-logind' dev-setup.sh | grep -vq 'graphical_session_active'; then
  # Ensure every restart line is within ~30 lines after a graphical_session_active check.
  while IFS=: read -r lineno _; do
    [ -n "$lineno" ] || continue
    start=$((lineno > 40 ? lineno - 40 : 1))
    if ! sed -n "${start},${lineno}p" dev-setup.sh | grep -q 'graphical_session_active'; then
      echo "systemd-logind restart at line $lineno is not guarded by graphical_session_active" >&2
      exit 1
    fi
  done < <(grep -nE 'systemctl restart systemd-logind' dev-setup.sh || true)
fi
help="$(./dev-setup.sh --help)"
grep -q -- '--profile=server' <<<"$help"
echo "== dry-run battery_charge_limit + remote_check =="
# Both are report-only steps: neither may report FAILED just because a
# feature was deliberately left off / is unsupported by this hardware.
batt="$(./dev-setup.sh -n --only=battery_charge_limit)"
grep -q 'battery_charge_limit *dry-run' <<<"$batt" || {
  echo "battery_charge_limit must not fail on hardware with no threshold control" >&2
  printf '%s\n' "$batt" >&2; exit 1
}
grep -q 'step_battery_charge_limit\|battery_charge_limit' <<<"$batt"
echo "== dry-run vscode_ext with docker+scala skipped =="
dry="$(./dev-setup.sh -n --only=vscode_ext --skip=docker,java_scala)"
grep -q 'Skipping VS Code extensions for stacks not present or skipped this run' <<<"$dry"
grep -q 'docker' <<<"$dry"
grep -q 'java_scala' <<<"$dry"
if grep -q 'ms-azuretools.vscode-docker' <<<"$dry"; then
  echo "docker extension should not be planned when docker is skipped" >&2
  exit 1
fi
echo OK
