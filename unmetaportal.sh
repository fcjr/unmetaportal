#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Frank Chiarulli Jr.
#
# unmetaportal — turn a Facebook/Meta Portal (Gen 2, Android 9) into a plain
# Android device: a normal third-party launcher as home, the Facebook home
# screen and account-facing apps disabled, and the logged-in account's app
# data wiped. No root required — everything goes through ADB.
#
# Validated against two Portal hardware families, both Android 9 (API 28),
# arm64-v8a, bootloader locked, no root:
#   "aloha"  — model "Portal" / "Portal+", fingerprint Facebook/aloha_prod/...
#   "ripley" — model "PortalTV" (Android TV / leanback), Facebook/ripley_prod/...
# The right package set and launcher are chosen automatically per device.
#
# Usage:
#   ./unmetaportal.sh            run the conversion (prompts before destructive steps)
#   ./unmetaportal.sh --yes      run without the confirmation prompt
#   ./unmetaportal.sh --dry-run  print every command without changing the device
#   ./unmetaportal.sh --revert   re-enable Facebook apps and restore the FB home
#   ./unmetaportal.sh --remove-accounts
#                                remove OS-level Portal Facebook accounts
#   ./unmetaportal.sh --with-account-cleanup
#                                convert, then remove OS-level accounts too
#   ./unmetaportal.sh --apk PATH use a local launcher APK instead of downloading
#   ./unmetaportal.sh -s SERIAL  target a specific device (also honors
#                                ANDROID_SERIAL); required when more than one
#                                device is attached, e.g. USB + wireless ADB
#
# Read the CAVEATS section near the bottom before relying on this for privacy.

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------

# This script supports two Portal hardware families, both Android 9 / arm64:
#
#   aloha  — Portal and Portal+ (touch panels, fingerprint Facebook/aloha_prod)
#   ripley — Portal TV (Android TV / leanback HDMI box, no touchscreen, driven
#            by a remote; fingerprint Facebook/ripley_prod)
#
# They run the same "aloha" software stack but differ in the home surface package
# and which launcher makes sense, so the config below is split per family and the
# active set is chosen by select_profile() from the detected hardware codename.

# --- aloha (Portal / Portal+) launcher ------------------------------------
# Lawnchair 12.1.0 Alpha 4 is the newest Lawnchair that actually RUNS on
# Android 9. Lawnchair 14/15 install but crash-loop (they reference framework
# classes/resources that don't exist before Android 11). Lawnchair 1.2 runs but
# is locked to portrait and renders sideways on the Portal's landscape panel.
ALOHA_LAUNCHER_URL="https://github.com/LawnchairLauncher/lawnchair/releases/download/v12.1.0-alpha.4/Lawnchair.12.1.0.Alpha.4.apk"
ALOHA_LAUNCHER_SHA256="db2c5ef7af633367b155dd7c132ddf5559a126456e69a4f029951afa2271c364"
ALOHA_LAUNCHER_PKG="app.lawnchair"
ALOHA_LAUNCHER_HOME_ACTIVITY="app.lawnchair/app.lawnchair.LawnchairLauncher"

# --- ripley (Portal TV) launcher ------------------------------------------
# LtvLauncher is an open-source Android TV / leanback launcher (a maintained
# fork of FLauncher; FLauncher itself has been dormant since 2023). Lawnchair is
# a phone/tablet touch launcher and is awkward to drive with the Portal TV
# remote, so the TV gets a d-pad-native leanback launcher instead. LtvLauncher is
# minSdk 21 and runs fine on Android 9. The arm64-v8a build matches the Portal's
# ABI; update both the URL and SHA-256 together when bumping the version.
RIPLEY_LAUNCHER_URL="https://github.com/LeanBitLab/LtvLauncher/releases/download/v2026.06.21/LTvLauncher-arm64-v8a-release.apk"
RIPLEY_LAUNCHER_SHA256="a99fe98620015de46465a701292a299c4efc66ab39b83801de47976a366170fe"
RIPLEY_LAUNCHER_PKG="com.leanbitlab.ltvL"
RIPLEY_LAUNCHER_HOME_ACTIVITY="com.leanbitlab.ltvL/com.leanbitlab.ltvL.MainActivity"

