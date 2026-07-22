if [ -f "profiles/$USER.sh" ]; then
  source "profiles/$USER.sh"
else
  echo "Profile $USER.sh not found in profiles/."
  return 1
fi

## jobset

export PROJECT="cloud-tpu-multipod-dev"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER="rl-scaffolding"

export JOBSET_TPU_TYPE="tpuv5e"
export JOBSET_TPU_TOPO="4x4"
# export JOBSET_TPU_TYPE="tpuv5"
# export JOBSET_TPU_TOPO="2x2x2"

export JOBSET_NAME="${USER%_google_com}-ws"
export JOBSET_NAMESPACE="default"

## container images

export IMAGE_PATHWAYS_SERVER='us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_server@sha256:1b743bc9c6a5ee6d4f7a2c35ea31375371b9fd6cabc4791c44afeeba2849e237'
export IMAGE_PATHWAYS_PROXY_SERVER='us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_proxy_server@sha256:c243fdd5ee52ef0f1d21165cf737540de54760882f82be358897f0b444c104bd'

# export IMAGE_PATHWAYS_SIDECAR='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/colocated_python_server:jax-0.9.1'

export IMAGE_WORKSPACE="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/tunix_base_image:latest"
# export IMAGE_WORKSPACE="vllm/vllm-tpu:latest"

## remote workspace

export WORKSPACE_CONTAINER="main"
export WORKSPACE_USER="${USER%_google_com}"

export WORKSPACE_JOBSET_TMPL="yamls/jobset-tmpl.$CLUSTER.pathways.yaml"

# disk settings
export WORKSPACE_DISK_NAME="${WORKSPACE_USER}-workspace-disk"
export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_ZONE="us-central1-a"

export WORKSPACE_DISK_CSI_HANDLE="projects/$PROJECT/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME"
export WORKSPACE_DISK_PV_NAME="${WORKSPACE_USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${WORKSPACE_USER}-pvc"

# sync settings
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # your local codebase
export WORKSPACE_LOCAL_VENV="${WORKSPACE_LOCAL_VENV:-}"
export WORKSPACE_REMOTE_ROOT="${WORKSPACE_REMOTE_ROOT:-}" # mirrored remote codebase (disk mount path)
export WORKSPACE_REMOTE_VENV="${WORKSPACE_REMOTE_VENV:-}"
export WORKSPACE_SYNC_EXCLUDE="${WORKSPACE_SYNC_EXCLUDE:-}"

# kubectl
export KUBECONFIG="$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER"

## role-specific override
echo "Select a role for the jobset:"
echo "  [0] rollout-0"
echo "  [1] rollout-1"
echo "  [2] rollout-2"
echo "  [3] rollout-3"
echo "  [4] trainer"
echo "  [5] orchestrator"
while true; do
  echo -n "Select role [0]: "
  read role_idx
  role_idx=${role_idx:-0}
  if (($role_idx >= 0 && $role_idx <= 3)); then
    export JOBSET_NAME="rollout-${role_idx}"
    export JOBSET_CPU_MACHINE=""
    export JOBSET_TPU_TYPE="tpuv5e"
    export JOBSET_TPU_TOPO="4x4"
    export WORKSPACE_JOBSET_TMPL="yamls/jobset-tmpl.$CLUSTER.pathways.yaml"
    break
  elif [[ "$role_idx" == "4" ]]; then
    export JOBSET_NAME="trainer"
    export JOBSET_CPU_MACHINE=""
    export JOBSET_TPU_TYPE="tpuv5"
    export JOBSET_TPU_TOPO="2x2x2"
    export WORKSPACE_JOBSET_TMPL="yamls/jobset-tmpl.$CLUSTER.pathways.yaml"
    break
  elif [[ "$role_idx" == "5" ]]; then
    export JOBSET_NAME="orchestrator"
    export JOBSET_CPU_MACHINE="n2-standard-64"
    export JOBSET_TPU_TYPE=""
    export JOBSET_TPU_TOPO=""
    export WORKSPACE_JOBSET_TMPL="yamls/jobset-tmpl.$CLUSTER.cpu.yaml"
    # export IMAGE_WORKSPACE="python:3.12"
    break
  fi
  echo "Invalid selection. Please try again."
done
