# `hotspotConcurrent.sh` — Concurrent Wi-Fi AP + Station on a single-radio MT7663

> Long-term memory doc. The script is intentionally terse; **this file is the real
> explanation** — the networking, the kernel/driver constraints, and the bash mechanics.
> Read this first if it's been a while.

---

## 1. The problem

I have **one** Wi-Fi radio (`wlan0`, backed by a MediaTek **MT7663** chip on the
`mt7615e` driver, exposed as `phy0`). I want it to do two things *at once*:

1. Stay connected to my home Wi-Fi (`aayush_5G`) as a **client** — this is the uplink.
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
| **Before** (client) | `managed` | 36 | 5 GHz | connected to `aayush_5G` |
| **After** NM hotspot | `AP` | 6 | 2.4 GHz | broadcasting `Hotspot-Incog` |

Same physical interface, silently repurposed. The uplink is gone.

**The goal of this script:** keep `wlan0` a station on channel 36 *and* stand up a
**second** interface (`ap0`) in AP mode on the **same channel**, so both coexist.

---

## 2. Key concepts (for the intermediate dev I'll be in a year)

### (a) A `phy` is the radio; a `netdev` is a virtual interface on top of it

- A **phy** (e.g. `phy0`) is the physical radio — the actual MT7663 chip + antennas,
  driven by `mt7615e`. There is exactly one here.
- A **netdev** / **vif** (virtual interface) is a software interface layered on a phy —
  `wlan0`, `ap0`, etc. One phy can host **multiple** netdevs, and each can be in a
  **different 802.11 mode**.

So "one radio" does *not* mean "one interface". The chip can present several vifs; they just
all share the one physical radio underneath (and therefore its constraints — see (c)).

```
        phy0  (MT7663 radio, mt7615e driver)
        │
        ├── wlan0   type managed  (station / client → aayush_5G)
        └── ap0     type AP       (our hotspot)
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
real vendor an address with this bit set. So if we take the station's real MAC and **XOR
byte 0 with `0x02`**, we flip that bit and get an address that:

- differs from the station's (no collision), and
- can **never** clash with any real hardware on the network.

Station `9c:2f:9d:8b:2c:1d` → AP `9e:2f:9d:8b:2c:1d`
(`0x9c ^ 0x02 = 0x9e`; the rest is untouched).

**Deterministic derivation beats random.** Because we always derive the same AP MAC from the
same station MAC, clients see a **stable BSSID** across restarts — they reconnect cleanly
instead of treating each restart as a brand-new network.

### (f) `ipv4.method=shared` — what NM actually does for a hotspot

The `Hotspot` NM profile uses `ipv4.method=shared`, which makes NetworkManager:

- assign `10.42.0.1/24` to the AP interface,
- spawn a **dnsmasq** instance for **DHCP + DNS** (this is why clients get `10.42.0.x`),
- install **NAT masquerade** so client traffic is routed out via the default route.

The masquerade is the piece that needs a working uplink. With NM's built-in hotspot the
uplink is gone, so the masquerade has nowhere to go → IP but no internet. With our script the
uplink (`wlan0`) is still up, so masquerade works.

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
  - If **not** root, the `||` fires and we **`exec sudo`** — replacing the current process
    image (no child, no return) with the same script under sudo.
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

```bash
[ "$1" = up ] && shift
[ "$1" = --name ] && shift
[ -n "$1" ] && SSID=$1
```

Permissive parsing so all these forms work:

- **optional leading `up`** — if `$1` is `up`, `shift` drops it. (Bare invocation with no `up`
  also works because this line just no-ops.)
- **optional `--name`** — if the (now-first) arg is `--name`, `shift` drops it, leaving the
  SSID as the next positional.
- **positional SSID** — if anything is left in `$1`, use it as the SSID; otherwise keep the
  default `Hotspot-Incog`.

This is why `up`, `up "MyNet"`, `up --name "MyNet"`, `"MyNet"`, and `--name "MyNet"` all land
on the right SSID (see §6).

### Reading the station's channel and frequency

```bash
CH=$(iw dev wlan0 info | awk '/channel/ {print $2}')
FREQ=$(iw dev wlan0 link | awk '/freq:/ {print $2}')
```

- **`CH`** from `iw dev wlan0 info` — the current channel number (e.g. `36`). If `wlan0` is
  **not** associated, this line comes back **empty**, which is how we detect the disconnected
  case below.
- **`FREQ`** from `iw dev wlan0 link` — the operating frequency in MHz. `iw link` reports it
  with a **decimal**, e.g. `5180.0`.

### Connected branch — band selection and the `%%.*` gotcha

```bash
if [ -n "$CH" ]; then
    [ "${FREQ%%.*}" -ge 5000 ] && BAND=a || BAND=bg
    ...
