#!/usr/bin/env bash
# ==============================================================================
# Warm (Redmi 24116RNC1I) - Bluetooth A2DP offload fix
#
# Installs the Qualcomm Bluetooth A2DP HAL and audio policy on LineageOS 24
# (Android 17) builds that ship a vendor image with A2DP offload disabled.
# Files are written through Android's overlayfs (adb remount), so the fix
# survives a normal reboot. A full clean flash removes it again.
#
# Requirements: adb (platform-tools), USB debugging enabled, rooted device
# (userdebug / eng build or a working KernelSU-Magisk `adb root`).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/push_bt_fix.sh | bash
#   bash push_bt_fix.sh            # local copy, fix files next to the script
#   bash push_bt_fix.sh --reboot   # install and reboot automatically
#
# The script downloads the two fix files from this repository when they are
# not present in the current directory, so the curl one-liner works on a fresh
# ROM where nothing has been copied to the phone or PC yet.
# ==============================================================================
set -euo pipefail

REPO_RAW="${WARM_BT_FIX_RAW:-https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main}"

XML_NAME="bluetooth_qti_audio_policy_configuration.xml"
SO_NAME="audio.bluetooth_qti.default.so"
XML_MD5="322e6992c6e04dd4de2775a05fa59266"
SO_MD5="568ad926348846885a30a1b3cc30c967"

REBOOT=0
for arg in "$@"; do
    case "$arg" in
        --reboot) REBOOT=1 ;;
        -h|--help)
            cat <<'USAGE'
Usage: push_bt_fix.sh [--reboot]

  (no option)  install the fix and print the reboot instructions
  --reboot     install the fix and reboot the phone immediately
  -h, --help   show this help

The script needs adb, a connected phone with USB debugging enabled and root
access (adb root). It downloads the fix files from this repository when they
are not available locally.
USAGE
            exit 0
            ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '[warm-bt-fix] %s\n' "$*"; }
