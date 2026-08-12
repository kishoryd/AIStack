#!/bin/bash
set -o pipefail

AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="${AISTACK_CONDA_DIR:-/home/apps/miniconda}"
TORCH_CU128="https://download.pytorch.org/whl/cu128"
TORCH_CU130="https://download.pytorch.org/whl/cu130"
LOG_DIR="$AISTACK_DIR/logs"
SUMMARY_LOG="$LOG_DIR/install_summary.log"
DONE_DIR="$LOG_DIR/done"

mkdir -p "$LOG_DIR" "$DONE_DIR"

log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_ok()  { echo "  ✔ $*" | tee -a "$SUMMARY_LOG"; }
log_skip(){ echo "  ⊘ $*" | tee -a "$SUMMARY_LOG"; }
log_err() { echo "  ✘ $*" | tee -a "$SUMMARY_LOG"; }

mark_done()  { touch "$DONE_DIR/$1.done"; }
is_done()    { [[ -f "$DONE_DIR/$1.done" ]]; }
env_exists() { [[ -d "$CONDA_DIR/envs/$1" ]]; }

pkg_installed() {
    local env="$1" pkg="$2"
    local mod
    mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
    "$CONDA_DIR/envs/$env/bin/python" -c "import $mod" &>/dev/null
}

declare -A ENV_ERRORS
declare -A ENV_SKIPPED

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

