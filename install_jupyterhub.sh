#!/bin/bash
# =============================================================================
# AIStack JupyterHub Installer
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash install_jupyterhub.sh
#
# IDEMPOTENT — safe to re-run:
#   - Node.js / configurable-http-proxy : skipped if already installed
#   - JupyterHub pip install            : skipped if already installed
#   - Config file                       : skipped if already exists
#   - Systemd service                   : skipped if already exists
#   - Kernel registration               : skipped per-env if already registered
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
JUPYTERHUB_DIR="/home/apps/jupyterhub"
CONFIG_FILE="$JUPYTERHUB_DIR/jupyterhub_config.py"
SERVICE_FILE="/etc/systemd/system/jupyterhub.service"

JUPYTERHUB_VERSION="4.1.0"
JUPYTERHUB_URL="https://github.com/jupyterhub/jupyterhub/archive/refs/tags/${JUPYTERHUB_VERSION}.tar.gz"
JUPYTERHUB_TARBALL="/tmp/jupyterhub-${JUPYTERHUB_VERSION}.tar.gz"
JUPYTERHUB_SRC="/tmp/jupyterhub-${JUPYTERHUB_VERSION}"

LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/jupyterhub_install.log"

mkdir -p "$LOG_DIR"

log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok()  { echo "  ✔ $*" | tee -a "$SUMMARY_LOG"; }
log_skip(){ echo "  ⊘ $*" | tee -a "$SUMMARY_LOG"; }
log_err() { echo "  ✘ $*" | tee -a "$SUMMARY_LOG"; }

log "=== AIStack JupyterHub Installer — $(date) ==="
log "AIStack dir    : $AISTACK_DIR"
log "Conda dir      : $CONDA_DIR"
log "JupyterHub dir : $JUPYTERHUB_DIR"

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────
if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
    log_err "Miniconda not found at $CONDA_DIR — run install_aistack.sh first"
    exit 1
fi

# =============================================================================
# STEP 1 — Node.js + configurable-http-proxy
# =============================================================================
log "=== STEP 1: Node.js & configurable-http-proxy ==="

if command -v node &>/dev/null; then
    log_skip "Node.js already installed ($(node --version))"
