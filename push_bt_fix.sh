
#!/usr/bin/env bash
# ==============================================================================
# Warm (Redmi A4 5G - 24116RNC1I)
# Bluetooth A2DP Offload Fix - LineageOS 24 / Android 17
#
# Repository:
# https://github.com/Shyam-vadgama/warm-bt-a2dp-fix
#
# Usage:
# curl -fsSL https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/push_bt_fix.sh | bash
#
# Reboot automatically:
# curl -fsSL https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main/push_bt_fix.sh | bash -s -- --reboot
# ==============================================================================

set -Eeuo pipefail

REPO_RAW="${WARM_BT_FIX_RAW:-https://raw.githubusercontent.com/Shyam-vadgama/warm-bt-a2dp-fix/main}"

XML_NAME="bluetooth_qti_audio_policy_configuration.xml"
SO_NAME="audio.bluetooth_qti.default.so"

XML_MD5="322e6992c6e04dd4de2775a05fa59266"
SO_MD5="568ad926348846885a30a1b3cc30c967"

CAP="sbc-aptx-aptxtws-aptxhd-aac-ldac"

REBOOT=0

for arg in "$@"; do
    case "$arg" in
        --reboot) REBOOT=1 ;;
        -h|--help)
            echo "Usage: push_bt_fix.sh [--reboot]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

say() {
    printf '[warm-bt-fix] %s\n' "$*"
}

