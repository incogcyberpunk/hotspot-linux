# `hotspot` — Concurrent Wi-Fi AP + Station on a single-radio adapter

> Long-term memory doc. The script is intentionally terse; **this file is the real
> explanation** — the networking, the kernel/driver constraints, and the bash mechanics.
> Read this first if it's been a while.

---

## 1. The problem

This laptop has **one** Wi-Fi radio (`wlan0`, a single wireless adapter exposed as `phy0`).
It needs to do two things *at once*:

1. Stay connected to an upstream Wi-Fi network as a **client** — this is the uplink.
2. Broadcast a **hotspot** that shares that uplink to other devices.

NetworkManager's built-in "Turn on hotspot" button **cannot** do this on one radio.
When you enable it, NM reconfigures the *existing* `wlan0` interface: it flips the single
netdev from **station (managed)** mode to **AP** mode. That AP mode is mutually exclusive
with being a client — so the very uplink the hotspot was supposed to share is destroyed the
instant the hotspot comes up.

The symptom is subtle and infuriating: clients **do** connect and **do** get an IP
(`10.42.0.x`) from the dnsmasq that NM spawns — but there is **no internet**, because the NAT
NM installed has no upstream route anymore. `wlan0` is no longer talking to the router.

### Observed before / after (same interface, `wlan0`)

| | Type | Channel | Band | Role |
|---|---|---|---|---|
| **Before** (client) | `managed` | 36 | 5 GHz | connected to the upstream network |
| **After** NM hotspot | `AP` | 6 | 2.4 GHz | broadcasting the hotspot SSID |

Same physical interface, silently repurposed. The uplink is gone.

**The goal of this script:** keep `wlan0` a station on channel 36 *and* stand up a
**second** interface (`ap0`) in AP mode on the **same channel**, so both coexist.

---

## 2. Key concepts (for the intermediate reader)

### (a) A `phy` is the radio; a `netdev` is a virtual interface on top of it

- A **phy** (e.g. `phy0`) is the physical radio — the actual wireless chip + antennas. There
  is exactly one here.
- A **netdev** / **vif** (virtual interface) is a software interface layered on a phy —
  `wlan0`, `ap0`, etc. One phy can host **multiple** netdevs, and each can be in a
  **different 802.11 mode**.

So "one radio" does *not* mean "one interface". The chip can present several vifs; they just
all share the one physical radio underneath (and therefore its constraints — see (c)).

```
        phy0  (wireless radio)
        │
        ├── wlan0   type managed  (station / client → upstream network)
        └── ap0     type AP       (the hotspot)
```

### (b) 802.11 interface modes

- **managed** = station / client. Associates *to* an access point. This is normal "join a
  Wi-Fi network" mode.
- **AP** = access point. *Broadcasts* a network others join.

A single vif is in exactly one mode. The NM hotspot's mistake is putting the *only* vif into
AP mode. The fix is a *second* vif in AP mode.

### (c) The interface-combinations constraint (the crux)

`iw list` reports what concurrent combinations the driver allows. For this chip:

```
valid interface combinations:
    * #{ managed } <= 16, #{ AP } <= 16, ...
      total <= 16, #channels <= 1, STA/AP BI must match
```

Two clauses matter enormously:

- **`#channels <= 1`** — every vif on this phy must be on the **same channel**. There is one
  radio tuner; it can only be on one frequency at a time. So a concurrent AP **must** sit on
  the **exact same channel** as the station link.
- **`STA/AP BI must match`** — the station and AP must share a compatible **beacon interval**.

This single-channel rule is the whole ballgame. It's *why* the script reads `wlan0`'s current
channel and pins `ap0` to it, rather than letting the AP pick its own. If the AP tried to sit
on a different channel, the driver would refuse (or the radio would thrash).

> The chip can host **16 vifs** — plenty of interfaces. The scarce resource is **channels**,
> not interfaces.

### (d) Why the second vif needs its own MAC

