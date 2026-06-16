#!/bin/bash
# =============================================================================
# AIStack — Full Installer + Modulefile Generator
# =============================================================================
# Usage:
#   bash aistack_setup.sh           # install all + create modulefiles
#   bash aistack_setup.sh --force   # regenerate modulefiles even if they exist
# =============================================================================
set -o pipefail

FORCE=0
[[ "${1}" == "--force" ]] && FORCE=1

AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── CONDA PATH ──────────────────────────────────────────────────────────────
echo ""
read -p "Enter Miniconda path (leave blank to use /home/apps/MLDL/DL-CondaPy3.10): " USER_CONDA_DIR
CONDA_DIR="${USER_CONDA_DIR:-/home/apps/MLDL/DL-CondaPy3.10}"

if [[ -f "$CONDA_DIR/bin/conda" ]]; then
    echo -e "  ${GREEN}✔${NC} Miniconda found at $CONDA_DIR — using existing installation"
    INSTALL_CONDA=0
else
    echo -e "  ${YELLOW}⊘${NC} Miniconda not found at $CONDA_DIR"
    read -p "Enter path to install Miniconda (leave blank to install at $CONDA_DIR): " INSTALL_PATH
    CONDA_DIR="${INSTALL_PATH:-$CONDA_DIR}"
    INSTALL_CONDA=1
fi
echo ""
MODULEFILE_DIR="/home/apps/modulefiles/MLDL"
TORCH_CU128="https://download.pytorch.org/whl/cu128"
TORCH_CU130="https://download.pytorch.org/whl/cu130"
LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/install_summary.log"
DONE_DIR="$LOG_DIR/done"
HOST_IP=$(hostname -I | awk '{print $1}')
MLFLOW_PORT=5001
MLFLOW_DIR="/home/apps/mlflow"

mkdir -p "$LOG_DIR" "$DONE_DIR" "$MODULEFILE_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok()   { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_skip() { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_err()  { echo -e "  ${RED}✘${NC} $*" | tee -a "$SUMMARY_LOG"; }

mark_done()  { touch "$DONE_DIR/$1.done"; }
is_done()    { [[ -f "$DONE_DIR/$1.done" ]]; }
env_exists() { [[ -d "$CONDA_DIR/envs/$1" ]]; }

declare -A ENV_ERRORS
declare -A ENV_SKIPPED

# ─── HELPERS ─────────────────────────────────────────────────────────────────
pkg_installed() {
    local env="$1" pkg="$2"
    local mod
    mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
    "$CONDA_DIR/envs/$env/bin/python" -c "import $mod" &>/dev/null
}

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

register_kernel() {
    local env="$1"; local display="$2"
    if [[ -d "$CONDA_DIR/envs/$env/share/jupyter/kernels/$env" ]]; then
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

begin_env() {
    local env="$1"; local pyver="$2"
    conda_create "$env" "$pyver"
    local rc=$?
    [[ $rc -eq 1 || $rc -eq 3 ]] && return 1
    return 0
}

# ─── MODULEFILE WRITER ───────────────────────────────────────────────────────
write_modulefile() {
    local env="$1" display="$2" category="$3" description="$4"
    local conda_prefix="$CONDA_DIR/envs/$env"
    local outfile="$MODULEFILE_DIR/$env"

    if [[ -f "$outfile" && $FORCE -eq 0 ]]; then
        log_skip "modulefile '$env' already exists (use --force to overwrite)"
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
    puts stderr "    module load MLDL/$env"
    puts stderr "    module unload MLDL/$env"
    puts stderr ""
}

conflict AIStack

setenv CONDA_SHLVL         1
setenv CONDA_PREFIX        $conda_prefix
setenv CONDA_DEFAULT_ENV   $env
setenv CONDA_EXE           $CONDA_DIR/bin/conda
setenv CONDA_PYTHON_EXE    $CONDA_DIR/bin/python
setenv VIRTUAL_ENV         $conda_prefix
setenv AISTACK_ENV         $env
setenv AISTACK_ENV_DISPLAY $display
setenv AISTACK_CATEGORY    $category

prepend-path PATH            $conda_prefix/bin
prepend-path PATH            $CONDA_DIR/bin
prepend-path LD_LIBRARY_PATH $conda_prefix/lib

if { [ module-info mode load ] } {
    puts stdout "source $CONDA_DIR/bin/activate $env ;"
}
if { [ module-info mode unload ] } {
    puts stdout "source $CONDA_DIR/bin/activate base ;"
}
EOF
    log_ok "modulefile → $outfile"
}

