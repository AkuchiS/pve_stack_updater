# Proxmox Stack Maintainer

Safe, autonomous maintenance for Proxmox VE homelab stacks.

`proxmox-stack-maintainer` runs on the Proxmox host as a nightly systemd timer. Each run discovers the current Proxmox stack, maintains every running LXC it can safely identify, tracks QEMU/KVM VMs for coverage, runs service health checks, and records an inventory so new, renamed, stopped, and removed guests are visible without manually editing a list.

It is intentionally conservative: Proxmox VE and kernel packages are skipped so they can be reviewed manually with a planned reboot.

## What it does

| Target | Method | Details |
|--------|--------|---------|
| Proxmox host | `apt` | Debian security/userland packages only; PVE/kernel packages intentionally skipped |
| LXC: Debian/Ubuntu | `apt-get update && apt-get upgrade` | Auto-detected, non-interactive |
| LXC: opkg-based | `opkg update && opkg upgrade` | Auto-detected; covers OpenWRT, Entware, and embedded Linux containers |
| LXC: Docker host | `docker pull` + Watchtower | Pulls registry-backed images and runs Watchtower `--run-once` |
| QEMU/KVM VMs | Inventory + guest-agent coverage | Detects VMs and checks `qm guest ping`; guest OS updates are not attempted blindly |
| Services | HTTP health checks | Configurable post-run checks such as Prismarr, Sonarr, Radarr, etc. |

## Self-healing inventory

The maintainer does **not** depend on a static VMID list.

On every run it queries live Proxmox state with `pct list` and `qm list`, writes the current inventory to:

```bash
/var/lib/proxmox-stack-maintainer/inventory.tsv
```

and compares it with the previous run. It logs:

- new LXCs
- new VMs
- renamed guests
- status changes
- removed guests
- running VMs whose qemu guest agent is not responding

New running LXCs are automatically added to the maintenance pass unless skipped by tag or config. This is the “self-healing” behaviour: add a new LXC to Proxmox, and the next timer run discovers it and applies the matching update procedure based on the package manager/tools inside that container.

VMs are tracked and health-checked, but not updated inside the guest OS by default. That is intentional: safe VM maintenance needs guest-specific credentials, agents, cloud-init, or SSH policy. The inventory makes uncovered VMs visible instead of silently ignoring them.

## Requirements

- Proxmox VE 7+ host
- Run as `root` on the Proxmox host, not inside a container
- Internet access from the host and containers
- `systemd` for autonomous timer install
- Proxmox host tools available on the install target (`pct`, `/etc/pve`)

The installer refuses to run inside a guest LXC/VM. Install it on the Proxmox node itself so it can see and maintain the full stack.

## Install

Clone the repository on the Proxmox host, then run the installer:

```bash
git clone https://github.com/AkuchiS/proxmox-stack-maintainer.git
cd proxmox-stack-maintainer
sudo ./install.sh
```

If the GitHub repository has not yet been renamed, clone the current repository name into the new local folder name:

```bash
git clone https://github.com/AkuchiS/pve_stack_updater.git proxmox-stack-maintainer
cd proxmox-stack-maintainer
sudo ./install.sh
```

The installer creates:

```text
/usr/local/bin/proxmox-stack-maintainer.sh
/etc/proxmox-stack-maintainer/config.env
/etc/systemd/system/proxmox-stack-maintainer.service
/etc/systemd/system/proxmox-stack-maintainer.timer
/var/log/proxmox-stack-maintainer
/var/lib/proxmox-stack-maintainer
```

and enables the nightly timer.

## Verify install

```bash
proxmox-stack-maintainer.sh --check
systemctl status proxmox-stack-maintainer.timer
systemctl list-timers --all | grep proxmox-stack-maintainer
```

Run once manually:

```bash
sudo systemctl start proxmox-stack-maintainer.service
sudo journalctl -u proxmox-stack-maintainer.service -n 100 --no-pager
```

Run without applying upgrades:

```bash
sudo proxmox-stack-maintainer.sh --dry-run
```

## Configure

Edit:

```bash
sudo nano /etc/proxmox-stack-maintainer/config.env
```

Default config:

```bash
SKIP_IDS="600"
LOG_RETENTION_DAYS="30"
SERVICE_CHECKS=(
  "Prismarr=http://10.12.0.30:7070"
)
```

### Skipping containers

Preferred method: add the Proxmox tag `no-auto-update` to the container.

Fallback method: add the VMID to `SKIP_IDS` in `/etc/proxmox-stack-maintainer/config.env`.

Stopped containers are skipped automatically.

### Service health checks

Add checks to the `SERVICE_CHECKS` bash array:

```bash
SERVICE_CHECKS=(
  "Prismarr=http://10.12.0.30:7070"
  "Sonarr=http://10.12.0.30:8989"
  "Radarr=http://10.12.0.30:7878"
)
```

2xx/3xx HTTP status is treated as healthy. Anything else is logged as an error.

## Logs and state

Daily logs:

```bash
/var/log/proxmox-stack-maintainer/YYYY-MM-DD.log
```

Inventory:

```bash
/var/lib/proxmox-stack-maintainer/inventory.tsv
/var/lib/proxmox-stack-maintainer/inventory.previous.tsv
```

Systemd journal:

```bash
journalctl -u proxmox-stack-maintainer.service
```

Logs older than `LOG_RETENTION_DAYS` are removed automatically.

## Uninstall

```bash
sudo ./uninstall.sh
```

The uninstall script removes the systemd timer/service and binary, but preserves config, logs, and inventory state.

## Safety notes

- Proxmox/kernel packages are deliberately skipped.
- The maintainer does not reboot the host automatically.
- Running VMs are inventoried and guest-agent checked, not blindly updated.
- Package-manager detection is dynamic: LXCs are handled based on what exists inside the container (`docker`, `opkg`, `apt-get`).
- Docker image pulls only target registry-style image names and skip local-only images.

## Contributing

PRs welcome. Additional package managers can be added using the same detection pattern used for `opkg` and `apt-get`.

## License

MIT