# --- aloha (Portal / Portal+) package set ---------------------------------
# The two surfaces the Portal framework uses as "home". BOTH must be disabled or
# the framework falls back from the FB launcher to the AbilityCenter instead of
# your launcher. Setting the home activity alone is silently overridden.
ALOHA_HOME_SURFACES=(
  com.facebook.alohaapps.launcher
  com.facebook.alohaservices.abilitymanager
)
ALOHA_FB_HOME_ACTIVITY="com.facebook.alohaapps.launcher/com.facebook.aloha.app.home.touch.HomeActivity"
# Packages whose app data holds the logged-in session (tokens, cached profile,
# messages, photos). `pm clear` wipes that data. AccountManager records require
# the explicit cleanup phase; see remove_account_records and CAVEATS.
ALOHA_WIPE_PKGS=(
  com.facebook.alohaservices.alohausers
  com.facebook.alohaapps.personaluser
  com.facebook.aloha.state
  com.facebook.alohaapps.launcher
  com.facebook.aloha.app.messenger
  com.facebook.aloha.app.whatsapp
  com.facebook.alohaapps.contacts
  com.facebook.aloha.app.portalfeed
  com.facebook.alohaservices.presence
)
# Account-facing / app-layer Facebook packages to disable so nothing prompts for
# login, runs in the background, or phones home. (HOME_SURFACES are disabled too.)
ALOHA_DISABLE_PKGS=(
  com.facebook.aloha.app.messenger
  com.facebook.aloha.app.whatsapp
  com.facebook.aloha.app.portalfeed
  com.facebook.aloha.app.storytime
  com.facebook.aloha.app.cameraeditor
  com.facebook.alohaapps.contacts
  com.facebook.alohaapps.personaluser
  com.facebook.alohaapps.superframe
  com.facebook.alohaservices.presence
  com.facebook.alohaservices.abilities.pages
  com.facebook.aloha.analytics
  com.facebook.aloha.websafety
  com.facebook.alohaapps.bugreporter
)

# --- ripley (Portal TV) package set ---------------------------------------
# Portal TV has no com.facebook.alohaapps.launcher. Its home is the leanback
# surface com.facebook.aloha.system.ripleyhome (TvHomeActivity). It is a SYSTEM
# package but is disable-able for user 0 and clearable, like the aloha launcher.
# AbilityCenter (abilitymanager) is present here too and is the same fallback
# surface, so BOTH are disabled.
RIPLEY_HOME_SURFACES=(
  com.facebook.aloha.system.ripleyhome
  com.facebook.alohaservices.abilitymanager
)
RIPLEY_FB_HOME_ACTIVITY="com.facebook.aloha.system.ripleyhome/com.facebook.aloha.app.ripleyhome.TvHomeActivity"
RIPLEY_WIPE_PKGS=(
  com.facebook.alohaservices.alohausers
  com.facebook.alohaapps.personaluser
  com.facebook.aloha.state
  com.facebook.aloha.system.ripleyhome
  com.facebook.aloha.app.messenger
  com.facebook.aloha.app.whatsapp
  com.facebook.alohaapps.contacts
  com.facebook.alohaservices.presence
)
RIPLEY_DISABLE_PKGS=(
  com.facebook.aloha.app.messenger
  com.facebook.aloha.app.whatsapp
  com.facebook.aloha.app.storytime
  com.facebook.aloha.app.cameraeditor
  com.facebook.aloha.app.photobooth
  com.facebook.alohaapps.contacts
  com.facebook.alohaapps.personaluser
  com.facebook.alohaapps.superframe
  com.facebook.alohaservices.presence
  com.facebook.alohaservices.abilities.pages
  com.facebook.aloha.analytics
  com.facebook.aloha.websafety
  com.facebook.alohaapps.bugreporter
)

