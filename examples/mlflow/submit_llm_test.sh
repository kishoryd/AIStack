#!/bin/bash
#SBATCH --job-name=aistack-mlflow-llm-test
#SBATCH --partition=gpu
#SBATCH --reservation=working_nodes
#SBATCH --gres=gpu:1
#SBATCH --time=00:10:00
#SBATCH --output=%x-%j.log

# Pre-download step (run once, from the login node, before submitting --
# compute nodes have no internet):
#
#   /home/apps/miniconda/envs/transformers/bin/python -c "
#   from transformers import AutoModelForCausalLM, AutoTokenizer
#   AutoTokenizer.from_pretrained('sshleifer/tiny-gpt2')
#   AutoModelForCausalLM.from_pretrained('sshleifer/tiny-gpt2')
#   "

# Tunnel to the MLflow server on the login node -- compute nodes can't
# reach it directly (firewalled), only SSH (port 22) is open between
# compute and login nodes. Uses the login node's internal IP since
# hostname resolution doesn't work from compute nodes either.
ssh -f -N -o StrictHostKeyChecking=no -L 5551:localhost:5551 172.40.0.23
sleep 2

export MLFLOW_TRACKING_URI=http://localhost:5551
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

# $SLURM_SUBMIT_DIR, not a path relative to this script -- SLURM copies
# the submitted script to a job-specific staging directory before
# running it, so the script's own location isn't where train_llm_test.py
# actually lives.
/home/apps/miniconda/envs/transformers/bin/python \
    "$SLURM_SUBMIT_DIR/train_llm_test.py"