A MAC address is the **layer-2 identity** of an interface. For an AP it *is* the **BSSID** —
the identifier clients lock onto. If two vifs on one phy share a MAC, frames become ambiguous
(which vif does an incoming frame belong to?), so the kernel simply **rejects** creating the
second vif with a duplicate address. Each vif needs a distinct MAC.

### (e) The locally-administered bit — deriving a guaranteed-unique MAC

A MAC's first byte carries two special low bits:

```
byte 0:  b7 b6 b5 b4 b3 b2 b1 b0
                            │  └─ I/G bit (0 = unicast)
                            └──── U/L bit (0 = globally unique / vendor-assigned,
                                           1 = locally administered)
```

The **U/L bit** (value `0x02`) says whether the address is a real vendor-burned address
(bit = 0) or a locally-invented one (bit = 1). The IEEE guarantees it will **never** assign a
real vendor an address with this bit set. So taking the station's real MAC and **XORing
byte 0 with `0x02`** flips that bit and yields an address that:

- differs from the station's (no collision), and
- can **never** clash with any real hardware on the network.

Station `<octet0>:xx:xx:xx:xx:xx` → AP `<octet0 ⊕ 0x02>:xx:xx:xx:xx:xx`
(e.g. `0x40 ^ 0x02 = 0x42`; the rest of the address is untouched).

**Deterministic derivation beats random.** Because the script always derives the same AP MAC
from the same station MAC, clients see a **stable BSSID** across restarts — they reconnect
cleanly instead of treating each restart as a brand-new network.

### (f) `ipv4.method=shared` — what NM actually does for a hotspot

The `Hotspot` NM profile uses `ipv4.method=shared`, which makes NetworkManager:

- assign `10.42.0.1/24` to the AP interface,
- spawn a **dnsmasq** instance for **DHCP + DNS** (this is why clients get `10.42.0.x`),
- install **NAT masquerade** so client traffic is routed out via the default route.

The masquerade is the piece that needs a working uplink. With NM's built-in hotspot the
uplink is gone, so the masquerade has nowhere to go → IP but no internet. With this script the
uplink (`wlan0`) is still up, so masquerade works.

### (g) The shared channel is *not* the internet path (a common confusion)

It's tempting to think that once `ap0` and `wlan0` share a channel, the internet somehow
"flows through the common channel." It doesn't. These are **two separate mechanisms**, at two
different layers, and conflating them hides how the traffic actually moves:

- **Same channel = coexistence (layer 1/2).** The shared channel is only what lets the two
  vifs exist on one radio at all — it satisfies `#channels <= 1` (see §c). It is a
  *precondition*, not a data path. It carries no client's internet traffic by itself.
- **Routing + NAT = internet (layer 3).** A client's packet is *forwarded between two distinct
  interfaces* by the kernel, exactly as it would be between an Ethernet port and a Wi-Fi port:

```
phone ──▶ ap0 (10.42.0.1) ──route──▶ NAT/masquerade ──▶ wlan0 ──▶ router ──▶ internet
          └──────── same radio, same channel ────────┘   └──── the real uplink ────┘
```

Step by step: a packet arrives at `ap0`; the kernel **routes** it (destination is the wider
internet, so it follows the default route out `wlan0`); `ipv4.method=shared` **NATs** it so
the source `10.42.0.x` is rewritten as `wlan0`'s address; the router replies to `wlan0`; the
reply is un-NATed and delivered back to the client via `ap0`. The shared channel is nowhere in
that chain — it's just what keeps both interfaces *alive at the same instant* so forwarding
between them is possible.

Two facts make the separation obvious:

- **Same channel, no uplink → no internet.** In the disconnected case (`wlan0` not
  associated), the two vifs still coexist on one channel perfectly, but clients get an IP and
  *no internet* — because there is no route out and nothing to NAT toward.
- **Different channels *can* still bridge internet.** A router with two separate radios shares
  internet across *different* channels. So "same channel" is neither necessary nor sufficient
  for internet; **uplink + routing + NAT** is what delivers it.

