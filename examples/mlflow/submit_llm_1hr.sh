#!/bin/bash
#SBATCH --job-name=aistack-mlflow-1hr
#SBATCH --partition=gpu
#SBATCH --reservation=working_nodes
#SBATCH --gres=gpu:1
#SBATCH --time=01:10:00
#SBATCH --output=%x-%j.log

# ServerAliveInterval keeps the tunnel from being dropped for inactivity
# over the full hour -- the earlier short test jobs never ran long enough
# for this to matter, but a 1hr job does.
ssh -f -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -L 5551:localhost:5551 172.40.0.23
sleep 2

export MLFLOW_TRACKING_URI=http://localhost:5551
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

/home/apps/miniconda/envs/transformers/bin/python \
    "$SLURM_SUBMIT_DIR/train_llm_1hr.py"
