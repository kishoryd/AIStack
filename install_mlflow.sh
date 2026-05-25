#!/bin/bash
# =============================================================================
# AIStack MLflow Server Installer
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash install_mlflow.sh
#
# IDEMPOTENT — safe to re-run:
#   - MLflow pip install   : skipped if already installed
#   - Data directory       : skipped if already exists
#   - Config file          : skipped if already exists
#   - Systemd service      : skipped if already exists
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
MLFLOW_DIR="/home/apps/mlflow"
MLFLOW_PORT=5000
MLFLOW_HOST="0.0.0.0"
MLFLOW_BACKEND="sqlite:///$MLFLOW_DIR/mlflow.db"
MLFLOW_ARTIFACTS="$MLFLOW_DIR/artifacts"
SERVICE_FILE="/etc/systemd/system/mlflow.service"

LOG_DIR="$AISTACK_DIR/logs"
MLFLOW_LOG="$LOG_DIR/mlflow_install.log"

mkdir -p "$LOG_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MLFLOW_LOG"; }
log_ok()   { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$MLFLOW_LOG"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$MLFLOW_LOG"; }
log_err()  { echo -e "  ${RED}✘${NC} $*" | tee -a "$MLFLOW_LOG"; }
die()      { echo -e "${RED}ERROR: $*${NC}" | tee -a "$MLFLOW_LOG"; exit 1; }

log "=== AIStack MLflow Server Installer — $(date) ==="
log "AIStack dir   : $AISTACK_DIR"
log "Conda dir     : $CONDA_DIR"
log "MLflow dir    : $MLFLOW_DIR"
log "Port          : $MLFLOW_PORT"
log "Backend store : $MLFLOW_BACKEND"
log "Artifact store: $MLFLOW_ARTIFACTS"

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────
if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
    die "Miniconda not found at $CONDA_DIR — run install_aistack.sh first"
fi

# =============================================================================
# STEP 1 — Install MLflow into conda base
# =============================================================================
log "=== STEP 1: Installing MLflow ==="

source "$CONDA_DIR/bin/activate"

if "$CONDA_DIR/bin/python" -c "import mlflow" &>/dev/null; then
    MLFLOW_VERSION=$("$CONDA_DIR/bin/mlflow" --version 2>/dev/null | awk '{print $NF}')
    log_skip "MLflow already installed ($MLFLOW_VERSION)"
else
    log "Installing mlflow and dependencies..."
    "$CONDA_DIR/bin/pip" install mlflow sqlalchemy psutil >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "MLflow installed" \
        || die "MLflow installation failed — check $MLFLOW_LOG"
fi

MLFLOW_BIN="$CONDA_DIR/bin/mlflow"
if [[ ! -x "$MLFLOW_BIN" ]]; then
    die "mlflow binary not found at $MLFLOW_BIN after install"
fi

# =============================================================================
# STEP 2 — Create MLflow directories
# =============================================================================
log "=== STEP 2: Creating MLflow directories ==="

if [[ -d "$MLFLOW_DIR" ]]; then
    log_skip "$MLFLOW_DIR already exists"
else
    mkdir -p "$MLFLOW_DIR" "$MLFLOW_ARTIFACTS"
    log_ok "Created $MLFLOW_DIR and $MLFLOW_ARTIFACTS"
fi

mkdir -p "$MLFLOW_ARTIFACTS"

# =============================================================================
# STEP 3 — Systemd service
# =============================================================================
log "=== STEP 3: systemd service ==="

if [[ -f "$SERVICE_FILE" ]]; then
    log_skip "Service file already exists at $SERVICE_FILE"
else
    log "Creating MLflow systemd service..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=MLflow Tracking Server
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$MLFLOW_DIR
ExecStart=$MLFLOW_BIN server \
    --host $MLFLOW_HOST \
    --port $MLFLOW_PORT \
    --backend-store-uri $MLFLOW_BACKEND \
    --default-artifact-root $MLFLOW_ARTIFACTS
Environment="PATH=$CONDA_DIR/bin:/usr/local/bin:/usr/bin:/bin"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    log_ok "Service file written to $SERVICE_FILE"

    systemctl daemon-reload >> "$MLFLOW_LOG" 2>&1

    systemctl enable mlflow >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "MLflow service enabled" \
        || log_err "Failed to enable MLflow service"

    systemctl start mlflow >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "MLflow service started" \
        || log_err "Failed to start MLflow — check: journalctl -u mlflow -f"
fi

# =============================================================================
# STEP 4 — Verify server is up
# =============================================================================
log "=== STEP 4: Verifying MLflow server ==="

sleep 3
if curl -sf "http://localhost:$MLFLOW_PORT/health" &>/dev/null; then
    log_ok "MLflow server responding on port $MLFLOW_PORT"
else
    log_err "MLflow server not responding — check: journalctl -u mlflow -f"
fi

# =============================================================================
# STEP 5 — Write MLFLOW_TRACKING_URI to /etc/profile.d
# =============================================================================
log "=== STEP 5: Exporting MLFLOW_TRACKING_URI system-wide ==="

PROFILE_SCRIPT="/etc/profile.d/mlflow.sh"
HOST_IP=$(hostname -I | awk '{print $1}')

if [[ -f "$PROFILE_SCRIPT" ]]; then
    log_skip "$PROFILE_SCRIPT already exists"
else
    cat > "$PROFILE_SCRIPT" << EOF
# MLflow tracking server — auto-generated by AIStack install_mlflow.sh
export MLFLOW_TRACKING_URI=http://${HOST_IP}:${MLFLOW_PORT}
EOF
    log_ok "Written: $PROFILE_SCRIPT"
    log_ok "MLFLOW_TRACKING_URI=http://${HOST_IP}:${MLFLOW_PORT}"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}              MLflow Server Installation Complete${NC}" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo    "  UI URL        : http://${HOST_IP}:${MLFLOW_PORT}" | tee -a "$MLFLOW_LOG"
echo    "  Tracking URI  : http://${HOST_IP}:${MLFLOW_PORT}" | tee -a "$MLFLOW_LOG"
echo    "  Backend store : $MLFLOW_BACKEND" | tee -a "$MLFLOW_LOG"
echo    "  Artifacts     : $MLFLOW_ARTIFACTS" | tee -a "$MLFLOW_LOG"
echo    "  Service       : systemctl status mlflow" | tee -a "$MLFLOW_LOG"
echo    "  Logs          : journalctl -u mlflow -f" | tee -a "$MLFLOW_LOG"
echo    "  Install log   : $MLFLOW_LOG" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}  ── Usage in Python ──${NC}" | tee -a "$MLFLOW_LOG"
echo    "    import mlflow" | tee -a "$MLFLOW_LOG"
echo    "    mlflow.set_tracking_uri('http://${HOST_IP}:${MLFLOW_PORT}')" | tee -a "$MLFLOW_LOG"
echo    "    mlflow.set_experiment('my-experiment')" | tee -a "$MLFLOW_LOG"
echo    "    with mlflow.start_run():" | tee -a "$MLFLOW_LOG"
echo    "        mlflow.log_param('lr', 1e-4)" | tee -a "$MLFLOW_LOG"
echo    "        mlflow.log_metric('loss', 0.42)" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"