> **Throughput cost.** Because `ap0` and `wlan0` share **one radio on one channel**, they also
> share the airtime: the uplink traffic and the hotspot's client traffic take turns on the
> same frequency. Expect roughly **half** the throughput of a dedicated AP. This is a
> performance cost of single-radio concurrency, not a connectivity problem.

---

## 3. Windows does this out of the box — why doesn't Linux?

Windows' **Mobile Hotspot** just works while you stay online. That's not because Windows
escapes the single-channel constraint — it's because of a **driver model**:

- Windows defines **WDI / WiFiCx**, a driver interface every Wi-Fi vendor **must** implement
  to get their hardware certified. Part of that contract is virtual-interface / concurrency
  support.
- **Mobile Hotspot** is built on the **Wi-Fi Direct** stack. When you toggle it on, the OS
  **auto-creates a second virtual adapter**, **pins it to the station's channel**, and
  **tears it down** automatically when you turn it off. All the messy parts of this script are
  done for you by the OS + driver.

On Linux, the kernel side **already exposes the same capability**: `mac80211` / `nl80211` let
you create a second AP vif and set its channel — which is exactly what this script does via
`iw`. The gap is purely in **userspace policy**: **NetworkManager never implemented** "create
a virtual AP interface and match it to the station's channel." So NM takes the lazy path and
reconfigures the one interface it already has.

> **Crucially:** even on Windows the **`#channels <= 1`** constraint still applies — the
> hotspot lands on the *same* channel as your uplink. Windows just **hides** that from you; it
> doesn't escape it. Our script makes the same rule explicit.

---

## 4. The fix (what this script does)

1. Read `wlan0`'s **current channel and band** (from `iw`).
2. Create a **second netdev `ap0`** on `wlan0`'s phy, in **AP mode** (`type __ap`).
3. Give `ap0` a **distinct, locally-administered MAC** (XOR byte 0 with `0x02`).
4. **Pin `ap0` to the station's channel/band** (satisfying `#channels <= 1`).
5. Bind the existing NetworkManager **`Hotspot`** profile to **`ap0` by name** and bring it up.

Result: `wlan0` **stays a station** on the home network, `ap0` **becomes the AP**, both on the
same channel, and NM's `shared` mode NATs client traffic out through the still-alive uplink.

---

## 5. Line-by-line / block-by-block walkthrough

### Header & safety

```bash
set -e
[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"
```

- **`set -e`** — abort the whole script the moment any command exits non-zero. Keeps a
  half-configured hotspot from limping along. (This is *why* the cleanup idiom in the next
  section needs `|| true` — see below.)
- **`[ "$EUID" -eq 0 ] || exec sudo -- "$0" "$@"`** — self-re-exec as root.
  - `$EUID` is the effective user id; `0` is root.
  - If **not** root, the `||` fires and the script **`exec sudo`**s — replacing the current
    process image (no child, no return) with the same script under sudo.
  - `--` ends sudo's own option parsing so a weird `$1` (e.g. `--name`) isn't eaten by sudo.
  - `"$0" "$@"` re-passes the script path and **all original arguments** verbatim.
  - Net effect: run it as a normal user and it silently elevates itself once.

### The `down` / teardown branch

```bash
if [ "$1" = down ]; then
    nmcli con down "$PROFILE" 2>/dev/null || true
    iw dev "$AP" del 2>/dev/null || true
    echo "hotspot down, $STATION untouched"
    exit 0
fi
```

Deactivate the NM profile and delete the `ap0` vif. **`wlan0` is never touched**, so the
uplink survives teardown. Note it uses the **cleanup-hygiene idiom** explained next.

### The `2>/dev/null || true` cleanup-hygiene idiom

```bash
nmcli con down "$PROFILE" 2>/dev/null || true
iw dev "$AP" del 2>/dev/null || true
```

