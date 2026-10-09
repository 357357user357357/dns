# dns

Zone-agnostic authoritative DNS infrastructure: NSD zone files and deploy
tooling. One server per nameserver; each host runs NSD bound to its own
public IP (never the wildcard — that collides with `systemd-resolved`'s
loopback stub on modern Debian/Ubuntu).

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
