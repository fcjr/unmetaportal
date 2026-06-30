# unmetaportal

Turn a Meta/Facebook Portal on Android 9 into a plain Android device with a
normal launcher and no active Facebook account UI. Supports both the `aloha`
touch panels (Portal / Portal+) and the `ripley` Android TV box (Portal TV).

> **Independent project.** unmetaportal is a community tool for repurposing a
> Portal you own. It is not affiliated with, authorized by, or endorsed by Meta
> Platforms, Inc. "Meta", "Facebook", and "Portal" are trademarks of Meta
> Platforms, Inc., used here only to identify the hardware this project works
> with. See [Disclaimer & Trademarks](#disclaimer--trademarks).

This is not a firmware flash and it does not unlock the bootloader. The main
conversion uses normal ADB package/app-state commands. Optional OS-level account
cleanup uses the community Portal CVE-2024-31317 path to ask Android's
AccountManager to remove Portal Facebook accounts as the Facebook authenticator
UID.

## Tested Devices

Two Portal hardware families are supported. Both run Android 9 and the same
"aloha" software stack, but they differ in form factor, home surface, and which
launcher makes sense. Preflight detects the hardware codename and picks the
right package set and launcher automatically; no flag needed.

### aloha — Portal / Portal+ (touch panels)

- Model: `Portal` and `Portal+`
- Hardware codename: `aloha`
- Android: 9 / API 28, `arm64-v8a`
- Build family: `Facebook/aloha_prod/aloha:9/...`
- Tested build: `1.44.4` (Oct 2025) on Portal+
- Home surface: `com.facebook.alohaapps.launcher` (+ AbilityCenter)
- Launcher used: Lawnchair 12.1.0 Alpha 4

Lawnchair version matters on this device:

- Lawnchair 12.1 runs and supports landscape.
- Lawnchair 14/15 install but crash-loop on Android 9.
- Lawnchair 1.2 runs but is portrait-only on the Portal panel.

### ripley — Portal TV (Android TV box)

- Model: `PortalTV`
- Hardware codename: `ripley`
- Android: 9 / API 28, `arm64-v8a`
- Build family: `Facebook/ripley_prod/ripley:9/...`
- Home surface: `com.facebook.aloha.system.ripleyhome` (TvHomeActivity, +
  AbilityCenter)
- Launcher used: LtvLauncher (arm64-v8a)

Portal TV is a leanback (Android TV) device driven by a remote, not a
touchscreen, so it gets a d-pad-native launcher instead of Lawnchair:

- LtvLauncher is an open-source leanback launcher (`LEANBACK_LAUNCHER` + HOME),
  navigable with the Portal TV remote. minSdk 21, runs on Android 9. It is an
  actively maintained fork of FLauncher (which has been dormant since 2023).
- Lawnchair is a touch launcher with no d-pad focus model and cannot be driven
  by the remote, so it is not used here.

After the Facebook apps are disabled, the script refreshes the launcher's app
list (`pm clear` on the launcher package) so the disabled apps stop appearing as
tiles. The HOME setting lives in PackageManager and survives that refresh.

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

1. Checks that ADB is connected, reports the device model/API level, and selects
   the matching profile (aloha or ripley).
2. Downloads the profile's launcher (Lawnchair on aloha, LtvLauncher on ripley)
   and verifies its SHA-256 checksum.
3. Installs the launcher and sets it as the Android HOME activity.
4. Disables both Portal home surfaces. The framework launcher differs by family:
   - aloha: `com.facebook.alohaapps.launcher`
   - ripley: `com.facebook.aloha.system.ripleyhome`
   - both: `com.facebook.alohaservices.abilitymanager` (AbilityCenter)
5. Clears Facebook session/app data with `pm clear`.
6. Disables account-facing Facebook apps such as Messenger, WhatsApp, feed,
   contacts, and presence.
7. Refreshes the launcher's app list so the disabled apps stop showing as tiles.
8. Verifies the launcher and AccountManager state.

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

## Credits

The optional account-cleanup path relies on **CVE-2024-31317**, an Android Zygote
command-injection vulnerability discovered and disclosed by **Tom Hebb** of
**Meta Red Team X**. Their writeup,
[*Becoming any Android app via Zygote command injection*](https://rtx.meta.security/exploitation/2024/06/03/Android-Zygote-injection.html),
documents the technique this project uses to run AccountManager calls as the
Facebook authenticator UID. This project is an independent application of that
publicly documented research; see [Disclaimer & Trademarks](#disclaimer--trademarks).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See the [NOTICE](NOTICE)
file for attribution and trademark information.

## Disclaimer & Trademarks

unmetaportal is an independent, community-maintained project. It is **not**
affiliated with, authorized by, sponsored by, or endorsed by Meta Platforms, Inc.

"Meta", "Facebook", "Portal", "Portal+", "Portal TV", "Messenger", and "WhatsApp"
are trademarks of Meta Platforms, Inc. and/or its affiliates. They are used in
this project only in a nominative, descriptive sense — to identify the specific
hardware and software this project interoperates with. No ownership, affiliation,
or endorsement is claimed or implied.

This project does not flash firmware, unlock the bootloader, or circumvent any
technical protection measure. It operates entirely through standard Android Debug
Bridge (ADB) commands and a publicly documented CVE, acting on device state that
the device's owner is entitled to change. It is provided for owners to repurpose
hardware they own, "AS IS" and without warranty of any kind. You are responsible
for complying with the laws and agreements that apply to your device.
