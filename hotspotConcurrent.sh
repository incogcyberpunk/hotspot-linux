#!/bin/bash
# Concurrent AP+STA: add a second vif and hand it to the existing Hotspot profile.
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"

STATION=wlan0
AP=ap0
PROFILE=Hotspot

# The second vif needs its own address: flip the locally-administered bit of
# byte 0 so it can't collide with the station interface.
BASE=$(cat "/sys/class/net/$STATION/address")
MAC=$(printf '%02x%s' "$(( 0x${BASE%%:*} ^ 2 ))" "${BASE#??}")

iw dev "$STATION" interface add "$AP" type __ap addr "$MAC"

nmcli con mod "$PROFILE" connection.interface-name "$AP"
nmcli con up "$PROFILE"