# DO NOT DISABLE — these provide drivers / HAL / framework / input the device
# needs to boot, take remote input, and drive the camera/mic/display. Disabling
# them can brick the device until a factory reset. Documentation only:
#   com.facebook.aloha.system.services   com.facebook.aloha.system.device
#   com.facebook.aloha.system.nativelibs com.facebook.aloha.inputhub
#   com.facebook.aloha.deviceidentity    com.facebook.aloha.platformmobileconfig
#   com.facebook.alohainstaller          com.facebook.alohaservices.player2
#   com.facebook.aloha.fbttsservice      com.facebook.alohasdk.*
#   com.facebook.alohaapps.controlcenter com.facebook.alohaapps.settings
# ripley-only system/input packages to leave alone as well:
#   com.facebook.aloha.system.ripleyhome is the home surface (disabled above),
#   but com.facebook.aloha.system.rcbootflow, com.facebook.aloha.bluetoothremote
#   (the remote), com.facebook.aloha.app.bishop.keyboard (on-screen keyboard),
#   and com.facebook.alohasdk.tvservice are required and are NOT touched.

# Active config, populated by select_profile() once hardware is known.
PROFILE=""
LAUNCHER_URL=""
LAUNCHER_SHA256=""
LAUNCHER_PKG=""
LAUNCHER_HOME_ACTIVITY=""
LAUNCHER_APK=""
FB_HOME_ACTIVITY=""
HOME_SURFACES=()
WIPE_PKGS=()
DISABLE_PKGS=()
USER_APK=""

# ----------------------------------------------------------------------------
# Plumbing
# ----------------------------------------------------------------------------

DRY_RUN=0
ASSUME_YES=0
MODE="convert"
RUN_ACCOUNT_CLEANUP=0
SERIAL=""       # target device serial (from -s/--serial or ANDROID_SERIAL)
ADB_ARGS=()     # populated by resolve_device as (-s "$SERIAL")

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Run an adb command (honoring --dry-run). Use for everything that touches device.
adbsh() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '   [dry-run] adb %s\n' "$*" >&2
    return 0
  fi
  adb "${ADB_ARGS[@]}" "$@"
}

adbq() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '   [dry-run] adb %s\n' "$*" >&2
    return 0
  fi
  adb "${ADB_ARGS[@]}" "$@" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --revert)  MODE="revert" ;;
    --remove-accounts) MODE="remove-accounts" ;;
    --with-account-cleanup) RUN_ACCOUNT_CLEANUP=1 ;;
    --serial|-s) shift; SERIAL="${1:?--serial needs a device serial}" ;;
    --apk)     shift; USER_APK="${1:?--apk needs a path}" ;;
    -h|--help) sed -n '6,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

