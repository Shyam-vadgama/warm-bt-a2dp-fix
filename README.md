# Warm — Bluetooth A2DP Fix (LineageOS 24 / Android 17)

One-shot installer that restores Bluetooth media audio (A2DP) on the
**Redmi 24116RNC1I (`warm`)** running LineageOS 24 builds whose vendor image
ships with the Qualcomm A2DP offload disabled.

Works right after a clean flash — no files have to be copied to the phone or PC
first, the installer downloads everything it needs from this repository.

| Platform | Command |
| --- | --- |
| Linux / macOS / WSL | `curl` one-liner (below) |
| Windows 10 / 11 | single `WarmBTFix.exe` (below) |

---

## The problem

The LineageOS 24 vendor image for `warm` (OS3.1 base) is built with A2DP
offload switched off:

```
ro.bluetooth.a2dp_offload.supported        = false
persist.bluetooth.a2dp_offload.disabled    = true
persist.vendor.qcom.bluetooth.a2dp_offload_cap   # commented out
```

Because of that the Qualcomm Bluetooth audio HAL is never loaded, the audio
policy never includes the A2DP device ports, and the Bluetooth stack has no
working path for media audio. The headset connects, but no sound is routed to
it.

The installer fixes all three layers:

1. installs `audio.bluetooth_qti.default.so` (Qualcomm Bluetooth audio HAL),
2. installs `bluetooth_qti_audio_policy_configuration.xml` and points the
   SKU audio policy (`/vendor/etc/audio/sku_pitti/audio_policy_configuration.xml`)
   at it,
3. re-enables the three A2DP offload properties in `/vendor/build.prop`.

Everything is written through Android's overlayfs (`adb remount`), so it
survives normal reboots and is removed by a factory reset / clean flash.

---

## Requirements

- Redmi 24116RNC1I (`warm`) running LineageOS 24 (Android 17).
- Root through `adb root` (userdebug/eng build) or KernelSU / Magisk.
- USB debugging enabled: **Settings → About phone → tap Build number 7×**,
  then **Developer options → USB debugging**.
- `adb` (Android platform-tools) installed on the PC:
  - Windows: `winget install Google.PlatformTools` (or download the zip from
    developer.android.com and add the folder to `PATH`),
  - Linux: `sudo apt install android-tools-adb` / `sudo pacman -S android-tools`,
  - macOS: `brew install android-platform-tools`.
- Internet connection (the fix files are downloaded from GitHub).

Connect the phone, run `adb devices` once and accept the *Allow USB debugging*
prompt on the phone. It must show your device as `device` (not `unauthorized`).

---

## Install — Linux / macOS / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/push_bt_fix.sh | bash
```

Reboot after it finishes:

```bash
adb reboot
```

Useful options:

```bash
# install and reboot in one go
curl -fsSL https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/push_bt_fix.sh | bash -s -- --reboot

# local copy (the two fix files can sit next to the script)
git clone https://github.com/Shyam-vadgama/warm-bt-a2dp-fix.git
cd warm-bt-a2dp-fix
bash push_bt_fix.sh
```

## Install — Windows

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/WarmBTFix.exe -OutFile "$env:TEMP\WarmBTFix.exe"; & "$env:TEMP\WarmBTFix.exe"
```

The executable embeds both fix files, checks `adb`, installs the fix and prints
the reboot step. Then reboot:

```powershell
adb reboot
```

> `WarmBTFix.exe` is not code-signed, so Windows SmartScreen may show
> *"Windows protected your PC"*. Choose **More info → Run anyway**.
> The full source of the installer is in `push_bt_fix.sh` and the behaviour is
> identical.

---

## After the install

1. Reboot the phone (mandatory — `ro.bluetooth.a2dp_offload.supported` is read
   at boot).
2. Connect the Bluetooth headset.
3. Play music.

Verify that offload is active and the codec is negotiated:

```bash
adb shell dumpsys bluetooth_manager | grep -E 'mA2dpOffloadEnabled|mCodecConfig'
```

Expected:

```
  mA2dpOffloadEnabled: true
    mCodecConfig: {codecName:AAC,...}
```

If the headset is connected but still silent, unpair and pair it again once
after the reboot.

---

## What is written on the device

| Path | Content |
| --- | --- |
| `/vendor/etc/bluetooth_qti_audio_policy_configuration.xml` | A2DP audio policy (0644, `vendor_configs_file`) |
| `/vendor/lib64/hw/audio.bluetooth_qti.default.so` | Qualcomm Bluetooth audio HAL (0644, `vendor_file`) |
| `/vendor/etc/audio/sku_pitti/audio_policy_configuration.xml` | include switched from `bluetooth_hearing_aid_*` to `bluetooth_qti_*` |
| `/vendor/build.prop` | `ro.bluetooth.a2dp_offload.supported=true`, `persist.bluetooth.a2dp_offload.disabled=false`, `persist.vendor.qcom.bluetooth.a2dp_offload_cap=sbc-aptx-aptxtws-aptxhd-aac-ldac` |

Stock backups are created once and kept on the phone:

- `/data/local/tmp/build.prop.stock`
- `/data/local/tmp/audio_policy_configuration.xml.stock`

---

## Restore / uninstall

```bash
adb root
adb remount
adb shell 'cp -f /data/local/tmp/build.prop.stock /vendor/build.prop && \
           cp -f /data/local/tmp/audio_policy_configuration.xml.stock \
                 /vendor/etc/audio/sku_pitti/audio_policy_configuration.xml && \
           chmod 0644 /vendor/build.prop \
                 /vendor/etc/audio/sku_pitti/audio_policy_configuration.xml && \
           rm -f /data/local/tmp/build.prop.stock \
                 /data/local/tmp/audio_policy_configuration.xml.stock'
adb reboot
```

A clean flash of the ROM also removes every change.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `adb: no devices/emulators found` | Reconnect the cable, use the original USB cable, accept the USB-debugging prompt on the phone. |
| Device shows `unauthorized` | Revoke USB debugging authorizations in Developer options and re-authorize. |
| `adbd cannot run as root in production builds` | The ROM is a `user` build. Root the device with KernelSU/Magisk and run: `adb shell su -c 'sh /data/local/tmp/warm_bt_fix.sh'` after pushing `bq.xml`, `bq.so` and the installer manually. |
| `/vendor is read-only` | Run `adb root`, then `adb remount`; if it still fails, reboot the phone and run the installer again. |
| Installed but still no sound | Reboot first. Then check `mA2dpOffloadEnabled: true`; if it is `false`, confirm the three properties with `adb shell getprop ro.bluetooth.a2dp_offload.supported`. |
| Fix disappeared | It was removed by a clean flash / factory reset. Run the installer again. |

---

## Files in this repository

| File | MD5 |
| --- | --- |
| `push_bt_fix.sh` | host-side installer (Linux/macOS/WSL) |
| `WarmBTFix.exe` | host-side installer (Windows, self-contained) |
| `bluetooth_qti_audio_policy_configuration.xml` | `322e6992c6e04dd4de2775a05fa59266` |
| `audio.bluetooth_qti.default.so` | `568ad926348846885a30a1b3cc30c967` |

The MD5 checksums are verified by `push_bt_fix.sh` before anything is written
to the device.

---

## Disclaimer

The installer modifies `/vendor` through overlayfs on your own device. Stock
files are backed up automatically, but you are responsible for your device.
Use it only on the Redmi 24116RNC1I (`warm`) with a LineageOS 24 vendor image
that matches the paths above.