die() { printf '[warm-bt-fix] ERROR: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/warm-bt-fix.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 1. Locate the two payload files (local copy first, repository fallback)
# ------------------------------------------------------------------------------
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

locate() { # locate <file name> -> prints path
    local name="$1" dir
    for dir in "$SELF_DIR" "$PWD" "$PWD/files"; do
        [ -n "$dir" ] && [ -s "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    done
    return 1
}

fetch() { # fetch <file name> <md5>
    local name="$1" want="$2" path found
    if found="$(locate "$name")"; then
        say "using local file: $found" >&2
        path="$found"
    else
        command -v curl >/dev/null 2>&1 ||
            die "curl not found - install curl or keep the fix files next to this script"
        say "downloading $name" >&2
        curl -fsSL --retry 3 "$REPO_RAW/$name" -o "$WORK/$name" ||
            die "download failed: $REPO_RAW/$name"
        path="$WORK/$name"
    fi
    if command -v md5sum >/dev/null 2>&1; then
        got="$(md5sum "$path" | awk '{print $1}')"
        [ "$got" = "$want" ] || die "checksum mismatch for $name ($got)"
    fi
    printf '%s\n' "$path"
}

XML_PATH="$(fetch "$XML_NAME" "$XML_MD5")"
SO_PATH="$(fetch "$SO_NAME" "$SO_MD5")"
[ -s "$XML_PATH" ] || die "could not prepare $XML_NAME"
[ -s "$SO_PATH" ] || die "could not prepare $SO_NAME"

# ------------------------------------------------------------------------------
# 2. Prepare adb access
# ------------------------------------------------------------------------------
command -v adb >/dev/null 2>&1 ||
    die "adb not found - install Android platform-tools and add them to PATH"

adb start-server >/dev/null 2>&1 || true
adb get-state >/dev/null 2>&1 ||
    die "no device found - connect the phone, enable USB debugging and authorize this PC"

say "requesting root"
adb root >/dev/null 2>&1 || say "adb root unavailable, continuing as-is"
adb wait-for-device

say "remounting /vendor read-write (overlayfs)"
adb remount 2>/dev/null || true

# ------------------------------------------------------------------------------
# 3. Upload the payload and the on-device installer
# ------------------------------------------------------------------------------
adb push "$XML_PATH" /data/local/tmp/bq.xml >/dev/null
adb push "$SO_PATH" /data/local/tmp/bq.so >/dev/null

cat >"$WORK/device_install.sh" <<'DEVICE_SCRIPT_EOF'
#!/system/bin/sh
# Warm (Redmi 24116RNC1I) - on-device installer for the Bluetooth A2DP offload fix.
# Runs as root on the phone. Launched by push_bt_fix.sh (Linux/macOS) or WarmBTFix.exe (Windows).
set -e

TMP=/data/local/tmp
XML_DST=/vendor/etc/bluetooth_qti_audio_policy_configuration.xml
SO_DST=/vendor/lib64/hw/audio.bluetooth_qti.default.so
SKU=/vendor/etc/audio/sku_pitti/audio_policy_configuration.xml
BP=/vendor/build.prop
CAP=sbc-aptx-aptxtws-aptxhd-aac-ldac

log() { echo "[warm-bt-fix] $*"; }
die() { echo "[warm-bt-fix] ERROR: $*" >&2; exit 1; }

# ---- preconditions -----------------------------------------------------------
[ "$(id -u)" = "0" ] || die "root is required (run 'adb root' first)"
[ -s "$TMP/bq.xml" ] || die "missing $TMP/bq.xml"
[ -s "$TMP/bq.so" ] || die "missing $TMP/bq.so"
[ -f "$SKU" ] || die "unsupported device: $SKU not found"
[ -f "$BP" ] || die "unsupported device: $BP not found"

touch /vendor/.warm_rw_test 2>/dev/null ||
    die "/vendor is read-only - enable root, run 'adb remount' and try again"
rm -f /vendor/.warm_rw_test

# ---- 1. Bluetooth A2DP HAL + audio policy ------------------------------------
log "installing Bluetooth A2DP HAL and audio policy"
cp -f "$TMP/bq.xml" "$XML_DST"
cp -f "$TMP/bq.so" "$SO_DST"
chown 0:0 "$XML_DST" "$SO_DST"
chmod 0644 "$XML_DST" "$SO_DST"
chcon u:object_r:vendor_configs_file:s0 "$XML_DST"
chcon u:object_r:vendor_file:s0 "$SO_DST"

# ---- 2. point the SKU audio policy at the QTI Bluetooth policy ----------------
log "repointing SKU audio policy to the QTI Bluetooth policy"
[ -f "$TMP/audio_policy_configuration.xml.stock" ] ||
    cp -f "$SKU" "$TMP/audio_policy_configuration.xml.stock"
sed -i 's#bluetooth_hearing_aid_audio_policy_configuration\.xml#bluetooth_qti_audio_policy_configuration.xml#' "$SKU"
grep -q 'bluetooth_qti_audio_policy_configuration.xml' "$SKU" ||
    die "could not patch the SKU audio policy"
chown 0:0 "$SKU"
chmod 0644 "$SKU"
chcon u:object_r:vendor_configs_file:s0 "$SKU"

# ---- 3. enable A2DP offload in /vendor/build.prop -----------------------------
log "enabling A2DP offload properties in /vendor/build.prop"
[ -f "$TMP/build.prop.stock" ] || cp -f "$BP" "$TMP/build.prop.stock"
sed -i 's#^ro.bluetooth.a2dp_offload.supported=.*#ro.bluetooth.a2dp_offload.supported=true#' "$BP"
sed -i 's#^persist.bluetooth.a2dp_offload.disabled=.*#persist.bluetooth.a2dp_offload.disabled=false#' "$BP"
sed -i 's#^#[[:space:]]*persist\.vendor\.qcom\.bluetooth\.a2dp_offload_cap=#persist.vendor.qcom.bluetooth.a2dp_offload_cap=#' "$BP"
grep -q '^ro.bluetooth.a2dp_offload.supported=' "$BP" ||
    echo "ro.bluetooth.a2dp_offload.supported=true" >>"$BP"
grep -q '^persist.bluetooth.a2dp_offload.disabled=' "$BP" ||
    echo "persist.bluetooth.a2dp_offload.disabled=false" >>"$BP"
grep -q '^persist.vendor.qcom.bluetooth.a2dp_offload_cap=' "$BP" ||
    echo "persist.vendor.qcom.bluetooth.a2dp_offload_cap=$CAP" >>"$BP"
chown 0:0 "$BP"
chmod 0644 "$BP"
chcon u:object_r:vendor_file:s0 "$BP" 2>/dev/null || true

# ---- 4. report ---------------------------------------------------------------
log "installed state:"
md5sum "$XML_DST" "$SO_DST"
grep -n 'bluetooth.*audio_policy_configuration' "$SKU"
grep -n 'a2dp_offload' "$BP"
DEVICE_SCRIPT_EOF

adb push "$WORK/device_install.sh" /data/local/tmp/warm_bt_fix.sh >/dev/null

# ------------------------------------------------------------------------------
# 4. Run the on-device installer
# ------------------------------------------------------------------------------
adb shell sh /data/local/tmp/warm_bt_fix.sh

say "restarting audioserver"
adb shell 'killall audioserver >/dev/null 2>&1 || true'
sleep 4

# ------------------------------------------------------------------------------
# 5. Finish
# ------------------------------------------------------------------------------
if [ "$REBOOT" = "1" ]; then
    say "rebooting the device"
    adb reboot
    exit 0
fi

cat <<'EOF'

--------------------------------------------------------------------------
Installation complete. A reboot is required for the new properties to load:

    adb reboot

After the reboot, connect the Bluetooth headset and play music.
Verify with:

    adb shell dumpsys bluetooth_manager | grep mA2dpOffloadEnabled

Expected output: mA2dpOffloadEnabled: true
--------------------------------------------------------------------------
EOF