preflight() {
  command -v adb >/dev/null 2>&1 || die "adb not found in PATH (install Android platform-tools)."

  resolve_device

  local model sdk hw
  model="$(adb "${ADB_ARGS[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  sdk="$(adb "${ADB_ARGS[@]}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  hw="$(adb "${ADB_ARGS[@]}" shell getprop ro.boot.hardware 2>/dev/null | tr -d '\r')"
  log "Device: model='${model}' hw='${hw}' sdk=${sdk}"

  select_profile "$model" "$hw"

  if [[ "${sdk:-0}" -lt 28 ]]; then
    warn "SDK ${sdk} < 28. Untested; launcher choice may differ."
  fi
}

# Resolve exactly one target device and pin every later adb call to it via -s.
# adb's bare commands (get-state, shell, ...) error out when more than one device
# is attached — common on a Portal that's reachable over both USB and TCP at once.
# Pick the target from -s/--serial or ANDROID_SERIAL when given; otherwise require
# a single authorized device, and list choices when the selection is ambiguous.
resolve_device() {
  local devices requested count
  devices="$(adb devices | awk 'NR>1 && $2=="device" {print $1}')"
  requested="${SERIAL:-${ANDROID_SERIAL:-}}"

  if [[ -z "$devices" ]]; then
    adb devices -l || true
    die "no authorized device. Connect the Portal over USB-C and accept the ADB prompt on its screen."
  fi

  if [[ -n "$requested" ]]; then
    if ! grep -qx "$requested" <<<"$devices"; then
      adb devices -l || true
      die "device '$requested' is not connected/authorized. Pick one of the serials listed above."
    fi
    SERIAL="$requested"
  else
    count="$(grep -c . <<<"$devices")"
    if [[ "$count" -gt 1 ]]; then
      adb devices -l || true
      die "multiple devices connected — choose one with -s SERIAL (e.g. -s $(head -1 <<<"$devices")) or set ANDROID_SERIAL."
    fi
    SERIAL="$devices"
  fi

  ADB_ARGS=(-s "$SERIAL")
  log "Target device: $SERIAL"
}

# Pick the package/launcher set for the connected hardware. The real invariant
# is the hardware codename, not the marketing model string: Portal/Portal+ both
# report hw=aloha, Portal TV reports hw=ripley. Each family shares one package
# set. When neither the codename nor the model is recognized, warn and fall back
# to the aloha set after confirmation.
select_profile() {
  local model="$1" hw="$2"

  case "$hw" in
    aloha)  PROFILE=aloha  ;;
    ripley) PROFILE=ripley ;;
    *)
      case "$model" in
        Portal|Portal+) PROFILE=aloha  ;;
        PortalTV)       PROFILE=ripley ;;
        *)
          warn "Device model='${model}' hw='${hw}' — only validated on aloha (Portal/Portal+) and ripley (Portal TV)."
          confirm "Continue using the aloha package set anyway?"
          PROFILE=aloha
          ;;
      esac
      ;;
  esac

  case "$PROFILE" in
    aloha)
      LAUNCHER_URL="$ALOHA_LAUNCHER_URL"
      LAUNCHER_SHA256="$ALOHA_LAUNCHER_SHA256"
      LAUNCHER_PKG="$ALOHA_LAUNCHER_PKG"
      LAUNCHER_HOME_ACTIVITY="$ALOHA_LAUNCHER_HOME_ACTIVITY"
      LAUNCHER_APK="${TMPDIR:-/tmp}/lawnchair-12.1.apk"
      FB_HOME_ACTIVITY="$ALOHA_FB_HOME_ACTIVITY"
      HOME_SURFACES=("${ALOHA_HOME_SURFACES[@]}")
      WIPE_PKGS=("${ALOHA_WIPE_PKGS[@]}")
      DISABLE_PKGS=("${ALOHA_DISABLE_PKGS[@]}")
      ;;
    ripley)
      LAUNCHER_URL="$RIPLEY_LAUNCHER_URL"
      LAUNCHER_SHA256="$RIPLEY_LAUNCHER_SHA256"
      LAUNCHER_PKG="$RIPLEY_LAUNCHER_PKG"
      LAUNCHER_HOME_ACTIVITY="$RIPLEY_LAUNCHER_HOME_ACTIVITY"
      LAUNCHER_APK="${TMPDIR:-/tmp}/ltvlauncher.apk"
      FB_HOME_ACTIVITY="$RIPLEY_FB_HOME_ACTIVITY"
      HOME_SURFACES=("${RIPLEY_HOME_SURFACES[@]}")
      WIPE_PKGS=("${RIPLEY_WIPE_PKGS[@]}")
      DISABLE_PKGS=("${RIPLEY_DISABLE_PKGS[@]}")
      ;;
  esac

  # A user-supplied APK overrides the downloaded launcher but still uses the
  # profile's launcher package/home-activity for set-home and verification.
  if [[ -n "$USER_APK" ]]; then
    LAUNCHER_APK="$USER_APK"
    LAUNCHER_URL=""
  fi

  log "Using '${PROFILE}' profile (launcher ${LAUNCHER_PKG})"
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user."
}

# ----------------------------------------------------------------------------
# Phases
# ----------------------------------------------------------------------------

