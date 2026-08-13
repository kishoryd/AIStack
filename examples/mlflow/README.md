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

## Known issue

A longer-running (1hr) variant of this test was tried and got stuck —
the training loop hung with zero progress logged, most likely the SSH
tunnel silently stalling under a long idle period rather than the
training itself failing. Not yet root-caused. Don't rely on this exact
tunnel pattern for long unattended jobs until that's understood; the
short version here (a few minutes) has been reliable across multiple
runs.
