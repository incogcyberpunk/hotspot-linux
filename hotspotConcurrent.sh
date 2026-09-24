#!/bin/bash
# Concurrent AP+STA on a single-radio Wi-Fi adapter: add an ap0 vif pinned to wlan0's channel.
# Full rationale + walkthrough: see hotspotConcurrent.md
#
#   hotspotConcurrent.sh up [--name X] [--pass Y]   bring the hotspot up
#   hotspotConcurrent.sh down                        tear it down, leave the Wi-Fi link alone
#   hotspotConcurrent.sh [status]                    show status (QR on top, stats below)
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"   # re-exec as root if needed

STATION=wlan0
AP=ap0
PROFILE=Hotspot

CMD=${1:-status}   # no arg = status
[ $# -gt 0 ] && shift

# --- shared: print the join QR for the profile's effective SSID/password ---
print_qr() {   # $1=ssid $2=pass
    command -v qrencode >/dev/null || return 0
    esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
    qrencode -m 1 -t UTF8 "WIFI:T:WPA;S:$(esc "$1");P:$(esc "$2");;"
}

case $CMD in
down)
    nmcli con down "$PROFILE" 2>/dev/null || true   # cleanup hygiene: ignore "not active"
    iw dev "$AP" del 2>/dev/null || true            # cleanup hygiene: ignore "no such dev"
    echo "hotspot down, $STATION untouched"
    exit 0
    ;;

status)
    SSID=$(nmcli -g 802-11-wireless.ssid con show "$PROFILE" 2>/dev/null)
    if iw dev "$AP" info >/dev/null 2>&1; then
        # AP vif exists -> hotspot is up. QR on top, stats below.
        PASS=$(nmcli -s -g 802-11-wireless-security.psk con show "$PROFILE" 2>/dev/null)
        ACH=$(iw dev "$AP" info | awk '/channel/ {print $2}')
        NCLIENTS=$(iw dev "$AP" station dump 2>/dev/null | grep -c '^Station') || true  # 0 matches = exit 1
        IP=$(ip -4 -o addr show "$AP" 2>/dev/null | awk '{print $4}')
        print_qr "$SSID" "$PASS"
        echo
        printf '  %-10s %s\n' "status"  "UP"
        printf '  %-10s %s\n' "ssid"    "$SSID"
        printf '  %-10s %s\n' "password" "$PASS"
        printf '  %-10s %s\n' "channel" "$ACH"
        printf '  %-10s %s\n' "address" "${IP:-none}"
        printf '  %-10s %s\n' "clients" "${NCLIENTS:-0}"
    else
        echo "hotspot is down"
        echo "  ssid    ${SSID:-<none saved>}"
        echo
        echo "start it with:"
        echo "  hotspotConcurrent.sh up [--name <SSID>] [--pass <password>]"
    fi
    exit 0
    ;;

up) : ;;   # fall through to bring-up below
*)
    echo "usage: hotspotConcurrent.sh {up [--name X] [--pass Y] | down | status}" >&2
    exit 1
    ;;
esac

# ---- bring-up (CMD = up) ----
SSID=""   # empty = keep whatever the profile already has
PASS=""   # empty = keep whatever the profile already has

# arg parsing (see hotspotConcurrent.md): flags in any order
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

# join QR: read the effective SSID/password back from the profile (handles "kept existing")
QSSID=$(nmcli -g 802-11-wireless.ssid con show "$PROFILE")
QPASS=$(nmcli -s -g 802-11-wireless-security.psk con show "$PROFILE")
echo "--- scan to join \"$QSSID\" ---"
print_qr "$QSSID" "$QPASS"
