# AIStack

AI/ML software stack for the cluster: 25 conda environments (finetuning,
inference, RAG, tracking, generation, and pinned legacy frameworks),
exposed to users as Lmod modules and as JupyterHub kernels.

Everything lives in a dedicated Miniconda base at `/home/apps/miniconda`,
deliberately separate from the production MLDL base at
`/home/apps/MLDL/DL-CondaPy3.10` so the two can't disturb each other.
Modulefiles are deployed to `/home/apps/AIStack`, which is already on
`MODULEPATH` cluster-wide.

This repo holds the installer, the modulefile generator, the test suite,
the deployed modulefiles, and a few cluster-specific workarounds.

---

## For users

Load an environment by module name and version — no `conda activate`
needed, the module does it:

```bash
module avail                    # AIStack section lists everything
module load vllm/0.27.1
python -c "import vllm; print(vllm.__version__)"
module list
module unload vllm/0.27.1
```

Each module points `PATH`, `CONDA_PREFIX`, and `VIRTUAL_ENV` at that
env's directory. Load one framework module at a time — they all provide
their own `python`, so stacking two shadows one with the other. The
`apptainer`, `nsight`, and `miniconda` modules are the exception: they
aren't conda envs, so they're safe to load alongside a framework module.

Every env also registers a JupyterHub kernel, so the same environments
are selectable from the notebook kernel picker without loading anything.

`/home/apps/AIStack/test_scripts/` holds a small runnable example per
module (`test_vllm.py`, `test_apptainer.sh`, …) — handy as a first
smoke test after loading one. Note these live only in the deploy path
and are **not** tracked in this repo.

Two cluster facts worth knowing before you submit a job:

- **GPU compute nodes have no DNS or internet.** Download models,
  datasets, and container images on the login node first, then run
  offline on the compute node (`HF_HUB_OFFLINE=1`,
  `TRANSFORMERS_OFFLINE=1`).
- **GPU work belongs in a SLURM allocation.** The login node has no GPU;
  use `srun`/`sbatch` with `--partition=gpu --gres=gpu:N`.

### Environments

Beyond its own framework, every env also carries a common baseline
(numpy, pandas, matplotlib, scikit-learn, scipy, datasets,
huggingface_hub, safetensors, einops, wandb, psutil, pynvml, …), so a
general-purpose script doesn't need a different env just to run.

#### Finetuning — Python 3.11, CUDA 12.8 (cu128 wheels)

| Module | Package |
|---|---|
| `unsloth/2026.8.15` | Unsloth |
| `transformers/5.15.0` | Transformers |
| `accelerate/1.14.0` | Accelerate |
| `trl/1.9.2` | TRL |
| `axolotl/0.18.0` | Axolotl |
| `llamafactory/0.9.5` | LLaMA-Factory |
| `torchtune/0.6.1` | TorchTune |
| `nemo/3.0.0` | NVIDIA NeMo |
| `deepspeed/0.19.5` | DeepSpeed — CUDA 12.9, spack gcc-12.5.0 + cuda-12.9.1 |

DeepSpeed is the odd one: it JIT-compiles fused ops via `nvcc`/`gcc` at
first *use*, not at install time, so its modulefile puts a real spack
CUDA toolchain on `PATH` rather than relying on conda.

#### Inference — Python 3.11, CUDA 13.0 (cu130 wheels)

| Module | Package |
|---|---|
| `vllm/0.27.1` | vLLM |
| `sglang/0.5.17` | SGLang |
| `lmdeploy/0.15.0` | LMDeploy |
| `rayserve/2.57.0` | Ray Serve |
| `tgi/0.7.0` | Text Generation Inference |
| `tensorrt-llm/1.2.1` | TensorRT-LLM — Python 3.10, CUDA bundled via NVIDIA's PyPI index |

#### RAG — Python 3.11, CUDA 13.0 (cu130 wheels)

