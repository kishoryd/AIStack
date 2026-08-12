#!/bin/bash
# =============================================================================
# Generates modulefiles/AIStack/<env>/<version> for every AIStack conda env
# that (a) exists and (b) has its key package actually installed. Envs not
# yet created, or mid-install, are skipped with a message rather than
# guessing at a version -- re-run this after install_aistack.sh finishes
# to pick up whatever wasn't ready yet.
#
# Also generates modulefiles/AIStack/miniconda/<version> -- the bare base
# conda/python install, no framework -- versioned off `conda --version`
# so it stays in sync if the base install itself is ever upgraded.
# =============================================================================
set -euo pipefail

OUT="$(dirname "${BASH_SOURCE[0]}")/modulefiles/AIStack"
CONDAROOT=/home/apps/miniconda
mkdir -p "$OUT"

if [[ -x "$CONDAROOT/bin/conda" ]]; then
  cversion=$("$CONDAROOT/bin/conda" --version 2>/dev/null | awk '{print $2}')
fi

if [[ -z "${cversion:-}" ]]; then
  echo "SKIP miniconda -- $CONDAROOT/bin/conda not found or --version failed"
else
  mkdir -p "$OUT/miniconda"
  find "$OUT/miniconda" -mindepth 1 -maxdepth 1 ! -name "$cversion" -exec rm -f {} \;

  out="$OUT/miniconda/$cversion"
  cat > "$out" <<EOF
#%Module1.0
#
# AIStack :: miniconda $cversion
# Base conda/python install, no framework -- for building a personal env.
# CUDA: n/a
#

module-whatis "AIStack miniconda $cversion :: base conda/python (no framework, CUDA n/a)"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  miniconda $cversion -- base conda/python install, no framework env."
    puts stderr ""
    puts stderr "  AIStack/* framework envs (unsloth, vllm, langchain, ...) are owned"
    puts stderr "  by cdacapp01: usable by anyone, but not writable. If you need a"
    puts stderr "  package that isn't already in one of those, build your own here:"
    puts stderr ""
    puts stderr "    module load AIStack/miniconda/$cversion"
    puts stderr "    conda create -n myenv python=3.11"
    puts stderr "    conda activate myenv"
    puts stderr ""
    puts stderr "  This module does not change your shell prompt. To confirm it loaded:"
    puts stderr "    echo \\\$CONDA_DEFAULT_ENV"
    puts stderr "    which python"
    puts stderr ""
}

# One conda env active at a time: loading another MLDL/AIStack module
# swaps this one out instead of stacking PATH entries.
family "condaenv"

set envpath $CONDAROOT

if { ![file isdirectory \$envpath] } {
    puts stderr "AIStack/miniconda/$cversion: \$envpath does not exist -- run install_aistack.sh first."
    break
}

setenv       CONDA_PREFIX       \$envpath
setenv       CONDA_DEFAULT_ENV  base
setenv       CONDA_SHLVL        1
setenv       VIRTUAL_ENV        \$envpath
prepend-path PATH               \$envpath/bin
EOF

  echo "wrote $out"
fi

# envname : pip-show package : category : cuda version : display name
declare -a ENTRIES=(
  "unsloth:unsloth:Finetuning:12.8 (cu128 wheel index):Unsloth"
  "transformers:transformers:Finetuning:12.8 (cu128 wheel index):Transformers"
  "accelerate:accelerate:Finetuning:12.8 (cu128 wheel index):Accelerate"
  "trl:trl:Finetuning:12.8 (cu128 wheel index):TRL"
  "axolotl:axolotl:Finetuning:12.8 (cu128 wheel index):Axolotl"
  "llamafactory:llamafactory:Finetuning:12.8 (cu128 wheel index):LLaMA-Factory"
  "torchtune:torchtune:Finetuning:12.8 (cu128 wheel index):TorchTune"
  "vllm:vllm:Inference:13.0 (cu130 wheel index):vLLM"
  "sglang:sglang:Inference:13.0 (cu130 wheel index):SGLang"
  "lmdeploy:lmdeploy:Inference:13.0 (cu130 wheel index):LMDeploy"
  "rayserve:ray:Inference:13.0 (cu130 wheel index):Ray Serve"
  "tgi:text-generation:Inference:13.0 (cu130 wheel index):TGI"
  "llamaindex:llama-index:RAG:13.0 (cu130 wheel index):LlamaIndex"
  "langchain:langchain:RAG:13.0 (cu130 wheel index):LangChain"
  "haystack:haystack-ai:RAG:13.0 (cu130 wheel index):Haystack"
  "mlflow:mlflow:Tracking:n/a (CPU-only, tracking service):MLflow"
  "pytorch-2.8:torch:Legacy:12.6 (cu126 wheel index):PyTorch"
  "tensorflow-2.20:tensorflow:Legacy:bundled via tensorflow[and-cuda] pip extra:TensorFlow GPU"
  "theano-1.0:theano:Legacy:n/a (GPU via pygpu/libgpuarray, not CUDA-indexed):Theano"
  "caffe-1.0:caffe:Legacy:n/a (GPU via caffe-gpu conda build):Caffe"
  "rapids-21.06:cudf:Legacy:11.2 (cudatoolkit=11.2):Rapids"
)

WROTE=0; SKIPPED=0

for e in "${ENTRIES[@]}"; do
  IFS=':' read -r envname pippkg category cudatag display <<< "$e"
  envpath="$CONDAROOT/envs/$envname"

  if [[ ! -d "$envpath" ]]; then
    echo "SKIP $envname -- env not created yet"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  version=$("$envpath/bin/pip" show "$pippkg" 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
  if [[ -z "$version" ]]; then
    echo "SKIP $envname -- '$pippkg' not installed yet (env exists, install still in progress)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Drop any stale version file for this env before writing the current
  # one, so module avail doesn't accumulate duplicates.
  mkdir -p "$OUT/$envname"
  find "$OUT/$envname" -mindepth 1 -maxdepth 1 ! -name "$version" -exec rm -f {} \;

  out="$OUT/$envname/$version"
  cat > "$out" <<EOF
#%Module1.0
#
# AIStack :: $display $version
# $category
# CUDA: $cudatag
#

module-whatis "AIStack $display $version :: $category, CUDA: $cudatag"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  $display $version"
    puts stderr "  Category : $category"
    puts stderr "  CUDA     : $cudatag"
    puts stderr "  Prefix   : $envpath"
    puts stderr ""
    puts stderr "  This module does not change your shell prompt. To confirm it loaded:"
    puts stderr "    echo \\\$CONDA_DEFAULT_ENV"
    puts stderr "    which python"
    puts stderr ""
}

# One conda env active at a time: loading another MLDL/AIStack module
# swaps this one out instead of stacking PATH entries.
family "condaenv"

set envpath $envpath

if { ![file isdirectory \$envpath] } {
    puts stderr "AIStack/$envname/$version: \$envpath does not exist -- run install_aistack.sh first."
    break
}

setenv       CONDA_PREFIX       \$envpath
setenv       CONDA_DEFAULT_ENV  $envname
setenv       CONDA_SHLVL        1
setenv       VIRTUAL_ENV        \$envpath
prepend-path PATH               \$envpath/bin
EOF

  echo "wrote $out"
  WROTE=$((WROTE + 1))
done

echo
echo "Wrote $WROTE modulefile(s), skipped $SKIPPED (not ready yet -- re-run later to pick them up)."