# install env then immediately write its modulefile
install_and_register() {
    local env="$1" display="$2" category="$3" description="$4"
    if [[ -n "${ENV_ERRORS[$env]}" ]]; then
        log_err "Skipping modulefile for '$env' due to install errors"
        return 1
    fi
    if [[ -n "${ENV_SKIPPED[$env]}" ]]; then
        write_modulefile "$env" "$display" "$category" "$description"
        return 0
    fi
    write_modulefile "$env" "$display" "$category" "$description"
}

# =============================================================================
# STEP 1 — CONDA BASE
# =============================================================================
log "=== AIStack Setup — $(date) ==="

if [[ $INSTALL_CONDA -eq 1 ]]; then
    log "Downloading Miniconda..."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
        -O /tmp/miniconda.sh
    log "Installing Miniconda to $CONDA_DIR..."
    bash /tmp/miniconda.sh -b -p "$CONDA_DIR" \
        && log_ok "Miniconda installed at $CONDA_DIR" \
        || { log_err "Miniconda install failed"; exit 1; }
else
    log_ok "Using existing Miniconda at $CONDA_DIR"
fi

export PATH="$CONDA_DIR/bin:$PATH"
source "$CONDA_DIR/bin/activate"
export CONDA_TOS_ACCEPTED=true
conda tos accept 2>/dev/null || true
log_ok "Conda ready"

"$CONDA_DIR/bin/conda" install -y python pip &>/dev/null && log_ok "python/pip in base" || log_err "python/pip in base FAILED"
"$CONDA_DIR/bin/pip" install uv &>/dev/null && log_ok "uv in base" || log_err "uv FAILED"

# miniconda modulefile
MINICONDA_MOD="$MODULEFILE_DIR/miniconda"
if [[ ! -f "$MINICONDA_MOD" || $FORCE -eq 1 ]]; then
    cat > "$MINICONDA_MOD" << EOF
