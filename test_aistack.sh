#!/bin/bash
# =============================================================================
# AIStack Environment Test Suite
# =============================================================================
# Usage:
#   cd /home/apps/AIStack
#   bash test_aistack.sh
#
# IDEMPOTENT — re-running only re-tests envs that previously failed or are new.
# Envs that passed last run are skipped (use --force to re-test all).
#
#   bash test_aistack.sh           # skip previously-passed envs
#   bash test_aistack.sh --force   # re-test everything
# =============================================================================

set -o pipefail

FORCE=0
[[ "${1}" == "--force" ]] && FORCE=1

# ─── CONFIG ──────────────────────────────────────────────────────────────────
AISTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_DIR="/home/apps/miniconda3"
LOG_DIR="/home/apps/logs/tests"
SUMMARY_LOG="$LOG_DIR/test_summary.log"
PASS_DIR="/home/apps/logs/done/tests"   # sentinel: <env>.pass

mkdir -p "$LOG_DIR" "$PASS_DIR"

# ─── COLORS ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()      { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_pass() { echo -e "    ${GREEN}✔${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_fail() { echo -e "    ${RED}✘${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_warn() { echo -e "    ${YELLOW}⚠${NC} $*" | tee -a "$SUMMARY_LOG"; }
log_skip() { echo -e "    ${CYAN}⊘${NC} $*" | tee -a "$SUMMARY_LOG"; }

section() {
    echo "" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}  $*${NC}" | tee -a "$SUMMARY_LOG"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
}

# ─── SENTINELS ───────────────────────────────────────────────────────────────
mark_pass()    { touch "$PASS_DIR/$1.pass"; }
clear_pass()   { rm -f "$PASS_DIR/$1.pass"; }
already_pass() { [[ $FORCE -eq 0 && -f "$PASS_DIR/$1.pass" ]]; }

# ─── TRACKING ────────────────────────────────────────────────────────────────
declare -A ENV_STATUS ENV_FAILURES
TOTAL_ENVS=0; PASSED_ENVS=0; FAILED_ENVS=0; SKIPPED_ENVS=0

# ─── TEST HELPERS ────────────────────────────────────────────────────────────
check_env_exists() {
    local env="$1"
    if [[ -d "$CONDA_DIR/envs/$env" ]]; then
        log_pass "env directory exists"
        return 0
    else
        log_fail "env directory NOT found: $CONDA_DIR/envs/$env"
        return 1
    fi
}

check_python_version() {
    local env="$1" expected="$2"
    local actual
    actual=$("$CONDA_DIR/envs/$env/bin/python" --version 2>&1 | awk '{print $2}')
    if [[ "$actual" == ${expected}* ]]; then
        log_pass "Python $actual"
        return 0
    else
        log_fail "Python: got $actual, expected $expected.x"
        return 1
    fi
}

check_cuda() {
    local env="$1"
    local result
    result=$("$CONDA_DIR/envs/$env/bin/python" - 2>&1 <<'EOF'
import torch
avail = torch.cuda.is_available()
count = torch.cuda.device_count() if avail else 0
names = " | ".join(torch.cuda.get_device_name(i) for i in range(count)) if avail else "N/A"
print(f"available={avail} count={count} devices={names}")
EOF
)
    if echo "$result" | grep -q "available=True"; then
        local count names
        count=$(echo "$result" | grep -oP 'count=\K[0-9]+')
        names=$(echo "$result" | grep -oP 'devices=\K.*')
        log_pass "CUDA OK — $count GPU(s): $names"
        return 0
    else
        log_fail "CUDA NOT available (torch.cuda.is_available() = False)"
        return 1
    fi
}

check_kernel() {
    local env="$1"
    if [[ -d "$CONDA_DIR/envs/$env/share/jupyter/kernels/$env" ]]; then
        log_pass "JupyterHub kernel registered"
        return 0
    else
        log_warn "Kernel not registered for '$env'"
        return 1
    fi
}

