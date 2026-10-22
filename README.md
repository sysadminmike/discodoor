# discodoor

**Open a port on your server only to the machines you name, wherever they
are.** Your firewall lets a machine in by its Syncthing device ID instead of
a fixed IP address, so a laptop, a home worker or a remote site gets
through, while the rest of the internet finds the port closed. No VPN, no
port knocking, no relay in the middle.

Every Syncthing device already tells Syncthing's public discovery servers
where it is, and anyone with its device ID can look that up. discodoor turns
that into a firewall allowlist: a cron job on the server (Box B) looks up a
client's (Box A's) current public IP and loads it into pf (FreeBSD, OpenBSD)
or nftables (Linux). When Box A's IP changes, the allowlist follows.

It isn't limited to ssh. The allowlist is just a list of IPs, and your
firewall rule decides which port it opens, so the same setup can let staff
working from home reach an internal HTTPS server. All they have to do is
install Syncthing (it runs on Windows, macOS and Linux) and email the
network admin their device ID. The admin adds the ID to the cron job.
There's no VPN client to set up, and no account to create.

```
   +-----------------------------+
   | Syncthing discovery servers |
   +-----------------------------+
      ^                     |
      | 1. announce         | 2. look up Box A:
      |                     |    "it's at 81.2.3.4"
      |                     v
   +-------+  3. ssh   +---------------------------+
   | Box A | --------> | Box B                     |
   +-------+           | firewall allows 81.2.3.4  |
                       +---------------------------+
```

- **Box A already runs Syncthing?** It needs nothing new. Box B needs one shell script.
- **It doesn't?** `discodoor-announce.py` does the announcing with just Python and openssl.

At a glance:

```sh
# Box A: announce itself (skip if Syncthing runs there); prints its device ID
discodoor-announce.py -c /usr/local/etc/discodoor

# Box B: let Box A's current IP reach sshd (run from cron every 30 minutes for example)
discodoor-allow.sh A-DEVICE-ID
```

