# OC Intance Reservation

Autonomous script that keeps trying to launch an Oracle Cloud instance until capacity appears
(typical use: the Always Free Ampere A1 shape, which is usually `Out of host capacity`).
Generic: regions, shapes, cadence and ntfy topic are all configuration.

## Configuration
See `config.example.env`. Key settings:

| Variable | Meaning |
|---|---|
| `REGIONS` | comma-separated, tried in order |
| `SHAPES` | `shape:ocpus:memGB`, comma-separated, tried in order |
| `INTERVAL_MINUTES` | cadence of the systemd timer |
| `NTFY_TOPIC` | optional push notifications (ntfy topics are public — use a hard-to-guess name) |
| `ENFORCE_FREE_TIER` | default `true`: skips non-home regions, non-free shapes, >2 OCPU/12 GB A1 and >200 GB boot |

## Free-tier facts (Oracle docs, Always Free)
- A1: **2 OCPU / 12 GB total** per tenancy; Always Free compute must be created in the **home region**.
- Block storage: 200 GB total.

## Requirements
`oci` CLI, `jq`, `curl`, systemd. Provide an OCI CLI config file + API key and an OpenSSH public key.

## Use
```sh
oc-reserve.sh --config config.env --dry-run   # everything except the launch
sudo ./install.sh config.env                  # installs script + timer
oc-reserve --status
```
Notifications (only these three): first start, a daily summary at 08:00 America/Los_Angeles with the number of tries (until success), and success. Errors go to the log only (`/var/lib/oc-reserve/run.log`).

Behaviour: each run checks for an existing instance of that name (idempotent), tries every
region/shape/AD, treats "out of capacity" as normal, backs off on HTTP 429, logs real faults, and on success notifies, records state, and disables its own timer.
