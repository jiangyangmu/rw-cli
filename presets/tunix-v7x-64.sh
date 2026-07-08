if [ -f "profiles/$USER.sh" ]; then
  source "profiles/$USER.sh"
else
  echo "Profile $USER.sh not found in profiles/."
  return 1
fi

## jobset

export PROJECT="tpu-prod-env-automated"
export REGION="us-central1"
export ZONE="us-central1-c"
export CLUSTER="tunix-v7x-64"

export JOBSET_TPU_TYPE="tpu7x"
export JOBSET_TPU_TOPO="2x4x4"

export JOBSET_NAME="${USER%_google_com}-ws"
export JOBSET_NAMESPACE="default"

## container images

# -- test image --
export IMAGE_PATHWAYS_SERVER='us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_server@sha256:1b743bc9c6a5ee6d4f7a2c35ea31375371b9fd6cabc4791c44afeeba2849e237'
export IMAGE_PATHWAYS_PROXY_SERVER='us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_proxy_server@sha256:c243fdd5ee52ef0f1d21165cf737540de54760882f82be358897f0b444c104bd'

# export IMAGE_PATHWAYS_SIDECAR='us-docker.pkg.dev/cloud-tpu-v2-images-dev/pathways/colocated_python_server:jax-0.9.1'

export IMAGE_WORKSPACE="us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/tunix_base_image:20260414"

## remote workspace

export WORKSPACE_CONTAINER="workspace-main"
export WORKSPACE_USER="${USER%_google_com}"

export WORKSPACE_JOBSET_TMPL="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.$CLUSTER.yaml"

# disk settings
export WORKSPACE_DISK_NAME="${WORKSPACE_USER}-workspace-disk"
export WORKSPACE_DISK_SIZE="512Gi"
export WORKSPACE_DISK_ZONE=$ZONE

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
