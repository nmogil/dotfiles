#!/bin/bash
# -e: exit on error. -E: ERR trap inherited by functions (so `run` failures fire it).
set -eE

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
LOG_FILE="$HOME/.dotfiles-setup-obsidian-sync-$(date +%Y%m%d-%H%M%S).log"
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
echo "  Obsidian Headless Sync Setup (Debian/Ubuntu)"
echo "================================================================"
echo "  Started: $(date)"
echo "  Log file: $LOG_FILE"
echo "================================================================"

# -----------------------------------------------------------------------------
# Privilege detection
# -----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    log "Running as root — no sudo needed"
else
    SUDO="sudo"
    log "Running as $(whoami) — using sudo for privileged ops"
    sudo -v
fi

if ! command -v apt-get &> /dev/null; then
    echo "✗ This script targets Debian/Ubuntu (apt). Aborting."
    exit 1
fi

# -----------------------------------------------------------------------------
# Step A: Prerequisite checks
# -----------------------------------------------------------------------------
section "Step A: Prerequisite checks"

if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "✗ node and npm are required but not found."
    echo "  Run ./setup-linux.sh first (it installs Node 22 via NodeSource)."
    exit 1
fi
log "node: $(node --version)"
log "npm:  $(npm --version)"

echo ""
echo "================================================================"
echo "  NOTICE: Obsidian Headless Sync requires an active Obsidian"
echo "  Sync subscription (paid). Without it, login will fail and"
echo "  no remote vaults will be available."
echo "================================================================"
echo ""
read -rp "Do you have an active Obsidian Sync subscription? [y/N]: " has_sub
if [[ ! $has_sub =~ ^[Yy]$ ]]; then
    log "Aborting — Obsidian Sync subscription required."
    exit 0
fi

# -----------------------------------------------------------------------------
# Step B: Install obsidian-headless globally
# -----------------------------------------------------------------------------
section "Step B: Install obsidian-headless"

if command -v ob &> /dev/null; then
    log "obsidian-headless already installed: $(ob --version 2>&1 | head -n1)"
else
    run $SUDO npm install -g obsidian-headless
    if ! command -v ob &> /dev/null; then
        echo "✗ 'ob' not on PATH after install. Check npm global bin location."
        exit 1
    fi
    log "Installed: $(ob --version 2>&1 | head -n1)"
fi

# -----------------------------------------------------------------------------
# Step C: Login (skip if already logged in)
# -----------------------------------------------------------------------------
section "Step C: Obsidian Sync login"

# Detect login state by trying a command that requires auth. If `ob sync-list-remote`
# succeeds, we're logged in; otherwise fall back to interactive `ob login`.
if ob sync-list-remote &> /dev/null; then
    log "Already authenticated (sync-list-remote succeeded)"
else
    log "Not logged in — launching interactive 'ob login'..."
    echo ""
    run ob login
    echo ""
    if ! ob sync-list-remote &> /dev/null; then
        echo "✗ Login appears to have failed (sync-list-remote still errors)."
        exit 1
    fi
    log "Login confirmed."
fi

# -----------------------------------------------------------------------------
# Step D: Vault selection and local path
# -----------------------------------------------------------------------------
section "Step D: Vault selection"

USE_EXISTING=false
existing_output=""
if existing_output=$(ob sync-list-local 2>&1) && [ -n "$existing_output" ]; then
    echo ""
    echo "  Existing local vault configuration:"
    echo "$existing_output" | sed 's/^/    /'
    echo ""
    read -rp "Use existing local setup? [Y/n]: " use_resp
    if [[ -z $use_resp || $use_resp =~ ^[Yy]$ ]]; then
        USE_EXISTING=true
    fi
fi

VAULT_NAME=""
if ! $USE_EXISTING; then
    echo ""
    log "Available remote vaults:"
    echo ""
    run ob sync-list-remote
    echo ""
    while [ -z "$VAULT_NAME" ]; do
        read -rp "Enter exact vault name to sync: " VAULT_NAME
    done
fi

echo ""
read -rp "Local vault path [default: $HOME/obsidian]: " LOCAL_PATH
LOCAL_PATH="${LOCAL_PATH:-$HOME/obsidian}"
# Expand ~ if user typed it literally
LOCAL_PATH="${LOCAL_PATH/#\~/$HOME}"

if [ ! -d "$LOCAL_PATH" ]; then
    log "Creating $LOCAL_PATH"
    run mkdir -p "$LOCAL_PATH"
