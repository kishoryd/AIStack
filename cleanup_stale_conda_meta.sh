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
# Not AIStack-specific: any conda base on this cluster where envs mix
# conda-installed and pip-installed packages can hit this (e.g. the MLDL
# conda base has the same pattern). Point it at either:
#
#   bash cleanup_stale_conda_meta.sh                              # AIStack (default)
#   bash cleanup_stale_conda_meta.sh /home/apps/MLDL/DL-CondaPy3.10  # MLDL
#
# Needs write access to the target conda base's envs (cdacapp01 owns both).
# =============================================================================
set -uo pipefail

CONDA_DIR="${1:-/home/apps/miniconda}"

if [[ ! -d "$CONDA_DIR/envs" ]]; then
    echo "FATAL: $CONDA_DIR/envs not found." >&2
    exit 1
fi

REMOVED=0
FAILED=0
for envdir in "$CONDA_DIR/envs"/*/; do
    env=$(basename "$envdir")

    # A removal can occasionally surface a second stale file on the next
    # pass (saw this with axolotl: setuptools AND packaging both stale) --
    # keep going per-env until a pass finds nothing left.
    for pass in 1 2 3; do
        stale=$("$CONDA_DIR/bin/conda" list -n "$env" 2>&1 >/dev/null \
            | grep -oP 'Could not remove or rename \K.*\.json(?=\.\s)')
        [[ -z "$stale" ]] && break

        removed_this_pass=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
                echo "  [$env] removed: $(basename "$f")"
                REMOVED=$((REMOVED + 1))
                removed_this_pass=1
            else
                echo "  [$env] FAILED to remove: $(basename "$f")"
                FAILED=$((FAILED + 1))
            fi
        done <<< "$stale"
        # Only worth another pass if something actually changed -- otherwise
        # conda will just report the exact same stale file(s) again.
        [[ $removed_this_pass -eq 1 ]] || break
    done
done

echo
echo "Removed $REMOVED stale conda-meta file(s)."
[[ $FAILED -gt 0 ]] && echo "Failed to remove $FAILED (check write access to the conda base)."