else
    log "Installing Node.js and npm via dnf..."
    dnf install -y nodejs npm >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "Node.js $(node --version) installed" \
        || { log_err "Node.js install failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }
fi

if command -v configurable-http-proxy &>/dev/null; then
    log_skip "configurable-http-proxy already installed"
else
    log "Installing configurable-http-proxy..."
    npm install -g configurable-http-proxy@4.6.3 >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "configurable-http-proxy installed" \
        || { log_err "configurable-http-proxy install failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }
fi

# =============================================================================
# STEP 2 — JupyterHub in conda base
# =============================================================================
log "=== STEP 2: JupyterHub install (v${JUPYTERHUB_VERSION}) ==="

source "$CONDA_DIR/bin/activate"

if "$CONDA_DIR/bin/python" -c "import jupyterhub" &>/dev/null; then
    log_skip "JupyterHub already installed in conda base"
else
    # Download tarball
    if [[ ! -f "$JUPYTERHUB_TARBALL" ]]; then
        log "Downloading JupyterHub ${JUPYTERHUB_VERSION} from GitHub..."
        wget -q "$JUPYTERHUB_URL" -O "$JUPYTERHUB_TARBALL" \
            >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
            && log_ok "Tarball downloaded to $JUPYTERHUB_TARBALL" \
            || { log_err "Download failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }
    else
        log_skip "Tarball already at $JUPYTERHUB_TARBALL"
    fi

    # Extract
    log "Extracting JupyterHub source..."
    tar -xzf "$JUPYTERHUB_TARBALL" -C /tmp \
        >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "Source extracted to $JUPYTERHUB_SRC" \
        || { log_err "Extraction failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }

    # Install from source
    log "Installing JupyterHub from source..."
    "$CONDA_DIR/bin/pip" install "$JUPYTERHUB_SRC" jupyterlab \
        >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "JupyterHub ${JUPYTERHUB_VERSION} installed" \
        || { log_err "JupyterHub install failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }

    # Cleanup source tree (keep tarball for idempotency check)
    rm -rf "$JUPYTERHUB_SRC"
fi

# =============================================================================
# STEP 3 — SELinux context for miniconda binaries
# =============================================================================
log "=== STEP 3: SELinux context ==="

if command -v chcon &>/dev/null; then
    chcon -R -t bin_t "$CONDA_DIR/bin/" \
        >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "SELinux bin_t context applied to $CONDA_DIR/bin/" \
        || log_err "chcon failed — SELinux may block JupyterHub execution"
else
    log_skip "chcon not available — skipping SELinux context step"
fi

# =============================================================================
# STEP 4 — JupyterHub directory & config
# =============================================================================
log "=== STEP 4: JupyterHub config ==="

mkdir -p "$JUPYTERHUB_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    log_skip "Config already exists at $CONFIG_FILE"
else
    log "Generating JupyterHub config..."
    cd "$JUPYTERHUB_DIR"
    "$CONDA_DIR/bin/jupyterhub" --generate-config \
        >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "Config generated" \
        || { log_err "Config generation failed — check $LOG_DIR/jupyterhub_install.log"; exit 1; }

    log "Writing AIStack settings to config..."
    cat >> "$CONFIG_FILE" << PYEOF

# ── AIStack JupyterHub settings ──────────────────────────────────────────────
c = get_config()  # noqa
c.JupyterHub.bind_url     = 'http://0.0.0.0:8000'
c.Authenticator.allow_all = True
PYEOF
    log_ok "Config updated"
fi

# =============================================================================
# STEP 5 — Systemd service
# =============================================================================
log "=== STEP 5: systemd service ==="

if [[ -f "$SERVICE_FILE" ]]; then
    log_skip "Service file already exists at $SERVICE_FILE"
else
    log "Creating JupyterHub systemd service..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=JupyterHub Service
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$JUPYTERHUB_DIR
ExecStart=$CONDA_DIR/bin/jupyterhub -f $CONFIG_FILE
Environment="PATH=$CONDA_DIR/bin:/usr/local/bin:/usr/bin:/bin"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    log_ok "Service file written"

    systemctl daemon-reload >> "$LOG_DIR/jupyterhub_install.log" 2>&1

    systemctl enable jupyterhub >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "JupyterHub service enabled" \
        || log_err "Failed to enable JupyterHub service"

    systemctl start jupyterhub >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
        && log_ok "JupyterHub service started" \
        || log_err "Failed to start JupyterHub — check: journalctl -u jupyterhub -f"
fi

# =============================================================================
# STEP 6 — Register kernels for all AIStack conda envs
# =============================================================================
log "=== STEP 6: Kernel registration ==="

while IFS= read -r line; do
    [[ "$line" =~ ^# || "$line" =~ ^base || -z "$line" ]] && continue

    env=$(echo "$line" | awk '{print $1}')
    env_python="$CONDA_DIR/envs/$env/bin/python"

    if [[ ! -x "$env_python" ]]; then
        log_skip "No python found in env '$env' — skipping"
        continue
    fi

    kernel_dir="$CONDA_DIR/share/jupyter/kernels/$env"
    if [[ -d "$kernel_dir" ]]; then
        log_skip "Kernel '$env' already registered"
    else
        log "Registering kernel for '$env'..."
        "$env_python" -m ipykernel install \
            --prefix "$CONDA_DIR" --name "$env" --display-name "$env" \
            >> "$LOG_DIR/jupyterhub_install.log" 2>&1 \
            && log_ok "Kernel '$env' registered" \
            || log_err "Kernel '$env' registration failed"
    fi
done < <("$CONDA_DIR/bin/conda" env list)

# =============================================================================
# SUMMARY
# =============================================================================
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "════════════════════════════════════════════════════════════"
echo "            JupyterHub Installation Complete"
echo "════════════════════════════════════════════════════════════"
echo "  URL         : http://$HOST_IP:8000"
echo "  Config      : $CONFIG_FILE"
echo "  Service     : systemctl status jupyterhub"
echo "  Logs        : journalctl -u jupyterhub -f"
echo "  Install log : $SUMMARY_LOG"
echo "════════════════════════════════════════════════════════════"