```

- **`-n "$CH"`** — non-empty channel ⇒ station is associated ⇒ we must match its channel.
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

- **`BASE`** — the station's real MAC read straight from sysfs, e.g. `9c:2f:9d:8b:2c:1d`.
- **`${BASE%%:*}`** — strip the longest trailing `:*`, leaving just the **first octet**: `9c`.
- **`0x${BASE%%:*}`** → `0x9c`, so bash treats it as **hex** in arithmetic.
- **`$(( 0x9c ^ 2 ))`** — arithmetic **XOR** with `2` (`0x02`, the U/L bit). `0x9c ^ 0x02`
  = `0x9e` = decimal `158`.
- **`${BASE#??}`** — strip the **shortest** leading two chars (`??` = the two hex digits of
  octet 0), leaving `:2f:9d:8b:2c:1d`. (It keeps the leading colon.)
- **`printf '%02x%s'`** — format the XORed octet as **two lowercase hex digits** (`9e`), then
  append the rest verbatim → `9e:2f:9d:8b:2c:1d`.

So `9c:2f:9d:8b:2c:1d` → `9e:2f:9d:8b:2c:1d`, a stable, locally-administered, collision-free
BSSID (see §2d/§2e).

### Creating the AP vif

```bash
iw dev "$AP" del 2>/dev/null || true
iw dev "$STATION" interface add "$AP" type __ap addr "$MAC"
```

- First line: delete any **stale `ap0`** from a previous run (cleanup-hygiene idiom again).
- **`iw dev wlan0 interface add ap0 type __ap addr <MAC>`** — ask the *station's phy* to
  create a **new vif** named `ap0` in **AP mode**, with our derived MAC.
  - **`type __ap`** — `iw`'s literal token for access-point mode. The double underscore is
    just `iw`'s naming (`__ap`, `__managed`, …) for the raw nl80211 interface types; it means
    "AP". Adding it on the *station's* phy is what makes the two vifs share the one radio.

### Binding and activating the NM profile

```bash
nmcli con mod "$PROFILE" \
    connection.interface-name "$AP" \
    802-11-wireless.ssid "$SSID" \
    802-11-wireless.band "$BAND" \
    802-11-wireless.channel "$CH"
nmcli con up "$PROFILE"
```

- **`nmcli con mod Hotspot ...`** — rewire the existing `Hotspot` profile:
  - `connection.interface-name ap0` — **bind it to `ap0` by name** (not `wlan0`!). This is the
    key line that keeps NM off the station interface.
  - `ssid`, `band`, `channel` — set the broadcast name and **pin the AP to the station's
    channel/band** computed above.
- **`nmcli con up Hotspot`** — activate. NM applies `ipv4.method=shared`: assigns
  `10.42.0.1/24`, spawns dnsmasq, installs NAT (see §2f).

### Verification

```bash
echo "--- result: expect $STATION=managed and $AP=AP on channel $CH ---"
iw dev | grep -E 'Interface|ssid|type|channel'
```

Dump all vifs and filter to the interesting lines. Success = **two** `Interface` blocks,
`wlan0` still `type managed`, `ap0` `type AP`, **both on the same channel** (see §8).

---

## 6. Usage examples

All of these elevate to root automatically via the self-re-exec.

| Command | Effect |
|---|---|
| `hotspotConcurrent.sh` | up, default SSID `Hotspot-Incog` |
| `hotspotConcurrent.sh up` | up, default SSID |
| `hotspotConcurrent.sh up "MyNet"` | up, SSID `MyNet` |
| `hotspotConcurrent.sh up --name "MyNet"` | up, SSID `MyNet` (explicit flag) |
| `hotspotConcurrent.sh "MyNet"` | up, SSID `MyNet` (bare positional) |
| `hotspotConcurrent.sh --name "MyNet"` | up, SSID `MyNet` (flag, no `up`) |
| `hotspotConcurrent.sh down` | tear down `ap0` + profile, leave `wlan0` alone |

---

## 7. Known limitations / caveats

- **Channel is read once, at activation.** If the **router changes channel** while the hotspot
  is up, `wlan0` follows it but `ap0` stays put — the AP effectively goes **deaf** (now on a
  different channel than the radio's tuner). Fix: **re-run** the script.
- **`ap0` is not persistent.** It vanishes on **reboot** or an **`mt7615e` module reload**. Re-run
  after either.
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
    channel 36 (5180 MHz) ...        ← still on the home SSID (aayush_5G)
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
