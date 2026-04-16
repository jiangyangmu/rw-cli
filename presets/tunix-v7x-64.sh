## jobset

export PROJECT="tpu-prod-env-automated"
export REGION="us-central1"
export ZONE="us-central1-c"
export CLUSTER="tunix-v7x-64"

export JOBSET_TPU_TYPE="tpu7x"
export JOBSET_TPU_TOPO="2x4x4"

export JOBSET_NAME="${USER}-ws"

## container images

export IMAGE_PATHWAYS_SERVER="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_server:latest"
export IMAGE_PATHWAYS_PROXY_SERVER="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_proxy_server:latest"
export IMAGE_WORKSPACE="vllm/vllm-tpu:latest"

## remote workspace

export WORKSPACE_CONTAINER="workspace-main"

export WORKSPACE_JOBSET_TMPL="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.$CLUSTER.yaml"

# disk settings
export WORKSPACE_DISK_NAME="$USER-workspace-disk"
export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_ZONE=$ZONE

if gcloud compute disks describe $WORKSPACE_DISK_NAME --zone=$WORKSPACE_DISK_ZONE --project=$PROJECT &>/dev/null; then
  :
else
  echo -n "Disk $WORKSPACE_DISK_NAME not found. Create it? (y/n) "
  read -r REPLY
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    gcloud compute disks create $WORKSPACE_DISK_NAME --size=${WORKSPACE_DISK_SIZE/Gi/GB} --zone=$WORKSPACE_DISK_ZONE --project=$PROJECT \
    && echo "$WORKSPACE_DISK_NAME created: https://pantheon.corp.google.com/compute/disksDetail/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME?project=$PROJECT" \
    || { echo "failed to create $WORKSPACE_DISK_NAME"; export WORKSPACE_DISK_NAME=""; }
  else
    export WORKSPACE_DISK_NAME=""
  fi
fi

export WORKSPACE_DISK_CSI_HANDLE="projects/$PROJECT/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME"
export WORKSPACE_DISK_PV_NAME="${USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${USER}-pvc"

# sync settings
export WORKSPACE_REMOTE_ROOT="/mnt/disks/github" # mirrored remote codebase (disk mount path)
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # TODO: set your local codebase
export WORKSPACE_SYNC_EXCLUDE="lost\+found,__pycache__,.cache,.venv,.git,.jax_cache,.pytest_cache,.bin,.home,.old,.data,.models"

# kubectl
export KUBECONFIG="$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER"