These commands are *expected* to sometimes fail harmlessly — the profile might already be
down, `ap0` might not exist. We want "make sure it's gone", not "it must currently be here".
Both pieces are needed and they do **different** jobs:

- **`2>/dev/null`** suppresses the **stderr noise** (`Error: 'ap0' does not exist`). It only
  hides the *message* — it does **not** change the exit code.
- **`|| true`** handles the **exit code**. The command still exits non-zero on "not found",
  and under **`set -e`** a non-zero exit would **kill the script**. `|| true` swallows that
  failure so execution continues.

So: `2>/dev/null` = quiet, `|| true` = don't die. Drop `|| true` and `set -e` aborts on a
harmless "already gone". Drop `2>/dev/null` and it works but spams errors. You want both.

### Argument parsing

An optional leading `up` is shifted off, then a `while`/`case` loop consumes flags in any
order:

```bash
[ "$1" = up ] && shift
while [ $# -gt 0 ]; do
    case $1 in
        --name)     SSID=$2; shift 2 ;;
        --name=*)   SSID=${1#*=}; shift ;;
        --pass|--password)  PASS=$2; shift 2 ;;
        --pass=*)   PASS=${1#*=}; shift ;;
        --password=*)       PASS=${1#*=}; shift ;;
        -*)         echo "unknown flag: $1" >&2; exit 1 ;;
        *)          SSID=$1; shift ;;
    esac
done
```

- **`while [ $# -gt 0 ]`** — loop while any arguments remain (`$#` is the count).
- **`shift 2`** — a flag that takes a value drops **both** the flag and its value in one step.
- **`--name=*` / `--pass=*`** — the `--flag=value` form; `${1#*=}` strips up to the first `=`,
  leaving just the value.
- **`-*)`** — any unrecognised flag is a hard error rather than being silently swallowed.
- **`*)`** — a bare word (no leading `-`) is taken as the SSID.

`SSID` and `PASS` both default to **empty**, meaning *keep whatever the profile already has* —
so `up` with no flags reuses the saved network name and password. This is why `up`,
`up "MyNet"`, `up --name "MyNet"`, `--pass "secret123"`, `--name=N --pass=P`, etc. all resolve
correctly (see §6).

**Password length is validated at the boundary:**

```bash
if [ -n "$PASS" ] && { [ "${#PASS}" -lt 8 ] || [ "${#PASS}" -gt 63 ]; }; then
    echo "password must be 8-63 characters (got ${#PASS})" >&2
    exit 1
fi
```

WPA2-PSK requires **8–63 characters**. `${#PASS}` is the string length. Checking here means a
bad password fails with a clear message *before* `nmcli` is touched, instead of surfacing as a
cryptic activation error later.

### Reading the station's channel and frequency

```bash
CH=$(iw dev wlan0 info | awk '/channel/ {print $2}')
FREQ=$(iw dev wlan0 link | awk '/freq:/ {print $2}')
```

- **`CH`** from `iw dev wlan0 info` — the current channel number (e.g. `36`). If `wlan0` is
  **not** associated, this line comes back **empty**, which is how the script detects the
  disconnected case below.
- **`FREQ`** from `iw dev wlan0 link` — the operating frequency in MHz. `iw link` reports it
  with a **decimal**, e.g. `5180.0`.

### Connected branch — band selection and the `%%.*` gotcha

```bash
if [ -n "$CH" ]; then
    [ "${FREQ%%.*}" -ge 5000 ] && BAND=a || BAND=bg
    ...
```

- **`-n "$CH"`** — non-empty channel ⇒ station is associated ⇒ the AP must match its channel.
- **`${FREQ%%.*}`** — parameter expansion: `%%.*` strips the **longest** trailing match of
  `.*`, turning `5180.0` into `5180`. **Why it's required:** `[` does integer comparison, and
  `[ 5180.0 -ge 5000 ]` throws **`integer expression expected`** — a non-zero exit that under
  **`set -e`** would abort the script. Stripping the decimal makes it a real integer.
