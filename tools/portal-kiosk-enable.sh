#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Frank Chiarulli Jr.
#
# Put the Portal into a reversible single-app mode.
#
# Usage:
#   ./tools/portal-kiosk-enable.sh --package PACKAGE
#   ./tools/portal-kiosk-enable.sh --component PACKAGE/.Activity
#   ./tools/portal-kiosk-enable.sh --package PACKAGE --set-home
#   ./tools/portal-kiosk-enable.sh --package PACKAGE --no-lock
#
# Default mode starts the app, enables immersive UI, and locks the foreground
# task with Android's activity task-lock command. `--set-home` additionally asks
# Android to make the app HOME, which only works for HOME-capable/kiosk launcher
# apps.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
TARGET_PKG=""
TARGET_COMPONENT=""
SET_HOME=0
LOCK_TASK=1
STATE_FILE="/data/local/tmp/unmetaportal-kiosk.state"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '6,17p' "$0"
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

shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

resolve_component() {
  if [[ -n "$TARGET_COMPONENT" ]]; then
    TARGET_PKG="${TARGET_COMPONENT%%/*}"
    return 0
  fi

  [[ -n "$TARGET_PKG" ]] || die "pass --package PACKAGE or --component PACKAGE/.Activity"

  local resolved
  resolved="$(
    adb shell cmd package resolve-activity --brief \
      -a android.intent.action.MAIN \
      -c android.intent.category.LAUNCHER \
      "$TARGET_PKG" 2>/dev/null |
      tr -d '\r' |
      tail -n 1
  )"

  [[ "$resolved" == "$TARGET_PKG/"* || "$resolved" == "$TARGET_PKG."*/* ]] ||
    die "could not resolve launchable activity for $TARGET_PKG; pass --component explicitly"

  TARGET_COMPONENT="$resolved"
}

find_task_id() {
  adb shell am stack list |
    tr -d '\r' |
    awk -v pkg="$TARGET_PKG" '
      $0 ~ "taskId=" && $0 ~ pkg {
        sub(/^.*taskId=/, "")
        sub(/:.*/, "")
        print
        exit
      }
    '
}

write_state() {
  local quoted_pkg quoted_component
  quoted_pkg="$(shell_quote "$TARGET_PKG")"
  quoted_component="$(shell_quote "$TARGET_COMPONENT")"
  adbq shell "printf 'TARGET_PKG=%s\nTARGET_COMPONENT=%s\nLOCK_TASK=%s\nSET_HOME=%s\n' $quoted_pkg $quoted_component '$LOCK_TASK' '$SET_HOME' > $STATE_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) shift; TARGET_PKG="${1:?--package needs a package name}" ;;
    --component) shift; TARGET_COMPONENT="${1:?--component needs PACKAGE/.Activity}" ;;
    --set-home) SET_HOME=1 ;;
    --no-lock) LOCK_TASK=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

preflight
resolve_component

cat <<EOF
This will put the Portal into kiosk mode for:
  package:   $TARGET_PKG
  component: $TARGET_COMPONENT

It will enable immersive UI, start the app, and $([[ $LOCK_TASK -eq 1 ]] && echo "lock its task" || echo "leave task locking off").
$([[ $SET_HOME -eq 1 ]] && echo "It will also try to make this component the HOME activity." || echo "It will leave Lawnchair as the configured HOME activity.")

Return to launcher mode with:
  ./tools/portal-kiosk-disable.sh
EOF
confirm "Proceed?"

log "Saving kiosk state"
write_state
ok "state saved to $STATE_FILE"

log "Enabling immersive UI"
adbq shell settings put global policy_control 'immersive.full=*'
ok "immersive.full=*"

if [[ $SET_HOME -eq 1 ]]; then
  log "Setting kiosk app as HOME"
  if adbq shell cmd package set-home-activity "$TARGET_COMPONENT"; then
    ok "set-home-activity $TARGET_COMPONENT"
  else
    die "Android rejected $TARGET_COMPONENT as HOME. Use a HOME-capable kiosk launcher app, or rerun without --set-home."
  fi
fi

log "Starting kiosk app"
adbq shell am force-stop "$TARGET_PKG" || true
adbq shell am start -S --activity-clear-task --activity-task-on-home -n "$TARGET_COMPONENT"
ok "started $TARGET_COMPONENT"

if [[ $LOCK_TASK -eq 1 ]]; then
  sleep 1
  task_id="$(find_task_id)"
  [[ -n "$task_id" ]] || die "started app, but could not find its task id for locking"
  log "Locking task $task_id"
  adbq shell am task lock "$task_id"
  ok "task locked"
fi

log "Kiosk mode enabled"
