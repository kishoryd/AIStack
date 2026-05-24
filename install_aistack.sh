#!/bin/bash
# =============================================================================
# AIStack Environment Installer
# =============================================================================
# Usage:
#   git clone https://github.com/YOUR_ORG/AIStack.git /home/apps/AIStack
#   cd /home/apps/AIStack
#   bash install_aistack.sh
#
# IDEMPOTENT — safe to re-run at any time:
#   - Miniconda : skipped if already installed
#   - conda env : skipped entirely if env directory already exists
#   - pip pkgs  : skipped per-package if already importable
#   - kernel    : skipped if already registered
#   - base reqs : skipped if sentinel file exists
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"

TORCH_CU128="https://download.pytorch.org/whl/cu128"
TORCH_CU130="https://download.pytorch.org/whl/cu130"


LOG_DIR="/home/apps/logs"
SUMMARY_LOG="$LOG_DIR/install_summary.log"
DONE_DIR="/home/apps/.done"   # sentinel files live here

mkdir -p "$LOG_DIR" "$DONE_DIR"
# append to summary log across restarts — do NOT truncate with >
log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok()  { echo "  ✔ $*" | tee -a "$SUMMARY_LOG"; }
log_skip(){ echo "  ⊘ $*" | tee -a "$SUMMARY_LOG"; }
log_err() { echo "  ✘ $*" | tee -a "$SUMMARY_LOG"; }

# ─── SENTINEL HELPERS ────────────────────────────────────────────────────────
# mark ENV as fully done
mark_done()   { touch "$DONE_DIR/$1.done"; }
# true if ENV was previously completed
is_done()     { [[ -f "$DONE_DIR/$1.done" ]]; }
# true if conda env directory exists
env_exists()  { [[ -d "$CONDA_DIR/envs/$1" ]]; }
# true if a package is importable inside an env
pkg_installed() {
    local env="$1" pkg="$2"
    # strip install flags (e.g. --no-build-isolation) to get just the module name
    local mod
    mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
    "$CONDA_DIR/envs/$env/bin/python" -c "import $mod" &>/dev/null
}

# ─── ERRORS ──────────────────────────────────────────────────────────────────
declare -A ENV_ERRORS
declare -A ENV_SKIPPED

# ─── PIP INSTALL (idempotent per-package) ────────────────────────────────────
pip_install() {
    local env="$1"; shift
    local failed=()
    for pkg in "$@"; do
        local mod
        mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
        if pkg_installed "$env" "$mod"; then
            log_skip "already installed: $pkg (env: $env)"
            continue
        fi
        log "  pip install $pkg (env: $env)"
        if "$CONDA_DIR/envs/$env/bin/pip" install $pkg >> "$LOG_DIR/${env}.log" 2>&1; then
            log_ok "$pkg"
        else
            log_err "$pkg FAILED"
            failed+=("$pkg")
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && ENV_ERRORS[$env]="${ENV_ERRORS[$env]} ${failed[*]}"
}

pip_install_with_index() {
    local env="$1"; local index_url="$2"; shift 2
    local failed=()
    for pkg in "$@"; do
        local mod
        mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
        if pkg_installed "$env" "$mod"; then
            log_skip "already installed: $pkg (env: $env)"
            continue
        fi
        log "  pip install $pkg --index-url $index_url (env: $env)"
        if "$CONDA_DIR/envs/$env/bin/pip" install $pkg --index-url "$index_url" >> "$LOG_DIR/${env}.log" 2>&1; then
            log_ok "$pkg"
        else
            log_err "$pkg FAILED"
            failed+=("$pkg")
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && ENV_ERRORS[$env]="${ENV_ERRORS[$env]} ${failed[*]}"
}

conda_install() {
    local env="$1"; shift
    log "  conda install $* (env: $env)"
    "$CONDA_DIR/bin/conda" install -n "$env" -y "$@" \
        >> "$LOG_DIR/${env}.log" 2>&1 \
        && log_ok "$*" \
        || { log_err "$* FAILED"; ENV_ERRORS[$env]="${ENV_ERRORS[$env]} $*"; }
}

# ─── CONDA CREATE (idempotent) ───────────────────────────────────────────────
# Returns:
#   0  → env was just created (proceed with installs)
#   1  → env already existed AND is marked done (skip all installs)
#   2  → env already existed but NOT marked done (proceed with installs to resume)
#   3  → creation failed
conda_create() {
    local env="$1"; local pyver="$2"

    if env_exists "$env"; then
        if is_done "$env"; then
            log_skip "env '$env' already complete — skipping"
            ENV_SKIPPED[$env]=1
            return 1
        else
            log "env '$env' exists but not marked done — resuming installs"
            return 2
        fi
    fi

    log "Creating conda env '$env' (python=$pyver)..."
    "$CONDA_DIR/bin/conda" create -n "$env" python="$pyver" -y \
        >> "$LOG_DIR/${env}.log" 2>&1 \
        && { log_ok "env '$env' created"; return 0; } \
        || { log_err "Failed to create env '$env'"; ENV_ERRORS[$env]="ENV_CREATION_FAILED"; return 3; }
}