- **band rule** — ≥ 5000 MHz ⇒ 5 GHz ⇒ `BAND=a`; else 2.4 GHz ⇒ `BAND=bg`.

Note the channel itself (`CH=36`) needs **no** stripping — `iw ... info` already prints a
clean integer. Only the **frequency** carries the decimal, and only `FREQ` is fed to `[ -ge ]`.

### Disconnected branch — fallback with no uplink

```bash
else
    CH=6
    BAND=bg
    echo "$STATION not connected -- creating hotspot without internet ..."
fi
```

No association ⇒ no channel to match ⇒ any legal channel works, so default to **channel 6,
band bg** (2.4 GHz, universally supported). The hotspot comes up but has **no upstream**, so
clients get an IP from dnsmasq but **no internet** until `wlan0` associates with something.

### MAC derivation, piece by piece

```bash
BASE=$(cat "/sys/class/net/$STATION/address")
MAC=$(printf '%02x%s' "$(( 0x${BASE%%:*} ^ 2 ))" "${BASE#??}")
```

- **`BASE`** — the station's real MAC read straight from sysfs, e.g. `40:aa:bb:cc:dd:ee`.
- **`${BASE%%:*}`** — strip the longest trailing `:*`, leaving just the **first octet**: `40`.
- **`0x${BASE%%:*}`** → `0x40`, so bash treats it as **hex** in arithmetic.
- **`$(( 0x40 ^ 2 ))`** — arithmetic **XOR** with `2` (`0x02`, the U/L bit). `0x40 ^ 0x02`
  = `0x42` = decimal `66`.
- **`${BASE#??}`** — strip the **shortest** leading two chars (`??` = the two hex digits of
  octet 0), leaving `:aa:bb:cc:dd:ee`. (It keeps the leading colon.)
- **`printf '%02x%s'`** — format the XORed octet as **two lowercase hex digits** (`42`), then
  append the rest verbatim → `42:aa:bb:cc:dd:ee`.

So `40:aa:bb:cc:dd:ee` → `42:aa:bb:cc:dd:ee`, a stable, locally-administered, collision-free
BSSID (see §2d/§2e).

### Creating the AP vif

```bash
iw dev "$AP" del 2>/dev/null || true
iw dev "$STATION" interface add "$AP" type __ap addr "$MAC"
```

- First line: delete any **stale `ap0`** from a previous run (cleanup-hygiene idiom again).
- **`iw dev wlan0 interface add ap0 type __ap addr <MAC>`** — ask the *station's phy* to
  create a **new vif** named `ap0` in **AP mode**, with the derived MAC.
  - **`type __ap`** — `iw`'s literal token for access-point mode. The double underscore is
    just `iw`'s naming (`__ap`, `__managed`, …) for the raw nl80211 interface types; it means
    "AP". Adding it on the *station's* phy is what makes the two vifs share the one radio.

### Binding and activating the NM profile

```bash
MODARGS=(connection.interface-name "$AP" 802-11-wireless.band "$BAND" 802-11-wireless.channel "$CH")
[ -n "$SSID" ] && MODARGS+=(802-11-wireless.ssid "$SSID")
[ -n "$PASS" ] && MODARGS+=(802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk "$PASS")
nmcli con mod "$PROFILE" "${MODARGS[@]}"
nmcli con up "$PROFILE"
```

- **`MODARGS=(...)`** — a bash **array** holding the `nmcli` settings. Interface, band, and
  channel are always set. SSID and password are **appended only if provided** (`MODARGS+=(...)`),
  so an empty value leaves the profile's saved name/password untouched rather than blanking it.
  Using an array (not a flat string) keeps each value a single argument even if it contains
  spaces — `"${MODARGS[@]}"` expands to one word per element.
- **`connection.interface-name ap0`** — **bind the profile to `ap0` by name** (not `wlan0`!).
  This is the key line that keeps NM off the station interface.
