#!/bin/bash

set -euo pipefail

echo "[task.sh] [1/2] Starting Execution."
export TZ="HST"
source /workspace/envs/prod.env

echo "[task.sh] [2/2] Running workflow."
Rscript /workspace/code/get_hads_obs.R
Rscript /workspace/code/append_hads_master.R

echo "[task.sh] All done!"