| Module | Package |
|---|---|
| `llamaindex/0.14.23` | LlamaIndex |
| `langchain/1.3.15` | LangChain |
| `haystack/3.0.0` | Haystack |

#### Tracking / Generation — Python 3.11

| Module | Package |
|---|---|
| `mlflow/3.15.1` | MLflow client — CPU-only; see [MLflow tracking server](#mlflow-tracking-server) |
| `diffusion/0.39.0` | Diffusers — CUDA 12.8 (cu128 wheels) |

#### Legacy

Pinned older frameworks. Their conda env directories carry the version
in the name (`pytorch-2.8`, `theano-1.0`, …) so a future re-pin can't
silently overwrite them; the module name strips it back off, keeping the
version in the version slot where it belongs.

| Module | Conda env | Python | CUDA |
|---|---|---|---|
| `pytorch/2.8.0+cu126` | `pytorch-2.8` | 3.10 | 12.6 (cu126 wheels) |
| `tensorflow/2.20.0` | `tensorflow-2.20` | 3.10 | bundled with the pip package |
| `theano/1.0.5` | `theano-1.0` | 3.8 | 12.9 (spack, `libnvrtc.so` for pygpu JIT) |
| `caffe/1.0` | `caffe-1.0` | 3.7 | via the `caffe-gpu` conda build |
| `rapids/21.6.1` | `rapids-21.06` | 3.7 | 11.2 (`cudatoolkit=11.2`) |

#### Tools (not conda envs)

| Module | What it does |
|---|---|
| `apptainer/1.5.1` | Unprivileged Apptainer on `PATH`; `--nv` for GPU passthrough |
| `nsight/12.9.1` | Nsight Systems (`nsys`) + Nsight Compute (`ncu`) |
| `miniconda/26.7.0` | Bare base conda/python, no framework |

---

## Repository layout

```
install_aistack.sh            create the conda base + all 25 envs
gen_aistack_modulefiles.sh    generate modulefiles from what's installed
test_aistack.sh               verify envs, imports, and GPU access
cleanup_stale_conda_meta.sh   clear stale conda-meta receipts (Lustre quirk)
modulefiles/AIStack/          generated modulefiles, ready to deploy
modulefiles/MLDL/             modulefiles for the production MLDL base
fixes/                        cluster-specific workarounds (see below)
examples/mlflow/              end-to-end MLflow + SLURM example
```

---

## Administration

### Install

Run from the **login node** — compute nodes have no DNS or internet, and
this step downloads packages:

```bash
bash install_aistack.sh
```

Idempotent, and safe to re-run: it installs Miniconda itself if missing,
then creates one env per framework, skipping envs already marked
complete and packages already importable. A re-run only picks up what
failed or wasn't there yet. Per-env logs land in `logs/`, completion
sentinels in `logs/done/`, and a rollup in `logs/install_summary.log`.

Override the target base with `AISTACK_CONDA_DIR` if you need to install
somewhere other than `/home/apps/miniconda`.

### Generate and deploy modulefiles

```bash
bash gen_aistack_modulefiles.sh
```

Versions come from what's actually installed in each env (`pip show`,
falling back to `conda list` for conda-only packages with no pip
dist-info), so the module version can't drift from reality. Envs that
don't exist yet, or are still mid-install, are skipped with a message —
re-run once the installer finishes to pick them up.

Review the diff, then deploy into the live module path:

```bash
cp -r modulefiles/AIStack/* /home/apps/AIStack/
module avail            # confirm
```

`apptainer` and `nsight` are hand-maintained rather than generated —
they're not conda envs, so nothing to read a version off.

### Test

```bash
bash test_aistack.sh           # skip envs that passed last run
bash test_aistack.sh --force   # re-test everything
```

Checks env existence, Python version, package imports, and GPU
availability — `torch.cuda.is_available()` for torch-based envs, and
framework-native probes for TensorFlow, Theano, Caffe, and RAPIDS. Run
it from the login node: if it isn't already inside a SLURM allocation it
re-launches itself on a GPU node via `srun`, so the GPU checks stay
meaningful without you wrapping it yourself.