# ─── KERNEL REGISTER (idempotent) ────────────────────────────────────────────
register_kernel() {
    local env="$1"; local display="$2"
    if jupyter kernelspec list 2>/dev/null | grep -qi "^${env}[[:space:]]"; then
        log_skip "kernel '$env' already registered"
        return 0
    fi
    log "  Installing Jupyter stack in '$env'..."
    "$CONDA_DIR/envs/$env/bin/pip" install \
        jupyter jupyterlab notebook ipykernel ipywidgets \
        -q >> "$LOG_DIR/${env}.log" 2>&1
    log "  Registering JupyterHub kernel for '$env'..."
    "$CONDA_DIR/envs/$env/bin/python" -m ipykernel install \
        --sys-prefix --name "$env" --display-name "$display" \
        >> "$LOG_DIR/${env}.log" 2>&1 \
        && log_ok "Kernel '$display' registered" \
        || log_err "Kernel registration failed for '$env'"
}

# ─── INSTALL ENV WRAPPER ─────────────────────────────────────────────────────
# Usage: begin_env ENV PYVER && { installs... ; mark_done ENV; }
# Handles the 3-state return from conda_create cleanly
begin_env() {
    local env="$1"; local pyver="$2"
    conda_create "$env" "$pyver"
    local rc=$?
    [[ $rc -eq 1 ]] && return 1   # fully done, caller skips block
    [[ $rc -eq 3 ]] && return 1   # creation failed, caller skips block
    return 0                       # rc 0 or 2 → proceed
}

# =============================================================================
# STEP 1 — MINICONDA
# =============================================================================
log "=== AIStack Installer — $(date) ==="
log "Repo : $AISTACK_DIR"

if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
    log "Downloading Miniconda..."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
        -O /tmp/miniconda.sh
    log "Installing Miniconda to $CONDA_DIR..."
    bash /tmp/miniconda.sh -b -p "$CONDA_DIR"
else
    log_skip "Miniconda already at $CONDA_DIR"
fi

export PATH="$CONDA_DIR/bin:$PATH"
source "$CONDA_DIR/bin/activate"
export CONDA_TOS_ACCEPTED=true
conda tos accept 2>/dev/null || true
log_ok "Conda ready"


# =============================================================================
# FINETUNING
# =============================================================================

log "=== FINETUNING: unsloth ==="
begin_env unsloth 3.11 && {
    pip_install_with_index unsloth "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install unsloth "ninja" "triton" "unsloth"
    register_kernel unsloth "Unsloth (Python 3.11)"
    [[ -z "${ENV_ERRORS[unsloth]}" ]] && mark_done unsloth
}

log "=== FINETUNING: transformers ==="
begin_env transformers 3.11 && {
    pip_install_with_index transformers "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install transformers "transformers"
    register_kernel transformers "Transformers (Python 3.11)"
    [[ -z "${ENV_ERRORS[transformers]}" ]] && mark_done transformers
}

log "=== FINETUNING: accelerate ==="
begin_env accelerate 3.11 && {
    pip_install_with_index accelerate "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install accelerate "accelerate"
    register_kernel accelerate "Accelerate (Python 3.11)"
    [[ -z "${ENV_ERRORS[accelerate]}" ]] && mark_done accelerate
}

log "=== FINETUNING: trl ==="
begin_env trl 3.11 && {
    pip_install_with_index trl "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install trl "trl"
    register_kernel trl "TRL (Python 3.11)"
    [[ -z "${ENV_ERRORS[trl]}" ]] && mark_done trl
}

log "=== FINETUNING: axolotl ==="
begin_env axolotl 3.11 && {
    pip_install_with_index axolotl "$TORCH_CU128" "torch" "torchaudio"
    pip_install axolotl "ninja" "packaging" "axolotl[deepspeed]"
    register_kernel axolotl "Axolotl (Python 3.11)"
    [[ -z "${ENV_ERRORS[axolotl]}" ]] && mark_done axolotl
}

