#!/bin/bash
# Concurrent AP+STA: add a second vif and hand it to the existing Hotspot profile.
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"

STATION=wlan0
AP=ap0
PROFILE=Hotspot

if [ "$1" = down ]; then
    nmcli con down "$PROFILE" 2>/dev/null || true
    iw dev "$AP" del 2>/dev/null || true
    echo "hotspot down, $STATION untouched"
    exit 0
fi

CH=$(iw dev wlan0 info | awk '/channel/ {print $2}')
FREQ=$(iw dev wlan0 link | awk '/freq:/ {print $2}')
[ "${FREQ%% *}" -ge 5000 ] && BAND=a || BAND=bg
echo "$STATION is on channel $CH (${FREQ%% *} MHz) -> pinning $AP to the same channel, band $BAND"

# The second vif needs its own address: flip the locally-administered bit of
# byte 0 so it can't collide with the station interface.
BASE=$(cat "/sys/class/net/$STATION/address")
MAC=$(printf '%02x%s' "$(( 0x${BASE%%:*} ^ 2 ))" "${BASE#??}")

iw dev "$AP" del 2>/dev/null || true
iw dev "$STATION" interface add "$AP" type __ap addr "$MAC"

nmcli con mod "$PROFILE" \
    connection.interface-name "$AP" \
    802-11-wireless.band "$BAND" \
    802-11-wireless.channel "$CH"
nmcli con up "$PROFILE"

echo "--- result: expect $STATION=managed and $AP=AP on channel $CH ---"
iw dev | grep -E 'Interface|ssid|type|channel'
