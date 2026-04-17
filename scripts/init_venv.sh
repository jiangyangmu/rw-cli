#!/bin/bash
#
# WARNING: don't download git repo here, it will be running on remote workspace,
# if sync is on, that may cause your local workspace files be overridden.
#
set -e

GITHUB_ROOT="${GITHUB_ROOT:-}"

if [[ -z "$GITHUB_ROOT" ]]; then
  echo "[${0##*/}] Error: GITHUB_ROOT is not set."
  exit 1
fi

VENV_PATH="${VENV_PATH:-$GITHUB_ROOT/.venv/3.12/k8s}"

echo "GITHUB_ROOT: $GITHUB_ROOT"
echo "VENV_PATH:   $VENV_PATH"

# read -p "Proceed? [y/N]: " confirm && [[ $confirm == [yY] ]] || exit 1

echo "================================================"
echo "Setup venv..."
echo "================================================"

VENV_ROOT=$(dirname "$VENV_PATH")
VENV_NAME=$(basename "$VENV_PATH")

mkdir -p "$VENV_ROOT"
cd "$VENV_ROOT"
if [[ -d "$VENV_NAME" ]]; then
  echo "$VENV_NAME already installed, skip."
else
  python3.12 -m venv "$VENV_NAME"
fi

echo "================================================"
echo "Activate venv..."
echo "================================================"

source "$VENV_PATH/bin/activate"
pip install --upgrade pip

echo "================================================"
echo "Install tunix (from source)..."
echo "================================================"

cd "$GITHUB_ROOT"
if [[ -d "tunix" ]]; then
  cd tunix
  pip install -e ".[dev]"
else
  echo "tunix not found, skip."
fi

echo "================================================"
echo "Install tpu-inference (from source)..."
echo "================================================"

cd "$GITHUB_ROOT"
if [[ -d "tpu-inference" ]]; then
  cd tpu-inference
  # if run on local workspace, checkout matched version
  if [[ -d ".git" ]] && [[ -f "$GITHUB_ROOT/tunix/tunix/oss/requirements.txt" ]]; then
    TPU_INFERENCE_VERSION=$(cat "$GITHUB_ROOT/tunix/tunix/oss/requirements.txt" | sed 's/google/vllm-project/' | grep tpu-inference.git | sed 's/.*git@//')
    git stash
    git checkout $TPU_INFERENCE_VERSION
    git stash pop
  else
    echo "tpu-inference .git not found, skip checkout."
  fi
  pip install -e .
else
  echo "tpu-inference not found, skip."
fi

echo "========================"
echo "Install xpk..."
echo "========================"

# https://github.com/AI-Hypercomputer/xpk/blob/main/docs/installation.md
pip install xpk

# echo "================================================"
# echo "Install pathways CRD..."
# echo "================================================"

# if ! kubectl get crd | grep -q "pathwaysjobs"; then
#   kubectl apply --server-side -f https://github.com/google/pathways-job/releases/download/v0.1.4/install.yaml
# fi

echo "================================================"
echo "Install pathways-utils (from source)..."
echo "================================================"

cd "$GITHUB_ROOT"
if [[ -d "pathways-utils" ]]; then
  cd pathways-utils

  set +e # tolerate error for patch

  # patch: pathwaysutils/experimental/shared_pathways_service/gke_utils.py:check_pod_ready()
  # increate timeout from 30 secs to 120 secs
  sed -i 's/timeout: int = 30/timeout: int = 120/g' \
    pathwaysutils/experimental/shared_pathways_service/gke_utils.py
  grep "timeout: int = 120" pathwaysutils/experimental/shared_pathways_service/gke_utils.py

  # patch: pathwaysutils/experimental/shared_pathways_service/gke_utils.py
  # append "--dns-endpoint" to get_credentials_command, if it's not there
  sed -i 's/f"--project={project_id}",$/f"--project={project_id}", "--dns-endpoint",/' \
    pathwaysutils/experimental/shared_pathways_service/gke_utils.py

  # patch: pathwaysutils/experimental/shared_pathways_service/validators.py
  # make it support tpu7x
  sed -i 's/6e))/6e)|tpu7x)/' pathwaysutils/experimental/shared_pathways_service/validators.py

  # patch: pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml
  # don't terminate pathways-worker when proxy-server is down
  if ! grep -q "temporary_flags_for_debugging" pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml; then
    sed -i '/--virtual_slices=${EXPECTED_INSTANCES}/a \        - --temporary_flags_for_debugging=temporary_flag_for_debugging_test_only_hold_death_ref=false' \
      pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml
  fi

  set -e

  # install deps for pathways-utils
  pip install -r requirements.txt
  pip install jax==0.9.1
  # install deps for pathways-utils run_connect_example.py
  pip install portpicker
  # install pathways-utils
  pip install -e .
else
  echo "pathways-utils not found, skip."
fi

echo "================================================"
echo "Install colab deps..."
echo "================================================"

pip install jupyter_server notebook ipywidgets

pip install kagglehub
pip install huggingface_hub
pip install tensorflow
pip install tensorflow_datasets
pip install tensorboardX
pip install tfds

pip install gcsfs

echo "================================================"
echo "Install debugging tools..."
echo "================================================"

pip install debugpy
pip install viztracer

echo "================================================"
echo "Download models..."
echo "================================================"

hf auth login --token=$(cat .hfkey) &&
hf download Qwen/Qwen3-0.6B --local-dir=/mnt/disks/github/.models/Qwen/Qwen3-0.6B && \
hf download meta-llama/Llama-3.2-1B-Instruct --local-dir=/mnt/disks/github/.models/meta-llama/Llama-3.2-1B-Instruct

echo "================================================"
echo "Install CRD:"
echo "kubectl apply --server-side -f https://github.com/google/pathways-job/releases/download/v0.1.4/install.yaml"
echo
echo "Run command:"
echo "source $VENV_PATH/bin/activate"
echo "================================================"
