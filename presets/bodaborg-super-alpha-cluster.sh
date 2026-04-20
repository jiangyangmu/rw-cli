## jobset

export PROJECT="cloud-tpu-multipod-dev"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER="bodaborg-super-alpha-cluster"

export JOBSET_TPU_TYPE="tpu7x"
export JOBSET_TPU_TOPO="4x4x4"

export JOBSET_NAME="${USER}-ws"
export JOBSET_NAMESPACE="${JOBSET_NAMESPACE:-poc-ml-perf}"

## container images

export IMAGE_PATHWAYS_SERVER='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/gke/wenxindong/unsanitized_server@sha256:3ffb32b12f6b8cbf4f12cf08ecc9fcfda720b171f4ec9d4131c95f5eeb84d2ae'
export IMAGE_PATHWAYS_PROXY_SERVER='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/gke/wenxindong/unsanitized_proxy_server@sha256:86fedb263c8221bb878c2d301cb45e7c93f54f62872c5c79b055a267da780f42'
# export IMAGE_PATHWAYS_SIDECAR='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/colocated_python_server:jax-0.9.1'
export IMAGE_WORKSPACE="vllm/vllm-tpu:latest"

## remote workspace

export WORKSPACE_CONTAINER="workspace-main"

export WORKSPACE_JOBSET_TMPL="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.$CLUSTER.yaml"

# disk settings
export WORKSPACE_DISK_NAME="$USER-workspace-disk"
export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_ZONE="us-central1-ai1a"

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

export WORKSPACE_DISK_CSI_HANDLE="projects/$PROJECT/zones/$WORKSPACE_DISK_ZONE/disks/$USER-workspace-disk"
export WORKSPACE_DISK_PV_NAME="${USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${USER}-pvc"

# sync settings
export WORKSPACE_REMOTE_ROOT="/mnt/disks/github" # mirrored remote codebase (disk mount path)
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # TODO: set your local codebase
export WORKSPACE_SYNC_EXCLUDE="${WORKSPACE_SYNC_EXCLUDE:-}"

# kubectl
export KUBECONFIG="$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER"
