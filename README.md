# dns

Zone-agnostic authoritative DNS infrastructure: NSD zone files and deploy
tooling. One server per nameserver; each host runs NSD bound to its own
public IP (never the wildcard — that collides with `systemd-resolved`'s
loopback stub on modern Debian/Ubuntu).

## Recursive resolver (Unbound)

`deploy/install-unbound.sh <relay-ip>` installs Unbound as a **recursive**
resolver alongside NSD (authoritative). Port layout on the host:

- `53` — NSD (authoritative zones)
- `127.0.0.1:53` and `<public-ip>:5353` — Unbound (recursion)

Recursion is restricted twice, by design:

1. **Unbound ACL** — only loopback, the host's own public IP (the VLESS
   hairpin path used by sing-box's `socks-out` detour) and `<relay-ip>` are
   allowed; everyone else gets REFUSED.
2. **iptables** — `<public-ip>:5353` accepts only sources `<public-ip>` and
   `<relay-ip>`; all other SYNs are dropped (`iptables -L INPUT | grep 5353`).

Point the VPN tunnel at it (bc-vpn):

```bash
sudo pkill -f bc-singbox ; sleep 2
BC_PROXY_DNS='tcp://<turkey-ip>:5353' bc-vpn connect
```

Verify from each vantage:

```bash
# hairpin (server itself — same path the tunnel uses)
dig @<public-ip> -p 5353 example.org SOA +short
# relay (allowlisted)
ssh root@<relay-ip> dig @<public-ip> -p 5353 example.org SOA +short
# stranger (must NOT answer; SYNs land in the iptables DROP counter)
curl -m 6 http://<public-ip>:5353/
```

Note: a probe from a sing-box TUN client is NOT a stranger test — the
`{ protocol: dns, action: hijack-dns }` route rule intercepts DNS traffic on
any port before it leaves the machine. Use a non-DNS probe (curl) or an
independent host for negative tests.

## Layout

- `zones/` — zone files, one file per zone, named `<zone>.zone`
- `deploy/install-nsd.sh` — installs/configures NSD on a host for one zone
- `deploy/deploy.ps1` — pushes a zone to the nameservers and verifies parity

## Usage

Deploy a zone to the default nameserver set:

```powershell
.\deploy\deploy.ps1 -Zone example.com -ZoneFile .\zones\example.com.zone
```

Different nameservers (label = IP pairs; order = deployment order):

```powershell
.\deploy\deploy.ps1 -Zone example.com -ZoneFile .\zones\example.com.zone `
  -Servers ([ordered]@{ 'ns1' = '192.0.2.53'; 'ns2' = '192.0.2.154' })
```

What the deploy does per server:

1. base64-transports the zone file over SSH (no CRLF mangling)
2. runs `install-nsd.sh <zone>`: apt-installs NSD, writes `/etc/nsd/nsd.conf`
   (binds the host's first public IP only), installs the zone, enables and
   restarts the service, opens 53/udp+tcp in ufw if active
3. verifies `nsd-checkconf` + `nsd-checkzone` pass

After both servers report OK, a parity check queries each nameserver
directly for the apex/`www` records and compares answers.

## Zone conventions

- SOA serial: `YYYYMMDDnn`, bump on every edit
- in-zone nameservers (`ns1`/`ns2` under the zone itself) need glue A
  records; the registrar side also needs glue when delegating
- zone files are LF-terminated (enforced via `.gitattributes`)
- `install-nsd.sh` is idempotent — safe to re-run on every deploy

## Registrar note

Delegating a zone to nameservers inside the zone itself requires glue
records at the registrar (label + IP for each NS). Until the registrar
switches delegation, the old nameservers keep serving the old zone and
nothing breaks.
