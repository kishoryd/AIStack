#!/bin/bash
# =============================================================================
# AIStack Environment Installer
# =============================================================================
# Usage:
#   git clone https://github.com/YOUR_ORG/AIStack.git /home/apps/AIStack
#   cd /home/apps/AIStack
#   bash install_aistack.sh
# =============================================================================
# - Miniconda is installed inside the cloned repo dir (./miniconda3)
# - Fail-safe: continues on error, reports failed packages per env at the end
# - Registers every env as a JupyterHub kernel
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
# Resolve the repo root as the directory containing this script — works
# regardless of where you call it from.
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="$AISTACK_DIR/miniconda3"
REQUIREMENTS_FILE="$AISTACK_DIR/requirements.txt"
Theano_YML_FILE="$AISTACK_DIR/envs/Theano.yml"
Caffe_YML_FILE="$AISTACK_DIR/envs/Caffe.yml"

TORCH_CU128="https://download.pytorch.org/whl/cu128"
TORCH_CU130="https://download.pytorch.org/whl/cu130"

LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/install_summary.log"

# ─── HELPERS ─────────────────────────────────────────────────────────────────
declare -A ENV_ERRORS   # env_name -> "pkg1 pkg2 ..."

log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok() { echo "  ✔ $*" | tee -a "$SUMMARY_LOG"; }
log_err(){ echo "  ✘ $*" | tee -a "$SUMMARY_LOG"; }

# pip_install ENV_NAME pkg [pkg ...]
# Installs each package individually so one failure doesn't abort the rest.
pip_install() {
    local env="$1"; shift
    local failed=()
    for pkg in "$@"; do
        log "  pip install $pkg (env: $env)"
        if "$CONDA_DIR/envs/$env/bin/pip" install $pkg >> "$LOG_DIR/${env}.log" 2>&1; then
            log_ok "$pkg"
        else
            log_err "$pkg FAILED"
            failed+=("$pkg")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        ENV_ERRORS[$env]="${ENV_ERRORS[$env]} ${failed[*]}"
    fi
}

# pip_install_group ENV_NAME index_url pkg [pkg ...]
pip_install_with_index() {
    local env="$1"; local index_url="$2"; shift 2
    local failed=()
    for pkg in "$@"; do
        log "  pip install $pkg --index-url $index_url (env: $env)"
        if "$CONDA_DIR/envs/$env/bin/pip" install $pkg --index-url "$index_url" >> "$LOG_DIR/${env}.log" 2>&1; then
            log_ok "$pkg"
        else
            log_err "$pkg FAILED"
            failed+=("$pkg")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        ENV_ERRORS[$env]="${ENV_ERRORS[$env]} ${failed[*]}"
    fi
}

# conda_create ENV_NAME python_version
conda_create() {
    local env="$1"; local pyver="$2"
    log "Creating conda env '$env' (python=$pyver)..."
    "$CONDA_DIR/bin/conda" create -n "$env" python="$pyver" -y \
        >> "$LOG_DIR/${env}.log" 2>&1 \
        && log_ok "env '$env' created" \
        || { log_err "Failed to create env '$env'"; ENV_ERRORS[$env]="ENV_CREATION_FAILED"; return 1; }
}

# register_kernel ENV_NAME DISPLAY_NAME
register_kernel() {
    local env="$1"; local display="$2"
    log "  Registering JupyterHub kernel for '$env'..."
    "$CONDA_DIR/envs/$env/bin/pip" install ipykernel -q >> "$LOG_DIR/${env}.log" 2>&1
    "$CONDA_DIR/envs/$env/bin/python" -m ipykernel install \
        --name "$env" --display-name "$display" \
        >> "$LOG_DIR/${env}.log" 2>&1 \
        && log_ok "Kernel '$display' registered" \
        || log_err "Kernel registration failed for '$env'"
}

