#!/bin/bash
# Concurrent AP+STA on MT7663 (mt7615e): add an ap0 vif pinned to wlan0's channel.
# Full rationale + walkthrough: see hotspotConcurrent.md
#
#   hotspotConcurrent.sh                       up, default SSID
#   hotspotConcurrent.sh [up] "MyNet"          up, SSID "MyNet"
#   hotspotConcurrent.sh [up] --name "MyNet"   same, explicit flag
#   hotspotConcurrent.sh down                  tear down, leave the Wi-Fi link alone
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"   # re-exec as root if needed

STATION=wlan0
AP=ap0
PROFILE=Hotspot
SSID=Hotspot-Incog   # default; override via arg

if [ "$1" = down ]; then
    nmcli con down "$PROFILE" 2>/dev/null || true   # cleanup hygiene: ignore "not active"
    iw dev "$AP" del 2>/dev/null || true            # cleanup hygiene: ignore "no such dev"
    echo "hotspot down, $STATION untouched"
    exit 0
fi

# arg parsing: optional "up", optional "--name", bare SSID
[ "$1" = up ] && shift
[ "$1" = --name ] && shift
[ -n "$1" ] && SSID=$1

CH=$(iw dev wlan0 info | awk '/channel/ {print $2}')     # station channel
FREQ=$(iw dev wlan0 link | awk '/freq:/ {print $2}')     # station freq (has decimal)

if [ -n "$CH" ]; then
    # associated: must share the station's channel (single-channel radio)
    [ "${FREQ%%.*}" -ge 5000 ] && BAND=a || BAND=bg      # %%.* strips ".0" -> integer
    echo "$STATION is on channel $CH (${FREQ%%.*} MHz) -> pinning $AP to the same channel, band $BAND"
else
    # not associated: no uplink, clients get IP but no internet
    CH=6
    BAND=bg
    echo "$STATION not connected -- creating hotspot without internet on channel $CH, band $BAND"
fi

# derive a distinct MAC: XOR byte 0 with 0x02 (locally-administered bit)
BASE=$(cat "/sys/class/net/$STATION/address")
MAC=$(printf '%02x%s' "$(( 0x${BASE%%:*} ^ 2 ))" "${BASE#??}")

iw dev "$AP" del 2>/dev/null || true                     # remove stale ap0
iw dev "$STATION" interface add "$AP" type __ap addr "$MAC"   # second vif in AP mode

nmcli con mod "$PROFILE" \
    connection.interface-name "$AP" \
    802-11-wireless.ssid "$SSID" \
    802-11-wireless.band "$BAND" \
    802-11-wireless.channel "$CH"
nmcli con up "$PROFILE"

echo "--- result: expect $STATION=managed and $AP=AP on channel $CH ---"
iw dev | grep -E 'Interface|ssid|type|channel'   # verify two vifs, same channel
