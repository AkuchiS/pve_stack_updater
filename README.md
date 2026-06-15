# ProxSweep

Automated update script for Proxmox VE homelab stacks. Runs on the Proxmox host and handles every container type in one pass — no per-container configuration required.

## What it does

| Target | Method | Details |
|--------|--------|---------|
| Proxmox host | `apt` | Debian security patches only — PVE/kernel packages intentionally skipped |
| LXC (Debian/Ubuntu) | `apt-get update && upgrade` | Standard apt upgrade, non-interactive |
| LXC (opkg-based) | `opkg update && upgrade` | Auto-detected — covers OpenWRT, Entware, and any embedded Linux using opkg |
| LXC (Docker) | `docker pull` + Watchtower | Pulls all named registry images, then runs Watchtower `--run-once` to restart updated containers |

PVE and kernel packages are deliberately excluded from the host update — these carry a higher risk of breaking running containers and should be applied manually with a planned reboot.

## Requirements

- Proxmox VE 7+ host
- Run as `root` on the Proxmox host (not inside a container)
- Internet access from the host and containers

## Installation

```bash
curl -o /usr/local/bin/proxsweep.sh \
  https://raw.githubusercontent.com/YOUR_USERNAME/proxsweep/main/proxsweep.sh

chmod +x /usr/local/bin/proxsweep.sh
```

## Usage

Run manually:
```bash
/usr/local/bin/proxsweep.sh
```

Or add a cron job to run nightly at 3am:
```bash
echo '0 3 * * * root /usr/local/bin/proxsweep.sh >> /var/log/proxsweep/cron.log 2>&1' \
  > /etc/cron.d/pve-stack-updater
```

## Skipping containers

### Preferred — Proxmox GUI tag (no script editing required)

In the Proxmox web UI: select the container → **Options** → **Tags** → add `no-auto-update`.

The script reads this tag automatically and skips the container with a clear log message. This survives script updates from GitHub.

### Fallback — SKIP_IDS list

Edit the `SKIP_IDS` variable near the top of the script:

```bash
SKIP_IDS="100 200 300"   # Space-separated VMIDs
```

Useful for headless or scripted setups where the GUI isn't convenient.

Stopped containers are automatically skipped regardless of either setting.

## Logs

Logs are written to `/var/log/proxsweep/YYYY-MM-DD.log` and rotated automatically after 30 days.

```
[2026-04-08 13:18:55] ============================================================
[2026-04-08 13:18:55]   Proxmox Stack Updater
[2026-04-08 13:18:55]   Host   : grayskull
[2026-04-08 13:18:55] ============================================================
[2026-04-08 13:18:56] [ OK] HOST — No security patches pending
[2026-04-08 13:18:57] ===  [100] plex
[2026-04-08 13:19:01] [ OK] [100] plex — Already up to date
[2026-04-08 13:19:01] ===  [101] openwrt
[2026-04-08 13:19:25] [ OK] [101] openwrt — opkg update successful
[2026-04-08 13:19:25] [ OK] [101] openwrt — Already up to date (opkg)
...
[2026-04-08 13:21:18] [ OK]   RESULT: 3 updated | 1 skipped | 0 errors
```

## Notes

### Watchtower stack trace
On some Docker containers, Watchtower prints a Go stack trace when exiting after `--run-once`. This is a cosmetic issue in Watchtower's exit handling and does not indicate a failure — the `[ OK]` line confirms a clean result.

### Docker image filtering
The script only pulls images with a registry prefix (e.g. `ghcr.io/...`, `docker.io/...`). Locally-built images (no `/` in the name) are automatically skipped to avoid pull errors.

### opkg-based containers (OpenWRT, Entware, embedded Linux)
The script detects any container running `opkg` — not just OpenWRT. This covers Entware on NAS devices (QNAP, Synology), and other embedded Linux distributions packaged as LXC containers.

A single `pct exec` call is used per operation to work around tmpfs `/tmp` not persisting between separate exec sessions, which is common in these environments.

> **Note:** OpenWRT 22.03 is end-of-life. Package feed availability may vary. Major version upgrades (e.g. to 23.05) require full container replacement and are out of scope for this script.

### Reboot notification
If a host package update requires a reboot, the script flags it clearly in the log and summary. It does **not** reboot automatically — this is intentional to avoid unexpected container downtime.

## Contributing

PRs welcome. If you run a container type not covered (e.g. Alpine apk, Fedora dnf), detection follows the same `command -v <package-manager>` pattern used for opkg and apt.

## License

MIT
