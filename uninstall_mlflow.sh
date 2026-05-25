#!/bin/bash
# =============================================================================
# AIStack MLflow Uninstaller
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash uninstall_mlflow.sh
#
# What this removes:
#   - mlflow systemd service
#   - nginx MLflow config (does NOT remove nginx itself)
#   - mlflow pip package from conda base
#   - /home/apps/mlflow directory (db + artifacts)
#   - /etc/profile.d/mlflow.sh
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
MLFLOW_ENV="mlflow"
MLFLOW_ENV_PREFIX="$CONDA_DIR/envs/$MLFLOW_ENV"
MLFLOW_DIR="/home/apps/mlflow"
MLFLOW_PUBLIC_PORT=5001
SERVICE_FILE="/etc/systemd/system/mlflow.service"
NGINX_CONF="/etc/nginx/conf.d/mlflow.conf"
PROFILE_SCRIPT="/etc/profile.d/mlflow.sh"

LOG_DIR="$AISTACK_DIR/logs"
UNINSTALL_LOG="$LOG_DIR/mlflow_uninstall.log"

mkdir -p "$LOG_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$UNINSTALL_LOG"; }
log_ok()   { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$UNINSTALL_LOG"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$UNINSTALL_LOG"; }
log_err()  { echo -e "  ${RED}✘${NC} $*" | tee -a "$UNINSTALL_LOG"; }

log "=== AIStack MLflow Uninstaller — $(date) ==="

# =============================================================================
# STEP 1 — Stop and remove mlflow systemd service
# =============================================================================
log "=== STEP 1: mlflow systemd service ==="

if systemctl is-active --quiet mlflow; then
    log "Stopping mlflow service..."
    systemctl stop mlflow >> "$UNINSTALL_LOG" 2>&1 \
        && log_ok "mlflow service stopped" \
        || log_err "Failed to stop mlflow service"
else
    log_skip "mlflow service not running"
fi

if systemctl is-enabled --quiet mlflow 2>/dev/null; then
    systemctl disable mlflow >> "$UNINSTALL_LOG" 2>&1 \
        && log_ok "mlflow service disabled" \
        || log_err "Failed to disable mlflow service"
fi

if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE" \
        && log_ok "Removed $SERVICE_FILE" \
        || log_err "Failed to remove $SERVICE_FILE"
else
    log_skip "Service file not found"
fi

systemctl daemon-reload >> "$UNINSTALL_LOG" 2>&1
log_ok "systemd reloaded"

# =============================================================================
# STEP 2 — Remove nginx MLflow config and reload nginx
# =============================================================================
log "=== STEP 2: nginx config ==="

if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF" \
        && log_ok "Removed $NGINX_CONF" \
        || log_err "Failed to remove $NGINX_CONF"

    if systemctl is-active --quiet nginx; then
        if nginx -t >> "$UNINSTALL_LOG" 2>&1; then
            systemctl reload nginx >> "$UNINSTALL_LOG" 2>&1 \
                && log_ok "nginx reloaded" \
                || log_err "nginx reload failed"
        else
            log_err "nginx config invalid after removal — check nginx configs manually"
        fi
    else
        log_skip "nginx not running — skipping reload"
    fi
else
    log_skip "nginx MLflow config not found at $NGINX_CONF"
fi

# Close firewall port if firewalld is active
if systemctl is-active --quiet firewalld; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "${MLFLOW_PUBLIC_PORT}/tcp"; then
        log "Closing firewall port $MLFLOW_PUBLIC_PORT..."
        firewall-cmd --permanent --remove-port="${MLFLOW_PUBLIC_PORT}/tcp" >> "$UNINSTALL_LOG" 2>&1 \
            && firewall-cmd --reload >> "$UNINSTALL_LOG" 2>&1 \
            && log_ok "Firewall port $MLFLOW_PUBLIC_PORT closed" \
            || log_err "Failed to close firewall port"
    else
        log_skip "Firewall port $MLFLOW_PUBLIC_PORT not open"
    fi
fi

# =============================================================================
# STEP 3 — Remove mlflow conda env
# =============================================================================
log "=== STEP 3: conda env '$MLFLOW_ENV' ==="

if [[ -d "$MLFLOW_ENV_PREFIX" ]]; then
    log "Removing conda env '$MLFLOW_ENV'..."
    "$CONDA_DIR/bin/conda" remove -y --name "$MLFLOW_ENV" --all >> "$UNINSTALL_LOG" 2>&1 \
        && log_ok "Conda env '$MLFLOW_ENV' removed" \
        || log_err "Failed to remove conda env — check $UNINSTALL_LOG"
else
    log_skip "Conda env '$MLFLOW_ENV' not found at $MLFLOW_ENV_PREFIX"
fi

# =============================================================================
# STEP 4 — Remove MLflow data directory
# =============================================================================
log "=== STEP 4: MLflow data directory ==="

if [[ -d "$MLFLOW_DIR" ]]; then
    echo -e "  ${YELLOW}WARNING: This will delete all MLflow runs, metrics, and artifacts in $MLFLOW_DIR${NC}"
    read -r -p "  Delete $MLFLOW_DIR? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$MLFLOW_DIR" \
            && log_ok "Removed $MLFLOW_DIR" \
            || log_err "Failed to remove $MLFLOW_DIR"
    else
        log_skip "Skipped — $MLFLOW_DIR kept (delete manually if needed)"
    fi
else
    log_skip "$MLFLOW_DIR not found"
fi

# =============================================================================
# STEP 5 — Remove /etc/profile.d/mlflow.sh
# =============================================================================
log "=== STEP 5: profile.d cleanup ==="

if [[ -f "$PROFILE_SCRIPT" ]]; then
    rm -f "$PROFILE_SCRIPT" \
        && log_ok "Removed $PROFILE_SCRIPT" \
        || log_err "Failed to remove $PROFILE_SCRIPT"
else
    log_skip "$PROFILE_SCRIPT not found"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo "" | tee -a "$UNINSTALL_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$UNINSTALL_LOG"
echo -e "${BOLD}                  MLflow Uninstall Complete${NC}" | tee -a "$UNINSTALL_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"
echo    "  Note: nginx itself was NOT removed (only the MLflow vhost config)" | tee -a "$UNINSTALL_LOG"
echo    "  Log : $UNINSTALL_LOG" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$UNINSTALL_LOG"