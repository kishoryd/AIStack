# AIStack

AI/ML conda environment stack, installed to a dedicated Miniconda base at
`/home/apps/miniconda` (separate from the production MLDL conda base at
`/home/apps/MLDL/DL-CondaPy3.10`), with matching Lmod modulefiles under
`/home/apps/AIStack`.

## Install

Run from the login node (compute nodes have no DNS/internet, needed for
package downloads):

```bash
bash install_aistack.sh
```

Idempotent — safe to re-run. Skips envs already marked complete and
packages already installed, so a re-run only picks up what failed or
wasn't there yet. Installs Miniconda itself first if not already present,
then creates one conda env per framework across Finetuning, Inference,
RAG, Tracking, Generation, and Legacy categories. Logs to `logs/`,
per-env completion sentinels in `logs/done/`.

## Generate modulefiles

```bash
bash gen_aistack_modulefiles.sh
```

Writes `modulefiles/AIStack/<name>/<version>`, driven by the actual
installed package version in each env (`pip show`, falling back to
`conda list` for conda-only packages with no pip dist-info). Skips any
env that isn't created yet or is still mid-install, with a message —
re-run once `install_aistack.sh` finishes to pick up what it skipped.

Deploy by copying into the live path:

```bash
cp -r modulefiles/AIStack/* /home/apps/AIStack/
```

## Test

```bash
bash test_aistack.sh           # skip envs that already passed
bash test_aistack.sh --force   # re-test everything
```

Checks env existence, Python version, package imports, and GPU
availability (`torch.cuda.is_available()` for torch-based envs;
framework-native probes for TensorFlow/Theano/Caffe/RAPIDS). Run via
`srun` with a GPU allocation for the GPU checks to mean anything.

## Cleanup tools

- `cleanup_stale_conda_meta.sh [conda-base-dir]` — removes stale
  `conda-meta/*.json` receipts that conda's own consistency check flags
  but can't delete itself (a Lustre `/home` quirk on this cluster).
  Defaults to `/home/apps/miniconda`; pass
  `/home/apps/MLDL/DL-CondaPy3.10` to run it against the MLDL base
  instead.
- `remove_aistack_envs_from_mldl_conda.sh [--apply]` — dry-run by
  default; removes any AIStack envs that ended up created inside the
  MLDL conda base by mistake, without touching MLDL's own production
  envs.

Both need write access to the target conda base (`cdacapp01`).
