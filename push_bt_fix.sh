
#!/usr/bin/env bash
# ==============================================================================
# Warm - Redmi A4 5G (24116RNC1I)
# Bluetooth A2DP Offload Fix
# LineageOS 24 / Android 17
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
    printf '[warm-bt-fix] %s\n' "$*" >&2
}

die() {
    say "ERROR: $*"
    exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/warm-bt-fix.XXXXXX")"

trap 'rm -rf "$WORK"' EXIT

# ==============================================================================
# 1. Locate files
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

    [ -s "$path" ] || die "Empty file: $name"

    command -v md5sum >/dev/null 2>&1 ||
        die "md5sum is required"

    got="$(md5sum "$path" | awk '{print $1}')"

    [ "$got" = "$expected" ] ||
        die "Checksum mismatch for $name: $got"

    # IMPORTANT: Only file path goes to stdout.
    printf '%s\n' "$path"
}

XML_PATH="$(fetch "$XML_NAME" "$XML_MD5")"
SO_PATH="$(fetch "$SO_NAME" "$SO_MD5")"

[ -s "$XML_PATH" ] || die "XML file missing"
[ -s "$SO_PATH" ] || die "SO file missing"

say "Payload files verified"

# ==============================================================================
# 2. ADB checks
# ==============================================================================

command -v adb >/dev/null 2>&1 ||
    die "ADB not found. Install Android platform-tools."

adb start-server >/dev/null 2>&1 || true

adb get-state >/dev/null 2>&1 ||
    die "No authorized device found"

say "Device connected"

say "Requesting root"

ROOT_OUTPUT="$(adb root 2>&1 || true)"
[ -n "$ROOT_OUTPUT" ] && say "$ROOT_OUTPUT"

adb wait-for-device

ROOT_UID="$(adb shell id -u | tr -d '\r')"

[ "$ROOT_UID" = "0" ] ||
    die "ADB root unavailable. Root/userdebug build required."

# ==============================================================================
# 3. Remount
# ==============================================================================

say "Remounting vendor"

adb remount ||
    die "adb remount failed"

# ==============================================================================
# 4. Push payloads
# ==============================================================================

say "Uploading Bluetooth payloads"

adb push "$XML_PATH" /data/local/tmp/bq.xml >/dev/null
adb push "$SO_PATH" /data/local/tmp/bq.so >/dev/null

# ==============================================================================
# 5. On-device installer
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

touch /vendor/.warm_rw_test 2>/dev/null ||
    die "Vendor is read-only"

rm -f /vendor/.warm_rw_test

# ------------------------------------------------------------------------------
# 1. Install HAL and XML
# ------------------------------------------------------------------------------

log "Installing Bluetooth A2DP HAL and policy"

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
    die "SKU policy patch failed"

chown 0:0 "$SKU"
chmod 0644 "$SKU"

chcon u:object_r:vendor_configs_file:s0 "$SKU"

# ------------------------------------------------------------------------------
# 3. Enable A2DP properties
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
# 4. Verify
# ------------------------------------------------------------------------------

log "Verifying installed files"

[ -s "$XML_DST" ] || die "XML installation failed"
[ -s "$SO_DST" ] || die "SO installation failed"

log "Installed file checksums"

md5sum "$XML_DST" "$SO_DST"

log "SKU audio policy"

grep -n 'bluetooth.*audio_policy_configuration' "$SKU"

log "A2DP properties"

grep -n 'a2dp_offload' "$BP"

log "Installation completed"

DEVICE_SCRIPT_EOF

# ==============================================================================
# 6. Execute installer
# ==============================================================================

say "Uploading installer"

adb push "$WORK/device_install.sh" \
    /data/local/tmp/warm_bt_fix.sh >/dev/null

say "Installing Bluetooth fix"

adb shell sh /data/local/tmp/warm_bt_fix.sh ||
    die "Device installation failed"

# ==============================================================================
# 7. Restart audio server
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

Installation completed.

Reboot your device:

    adb reboot

After reboot, connect your Bluetooth headset.

Verify:

    adb shell dumpsys bluetooth_manager | grep -E 'mA2dpOffloadEnabled|mCodecConfig'

============================================================

EOF
