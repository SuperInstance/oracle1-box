#!/usr/bin/env bash
# Oracle1-in-a-Box — one script to provision the entire fleet infrastructure
# Usage: curl -fsSL https://raw.githubusercontent.com/SuperInstance/oracle1-box/main/setup.sh | bash
#
# Sets up:
#   - PLATO room server (shared knowledge between agents)
#   - Keeper (agent identity and auth)
#   - Data pipeline (hourly tile ingestion → dedup → trust scoring → training export)
#   - CFP constraint flow protocol (agents share FLUX bytecode constraints)
#   - Ambient briefing (fleet generates "12 Things" briefings when idle)
#
# All running via systemd timers. Idempotent — safe to run twice.

set -euo pipefail

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
REPO_BASE="${HOME}/oracle1-box"
PLATO_REPO_URL="https://github.com/SuperInstance/plato-vessel-core.git"
PLATO_DIR="${REPO_BASE}/plato-vessel-core"
VENV_DIR="${REPO_BASE}/venv"
PLATO_PORT=8847
KEEPER_PORT=8900
DATA_DIR="/data/plato-training"
PLATO_ROOM_SERVICE="oracle1-plato-room"
KEEPER_SERVICE="oracle1-keeper"
PIPELINE_TIMER="oracle1-pipeline"
CFP_TIMER="oracle1-cfp-monitor"
BRIEFING_TIMER="oracle1-ambient-briefing"
PIPELINE_INTERVAL="hourly"
CFP_INTERVAL="*:0/15"
BRIEFING_INTERVAL="*:0/30"
PYTHON="${VENV_DIR}/bin/python3"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ──────────────────────────────────────────────
# Preflight: Root check
# ──────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    err "Do not run this script as root or with sudo. It manages service files via sudo."
    exit 1
fi

# ──────────────────────────────────────────────
# Step 1: Install system dependencies
# ──────────────────────────────────────────────
install_deps() {
    info "Step 1/7: Installing system dependencies..."

    local pkgs=()
    for pkg in python3 python3-venv python3-pip curl git systemd; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            pkgs+=("$pkg")
        fi
    done

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${pkgs[@]}"
        ok "Installed: ${pkgs[*]}"
    else
        ok "All dependencies already installed."
    fi
}

# ──────────────────────────────────────────────
# Step 2: Create directory structure
# ──────────────────────────────────────────────
create_dirs() {
    info "Step 2/7: Creating directory structure..."

    mkdir -p "${REPO_BASE}"
    mkdir -p "${DATA_DIR}"
    sudo chown -R "${USER}:${USER}" "${DATA_DIR}" 2>/dev/null || true
    ok "Directories ready: ${REPO_BASE}, ${DATA_DIR}"
}

# ──────────────────────────────────────────────
# Step 3: Clone/update plato-vessel-core
# ──────────────────────────────────────────────
clone_repo() {
    info "Step 3/7: Setting up plato-vessel-core..."

    if [[ -d "${PLATO_DIR}/.git" ]]; then
        info "Repository exists — pulling latest..."
        cd "${PLATO_DIR}"
        git pull --ff-only origin main 2>/dev/null || true
        cd "${REPO_BASE}"
        ok "Updated plato-vessel-core to latest."
    else
        git clone "${PLATO_REPO_URL}" "${PLATO_DIR}"
        ok "Cloned plato-vessel-core."
    fi
}

# ──────────────────────────────────────────────
# Step 4: Create Python virtual environment
# ──────────────────────────────────────────────
setup_venv() {
    info "Step 4/7: Setting up Python virtual environment..."

    if [[ -f "${VENV_DIR}/bin/python3" ]]; then
        info "Virtual environment exists — updating pip..."
        "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    else
        python3 -m venv "${VENV_DIR}"
        ok "Created virtual environment."
    fi

    # Install plato-vessel-core dependencies if requirements.txt exists
    if [[ -f "${PLATO_DIR}/requirements.txt" ]]; then
        "${VENV_DIR}/bin/pip" install --quiet -r "${PLATO_DIR}/requirements.txt"
        ok "Installed plato-vessel-core dependencies."
    fi

    # Install common dependencies the fleet scripts need
    local common_deps=(
        "flask"
        "requests"
        "croniter"
        "watchdog"
    )
    for dep in "${common_deps[@]}"; do
        "${VENV_DIR}/bin/pip" install --quiet "$dep" 2>/dev/null || true
    done
    ok "Installed common Python dependencies."
}

