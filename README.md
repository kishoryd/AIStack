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

### Enabling authentication

By default there's no auth at all — anyone who can reach the port has
full read/write access to every experiment. MLflow ships a real
basic-auth mode; `fixes/mlflow-auth.service` is a separate, opt-in unit
for it (deliberately not baked into the plain `mlflow.service` above,
since turning auth on breaks any client that isn't sending credentials —
this should be a conscious cutover, not a silent behavior change).

```bash
# 1. generate a real secret key and set the admin password (do NOT
#    commit either of these anywhere)
python3 -c "import secrets; print(secrets.token_hex(32))"

cp fixes/basic_auth.ini.template /home/apps/mlflow/basic_auth.ini
# edit /home/apps/mlflow/basic_auth.ini: replace admin_password

cat > /home/apps/mlflow/mlflow-auth.env <<EOF
MLFLOW_AUTH_CONFIG_PATH=/home/apps/mlflow/basic_auth.ini
MLFLOW_FLASK_SERVER_SECRET_KEY=<paste the generated secret key here>
EOF
chmod 600 /home/apps/mlflow/mlflow-auth.env   # contains the secret key

# 2. cut over: stop the old no-auth service, start the auth one
systemctl --user stop mlflow.service
systemctl --user disable mlflow.service

cp fixes/mlflow-auth.service ~/.config/systemd/user/mlflow-auth.service
systemctl --user daemon-reload
systemctl --user enable --now mlflow-auth.service
systemctl --user status mlflow-auth.service
```

Once enabled, every client needs credentials — `default_permission =
READ` in the template means a logged-in non-admin user can read
everything but not write, until given explicit per-experiment
permissions:

```bash
export MLFLOW_TRACKING_URI=http://<login-node-hostname>:5551
export MLFLOW_TRACKING_USERNAME=admin
export MLFLOW_TRACKING_PASSWORD=<the admin password you set>
```

To create real per-user accounts instead of sharing the admin login
(`admin` can do this via the REST API — there's no `mlflow` CLI command
for it yet):

```bash
curl -u admin:<admin-password> -X POST \
  http://<login-node-hostname>:5551/api/2.0/mlflow/users/create \
  -H "Content-Type: application/json" \
  -d '{"username": "someuser", "password": "their-password"}'
```

Verified end-to-end before writing any of this down: unauthenticated
and wrong-password requests both get `401`, correct credentials get
`200`.

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
