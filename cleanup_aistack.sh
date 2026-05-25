#!/bin/bash
# =============================================================================
# AIStack Cleanup
# =============================================================================
# Usage:
#   sudo bash /home/apps/AIStack/cleanup_aistack.sh
#
# What this removes:
#   1. Shell history for root and admin
#   2. AIStack logs directory
#   3. AIStack repo itself (self-deletes)
# =============================================================================

set -o pipefail

AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_USER="admin"
LOG_DIR="$AISTACK_DIR/logs"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*"; }
log_err()  { echo -e "  ${RED}✘${NC} $*"; }

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run as root — sudo bash cleanup_aistack.sh"
    exit 1
fi

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                     AIStack Cleanup${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}This will permanently delete:${NC}"
echo    "    • Shell history (root + $ADMIN_USER)"
echo    "    • Logs : $LOG_DIR"
echo    "    • Repo : /root/AIStack (if exists)"
echo    "    • Repo : /home/apps/AIStack (if exists)"
echo ""
read -r -p "  Are you sure? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
fi
echo ""

# =============================================================================
# STEP 1 — Clear shell history
# =============================================================================
echo ">>> STEP 1: Clearing shell history"

# root
for f in /root/.bash_history /root/.zsh_history /root/.sh_history; do
    if [[ -f "$f" ]]; then
        cat /dev/null > "$f"
        log_ok "Cleared $f"
    else
        log_skip "$f not found"
    fi
done
history -c 2>/dev/null || true

# admin user
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
if [[ -n "$ADMIN_HOME" ]]; then
    for f in "$ADMIN_HOME/.bash_history" "$ADMIN_HOME/.zsh_history" "$ADMIN_HOME/.sh_history"; do
        if [[ -f "$f" ]]; then
            cat /dev/null > "$f"
            log_ok "Cleared $f"
        else
            log_skip "$f not found"
        fi
    done
else
    log_skip "User '$ADMIN_USER' not found — skipping"
fi

# =============================================================================
# STEP 2 — Remove logs
# =============================================================================
echo ""
echo ">>> STEP 2: Removing logs"

if [[ -d "$LOG_DIR" ]]; then
    rm -rf "$LOG_DIR"
    log_ok "Removed $LOG_DIR"
else
    log_skip "$LOG_DIR not found"
fi

# =============================================================================
# STEP 3 — Remove AIStack repos (both /root and /home/apps locations)
# =============================================================================
echo ""
echo ">>> STEP 3: Removing AIStack repos"

REPO_LOCATIONS=(
    "/root/AIStack"
    "/home/apps/AIStack"
)

# Also include wherever this script is running from (in case it's elsewhere)
if [[ "$AISTACK_DIR" != "/root/AIStack" && "$AISTACK_DIR" != "/home/apps/AIStack" ]]; then
    REPO_LOCATIONS+=("$AISTACK_DIR")
fi

# Build the delete commands for background execution
DELETE_CMDS=""
for repo in "${REPO_LOCATIONS[@]}"; do
    if [[ -d "$repo" ]]; then
        echo "  Queued for removal: $repo"
        DELETE_CMDS+="rm -rf \"$repo\" && echo -e '  \033[0;32m✔\033[0m Removed $repo' || echo -e '  \033[0;31m✘\033[0m Failed to remove $repo';"
    else
        log_skip "$repo not found"
    fi
done

# Self-delete runs in background after script exits
TMP_SCRIPT=$(mktemp /tmp/aistack_cleanup_XXXXXX.sh)
cat > "$TMP_SCRIPT" << HEREDOC
#!/bin/bash
sleep 1
$DELETE_CMDS
rm -f "$TMP_SCRIPT"
HEREDOC

chmod +x "$TMP_SCRIPT"
bash "$TMP_SCRIPT" &

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                    Cleanup Complete${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  History : cleared"
echo "  Logs    : removed"
echo "  Repos   : removing in background..."
echo ""