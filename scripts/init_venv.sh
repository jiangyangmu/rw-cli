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
echo "Install pathways-utils (from source)..."
echo "================================================"

cd "$GITHUB_ROOT"
if [[ -d "pathways-utils" ]]; then
  cd pathways-utils

  if [[ -d ".git" ]]; then
    git stash
    git pull origin main
    git checkout main
    git stash list | grep -q "stash@{0}" && git stash pop || true
  else
    echo "pathways-utils .git not found, skip pull."
  fi

  set +e # tolerate error for patch

  # patch: pathwaysutils/experimental/shared_pathways_service/gke_utils.py:check_pod_ready()
  # increate timeout from 30 secs to 120 secs
  sed -i 's/timeout: int = 30/timeout: int = 120/g' \
    pathwaysutils/experimental/shared_pathways_service/gke_utils.py

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

  # patch: pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml
  # needed for colocated python
  # if ! grep -q "sidecar_name=external" pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml; then
  #   sed -i '/--virtual_slices=${EXPECTED_INSTANCES}/a \        - --sidecar_name=external' \
  #     pathwaysutils/experimental/shared_pathways_service/yamls/pw-proxy.yaml
  # fi

  set -e

  # install deps for pathways-utils
  pip install -r requirements.txt
  # install deps for pathways-utils run_connect_example.py
  pip install portpicker
  # install pathways-utils
  pip install -e .
else
  echo "pathways-utils not found, skip."
fi

# echo "================================================"
# echo "Install vllm & tpu-inference (from source)..."
# echo "================================================"

# TODO: move to customize section
cd "$GITHUB_ROOT/vllm"
if [[ "$USER" == "yangmu" ]] && ! [[ -d ".git" ]]; then
  $HOME/.bin/google-cloud-sdk/bin/gsutil cp gs://yangmu/vllm.git.tar .
  tar -xvf vllm.git.tar
fi

# # Install vllm requirements
# cd "$GITHUB_ROOT"
# if [[ -d "vllm" ]]; then
#   cd vllm

#   # if run on local workspace, checkout matched version
#   if [[ -d ".git" ]] && [[ -f "$GITHUB_ROOT/tunix/requirements/requirements.txt" ]]; then
#     VLLM_VERSION=$(cat "$GITHUB_ROOT/tunix/requirements/requirements.txt" | grep vllm.git | sed 's/.*git@//')
#     git stash
#     git pull origin main
#     git checkout $VLLM_VERSION
#     git stash list | grep -q "stash@{0}" && git stash pop || true
#   else
#     echo "vllm .git not found, skip checkout."
#   fi

#   pip install -r requirements/tpu.txt # -f https://storage.googleapis.com/jax-releases/libtpu_releases.html
#   # reference: tunix/scripts/install_tunix_vllm_requirement.sh
#   pip install aiohttp==3.12.15
#   pip install keyring keyrings.google-artifactregistry-auth
# else
#   echo "vllm not found, skip."
# fi

# # Install tpu-inference requirements
# cd "$GITHUB_ROOT"
# if [[ -d "tpu-inference" ]]; then
#   cd tpu-inference
#   # if run on local workspace, checkout matched version
#   if [[ -d ".git" ]] && [[ -f "$GITHUB_ROOT/tunix/requirements/special_requirements.txt" ]]; then
#     TPU_INFERENCE_VERSION=$(cat "$GITHUB_ROOT/tunix/requirements/special_requirements.txt" | grep tpu-inference.git | sed 's/.*git@//')
#     git stash
#     git pull origin main
#     git checkout $TPU_INFERENCE_VERSION
#     git stash list | grep -q "stash@{0}" && git stash pop || true
#   else
#     echo "tpu-inference .git not found, skip checkout."
#   fi
#   pip install -r requirements.txt # -f https://storage.googleapis.com/jax-releases/libtpu_releases.html
# else
#   echo "tpu-inference not found, skip."
# fi

# # reference: tunix/scripts/install_tunix_vllm_requirement.sh
# VLLM_TARGET_DEVICE="tpu" pip install -e "$GITHUB_ROOT/vllm"
# pip install -e "$GITHUB_ROOT/tpu-inference" \
#   --force-reinstall \
#   --extra-index-url https://us-python.pkg.dev/ml-oss-artifacts-published/jax/simple/ \
#   --find-links https://storage.googleapis.com/jax-releases/libtpu_releases.html \
#   --pre

# echo "================================================"
# echo "Install tunix (from source)..."
# echo "================================================"

# cd "$GITHUB_ROOT"
# if [[ -d "tunix" ]]; then
#   cd tunix
#   # pip install jax==0.9.1
#   pip install -e ".[dev]"
# else
#   echo "tunix not found, skip."
# fi

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
echo "Install colab deps..."
echo "================================================"

pip install jupyter_server notebook ipywidgets

pip install kagglehub
pip install huggingface_hub
pip install tensorflow
pip install tensorflow_datasets
pip install tensorboardX
pip install tensorboard
pip install tfds

pip install gcsfs

echo "================================================"
echo "Install debugging tools..."
echo "================================================"

pip install debugpy
pip install viztracer

echo "================================================"
echo "Install tunix+vllm+tpu-inference (from source) ..."
echo "================================================"

export VLLM_TARGET_DEVICE="tpu"
export VLLM_VERSION_OVERRIDE="0.0.0"

cd "$GITHUB_ROOT"
curl -sSL https://install.python-poetry.org | python3 -
export PATH="/home/yangmu/.local/bin:$PATH"

cd "$GITHUB_ROOT/tunix"
poetry source add --priority=supplemental libtpu-source https://storage.googleapis.com/jax-releases/libtpu_releases.html 
poetry lock
poetry install --with dev

echo "================================================"
echo "Download models to $GITHUB_ROOT/.models ..."
echo "================================================"

cd "$GITHUB_ROOT"
if [[ -f ".keys/.hf_token" ]]; then
  hf auth login --token "$(cat .keys/.hf_token)" && \
  for model in \
    "Qwen/Qwen2.5-0.5B" \
    "Qwen/Qwen2.5-1.5B" \
    "meta-llama/Llama-3.2-1B-Instruct"\
  ; do
    echo -n "Downloading $model..."
    hf download "$model" --local-dir "$GITHUB_ROOT/.models/$model" &>/dev/null && echo ok || echo error
  done
else
  echo ".keys not found, skip downloading models."
fi

# see ok-cli/tunix/download_kaggle.py
# kaggle models get google/gemma-2/flax/gemma2-2b-it -p "$GITHUB_ROOT/.models"

echo "================================================"
echo "Run command:"
echo "source $VENV_PATH/bin/activate"
echo "================================================"

echo "Done."
