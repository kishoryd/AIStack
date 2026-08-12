#!/bin/bash
set -euo pipefail

OUT="$(dirname "${BASH_SOURCE[0]}")/modulefiles/AIStack"
CONDAROOT=/home/apps/MLDL/DL-CondaPy3.10
mkdir -p "$OUT"

# file_name : label
declare -a ENTRIES=(
  "unsloth:Unsloth (Finetuning)"
  "transformers:Transformers (Finetuning)"
  "accelerate:Accelerate (Finetuning)"
  "trl:TRL (Finetuning)"
  "axolotl:Axolotl (Finetuning)"
  "llamafactory:LLaMA-Factory (Finetuning)"
  "torchtune:TorchTune (Finetuning)"
  "vllm:vLLM (Inference)"
  "sglang:SGLang (Inference)"
  "lmdeploy:LMDeploy (Inference)"
  "rayserve:Ray Serve (Inference)"
  "tgi:TGI (Inference)"
  "llamaindex:LlamaIndex (RAG)"
  "langchain:LangChain (RAG)"
  "haystack:Haystack (RAG)"
  "mlflow:MLflow (Tracking)"
  "pytorch-2.8:PyTorch (Legacy)"
  "tensorflow-2.20:TensorFlow GPU (Legacy)"
  "theano-1.0:Theano (Legacy)"
  "caffe-1.0:Caffe (Legacy)"
  "rapids-21.06:Rapids (Legacy)"
)

for e in "${ENTRIES[@]}"; do
  envname="${e%%:*}"
  label="${e#*:}"
  out="$OUT/$envname"

  cat > "$out" <<EOF
#%Module1.0

## AIStack/$envname - $label
## Conda environment shipped under $CONDAROOT/envs/$envname

set condaroot $CONDAROOT
set envname   $envname
set envpath   \$condaroot/envs/\$envname

module-whatis "$label conda environment ($envname)"

proc ModulesHelp { } {
    global envname envpath
    puts stderr "Loads the \$envname conda environment."
    puts stderr "  CONDA_PREFIX -> \$envpath"
}

# Shares the same family as the MLDL modules -- they're conda envs in
# the same conda base, so loading one of these auto-swaps out any
# currently-loaded MLDL or AIStack env instead of stacking PATH entries.
family "condaenv"

if { ![file isdirectory \$envpath] } {
    puts stderr "AIStack/$envname: environment path \$envpath does not exist -- run install_aistack.sh first."
    break
}

setenv       CONDA_PREFIX       \$envpath
setenv       CONDA_DEFAULT_ENV  \$envname
setenv       CONDA_SHLVL        1
setenv       VIRTUAL_ENV        \$envpath
prepend-path PATH               \$envpath/bin
EOF

  echo "wrote $out"
done
