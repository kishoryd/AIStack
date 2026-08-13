# MLflow smoke test

Small end-to-end test: fine-tunes a tiny GPT-2 model on a GPU compute
node and logs params/metrics to the shared MLflow tracking server on the
login node. Verified working via both `srun` and real `sbatch`
submission.

## Usage

```bash
# 1. pre-download the model on the LOGIN node (compute nodes have no
#    internet) -- see the comment at the top of submit_llm_test.sh
module load transformers/5.15.0   # or run via the env's python directly

# 2. submit
sbatch submit_llm_test.sh

# 3. watch it
squeue -u $USER
cat aistack-mlflow-llm-test-*.log
```

Results land in the `aistack-smoke-test` experiment on the MLflow server
(`http://172.40.0.23:5551`, or tunnel it to your own machine:
`ssh -L 5551:localhost:5551 172.40.0.23`).

## Longer-running variant (`train_llm_1hr.py` / `submit_llm_1hr.sh`)

Same idea, but trains in a time-bounded loop (default 1 hour) instead of
a fixed epoch count, logging metrics every 30s. Two issues found and
fixed while testing this one:

- **The log file looked stuck with zero progress even though training
  was running fine.** `print()` to a file (not a live terminal) is
  buffered by Python and only flushes periodically or at clean exit --
  a killed job never gets to flush, so the `.log` file showed nothing
  even though `mlflow.log_metric()` (a separate, immediate HTTP call)
  had been reporting real progress the whole time, visible in the
  MLflow UI. Fixed with `flush=True` on every print.
- **A killed run stayed stuck showing "Running" in MLflow forever.**
  MLflow has no server-side heartbeat -- a run only flips to `FINISHED`
  when the `with mlflow.start_run():` block exits normally, which
  `SIGTERM` skips entirely. Fixed with a signal handler that catches
  `SIGTERM` and calls `mlflow.end_run(status="KILLED")` before exiting,
  so a cancelled/timed-out job closes its run out properly instead of
  leaving a false "Running" entry behind.
