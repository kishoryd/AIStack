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
WROTE=0; SKIPPED=0

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
    puts stderr "AIStack/miniconda/$cversion: \$envpath does not exist"
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

# deepspeed JIT-compiles several ops (fused adam, transformer kernels, ...)
# via nvcc/gcc at first *use*, not just at install time -- unlike every
# other module here, it needs a real CUDA compiler toolchain on PATH at
# runtime too, which conda doesn't provide. Same spack gcc-12.5.0 +
# cuda-12.9.1 pair install_aistack.sh builds it with (see SPACK_GCC/
# SPACK_CUDA there) -- special-cased here since no other entry needs this.
SPACK_GCC="/home/apps/spack/opt/spack/linux-cascadelake/gcc-12.5.0-2abo2si4ifm6qax4q4fyqc6hi4d4hq3e"
SPACK_CUDA="/home/apps/spack/opt/spack/linux-cascadelake/cuda-12.9.1-cl6xkxoxd64xi53nykj7k7bjzaadg7iw"

envname=deepspeed; envpath="$CONDAROOT/envs/$envname"
if [[ ! -d "$envpath" ]]; then
  echo "SKIP deepspeed -- env not created yet"
  SKIPPED=$((SKIPPED + 1))
else
  version=$("$envpath/bin/pip" show deepspeed 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
  if [[ -z "$version" ]]; then
    echo "SKIP deepspeed -- 'deepspeed' not installed yet (env exists, install still in progress)"
    SKIPPED=$((SKIPPED + 1))
  else
    mkdir -p "$OUT/deepspeed"
    find "$OUT/deepspeed" -mindepth 1 -maxdepth 1 ! -name "$version" -exec rm -f {} \;
    out="$OUT/deepspeed/$version"
    cat > "$out" <<EOF
#%Module1.0
#
# AIStack :: DeepSpeed $version
# Finetuning
# CUDA: 12.9 (spack gcc-12.5.0 + cuda-12.9.1, needed for op JIT builds)
#

module-whatis "AIStack DeepSpeed $version :: Finetuning, CUDA: 12.9 (spack toolchain for op JIT builds)"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  DeepSpeed $version"
    puts stderr "  Category : Finetuning"
    puts stderr "  CUDA     : 12.9 (spack gcc-12.5.0 + cuda-12.9.1)"
    puts stderr "  Prefix   : $envpath"
    puts stderr ""
    puts stderr "  DeepSpeed JIT-compiles several ops (fused adam, transformer"
    puts stderr "  kernels, ...) via nvcc/gcc the first time they're used, not"
    puts stderr "  just at install time -- this module puts a matching compiler"
    puts stderr "  toolchain on PATH so that still works at runtime."
    puts stderr ""
    puts stderr "  This module does not change your shell prompt. To confirm it loaded:"
    puts stderr "    echo \\\$CONDA_DEFAULT_ENV"
    puts stderr "    which python"
    puts stderr ""
}

# One conda env active at a time: loading another MLDL/AIStack module
# swaps this one out instead of stacking PATH entries.
family "condaenv"

set envpath   $envpath
set spackgcc  $SPACK_GCC
set spackcuda $SPACK_CUDA

if { ![file isdirectory \$envpath] } {
    puts stderr "AIStack/deepspeed/$version: \$envpath does not exist"
    break
}
if { ![file isdirectory \$spackcuda] } {
    puts stderr "AIStack/deepspeed/$version: \$spackcuda does not exist -- op JIT builds will fail"
    break
}

setenv       CONDA_PREFIX       \$envpath
setenv       CONDA_DEFAULT_ENV  $envname
setenv       CONDA_SHLVL        1
setenv       VIRTUAL_ENV        \$envpath
setenv       CUDA_HOME          \$spackcuda
setenv       CC                 \$spackgcc/bin/gcc
setenv       CXX                \$spackgcc/bin/g++
prepend-path PATH               \$envpath/bin
prepend-path PATH               \$spackgcc/bin
prepend-path PATH               \$spackcuda/bin
prepend-path LD_LIBRARY_PATH    \$spackcuda/targets/x86_64-linux/lib
EOF
    echo "wrote $out"
    WROTE=$((WROTE + 1))
  fi