- **`band` / `channel`** — pin the AP to the station's channel/band computed above.
- **password** — when set, `key-mgmt wpa-psk` + `psk` together configure WPA2.
- **`nmcli con up Hotspot`** — activate. NM applies `ipv4.method=shared`: assigns
  `10.42.0.1/24`, spawns dnsmasq, installs NAT (see §2f).

### Verification

```bash
echo "--- result: expect $STATION=managed and $AP=AP on channel $CH ---"
iw dev | grep -E 'Interface|ssid|type|channel'
```

Dump all vifs and filter to the interesting lines. Success = **two** `Interface` blocks, the
station interface still `type managed`, the AP vif `type AP`, **both on the same channel**
(see §8).

---

## 6. Usage examples

The first argument is a **subcommand** — `up`, `down`, or `status` (bare command = `status`).
All elevate to root automatically via the self-re-exec. On `up`, SSID/password default to
**keeping the profile's saved values** when not passed.

| Command | Effect |
|---|---|
| `hotspot` | show status (QR + stats if up; "down" + start hint if not) |
| `hotspot status` | same as bare `hotspot` |
| `hotspot up` | up, keep saved SSID + password |
| `hotspot up "MyNet"` | up, set SSID `MyNet`, keep password |
| `hotspot up --name "MyNet"` | up, set SSID `MyNet` (explicit flag) |
| `hotspot up --pass "secret123"` | up, set password, keep SSID |
| `hotspot up --name "N" --pass "P"` | set both (flags in any order) |
| `hotspot up --name=N --pass=P` | set both (`--flag=value` form) |
| `hotspot down` | tear down the AP vif + profile, leave the station alone |

Anything else (`hotspot foo`, a bare `--name`, etc.) prints a usage error — `up` is required
to start the hotspot; it is no longer implicit.

---

## 7. Known limitations / caveats

- **Channel is read once, at activation.** If the **router changes channel** while the hotspot
  is up, `wlan0` follows it but `ap0` stays put — the AP effectively goes **deaf** (now on a
  different channel than the radio's tuner). Fix: **re-run** the script.
- **`ap0` is not persistent.** It vanishes on **reboot** or a **wireless driver module reload**.
  Re-run after either.
- **Disconnected case = no internet.** If `wlan0` isn't associated, clients get a `10.42.0.x`
  IP but **no internet** until `wlan0` connects to an uplink.
- **Relies on the driver honoring its advertised combination.** The concurrency is only as good
  as the `iw list` interface-combination table (`#channels <= 1`, 16 vifs). That table was read
  and reasoned from, **but the actual `iw ... interface add` was never executed with root in the
  environment where this script was built** — so that specific step is **unproven** here and
  should be verified on real hardware.

---

## 8. Quick-reference troubleshooting

### ✅ What success looks like (`iw dev` output)

Two `Interface` blocks on the one phy, same channel:

```
Interface wlan0
    type managed
    channel 36 (5180 MHz) ...        ← still on the upstream network
Interface ap0
    type AP
    channel 36 (5180 MHz) ...        ← AP on the SAME channel
```

Both `type` lines correct, both `channel` numbers **equal**, and `wlan0` still associated to
the home network.

### ✗ Common failure signs

| Symptom in `iw dev` / nmcli | Likely cause |
|---|---|
| **Only one `Interface` block** | `iw ... interface add` failed — driver refused the combo, or `ap0` wasn't created (check as root, check `iw list`). |
| **`ap0` on a *different* channel** than `wlan0` | Channel pinning didn't take, or the router hopped channels after activation → re-run. |
| **`nmcli con up Hotspot` fails** | Profile bound to the wrong interface, band/channel mismatch, or `ap0` not present yet. Re-check `connection.interface-name ap0` and that `ap0` exists. |
| **Clients get `10.42.0.x` but no internet** | `wlan0` not associated (disconnected branch), so NAT has no uplink — connect `wlan0` first. |
