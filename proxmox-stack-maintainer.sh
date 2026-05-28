#!/bin/bash
# ============================================================
#  proxmox-stack-maintainer.sh — Proxmox Stack Maintainer
#  Run on the Proxmox HOST as root
#
#  Supports:
#    - Proxmox HOST (Debian security patches only,
#      excludes PVE/kernel packages to preserve stability)
#    - LXC containers (apt/Debian-based)
#    - Docker containers (via Watchtower)
#    - OpenWRT containers (via opkg)
#
#  Usage:    bash proxmox-stack-maintainer.sh
#  Logs:     /var/log/proxmox-stack-maintainer/YYYY-MM-DD.log
# ============================================================

APP_NAME="Proxmox Stack Maintainer"
APP_SLUG="proxmox-stack-maintainer"
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-stack-maintainer/config.env}"
LOG_DIR="/var/log/proxmox-stack-maintainer"
STATE_DIR="/var/lib/proxmox-stack-maintainer"
INVENTORY_FILE="$STATE_DIR/inventory.tsv"
PREV_INVENTORY_FILE="$STATE_DIR/inventory.previous.tsv"
CURRENT_INVENTORY_FILE="$STATE_DIR/inventory.current.tsv"
LOG_RETENTION_DAYS="30"
SKIP_IDS="600"   # Fallback: space-separated VMIDs to skip (e.g. "100 200 300")
                 # Preferred: tag a container "no-auto-update" in the Proxmox GUI instead
SERVICE_CHECKS=(
  "Prismarr=http://10.12.0.30:7070"
)
DRY_RUN=0
CHECK_ONLY=0

usage() {
    cat <<'EOF'
Proxmox Stack Maintainer

Usage:
  proxmox-stack-maintainer.sh [--dry-run] [--check] [--config /path/config.env]

Options:
  --dry-run       Discover stack and log intended actions without applying upgrades.
  --check         Validate host prerequisites and print install/runtime status.
  --config PATH   Source an alternate config file before running.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --check) CHECK_ONLY=1 ;;
        --config) shift; CONFIG_FILE="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/etc/proxmox-stack-maintainer/config.env
    source "$CONFIG_FILE"
fi

LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

