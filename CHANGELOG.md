# Changelog

Notable changes to this project. Newest first.

## [1.0.0] - 2026-06-28
- One command updates a whole Proxmox homelab: the host, every LXC, and Docker, in a single pass.
- Detects each container's package manager (apt/opkg and the `command -v` pattern) and reports reboot-required clearly — it never reboots automatically.
