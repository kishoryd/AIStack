#!/bin/bash
# =============================================================================
# AIStack JupyterHub Uninstaller
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash uninstall_jupyterhub.sh
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="$AISTACK_DIR/miniconda3"
JUPYTERHUB_DIR="/usr/local/jupyterhub"
CONFIG_FILE="$JUPYTERHUB_DIR/jupyterhub_config.py"
SERVICE_FILE="/etc/systemd/system/jupyterhub.service"

JUPYTERHUB_VERSION="4.1.0"
JUPYTERHUB_TARBALL="/tmp/jupyterhub-${JUPYTERHUB_VERSION}.tar.gz"

LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/jupyterhub_uninstall.log"

mkdir -p "$LOG_DIR"

log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok()  { echo "  ✔ $*" | tee -a "$SUMMARY_LOG"; }
log_skip(){ echo "  ⊘ $*" | tee -a "$SUMMARY_LOG"; }
log_err() { echo "  ✘ $*" | tee -a "$SUMMARY_LOG"; }

log "=== AIStack JupyterHub Uninstaller — $(date) ==="

# =============================================================================
# STEP 1 — Stop and disable systemd service
# =============================================================================
log "=== STEP 1: systemd service ==="

if systemctl is-active --quiet jupyterhub; then
    log "Stopping JupyterHub service..."
    systemctl stop jupyterhub >> "$LOG_DIR/jupyterhub_uninstall.log" 2>&1 \
        && log_ok "Service stopped" \
        || log_err "Failed to stop service"
else
    log_skip "Service not running"
fi

if systemctl is-enabled --quiet jupyterhub 2>/dev/null; then
    systemctl disable jupyterhub >> "$LOG_DIR/jupyterhub_uninstall.log" 2>&1 \
        && log_ok "Service disabled" \
        || log_err "Failed to disable service"
fi

if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE" \
        && log_ok "Service file removed: $SERVICE_FILE" \
        || log_err "Failed to remove $SERVICE_FILE"
else
    log_skip "Service file not found"
fi

systemctl daemon-reload >> "$LOG_DIR/jupyterhub_uninstall.log" 2>&1
log_ok "systemd reloaded"

# =============================================================================
# STEP 2 — Uninstall JupyterHub from conda base
# =============================================================================
log "=== STEP 2: pip uninstall ==="

if [[ -f "$CONDA_DIR/bin/pip" ]]; then
    if "$CONDA_DIR/bin/python" -c "import jupyterhub" &>/dev/null; then
        log "Uninstalling JupyterHub and JupyterLab from conda base..."
        "$CONDA_DIR/bin/pip" uninstall -y jupyterhub jupyterlab \
            >> "$LOG_DIR/jupyterhub_uninstall.log" 2>&1 \
            && log_ok "JupyterHub and JupyterLab uninstalled" \
            || log_err "pip uninstall failed — check $LOG_DIR/jupyterhub_uninstall.log"
    else
        log_skip "JupyterHub not installed in conda base"
    fi
else
    log_skip "Conda not found at $CONDA_DIR — skipping pip uninstall"
fi

# =============================================================================
# STEP 3 — Remove JupyterHub directory and config
# =============================================================================
log "=== STEP 3: JupyterHub directory ==="

if [[ -d "$JUPYTERHUB_DIR" ]]; then
    rm -rf "$JUPYTERHUB_DIR" \
        && log_ok "Removed $JUPYTERHUB_DIR" \
        || log_err "Failed to remove $JUPYTERHUB_DIR"
else
    log_skip "$JUPYTERHUB_DIR not found"
fi

# =============================================================================
# STEP 4 — Remove downloaded tarball
# =============================================================================
log "=== STEP 4: tarball cleanup ==="

if [[ -f "$JUPYTERHUB_TARBALL" ]]; then
    rm -f "$JUPYTERHUB_TARBALL" \
        && log_ok "Removed $JUPYTERHUB_TARBALL" \
        || log_err "Failed to remove $JUPYTERHUB_TARBALL"
else
    log_skip "Tarball not found"
fi

# =============================================================================
# STEP 5 — Remove registered kernels from all conda envs
# =============================================================================
log "=== STEP 5: Kernel cleanup ==="

if [[ -f "$CONDA_DIR/bin/conda" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^# || "$line" =~ ^base || -z "$line" ]] && continue

        env=$(echo "$line" | awk '{print $1}')
        kernel_dir="$CONDA_DIR/envs/$env/share/jupyter/kernels/$env"

        if [[ -d "$kernel_dir" ]]; then
            rm -rf "$kernel_dir" \
                && log_ok "Kernel '$env' removed" \
                || log_err "Failed to remove kernel '$env'"
        else
            log_skip "Kernel '$env' not found"
        fi
    done < <("$CONDA_DIR/bin/conda" env list)
else
    log_skip "Conda not found — skipping kernel cleanup"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
echo "            JupyterHub Uninstall Complete"
echo "════════════════════════════════════════════════════════════"
echo "  Log : $SUMMARY_LOG"
echo "════════════════════════════════════════════════════════════"