else
    log "Local path exists: $LOCAL_PATH"
fi

if ! $USE_EXISTING; then
    log "Running 'ob sync-setup' (may prompt for E2EE password)..."
    cd "$LOCAL_PATH"
    echo ""
    run ob sync-setup --vault "$VAULT_NAME"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step E: Initial sync (one-shot)
# -----------------------------------------------------------------------------
section "Step E: Initial sync"
log "Running one-shot 'ob sync' to populate $LOCAL_PATH..."
cd "$LOCAL_PATH"
run ob sync

# -----------------------------------------------------------------------------
# Step F: Systemd user unit for continuous sync
# -----------------------------------------------------------------------------
section "Step F: Systemd user unit (continuous sync)"

OB_BIN="$(command -v ob || echo /usr/bin/ob)"
log "Resolved ob binary: $OB_BIN"

UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/ob-sync.service"
mkdir -p "$UNIT_DIR"

log "Writing $UNIT_FILE"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Obsidian Headless Sync (continuous)
Documentation=https://help.obsidian.md/sync/headless
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$LOCAL_PATH
ExecStart=$OB_BIN sync --continuous
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5
MemoryHigh=512M
MemoryMax=1G

[Install]
WantedBy=default.target
EOF

# Enable lingering so the user instance keeps running across logout / reboot
CURRENT_USER="$(whoami)"
if loginctl show-user "$CURRENT_USER" 2>/dev/null | grep -q '^Linger=yes'; then
    log "Lingering already enabled for $CURRENT_USER"
else
    log "Enabling lingering for $CURRENT_USER"
    run $SUDO loginctl enable-linger "$CURRENT_USER"
fi

run systemctl --user daemon-reload
run systemctl --user enable --now ob-sync.service

log "Sleeping 3s to let the unit start..."
sleep 3

if systemctl --user is-active --quiet ob-sync.service; then
    log "ob-sync.service is active"
else
    log "ob-sync.service not active — current status:"
    systemctl --user status ob-sync.service --no-pager --lines=20 || true
    log "Investigate with: journalctl --user -u ob-sync -e"
fi

# -----------------------------------------------------------------------------
# Step G: Hermes wiring (optional)
# -----------------------------------------------------------------------------
section "Step G: Hermes integration"

HERMES_ENV="$HOME/.hermes/.env"
if [ -f "$HERMES_ENV" ]; then
    if grep -q '^OBSIDIAN_VAULT_PATH=' "$HERMES_ENV"; then
        existing_path=$(grep '^OBSIDIAN_VAULT_PATH=' "$HERMES_ENV" | head -n1 | cut -d= -f2-)
        if [ "$existing_path" = "$LOCAL_PATH" ]; then
            log "Hermes already has OBSIDIAN_VAULT_PATH=$LOCAL_PATH"
        else
            log "Hermes currently has OBSIDIAN_VAULT_PATH=$existing_path"
            read -rp "Overwrite with $LOCAL_PATH? [y/N]: " overwrite
            if [[ $overwrite =~ ^[Yy]$ ]]; then
                run sed -i "s|^OBSIDIAN_VAULT_PATH=.*|OBSIDIAN_VAULT_PATH=$LOCAL_PATH|" "$HERMES_ENV"
                log "Updated."
            else
                log "Left existing value in place."
            fi
        fi
    else
        log "Appending OBSIDIAN_VAULT_PATH=$LOCAL_PATH to $HERMES_ENV"
        echo "OBSIDIAN_VAULT_PATH=$LOCAL_PATH" >> "$HERMES_ENV"
    fi
else
    log "No $HERMES_ENV found — skipping Hermes wiring."
    log "If you install Hermes later, add: OBSIDIAN_VAULT_PATH=$LOCAL_PATH"
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
section "Obsidian Sync Setup Complete"
log "Finished: $(date)"
echo ""
echo "  Vault path:  $LOCAL_PATH"
echo "  ob binary:   $OB_BIN"
echo "  Unit file:   $UNIT_FILE"
echo "  Log file:    $LOG_FILE"
echo ""
echo "Manage the sync service:"
echo "  systemctl --user status ob-sync"
echo "  systemctl --user restart ob-sync"
echo "  systemctl --user stop ob-sync"
echo "  systemctl --user disable --now ob-sync"
echo "  journalctl --user -u ob-sync -f"
echo ""
echo "Docs: https://help.obsidian.md/sync/headless"
echo ""