fetch_launcher() {
  if [[ -f "$LAUNCHER_APK" ]] && verify_sha "$LAUNCHER_APK"; then
    ok "launcher APK already present and verified: $LAUNCHER_APK"
    return 0
  fi
  [[ -n "$LAUNCHER_URL" ]] || die "launcher APK missing and no URL set (did you pass --apk to a bad path?)."
  log "Downloading launcher: $LAUNCHER_URL"
  [[ $DRY_RUN -eq 1 ]] && { printf '   [dry-run] curl -o %s %s\n' "$LAUNCHER_APK" "$LAUNCHER_URL" >&2; return 0; }
  curl -fsSL -o "$LAUNCHER_APK" "$LAUNCHER_URL" || die "download failed."
  verify_sha "$LAUNCHER_APK" || die "sha256 mismatch — refusing to install. Expected $LAUNCHER_SHA256."
  ok "downloaded and verified."
}

verify_sha() {
  [[ -n "$LAUNCHER_SHA256" ]] || return 0
  local got
  if command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$1" | awk '{print $1}')"
  else got="$(sha256sum "$1" | awk '{print $1}')"; fi
  [[ "$got" == "$LAUNCHER_SHA256" ]]
}

install_launcher() {
  log "Installing launcher and setting it as HOME"
  adbq install -r "$LAUNCHER_APK" && ok "installed $LAUNCHER_PKG"
  adbq shell cmd package set-home-activity "$LAUNCHER_HOME_ACTIVITY" && ok "set-home-activity $LAUNCHER_HOME_ACTIVITY"
  # Let the system pick the panel's natural landscape orientation.
  adbq shell settings put system accelerometer_rotation 1 || true
}

disable_home_surfaces() {
  log "Disabling Facebook home surfaces (so your launcher actually wins HOME)"
  for p in "${HOME_SURFACES[@]}"; do
    adbq shell pm disable-user --user 0 "$p" && ok "disabled $p"
  done
}

wipe_account() {
  log "Wiping Facebook session/app data (best-effort credential removal)"
  for p in "${WIPE_PKGS[@]}"; do
    adbq shell pm clear "$p" && ok "cleared $p" || warn "could not clear $p (may not exist on this build)"
  done
}

disable_apps() {
  log "Disabling account-facing Facebook apps"
  for p in "${DISABLE_PKGS[@]}"; do
    adbq shell pm disable-user --user 0 "$p" && ok "disabled $p" || warn "skip $p (absent/already disabled)"
  done
}

refresh_launcher() {
  # The launcher caches its app list on first scan, which happens at install
  # time — before the disable steps above run. Without this it keeps showing
  # tiles for the now-disabled Facebook apps until its cache happens to refresh.
  # Clearing the launcher's data forces a rescan of the final package state. The
  # HOME setting lives in PackageManager (set-home-activity), not launcher data,
  # so it survives the clear.
  log "Refreshing launcher app list so disabled apps disappear"
  adbq shell pm clear "$LAUNCHER_PKG" && ok "rescanned $LAUNCHER_PKG" || warn "could not refresh $LAUNCHER_PKG"
}

remove_account_records() {
  local helper_dir helper_remote
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helper_remote="/data/local/tmp/portal-remove-facebook-accounts.sh"

  if [[ ! -f "$helper_dir/tools/portal-remove-facebook-accounts.sh" ]]; then
    die "missing helper: $helper_dir/tools/portal-remove-facebook-accounts.sh"
  fi

  cat <<EOF

This will remove active OS-level Facebook Portal accounts from Android
AccountManager. It uses the community Portal CVE-2024-31317 path to run the
AccountManager removal calls as the Facebook authenticator UID. It does not
edit AccountManager SQLite files directly.
EOF
  confirm "Proceed with AccountManager cleanup?"

  log "Preparing Facebook authenticator account cleanup"
  adbq shell pm enable com.facebook.alohaservices.alohausers || true
  adbq push "$helper_dir/tools/portal-remove-facebook-accounts.sh" "$helper_remote"
  adbsh shell sh "$helper_remote"
  adbq shell pm disable-user --user 0 com.facebook.alohaservices.alohausers || true
  ok "disabled com.facebook.alohaservices.alohausers"
}

