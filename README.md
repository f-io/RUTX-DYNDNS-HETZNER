# Teltonika RUTX DYNDNS (Hetzner)

DynDNS for Teltonika RUTX (RutOS / OpenWrt) devices using the **new Hetzner
Cloud DNS API** (`api.hetzner.cloud`).

Designed for uplinks where the available address families change:
the script runs in **auto mode** and updates every family that is actually
usable - IPv4 only, IPv6 only, or both.

## Installation

1. Copy the content of [rc.local](rc.local) into **System → Custom Scripts**
   in the WebUI (`/etc/rc.local`).
2. Fill in the configuration block at the top:
   - `HETZNER_TOKEN` - Hetzner **Cloud** API token (project token with
     read & write permissions, created in the Hetzner Cloud Console)
   - `ZONE_NAME` - your zone, e.g. `example.com`
   - `RECORD_NAME` - the record, e.g. `router` (`@` for the zone apex)
3. Reboot.

To change the configuration later, edit `/root/dyndns.conf` on the device -
the block in `rc.local` is only used to seed it once.

## Manual usage

```sh
/root/dyndns.sh                          # auto: A and/or AAAA, whatever works
/root/dyndns.sh -T AAAA                  # force IPv6 only
/root/dyndns.sh -Z example.com -n router # auto for router.example.com
```

## Related

- [RUTX-SSL](https://github.com/f-io/RUTX-SSL) - Let's Encrypt certificates
  via acme.sh and the Hetzner Cloud DNS API
- [RUTX-GPS](https://github.com/f-io/RUTX-GPS) - GPS tracking to Nextcloud
  PhoneTrack
- [Combined rc.local example](examples/rc.local.combined)
  (DynDNS + SSL + GPS)

## Tested devices

| Device | Firmware |
|-|-|
| RUTX11 | RUTX_R_00.07.24.1 |
| RUTX50 | RUTX_R_00.07.06.3 |

