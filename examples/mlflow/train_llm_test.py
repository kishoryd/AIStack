import os
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import torch
import mlflow
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_NAME = "sshleifer/tiny-gpt2"

def main():
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")
    if device == "cuda":
        print("gpu:", torch.cuda.get_device_name(0))

    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(MODEL_NAME).to(device)
    model.train()

    texts = [
        "AIStack is a set of conda environments for AI and ML workloads.",
        "MLflow tracks experiments, parameters, and metrics for training runs.",
        "This is a small smoke test running on a GPU compute node.",
    ]
    batch = tokenizer(texts, return_tensors="pt", padding=True, truncation=True).to(device)

    opt = torch.optim.AdamW(model.parameters(), lr=5e-4)
    epochs = 20

    mlflow.set_experiment("aistack-smoke-test")
    with mlflow.start_run(run_name=f"tiny-gpt2-{device}"):
        mlflow.log_param("model", MODEL_NAME)
        mlflow.log_param("device", device)
        mlflow.log_param("lr", 5e-4)
        mlflow.log_param("epochs", epochs)
        if device == "cuda":
            props = torch.cuda.get_device_properties(0)
            mlflow.log_param("gpu_name", props.name)
            mlflow.log_param("gpu_total_memory_gb", round(props.total_memory / 1e9, 1))
            mlflow.log_param("gpu_compute_capability", f"{props.major}.{props.minor}")
            mlflow.log_param("cuda_version", torch.version.cuda)

        for epoch in range(epochs):
            opt.zero_grad()
            out = model(**batch, labels=batch["input_ids"])
            out.loss.backward()
            opt.step()
            mlflow.log_metric("loss", out.loss.item(), step=epoch)
            if epoch % 5 == 0:
                print(f"epoch {epoch}: loss={out.loss.item():.4f}")

        mlflow.log_metric("final_loss", out.loss.item())
        print("run id:", mlflow.active_run().info.run_id)

if __name__ == "__main__":
    main()