verify() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  log "Verifying"
  local home
  home="$(adb "${ADB_ARGS[@]}" shell cmd package resolve-activity -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | grep -iE 'packageName=' | head -1 | tr -d '\r')"
  printf '   HOME resolves to:%s\n' "${home#*packageName=}"
  [[ "$home" == *"$LAUNCHER_PKG"* ]] && ok "launcher is the default home" || warn "launcher is NOT resolving as home — check manually."
  adb "${ADB_ARGS[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb "${ADB_ARGS[@]}" shell input keyevent KEYCODE_HOME   >/dev/null 2>&1 || true
  local account_count
  account_count="$(adb "${ADB_ARGS[@]}" shell dumpsys account 2>/dev/null | sed -n 's/^  Accounts: //p' | head -1 | tr -d '\r')"
  printf '   AccountManager active accounts: %s\n' "${account_count:-unknown}"
  if [[ "${account_count:-unknown}" == "0" ]]; then
    ok "no active OS-level accounts registered"
  else
    warn "Active OS-level accounts remain. Run: $0 --remove-accounts"
    adb "${ADB_ARGS[@]}" shell dumpsys account 2>/dev/null | grep -iE "Account \{" | sed 's/^/     /' || true
  fi
}

revert() {
  log "Reverting: re-enabling all Facebook packages and restoring the FB home"
  for p in "${HOME_SURFACES[@]}" "${DISABLE_PKGS[@]}"; do
    adbq shell pm enable "$p" && ok "enabled $p" || true
  done
  adbq shell cmd package set-home-activity "$FB_HOME_ACTIVITY" || true
  ok "FB home restored. (Cleared account data is NOT restored — you'll be asked to log in again.)"
  warn "You may want to: adb uninstall $LAUNCHER_PKG"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

preflight

if [[ "$MODE" == "revert" ]]; then
  revert
  exit 0
fi

if [[ "$MODE" == "remove-accounts" ]]; then
  remove_account_records
  verify
  exit 0
fi

cat <<EOF

This will, on the connected Portal (${PROFILE} profile):
  1. Install ${LAUNCHER_PKG} and make it the home screen
  2. Disable the Facebook home surface(s) + AbilityCenter
  3. Wipe Facebook session/app data (pm clear)
  4. Disable Messenger/WhatsApp/feed/contacts/etc.
  5. Optionally remove OS-level Facebook accounts (--with-account-cleanup)
  6. Refresh the launcher so the disabled apps disappear from its app list

Reversible with: $0 --revert   (account login data is NOT restorable)
EOF
confirm "Proceed?"

fetch_launcher
install_launcher
disable_home_surfaces
wipe_account
disable_apps
if [[ $RUN_ACCOUNT_CLEANUP -eq 1 ]]; then
  remove_account_records
fi
refresh_launcher
verify

log "Done. The Portal should now boot to ${LAUNCHER_PKG} with no Facebook account UI."

# ----------------------------------------------------------------------------
# CAVEATS (read me)
# ----------------------------------------------------------------------------
# * No root / locked bootloader: everything here is reversible app-level state,
#   not a firmware change.
# * Credential removal in this main script is BEST-EFFORT. `pm clear` wipes the
#   FB apps' on-device session data, but AccountManager records can survive.
#   Use --remove-accounts or --with-account-cleanup to ask Android's
#   AccountManager to remove those records as the Facebook authenticator UID.
#   That cleanup uses the community Portal CVE-2024-31317 path; it does not
#   directly edit system credential databases. Verify with: adb shell dumpsys account
# * Only HOME_SURFACES and DISABLE_PKGS are touched. The com.facebook.aloha.system.*
#   / inputhub / nativelibs / *sdk* packages are deliberately left alone.
# * Persistence: disabled state and the home setting survive reboot. Verify on
#   the first device by rebooting before deploying to a public location.
