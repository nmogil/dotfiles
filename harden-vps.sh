#!/bin/bash
# -e: exit on error. -E: ERR trap inherited by functions (so `run` failures fire it).
set -eE

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
LOG_FILE="$HOME/.dotfiles-harden-vps-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date +%H:%M:%S; }

section() {
    echo ""
    echo "================================================================"
    echo "  [$(ts)] $1"
    echo "================================================================"
}

log() { echo "  [$(ts)] $*"; }
run() { echo "  [$(ts)] \$ $*"; "$@"; }

trap 'rc=$?; echo ""; echo "✗ FAILED at line $LINENO (exit $rc)"; echo "  Full log: $LOG_FILE"; exit $rc' ERR

echo "================================================================"
echo "  VPS Hardening Script (Debian/Ubuntu)"
echo "================================================================"
echo "  Started: $(date)"
echo "  Log file: $LOG_FILE"
echo "================================================================"
echo ""
echo "Three opt-in steps, in safe order:"
echo "  1. Unattended security upgrades (always safe)"
echo "  2. Tailscale install + tailnet join"
echo "  3. UFW firewall (Tailscale-only inbound)"
echo ""
echo "Step 3 is gated: it will only run after verifying that tailscale0"
echo "exists AND you confirm a working Tailscale SSH session."
echo ""

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    log "Running as root"
else
    SUDO="sudo"
    log "Running as $(whoami) — using sudo"
    sudo -v
fi

if ! command -v apt-get &> /dev/null; then
    echo "✗ This script targets Debian/Ubuntu (apt). Aborting."
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 1: unattended-upgrades
# -----------------------------------------------------------------------------
section "Step 1: Unattended security upgrades"
read -rp "Enable automatic security patches? [y/N]: " do_unattended
if [[ $do_unattended =~ ^[Yy]$ ]]; then
    run $SUDO apt-get update -y
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades

    log "Writing /etc/apt/apt.conf.d/20auto-upgrades"
    $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    log "Service status:"
    $SUDO systemctl status unattended-upgrades --no-pager --lines=3 || true
else
    log "Skipped."
fi

# -----------------------------------------------------------------------------
# Step 2: Tailscale
# -----------------------------------------------------------------------------
section "Step 2: Tailscale"
read -rp "Install Tailscale and join tailnet? [y/N]: " do_tailscale
if [[ $do_tailscale =~ ^[Yy]$ ]]; then
    if command -v tailscale &> /dev/null; then
        log "Tailscale already installed: $(tailscale version | head -n1)"
    else
        log "Installing Tailscale..."
        run bash -c "curl -fsSL https://tailscale.com/install.sh | $SUDO sh"
    fi

    echo ""
    echo "Next: 'tailscale up --ssh' will print an auth URL."
    echo "Open that URL in your browser to add this VPS to your tailnet."
    echo ""
    read -rp "Run 'tailscale up --ssh' now? [y/N]: " confirm_up
    if [[ $confirm_up =~ ^[Yy]$ ]]; then
        run $SUDO tailscale up --ssh
        echo ""
        log "Tailscale status:"
        $SUDO tailscale status || true
        TAILSCALE_IP=$($SUDO tailscale ip -4 2>/dev/null | head -n1 || echo "")
        if [ -n "$TAILSCALE_IP" ]; then
            log "Tailnet IP: $TAILSCALE_IP"
        fi
    else
        log "Skipped 'tailscale up'. Run manually later: sudo tailscale up --ssh"
    fi
else
    log "Skipped."
fi

# -----------------------------------------------------------------------------
# Step 3: UFW (gated on Tailscale being up)
# -----------------------------------------------------------------------------
section "Step 3: UFW firewall"

if ! ip link show tailscale0 &> /dev/null; then
    log "tailscale0 interface not found — skipping UFW to prevent lock-out."
    log "Re-run this script after Tailscale is up if you want to enable UFW."
else
    log "tailscale0 interface present"
    echo ""
    echo "================================================================"
    echo "  WARNING: enabling UFW will:"
    echo "    - DROP all inbound on the public interface (incl. port 22)"
    echo "    - ALLOW inbound only on tailscale0"
    echo ""
    echo "  If you are SSH'd in over the public IP right now, you WILL"
    echo "  be disconnected. Before continuing:"
    echo ""
    echo "    1. Open a SECOND terminal"
    echo "    2. SSH in via Tailscale (use the tailnet name or 100.x IP)"
    echo "    3. Confirm that second session works"
    echo "================================================================"
    echo ""
    read -rp "Have you confirmed a working Tailscale SSH session? [y/N]: " ts_confirmed
    if [[ ! $ts_confirmed =~ ^[Yy]$ ]]; then
        log "Skipped UFW. Re-run once Tailscale SSH is verified."
    else
        read -rp "Enable UFW now (Tailscale-only inbound)? [y/N]: " do_ufw
        if [[ $do_ufw =~ ^[Yy]$ ]]; then
            if ! command -v ufw &> /dev/null; then
                run $SUDO apt-get install -y ufw
            fi

            run $SUDO ufw default deny incoming
            run $SUDO ufw default allow outgoing
            run $SUDO ufw allow in on tailscale0
            log "Enabling UFW (auto-confirming the y/N prompt)..."
            yes | $SUDO ufw enable

            echo ""
            log "UFW status:"
            $SUDO ufw status verbose
        else
            log "Skipped."
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
section "Hardening Complete"
log "Finished: $(date)"
log "Full log saved to: $LOG_FILE"
echo ""
echo "Verification:"
echo "  - From outside Tailscale:  'ssh root@<public-ip>'  → should hang/timeout"
echo "  - From a tailnet device:   'ssh <user>@<tailscale-name>'  → should work"
echo "  - Local check:             'sudo ufw status'  → tailscale0 ALLOW IN"
echo ""
echo "Optional next steps (manual — not done by this script):"
echo "  - Edit /etc/ssh/sshd_config:"
echo "      PasswordAuthentication no"
echo "      PermitRootLogin no"
echo "    Then: sudo systemctl restart ssh"
echo "    Only do this AFTER confirming SSH key auth works!"
echo ""
