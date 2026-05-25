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
#   - Systemd service      : skipped if already exists
#   - nginx CORS proxy     : skipped if already configured
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
MLFLOW_DIR="/home/apps/mlflow"
MLFLOW_INTERNAL_PORT=5002          # MLflow listens here (localhost only)
MLFLOW_PUBLIC_PORT=5001            # nginx exposes this to the network
MLFLOW_BACKEND="sqlite:///$MLFLOW_DIR/mlflow.db"
MLFLOW_ARTIFACTS="$MLFLOW_DIR/artifacts"
SERVICE_FILE="/etc/systemd/system/mlflow.service"
NGINX_CONF="/etc/nginx/conf.d/mlflow.conf"

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
log "AIStack dir      : $AISTACK_DIR"
log "Conda dir        : $CONDA_DIR"
log "MLflow dir       : $MLFLOW_DIR"
log "Internal port    : $MLFLOW_INTERNAL_PORT"
log "Public port      : $MLFLOW_PUBLIC_PORT (nginx + CORS)"
log "Backend store    : $MLFLOW_BACKEND"
log "Artifact store   : $MLFLOW_ARTIFACTS"

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
# STEP 3 — Systemd service (MLflow on localhost only)
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
    --host 127.0.0.1 \
    --port $MLFLOW_INTERNAL_PORT \
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
# STEP 4 — Install nginx
# =============================================================================
log "=== STEP 4: Installing nginx ==="

if command -v nginx &>/dev/null; then
    log_skip "nginx already installed ($(nginx -v 2>&1 | awk -F/ '{print $2}'))"
else
    log "Installing nginx via dnf..."
    if command -v dnf &>/dev/null; then
        dnf install -y nginx >> "$MLFLOW_LOG" 2>&1 \
            && log_ok "nginx installed" \
            || die "nginx installation failed — check $MLFLOW_LOG"
    elif command -v apt-get &>/dev/null; then
        apt-get install -y nginx >> "$MLFLOW_LOG" 2>&1 \
            && log_ok "nginx installed" \
            || die "nginx installation failed — check $MLFLOW_LOG"
    else
        die "No supported package manager found. Install nginx manually."
    fi
fi

# =============================================================================
# STEP 5 — nginx CORS reverse proxy config
# =============================================================================
log "=== STEP 5: nginx CORS reverse proxy ==="

if [[ -f "$NGINX_CONF" ]]; then
    log "Overwriting existing nginx config at $NGINX_CONF..."
fi

log "Writing nginx CORS config for MLflow..."
cat > "$NGINX_CONF" << EOF
server {
    listen $MLFLOW_PUBLIC_PORT;
    server_name _;

    location / {
        # ── Preflight OPTIONS ─────────────────────────────────────────────────
        if (\$request_method = OPTIONS) {
            add_header 'Access-Control-Allow-Origin'  '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH';
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, Origin, X-Requested-With';
            add_header 'Access-Control-Max-Age'       86400;
            add_header 'Content-Length'               0;
            return 204;
        }

        # ── CORS headers for all other requests ───────────────────────────────
        add_header 'Access-Control-Allow-Origin'  '*'                                                          always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS, PATCH'                    always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, Origin, X-Requested-With' always;

        # ── Proxy to MLflow ───────────────────────────────────────────────────
        proxy_pass         http://127.0.0.1:$MLFLOW_INTERNAL_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        # Strip Origin so MLflow's fastapi_security does not block the request.
        # nginx handles CORS for the browser; MLflow sees it as same-origin.
        proxy_set_header   Origin            "";
        proxy_read_timeout 300;
        proxy_buffering    off;
    }
}
EOF
log_ok "nginx CORS config written to $NGINX_CONF"

# Test config regardless of whether it was just written or already existed
log "Testing nginx config..."
if nginx -t >> "$MLFLOW_LOG" 2>&1; then
    log_ok "nginx config test passed"
else
    nginx -t
    die "nginx config test failed — check $MLFLOW_LOG"
fi