fi

# pygpu (theano's GPU backend) JIT-compiles GPU kernels at runtime via
# libnvrtc.so, which the conda env doesn't provide on its own (theano-1.0
# was installed with no cudatoolkit package at all) -- without this,
# pygpu.init('cuda') fails with "Could not load libnvrtc.so". Verified
# working against spack's cuda-12.9.1 despite pygpu/libgpuarray being a
# much older (~2019) library than that CUDA release.
envname=theano-1.0; envpath="$CONDAROOT/envs/$envname"
if [[ ! -d "$envpath" ]]; then
  echo "SKIP theano-1.0 -- env not created yet"
  SKIPPED=$((SKIPPED + 1))
else
  version=$("$CONDAROOT/bin/conda" list -n "$envname" 2>/dev/null | awk '$1 == "theano" {print $2; exit}')
  if [[ -z "$version" ]]; then
    echo "SKIP theano-1.0 -- 'theano' not installed yet (env exists, install still in progress)"
    SKIPPED=$((SKIPPED + 1))
  else
    mkdir -p "$OUT/theano"
    find "$OUT/theano" -mindepth 1 -maxdepth 1 ! -name "$version" -exec rm -f {} \;
    out="$OUT/theano/$version"
    cat > "$out" <<EOF
#%Module1.0
#
# AIStack :: Theano $version
# Legacy
# CUDA: 12.9 (spack cuda-12.9.1, runtime libnvrtc.so for pygpu JIT)
#

module-whatis "AIStack Theano $version :: Legacy, CUDA: 12.9 (runtime libnvrtc.so for pygpu JIT)"