Full instructions are under [Setup](#setup).

## What you can do with it

**Keep a tunnel up.** Once Box A is allowed in on Box B, `autossh` can keep
a constant tunnel open between them, reconnecting automatically if it drops:

```sh
autossh -M 0 -N -o ServerAliveInterval=30 \
  -L 5666:127.0.0.1:5666 \
  -R 2222:127.0.0.1:22 \
  tunnel@B
```

- `-L` (local forward) makes a service on Box B's side reachable on Box A,
  here Box B's port 5666 on Box A's `localhost:5666`.
- `-R` (reverse forward) makes a service on Box A's side reachable on Box B,
  here `ssh -p 2222 localhost` on Box B reaches Box A. Box A doesn't need
  any open ports for this.

**Open more than ssh.** The script only fills the table or set; the
firewall rule decides the port. To let the same IPs reach a web server on
port 443, add a rule next to the ssh one:

```
pass in on $ext_if proto tcp from <ssh_ok> to port 443 keep state   # pf
tcp dport 443 ip saddr @ssh_ok accept                               # nftables
```

Use `-t` if you want a table name that fits better than `ssh_ok`, such as `web_ok`.

**Follow a laptop.** If a laptop runs Syncthing, the allowlist follows it to
whatever network it's on.

**Server behind NAT, too.** Box B doesn't need a public IP address. If it
sits behind a NAT router with an IP that changes, port-forward the service
on that router as usual and have Box B announce itself too (with Syncthing
or `discodoor-announce.py`). Box A then finds Box B by looking up Box B's
device ID, which replaces dynamic DNS:

```sh
curl -s 'https://discovery-lookup.syncthing.net/v2/?device=B-DEVICE-ID'
```

## How it compares

- **Port knocking** keeps sshd hidden until a client sends a secret packet
  sequence, but the knock ports have to be forwarded and reachable from
  anywhere, since the server doesn't know where the knock will come from.
  Here the "knock" is Box A's signed announcement to Syncthing's discovery
  servers, not a packet to Box B. Box B exposes only ssh, and that stays
  closed to everyone except Box A's current IP.
- **Dynamic DNS** (e.g. DuckDNS) gives a machine a hostname that tracks its
  IP, but someone has to sign up, create the entry and keep an updater
  running on that machine. On Linux or macOS that's a cron job and a `curl`
  command; on Windows it means finding and installing a third-party
  updater, which is a lot to ask of someone who isn't technical. With
  discodoor they install Syncthing and email their device ID to whoever runs
  Box B, and Syncthing keeps announcing on its own.

## How it works

Opening a port on Box B's firewall to one address is easy. The trouble is
that Box A doesn't have a fixed address. Its public IP is its router's,
which changes whenever the ISP feels like it, and Box A can't see it from
the inside. A laptop gets a new one every time it moves.

Syncthing already solves "find a device by ID" for millions of users. Each
Syncthing device announces itself to the public discovery servers using a
TLS client certificate; its device ID is just a hash of that
certificate. When a device announces `tcp://0.0.0.0:22000`, the server
replaces `0.0.0.0` with the source IP it saw, which is the device's NAT
router's public IP. Anyone who knows the device ID can then look that up, e.g.:

```sh
curl -s 'https://discovery-lookup.syncthing.net/v2/?device=DEVICE-ID'
```

This returns JSON such as
`{"addresses":["tcp://81.2.3.4:22000","quic://81.2.3.4:22000"], ...}`, and
the IP is in the `tcp://` / `quic://` entries (ignore `relay://`). A 404 means
the device hasn't announced recently. If TLS verification fails, add `-k`.

There are two ways for Box A to announce itself:

- **Box A already runs Syncthing:** nothing to install. Syncthing announces
  Box A every 30 minutes by default. Just get Box A's device ID from Syncthing
  (see [Alternative: just run Syncthing](#alternative-just-run-syncthing))
  and go straight to setting up Box B.
- **Box A doesn't run Syncthing:** use `discodoor-announce.py`. It's only for announcing
  to the Syncthing discovery servers *without* a Syncthing client, using
  nothing but Python and openssl:

1. Generate a cert + key (once). This is the machine's identity.
2. Derive the Syncthing device ID from the cert.
3. POST an announcement to the discovery announce server.
4. Print the lookup URL for that device ID.

Announcements are signed by the client certificate, so nobody can announce
your device ID without your key.

Syncthing is only the signal ("this is where Box A is right now"). The ssh
traffic goes directly from Box A to Box B, not through Syncthing.

## Setup

Box A announces itself; Box B looks it up and opens its firewall. Box A's
side is the same on every system. Box B's side depends on the firewall, so
it has a section for each:

- [Box A: announce itself](#box-a-announce-itself)
- [Box B on FreeBSD/OpenBSD (pf)](#box-b-on-freebsdopenbsd-pf)
- [Box B on Linux (nftables)](#box-b-on-linux-nftables)

### Box A: announce itself

**If Box A runs Syncthing, skip this section.** Syncthing is already
announcing Box A. Take its device ID from the GUI (Actions → Show ID) and
use that on Box B. Don't also run `discodoor-announce.py` there: it would create a
second, different identity.

If Box A doesn't run Syncthing, set up `discodoor-announce.py`. It needs Python 3 and
openssl (`pkg install python3` on FreeBSD; already there on most Linux
systems):

```sh
mkdir -p /usr/local/etc/discodoor
./discodoor-announce.py -c /usr/local/etc/discodoor -d --check
```

Note the device ID it prints. Keep `key.pem` private: it *is* Box A's identity.

Re-announce regularly (the server asks for roughly every 45 minutes):

```
*/45 * * * * /usr/local/bin/discodoor-announce.py -c /usr/local/etc/discodoor
```

Options: `-c DIR` for the cert directory (default: current directory),
`--cert`/`--key` to name each file, `-k` to skip TLS verification, `-d` for
debug output, `--id-only` to just print the ID. Existing certs are always
reused; only `--force-new` makes a new identity.

### Box B on FreeBSD/OpenBSD (pf)

Run these as root.

#### 1. Router (only if Box B is behind NAT)

If Box B sits behind a NAT router, port-forward ssh on that router to Box B.
If Box B has a public IP address, skip this step.

#### 2. pf

pf needs a table for the script to fill, and a rule that lets the IPs in it
reach sshd. These are the two lines that matter:

```
table <ssh_ok> persist
pass in on $ext_if proto tcp from <ssh_ok> to port 22 keep state
```

A pf table holds both IPv4 and IPv6 addresses. Established connections
survive table changes because pf keeps state, so a long rsync won't be cut
off when Box A's IP drops out.

**Full example `/etc/pf.conf`.** This blocks everything coming in except
ssh from the LAN and from allowed IPs. Set `ext_if` to the machine's
network interface (`ifconfig -l` lists them) and `lan` to its local
network, and add rules for anything else it serves:

```
ext_if = "vtnet0"
lan    = "192.168.0.0/24"

# Filled by discodoor-allow.sh.
table <ssh_ok> persist

set skip on lo0

block in all
pass out all keep state

# IPv6 needs ICMPv6 (neighbour discovery); ping is handy on IPv4.
pass in inet6 proto icmp6
pass in inet proto icmp icmp-type echoreq

# ssh: always from the LAN, from outside only for allowed IPs.
pass in on $ext_if proto tcp from $lan to port 22 keep state
pass in on $ext_if proto tcp from <ssh_ok> to port 22 keep state
```

Check it, then for FreeBSD turn pf on:

```sh
pfctl -nf /etc/pf.conf      # syntax check only, loads nothing
sysrc pf_enable=YES
service pf start
```

After editing the file later, load the changes with `pfctl -f /etc/pf.conf`.

The table starts empty, so nobody can reach sshd from outside until the
script fills it.

**Doing this over ssh?** A mistake in the rules can lock you out. Before
starting pf, set it to switch itself off again in two minutes:

```sh
daemon -f sh -c 'sleep 120; pfctl -d'
service pf start
```

#### 3. The allow script

Install it. It uses FreeBSD's built-in `fetch`, or `curl` if that's
installed; nothing else is needed:

```sh
install -m 755 discodoor-allow.sh /usr/local/sbin/
```

Try it by hand first. `-n` is a dry run, `-d` shows the lookups and responses:

```sh
discodoor-allow.sh -d -n A-DEVICE-ID
discodoor-allow.sh A-DEVICE-ID
pfctl -t ssh_ok -T show
```

Then run it every 30 minutes from root's crontab (`crontab -e`):

```
*/30 * * * * /usr/local/sbin/discodoor-allow.sh A-DEVICE-ID
```

#### 4. Logs

Changes and failed lookups go to syslog:

```sh
grep discodoor /var/log/messages
```

### Box B on Linux (nftables)

Run these as root, or with `sudo`. The commands are for Debian and Ubuntu;
other distributions differ mainly in package names.

#### 1. Router (only if Box B is behind NAT)

If Box B sits behind a NAT router, port-forward ssh on that router to Box B.
If Box B has a public IP address, skip this step.

#### 2. nftables

nftables needs a set for the script to fill, and a rule that lets the IPs in
it reach sshd. The script looks for the set in the `inet filter` table by default.

**Full example `/etc/nftables.conf`.** This replaces the stock Debian/Ubuntu
file. It blocks everything coming in except ssh from the LAN and from
allowed IPs. Set `LAN` to the machine's local network, and add rules for
anything else it serves:

```
#!/usr/sbin/nft -f

flush ruleset

define LAN = 192.168.0.0/24

table inet filter {
	# Filled by discodoor-allow.sh. IPv4 only for now.
	set ssh_ok {
		type ipv4_addr
	}

	chain input {
		type filter hook input priority filter; policy drop;

		iif lo accept
		ct state established,related accept
		ct state invalid drop
		meta l4proto { icmp, ipv6-icmp } accept

		# ssh: always from the LAN, from outside only for allowed IPs.
		tcp dport 22 ip saddr $LAN accept
		tcp dport 22 ip saddr @ssh_ok accept
	}
}
```

The lines that matter for the allowlist are the `ssh_ok` set and the
`ip saddr @ssh_ok` rule. The `ct state established,related` rule plays the
part of pf's `keep state`: established connections survive when an IP
drops out of the set.

`flush ruleset` wipes **every** rule on the machine, including ones made by
Docker or LXD. On a machine that uses them, replace that line with these
two, which reset only this table:

```
table inet filter
delete table inet filter
```

Don't run ufw or firewalld alongside this; disable them first
(`ufw disable`).

Check it, then turn nftables on:

```sh
nft -c -f /etc/nftables.conf      # syntax check only, loads nothing
systemctl enable --now nftables
```

The set starts empty, so nobody can reach sshd from outside until the
script fills it. Reloading the rules (`systemctl reload nftables`) empties
it again; run the script once afterwards, or wait for the next cron run.

**Doing this over ssh?** A mistake in the rules can lock you out. Before
starting nftables, set it to clear the rules again in two minutes:

```sh
systemd-run --unit=fw-undo --on-active=120 /usr/sbin/nft flush ruleset
systemctl enable --now nftables
```

A few things differ from pf:

- **IPv4 only for now.** The set is `ipv4_addr`, and the script skips any
  IPv6 addresses it finds.
- **Create the set first.** The script doesn't create the set, and exits 2
  if it can't find it.
- **Set location.** If your set isn't in `inet filter`, pass
  `-t FAMILY:TABLE:SET`, e.g. `-t ip:fw:ssh_ok`.

#### 3. The allow script

Install it. It needs `curl` (`apt install curl` if it's missing):

```sh
install -m 755 discodoor-allow.sh /usr/local/sbin/
```

Try it by hand first. `-n` is a dry run, `-d` shows the lookups and responses:

```sh
discodoor-allow.sh -d -n A-DEVICE-ID
discodoor-allow.sh A-DEVICE-ID
nft list set inet filter ssh_ok
```

Then run it every 30 minutes from root's crontab (`sudo crontab -e`):

```
*/30 * * * * /usr/local/sbin/discodoor-allow.sh A-DEVICE-ID
```

#### 4. Logs

Changes and failed lookups go to the journal:

```sh
journalctl -t discodoor        # add -f to follow
```

### discodoor-allow.sh reference

The script works out the firewall itself: pf if `pfctl` is installed,
otherwise nft. `-b` overrides that.

| Option | Meaning |
|---|---|
| `-b pf\|nft` | firewall to update (default: pf if `pfctl` is found, else nft) |
| `-t TABLE` | pf: table name (default `ssh_ok`); nft: `FAMILY:TABLE:SET`, or just `SET` for `inet:filter:SET` (default `inet:filter:ssh_ok`) |
| `-u URL` | lookup server (default `https://discovery-lookup.syncthing.net/v2/`) |
| `-d` | debug output |
| `-n` | dry run: show what would change, don't touch the firewall |
| `-k` | don't verify the lookup server's TLS certificate |

To allow several machines, list all their device IDs in one run. The table
then holds every IP found:

```sh
discodoor-allow.sh A-DEVICE-ID C-DEVICE-ID D-DEVICE-ID
```

How it updates the table or set:

- **Every lookup succeeds:** the table is replaced with exactly the IPs
  found, so an old IP drops out when a peer's address changes.
- **Some lookups fail:** IPs found are only added and nothing is removed,
  so a failed lookup can't lock a peer out.
- **Nothing found:** the table is left alone and the script exits 1.
- **Filtered out:** relay addresses, private and CGNAT ranges, loopback and
  link-local addresses (and, on nftables, IPv6).

Log entries are tagged `discodoor`. Entries from a dry run (`-n`) start with `dry run:`.

For two-way access, do both halves on both machines.

## Alternative: just run Syncthing

You don't need `discodoor-announce.py` at all if you're happy to run Syncthing itself
on Box A. Global discovery is on by default, so a running Syncthing announces
Box A's address every 30 minutes on its own.

On Box A (FreeBSD):

```sh
pkg install syncthing
sysrc syncthing_enable=YES
service syncthing start
```

On Box A (Debian/Ubuntu), running as user `USER`:

```sh
apt install syncthing
systemctl enable --now syncthing@USER
```

Get Box A's device ID from the web GUI (Actions → Show ID), or from the REST API:

```sh
curl -s -H "X-API-Key: $KEY" http://127.0.0.1:8384/rest/system/status | jq -r .myID
```

The API key is under Actions → Settings in the GUI, or in `config.xml`.

Box B's side is unchanged: the same pf table or nft set and the same cron
lookup script, using Box A's Syncthing device ID. The two machines don't
need to be paired or share any folders.

**Which to pick**

| | discodoor-announce.py | Syncthing |
|---|---|---|
| Footprint | one script, run from cron | a daemon running all the time |
| If the discovery protocol changes | script may break | an update fixes it |
| Extras | none | file sync, relays, local discovery |

If Box A runs Syncthing anyway, use that. Use `discodoor-announce.py` when you want the
lookup trick on a box where a full Syncthing install isn't wanted.

## Things to know

- **It's the router's IP.** That's what Box B's firewall sees as the source,
  so it's exactly what you want. If Box A is behind CGNAT, the IP is shared
  with other customers of the same ISP, so they get through the allowlist
  too.
- **Lag.** After Box A's IP changes, Box B learns about it at the next
  announce plus the next cron run. Allow up to about an hour in the worst case.
- **It's an allowlist, not authentication.** The discovery operator could
  map an ID to any IP.
- **TLS.** The announce and lookup hosts use Let's Encrypt certs. If
  verification fails, fix the CA bundle (`ca-certificates` on Ubuntu,
  `ca_root_nss` on FreeBSD) rather than using `-k` long term.
- **Be polite.** These are free servers run by the Syncthing Foundation,
  with no written terms and no promises. One announce every ~45 minutes and
  a few lookups every hour is negligible; don't hammer them, and respect
  `Retry-After`.


## Security & Operational Considerations for Production/Multi-User Deployments

While `discodoor` provides simple experience for non-technical users (especially on Windows), administrators should be aware of two inherent issues.

### 1. The Shared Public IP Risk (CGNAT / Public Wi-Fi)
`discodoor` creates firewall rules based strictly on the public source IP reported by the discovery server. When a client connects from a shared network—such as a coffee shop, hotel, airport, or an ISP using Carrier-Grade NAT (CGNAT)—they share a single public gateway IP with hundreds of other users. 
* **Impact:** Your firewall opens the configured port to *the entire public IP*, meaning anyone else on that same local Wi-Fi or cellular tower can theoretically route traffic to your opened port.
* **Mitigation:** Never rely on the `discodoor` allowlist as your sole layer of defense. The underlying service (e.g., an HTTPS web server or SSH) must be fully hardened with robust authentication (MFA, strong passwords, or cryptographic keys) and transport encryption.

### 2. Connection Lag & OS Power Management
Because the allowlist relies on a decoupled "announce-then-lookup" loop driven by a server-side cron job, there is an inherent delay when a client changes locations. On Windows laptops, aggressive OS power management may delay the Syncthing daemon from waking up and announcing its new IP immediately upon lid-open.
* **Impact:** A user opening their laptop at a new location may experience a "Site cannot be reached" or connection timeout error for a few minutes until the next announce/cron cycle completes.
* **Mitigation:** For tighter sync loops, consider hosting a private Syncthing Discovery Server ([`stdiscosrv`](https://docs.syncthing.net/users/stdiscosrv.html)). Running your own discovery infrastructure allows you to safely increase the announce frequency and lower the server-side cron job interval to every 1–2 minutes without hammering public community resources.

## License

MIT. See [LICENSE](LICENSE).

discodoor isn't affiliated with or endorsed by the Syncthing Foundation. It
only uses the public discovery servers that Syncthing itself uses.
