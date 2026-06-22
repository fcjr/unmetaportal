#!/usr/bin/env bash
#
# Return a Portal from single-app kiosk mode to the Lawnchair launcher mode.
#
# Usage:
#   ./tools/portal-kiosk-disable.sh
#   ./tools/portal-kiosk-disable.sh --force-stop-target

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
FORCE_STOP_TARGET=0
STATE_FILE="/data/local/tmp/unmetaportal-kiosk.state"
LAWNCHAIR_HOME="app.lawnchair/app.lawnchair.LawnchairLauncher"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,7p' "$0"
}

adbsh() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '   [dry-run] adb %s\n' "$*" >&2
    return 0
  fi
  adb "$@"
}

adbq() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '   [dry-run] adb %s\n' "$*" >&2
    return 0
  fi
  adb "$@" >/dev/null 2>&1
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user."
}

preflight() {
  command -v adb >/dev/null 2>&1 || die "adb not found in PATH."
  local state
  state="$(adb get-state 2>/dev/null || true)"
  [[ "$state" == "device" ]] || die "no authorized ADB device connected."
}

read_state_value() {
  local key="$1"
  adb shell "test -f $STATE_FILE && sed -n 's/^$key=//p' $STATE_FILE | tail -n 1" 2>/dev/null |
    tr -d '\r'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-stop-target) FORCE_STOP_TARGET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

preflight

target_pkg="$(read_state_value TARGET_PKG || true)"

cat <<EOF
This will return the Portal to Lawnchair launcher mode:
  HOME: $LAWNCHAIR_HOME
  clear: global policy_control
  stop: current task lock
$([[ -n "$target_pkg" && $FORCE_STOP_TARGET -eq 1 ]] && echo "  force-stop target: $target_pkg" || true)
EOF
confirm "Proceed?"

log "Stopping task lock"
adbq shell am task lock stop || warn "task lock was not active or could not be stopped"
ok "task lock stopped"

log "Clearing immersive UI"
adbq shell settings delete global policy_control || true
ok "policy_control cleared"

if [[ -n "$target_pkg" && $FORCE_STOP_TARGET -eq 1 ]]; then
  log "Force-stopping kiosk target"
  adbq shell am force-stop "$target_pkg" || true
  ok "force-stopped $target_pkg"
fi

log "Restoring Lawnchair as HOME"
adbq shell cmd package set-home-activity "$LAWNCHAIR_HOME"
ok "set-home-activity $LAWNCHAIR_HOME"

adbq shell input keyevent KEYCODE_WAKEUP || true
adbq shell input keyevent KEYCODE_HOME || true
adbq shell rm -f "$STATE_FILE" || true

log "Launcher mode restored"
