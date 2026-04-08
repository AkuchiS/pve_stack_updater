#!/bin/bash
# ============================================================
#  pve_stack_updater.sh — Proxmox Stack Updater
#  Run on the Proxmox HOST as root
#
#  Supports:
#    - Proxmox HOST (Debian security patches only,
#      excludes PVE/kernel packages to preserve stability)
#    - LXC containers (apt/Debian-based)
#    - Docker containers (via Watchtower)
#    - OpenWRT containers (via opkg)
#
#  Usage:    bash pve_stack_updater.sh
#  Logs:     /var/log/pve_stack_updater/YYYY-MM-DD.log
# ============================================================

LOG_DIR="/var/log/pve_stack_updater"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"
SKIP_IDS="600"   # Fallback: space-separated VMIDs to skip (e.g. "100 200 300")
                 # Preferred: tag a container "no-auto-update" in the Proxmox GUI instead

# Colours
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[0;36m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

flag()  { log "${RED}[!!!] $1${NC}"; }
ok()    { log "${GRN}[ OK] $1${NC}"; }
info()  { log "${YLW}[---] $1${NC}"; }
title() { log "${BLU}===  $1${NC}"; }
host()  { log "${CYN}[HST] $1${NC}"; }

# ── SANITY CHECK ─────────────────────────────────────────────
if ! command -v pct &>/dev/null; then
    echo "ERROR: pct not found. Run this on the Proxmox host as root."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root."
    exit 1
fi

# ── HEADER ───────────────────────────────────────────────────
echo "" | tee -a "$LOG_FILE"
log "============================================================"
log "  Proxmox Stack Updater"
log "  Host   : $(hostname)"
log "  Date   : $(date)"
log "============================================================"
echo "" | tee -a "$LOG_FILE"

TOTAL_UPDATED=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
DOCKER_CONTAINERS=()

# ── PROXMOX HOST SECURITY UPDATES ────────────────────────────
title "PROXMOX HOST — Security patches (Debian only)"

apt-get update -qq 2>&1 | tee -a "$LOG_FILE"

# Identify upgradable packages, excluding PVE, kernel and proxmox packages
HOST_PKGS=$(apt-get --simulate upgrade 2>/dev/null \
    | grep '^Inst' \
    | grep -iv 'proxmox\|pve\|linux-image\|linux-headers\|pve-kernel\|proxmox-kernel' \
    | awk '{print $2}')

HOST_COUNT=$(echo "$HOST_PKGS" | grep -c '\S' || true)

if [ "$HOST_COUNT" -eq 0 ]; then
    ok "HOST — No security patches pending"
else
    host "HOST — $HOST_COUNT security package(s) to upgrade"
    host "HOST — Upgrading: $(echo "$HOST_PKGS" | tr '\n' ' ')"

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $HOST_PKGS 2>&1 | tee -a "$LOG_FILE"
    HOST_EXIT=${PIPESTATUS[0]}

    if [ $HOST_EXIT -eq 0 ]; then
        ok "HOST — Successfully applied $HOST_COUNT security patch(es)"
        TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
    else
        flag "HOST — Security patch failed (check log for details)"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi
fi

host "HOST — PVE/kernel updates intentionally skipped (apply manually)"
echo "" | tee -a "$LOG_FILE"

# ── ITERATE CONTAINERS ───────────────────────────────────────
while IFS= read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    STATUS=$(echo "$line" | awk '{print $2}')
    NAME=$(echo "$line" | awk '{print $3}')

    [ -z "$VMID" ] && continue

    # ── SKIP CHECKS ──────────────────────────────────────────────
    # Primary: honour "no-auto-update" tag set in the Proxmox GUI
    # (Container → Options → Tags → add: no-auto-update)
    TAGS=$(pct config "$VMID" 2>/dev/null | grep '^tags:' | cut -d' ' -f2-)
    if echo "$TAGS" | grep -qw "no-auto-update"; then
        info "[$VMID] $NAME — SKIPPED (tagged no-auto-update)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    # Fallback: SKIP_IDS list defined at top of script
    if [[ " $SKIP_IDS " == *" $VMID "* ]]; then
        info "[$VMID] $NAME — SKIPPED (in SKIP_IDS list)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    # Skip non-running containers
    if [ "$STATUS" != "running" ]; then
        info "[$VMID] $NAME — SKIPPED (status: $STATUS)"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        continue
    fi

    title "[$VMID] $NAME"

    # ── CHECK FOR DOCKER ─────────────────────────────────────
    if pct exec "$VMID" -- sh -c "command -v docker >/dev/null 2>&1" 2>/dev/null; then
        info "[$VMID] $NAME — Docker detected, handling separately"
        DOCKER_CONTAINERS+=("$VMID:$NAME")

        # Pull all named registry images — grep '/' filters out locally built
        # images (no org/registry prefix) which cannot be pulled from any
        # registry and would error. Works generically across any Docker setup.
        DOCKER_OUTPUT=$(pct exec "$VMID" -- sh -c "
            docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -v '<none>' | grep '/' | sort -u | while read img; do
                echo -n \"  Pulling \$img ... \"
                result=\$(docker pull \$img 2>&1 | tail -1)
                echo \"\$result\"
            done
        " 2>/dev/null)

        if [ -n "$DOCKER_OUTPUT" ]; then
            log "$DOCKER_OUTPUT"
            pct exec "$VMID" -- bash -c "
                docker run --rm -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --run-once 2>&1 | tail -5
            " 2>/dev/null && ok "[$VMID] $NAME — Docker images updated" || info "[$VMID] $NAME — No Docker updates or Watchtower not available"
        fi

        TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    # ── OPKG-BASED UPDATE (OpenWRT) ──────────────────────────
    if pct exec "$VMID" -- sh -c "command -v opkg >/dev/null 2>&1" 2>/dev/null; then
        info "[$VMID] $NAME — opkg detected (OpenWRT / Entware / embedded Linux)"

        # Single pct exec call — avoids tmpfs context loss between separate
        # pct exec sessions on OpenWRT. Sentinel marker __EXIT__:N is appended
        # so we can parse the exit code out of the combined output string.
        log "[$VMID] $NAME — Running opkg update..."
        OPKG_UPDATE_RAW=$(pct exec "$VMID" -- sh -c "opkg update 2>&1; echo __EXIT__:\$?" 2>/dev/null)
        UPDATE_EXIT=$(echo "$OPKG_UPDATE_RAW" | grep '__EXIT__:' | cut -d: -f2 | tr -d '[:space:]')
        UPDATE_OUT=$(echo "$OPKG_UPDATE_RAW" | grep -v '__EXIT__:')

        if [ "$UPDATE_EXIT" != "0" ]; then
            info "[$VMID] $NAME — opkg update could not reach package feeds"
            [ -n "$UPDATE_OUT" ] && log "$UPDATE_OUT"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            echo "" | tee -a "$LOG_FILE"
            continue
        fi

        ok "[$VMID] $NAME — opkg update successful"

        UPGRADABLE_LIST=$(pct exec "$VMID" -- sh -c "opkg list-upgradable 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
        UPGRADABLE=$(echo "$UPGRADABLE_LIST" | grep -c '\S' || true)

        if [ "$UPGRADABLE" -eq 0 ]; then
            ok "[$VMID] $NAME — Already up to date (opkg)"
            echo "" | tee -a "$LOG_FILE"
            continue
        fi

        info "[$VMID] $NAME — $UPGRADABLE package(s) to upgrade via opkg"
        log "[$VMID] $NAME — Upgrading: $(echo "$UPGRADABLE_LIST" | tr '\n' ' ')"

        OPKG_UPGRADE_RAW=$(pct exec "$VMID" -- sh -c "
            pkgs=\$(opkg list-upgradable 2>/dev/null | awk '{print \$1}' | tr '\n' ' ')
            opkg upgrade \$pkgs 2>&1
            echo __EXIT__:\$?
        " 2>/dev/null)
        UPGRADE_EXIT=$(echo "$OPKG_UPGRADE_RAW" | grep '__EXIT__:' | cut -d: -f2 | tr -d '[:space:]')
        UPGRADE_OUT=$(echo "$OPKG_UPGRADE_RAW" | grep -v '__EXIT__:')

        if [ "$UPGRADE_EXIT" = "0" ]; then
            ok "[$VMID] $NAME — Successfully upgraded $UPGRADABLE package(s) via opkg"
            TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
        else
            flag "[$VMID] $NAME — opkg upgrade failed: $UPGRADE_OUT"
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        fi

        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    # ── APT-BASED UPDATE ─────────────────────────────────────
    if ! pct exec "$VMID" -- sh -c "command -v apt-get >/dev/null 2>&1" 2>/dev/null; then
        info "[$VMID] $NAME — No apt-get or opkg found, skipping"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    log "[$VMID] $NAME — Running apt update..."
    UPDATE_OUT=$(pct exec "$VMID" -- sh -c "apt-get update -qq 2>&1")
    UPDATE_EXIT=$?

    if [ $UPDATE_EXIT -ne 0 ]; then
        flag "[$VMID] $NAME — apt update failed: $UPDATE_OUT"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    UPGRADABLE=$(pct exec "$VMID" -- sh -c "apt-get --simulate upgrade 2>/dev/null | grep '^Inst' | wc -l")

    if [ "$UPGRADABLE" -eq 0 ]; then
        ok "[$VMID] $NAME — Already up to date"
        echo "" | tee -a "$LOG_FILE"
        continue
    fi

    info "[$VMID] $NAME — $UPGRADABLE package(s) to upgrade"
    UPGRADE_LIST=$(pct exec "$VMID" -- sh -c "apt-get --simulate upgrade 2>/dev/null | grep '^Inst' | awk '{print \$2}' | tr '\n' ' '")
    log "[$VMID] $NAME — Upgrading: $UPGRADE_LIST"

    UPGRADE_OUT=$(pct exec "$VMID" -- sh -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1")
    UPGRADE_EXIT=$?

    if [ $UPGRADE_EXIT -eq 0 ]; then
        ok "[$VMID] $NAME — Successfully upgraded $UPGRADABLE package(s)"
        TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
    else
        flag "[$VMID] $NAME — Upgrade failed: $UPGRADE_OUT"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi

    echo "" | tee -a "$LOG_FILE"

done < <(pct list | tail -n +2)

# ── DOCKER SUMMARY ───────────────────────────────────────────
if [ ${#DOCKER_CONTAINERS[@]} -gt 0 ]; then
    log "------------------------------------------------------------"
    info "Docker containers found in:"
    for entry in "${DOCKER_CONTAINERS[@]}"; do
        VMID="${entry%%:*}"
        NAME="${entry##*:}"
        info "  → [$VMID] $NAME"
    done
fi

# ── REBOOT CHECK ─────────────────────────────────────────────
echo "" | tee -a "$LOG_FILE"
if [ -f /var/run/reboot-required ]; then
    REBOOT_PKGS=""
    [ -f /var/run/reboot-required.pkgs ] && REBOOT_PKGS=$(cat /var/run/reboot-required.pkgs | tr '\n' ' ')
    flag "HOST — REBOOT REQUIRED — triggered by: ${REBOOT_PKGS:-unknown}"
    flag "HOST — Run 'reboot' manually when ready (all containers will restart)"
else
    ok "HOST — No reboot required"
fi

# ── SUMMARY ──────────────────────────────────────────────────
echo "" | tee -a "$LOG_FILE"
log "============================================================"
if [ $TOTAL_ERRORS -gt 0 ]; then
    flag "  RESULT: $TOTAL_UPDATED updated | $TOTAL_SKIPPED skipped | ${RED}$TOTAL_ERRORS ERROR(S)${NC}"
else
    ok "  RESULT: $TOTAL_UPDATED updated | $TOTAL_SKIPPED skipped | $TOTAL_ERRORS errors"
fi
log "  NOTE: PVE/kernel updates require manual review + reboot"
log "  Log saved to: $LOG_FILE"
log "============================================================"
echo "" | tee -a "$LOG_FILE"

# Trim logs older than 30 days
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null