---

## MLflow tracking server

The `mlflow` module — and the MLflow bundled into most finetuning and
RAG envs — is only the **client library**. With no `MLFLOW_TRACKING_URI`
set, each run logs to a local `./mlruns/` wherever the script happened to
run.

For a shared server everyone can log to and browse, run it as a
`systemd --user` service. No root needed, and unlike a bare background
process it survives logout and reboot:

```bash
mkdir -p ~/.config/systemd/user /home/apps/mlflow/artifacts
cp fixes/mlflow.service ~/.config/systemd/user/mlflow.service

systemctl --user daemon-reload
systemctl --user enable --now mlflow.service
systemctl --user status mlflow.service

# keep it running after full logout, not just while a session is open
loginctl enable-linger cdacapp01
```

`fixes/mlflow.service` calls the binary by absolute path
(`/home/apps/miniconda/envs/mlflow/bin/mlflow`) because systemd services
don't source the module system, and binds `--host 0.0.0.0`.

Users then point at it before logging runs:

```bash
export MLFLOW_TRACKING_URI=http://<login-node>:5551
```

It's reachable directly from the login node, and from anywhere else over
an SSH tunnel (`ssh -L 5551:localhost:5551 <login-node>`). GPU compute
nodes are firewalled off from it, so batch jobs open the tunnel
themselves — see `examples/mlflow/submit_llm_1hr.sh`.

> **No authentication is configured.** Anyone who can reach the port has
> full read/write access to every experiment. The firewall separates
> compute nodes from the server; it does nothing to separate one user's
> experiments from another's.

`examples/mlflow/` has a working end-to-end example — a tiny GPT-2
finetune with tracking, submittable via `sbatch`, in both a short
smoke-test and a time-bounded 1-hour variant.

---

## Cluster-specific workarounds (`fixes/`)

| File | Problem it works around |
|---|---|
| `mlflow.service` | systemd user unit for the tracking server (above) |
| `apptainer-libs/libsubid.so.3` | GPU nodes ship a shadow-utils that claims installed but is missing this `.so` fleet-wide; the apptainer modulefile adds this copy to `LD_LIBRARY_PATH` so apptainer starts regardless |
| `apptainer` | Earlier draft of the apptainer modulefile; the deployed version is `modulefiles/AIStack/apptainer/1.5.1` |

Other workarounds live inline, commented at the point of use:

- **Broken system CMake** (`/usr/bin/cmake` can't find `CMAKE_ROOT`,
  cluster-wide and unrelated to these envs) — the installer uses spack's
  cmake instead of pip-installing one per env.
- **CPU-only torch clobbering CUDA builds** — anything installed after a
  GPU torch build passes the CUDA wheel index as an `--extra-index-url`,
  so pip's resolver can't silently swap in a PyPI CPU wheel.
- **`safetensors` on Python <3.9** (theano, caffe, rapids) — pinned to
  `<0.5`, the last release with cp37/cp38 wheels; newer sdists bootstrap
  Rust via a tool that itself needs Python ≥3.9.
- **Apptainer cache on scratch** — `$HOME` mirrors the scratch layout
  (`/home/<org>/<user>` ↔ `/scratch/<org>/<user>`), so the modulefile
  derives the cache base from `$HOME` rather than assuming a flat
  `/scratch/$USER`.

---

## Cleanup tools

```bash
bash cleanup_stale_conda_meta.sh [conda-base-dir]
```

Removes stale `conda-meta/*.json` receipts that conda's own consistency
check flags but can't delete itself — a Lustre `/home` quirk on this
cluster. Defaults to `/home/apps/miniconda`; pass
`/home/apps/MLDL/DL-CondaPy3.10` to run it against the MLDL base
instead. Needs write access to the target base (`cdacapp01`).