# ─── SPACK CUDA LOADER ───────────────────────────────────────────────────────
load_cuda_130() {
    if [[ -f /home/apps/spack/share/spack/setup-env.sh ]]; then
        source /home/apps/spack/share/spack/setup-env.sh
        if ! spack find cuda@13.0.2 &>/dev/null; then
            log "Installing cuda@13.0.2 via spack (this may take a while)..."
            spack install -j 10 cuda@13.0.2
        fi
        spack load cuda@13.0.2
        export CUDA_HOME=$(dirname $(dirname $(which nvcc)))
        export PATH="$CUDA_HOME/bin:$PATH"
        export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
        log_ok "CUDA 13.0.2 loaded via spack (CUDA_HOME=$CUDA_HOME)"
    else
        log_err "Spack not found at /home/apps/spack — skipping CUDA 13.0.2 load"
    fi
}

# ─── SETUP ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
> "$SUMMARY_LOG"
log "=== AIStack Installer started ==="

# ─── STEP 1: Miniconda ───────────────────────────────────────────────────────
if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
    log "Downloading Miniconda..."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
        -O /tmp/miniconda.sh
    log "Installing Miniconda to $CONDA_DIR..."
    bash /tmp/miniconda.sh -b -p "$CONDA_DIR"
else
    log "Miniconda already installed at $CONDA_DIR, skipping."
fi

export PATH="$CONDA_DIR/bin:$PATH"
source "$CONDA_DIR/bin/activate"
conda tos accept --override-channels 2>/dev/null || true
log_ok "Conda initialized"

log "=== Running from repo: $AISTACK_DIR ==="

# ─── STEP 2: Base Environment ────────────────────────────────────────────────
log "=== BASE ENVIRONMENT (base conda) ==="
conda install -y pip >> "$LOG_DIR/base.log" 2>&1
if [[ -f "$REQUIREMENTS_FILE" ]]; then
    pip install -r "$REQUIREMENTS_FILE" >> "$LOG_DIR/base.log" 2>&1 \
        && log_ok "base requirements installed" \
        || log_err "Some base requirements failed — check $LOG_DIR/base.log"
else
    log_err "Requirements file not found: $REQUIREMENTS_FILE"
fi

# =============================================================================
# ███████╗██╗███╗   ██╗███████╗████████╗██╗   ██╗███╗   ██╗██╗███╗   ██╗ ██████╗
# ██╔════╝██║████╗  ██║██╔════╝╚══██╔══╝██║   ██║████╗  ██║██║████╗  ██║██╔════╝
# █████╗  ██║██╔██╗ ██║█████╗     ██║   ██║   ██║██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
# ██╔══╝  ██║██║╚██╗██║██╔══╝     ██║   ██║   ██║██║╚██╗██║██║██║╚██╗██║██║   ██║
# ██║     ██║██║ ╚████║███████╗   ██║   ╚██████╔╝██║ ╚████║██║██║ ╚████║╚██████╔╝
# ╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝
# =============================================================================

# ─── unsloth ─────────────────────────────────────────────────────────────────
log "=== FINETUNING: unsloth ==="
conda_create unsloth 3.11 && {
    pip_install_with_index unsloth "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install unsloth \
        "ninja" "triton" \
        "unsloth" \
        "flash-attn --no-build-isolation"
    register_kernel unsloth "Unsloth (Python 3.11)"
}

# ─── transformers ────────────────────────────────────────────────────────────
log "=== FINETUNING: transformers ==="
conda_create transformers 3.11 && {
    pip_install_with_index transformers "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install transformers "transformers"
    register_kernel transformers "Transformers (Python 3.11)"
}

# ─── accelerate ──────────────────────────────────────────────────────────────
log "=== FINETUNING: accelerate ==="
conda_create accelerate 3.11 && {
    pip_install_with_index accelerate "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install accelerate "accelerate"
    register_kernel accelerate "Accelerate (Python 3.11)"
}

# ─── trl ─────────────────────────────────────────────────────────────────────
log "=== FINETUNING: trl ==="
conda_create trl 3.11 && {
    pip_install_with_index trl "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install trl "trl"
    register_kernel trl "TRL (Python 3.11)"
}