die() {
    printf '[warm-bt-fix] ERROR: %s\n' "$*" >&2
    exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/warm-bt-fix.XXXXXX")"

cleanup() {
    rm -rf "$WORK"
}

trap cleanup EXIT

# ==============================================================================
# 1. Locate / download files
# ==============================================================================

SELF_DIR=""

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

locate() {
    local name="$1"
    local dir

    for dir in "$SELF_DIR" "$PWD" "$PWD/files"; do
        if [ -n "$dir" ] && [ -s "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done

    return 1
}

fetch() {
    local name="$1"
    local expected="$2"
    local path found got

    if found="$(locate "$name")"; then
        say "Using local file: $found"
        path="$found"
    else
        command -v curl >/dev/null 2>&1 ||
            die "curl is not installed"

        say "Downloading $name"

        curl -fsSL --retry 3 \
            "$REPO_RAW/$name" \
            -o "$WORK/$name" ||
            die "Download failed: $name"

        path="$WORK/$name"
    fi

    if command -v md5sum >/dev/null 2>&1; then
        got="$(md5sum "$path" | awk '{print $1}')"

        [ "$got" = "$expected" ] ||
            die "Checksum mismatch for $name"
    else
        die "md5sum is required for file verification"
    fi

    printf '%s\n' "$path"
}

XML_PATH="$(fetch "$XML_NAME" "$XML_MD5")"
SO_PATH="$(fetch "$SO_NAME" "$SO_MD5")"

[ -s "$XML_PATH" ] || die "XML file missing"
[ -s "$SO_PATH" ] || die "SO file missing"

# ==============================================================================
# 2. Check ADB
# ==============================================================================

command -v adb >/dev/null 2>&1 ||
    die "ADB not found. Install Android platform-tools."

adb start-server >/dev/null 2>&1 || true

adb get-state >/dev/null 2>&1 ||
    die "No authorized device found. Enable USB debugging."

say "Device connected"

say "Requesting root"

ROOT_OUTPUT="$(adb root 2>&1 || true)"
echo "$ROOT_OUTPUT"

adb wait-for-device

ROOT_UID="$(adb shell id -u | tr -d '\r')"

[ "$ROOT_UID" = "0" ] ||
    die "ADB root is required. Run on userdebug/eng or a supported rooted setup."

# ==============================================================================
# 3. Remount vendor
# ==============================================================================

say "Remounting vendor read-write"

adb remount ||
    die "adb remount failed. Check overlayfs/root support."

# ==============================================================================
# 4. Upload payload
# ==============================================================================

say "Uploading Bluetooth files"

adb push "$XML_PATH" /data/local/tmp/bq.xml >/dev/null
adb push "$SO_PATH" /data/local/tmp/bq.so >/dev/null

# ==============================================================================
# 5. Create on-device installer
# ==============================================================================

cat > "$WORK/device_install.sh" <<'DEVICE_SCRIPT_EOF'
#!/system/bin/sh

set -eu

TMP=/data/local/tmp

XML_DST=/vendor/etc/bluetooth_qti_audio_policy_configuration.xml
SO_DST=/vendor/lib64/hw/audio.bluetooth_qti.default.so

SKU=/vendor/etc/audio/sku_pitti/audio_policy_configuration.xml
BP=/vendor/build.prop

CAP="sbc-aptx-aptxtws-aptxhd-aac-ldac"

log() {
    echo "[warm-bt-fix] $*"
}

die() {
    echo "[warm-bt-fix] ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

[ "$(id -u)" = "0" ] || die "Root required"

[ -s "$TMP/bq.xml" ] || die "Missing XML payload"
[ -s "$TMP/bq.so" ] || die "Missing SO payload"

[ -f "$SKU" ] || die "SKU audio policy not found"
[ -f "$BP" ] || die "Vendor build.prop not found"

# Test vendor write access

touch /vendor/.warm_rw_test 2>/dev/null ||
    die "/vendor is read-only. Run adb remount."

rm -f /vendor/.warm_rw_test

# ------------------------------------------------------------------------------
# 1. Install Bluetooth HAL and policy
# ------------------------------------------------------------------------------

log "Installing Bluetooth A2DP HAL and audio policy"

mkdir -p /vendor/lib64/hw

cp -f "$TMP/bq.xml" "$XML_DST"
cp -f "$TMP/bq.so" "$SO_DST"

chown 0:0 "$XML_DST" "$SO_DST"

chmod 0644 "$XML_DST" "$SO_DST"

chcon u:object_r:vendor_configs_file:s0 "$XML_DST"
chcon u:object_r:vendor_file:s0 "$SO_DST"

# ------------------------------------------------------------------------------
# 2. Patch SKU audio policy
# ------------------------------------------------------------------------------

log "Patching SKU audio policy"

if [ ! -f "$TMP/audio_policy_configuration.xml.stock" ]; then
    cp -f "$SKU" "$TMP/audio_policy_configuration.xml.stock"
fi

sed -i \
's#bluetooth_hearing_aid_audio_policy_configuration\.xml#bluetooth_qti_audio_policy_configuration.xml#g' \
"$SKU"

grep -q 'bluetooth_qti_audio_policy_configuration.xml' "$SKU" ||
    die "Failed to patch SKU audio policy"

chown 0:0 "$SKU"
chmod 0644 "$SKU"

chcon u:object_r:vendor_configs_file:s0 "$SKU"

# ------------------------------------------------------------------------------
# 3. Enable A2DP offload properties
# ------------------------------------------------------------------------------

log "Configuring A2DP offload properties"

if [ ! -f "$TMP/build.prop.stock" ]; then
    cp -f "$BP" "$TMP/build.prop.stock"
fi

set_prop() {
    key="$1"
    value="$2"

    if grep -q "^[[:space:]#]*${key}=" "$BP"; then
        sed -i "s#^[[:space:]#]*${key}=.*#${key}=${value}#" "$BP"
    else
        echo "${key}=${value}" >> "$BP"
    fi
}

set_prop "ro.bluetooth.a2dp_offload.supported" "true"

set_prop "persist.bluetooth.a2dp_offload.disabled" "false"

set_prop "persist.vendor.qcom.bluetooth.a2dp_offload_cap" "$CAP"

chown 0:0 "$BP"
chmod 0644 "$BP"

chcon u:object_r:vendor_file:s0 "$BP" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Verify installation
# ------------------------------------------------------------------------------

log "Verifying installed files"

[ -s "$XML_DST" ] || die "XML installation failed"
[ -s "$SO_DST" ] || die "SO installation failed"

md5sum "$XML_DST" "$SO_DST"

log "Verifying SKU policy"

grep -n 'bluetooth.*audio_policy_configuration' "$SKU"

log "Verifying A2DP properties"

grep -n 'a2dp_offload' "$BP"

log "Bluetooth A2DP fix installed successfully"

DEVICE_SCRIPT_EOF

# ==============================================================================
# 6. Push and execute installer
# ==============================================================================

say "Uploading device installer"

adb push "$WORK/device_install.sh" \
    /data/local/tmp/warm_bt_fix.sh >/dev/null

say "Installing Bluetooth A2DP fix"

adb shell sh /data/local/tmp/warm_bt_fix.sh ||
    die "Device installation failed"

# ==============================================================================
# 7. Restart audio services
# ==============================================================================

say "Restarting audioserver"

adb shell 'killall audioserver >/dev/null 2>&1 || true'

sleep 4

# ==============================================================================
# 8. Finish
# ==============================================================================

if [ "$REBOOT" = "1" ]; then
    say "Rebooting device"
    adb reboot
    exit 0
fi

cat <<'EOF'

============================================================
       WARM BLUETOOTH A2DP FIX INSTALLED
============================================================

Installation completed successfully.

A reboot is required for the new properties to load.

Run:

    adb reboot

After reboot, connect your Bluetooth headset and play music.

Verify:

    adb shell dumpsys bluetooth_manager | grep -E 'mA2dpOffloadEnabled|mCodecConfig'

============================================================
EOF