log "=== FINETUNING: llamafactory ==="
begin_env llamafactory 3.11 && {
    pip_install_with_index llamafactory "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install llamafactory "ninja" "llamafactory[metrics]"
    register_kernel llamafactory "LLaMA-Factory (Python 3.11)"
    [[ -z "${ENV_ERRORS[llamafactory]}" ]] && mark_done llamafactory
}

log "=== FINETUNING: torchtune ==="
begin_env torchtune 3.11 && {
    pip_install_with_index torchtune "$TORCH_CU128" "torch" "torchvision" "torchaudio" "torchao"
    pip_install torchtune "torchtune"
    register_kernel torchtune "TorchTune (Python 3.11)"
    [[ -z "${ENV_ERRORS[torchtune]}" ]] && mark_done torchtune
}

log "=== FINETUNING: deepspeed ==="
begin_env deepspeed 3.11 && {
    pip_install_with_index deepspeed "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install deepspeed "deepspeed"
    register_kernel deepspeed "DeepSpeed (Python 3.11)"
    [[ -z "${ENV_ERRORS[deepspeed]}" ]] && mark_done deepspeed
}

# =============================================================================
# INFERENCE
# =============================================================================

log "=== INFERENCE: vllm ==="
begin_env vllm 3.11 && {
    pip_install_with_index vllm "$TORCH_CU130" "torch"
    pip_install vllm "vllm"
    register_kernel vllm "vLLM (Python 3.11)"
    [[ -z "${ENV_ERRORS[vllm]}" ]] && mark_done vllm
}

log "=== INFERENCE: sglang ==="
begin_env sglang 3.11 && {
    pip_install_with_index sglang "$TORCH_CU130" "torch"
    pip_install sglang "sglang[all]"
    register_kernel sglang "SGLang (Python 3.11)"
    [[ -z "${ENV_ERRORS[sglang]}" ]] && mark_done sglang
}

log "=== INFERENCE: lmdeploy ==="
begin_env lmdeploy 3.11 && {
    pip_install_with_index lmdeploy "$TORCH_CU130" "torch"
    pip_install lmdeploy "lmdeploy"
    register_kernel lmdeploy "LMDeploy (Python 3.11)"
    [[ -z "${ENV_ERRORS[lmdeploy]}" ]] && mark_done lmdeploy
}

log "=== INFERENCE: rayserve ==="
begin_env rayserve 3.11 && {
    pip_install_with_index rayserve "$TORCH_CU130" "torch"
    pip_install rayserve "ray[serve,air,tune]" "vllm"
    register_kernel rayserve "Ray Serve (Python 3.11)"
    [[ -z "${ENV_ERRORS[rayserve]}" ]] && mark_done rayserve
}

log "=== INFERENCE: tgi ==="
begin_env tgi 3.11 && {
    pip_install_with_index tgi "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install tgi "text-generation" "text-generation-server"
    register_kernel tgi "TGI (Python 3.11)"
    [[ -z "${ENV_ERRORS[tgi]}" ]] && mark_done tgi
}

# =============================================================================
# RAG
# =============================================================================

log "=== RAG: llamaindex ==="
begin_env llamaindex 3.11 && {
    pip_install_with_index llamaindex "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install llamaindex \
        "llama-index" "llama-index-core" \
        "llama-index-llms-huggingface" "llama-index-llms-openai" \
        "llama-index-llms-ollama" "llama-index-llms-vllm" \
        "llama-index-embeddings-huggingface" "llama-index-embeddings-openai" \
        "llama-index-embeddings-fastembed" \
        "llama-index-vector-stores-chroma" "llama-index-vector-stores-qdrant" \
        "llama-index-vector-stores-faiss" "llama-index-vector-stores-milvus" \
        "llama-index-vector-stores-postgres" \
        "llama-index-postprocessor-colbert-rerank" \
        "llama-index-postprocessor-flag-embedding-reranker" \
        "llama-index-readers-file" "llama-index-readers-web" \
        "llama-index-readers-database" "llama-index-readers-json" \
        "sentence-transformers" "FlagEmbedding" "fastembed" \
        "chromadb" "qdrant-client" "pymilvus" \
        "pypdf" "psycopg2-binary" "pgvector" "redis" \
        "ragas" "deepeval" "trulens-eval" \
        "wandb" "arize-phoenix" \
        "fastapi" "uvicorn" "gradio"
    register_kernel llamaindex "LlamaIndex (Python 3.11)"
    [[ -z "${ENV_ERRORS[llamaindex]}" ]] && mark_done llamaindex
}

