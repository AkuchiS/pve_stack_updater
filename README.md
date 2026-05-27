# Proxmox Stack Maintainer

Safe automated maintenance for Proxmox VE homelab stacks.

`proxmox-stack-maintainer` runs on the Proxmox host and handles the stack in one pass: the host, LXCs, opkg-based containers, and Docker workloads running inside LXCs. It is intentionally conservative: Proxmox VE and kernel packages are skipped so they can be reviewed manually with a planned reboot.

## What it does

| Target | Method | Details |
|--------|--------|---------|
| Proxmox host | `apt` | Debian security patches only — PVE/kernel packages intentionally skipped |
| LXC (Debian/Ubuntu) | `apt-get update && upgrade` | Standard apt upgrade, non-interactive |
| LXC (opkg-based) | `opkg update && upgrade` | Auto-detected — covers OpenWRT, Entware, and embedded Linux using opkg |
| LXC (Docker) | `docker pull` + Watchtower | Pulls named registry images, then runs Watchtower `--run-once` to restart updated containers |
| QEMU VMs | Inventory only | Detects and tracks VMs, but does not update inside guest OSes |

PVE and kernel packages are deliberately excluded from host updates. They carry a higher risk of breaking running workloads and should be applied manually with a planned reboot.

## Stack inventory detection

The maintainer keeps a persistent inventory at:

```bash
/var/lib/proxmox-stack-maintainer/inventory.tsv
```

On every run it compares the current Proxmox stack with the previous inventory and logs:

- new LXCs
- new VMs
- renamed LXCs/VMs
- status changes
- removed LXCs/VMs

New running LXCs are maintained automatically unless they are skipped by tag or ID. VMs are detected and logged as inventory-only because updating guest OSes safely requires guest-specific access such as SSH, cloud-init, or an agent.

## Requirements

- Proxmox VE 7+ host
- Run as `root` on the Proxmox host, not inside a container
- Internet access from the host and containers

## Installation

```bash
curl -o /usr/local/bin/proxmox-stack-maintainer.sh \
  https://raw.githubusercontent.com/AkuchiS/proxmox-stack-maintainer/main/proxmox-stack-maintainer.sh

chmod +x /usr/local/bin/proxmox-stack-maintainer.sh
```

If the repository has not yet been renamed, use the old repo path temporarily:

```bash
curl -o /usr/local/bin/proxmox-stack-maintainer.sh \
  https://raw.githubusercontent.com/AkuchiS/pve_stack_updater/main/proxmox-stack-maintainer.sh
```

## Usage

Run manually:

```bash
/usr/local/bin/proxmox-stack-maintainer.sh
```

Or add a cron job to run nightly at 3am:

```bash
echo '0 3 * * * root /usr/local/bin/proxmox-stack-maintainer.sh >> /var/log/proxmox-stack-maintainer/cron.log 2>&1' \
  > /etc/cron.d/proxmox-stack-maintainer
```

## Skipping containers

### Preferred — Proxmox GUI tag

In the Proxmox web UI: select the container → **Options** → **Tags** → add:

```text
no-auto-update
```

The maintainer reads this tag automatically and skips the container with a clear log message. This survives script updates from GitHub.

### Fallback — SKIP_IDS list

Edit the `SKIP_IDS` variable near the top of the script:

```bash
SKIP_IDS="100 200 300"   # Space-separated VMIDs
```

Stopped containers are automatically skipped regardless of either setting.

## Logs

Logs are written to:

```bash
/var/log/proxmox-stack-maintainer/YYYY-MM-DD.log
```

Logs older than 30 days are rotated automatically.

Example:

```text
[2026-04-08 13:18:55] ============================================================
[2026-04-08 13:18:55]   Proxmox Stack Maintainer
[2026-04-08 13:18:55]   Host   : grayskull
[2026-04-08 13:18:55] ============================================================
[2026-04-08 13:18:56] [ OK] HOST — No security patches pending
[2026-04-08 13:18:57] [---] NEW LXC detected: [100] plex (status: running)
[2026-04-08 13:19:01] [ OK] [100] plex — Already up to date
[2026-04-08 13:19:01] [---] NEW VM detected: [900] debian-template (status: stopped)
[2026-04-08 13:19:01] [---] [900] debian-template — VM detected, inventory only (guest updates are out of scope)
[2026-04-08 13:21:18] [ OK]   RESULT: 3 updated | 1 skipped | 0 errors
```

## Notes

### Watchtower stack trace

On some Docker containers, Watchtower prints a Go stack trace when exiting after `--run-once`. This is a cosmetic issue in Watchtower's exit handling and does not indicate a failure — the `[ OK]` line confirms a clean result.

### Docker image filtering

The script only pulls images with a registry prefix, for example `ghcr.io/...` or `docker.io/...`. Locally-built images with no `/` in the name are automatically skipped to avoid pull errors.

### opkg-based containers

The script detects any container running `opkg`, not just OpenWRT. This covers Entware on NAS devices such as QNAP and Synology, plus other embedded Linux distributions packaged as LXC containers.

A single `pct exec` call is used per operation to work around tmpfs `/tmp` not persisting between separate exec sessions, which is common in these environments.

> **Note:** OpenWRT 22.03 is end-of-life. Package feed availability may vary. Major version upgrades, such as to 23.05, require full container replacement and are out of scope for this script.

### Reboot notification

If a host package update requires a reboot, the script flags it clearly in the log and summary. It does **not** reboot automatically.

## Contributing

PRs welcome. If you run a container type not covered, such as Alpine `apk` or Fedora `dnf`, detection follows the same `command -v <package-manager>` pattern used for `opkg` and `apt`.

## License

MIT
