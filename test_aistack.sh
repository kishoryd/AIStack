#!/bin/bash
# =============================================================================
# AIStack Environment Test Suite
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   bash test_aistack.sh
#
# Tests every conda env for:
#   - Env exists
#   - Python version correct
#   - Core packages importable
#   - CUDA / GPU visible (torch.cuda.is_available)
#   - JupyterHub kernel registered
# Produces a per-env pass/fail report + detailed logs
# =============================================================================

set -o pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="$AISTACK_DIR/miniconda3"
LOG_DIR="$AISTACK_DIR/logs/tests"
SUMMARY_LOG="$LOG_DIR/test_summary.log"

mkdir -p "$LOG_DIR"
> "$SUMMARY_LOG"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── TRACKING ────────────────────────────────────────────────────────────────
declare -A ENV_STATUS      # env -> PASS | FAIL | SKIP
declare -A ENV_FAILURES    # env -> "test1, test2, ..."
TOTAL_ENVS=0
PASSED_ENVS=0
FAILED_ENVS=0
SKIPPED_ENVS=0

# ─── HELPERS ─────────────────────────────────────────────────────────────────
log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_pass() { echo -e "    ${GREEN}✔${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_fail() { echo -e "    ${RED}✘${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_warn() { echo -e "    ${YELLOW}⚠${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_info() { echo -e "    ${CYAN}ℹ${NC} $*" | tee -a "$SUMMARY_LOG"; }

section() {
    echo "" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}  $*${NC}" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
}

PYTHON() { "$CONDA_DIR/envs/$1/bin/python"; }

# ─── CORE TEST FUNCTIONS ─────────────────────────────────────────────────────

# check_env_exists ENV
check_env_exists() {
    local env="$1"
    if [[ -d "$CONDA_DIR/envs/$env" ]]; then
        log_pass "env directory exists: $CONDA_DIR/envs/$env"
        return 0
    else
        log_fail "env directory NOT found: $CONDA_DIR/envs/$env"
        return 1
    fi
}

# check_python_version ENV EXPECTED_VERSION (e.g. "3.11")
check_python_version() {
    local env="$1" expected="$2"
    local actual
    actual=$("$CONDA_DIR/envs/$env/bin/python" --version 2>&1 | awk '{print $2}')
    if [[ "$actual" == ${expected}* ]]; then
        log_pass "Python version: $actual"
        return 0
    else
        log_fail "Python version: got $actual, expected $expected.x"
        return 1
    fi
}

# check_import ENV pkg [pkg ...]  — tests each import individually
check_import() {
    local env="$1"; shift
    local failed=()
    for pkg in "$@"; do
        # handle sub-module imports (e.g. "torch.cuda")
        if "$CONDA_DIR/envs/$env/bin/python" -c "import $pkg" \
                >> "$LOG_DIR/${env}.log" 2>&1; then
            log_pass "import $pkg"
        else
            log_fail "import $pkg  FAILED"
            failed+=("$pkg")
        fi
    done
    [[ ${#failed[@]} -eq 0 ]] && return 0 || return 1
}

# check_cuda ENV — verifies torch sees a GPU
check_cuda() {
    local env="$1"
    local result
    result=$("$CONDA_DIR/envs/$env/bin/python" - <<'EOF' 2>&1
import torch
avail = torch.cuda.is_available()
count = torch.cuda.device_count() if avail else 0
name  = torch.cuda.get_device_name(0) if avail else "N/A"
print(f"available={avail} count={count} device={name}")
EOF
)
    echo "$result" >> "$LOG_DIR/${env}.log"
    if echo "$result" | grep -q "available=True"; then
        local count name
        count=$(echo "$result" | grep -oP 'count=\K[0-9]+')
        name=$(echo "$result"  | grep -oP 'device=\K.*')
        log_pass "CUDA available — $count GPU(s) detected: $name"
        return 0
    else
        log_fail "CUDA NOT available (torch.cuda.is_available() = False)"
        return 1
    fi
}

# check_kernel ENV — verifies ipykernel is registered
check_kernel() {
    local env="$1"
    if jupyter kernelspec list 2>/dev/null | grep -qi "^${env}"; then
        log_pass "JupyterHub kernel registered: $env"
        return 0
    else
        log_warn "JupyterHub kernel NOT found for: $env (jupyter may not be on PATH)"
        return 1   # warn only, not fatal
    fi
}

# ─── MASTER TEST RUNNER ───────────────────────────────────────────────────────
# run_env_test ENV PYTHON_VER "import1 import2 ..." DISPLAY_NAME
run_env_test() {
    local env="$1"
    local pyver="$2"
    local imports="$3"   # space-separated
    local display="$4"
    local env_failed=()
    TOTAL_ENVS=$((TOTAL_ENVS + 1))

    echo "" | tee -a "$SUMMARY_LOG"
    log "▶ Testing: ${BOLD}$display${NC} (env=$env)"
    > "$LOG_DIR/${env}.log"

    # 1. Env exists?
    if ! check_env_exists "$env"; then
        ENV_STATUS[$env]="SKIP"
        ENV_FAILURES[$env]="env not installed"
        SKIPPED_ENVS=$((SKIPPED_ENVS + 1))
        return
    fi

    # 2. Python version
    check_python_version "$env" "$pyver" || env_failed+=("python-version")

    # 3. Package imports
    local import_ok=true
    for pkg in $imports; do
        if ! "$CONDA_DIR/envs/$env/bin/python" -c "import $pkg" \
                >> "$LOG_DIR/${env}.log" 2>&1; then
            log_fail "import $pkg  FAILED"
            env_failed+=("import:$pkg")
            import_ok=false
        else
            log_pass "import $pkg"
        fi
    done

    # 4. CUDA check (only if torch is in import list)
    if echo "$imports" | grep -qw "torch"; then
        check_cuda "$env" || env_failed+=("cuda")
    fi

    # 5. Kernel check
    check_kernel "$env" || env_failed+=("kernel")

    # ── result
    if [[ ${#env_failed[@]} -eq 0 ]]; then
        ENV_STATUS[$env]="PASS"
        PASSED_ENVS=$((PASSED_ENVS + 1))
    else
        ENV_STATUS[$env]="FAIL"
        ENV_FAILURES[$env]="${env_failed[*]}"
        FAILED_ENVS=$((FAILED_ENVS + 1))
    fi
}

# =============================================================================
# TEST DEFINITIONS
# =============================================================================

section "FINETUNING ENVIRONMENTS"

run_env_test unsloth 3.11 \
    "torch torchvision torchaudio unsloth triton" \
    "Unsloth"

run_env_test transformers 3.11 \
    "torch torchvision torchaudio transformers" \
    "Transformers"

run_env_test accelerate 3.11 \
    "torch torchvision torchaudio accelerate" \
    "Accelerate"

run_env_test trl 3.11 \
    "torch torchvision torchaudio trl" \
    "TRL"

run_env_test axolotl 3.11 \
    "torch torchvision torchaudio axolotl" \
    "Axolotl"

run_env_test llamafactory 3.11 \
    "torch torchvision torchaudio llamafactory" \
    "LLaMA-Factory"

run_env_test torchtune 3.11 \
    "torch torchvision torchaudio torchtune" \
    "TorchTune"

run_env_test deepspeed 3.11 \
    "torch torchvision torchaudio deepspeed" \
    "DeepSpeed"

section "INFERENCE ENVIRONMENTS"

run_env_test vllm 3.11 \
    "torch vllm" \
    "vLLM"

run_env_test sglang 3.11 \
    "torch sglang" \
    "SGLang"

run_env_test lmdeploy 3.11 \
    "torch lmdeploy" \
    "LMDeploy"

run_env_test rayserve 3.11 \
    "torch ray vllm" \
    "Ray Serve"

run_env_test tgi 3.11 \
    "torch text_generation" \
    "TGI"

section "RAG ENVIRONMENTS"

run_env_test llamaindex 3.11 \
    "torch llama_index chromadb qdrant_client pymilvus sentence_transformers fastapi gradio" \
    "LlamaIndex"

run_env_test langchain 3.11 \
    "torch langchain langchain_core langgraph langsmith chromadb qdrant_client sentence_transformers streamlit fastapi" \
    "LangChain"

run_env_test haystack 3.11 \
    "torch haystack chromadb qdrant_client sentence_transformers fastapi streamlit" \
    "Haystack"

section "LEGACY ENVIRONMENTS"

run_env_test pytorch_gpu 3.10 \
    "torch torchvision" \
    "PyTorch GPU"

run_env_test tensorflow 3.10 \
    "tensorflow" \
    "TensorFlow GPU"

# Theano & Caffe — just check env exists + python boots
run_env_test Theano 3.11 \
    "theano" \
    "Theano"

run_env_test Caffe 3.11 \
    "caffe" \
    "Caffe"

# =============================================================================
# FINAL SUMMARY REPORT
# =============================================================================
echo "" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}                   TEST SUMMARY REPORT${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"

ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune deepspeed
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    pytorch_gpu tensorflow Theano Caffe
)

for env in "${ALL_ENVS[@]}"; do
    status="${ENV_STATUS[$env]:-SKIP}"
    case "$status" in
        PASS) echo -e "  ${GREEN}✔ PASS${NC}  $env" | tee -a "$SUMMARY_LOG" ;;
        FAIL) echo -e "  ${RED}✘ FAIL${NC}  $env  →  ${ENV_FAILURES[$env]}" | tee -a "$SUMMARY_LOG" ;;
        SKIP) echo -e "  ${YELLOW}⊘ SKIP${NC}  $env  →  ${ENV_FAILURES[$env]}" | tee -a "$SUMMARY_LOG" ;;
    esac
done

echo "" | tee -a "$SUMMARY_LOG"
echo -e "────────────────────────────────────────────────────────────" | tee -a "$SUMMARY_LOG"
echo -e "  Total : $TOTAL_ENVS   ${GREEN}Passed : $PASSED_ENVS${NC}   ${RED}Failed : $FAILED_ENVS${NC}   ${YELLOW}Skipped : $SKIPPED_ENVS${NC}" | tee -a "$SUMMARY_LOG"
echo -e "  Detailed logs : $LOG_DIR/<env>.log" | tee -a "$SUMMARY_LOG"
echo -e "  Summary log   : $SUMMARY_LOG" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"

if [[ $FAILED_ENVS -eq 0 && $SKIPPED_ENVS -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}🎉 All environments passed!${NC}" | tee -a "$SUMMARY_LOG"
elif [[ $FAILED_ENVS -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}⚠  $FAILED_ENVS environment(s) failed. Check logs above.${NC}" | tee -a "$SUMMARY_LOG"
fi
if [[ $SKIPPED_ENVS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}⊘  $SKIPPED_ENVS environment(s) skipped (not installed).${NC}" | tee -a "$SUMMARY_LOG"
fi
echo -e "════════════════════════════════════════════════════════════" | tee -a "$SUMMARY_LOG"
