## jobset

export PROJECT="cloud-tpu-multipod-dev"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER="bodaborg-super-alpha-cluster"

export JOBSET_TPU_TYPE="tpu7x"
export JOBSET_TPU_TOPO="4x4x4"

export JOBSET_NAME="${USER}-workspace"

export GCS_BUCKET="gs://$USER-$REGION"

## container images

export IMAGE_PATHWAYS_SERVER="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_server:latest"
export IMAGE_PATHWAYS_PROXY_SERVER="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_proxy_server:latest"
export IMAGE_WORKSPACE="vllm/vllm-tpu:latest"

## remote workspace

export WORKSPACE_CONTAINER="workspace-main"

# disk settings
# $ gcloud compute disks describe $USER-workspace-disk --zone=$ZONE --project=$PROJECT
# $ gcloud compute disks create $USER-workspace-disk --size=512GB --zone=$ZONE --project=$PROJECT
if gcloud compute disks create $USER-workspace-disk --size=512GB --zone=$ZONE --project=$PROJECT 2>/dev/null; then
  echo "$USER-workspace-disk created"
else
  echo "$USER-workspace-disk already exists, skipping creation"
fi

export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_CSI_HANDLE="projects/$PROJECT/zones/us-central1-ai1a/disks/$USER-workspace-disk"
export WORKSPACE_DISK_PV_NAME="${USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${USER}-pvc"

# sync settings
export WORKSPACE_REMOTE_ROOT="/mnt/disks/github" # mirrored remote codebase (disk mount path)
export WORKSPACE_LOCAL_ROOT="/mnt/disks/github" # set your local codebase
export WORKSPACE_SYNC_EXCLUDE="lost\+found,.cache,.venv,.git,.jax_cache,.pytest_cache,.bin,.home,.old,.data,.models"
