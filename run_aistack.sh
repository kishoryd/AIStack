#!/bin/bash
set -o pipefail

AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_USER="admin"
ADMIN_PASS="admin"
APPS_DIR="/home/apps"

# =============================================================================
# MUST RUN AS ROOT
# =============================================================================
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use: sudo bash run_aistack.sh)"
    exit 1
fi

echo "════════════════════════════════════════════════════════════"
echo "                    AIStack Setup"
echo "════════════════════════════════════════════════════════════"

# =============================================================================
# STEP 1 — Create admin user
# =============================================================================
if id "$ADMIN_USER" &>/dev/null; then
    echo "  ⊘ User '$ADMIN_USER' already exists — skipping"
else
    echo ">>> Creating user '$ADMIN_USER'..."
    useradd -m -s /bin/bash "$ADMIN_USER"
    echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
    echo "  ✔ User '$ADMIN_USER' created"
fi

# =============================================================================
# STEP 2 — Create /home/apps and assign to admin
# =============================================================================
if [[ -d "$APPS_DIR" ]]; then
    echo "  ⊘ $APPS_DIR already exists — skipping"
else
    echo ">>> Creating $APPS_DIR..."
    mkdir -p "$APPS_DIR"
    chown "${ADMIN_USER}:${ADMIN_USER}" "$APPS_DIR"
    chmod 755 "$APPS_DIR"
    echo "  ✔ $APPS_DIR created and owned by '$ADMIN_USER'"
fi

# Give admin read access to the AIStack repo dir
chmod o+rx "$AISTACK_DIR"

# =============================================================================
# STEP 3 — Install as admin
# =============================================================================
echo ""
echo ">>> Running installation as '$ADMIN_USER'..."
echo ""

runuser -l "$ADMIN_USER" -c "bash $AISTACK_DIR/install_aistack.sh"
INSTALL_EXIT=$?

if [[ $INSTALL_EXIT -ne 0 ]]; then
    echo ""
    echo "ERROR: Installation failed (exit code $INSTALL_EXIT). Aborting."
    exit $INSTALL_EXIT
fi

# =============================================================================
# STEP 4 — Test as admin
# =============================================================================
echo ""
echo ">>> Running tests as '$ADMIN_USER'..."
echo ""

runuser -l "$ADMIN_USER" -c "bash $AISTACK_DIR/test_aistack.sh"
TEST_EXIT=$?

# =============================================================================
# STEP 5 — Create modulefiles as root (requires sudo)
# =============================================================================
echo ""
echo ">>> Creating modulefiles as root..."
echo ""

bash "$AISTACK_DIR/create_modulefiles.sh"
MOD_EXIT=$?

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
echo "                       SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo "  Install      : $([ $INSTALL_EXIT -eq 0 ] && echo PASS || echo FAIL)"
echo "  Tests        : $([ $TEST_EXIT   -eq 0 ] && echo PASS || echo FAIL)"
echo "  Modulefiles  : $([ $MOD_EXIT    -eq 0 ] && echo PASS || echo FAIL)"
echo "════════════════════════════════════════════════════════════"

[[ $INSTALL_EXIT -ne 0 || $TEST_EXIT -ne 0 || $MOD_EXIT -ne 0 ]] && exit 1
exit 0