# ──────────────────────────────────────────────
# Step 5: Install systemd service files
# ──────────────────────────────────────────────
install_systemd_services() {
    info "Step 5/7: Installing systemd service and timer units..."

    # ── PLATO Room Server ──
    info "  Installing PLATO room server service..."
    sudo tee "/etc/systemd/system/${PLATO_ROOM_SERVICE}.service" > /dev/null <<SERVICE_PLATO
[Unit]
Description=Oracle1 PLATO Room Server
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${PLATO_DIR}
ExecStart=${PYTHON} ${PLATO_DIR}/plato-room-server.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_PLATO

    # ── Keeper ──
    info "  Installing Keeper service..."
    sudo tee "/etc/systemd/system/${KEEPER_SERVICE}.service" > /dev/null <<SERVICE_KEEPER
[Unit]
Description=Oracle1 Keeper — Agent Identity and Auth
After=network.target
Requires=${PLATO_ROOM_SERVICE}.service
After=${PLATO_ROOM_SERVICE}.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${PLATO_DIR}
ExecStart=${PYTHON} ${PLATO_DIR}/keeper.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_KEEPER

    # ── Pipeline Timer ──
    info "  Installing data pipeline timer..."
    sudo tee "/etc/systemd/system/${PIPELINE_TIMER}.service" > /dev/null <<SERVICE_PIPELINE
[Unit]
Description=Oracle1 Data Pipeline — Tile Ingestion → Dedup → Trust Scoring → Training Export
After=network.target
Requires=${PLATO_ROOM_SERVICE}.service

[Service]
Type=oneshot
User=${USER}
WorkingDirectory=${PLATO_DIR}
ExecStart=${PYTHON} ${PLATO_DIR}/pipeline.py
StandardOutput=journal
StandardError=journal
SERVICE_PIPELINE

    sudo tee "/etc/systemd/system/${PIPELINE_TIMER}.timer" > /dev/null <<TIMER_PIPELINE
[Unit]
Description=Oracle1 Data Pipeline (hourly)
Requires=${PIPELINE_TIMER}.service

[Timer]
OnCalendar=${PIPELINE_INTERVAL}
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
TIMER_PIPELINE

    # ── CFP Monitor Timer ──
    info "  Installing CFP room monitor timer..."
    sudo tee "/etc/systemd/system/${CFP_TIMER}.service" > /dev/null <<SERVICE_CFP
[Unit]
Description=Oracle1 CFP Room Monitor — Constraint Flow Protocol
After=network.target
Requires=${PLATO_ROOM_SERVICE}.service

[Service]
Type=oneshot
User=${USER}
WorkingDirectory=${PLATO_DIR}
ExecStart=${PYTHON} ${PLATO_DIR}/cfp_monitor.py
StandardOutput=journal
StandardError=journal
SERVICE_CFP

    sudo tee "/etc/systemd/system/${CFP_TIMER}.timer" > /dev/null <<TIMER_CFP
[Unit]
Description=Oracle1 CFP Room Monitor (every 15 min)
Requires=${CFP_TIMER}.service

[Timer]
OnCalendar=${CFP_INTERVAL}
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
TIMER_CFP

    # ── Ambient Briefing Timer ──
    info "  Installing ambient briefing timer..."
    sudo tee "/etc/systemd/system/${BRIEFING_TIMER}.service" > /dev/null <<SERVICE_BRIEFING
[Unit]
Description=Oracle1 Ambient Briefing — Fleet "12 Things" Generation
After=network.target
Requires=${PLATO_ROOM_SERVICE}.service

[Service]
Type=oneshot
User=${USER}
WorkingDirectory=${PLATO_DIR}
ExecStart=${PYTHON} ${PLATO_DIR}/ambient_briefing.py
StandardOutput=journal
StandardError=journal
SERVICE_BRIEFING

    sudo tee "/etc/systemd/system/${BRIEFING_TIMER}.timer" > /dev/null <<TIMER_BRIEFING
[Unit]
Description=Oracle1 Ambient Briefing (every 30 min)
Requires=${BRIEFING_TIMER}.service

[Timer]
OnCalendar=${BRIEFING_INTERVAL}
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
TIMER_BRIEFING

    sudo systemctl daemon-reload
    ok "Installed all systemd units."
}