# ─── MAIN TEST RUNNER ────────────────────────────────────────────────────────
# run_env_test ENV PYVER "import1 import2 ... jupyter jupyterlab ipykernel" DISPLAY_NAME
run_env_test() {
    local env="$1" pyver="$2" imports="$3" display="$4"
    local env_failed=()
    TOTAL_ENVS=$((TOTAL_ENVS + 1))

    echo "" | tee -a "$SUMMARY_LOG"
    log "▶ [$display] (env=$env)"

    # ── Already passed last run?
    if already_pass "$env"; then
        log_skip "Passed on previous run — skipping (use --force to re-test)"
        ENV_STATUS[$env]="PASS_CACHED"
        PASSED_ENVS=$((PASSED_ENVS + 1))
        return
    fi

    > "$LOG_DIR/${env}.log"

    # ── 1. Env exists?
    if ! check_env_exists "$env"; then
        ENV_STATUS[$env]="SKIP"
        ENV_FAILURES[$env]="env not installed"
        SKIPPED_ENVS=$((SKIPPED_ENVS + 1))
        return
    fi

    # ── 2. Python version
    check_python_version "$env" "$pyver" || env_failed+=("python-version")

    # ── 3. Package imports
    for pkg in $imports; do
        if "$CONDA_DIR/envs/$env/bin/python" -c "import $pkg" \
                >> "$LOG_DIR/${env}.log" 2>&1; then
            log_pass "import $pkg"
        else
            log_fail "import $pkg  FAILED"
            env_failed+=("import:$pkg")
        fi
    done

    # ── 4. CUDA (only if torch in imports)
    if echo "$imports" | grep -qw "torch"; then
        check_cuda "$env" || env_failed+=("cuda")
    fi

    # ── 5. Kernel
    check_kernel "$env" || env_failed+=("kernel")

    # ── Result
    if [[ ${#env_failed[@]} -eq 0 ]]; then
        ENV_STATUS[$env]="PASS"
        mark_pass "$env"
        PASSED_ENVS=$((PASSED_ENVS + 1))
    else
        ENV_STATUS[$env]="FAIL"
        ENV_FAILURES[$env]="${env_failed[*]}"
        clear_pass "$env"   # remove stale pass sentinel if any
        FAILED_ENVS=$((FAILED_ENVS + 1))
    fi
}

# =============================================================================
# TEST DEFINITIONS
# =============================================================================
log "=== AIStack Test Suite — $(date) ==="
[[ $FORCE -eq 1 ]] && log "  --force: re-testing all environments"

section "FINETUNING"
run_env_test unsloth      3.11 "torch torchvision unsloth triton jupyter jupyterlab ipykernel"            "Unsloth"
run_env_test transformers 3.11 "torch torchvision torchaudio transformers jupyter jupyterlab ipykernel"     "Transformers"
run_env_test accelerate   3.11 "torch torchvision torchaudio accelerate jupyter jupyterlab ipykernel"       "Accelerate"
run_env_test trl          3.11 "torch torchvision torchaudio trl jupyter jupyterlab ipykernel"              "TRL"
run_env_test axolotl      3.11 "torch axolotl jupyter jupyterlab ipykernel"                              "Axolotl"
run_env_test llamafactory 3.11 "torch torchvision torchaudio llamafactory jupyter jupyterlab ipykernel"     "LLaMA-Factory"
run_env_test torchtune    3.11 "torch torchvision torchaudio torchtune jupyter jupyterlab ipykernel"        "TorchTune"
run_env_test deepspeed    3.11 "torch torchvision torchaudio jupyter jupyterlab ipykernel"                 "DeepSpeed"

section "INFERENCE"
run_env_test vllm         3.11 "torch vllm jupyter jupyterlab ipykernel"                                    "vLLM"
run_env_test sglang       3.11 "torch sglang jupyter jupyterlab ipykernel"                                  "SGLang"
run_env_test lmdeploy     3.11 "torch lmdeploy jupyter jupyterlab ipykernel"                                "LMDeploy"
run_env_test rayserve     3.11 "torch ray vllm jupyter jupyterlab ipykernel"                                "Ray Serve"
run_env_test tgi          3.11 "torch text_generation jupyter jupyterlab ipykernel"                         "TGI"

section "RAG"
run_env_test llamaindex   3.11 "torch llama_index chromadb qdrant_client pymilvus sentence_transformers fastapi gradio jupyter jupyterlab ipykernel"            "LlamaIndex"
run_env_test langchain    3.11 "torch langchain langchain_core langgraph langsmith chromadb qdrant_client sentence_transformers streamlit fastapi jupyter jupyterlab ipykernel" "LangChain"
run_env_test haystack     3.11 "torch haystack chromadb qdrant_client sentence_transformers fastapi streamlit jupyter jupyterlab ipykernel"                     "Haystack"

section "LEGACY"
run_env_test pytorch  3.10 "torch torchvision jupyter jupyterlab ipykernel"  "PyTorch"
run_env_test tensorflow   3.10 "tensorflow jupyter jupyterlab ipykernel"          "TensorFlow GPU"
run_env_test Theano       3.10 "theano pygpu jupyter jupyterlab ipykernel"        "Theano"
run_env_test Caffe        3.7  "caffe jupyter jupyterlab ipykernel"               "Caffe"
run_env_test rapids       3.7  "cudf jupyter jupyterlab ipykernel"                "Rapids"

# =============================================================================
# FINAL REPORT
# =============================================================================
ALL_ENVS=(
    unsloth transformers accelerate trl axolotl llamafactory torchtune deepspeed
    vllm sglang lmdeploy rayserve tgi
    llamaindex langchain haystack
    pytorch tensorflow Theano Caffe rapids
)

echo "" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}                   TEST SUMMARY REPORT${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"

for env in "${ALL_ENVS[@]}"; do
    status="${ENV_STATUS[$env]:-SKIP}"
    case "$status" in
        PASS)        echo -e "  ${GREEN}✔ PASS${NC}        $env" | tee -a "$SUMMARY_LOG" ;;
        PASS_CACHED) echo -e "  ${GREEN}✔ PASS${NC} ${CYAN}(cached)${NC} $env" | tee -a "$SUMMARY_LOG" ;;
        FAIL)        echo -e "  ${RED}✘ FAIL${NC}        $env  →  ${ENV_FAILURES[$env]}" | tee -a "$SUMMARY_LOG" ;;
        SKIP)        echo -e "  ${YELLOW}⊘ SKIP${NC}        $env  →  ${ENV_FAILURES[$env]}" | tee -a "$SUMMARY_LOG" ;;
    esac
done

echo "" | tee -a "$SUMMARY_LOG"
echo -e "────────────────────────────────────────────────────────────" | tee -a "$SUMMARY_LOG"
echo -e "  Total: $TOTAL_ENVS   ${GREEN}Passed: $PASSED_ENVS${NC}   ${RED}Failed: $FAILED_ENVS${NC}   ${YELLOW}Skipped: $SKIPPED_ENVS${NC}" | tee -a "$SUMMARY_LOG"
echo -e "  Logs  : $LOG_DIR/<env>.log" | tee -a "$SUMMARY_LOG"
echo -e "  Report: $SUMMARY_LOG" | tee -a "$SUMMARY_LOG"
echo "" | tee -a "$SUMMARY_LOG"
[[ $FAILED_ENVS -gt 0 ]] && \
    echo -e "  ${YELLOW}Tip: re-run without --force to skip already-passing envs${NC}" | tee -a "$SUMMARY_LOG"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}" | tee -a "$SUMMARY_LOG"