# Enable and ensure nginx is running (handles both fresh install and stopped service)
systemctl enable nginx >> "$MLFLOW_LOG" 2>&1 \
    && log_ok "nginx service enabled" \
    || log_err "Failed to enable nginx"

# ── SELinux: allow nginx to bind to non-standard port ────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    log "SELinux active — checking port $MLFLOW_PUBLIC_PORT label..."
    if command -v semanage &>/dev/null; then
        if semanage port -l 2>/dev/null | grep -q "^http_port_t.*${MLFLOW_PUBLIC_PORT}"; then
            log_skip "Port $MLFLOW_PUBLIC_PORT already labelled http_port_t"
        else
            log "Labelling port $MLFLOW_PUBLIC_PORT as http_port_t for SELinux..."
            semanage port -a -t http_port_t -p tcp "$MLFLOW_PUBLIC_PORT" >> "$MLFLOW_LOG" 2>&1 \
                && log_ok "SELinux port label added for $MLFLOW_PUBLIC_PORT" \
                || {
                    # Port might already exist under a different type — modify instead
                    semanage port -m -t http_port_t -p tcp "$MLFLOW_PUBLIC_PORT" >> "$MLFLOW_LOG" 2>&1 \
                        && log_ok "SELinux port label updated for $MLFLOW_PUBLIC_PORT" \
                        || log_err "semanage failed — install policycoreutils-python-utils and retry"
                }
        fi
    else
        log_err "semanage not found — install policycoreutils-python-utils to fix SELinux port binding"
        log_err "  dnf install -y policycoreutils-python-utils"
        log_err "  semanage port -a -t http_port_t -p tcp $MLFLOW_PUBLIC_PORT"
    fi
fi

# ── Check port is free before starting ───────────────────────────────────────
if ss -tlnp 2>/dev/null | grep -q ":${MLFLOW_PUBLIC_PORT} "; then
    log_err "Port $MLFLOW_PUBLIC_PORT is already in use:"
    ss -tlnp | grep ":${MLFLOW_PUBLIC_PORT} " | tee -a "$MLFLOW_LOG"
    die "Free port $MLFLOW_PUBLIC_PORT before starting nginx"
fi

if systemctl is-active --quiet nginx; then
    log "Reloading nginx to pick up config..."
    systemctl reload nginx >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "nginx reloaded" \
        || { log_err "nginx reload failed — attempting restart"; systemctl restart nginx >> "$MLFLOW_LOG" 2>&1; }
else
    log "nginx not running — starting..."
    systemctl start nginx >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "nginx started" \
        || {
            log_err "nginx failed to start — diagnostic output:"
            journalctl -u nginx -n 30 --no-pager | tee -a "$MLFLOW_LOG"
            grep nginx /var/log/audit/audit.log 2>/dev/null | tail -10 | tee -a "$MLFLOW_LOG"
            die "nginx start failed — see above for details"
        }
fi

# Open firewall port if firewalld is active
if systemctl is-active --quiet firewalld; then
    log "Opening port $MLFLOW_PUBLIC_PORT in firewalld..."
    firewall-cmd --permanent --add-port="${MLFLOW_PUBLIC_PORT}/tcp" >> "$MLFLOW_LOG" 2>&1 \
        && firewall-cmd --reload >> "$MLFLOW_LOG" 2>&1 \
        && log_ok "Firewall port $MLFLOW_PUBLIC_PORT opened" \
        || log_err "Failed to open firewall port — open manually: firewall-cmd --permanent --add-port=${MLFLOW_PUBLIC_PORT}/tcp"
fi

# =============================================================================
# STEP 6 — Verify server is up through nginx
# =============================================================================
log "=== STEP 6: Verifying MLflow via nginx ==="

# First confirm MLflow backend (port $MLFLOW_INTERNAL_PORT) is actually up
log "Waiting for MLflow backend on port $MLFLOW_INTERNAL_PORT..."
RETRIES=15
WAIT=2
MLFLOW_UP=0
for ((i=1; i<=RETRIES; i++)); do
    if curl -sf "http://127.0.0.1:$MLFLOW_INTERNAL_PORT/" &>/dev/null; then
        MLFLOW_UP=1
        break
    fi
    log "  attempt $i/$RETRIES — waiting ${WAIT}s..."
    sleep $WAIT
