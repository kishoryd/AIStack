#!/bin/bash
# =============================================================================
# Remove AIStack envs that were accidentally created inside the shared
# production MLDL conda base (/home/apps/MLDL/DL-CondaPy3.10).
#
# Context: install_aistack.sh originally pointed CONDA_DIR at that shared
# base before switching to its own separate Miniconda at
# /home/apps/miniconda (to isolate AIStack from the already-working,
# GPU-verified MLDL envs, and to sidestep a conda/openssl bug specific to
# that base). Any envs created there during that earlier attempt (e.g.
# "unsloth") are now orphaned cruft in a shared production install and
# should be cleaned up.
#
# Usage:
#   bash remove_aistack_envs_from_mldl_conda.sh            # dry run (default)
#   bash remove_aistack_envs_from_mldl_conda.sh --apply     # actually delete
#
# Must be run as a user with write access to /home/apps/MLDL/DL-CondaPy3.10
# (e.g. cdacapp01) -- same requirement as install_aistack.sh had when
# pointed there.
# =============================================================================
set -euo pipefail

CONDA_DIR="${AISTACK_OLD_CONDA_DIR:-/home/apps/MLDL/DL-CondaPy3.10}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

# Every env name install_aistack.sh has used across all naming iterations
# during development, so this cleans up regardless of which point in time
# a partial run against $CONDA_DIR happened.
AISTACK_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    mlflow
    pytorch-aistack tensorflow-aistack theano-aistack caffe-aistack rapids-aistack
    pytorch-latest tensorflow-latest theano-latest caffe-latest rapids-latest
    pytorch-2.8 tensorflow-2.20 theano-1.0 caffe-1.0 rapids-21.06
)

# Never touch these, even by naming coincidence -- the actual production
# MLDL envs this conda base exists for.
PROTECTED_ENVS=(
    Caffe Caffe-gpu Horovod Horovod-Pytorch Horovod-Tensorflow
    Pytorch Pytorch-gpu Rapids Tensorflow Tensorflow-gpu Theano Theano-gpu
)

is_protected() {
    local env="$1"
    for p in "${PROTECTED_ENVS[@]}"; do
        [[ "$env" == "$p" ]] && return 0
    done
    return 1
}

echo "Conda base : $CONDA_DIR"
echo "Mode       : $([[ $APPLY -eq 1 ]] && echo APPLY || echo 'DRY RUN (pass --apply to actually delete)')"
echo

if [[ ! -d "$CONDA_DIR" ]]; then
    echo "Nothing to do -- $CONDA_DIR does not exist."
    exit 0
fi

FOUND=0
for env in "${AISTACK_ENVS[@]}"; do
    envpath="$CONDA_DIR/envs/$env"
    [[ ! -d "$envpath" ]] && continue

    if is_protected "$env"; then
        echo "  SKIP (protected, should never match): $env"
        continue
    fi

    FOUND=1
    if [[ $APPLY -eq 1 ]]; then
        echo "  Removing: $env"
        "$CONDA_DIR/bin/conda" env remove -n "$env" -y >/dev/null 2>&1 \
            || rm -rf "$envpath"
    else
        echo "  Would remove: $env  ($envpath)"
    fi
done

echo
if [[ $FOUND -eq 0 ]]; then
    echo "Nothing to remove -- no AIStack envs found under $CONDA_DIR/envs/."
elif [[ $APPLY -eq 0 ]]; then
    echo "Dry run only. Re-run with --apply to actually delete the env(s) listed above."
else
    echo "Done."
fi
