#!/bin/bash
# Concurrent AP+STA on a single-radio Wi-Fi adapter: add an ap0 vif pinned to wlan0's channel.
# Full rationale + walkthrough: see hotspotConcurrent.md
#
#   hotspotConcurrent.sh                              up, keep saved SSID/password
#   hotspotConcurrent.sh [up] "MyNet"                 up, set SSID
#   hotspotConcurrent.sh [up] --name "MyNet"          same, explicit flag
#   hotspotConcurrent.sh [up] --pass "secret123"      up, set password
#   hotspotConcurrent.sh [up] --name "N" --pass "P"   set both (flags any order)
#   hotspotConcurrent.sh down                         tear down, leave the Wi-Fi link alone
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"   # re-exec as root if needed

STATION=wlan0
AP=ap0
PROFILE=Hotspot
SSID=""   # empty = keep whatever the profile already has
PASS=""   # empty = keep whatever the profile already has

if [ "$1" = down ]; then
    nmcli con down "$PROFILE" 2>/dev/null || true   # cleanup hygiene: ignore "not active"
    iw dev "$AP" del 2>/dev/null || true            # cleanup hygiene: ignore "no such dev"
    echo "hotspot down, $STATION untouched"
    exit 0
fi

# arg parsing (see hotspotConcurrent.md): optional "up", then flags in any order
[ "$1" = up ] && shift
while [ $# -gt 0 ]; do
    case $1 in
        --name)     SSID=$2; shift 2 ;;
        --name=*)   SSID=${1#*=}; shift ;;
        --pass|--password)  PASS=$2; shift 2 ;;
        --pass=*)   PASS=${1#*=}; shift ;;
        --password=*)       PASS=${1#*=}; shift ;;
        -*)         echo "unknown flag: $1" >&2; exit 1 ;;
        *)          SSID=$1; shift ;;   # bare positional = SSID
    esac
done

# WPA2-PSK requires 8-63 chars; fail early with a clear message rather than a cryptic nmcli error
if [ -n "$PASS" ] && { [ "${#PASS}" -lt 8 ] || [ "${#PASS}" -gt 63 ]; }; then
    echo "password must be 8-63 characters (got ${#PASS})" >&2
    exit 1
fi

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

# always pin interface/band/channel; set SSID/password only if given (empty = keep existing)
MODARGS=(connection.interface-name "$AP" 802-11-wireless.band "$BAND" 802-11-wireless.channel "$CH")
[ -n "$SSID" ] && MODARGS+=(802-11-wireless.ssid "$SSID")
[ -n "$PASS" ] && MODARGS+=(802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk "$PASS")
nmcli con mod "$PROFILE" "${MODARGS[@]}"
nmcli con up "$PROFILE"

echo "--- result: expect $STATION=managed and $AP=AP on channel $CH ---"
iw dev | grep -E 'Interface|ssid|type|channel'   # verify two vifs, same channel

# QR to join: read the effective SSID/password back from the profile (handles "kept existing"),
# escape the Wi-Fi-URI special chars (\ ; , : "), render with the installed qrencode.
if command -v qrencode >/dev/null; then
    QSSID=$(nmcli -g 802-11-wireless.ssid con show "$PROFILE")
    QPASS=$(nmcli -s -g 802-11-wireless-security.psk con show "$PROFILE")
    esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
    echo "--- scan to join \"$QSSID\" ---"
    qrencode -m 1 -t UTF8 "WIFI:T:WPA;S:$(esc "$QSSID");P:$(esc "$QPASS");;"
fi
