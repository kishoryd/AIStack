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
framework-native probes for TensorFlow/Theano/Caffe/RAPIDS). Run it from
the login node — if it's not already inside a SLURM allocation, it
re-launches itself on a GPU node via `srun` automatically, so the GPU
checks are meaningful without you having to wrap it yourself.

## MLflow tracking server

`mlflow` (both the standalone env and bundled into most of the
finetuning/RAG envs) is just the client library by default — no shared
tracking server, no fixed `MLFLOW_TRACKING_URI`. Without one configured,
each run just logs to a local `./mlruns/` directory wherever the script
happens to run.

For a real shared server everyone can log to and browse, run it as a
`systemd --user` service (no root needed, and it survives logout/reboot,
unlike a bare background process):

```bash
mkdir -p ~/.config/systemd/user
mkdir -p /home/apps/mlflow/artifacts

cp fixes/mlflow.service ~/.config/systemd/user/mlflow.service

systemctl --user daemon-reload
systemctl --user enable --now mlflow.service
systemctl --user status mlflow.service

# survive full logout, not just while a session is still open:
loginctl enable-linger cdacapp01
```

Then every user points at it before logging runs:

```bash
export MLFLOW_TRACKING_URI=http://<login-node-hostname>:5551
```

`fixes/mlflow.service` calls the mlflow binary by absolute path
(`/home/apps/miniconda/envs/mlflow/bin/mlflow`) since systemd services
don't source the module system. `--host 0.0.0.0` opens it to the whole
network, not just localhost.

**No authentication is configured** — anyone who can reach the port has
full read/write access to every experiment. It's reachable from the
login node directly, and from anywhere else via an SSH tunnel
(`ssh -L 5551:localhost:5551 <login-node>`) — the firewall blocks direct
access from GPU compute nodes specifically (see `examples/mlflow/`),
but does nothing to separate one cluster user's experiments from
another's.

See `examples/mlflow/` for a working end-to-end smoke test (tiny model
fine-tune + tracking, submittable via `sbatch`).

## Cleanup tools

- `cleanup_stale_conda_meta.sh [conda-base-dir]` — removes stale
  `conda-meta/*.json` receipts that conda's own consistency check flags
  but can't delete itself (a Lustre `/home` quirk on this cluster).
  Defaults to `/home/apps/miniconda`; pass
  `/home/apps/MLDL/DL-CondaPy3.10` to run it against the MLDL base
  instead.

Needs write access to the target conda base (`cdacapp01`).