#%Module1.0
module-whatis "Conda base at $CONDA_DIR"
proc ModulesHelp { } {
    puts stderr "  Conda base : $CONDA_DIR"
    puts stderr "  Usage: module load MLDL/miniconda"
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
    log_ok "modulefile → $MINICONDA_MOD"
else
    log_skip "modulefile 'miniconda' already exists"
fi

# Set MLDL/miniconda as default
cat > "$MODULEFILE_DIR/.version" << 'VEOF'
#%Module
set ModulesVersion "miniconda"
VEOF
log_ok ".version → default MLDL/miniconda"

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
install_and_register unsloth "Unsloth" "Finetuning" "Fast LLM finetuning with Unsloth (CUDA 12.8)"

log "=== FINETUNING: transformers ==="
begin_env transformers 3.11 && {
    pip_install_with_index transformers "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install transformers "transformers" "mlflow"
    register_kernel transformers "Transformers (Python 3.11)"
    [[ -z "${ENV_ERRORS[transformers]}" ]] && mark_done transformers
}
install_and_register transformers "Transformers" "Finetuning" "HuggingFace Transformers finetuning (CUDA 12.8)"

log "=== FINETUNING: accelerate ==="
begin_env accelerate 3.11 && {
    pip_install_with_index accelerate "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install accelerate "accelerate" "mlflow"
    register_kernel accelerate "Accelerate (Python 3.11)"
    [[ -z "${ENV_ERRORS[accelerate]}" ]] && mark_done accelerate
}
install_and_register accelerate "Accelerate" "Finetuning" "HuggingFace Accelerate distributed training (CUDA 12.8)"

log "=== FINETUNING: trl ==="
begin_env trl 3.11 && {
    pip_install_with_index trl "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install trl "trl" "mlflow"
    register_kernel trl "TRL (Python 3.11)"
    [[ -z "${ENV_ERRORS[trl]}" ]] && mark_done trl
}
install_and_register trl "TRL" "Finetuning" "HuggingFace TRL RLHF finetuning (CUDA 12.8)"

log "=== FINETUNING: axolotl ==="
begin_env axolotl 3.11 && {
    pip_install_with_index axolotl "$TORCH_CU128" "torch" "torchaudio"
    pip_install axolotl "ninja" "packaging" "axolotl[deepspeed]" "mlflow"
    register_kernel axolotl "Axolotl (Python 3.11)"
    [[ -z "${ENV_ERRORS[axolotl]}" ]] && mark_done axolotl
}
install_and_register axolotl "Axolotl" "Finetuning" "Axolotl with DeepSpeed (CUDA 12.8)"

log "=== FINETUNING: llamafactory ==="
begin_env llamafactory 3.11 && {
    pip_install_with_index llamafactory "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install llamafactory "ninja" "llamafactory[metrics]" "mlflow"
    register_kernel llamafactory "LLaMA-Factory (Python 3.11)"
    [[ -z "${ENV_ERRORS[llamafactory]}" ]] && mark_done llamafactory
}
install_and_register llamafactory "LLaMA-Factory" "Finetuning" "LLaMA-Factory finetuning framework (CUDA 12.8)"

log "=== FINETUNING: torchtune ==="
begin_env torchtune 3.11 && {
    pip_install_with_index torchtune "$TORCH_CU128" "torch" "torchvision" "torchaudio" "torchao"
    pip_install torchtune "torchtune" "mlflow"
    register_kernel torchtune "TorchTune (Python 3.11)"
    [[ -z "${ENV_ERRORS[torchtune]}" ]] && mark_done torchtune
}
install_and_register torchtune "TorchTune" "Finetuning" "PyTorch native finetuning with TorchTune (CUDA 12.8)"

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
install_and_register vllm "vLLM" "Inference" "High-throughput LLM inference with vLLM (CUDA 13.0)"

log "=== INFERENCE: sglang ==="
begin_env sglang 3.11 && {
    pip_install_with_index sglang "$TORCH_CU130" "torch"
    pip_install sglang "sglang[all]"
    register_kernel sglang "SGLang (Python 3.11)"
    [[ -z "${ENV_ERRORS[sglang]}" ]] && mark_done sglang
}
install_and_register sglang "SGLang" "Inference" "Structured generation LLM inference with SGLang (CUDA 13.0)"

log "=== INFERENCE: lmdeploy ==="
begin_env lmdeploy 3.11 && {
    pip_install_with_index lmdeploy "$TORCH_CU130" "torch"
    pip_install lmdeploy "lmdeploy"
    register_kernel lmdeploy "LMDeploy (Python 3.11)"
    [[ -z "${ENV_ERRORS[lmdeploy]}" ]] && mark_done lmdeploy
}
install_and_register lmdeploy "LMDeploy" "Inference" "LMDeploy LLM serving and quantization (CUDA 13.0)"

log "=== INFERENCE: rayserve ==="
begin_env rayserve 3.11 && {
    pip_install_with_index rayserve "$TORCH_CU130" "torch"
    pip_install rayserve "ray[serve,air,tune]" "vllm"
    register_kernel rayserve "Ray Serve (Python 3.11)"
    [[ -z "${ENV_ERRORS[rayserve]}" ]] && mark_done rayserve
}
install_and_register rayserve "RayServe" "Inference" "Scalable model serving with Ray Serve and vLLM (CUDA 13.0)"

log "=== INFERENCE: tgi ==="
begin_env tgi 3.11 && {
    pip_install_with_index tgi "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install tgi "text-generation"
    register_kernel tgi "TGI (Python 3.11)"
    [[ -z "${ENV_ERRORS[tgi]}" ]] && mark_done tgi
}
install_and_register tgi "TGI" "Inference" "HuggingFace Text Generation Inference (CUDA 13.0)"

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
install_and_register llamaindex "LlamaIndex" "RAG" "RAG pipelines with LlamaIndex (CUDA 13.0)"

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
install_and_register langchain "LangChain" "RAG" "RAG and agent workflows with LangChain and LangGraph (CUDA 13.0)"

log "=== RAG: haystack ==="
begin_env haystack 3.11 && {
    pip_install_with_index haystack "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install haystack \
        "haystack-ai" "huggingface_hub" "openai" "haystack-ai[inference]" \
        "chroma-haystack" "qdrant-haystack" "milvus-haystack" \
        "pgvector-haystack" "elasticsearch-haystack" \
        "sentence-transformers" "FlagEmbedding" "fastembed" \
        "chromadb" "qdrant-client" "pymilvus" \
        "psycopg2-binary" "pgvector" "elasticsearch" \
        "pypdf" "docx2txt" "unstructured" "pymupdf" "markdown" \
        "ragatouille" "flashrank" \
        "ragas" "deepeval" \
        "wandb" "arize-phoenix" \
        "fastapi" "uvicorn" "gradio" "streamlit"
    register_kernel haystack "Haystack (Python 3.11)"
    [[ -z "${ENV_ERRORS[haystack]}" ]] && mark_done haystack
}
install_and_register haystack "Haystack" "RAG" "RAG pipelines with Haystack AI (CUDA 13.0)"

# =============================================================================
# TRACKING
# =============================================================================
log "=== TRACKING: mlflow ==="
begin_env mlflow 3.11 && {
    pip_install mlflow "mlflow" "sqlalchemy" "psutil"
    register_kernel mlflow "MLflow (Python 3.11)"
    [[ -z "${ENV_ERRORS[mlflow]}" ]] && mark_done mlflow
}

# mlflow modulefile (special — sets MLFLOW_TRACKING_URI)
MLFLOW_MOD="$MODULEFILE_DIR/mlflow"
if [[ ! -f "$MLFLOW_MOD" || $FORCE -eq 1 ]] && [[ -f "$CONDA_DIR/envs/mlflow/bin/mlflow" ]]; then
    cat > "$MLFLOW_MOD" << EOF
#%Module1.0
# =============================================================================
# AIStack modulefile — MLflow Tracking Server
# Category  : Tracking
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
module-whatis "MLflow — experiment tracking server at http://$HOST_IP:$MLFLOW_PORT"
proc ModulesHelp { } {
    puts stderr "  Tracking URI : http://$HOST_IP:$MLFLOW_PORT"
    puts stderr "  Artifacts    : $MLFLOW_DIR/artifacts"
    puts stderr "  Backend      : $MLFLOW_DIR/mlflow.db"
    puts stderr "  Usage: module load MLDL/mlflow"
}
conflict AIStack
setenv MLFLOW_TRACKING_URI http://$HOST_IP:$MLFLOW_PORT
prepend-path PATH $CONDA_DIR/envs/mlflow/bin
if { [ module-info mode load ] } {
    puts stderr "  MLflow tracking URI : http://$HOST_IP:$MLFLOW_PORT"
    puts stdout "export MLFLOW_TRACKING_URI=http://$HOST_IP:$MLFLOW_PORT ;"
}
if { [ module-info mode unload ] } {
    puts stdout "unset MLFLOW_TRACKING_URI ;"
}
EOF
    log_ok "modulefile → $MLFLOW_MOD"
else
    log_skip "modulefile 'mlflow' already exists or env not installed"
fi

# =============================================================================
# LEGACY
# =============================================================================
log "=== LEGACY: pytorch ==="
begin_env pytorch 3.10 && {
    pip_install_with_index pytorch "https://download.pytorch.org/whl/cu126" "torch" "torchvision"
    register_kernel pytorch "PyTorch (Python 3.10)"
    [[ -z "${ENV_ERRORS[pytorch]}" ]] && mark_done pytorch
}
install_and_register pytorch "PyTorch" "Legacy" "PyTorch workloads (CUDA 12.6, Python 3.10)"

log "=== LEGACY: tensorflow ==="
begin_env tensorflow 3.10 && {
    pip_install tensorflow "tensorflow[and-cuda]"
    register_kernel tensorflow "TensorFlow GPU (Python 3.10)"
    [[ -z "${ENV_ERRORS[tensorflow]}" ]] && mark_done tensorflow
}
install_and_register tensorflow "TensorFlow-GPU" "Legacy" "TensorFlow GPU workloads (Python 3.10)"

log "=== LEGACY: Theano ==="
begin_env Theano 3.8 && {
    conda_install Theano -c conda-forge theano=1.0.5 pygpu=0.7.6 "numpy<1.24" python=3.8
    conda_install Theano mkl-service
    register_kernel Theano "Theano (Python 3.8)"
    [[ -z "${ENV_ERRORS[Theano]}" ]] && mark_done Theano
}
install_and_register Theano "Theano" "Legacy" "Theano with GPU support via pygpu (Python 3.8)"

log "=== LEGACY: Caffe ==="
begin_env Caffe 3.7 && {
    conda_install Caffe -c anaconda caffe-gpu
    register_kernel Caffe "Caffe (Python 3.7)"
    [[ -z "${ENV_ERRORS[Caffe]}" ]] && mark_done Caffe
}
install_and_register Caffe "Caffe" "Legacy" "Caffe with GPU support (Python 3.7)"

log "=== LEGACY: rapids ==="
begin_env rapids 3.7 && {
    conda_install rapids -c rapidsai -c nvidia -c numba -c conda-forge cudf=21.06 cudatoolkit=11.2
    register_kernel rapids "Rapids (Python 3.7)"
    [[ -z "${ENV_ERRORS[rapids]}" ]] && mark_done rapids
}
install_and_register rapids "Rapids" "Legacy" "RAPIDS AI cuDF GPU dataframe (CUDA 11.2, Python 3.7)"

# =============================================================================
# SUMMARY
# =============================================================================
ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    mlflow
    pytorch tensorflow Theano Caffe rapids
)

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                   INSTALLATION SUMMARY${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"

FAILED_COUNT=0
for env in "${ALL_ENVS[@]}"; do
    if [[ -n "${ENV_SKIPPED[$env]}" ]]; then
        echo -e "  ${YELLOW}⊘${NC} $env  (already complete, skipped)"
    elif [[ -n "${ENV_ERRORS[$env]}" ]]; then
        echo -e "  ${RED}✘${NC} $env  →  FAILED:${ENV_ERRORS[$env]}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        echo -e "  ${GREEN}✔${NC} $env"
    fi
done

echo ""
echo -e "${BOLD}  ── Modulefiles ──${NC}"
echo    "  Location : $MODULEFILE_DIR"
echo    "  Usage    : module avail MLDL"
echo    "             module load  MLDL/<env>"
echo ""
echo    "  Ensure MODULEPATH includes /home/apps/modulefiles:"
echo    "    export MODULEPATH=\$MODULEPATH:/home/apps/modulefiles"
echo ""
echo    "  Sentinel dir : $DONE_DIR"
echo    "  Logs dir     : $LOG_DIR"
echo    "  Summary log  : $SUMMARY_LOG"
echo ""

if [[ $FAILED_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}All done!${NC}"
else
    echo -e "  ${RED}$FAILED_COUNT env(s) had failures. Re-run to retry only those.${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