done

if [[ $MLFLOW_UP -eq 0 ]]; then
    log_err "MLflow backend not responding on port $MLFLOW_INTERNAL_PORT after $((RETRIES * WAIT))s"
    log_err "MLflow service status:"
    systemctl status mlflow --no-pager | tail -20 | tee -a "$MLFLOW_LOG"
    log_err "MLflow logs:"
    journalctl -u mlflow -n 30 --no-pager | tee -a "$MLFLOW_LOG"
    die "MLflow backend failed to start"
fi
log_ok "MLflow backend up on port $MLFLOW_INTERNAL_PORT"

# Now verify through nginx
if curl -sf "http://localhost:$MLFLOW_PUBLIC_PORT/" &>/dev/null; then
    log_ok "MLflow responding on port $MLFLOW_PUBLIC_PORT via nginx"
else
    log_err "nginx proxy not forwarding to MLflow — nginx status:"
    systemctl status nginx --no-pager | tail -10 | tee -a "$MLFLOW_LOG"
    log_err "Try: curl -v http://localhost:$MLFLOW_PUBLIC_PORT/"
    die "nginx not proxying to MLflow"
fi

# =============================================================================
# STEP 7 — Write MLFLOW_TRACKING_URI to /etc/profile.d
# =============================================================================
log "=== STEP 7: Exporting MLFLOW_TRACKING_URI system-wide ==="

PROFILE_SCRIPT="/etc/profile.d/mlflow.sh"
HOST_IP=$(hostname -I | awk '{print $1}')

if [[ -f "$PROFILE_SCRIPT" ]]; then
    log_skip "$PROFILE_SCRIPT already exists"
else
    cat > "$PROFILE_SCRIPT" << EOF
# MLflow tracking server — auto-generated by AIStack install_mlflow.sh
export MLFLOW_TRACKING_URI=http://${HOST_IP}:${MLFLOW_PUBLIC_PORT}
EOF
    log_ok "Written: $PROFILE_SCRIPT"
    log_ok "MLFLOW_TRACKING_URI=http://${HOST_IP}:${MLFLOW_PUBLIC_PORT}"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}              MLflow Server Installation Complete${NC}" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo    "  UI URL        : http://${HOST_IP}:${MLFLOW_PUBLIC_PORT}  (nginx + CORS)" | tee -a "$MLFLOW_LOG"
echo    "  Tracking URI  : http://${HOST_IP}:${MLFLOW_PUBLIC_PORT}" | tee -a "$MLFLOW_LOG"
echo    "  Backend store : $MLFLOW_BACKEND" | tee -a "$MLFLOW_LOG"
echo    "  Artifacts     : $MLFLOW_ARTIFACTS" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo    "  MLflow service : systemctl status mlflow" | tee -a "$MLFLOW_LOG"
echo    "  MLflow logs    : journalctl -u mlflow -f" | tee -a "$MLFLOW_LOG"
echo    "  nginx service  : systemctl status nginx" | tee -a "$MLFLOW_LOG"
echo    "  nginx logs     : journalctl -u nginx -f" | tee -a "$MLFLOW_LOG"
echo    "  Install log    : $MLFLOW_LOG" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}  ── Usage in Python ──${NC}" | tee -a "$MLFLOW_LOG"
echo    "    import mlflow" | tee -a "$MLFLOW_LOG"
echo    "    mlflow.set_tracking_uri('http://${HOST_IP}:${MLFLOW_PUBLIC_PORT}')" | tee -a "$MLFLOW_LOG"
echo    "    mlflow.set_experiment('my-experiment')" | tee -a "$MLFLOW_LOG"
echo    "    with mlflow.start_run():" | tee -a "$MLFLOW_LOG"
echo    "        mlflow.log_param('lr', 1e-4)" | tee -a "$MLFLOW_LOG"
echo    "        mlflow.log_metric('loss', 0.42)" | tee -a "$MLFLOW_LOG"
echo "" | tee -a "$MLFLOW_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$MLFLOW_LOG"