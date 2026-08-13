import os
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import signal
import time
import torch
import mlflow
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_NAME = "sshleifer/tiny-gpt2"
RUN_SECONDS = 60 * 60
LOG_EVERY_SECONDS = 30

def main():
    # MLflow has no server-side heartbeat -- a run only flips from RUNNING
    # to FINISHED when this `with` block exits normally. A SLURM job
    # getting killed (time limit, scancel, preemption) sends SIGTERM and
    # skips that entirely, leaving the run stuck showing "Running" forever.
    # Catch it and close the run out properly before dying.
    def handle_sigterm(signum, frame):
        if mlflow.active_run() is not None:
            mlflow.end_run(status="KILLED")
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, handle_sigterm)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}", flush=True)
    if device == "cuda":
        print("gpu:", torch.cuda.get_device_name(0), flush=True)

    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(MODEL_NAME).to(device)
    model.train()

    texts = [
        "AIStack is a set of conda environments for AI and ML workloads.",
        "MLflow tracks experiments, parameters, and metrics for training runs.",
        "This is a one hour soak test running on a GPU compute node.",
        "The training loop keeps stepping until the time budget runs out.",
    ]
    batch = tokenizer(texts, return_tensors="pt", padding=True, truncation=True).to(device)

    opt = torch.optim.AdamW(model.parameters(), lr=5e-4)

    mlflow.set_experiment("aistack-smoke-test")
    with mlflow.start_run(run_name=f"tiny-gpt2-1hr-{device}"):
        mlflow.log_param("model", MODEL_NAME)
        mlflow.log_param("device", device)
        mlflow.log_param("lr", 5e-4)
        mlflow.log_param("run_seconds", RUN_SECONDS)
        if device == "cuda":
            props = torch.cuda.get_device_properties(0)
            mlflow.log_param("gpu_name", props.name)
            mlflow.log_param("gpu_total_memory_gb", round(props.total_memory / 1e9, 1))
            mlflow.log_param("gpu_compute_capability", f"{props.major}.{props.minor}")
            mlflow.log_param("cuda_version", torch.version.cuda)

        start = time.time()
        last_log = start
        step = 0
        while time.time() - start < RUN_SECONDS:
            opt.zero_grad()
            out = model(**batch, labels=batch["input_ids"])
            out.loss.backward()
            opt.step()
            step += 1

            now = time.time()
            if now - last_log >= LOG_EVERY_SECONDS:
                elapsed = now - start
                mlflow.log_metric("loss", out.loss.item(), step=step)
                mlflow.log_metric("elapsed_seconds", elapsed, step=step)
                mlflow.log_metric("steps_per_second", step / elapsed, step=step)
                print(f"[{elapsed:7.1f}s] step={step} loss={out.loss.item():.4f}", flush=True)
                last_log = now

        mlflow.log_metric("final_loss", out.loss.item())
        mlflow.log_metric("total_steps", step)
        print(f"done: {step} steps in {time.time() - start:.1f}s", flush=True)
        print("run id:", mlflow.active_run().info.run_id, flush=True)

if __name__ == "__main__":
    main()
