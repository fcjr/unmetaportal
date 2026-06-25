# unmetaportal

Turn a Meta/Facebook Portal Gen 2 on Android 9 into a plain Android device with
a normal launcher and no active Facebook account UI.

This is not a firmware flash and it does not unlock the bootloader. The main
conversion uses normal ADB package/app-state commands. Optional OS-level account
cleanup uses the community Portal CVE-2024-31317 path to ask Android's
AccountManager to remove Portal Facebook accounts as the Facebook authenticator
UID.

## Tested Devices

Both share the `aloha` hardware family, the same Android 9 image, and the same
Portal/Facebook package set, so the conversion is identical across them. The
preflight check gates on the `aloha` hardware codename, not the model string,
so both are accepted without prompting.

- Model: `Portal` and `Portal+`
- Hardware codename: `aloha`
- Android: 9 / API 28
- CPU ABI: `arm64-v8a`
- Build family: `Facebook/aloha_prod/aloha:9/...`
- Tested build: `1.44.4` (Oct 2025) on Portal+
- Launcher used: Lawnchair 12.1.0 Alpha 4

Lawnchair version matters on this device:

- Lawnchair 12.1 runs and supports landscape.
- Lawnchair 14/15 install but crash-loop on Android 9.
- Lawnchair 1.2 runs but is portrait-only on the Portal panel.

## Requirements

- Android platform-tools with `adb` in `PATH`
- Portal connected over USB-C
- ADB authorized on the Portal
- The Portal should already have Meta's ADB-enabled firmware/update

Confirm connection:

```sh
adb devices -l
adb shell getprop ro.product.model
adb shell getprop ro.build.version.sdk
```

## Quick Start

Preview the conversion:

```sh
./unmetaportal.sh --dry-run
```

Convert the Portal:

```sh
./unmetaportal.sh
```

Convert without prompts:

```sh
./unmetaportal.sh --yes
```

Convert and also remove active OS-level Facebook account records:

```sh
./unmetaportal.sh --with-account-cleanup
```

If the Portal is already converted and you only want to remove AccountManager
records:

```sh
./unmetaportal.sh --remove-accounts
```

Use your own launcher APK instead of downloading Lawnchair:

```sh
./unmetaportal.sh --apk /path/to/launcher.apk
```

Start a single-app kiosk session:

```sh
./tools/portal-kiosk-enable.sh --package com.example.app
```

Return to Lawnchair launcher mode:

```sh
./tools/portal-kiosk-disable.sh
```

## What The Conversion Does

1. Checks that ADB is connected and reports the device model/API level.
2. Downloads Lawnchair 12.1 and verifies its SHA-256 checksum.
3. Installs Lawnchair and sets it as the Android HOME activity.
4. Disables both Portal home surfaces:
   - `com.facebook.alohaapps.launcher`
   - `com.facebook.alohaservices.abilitymanager`
5. Clears Facebook session/app data with `pm clear`.
6. Disables account-facing Facebook apps such as Messenger, WhatsApp, feed,
   contacts, and presence.
7. Verifies the launcher and AccountManager state.

Both Portal home surfaces matter. If only one is disabled, the framework can
fall back to AbilityCenter instead of the third-party launcher.

## Account Cleanup

`pm clear` removes app data, but Android AccountManager records can survive in
system credential databases that normal ADB shell cannot read or edit.

`./unmetaportal.sh --remove-accounts` handles that separately:

1. Temporarily enables `com.facebook.alohaservices.alohausers`.
2. Pushes `tools/portal-remove-facebook-accounts.sh` to `/data/local/tmp`.
3. Uses CVE-2024-31317 to run `service call account` as the Facebook
   authenticator UID.
4. Removes all active accounts whose type starts with `com.facebook.aloha.`.
5. Disables `com.facebook.alohaservices.alohausers` again.

The helper uses Android's AccountManager service. It does not directly modify
`accounts_ce.db` or `accounts_de.db`.

## Verification

Check the HOME activity:

```sh
adb shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN \
  -c android.intent.category.HOME
```

Expected result includes:

```text
app.lawnchair/.LawnchairLauncher
```

Check active Android accounts:

```sh
adb shell dumpsys account | sed -n '/Accounts:/,/Active Sessions:/p'
```

Expected after account cleanup:

```text
Accounts: 0
Active Sessions: 0
```

Check disabled Portal/Facebook packages:

```sh
adb shell pm list packages -d | grep -E 'alohausers|launcher|abilitymanager|devicesetup'
```

Expected packages include:

```text
package:com.facebook.alohaapps.launcher
package:com.facebook.alohaservices.abilitymanager
package:com.facebook.alohaservices.alohausers
```

Reboot and verify persistence:

```sh
adb reboot
adb wait-for-device
adb shell 'until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done'
adb shell dumpsys account | sed -n '/Accounts:/,/Active Sessions:/p'
```

If `Accounts: 0` is still reported after reboot, the active OS-level account
records did not regenerate.

## Kiosk Mode

The kiosk scripts provide a reversible single-app mode on top of the converted
Portal state.

Enable kiosk mode for an app with a normal launcher activity:

```sh
./tools/portal-kiosk-enable.sh --package com.example.app
```

Enable kiosk mode with an explicit activity component:

```sh
./tools/portal-kiosk-enable.sh --component com.example.app/.MainActivity
```

What this does:

1. Saves the target package/component to `/data/local/tmp/unmetaportal-kiosk.state`.
2. Enables immersive UI with `settings put global policy_control immersive.full=*`.
3. Starts the target app as a fresh foreground task.
4. Locks that task with `am task lock <taskId>`.

Disable kiosk mode and return to Lawnchair:

```sh
./tools/portal-kiosk-disable.sh
```

Disable kiosk mode and force-stop the kiosk target too:

```sh
./tools/portal-kiosk-disable.sh --force-stop-target
```

For a kiosk launcher APK that is HOME-capable, make it the HOME activity while
enabling kiosk mode:

```sh
./tools/portal-kiosk-enable.sh --package com.example.kiosk --set-home
```

`--set-home` is intentionally strict. Android will reject ordinary apps that do
not declare a HOME activity. For those apps, the script can still start and lock
the foreground task, but the setting will not survive a reboot as the boot/home
target. Use a purpose-built kiosk launcher APK if you need the app to load
automatically after every boot.

## Revert

Re-enable the Facebook packages and restore the Facebook home activity:

```sh
./unmetaportal.sh --revert
```

This does not restore cleared app data or removed AccountManager records. The
Portal will need login/setup again for Facebook services.

You can remove Lawnchair manually:

```sh
adb uninstall app.lawnchair
```

## Safety Notes

- Do not disable core Portal system packages such as
  `com.facebook.aloha.system.services`, `com.facebook.aloha.system.device`,
  `com.facebook.aloha.inputhub`, native libraries, or SDK/HAL packages.
- A factory reset wipes credential databases, but on Android 9 Portals it can
  return you to a setup flow that requires Facebook login before normal use.
- The account cleanup is stronger than `pm clear`, but it is not forensic flash
  sanitization. It confirms Android has no active registered Portal Facebook
  accounts.
- This repository is intended for repurposing your own retired device.
