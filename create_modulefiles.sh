#!/bin/bash
# =============================================================================
# AIStack Modulefile Generator
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   sudo bash create_modulefiles.sh
#
# IDEMPOTENT — safe to re-run:
#   - Modulefile is skipped if it already exists (and conda env is unchanged)
#   - Use --force to overwrite all existing modulefiles
#
#   sudo bash create_modulefiles.sh           # skip existing modulefiles
#   sudo bash create_modulefiles.sh --force   # regenerate all
# =============================================================================

set -o pipefail

FORCE=0
[[ "${1}" == "--force" ]] && FORCE=1

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
MODULEFILE_DIR="/usr/share/modulefiles/AIStack"
LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/modulefiles.log"

mkdir -p "$LOG_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_pass() { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_fail() { echo -e "  ${RED}✘${NC} $*" | tee -a "$SUMMARY_LOG"; }

# ─── ENV METADATA ────────────────────────────────────────────────────────────
# "env_name|display_name|category|description"
ENV_DEFS=(
    "unsloth|Unsloth|Finetuning|Fast LLM finetuning with Unsloth (CUDA 12.8)"
    "transformers|Transformers|Finetuning|HuggingFace Transformers finetuning (CUDA 12.8)"
    "accelerate|Accelerate|Finetuning|HuggingFace Accelerate distributed training (CUDA 12.8)"
    "trl|TRL|Finetuning|HuggingFace TRL RLHF finetuning (CUDA 12.8)"
    "axolotl|Axolotl|Finetuning|Axolotl with DeepSpeed (CUDA 12.8)"
    "llamafactory|LLaMA-Factory|Finetuning|LLaMA-Factory finetuning framework (CUDA 12.8)"
    "torchtune|TorchTune|Finetuning|PyTorch native finetuning with TorchTune (CUDA 12.8)"
    "deepspeed|DeepSpeed|Finetuning|Microsoft DeepSpeed distributed training (CUDA 13.0)"
    "vllm|vLLM|Inference|High-throughput LLM inference with vLLM (CUDA 13.0)"
    "sglang|SGLang|Inference|Structured generation LLM inference with SGLang (CUDA 13.0)"
    "lmdeploy|LMDeploy|Inference|LMDeploy LLM serving and quantization (CUDA 13.0)"
    "rayserve|RayServe|Inference|Scalable model serving with Ray Serve and vLLM (CUDA 13.0)"
    "tgi|TGI|Inference|HuggingFace Text Generation Inference (CUDA 13.0)"
    "llamaindex|LlamaIndex|RAG|RAG pipelines with LlamaIndex (CUDA 13.0)"
    "langchain|LangChain|RAG|RAG and agent workflows with LangChain and LangGraph (CUDA 13.0)"
    "haystack|Haystack|RAG|RAG pipelines with Haystack AI (CUDA 13.0)"
    "pytorch|PyTorch|Legacy|PyTorch workloads (CUDA 12.6, Python 3.10)"
    "tensorflow|TensorFlow-GPU|Legacy|TensorFlow GPU workloads (Python 3.10)"
    "Theano|Theano|Legacy|Theano with GPU support via pygpu (Python 3.10)"
    "Caffe|Caffe|Legacy|Caffe with GPU support (Python 3.7)"
    "rapids|Rapids|Legacy|RAPIDS AI cuDF GPU dataframe (CUDA 11.2, Python 3.7)"
)

# ─── MODULEFILE WRITER ───────────────────────────────────────────────────────
generate_modulefile() {
    local env="$1" display="$2" category="$3" description="$4"
    local conda_prefix="$CONDA_DIR/envs/$env"
    local outfile="$MODULEFILE_DIR/$env"

    # Skip if file already exists and --force not set
    if [[ -f "$outfile" && $FORCE -eq 0 ]]; then
        log_skip "$env — modulefile already exists (use --force to overwrite)"
        return 0
    fi

    cat > "$outfile" << EOF
#%Module1.0
# =============================================================================
# AIStack modulefile — $display
# Category  : $category
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

module-whatis "$display — AIStack $category Environment"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  $description"
    puts stderr ""
    puts stderr "  Category  : $category"
    puts stderr "  Conda env : $env"
    puts stderr "  Prefix    : $conda_prefix"
    puts stderr "  Conda base: $CONDA_DIR"
    puts stderr ""
    puts stderr "  Usage:"
    puts stderr "    module load AIStack/$env"
    puts stderr "    module unload AIStack/$env"
    puts stderr ""
}

# Prevent stacking two AIStack envs at once
conflict AIStack

# ── Environment variables
setenv CONDA_SHLVL         1
setenv CONDA_PREFIX        $conda_prefix
setenv CONDA_DEFAULT_ENV   $env
setenv CONDA_EXE           $CONDA_DIR/bin/conda
setenv CONDA_PYTHON_EXE    $CONDA_DIR/bin/python
setenv VIRTUAL_ENV         $conda_prefix
setenv AISTACK_ENV         $env
setenv AISTACK_ENV_DISPLAY $display
setenv AISTACK_CATEGORY    $category

# ── Prepend conda base (for the conda command) then env bin to PATH
prepend-path PATH            $conda_prefix/bin
prepend-path PATH            $CONDA_DIR/bin
prepend-path LD_LIBRARY_PATH $conda_prefix/lib

# ── Run conda activate/deactivate so the shell prompt updates
if { [ module-info mode load ] } {
    puts stdout "source $CONDA_DIR/bin/activate $env ;"
}
if { [ module-info mode unload ] } {
    puts stdout "source $CONDA_DIR/bin/activate base ;"
}
EOF
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
log "=== AIStack Modulefile Generator — $(date) ==="
log "Modulefile dir : $MODULEFILE_DIR"
log "Conda base     : $CONDA_DIR"
[[ $FORCE -eq 1 ]] && log "  --force: overwriting all existing modulefiles"