log "=== RAG: langchain ==="
begin_env langchain 3.11 && {
    pip_install_with_index langchain "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install langchain \
        "langchain" "langchain-core" "langchain-community" \
        "langchain-text-splitters" \
        "langchain-huggingface" "langchain-openai" "langchain-ollama" \
        "langchain-anthropic" "langchain-groq" \
        "langchain-chroma" "langchain-qdrant" "langchain-postgres" \
        "langgraph" "langgraph-checkpoint" \
        "langgraph-checkpoint-sqlite" "langgraph-checkpoint-postgres" \
        "langsmith" \
        "sentence-transformers" "FlagEmbedding" "fastembed" \
        "chromadb" "qdrant-client" "pymilvus" \
        "psycopg2-binary" "pgvector" \
        "unstructured" "pypdf" "docx2txt" \
        "beautifulsoup4" "playwright" "pymupdf" "pandas" "openpyxl" \
        "ragatouille" "flashrank" \
        "mem0ai" "zep-python" \
        "ragas" "deepeval" \
        "wandb" \
        "fastapi" "uvicorn" "gradio" "streamlit"
    register_kernel langchain "LangChain (Python 3.11)"
    [[ -z "${ENV_ERRORS[langchain]}" ]] && mark_done langchain
}

log "=== RAG: haystack ==="
begin_env haystack 3.11 && {
    pip_install_with_index haystack "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install haystack \
        "haystack-ai" "huggingface_hub" "openai" "haystack-ai[inference]" \
        "chroma-haystack" "qdrant-haystack" "milvus-haystack" \
        "pgvector-haystack" "elasticsearch-haystack" \
        "sentence-transformers" "FlagEmbedding" "fastembed" \
        "chromadb" "qdrant-client" "pymilvus" "faiss-gpu" \
        "psycopg2-binary" "pgvector" "elasticsearch" \
        "pypdf" "docx2txt" "unstructured" "pymupdf" "markdown" \
        "ragatouille" "flashrank" \
        "ragas" "deepeval" \
        "wandb" "arize-phoenix" \
        "fastapi" "uvicorn" "gradio" "streamlit"
    register_kernel haystack "Haystack (Python 3.11)"
    [[ -z "${ENV_ERRORS[haystack]}" ]] && mark_done haystack
}

# =============================================================================
# LEGACY
# =============================================================================

log "=== LEGACY: pytorch ==="
begin_env pytorch 3.10 && {
    pip_install_with_index pytorch "https://download.pytorch.org/whl/cu126" \
        "torch" "torchvision"
    register_kernel pytorch "PyTorch (Python 3.10)"
    [[ -z "${ENV_ERRORS[pytorch]}" ]] && mark_done pytorch
}

log "=== LEGACY: tensorflow ==="
begin_env tensorflow 3.10 && {
    pip_install tensorflow "tensorflow[and-cuda]"
    register_kernel tensorflow "TensorFlow GPU (Python 3.10)"
    [[ -z "${ENV_ERRORS[tensorflow]}" ]] && mark_done tensorflow
}

log "=== LEGACY: Theano ==="
begin_env Theano 3.10 && {
    conda_install Theano -c conda-forge theano pygpu
    register_kernel Theano "Theano (Python 3.10)"
    [[ -z "${ENV_ERRORS[Theano]}" ]] && mark_done Theano
}

log "=== LEGACY: Caffe ==="
begin_env Caffe 3.7 && {
    conda_install Caffe -c anaconda caffe-gpu
    register_kernel Caffe "Caffe (Python 3.7)"
    [[ -z "${ENV_ERRORS[Caffe]}" ]] && mark_done Caffe
}

# =============================================================================
# SUMMARY
# =============================================================================
ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune deepspeed
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    pytorch tensorflow Theano Caffe
)

echo ""
echo "════════════════════════════════════════════════════════════"
echo "                   INSTALLATION SUMMARY"
echo "════════════════════════════════════════════════════════════"

FAILED_COUNT=0
for env in "${ALL_ENVS[@]}"; do
    if [[ -n "${ENV_SKIPPED[$env]}" ]]; then
        echo "  ⊘ $env  (already complete, skipped)"
    elif [[ -n "${ENV_ERRORS[$env]}" ]]; then
        echo "  ✘ $env  →  FAILED packages:${ENV_ERRORS[$env]}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        echo "  ✔ $env"
    fi
done

echo ""
echo "  Sentinel dir : $DONE_DIR"
echo "  Logs dir     : $LOG_DIR"
echo "  Summary log  : $SUMMARY_LOG"
echo ""
"$CONDA_DIR/bin/conda" env list
echo ""
if [[ $FAILED_COUNT -eq 0 ]]; then
    echo "  🎉 All done!"
else
    echo "  ⚠  $FAILED_COUNT env(s) had failures. Re-run to retry only those."
fi
echo "════════════════════════════════════════════════════════════"
