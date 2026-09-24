#!/bin/bash
# Concurrent AP+STA: add a second vif and hand it to the existing Hotspot profile.
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"

STATION=wlan0
AP=ap0
PROFILE=Hotspot

iw dev "$STATION" interface add "$AP" type __ap

nmcli con mod "$PROFILE" connection.interface-name "$AP"
nmcli con up "$PROFILE"
