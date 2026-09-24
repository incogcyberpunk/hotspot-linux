#!/bin/bash
# Concurrent AP+STA on the MT7663 (mt7615e): add a second vif pinned to wlan0's
# current channel, since the chip allows many interfaces but only one channel.
#
#   hotspotConcurrent.sh        bring the hotspot up alongside the Wi-Fi link
#   hotspotConcurrent.sh down   tear it down, leave the Wi-Fi link alone
#
# ponytail: the channel is read once at activation. If the router moves channel
# while the hotspot is up, the AP goes deaf and you must re-run this. Following
# it live would need a netlink listener on CH_SWITCH events.
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

if [ -n "$CH" ]; then
    # Station is associated: must share its channel (single-channel radio).
    [ "${FREQ%% *}" -ge 5000 ] && BAND=a || BAND=bg
    echo "$STATION is on channel $CH (${FREQ%% *} MHz) -> pinning $AP to the same channel, band $BAND"
else
    # Not associated: no channel to match, so any legal one works. The hotspot
    # comes up with no uplink -- clients get an IP but no internet until $STATION
    # connects to something.
    CH=6
    BAND=bg
    echo "$STATION not connected -- creating hotspot without internet on channel $CH, band $BAND"
fi

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
