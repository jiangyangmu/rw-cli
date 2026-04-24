if [ -f "profiles/$USER.sh" ]; then
  source "profiles/$USER.sh"
else
  echo "Profile $USER.sh not found in profiles/."
  return 1
fi

## jobset

export PROJECT='cloud-tpu-multipod-dev'
export REGION='europe-west4'
export ZONE='europe-west4-b'
export CLUSTER="tunix-v5p-16"

export JOBSET_TPU_TYPE="tpuv5"
export JOBSET_TPU_TOPO="2x2x2"

export JOBSET_NAME="${USER%_google_com}-ds"
export JOBSET_NAMESPACE="default"

## container images

export IMAGE_PATHWAYS_SERVER='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/gke/ksadi/unsanitized_server@sha256:bea35fb014edf250718ce32820777ceb943dfdcf08a593b3fb762ad9ea433fdc'
export IMAGE_PATHWAYS_PROXY_SERVER='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/gke/ksadi/unsanitized_proxy_server@sha256:e5ad4ef0ec907ba2378394f59c4ba074a82231112c03d7f80d7c4a38b19c043c'

# export IMAGE_PATHWAYS_SIDECAR='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/colocated_python_server:jax-0.9.1'

# export IMAGE_WORKSPACE="vllm/vllm-tpu:latest"
export IMAGE_WORKSPACE="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/tunix_base_image:20260414"

## remote workspace

export WORKSPACE_CONTAINER="workspace-main"
export WORKSPACE_USER="${USER%_google_com}"

export WORKSPACE_JOBSET_TMPL="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.$CLUSTER.yaml"

# disk settings
export WORKSPACE_DISK_NAME="${WORKSPACE_USER}-workspace-disk"
export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_ZONE=$ZONE

# gcloud auth check
if ! gcloud auth print-access-token &>/dev/null; then
  echo "No active gcloud account found. Please run 'gcloud auth login'."
  return 1
fi
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
export WORKSPACE_DISK_PV_NAME="${WORKSPACE_USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${WORKSPACE_USER}-pvc"

# sync settings (set by profiles/$UER.sh)
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # your local codebase
export WORKSPACE_LOCAL_VENV="${WORKSPACE_LOCAL_VENV:-}"
export WORKSPACE_REMOTE_ROOT="${WORKSPACE_REMOTE_ROOT:-}" # mirrored remote codebase (disk mount path)
export WORKSPACE_REMOTE_VENV="${WORKSPACE_REMOTE_VENV:-}"
export WORKSPACE_SYNC_EXCLUDE="${WORKSPACE_SYNC_EXCLUDE:-}"

# kubectl
export KUBECONFIG="$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER"