# Colours
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[0;36m'
NC='\033[0m'

runtime_check() {
    local rc=0
    echo "$APP_NAME runtime check"
    echo "Config: ${CONFIG_FILE:-none}"
    if [ "$EUID" -ne 0 ]; then
        echo "FAIL: must run as root"
        rc=1
    else
        echo "OK: running as root"
    fi
    for cmd in pct apt-get awk grep sort tee curl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "OK: command found: $cmd"
        else
            echo "FAIL: missing command: $cmd"
            rc=1
        fi
    done
    if command -v qm >/dev/null 2>&1; then
        echo "OK: command found: qm"
    else
        echo "WARN: qm not found; VM coverage will be skipped"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-enabled proxmox-stack-maintainer.timer >/dev/null 2>&1 \
            && echo "OK: systemd timer enabled" \
            || echo "WARN: systemd timer not enabled"
        systemctl list-timers --all --no-pager 2>/dev/null | grep -q 'proxmox-stack-maintainer.timer' \
            && echo "OK: systemd timer listed" \
            || echo "WARN: systemd timer not listed"
    fi
    echo "Log dir: $LOG_DIR"
    echo "State dir: $STATE_DIR"
    return "$rc"
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    runtime_check
    exit $?
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"
: > "$CURRENT_INVENTORY_FILE"
if [ -f "$INVENTORY_FILE" ]; then
    cp "$INVENTORY_FILE" "$PREV_INVENTORY_FILE"
else
    : > "$PREV_INVENTORY_FILE"
fi

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

flag()  { log "${RED}[!!!] $1${NC}"; }
ok()    { log "${GRN}[ OK] $1${NC}"; }
info()  { log "${YLW}[---] $1${NC}"; }
title() { log "${BLU}===  $1${NC}"; }
host()  { log "${CYN}[HST] $1${NC}"; }

inventory_escape() {
    printf '%s' "$1" | tr '\t' ' ' | tr '\n' ' '
}

inventory_previous_line() {
    local type="$1" vmid="$2"
    awk -F'\t' -v type="$type" -v vmid="$vmid" '$1 == type && $2 == vmid { print; exit }' "$PREV_INVENTORY_FILE"
}

inventory_seen_current() {
    local type="$1" vmid="$2"
    awk -F'\t' -v type="$type" -v vmid="$vmid" '$1 == type && $2 == vmid { found=1 } END { exit found ? 0 : 1 }' "$CURRENT_INVENTORY_FILE"
}

record_stack_member() {
    local type="$1" vmid="$2" name="$3" status="$4" tags="$5"
    local now first_seen prev_line prev_status prev_name safe_name safe_tags

    now="$(date '+%Y-%m-%d %H:%M:%S')"
    safe_name="$(inventory_escape "$name")"
    safe_tags="$(inventory_escape "$tags")"
    prev_line="$(inventory_previous_line "$type" "$vmid")"

    if [ -z "$prev_line" ]; then
        first_seen="$now"
        info "NEW ${type^^} detected: [$vmid] $name (status: $status)"
    else
        first_seen="$(echo "$prev_line" | awk -F'\t' '{print $6}')"
        prev_name="$(echo "$prev_line" | awk -F'\t' '{print $3}')"
        prev_status="$(echo "$prev_line" | awk -F'\t' '{print $4}')"
        [ "$prev_name" != "$safe_name" ] && info "${type^^} renamed: [$vmid] $prev_name → $name"
        [ "$prev_status" != "$status" ] && info "${type^^} status changed: [$vmid] $name ($prev_status → $status)"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$vmid" "$safe_name" "$status" "$safe_tags" "$first_seen" "$now" >> "$CURRENT_INVENTORY_FILE"
}

summarise_removed_stack_members() {
    [ -s "$PREV_INVENTORY_FILE" ] || return 0

    while IFS=$'\t' read -r type vmid name status tags first_seen last_seen; do
        [ -z "$type" ] && continue
        if ! inventory_seen_current "$type" "$vmid"; then
            info "REMOVED ${type^^} from stack inventory: [$vmid] $name (last status: $status, last seen: $last_seen)"
        fi
    done < "$PREV_INVENTORY_FILE"
}

finalise_inventory() {
    sort -t $'\t' -k1,1 -k2,2n "$CURRENT_INVENTORY_FILE" > "$INVENTORY_FILE"
    rm -f "$CURRENT_INVENTORY_FILE"
}

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
log "  Proxmox Stack Maintainer"
log "  Host   : $(hostname)"
log "  Date   : $(date)"
[ "$DRY_RUN" -eq 1 ] && log "  Mode   : DRY RUN (no upgrades will be applied)"
log "============================================================"
echo "" | tee -a "$LOG_FILE"

TOTAL_UPDATED=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
DOCKER_CONTAINERS=()

# ── PROXMOX HOST SECURITY UPDATES ────────────────────────────
title "PROXMOX HOST — Security patches (Debian only)"

if [ "$DRY_RUN" -eq 1 ]; then
    info "HOST — DRY RUN: skipping apt-get update"
else
    apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
fi

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

    if [ "$DRY_RUN" -eq 1 ]; then
        info "HOST — DRY RUN: would apply $HOST_COUNT security patch(es)"
    else
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
    record_stack_member "lxc" "$VMID" "$NAME" "$STATUS" "$TAGS"

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

        if [ "$DRY_RUN" -eq 1 ]; then
            DOCKER_IMAGES=$(pct exec "$VMID" -- sh -c "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | grep '/' | sort -u" 2>/dev/null || true)
            info "[$VMID] $NAME — DRY RUN: would pull registry images and run Watchtower"
            [ -n "$DOCKER_IMAGES" ] && log "$DOCKER_IMAGES"
        else
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

        if [ "$DRY_RUN" -eq 1 ]; then
            info "[$VMID] $NAME — DRY RUN: would upgrade $UPGRADABLE opkg package(s)"
        else
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

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[$VMID] $NAME — DRY RUN: would upgrade $UPGRADABLE apt package(s)"
    else
        UPGRADE_OUT=$(pct exec "$VMID" -- sh -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>&1")
        UPGRADE_EXIT=$?

        if [ $UPGRADE_EXIT -eq 0 ]; then
            ok "[$VMID] $NAME — Successfully upgraded $UPGRADABLE package(s)"
            TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
        else
            flag "[$VMID] $NAME — Upgrade failed: $UPGRADE_OUT"
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        fi
    fi

    echo "" | tee -a "$LOG_FILE"

done < <(pct list | tail -n +2)

# ── QEMU/KVM VM COVERAGE ────────────────────────────────────
VM_TOTAL=0
VM_RUNNING=0
VM_AGENT_OK=0
VM_AGENT_MISSING=0
if command -v qm &>/dev/null; then
    title "QEMU/KVM VMs — inventory and guest-agent coverage"
    while IFS= read -r line; do
        VMID=$(echo "$line" | awk '{print $1}')
        NAME=$(echo "$line" | awk '{print $2}')
        STATUS=$(echo "$line" | awk '{print $3}')

        [ -z "$VMID" ] && continue
        VM_TOTAL=$((VM_TOTAL + 1))

        TAGS=$(qm config "$VMID" 2>/dev/null | grep '^tags:' | cut -d' ' -f2-)
        record_stack_member "vm" "$VMID" "$NAME" "$STATUS" "$TAGS"

        if [ "$STATUS" != "running" ]; then
            info "[VM:$VMID] $NAME — SKIPPED (status: $STATUS)"
            continue
        fi

        VM_RUNNING=$((VM_RUNNING + 1))
        if qm guest ping "$VMID" >/dev/null 2>&1; then
            ok "[VM:$VMID] $NAME — running + qemu-guest-agent reachable"
            VM_AGENT_OK=$((VM_AGENT_OK + 1))
        else
            info "[VM:$VMID] $NAME — running, but qemu-guest-agent not responding"
            VM_AGENT_MISSING=$((VM_AGENT_MISSING + 1))
        fi
        info "[VM:$VMID] $NAME — VM updates are inventory-only unless guest-specific maintenance is configured"
    done < <(qm list | tail -n +2)
    echo "" | tee -a "$LOG_FILE"
fi

# ── SERVICE HEALTH CHECKS ────────────────────────────────────
if [ ${#SERVICE_CHECKS[@]} -gt 0 ]; then
    title "SERVICE HEALTH CHECKS"
    for entry in "${SERVICE_CHECKS[@]}"; do
        SVC_NAME="${entry%%=*}"
        SVC_URL="${entry#*=}"
        [ -z "$SVC_NAME" ] || [ -z "$SVC_URL" ] && continue
        HTTP_CODE=$(curl -sS -L -o /dev/null -m 8 -w "%{http_code}" "$SVC_URL" 2>/dev/null || echo "000")
        if echo "$HTTP_CODE" | grep -Eq '^(2|3)[0-9][0-9]$'; then
            ok "$SVC_NAME — reachable ($HTTP_CODE) at $SVC_URL"
        else
            flag "$SVC_NAME — health check failed ($HTTP_CODE) at $SVC_URL"
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        fi
    done
    echo "" | tee -a "$LOG_FILE"
fi

summarise_removed_stack_members
finalise_inventory

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
log "  VM coverage: total=$VM_TOTAL running=$VM_RUNNING guest-agent-ok=$VM_AGENT_OK guest-agent-missing=$VM_AGENT_MISSING"
log "  NOTE: PVE/kernel updates require manual review + reboot"
log "  Log saved to: $LOG_FILE"
log "============================================================"
echo "" | tee -a "$LOG_FILE"

# Trim logs older than 30 days
find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