proc ModulesHelp { } {
    puts stderr ""
    puts stderr "  Theano $version"
    puts stderr "  Category : Legacy"
    puts stderr "  CUDA     : 12.9 (spack cuda-12.9.1, runtime libnvrtc.so for pygpu JIT)"
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

set envpath   $envpath
set spackcuda "$SPACK_CUDA"

if { ![file isdirectory \$envpath] } {
    puts stderr "AIStack/theano/$version: \$envpath does not exist"
    break
}

setenv       CONDA_PREFIX       \$envpath
setenv       CONDA_DEFAULT_ENV  $envname
setenv       CONDA_SHLVL        1
setenv       VIRTUAL_ENV        \$envpath
prepend-path PATH               \$envpath/bin
prepend-path LD_LIBRARY_PATH    \$spackcuda/targets/x86_64-linux/lib
EOF
    echo "wrote $out"
    WROTE=$((WROTE + 1))
  fi
fi

# envname : modname : pip-show package : category : cuda version : display name
#
# modname is the exposed Lmod module name (module avail / module load).
# It's the same as envname (the conda env dir name) for most entries, but
# the Legacy envs were created with a version baked into the env name
# itself (e.g. "pytorch-2.8") to dodge collisions with production MLDL
# envs of the same bare name -- modname strips that back off so the
# module shows up as pytorch/2.8.0+cu126 like everything else, with the
# version living only in the version slot, not duplicated in the name.
declare -a ENTRIES=(
  "unsloth:unsloth:unsloth:Finetuning:12.8 (cu128 wheel index):Unsloth"
  "transformers:transformers:transformers:Finetuning:12.8 (cu128 wheel index):Transformers"
  "accelerate:accelerate:accelerate:Finetuning:12.8 (cu128 wheel index):Accelerate"
  "trl:trl:trl:Finetuning:12.8 (cu128 wheel index):TRL"
  "axolotl:axolotl:axolotl:Finetuning:12.8 (cu128 wheel index):Axolotl"
  "llamafactory:llamafactory:llamafactory:Finetuning:12.8 (cu128 wheel index):LLaMA-Factory"
  "torchtune:torchtune:torchtune:Finetuning:12.8 (cu128 wheel index):TorchTune"
  "nemo:nemo:nemo_toolkit:Finetuning:12.8 (cu128 wheel index):NVIDIA NeMo"
  "vllm:vllm:vllm:Inference:13.0 (cu130 wheel index):vLLM"
  "sglang:sglang:sglang:Inference:13.0 (cu130 wheel index):SGLang"
  "lmdeploy:lmdeploy:lmdeploy:Inference:13.0 (cu130 wheel index):LMDeploy"
  "rayserve:rayserve:ray:Inference:13.0 (cu130 wheel index):Ray Serve"
  "tgi:tgi:text-generation:Inference:13.0 (cu130 wheel index):TGI"
  "llamaindex:llamaindex:llama-index:RAG:13.0 (cu130 wheel index):LlamaIndex"
  "langchain:langchain:langchain:RAG:13.0 (cu130 wheel index):LangChain"
  "haystack:haystack:haystack-ai:RAG:13.0 (cu130 wheel index):Haystack"
  "mlflow:mlflow:mlflow:Tracking:n/a (CPU-only, tracking service):MLflow"
  "pytorch-2.8:pytorch:torch:Legacy:12.6 (cu126 wheel index):PyTorch"
  "tensorflow-2.20:tensorflow:tensorflow:Legacy:bundled with pip package:TensorFlow GPU"
  "caffe-1.0:caffe:caffe:Legacy:n/a (GPU via caffe-gpu conda build):Caffe"
  "rapids-21.06:rapids:cudf:Legacy:11.2 (cudatoolkit=11.2):Rapids"
  "tensorrt-llm:tensorrt-llm:tensorrt_llm:Inference:bundled via NVIDIA pypi index:TensorRT-LLM"
  "diffusion:diffusion:diffusers:Generation:12.8 (cu128 wheel index):Diffusion Models"
)

for e in "${ENTRIES[@]}"; do
  IFS=':' read -r envname modname pippkg category cudatag display <<< "$e"
  envpath="$CONDAROOT/envs/$envname"

  if [[ ! -d "$envpath" ]]; then
    echo "SKIP $envname -- env not created yet"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  version=$("$envpath/bin/pip" show "$pippkg" 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
  if [[ -z "$version" ]]; then
    # Some legacy packages (e.g. caffe-gpu) are conda-only with no pip
    # dist-info, so `pip show` never finds them -- fall back to conda's
    # own package list, matching any conda package name that starts with
    # $pippkg (e.g. pippkg=caffe matches installed package "caffe-gpu").
    version=$("$CONDAROOT/bin/conda" list -n "$envname" 2>/dev/null | awk -v p="$pippkg" '$1 ~ "^"p"($|-)" {print $2; exit}')
  fi
  if [[ -z "$version" ]]; then
    echo "SKIP $envname -- '$pippkg' not installed yet (env exists, install still in progress)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Some conda packages (e.g. rapidsai's cudf) report a git-describe-style
  # local version segment (+21.g101fc0fda4) with no meaning to an end user
  # -- strip that specific shape. Leave meaningful local tags (+cu126, from
  # the PyTorch CUDA wheel index) untouched.
  version=$(echo "$version" | sed -E 's/\+[0-9]+\.g[0-9a-f]+$//')

  # Drop any stale version file for this module before writing the current
  # one, so module avail doesn't accumulate duplicates.
  mkdir -p "$OUT/$modname"
  find "$OUT/$modname" -mindepth 1 -maxdepth 1 ! -name "$version" -exec rm -f {} \;

  out="$OUT/$modname/$version"
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
    puts stderr "AIStack/$modname/$version: \$envpath does not exist"
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
