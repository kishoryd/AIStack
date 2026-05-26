#!/bin/bash
# =============================================================================
# AIStack Docker Installer
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash install_docker.sh
#
# IDEMPOTENT — safe to re-run:
#   - Docker install        : skipped if already installed
#   - Docker service        : skipped if already running
#   - NVIDIA toolkit        : skipped if already installed
#   - admin docker group    : skipped if already member
# =============================================================================

set -o pipefail

AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_USER="admin"
LOG_DIR="$AISTACK_DIR/logs"
DOCKER_LOG="$LOG_DIR/docker_install.log"

mkdir -p "$LOG_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$DOCKER_LOG"; }
log_ok()   { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$DOCKER_LOG"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$DOCKER_LOG"; }
log_err()  { echo -e "  ${RED}✘${NC} $*" | tee -a "$DOCKER_LOG"; }
die()      { echo -e "${RED}ERROR: $*${NC}" | tee -a "$DOCKER_LOG"; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
    die "Run as root — sudo bash install_docker.sh"
fi

# Detect package manager
if command -v dnf &>/dev/null; then
    PKG="dnf"
elif command -v apt-get &>/dev/null; then
    PKG="apt"
else
    die "No supported package manager found (dnf or apt-get required)"
fi

log "=== AIStack Docker Installer — $(date) ==="
log "Package manager : $PKG"
log "Admin user      : $ADMIN_USER"

# =============================================================================
# STEP 1 — Install Docker
# =============================================================================
log "=== STEP 1: Installing Docker ==="

if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    log_skip "Docker already installed ($DOCKER_VER)"
else
    if [[ "$PKG" == "dnf" ]]; then
        log "Adding Docker repo..."
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo \
            >> "$DOCKER_LOG" 2>&1 \
            && log_ok "Docker repo added" \
            || die "Failed to add Docker repo"

        log "Installing Docker CE..."
        dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin \
            >> "$DOCKER_LOG" 2>&1 \
            && log_ok "Docker CE installed" \
            || die "Docker installation failed — check $DOCKER_LOG"

    elif [[ "$PKG" == "apt" ]]; then
        log "Installing prerequisites..."
        apt-get install -y ca-certificates curl gnupg lsb-release \
            >> "$DOCKER_LOG" 2>&1

        log "Adding Docker GPG key and repo..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg >> "$DOCKER_LOG" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) \
            signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update >> "$DOCKER_LOG" 2>&1
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin \
            >> "$DOCKER_LOG" 2>&1 \
            && log_ok "Docker CE installed" \
            || die "Docker installation failed — check $DOCKER_LOG"
    fi
fi

# =============================================================================
# STEP 2 — Start and enable Docker service
# =============================================================================
log "=== STEP 2: Docker service ==="

if systemctl is-active --quiet docker; then
    log_skip "Docker service already running"
else
    log "Starting Docker service..."
    systemctl start docker >> "$DOCKER_LOG" 2>&1 \
        && log_ok "Docker service started" \
        || die "Failed to start Docker — check: journalctl -u docker -f"
fi

if systemctl is-enabled --quiet docker; then
    log_skip "Docker service already enabled"
else
    systemctl enable docker >> "$DOCKER_LOG" 2>&1 \
        && log_ok "Docker service enabled on boot" \
        || log_err "Failed to enable Docker service"
fi

# =============================================================================
# STEP 3 — NVIDIA Container Toolkit
# =============================================================================
log "=== STEP 3: NVIDIA Container Toolkit ==="

# Check if NVIDIA GPU is present
if ! command -v nvidia-smi &>/dev/null; then
    log_skip "nvidia-smi not found — skipping NVIDIA Container Toolkit"
else
    GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    log "GPU detected: $GPU_INFO"

    if command -v nvidia-container-toolkit &>/dev/null || \
       rpm -q nvidia-container-toolkit &>/dev/null 2>/dev/null || \
       dpkg -l nvidia-container-toolkit &>/dev/null 2>/dev/null; then
        log_skip "NVIDIA Container Toolkit already installed"
    else
        if [[ "$PKG" == "dnf" ]]; then
            log "Adding NVIDIA Container Toolkit repo..."
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
                >> "$DOCKER_LOG" 2>&1

            curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                > /etc/yum.repos.d/nvidia-container-toolkit.repo \
                && log_ok "NVIDIA repo added" \
                || die "Failed to add NVIDIA repo"

            dnf install -y nvidia-container-toolkit >> "$DOCKER_LOG" 2>&1 \
                && log_ok "NVIDIA Container Toolkit installed" \
                || die "NVIDIA Container Toolkit installation failed — check $DOCKER_LOG"

        elif [[ "$PKG" == "apt" ]]; then
            log "Adding NVIDIA Container Toolkit repo..."
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
                >> "$DOCKER_LOG" 2>&1

            curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                > /etc/apt/sources.list.d/nvidia-container-toolkit.list

            apt-get update >> "$DOCKER_LOG" 2>&1
            apt-get install -y nvidia-container-toolkit >> "$DOCKER_LOG" 2>&1 \
                && log_ok "NVIDIA Container Toolkit installed" \
                || die "NVIDIA Container Toolkit installation failed — check $DOCKER_LOG"
        fi
    fi

    # Configure Docker to use NVIDIA runtime
    log "Configuring Docker NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker >> "$DOCKER_LOG" 2>&1 \
        && log_ok "NVIDIA runtime configured for Docker" \
        || log_err "Failed to configure NVIDIA runtime"

    # Restart Docker to apply runtime config
    log "Restarting Docker to apply NVIDIA runtime..."
    systemctl restart docker >> "$DOCKER_LOG" 2>&1 \
        && log_ok "Docker restarted" \
        || log_err "Failed to restart Docker"

    # Quick GPU test inside Docker
    log "Testing NVIDIA GPU inside Docker..."
    if docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu20.04 \
        nvidia-smi >> "$DOCKER_LOG" 2>&1; then
        log_ok "GPU accessible inside Docker containers"
    else
        log_err "GPU test failed — check: docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu20.04 nvidia-smi"
    fi
fi

# =============================================================================
# STEP 4 — Add admin user to docker group
# =============================================================================
log "=== STEP 4: Adding '$ADMIN_USER' to docker group ==="

if ! id "$ADMIN_USER" &>/dev/null; then
    log_err "User '$ADMIN_USER' does not exist — skipping"
else
    if id -nG "$ADMIN_USER" | grep -qw docker; then
        log_skip "'$ADMIN_USER' already in docker group"
    else
        usermod -aG docker "$ADMIN_USER" >> "$DOCKER_LOG" 2>&1 \
            && log_ok "'$ADMIN_USER' added to docker group" \
            || log_err "Failed to add '$ADMIN_USER' to docker group"
    fi
fi

# =============================================================================
# STEP 5 — Verify Docker
# =============================================================================
log "=== STEP 5: Verifying Docker ==="

if docker info &>/dev/null; then
    DOCKER_VER=$(docker --version)
    log_ok "$DOCKER_VER"
else
    log_err "Docker not responding — check: systemctl status docker"
fi

# =============================================================================
# SUMMARY
# =============================================================================
HOST_IP=$(hostname -I | awk '{print $1}')

echo "" | tee -a "$DOCKER_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$DOCKER_LOG"
echo -e "${BOLD}               Docker Installation Complete${NC}" | tee -a "$DOCKER_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$DOCKER_LOG"
echo "" | tee -a "$DOCKER_LOG"
echo    "  Docker         : $(docker --version 2>/dev/null)" | tee -a "$DOCKER_LOG"
echo    "  Service        : systemctl status docker" | tee -a "$DOCKER_LOG"
echo    "  Admin user     : $ADMIN_USER added to docker group" | tee -a "$DOCKER_LOG"
echo    "  Install log    : $DOCKER_LOG" | tee -a "$DOCKER_LOG"
echo "" | tee -a "$DOCKER_LOG"
if command -v nvidia-container-toolkit &>/dev/null || \
   rpm -q nvidia-container-toolkit &>/dev/null 2>/dev/null; then
    echo    "  NVIDIA toolkit : installed" | tee -a "$DOCKER_LOG"
    echo    "  GPU test       : docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu20.04 nvidia-smi" | tee -a "$DOCKER_LOG"
    echo "" | tee -a "$DOCKER_LOG"
fi
echo -e "${BOLD}  ── NOTE ──${NC}" | tee -a "$DOCKER_LOG"
echo    "  '$ADMIN_USER' must log out and back in for docker group to take effect" | tee -a "$DOCKER_LOG"
echo    "  Or run: newgrp docker" | tee -a "$DOCKER_LOG"
echo "" | tee -a "$DOCKER_LOG"
echo -e "${BOLD}  ── Quick commands ──${NC}" | tee -a "$DOCKER_LOG"
echo    "    docker ps                        # list running containers" | tee -a "$DOCKER_LOG"
echo    "    docker images                    # list images" | tee -a "$DOCKER_LOG"
echo    "    docker run --gpus all ...        # run with GPU" | tee -a "$DOCKER_LOG"
echo    "    docker compose up -d             # start compose stack" | tee -a "$DOCKER_LOG"
echo "" | tee -a "$DOCKER_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$DOCKER_LOG"