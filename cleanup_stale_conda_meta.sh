#!/bin/bash
# =============================================================================
# Clean up stale conda-meta/*.json receipts that conda's own consistency
# check flags but fails to delete -- shows up as:
#
#   WARNING conda.gateways.disk.delete:unlink_or_rename_to_trash(...):
#   Could not remove or rename .../conda-meta/setuptools-83.0.0-....json.
#   Please remove this file manually (you may need to reboot to free file handles)
#
# Root cause: `conda create` installs setuptools/packaging/wheel into every
# new env; install_aistack.sh's later `pip install` steps then upgrade one
# of those as a build dependency of something else, without updating
# conda's own record. Conda notices the mismatch and tries to clean up its
# now-stale receipt on every `conda list`/`conda create`, but the delete
# itself fails -- likely a Lustre rename/unlink quirk on this cluster's
# /home mount, not a real permissions problem (owner, normal 644 perms, no
# lock held). Harmless but self-perpetuating: the same warning fires again
# on every subsequent conda command against that env until the file is
# removed directly.
#
# This script doesn't guess which files are stale -- it drives directly off
# conda's own warning output (`conda list` on each env) and rm -f's exactly
# what conda already identified but couldn't remove itself.
#
# Usage: bash cleanup_stale_conda_meta.sh [conda_dir]
#   (default conda_dir: /home/apps/miniconda)
# =============================================================================
set -uo pipefail

CONDA_DIR="${1:-/home/apps/miniconda}"

if [[ ! -d "$CONDA_DIR/envs" ]]; then
    echo "FATAL: $CONDA_DIR/envs not found." >&2
    exit 1
fi

TOTAL=0
for envdir in "$CONDA_DIR/envs"/*/; do
    env=$(basename "$envdir")

    # A removal can occasionally surface a second stale file on the next
    # pass (saw this with axolotl: setuptools AND packaging both stale) --
    # keep going per-env until a pass finds nothing left.
    for pass in 1 2 3; do
        stale=$("$CONDA_DIR/bin/conda" list -n "$env" 2>&1 >/dev/null \
            | grep -oP 'Could not remove or rename \K.*\.json(?=\.\s)')
        [[ -z "$stale" ]] && break

        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "  [$env] removing stale: $(basename "$f")"
            rm -f "$f"
            TOTAL=$((TOTAL + 1))
        done <<< "$stale"
    done
done

echo
echo "Removed $TOTAL stale conda-meta file(s)."