# ── STEP 1: Ensure Lmod is installed
if command -v module &>/dev/null || [[ -f /usr/share/lmod/lmod/init/bash ]]; then
    log_skip "Lmod already installed"
else
    log "Installing Lmod via dnf..."
    if ! command -v dnf &>/dev/null; then
        echo -e "${RED}ERROR: dnf not found — cannot install Lmod. Install it manually.${NC}"
        exit 1
    fi
    dnf install -y Lmod >> "$LOG_DIR/lmod_install.log" 2>&1 \
        && log_pass "Lmod installed" \
        || { echo -e "${RED}ERROR: Lmod installation failed — check $LOG_DIR/lmod_install.log${NC}"; exit 1; }
fi

# ── STEP 2: Create modulefile directory
if ! mkdir -p "$MODULEFILE_DIR" 2>/dev/null; then
    echo -e "${RED}ERROR: Cannot create $MODULEFILE_DIR — try running with sudo.${NC}"
    exit 1
fi

# Write .version file if missing
if [[ ! -f "$MODULEFILE_DIR/.version" || $FORCE -eq 1 ]]; then
    cat > "$MODULEFILE_DIR/.version" << 'EOF'
#%Module
set ModulesVersion "miniconda"
EOF
    log_pass ".version file written"
else
    log_skip ".version file already exists"
fi

CREATED=0; SKIPPED=0; FAILED=0

echo "" | tee -a "$SUMMARY_LOG"

# ── Miniconda modulefile (standalone — for users creating their own envs)
log "Generating miniconda modulefile..."
MINICONDA_MOD="$MODULEFILE_DIR/miniconda"
if [[ -f "$MINICONDA_MOD" && $FORCE -eq 0 ]]; then
    log_skip "miniconda — modulefile already exists"
    SKIPPED=$((SKIPPED + 1))
elif [[ ! -d "$CONDA_DIR" ]]; then
    log_skip "miniconda — $CONDA_DIR not found, skipping"
    SKIPPED=$((SKIPPED + 1))
else
    cat > "$MINICONDA_MOD" << EOF
#%Module1.0
# =============================================================================
# AIStack modulefile — Miniconda3
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

module-whatis "Miniconda3 — base conda at $CONDA_DIR"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  Miniconda3 base conda installation"
    puts stderr ""
    puts stderr "  Conda base : $CONDA_DIR"
    puts stderr ""
    puts stderr "  Usage:"
    puts stderr "    module load AIStack/miniconda"
    puts stderr "    conda create -n myenv python=3.11"
    puts stderr "    conda activate myenv"
    puts stderr ""
}

setenv CONDA_DIR        $CONDA_DIR
setenv CONDA_EXE        $CONDA_DIR/bin/conda
setenv CONDA_PYTHON_EXE $CONDA_DIR/bin/python

prepend-path PATH $CONDA_DIR/bin

if { [ module-info mode load ] } {
    puts stdout "source $CONDA_DIR/bin/activate base ;"
}
if { [ module-info mode unload ] } {
    puts stdout "conda deactivate ;"
}
EOF
    log_pass "miniconda → $MINICONDA_MOD"
    CREATED=$((CREATED + 1))
fi

echo "" | tee -a "$SUMMARY_LOG"

for def in "${ENV_DEFS[@]}"; do
    IFS='|' read -r env display category description <<< "$def"

    # Skip if conda env not installed
    if [[ ! -d "$CONDA_DIR/envs/$env" ]]; then
        log_skip "$env — conda env not installed, skipping modulefile"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check existing modulefile
    outfile="$MODULEFILE_DIR/$env"
    if [[ -f "$outfile" && $FORCE -eq 0 ]]; then
        log_skip "$env — modulefile already exists"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if generate_modulefile "$env" "$display" "$category" "$description"; then
        log_pass "$env → $outfile"
        CREATED=$((CREATED + 1))
    else
        log_fail "$env — failed to write modulefile"
        FAILED=$((FAILED + 1))
    fi
done

# ─── REPORT ──────────────────────────────────────────────────────────────────
echo "" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}                    MODULEFILE SUMMARY${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo -e "  ${GREEN}Created : $CREATED${NC}" | tee -a "$SUMMARY_LOG"
echo -e "  ${YELLOW}Skipped : $SKIPPED${NC}  (already exist or env not installed)" | tee -a "$SUMMARY_LOG"
echo -e "  ${RED}Failed  : $FAILED${NC}" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}  ── Make AIStack modules available system-wide ──${NC}" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo    "  Add to /etc/profile.d/modules.sh or /etc/environment :" | tee -a "$SUMMARY_LOG"
echo    "    export MODULEPATH=\$MODULEPATH:/usr/share/modulefiles" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}  ── Usage ──${NC}" | tee -a "$SUMMARY_LOG"
echo    "    module avail AIStack              # list all" | tee -a "$SUMMARY_LOG"
echo    "    module load   AIStack/vllm        # activate" | tee -a "$SUMMARY_LOG"
echo    "    module unload AIStack/vllm        # deactivate" | tee -a "$SUMMARY_LOG"
echo    "    module help   AIStack/deepspeed   # show info" | tee -a "$SUMMARY_LOG"
echo    "    module whatis AIStack/langchain   # one-liner" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo    "  To regenerate all (overwrite) :" | tee -a "$SUMMARY_LOG"
echo    "    sudo bash create_modulefiles.sh --force" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
echo -e "  Log : $SUMMARY_LOG" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