# ─── axolotl ─────────────────────────────────────────────────────────────────
log "=== FINETUNING: axolotl ==="
conda_create axolotl 3.11 && {
    pip_install_with_index axolotl "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install axolotl "ninja" "packaging" "axolotl[flash-attn,deepspeed]"
    register_kernel axolotl "Axolotl (Python 3.11)"
}

# ─── llamafactory ────────────────────────────────────────────────────────────
log "=== FINETUNING: llamafactory ==="
conda_create llamafactory 3.11 && {
    pip_install_with_index llamafactory "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install llamafactory "ninja" "llamafactory[metrics]" "flash-attn --no-build-isolation"
    register_kernel llamafactory "LLaMA-Factory (Python 3.11)"
}

# ─── torchtune ───────────────────────────────────────────────────────────────
log "=== FINETUNING: torchtune ==="
conda_create torchtune 3.11 && {
    pip_install_with_index torchtune "$TORCH_CU128" \
        "torch" "torchvision" "torchaudio"
    pip_install torchtune "torchtune"
    register_kernel torchtune "TorchTune (Python 3.11)"
}

# ─── deepspeed (CUDA 13.0.2 via spack) ───────────────────────────────────────
log "=== FINETUNING: deepspeed ==="
load_cuda_130
conda_create deepspeed 3.11 && {
    pip_install_with_index deepspeed "$TORCH_CU130" \
        "torch" "torchvision" "torchaudio"
    pip_install deepspeed "deepspeed"
    register_kernel deepspeed "DeepSpeed (Python 3.11)"
}

# =============================================================================
# INFERENCE
# =============================================================================

# ─── vllm ────────────────────────────────────────────────────────────────────
log "=== INFERENCE: vllm ==="
conda_create vllm 3.11 && {
    pip_install_with_index vllm "$TORCH_CU130" "torch"
    pip_install vllm "vllm"
    register_kernel vllm "vLLM (Python 3.11)"
}

# ─── sglang ──────────────────────────────────────────────────────────────────
log "=== INFERENCE: sglang ==="
conda_create sglang 3.11 && {
    pip_install_with_index sglang "$TORCH_CU130" "torch"
    pip_install sglang "sglang[all]"
    register_kernel sglang "SGLang (Python 3.11)"
}

# ─── lmdeploy ────────────────────────────────────────────────────────────────
log "=== INFERENCE: lmdeploy ==="
conda_create lmdeploy 3.11 && {
    pip_install_with_index lmdeploy "$TORCH_CU130" "torch"
    pip_install lmdeploy "lmdeploy"
    register_kernel lmdeploy "LMDeploy (Python 3.11)"
}

# ─── rayserve ────────────────────────────────────────────────────────────────
log "=== INFERENCE: rayserve ==="
conda_create rayserve 3.11 && {
    pip_install_with_index rayserve "$TORCH_CU130" "torch"
    pip_install rayserve "ray[serve,air,tune]" "vllm"
    register_kernel rayserve "Ray Serve (Python 3.11)"
}

# ─── tgi ─────────────────────────────────────────────────────────────────────
log "=== INFERENCE: tgi ==="
conda_create tgi 3.11 && {
    pip_install_with_index tgi "$TORCH_CU130" \
        "torch" "torchvision" "torchaudio"
    pip_install tgi "text-generation" "text-generation-server"
    register_kernel tgi "TGI (Python 3.11)"
}

# =============================================================================
# RAG
# =============================================================================
load_cuda_130   # ensure CUDA env vars are set for RAG envs too

# ─── llamaindex ──────────────────────────────────────────────────────────────
log "=== RAG: llamaindex ==="
conda_create llamaindex 3.11 && {
    pip_install_with_index llamaindex "$TORCH_CU130" \
        "torch" "torchvision" "torchaudio"
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
}