# Like pip_install(), but also offers the CUDA wheel index as an *extra*
# source (default PyPI stays primary). Use this for anything installed
# AFTER a GPU torch build in the same env: several of these packages list
# "torch" as a plain dependency, and without the extra index pip's resolver
# can silently pull a fresh CPU-only torch from PyPI to satisfy it,
# clobbering the CUDA build we just installed. Per PEP 440, a local version
# segment (e.g. 2.8.0+cu128) outranks the bare 2.8.0 from PyPI, so as long
# as the CUDA index is visible pip keeps the GPU wheel.
pip_install_extra() {
    local env="$1"; local extra_index_url="$2"; shift 2
    local failed=()
    for pkg in "$@"; do
        local mod
        mod=$(echo "$pkg" | sed 's/\[.*\]//' | sed 's/-/_/g' | awk '{print $1}')
        if pkg_installed "$env" "$mod"; then
            log_skip "already installed: $pkg (env: $env)"
            continue
        fi
        log "  pip install $pkg --extra-index-url $extra_index_url (env: $env)"
        if "$CONDA_DIR/envs/$env/bin/pip" install $pkg --extra-index-url "$extra_index_url" >> "$LOG_DIR/${env}.log" 2>&1; then
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

# Baseline packages every env gets, on top of its own framework-specific
# installs, so any general-purpose project (not just the framework's own
# use case) can run in that env without hunting for a different one.
# Mix of classic data-science stack + packages that show up in most
# current (2026) AI/ML work regardless of which framework the env is for.
COMMON_PKGS=(
    numpy pandas matplotlib scikit-learn scipy tqdm requests pyyaml
    huggingface_hub datasets pillow einops safetensors
)

install_common() {
    local env="$1"
    pip_install "$env" "${COMMON_PKGS[@]}"
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

# =============================================================================
# STEP 1 — MINICONDA
# =============================================================================
# Deliberately a *separate* install from /home/apps/MLDL/DL-CondaPy3.10 (the
# production MLDL conda base) -- keeps AIStack fully isolated from those
# already-working, GPU-verified envs. It also sidesteps whatever produced
# a broken libcrypto.so.3 there (conda's binary prefix-replacement step
# corrupting openssl on every new env in that base): that conda was built
# through some internal Anaconda croot/build-farm pipeline (visible in its
# has_prefix placeholder paths), which a plain upstream Miniconda installer
# doesn't go through.
log "=== AIStack Installer — $(date) ==="

if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
    MINICONDA_SH="/tmp/miniconda-$$.sh"
    MINICONDA_OK=0
    for attempt in 1 2 3; do
        log "Downloading Miniconda (attempt $attempt/3)..."
        rm -f "$MINICONDA_SH"
        if wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
                -O "$MINICONDA_SH" \
            && [[ $(stat -c%s "$MINICONDA_SH" 2>/dev/null || echo 0) -gt 50000000 ]]; then
            MINICONDA_OK=1
            break
        fi
        log_err "Download attempt $attempt failed or file too small ($(stat -c%s "$MINICONDA_SH" 2>/dev/null || echo 0) bytes) — retrying"
        sleep 3
    done

    if [[ $MINICONDA_OK -ne 1 ]]; then
        echo "FATAL: could not download Miniconda after 3 attempts. Check network/DNS (must run from the login node)." >&2
        exit 1
    fi

    log "Installing Miniconda to $CONDA_DIR..."
    if ! bash "$MINICONDA_SH" -b -p "$CONDA_DIR"; then
        echo "FATAL: Miniconda installer failed — see above." >&2
        exit 1
    fi
    rm -f "$MINICONDA_SH"

    if [[ ! -f "$CONDA_DIR/bin/conda" ]]; then
        echo "FATAL: Miniconda installer reported success but $CONDA_DIR/bin/conda is missing." >&2
        exit 1
    fi
else
    log_skip "Miniconda already at $CONDA_DIR"
fi

export PATH="$CONDA_DIR/bin:$PATH"
source "$CONDA_DIR/bin/activate"
export CONDA_TOS_ACCEPTED=true
conda tos accept 2>/dev/null || true
log_ok "Conda ready"

log "Installing python and pip in base env..."
"$CONDA_DIR/bin/conda" install -y python pip &>/dev/null \
    && log_ok "python and pip installed in base env" \
    || log_err "Failed to install python/pip in base env"

log "Installing uv in base env..."
"$CONDA_DIR/bin/pip" install uv &>/dev/null \
    && log_ok "uv installed in base env" \
    || log_err "Failed to install uv in base env"

# =============================================================================
# FINETUNING
# =============================================================================

log "=== FINETUNING: unsloth ==="
begin_env unsloth 3.11 && {
    install_common "unsloth"
    pip_install_with_index unsloth "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install_extra unsloth "$TORCH_CU128" "ninja" "triton" "unsloth"
    register_kernel unsloth "Unsloth (Python 3.11)"
    [[ -z "${ENV_ERRORS[unsloth]}" ]] && mark_done unsloth
}

log "=== FINETUNING: transformers ==="
begin_env transformers 3.11 && {
    install_common "transformers"
    pip_install_with_index transformers "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install_extra transformers "$TORCH_CU128" "transformers" "mlflow"
    register_kernel transformers "Transformers (Python 3.11)"
    [[ -z "${ENV_ERRORS[transformers]}" ]] && mark_done transformers
}

log "=== FINETUNING: accelerate ==="
begin_env accelerate 3.11 && {
    install_common "accelerate"
    pip_install_with_index accelerate "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install_extra accelerate "$TORCH_CU128" "accelerate" "mlflow"
    register_kernel accelerate "Accelerate (Python 3.11)"
    [[ -z "${ENV_ERRORS[accelerate]}" ]] && mark_done accelerate
}

log "=== FINETUNING: trl ==="
begin_env trl 3.11 && {
    install_common "trl"
    pip_install_with_index trl "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install_extra trl "$TORCH_CU128" "trl" "mlflow"
    register_kernel trl "TRL (Python 3.11)"
    [[ -z "${ENV_ERRORS[trl]}" ]] && mark_done trl
}

log "=== FINETUNING: axolotl ==="
begin_env axolotl 3.11 && {
    install_common "axolotl"
    pip_install_with_index axolotl "$TORCH_CU128" "torch" "torchaudio"
    pip_install_extra axolotl "$TORCH_CU128" "ninja" "packaging" "axolotl[deepspeed]" "mlflow"
    register_kernel axolotl "Axolotl (Python 3.11)"
    [[ -z "${ENV_ERRORS[axolotl]}" ]] && mark_done axolotl
}

log "=== FINETUNING: llamafactory ==="
begin_env llamafactory 3.11 && {
    install_common "llamafactory"
    pip_install_with_index llamafactory "$TORCH_CU128" "torch" "torchvision" "torchaudio"
    pip_install_extra llamafactory "$TORCH_CU128" "ninja" "llamafactory[metrics]" "mlflow"
    register_kernel llamafactory "LLaMA-Factory (Python 3.11)"
    [[ -z "${ENV_ERRORS[llamafactory]}" ]] && mark_done llamafactory
}

log "=== FINETUNING: torchtune ==="
begin_env torchtune 3.11 && {
    install_common "torchtune"
    pip_install_with_index torchtune "$TORCH_CU128" "torch" "torchvision" "torchaudio" "torchao"
    pip_install_extra torchtune "$TORCH_CU128" "torchtune" "mlflow"
    register_kernel torchtune "TorchTune (Python 3.11)"
    [[ -z "${ENV_ERRORS[torchtune]}" ]] && mark_done torchtune
}

# =============================================================================
# INFERENCE
# =============================================================================

log "=== INFERENCE: vllm ==="
begin_env vllm 3.11 && {
    install_common "vllm"
    pip_install_with_index vllm "$TORCH_CU130" "torch"
    pip_install_extra vllm "$TORCH_CU130" "vllm"
    register_kernel vllm "vLLM (Python 3.11)"
    [[ -z "${ENV_ERRORS[vllm]}" ]] && mark_done vllm
}

log "=== INFERENCE: sglang ==="
begin_env sglang 3.11 && {
    install_common "sglang"
    pip_install_with_index sglang "$TORCH_CU130" "torch"
    pip_install_extra sglang "$TORCH_CU130" "sglang[all]"
    register_kernel sglang "SGLang (Python 3.11)"
    [[ -z "${ENV_ERRORS[sglang]}" ]] && mark_done sglang
}

log "=== INFERENCE: lmdeploy ==="
begin_env lmdeploy 3.11 && {
    install_common "lmdeploy"
    pip_install_with_index lmdeploy "$TORCH_CU130" "torch"
    pip_install_extra lmdeploy "$TORCH_CU130" "lmdeploy"
    register_kernel lmdeploy "LMDeploy (Python 3.11)"
    [[ -z "${ENV_ERRORS[lmdeploy]}" ]] && mark_done lmdeploy
}

log "=== INFERENCE: rayserve ==="
begin_env rayserve 3.11 && {
    install_common "rayserve"
    pip_install_with_index rayserve "$TORCH_CU130" "torch"
    pip_install_extra rayserve "$TORCH_CU130" "ray[serve,air,tune]" "vllm"
    register_kernel rayserve "Ray Serve (Python 3.11)"
    [[ -z "${ENV_ERRORS[rayserve]}" ]] && mark_done rayserve
}

log "=== INFERENCE: tgi ==="
begin_env tgi 3.11 && {
    install_common "tgi"
    pip_install_with_index tgi "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install_extra tgi "$TORCH_CU130" "text-generation"
    register_kernel tgi "TGI (Python 3.11)"
    [[ -z "${ENV_ERRORS[tgi]}" ]] && mark_done tgi
}

# =============================================================================
# RAG
# =============================================================================

log "=== RAG: llamaindex ==="
begin_env llamaindex 3.11 && {
    install_common "llamaindex"
    pip_install_with_index llamaindex "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install_extra llamaindex "$TORCH_CU130" \
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
    install_common "langchain"
    pip_install_with_index langchain "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install_extra langchain "$TORCH_CU130" \
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
    install_common "haystack"
    pip_install_with_index haystack "$TORCH_CU130" "torch" "torchvision" "torchaudio"
    pip_install_extra haystack "$TORCH_CU130" \
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

# =============================================================================
# TRACKING
# =============================================================================

log "=== TRACKING: mlflow ==="
begin_env mlflow 3.11 && {
    install_common "mlflow"
    pip_install mlflow "mlflow" "sqlalchemy" "psutil"
    register_kernel mlflow "MLflow (Python 3.11)"
    [[ -z "${ENV_ERRORS[mlflow]}" ]] && mark_done mlflow
}

# =============================================================================
# LEGACY
# =============================================================================
# Named after their pinned version (pytorch-2.8, theano-1.0, ...) rather than
# the bare framework name: this AIStack conda base is separate from
# /home/apps/MLDL/DL-CondaPy3.10 (which already has its own production
# "Theano"/"Caffe"/etc. envs, GPU-verified earlier), so there's no actual
# name collision risk here anymore -- kept the specific naming anyway since
# it also documents exactly which version you get, and re-running with a
# different pin later won't silently overwrite the old one.

log "=== LEGACY: pytorch-2.8 ==="
begin_env pytorch-2.8 3.10 && {
    install_common "pytorch-2.8"
    pip_install_with_index pytorch-2.8 "https://download.pytorch.org/whl/cu126" \
        "torch==2.8.0+cu126" "torchvision==0.23.0+cu126"
    register_kernel pytorch-2.8 "PyTorch (Python 3.10, AIStack)"
    [[ -z "${ENV_ERRORS[pytorch-2.8]}" ]] && mark_done pytorch-2.8
}

log "=== LEGACY: tensorflow-2.20 ==="
begin_env tensorflow-2.20 3.10 && {
    install_common "tensorflow-2.20"
    pip_install tensorflow-2.20 "tensorflow[and-cuda]==2.20.0"
    register_kernel tensorflow-2.20 "TensorFlow GPU (Python 3.10, AIStack)"
    [[ -z "${ENV_ERRORS[tensorflow-2.20]}" ]] && mark_done tensorflow-2.20
}

log "=== LEGACY: theano-1.0 ==="
begin_env theano-1.0 3.8 && {
    install_common "theano-1.0"
    conda_install theano-1.0 -c conda-forge theano=1.0.5 pygpu=0.7.6 "numpy<1.24" python=3.8
    conda_install theano-1.0 mkl-service
    register_kernel theano-1.0 "Theano (Python 3.8, AIStack)"
    [[ -z "${ENV_ERRORS[theano-1.0]}" ]] && mark_done theano-1.0
}

log "=== LEGACY: caffe-1.0 ==="
begin_env caffe-1.0 3.7 && {
    install_common "caffe-1.0"
    conda_install caffe-1.0 -c anaconda caffe-gpu=1.0
    register_kernel caffe-1.0 "Caffe (Python 3.7, AIStack)"
    [[ -z "${ENV_ERRORS[caffe-1.0]}" ]] && mark_done caffe-1.0
}

log "=== LEGACY: rapids-21.06 ==="
begin_env rapids-21.06 3.7 && {
    install_common "rapids-21.06"
    conda_install rapids-21.06 -c rapidsai -c nvidia -c numba -c conda-forge cudf=21.06 cudatoolkit=11.2
    register_kernel rapids-21.06 "Rapids (Python 3.7, AIStack)"
    [[ -z "${ENV_ERRORS[rapids-21.06]}" ]] && mark_done rapids-21.06
}

# =============================================================================
# SUMMARY
# =============================================================================
ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    mlflow
    pytorch-2.8 tensorflow-2.20 theano-1.0 caffe-1.0 rapids-21.06
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
    echo "  All done!"
else
    echo "  $FAILED_COUNT env(s) had failures. Re-run to retry only those."
fi
echo "════════════════════════════════════════════════════════════"