# ──────────────────────────────────────────────
# Step 6: Enable and start services
# ──────────────────────────────────────────────
enable_and_start() {
    info "Step 6/7: Enabling and starting services..."

    # Start PLATO first (others depend on it)
    sudo systemctl enable "${PLATO_ROOM_SERVICE}.service"
    sudo systemctl restart "${PLATO_ROOM_SERVICE}.service"
    ok "PLATO room server enabled and started."

    # Give PLATO a moment to initialize
    sleep 2

    # Start Keeper
    sudo systemctl enable "${KEEPER_SERVICE}.service"
    sudo systemctl restart "${KEEPER_SERVICE}.service"
    ok "Keeper enabled and started."

    # Enable timers
    sudo systemctl enable "${PIPELINE_TIMER}.timer"
    sudo systemctl start "${PIPELINE_TIMER}.timer"
    ok "Data pipeline timer enabled."

    sudo systemctl enable "${CFP_TIMER}.timer"
    sudo systemctl start "${CFP_TIMER}.timer"
    ok "CFP room monitor timer enabled."

    sudo systemctl enable "${BRIEFING_TIMER}.timer"
    sudo systemctl start "${BRIEFING_TIMER}.timer"
    ok "Ambient briefing timer enabled."

    # Run initial pass of data pipeline
    info "Running initial data pipeline pass..."
    sudo systemctl start "${PIPELINE_TIMER}.service" 2>/dev/null || {
        warn "Initial pipeline pass skipped (may need dependencies). Will run on timer."
    }
}

# ──────────────────────────────────────────────
# Step 7: Verify and print success
# ──────────────────────────────────────────────
verify_and_summary() {
    info "Step 7/7: Verifying installation..."

    local failures=0

    # Check services
    for svc in "${PLATO_ROOM_SERVICE}" "${KEEPER_SERVICE}"; do
        if sudo systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            ok "  ${svc} — active"
        else
            warn "  ${svc} — not running (may still be starting)"
            ((failures++))
        fi
    done

    # Check timers
    for tmr in "${PIPELINE_TIMER}" "${CFP_TIMER}" "${BRIEFING_TIMER}"; do
        if sudo systemctl is-active --quiet "${tmr}.timer" 2>/dev/null; then
            ok "  ${tmr}.timer — active"
        else
            warn "  ${tmr}.timer — not active"
            ((failures++))
        fi
    done

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Oracle1-in-a-Box is deployed!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}PLATO:${NC}        http://localhost:${PLATO_PORT}"
    echo -e "  ${BLUE}Keeper:${NC}       http://localhost:${KEEPER_PORT}"
    echo -e "  ${BLUE}Data:${NC}         ${DATA_DIR}/"
    echo -e "  ${BLUE}CFP Room:${NC}     http://localhost:${PLATO_PORT}/room/cfp"
    echo -e "  ${BLUE}Briefings:${NC}    journalctl -u ${BRIEFING_TIMER}.service --since '1 hour ago'"
    echo ""
    echo -e "  ${YELLOW}Manage:${NC}"
    echo -e "    systemctl status ${PLATO_ROOM_SERVICE}     # PLATO server"
    echo -e "    systemctl status ${KEEPER_SERVICE}          # Keeper"
    echo -e "    systemctl list-timers ${PIPELINE_TIMER}     # Pipeline schedule"
    echo ""

    if [[ $failures -gt 0 ]]; then
        warn "Some services/timers may need attention. Check with: systemctl list-timers --all"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    echo ""
    echo -e "${GREEN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│               Oracle1-in-a-Box — Fleet Provisioner        │${NC}"
    echo -e "${GREEN}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    if ! command -v sudo &>/dev/null; then
        err "sudo is required but not installed."
        exit 1
    fi

    install_deps
    create_dirs
    clone_repo
    setup_venv
    install_systemd_services
    enable_and_start
    verify_and_summary
}

main "$@"