# ─── langchain ───────────────────────────────────────────────────────────────
log "=== RAG: langchain ==="
conda_create langchain 3.11 && {
    pip_install_with_index langchain "$TORCH_CU130" \
        "torch" "torchvision" "torchaudio"
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
}

# ─── haystack ────────────────────────────────────────────────────────────────
log "=== RAG: haystack ==="
conda_create haystack 3.11 && {
    pip_install_with_index haystack "$TORCH_CU130" \
        "torch" "torchvision" "torchaudio"
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
}

# =============================================================================
# LEGACY ENVS (from original script)
# =============================================================================

log "=== LEGACY: pytorch_gpu ==="
conda_create pytorch_gpu 3.10 && {
    pip_install_with_index pytorch_gpu "https://download.pytorch.org/whl/cu126" \
        "torch" "torchvision"
    register_kernel pytorch_gpu "PyTorch GPU (Python 3.10)"
}

log "=== LEGACY: tensorflow ==="
conda_create tensorflow 3.10 && {
    pip_install tensorflow "tensorflow[and-cuda]"
    register_kernel tensorflow "TensorFlow GPU (Python 3.10)"
}

log "=== LEGACY: Theano (from yml) ==="
if [[ -f "$Theano_YML_FILE" ]]; then
    "$CONDA_DIR/bin/conda" env create -f "$Theano_YML_FILE" \
        >> "$LOG_DIR/Theano.log" 2>&1 \
        && log_ok "Theano env created" \
        || log_err "Theano env creation failed — check $LOG_DIR/Theano.log"
    THEANO_PYTHON=$(find "$CONDA_DIR/envs/Theano/bin" -name python3 2>/dev/null | head -1)
    [[ -n "$THEANO_PYTHON" ]] && \
        "$CONDA_DIR/envs/Theano/bin/pip" install ipykernel -q && \
        "$THEANO_PYTHON" -m ipykernel install --name Theano --display-name "Theano"
else
    log_err "Theano.yml not found at $Theano_YML_FILE"
fi

log "=== LEGACY: Caffe (from yml) ==="
if [[ -f "$Caffe_YML_FILE" ]]; then
    "$CONDA_DIR/bin/conda" env create -f "$Caffe_YML_FILE" \
        >> "$LOG_DIR/Caffe.log" 2>&1 \
        && log_ok "Caffe env created" \
        || log_err "Caffe env creation failed — check $LOG_DIR/Caffe.log"
    CAFFE_PYTHON=$(find "$CONDA_DIR/envs/Caffe/bin" -name python3 2>/dev/null | head -1)
    [[ -n "$CAFFE_PYTHON" ]] && \
        "$CONDA_DIR/envs/Caffe/bin/pip" install ipykernel -q && \
        "$CAFFE_PYTHON" -m ipykernel install --name Caffe --display-name "Caffe"
else
    log_err "Caffe.yml not found at $Caffe_YML_FILE"
fi

# =============================================================================
# SUMMARY REPORT
# =============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
echo "                   INSTALLATION SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo ""

ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune deepspeed
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    pytorch_gpu tensorflow Theano Caffe
)

FAILED_COUNT=0
for env in "${ALL_ENVS[@]}"; do
    if [[ -n "${ENV_ERRORS[$env]}" ]]; then
        echo "  ✘ $env  →  FAILED packages: ${ENV_ERRORS[$env]}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        echo "  ✔ $env"
    fi
done

echo ""
echo "────────────────────────────────────────────────────────────"
echo "  Logs per env : $LOG_DIR/<env_name>.log"
echo "  Summary log  : $SUMMARY_LOG"
echo "  Conda envs   :"
"$CONDA_DIR/bin/conda" env list
echo ""
if [[ $FAILED_COUNT -eq 0 ]]; then
    echo "  🎉 All environments installed successfully!"
else
    echo "  ⚠  $FAILED_COUNT environment(s) had package failures. See logs above."
fi
echo "════════════════════════════════════════════════════════════"
