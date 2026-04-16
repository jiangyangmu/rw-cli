#!/bin/bash
#
# Usage: [env1=val1] ... rw-cli.sh [command1] [command2] ...
#
# If no commands are provided, the script runs in interactive mode.
#
# Environment variables:
#   PROJECT          - GCP project ID (default: cloud-tpu-multipod-dev)
#   REGION           - GCP region (default: us-central1)
#   ZONE             - GCP zone (default: us-central1-a)
#   CLUSTER          - GKE cluster name (default: bodaborg-super-alpha-cluster)
#   JOBSET_TPU_TYPE  - TPU type (default: tpu7x)
#   JOBSET_TPU_TOPO  - TPU topology (default: 4x4x4)
#   JOBSET_NAME      - Name of the JobSet (default: ${USER}-workspace)
#
# Available commands:
#   login           - Get GKE credentials and set context
#   list-jobs       - List jobs for the current JobSet
#   list-jobs-all   - List all jobs in the namespace
#   list-pods       - List pods for the current JobSet
#   list-nodes      - List TPU nodes with specific topology labels
#   server-start    - Generate JobSet YAML, apply it, and start the server
#   server-stop     - Delete the JobSet and wait for termination
#   server-wait     - Wait for pods to be in running state
#   head-restart    - Restart the head node
#   worker-restart  - Restart one of the worker nodes
#   ssh-init        - Initialize the remote workspace (add user, home, venv)
#   ssh-root        - SSH to the head node as root
#   ssh             - SSH to the head node as the current user
#   sync-init       - One-time sync from local to remote workspace
#   sync            - Start continuous sync from local to remote workspace
#   log-head        - Show logs for the head node
#   log-worker      - Show logs for one of the worker nodes
#   desc-pods       - Describe pods for the current JobSet
#   desc-jobset     - Describe the current JobSet
#   desc-workload   - Describe the current workload
#   server-config   - Get JobSet configuration in YAML format
#   disk-register   - Register the persistent disk (PV and PVC)
#   disk-unregister - Unregister the persistent disk (PV and PVC)
#   proxy-list      - List proxy pods
#   proxy-kill      - Delete proxy pods
#   port-forward    - Start port forwarding to the head node (defaut: forward 29000)
#   port-forward-kill - Stop port forwarding
#   dash            - Print the Google Cloud Console dashboard URL
#   quit            - Exit the script
#
set -e

source "/mnt/disks/github/.venv/3.12/k8s/bin/activate"

# ============= Your TODOs begin =============

## jobset

export PROJECT="${PROJECT:-}"
export REGION="${REGION:-}"
export ZONE="${ZONE:-}"
export CLUSTER="${CLUSTER:-}"

export JOBSET_TPU_TYPE="${JOBSET_TPU_TYPE:-}"
export JOBSET_TPU_TOPO="${JOBSET_TPU_TOPO:-}"

export JOBSET_NAME="${JOBSET_NAME:-}"

export GCS_BUCKET="${GCS_BUCKET:-}"

## container images

export IMAGE_PATHWAYS_SERVER="${IMAGE_PATHWAYS_SERVER:-}"
export IMAGE_PATHWAYS_PROXY_SERVER="${IMAGE_PATHWAYS_PROXY_SERVER:-}"
export IMAGE_WORKSPACE="${IMAGE_WORKSPACE:-}"

## remote workspace

export WORKSPACE_CONTAINER="${WORKSPACE_CONTAINER:-}"

export WORKSPACE_JOBSET_TMPL="${WORKSPACE_JOBSET_TMPL:-}"

# disk settings
export WORKSPACE_DISK_SIZE="${WORKSPACE_DISK_SIZE:-}"
export WORKSPACE_DISK_CSI_HANDLE="${WORKSPACE_DISK_CSI_HANDLE:-}"
export WORKSPACE_DISK_PV_NAME="${WORKSPACE_DISK_PV_NAME-}"
export WORKSPACE_DISK_PVC_NAME="${WORKSPACE_DISK_PVC_NAME-}"

# sync settings
export WORKSPACE_REMOTE_ROOT="${WORKSPACE_REMOTE_ROOT:-}" # mirrored remote codebase (disk mount path)
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # TODO: set your local codebase
export WORKSPACE_SYNC_EXCLUDE="${WORKSPACE_SYNC_EXCLUDE:-lost\+found,__pycache__,.cache,.venv,.git,.jax_cache,.pytest_cache,.bin,.home}"

# ============= Your TODOs end =============

# sanity check of environment variables
if [ -z "$JOBSET_NAME" ]; then
  echo "Error: JOBSET_NAME is not set."
  echo "Please run 'source presets/<your-cluster>.sh' to initialize the environment."
  exit 1
fi
if [ ${#JOBSET_NAME} -gt 15 ]; then
  echo "Error: JOBSET_NAME '$JOBSET_NAME' is too long (${#JOBSET_NAME} chars). Max 15 chars allowed."
  exit 1
fi
if [[ ! "$WORKSPACE_DISK_CSI_HANDLE" == *"$PROJECT"* ]]; then
  echo "Error: WORKSPACE_DISK_CSI_HANDLE does not contain PROJECT '$PROJECT'."
  echo "WORKSPACE_DISK_CSI_HANDLE=$WORKSPACE_DISK_CSI_HANDLE"
  exit 1
fi
REQUIRED_VARS=(
  PROJECT REGION ZONE CLUSTER 
  JOBSET_TPU_TYPE JOBSET_TPU_TOPO JOBSET_NAME GCS_BUCKET
  IMAGE_PATHWAYS_SERVER IMAGE_PATHWAYS_PROXY_SERVER IMAGE_WORKSPACE 
  WORKSPACE_CONTAINER WORKSPACE_JOBSET_TMPL
  WORKSPACE_DISK_SIZE WORKSPACE_DISK_CSI_HANDLE 
  WORKSPACE_DISK_PV_NAME WORKSPACE_DISK_PVC_NAME
  WORKSPACE_REMOTE_ROOT WORKSPACE_LOCAL_ROOT
)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Environment variable $var is not set."
    exit 1
  fi
done

# gcloud auth check
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
  echo "No active gcloud account found. Please run 'gcloud auth login'."
  exit 1
fi

SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# go to script root
cd $SCRIPT_ROOT
source "src/utils.sh"

# enter kube context
export KUBECONFIG="$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER"
if ! [ -f "$KUBECONFIG" ]; then
    gcloud container clusters get-credentials $CLUSTER --region=$REGION --project=$PROJECT --dns-endpoint && \
    kubectl config set-context --current --namespace=default && \
    kubectl get namespaces
fi
kubectl config use-context "gke_${PROJECT}_${REGION}_${CLUSTER}" 2>/dev/null || { echo "kubectl use-context failed"; exit 1; }

generate_jobset_yaml() {
  # TMPL_FILE="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.yaml"
  # TMPL_FLAGS=""

  TMPL_FILE="${WORKSPACE_JOBSET_TMPL}"
  TMPL_FLAGS=""
  TMPL_FLAGS+=" --user_container=${WORKSPACE_CONTAINER}"
  TMPL_FLAGS+=" --user_container_image=${IMAGE_WORKSPACE}"
  TMPL_FLAGS+=" --user_pvc_name=${WORKSPACE_DISK_PVC_NAME}"
  TMPL_FLAGS+=" --user_disk_mount_path=${WORKSPACE_REMOTE_ROOT}"

  python3 src/yaml_gen_jobset.py "$TMPL_FILE" \
    --jobset_name="$JOBSET_NAME" \
    --server_image="$IMAGE_PATHWAYS_SERVER" \
    --proxy_image="$IMAGE_PATHWAYS_PROXY_SERVER" \
    --tpu_type="$JOBSET_TPU_TYPE:$JOBSET_TPU_TOPO" \
    $TMPL_FLAGS
}

generate_pv_yaml() {
  TMPL_FILE="yamls/user-pv.yaml"
  python3 src/yaml_gen_pv.py "$TMPL_FILE" \
    --user_pv_name="${WORKSPACE_DISK_PV_NAME}" \
    --user_pv_handle="${WORKSPACE_DISK_CSI_HANDLE}" \
    --user_pv_size="${WORKSPACE_DISK_SIZE}"
}

generate_pvc_yaml() {
  TMPL_FILE="yamls/user-pvc.yaml"
  python3 src/yaml_gen_pvc.py "$TMPL_FILE" \
    --user_pvc_name="${WORKSPACE_DISK_PVC_NAME}" \
    --user_pvc_size="${WORKSPACE_DISK_SIZE}" \
    --user_pv_name="${WORKSPACE_DISK_PV_NAME}"
}

# auto register disk
if ! kubectl get pv | grep -q "$WORKSPACE_DISK_PV_NAME"; then
  generate_pv_yaml | kubectl apply -f - || { echo "failed to register $WORKSPACE_DISK_PV_NAME"; exit 1; }
fi
if ! kubectl get pvc | grep -q "$WORKSPACE_DISK_PVC_NAME"; then
  generate_pvc_yaml | kubectl apply -f - || { echo "failed to register $WORKSPACE_DISK_PVC_NAME"; exit 1; }
fi

# detect run mode
if [ -z "$1" ]; then
  INTERACTIVE=true
  echo "cluster: ${CLUSTER}"
  echo "jobset: ${JOBSET_NAME}"
  echo "tpu:    ${JOBSET_TPU_TYPE}:${JOBSET_TPU_TOPO}"
  echo "tmpl:   ${WORKSPACE_JOBSET_TMPL}"
  echo "local:  ${WORKSPACE_LOCAL_ROOT}"
  echo "remote: ${WORKSPACE_REMOTE_ROOT}"
  echo
else
  INTERACTIVE=false
  ACTIONS=("$@")
fi

set +e

while true; do
  trap 'echo' INT
  if [ "$INTERACTIVE" = true ]; then
    read -e -p "> " action
  else
    [ ${#ACTIONS[@]} -eq 0 ] && break
    action="${ACTIONS[0]}"; ACTIONS=("${ACTIONS[@]:1}")
  fi

  case $action in
  login)
    gcloud container clusters get-credentials $CLUSTER --region=$REGION --project=$PROJECT --dns-endpoint && \
    kubectl config set-context --current --namespace=default && \
    kubectl get namespaces
    ;;
  list-jobs)
    kubectl get jobs --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME"
    ;;
  list-jobs-all)
    kubectl get jobs -o wide
    ;;
  list-pods)
    kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME"
    ;;
  list-queues)
    kubectl get queues
    ;;
  list-nodes)
    kubectl get nodes -l cloud.google.com/gke-tpu-partition-$JOBSET_TPU_TOPO-id
    ;;
  server-yaml)
    read -e -p "Output file [${JOBSET_NAME}.yaml]: " yaml_file
    yaml_file="${yaml_file:-${JOBSET_NAME}.yaml}"
    if [ -f "$yaml_file" ]; then
      echo -n "File $yaml_file already exists. Overwrite? (y/n) "
      read -r REPLY
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        continue
      fi
    fi
    if generate_jobset_yaml > "$yaml_file"; then
      echo "JobSet YAML written to $yaml_file"
    else
      echo "Error: Failed to generate JobSet YAML"
    fi
    ;;
  server-start)
    generate_jobset_yaml | kubectl apply -f - && echo "applied $JOBSET_NAME"
    sleep 1

    WORKLOAD=$(kubectl get workloads | grep "$JOBSET_NAME" | awk '{print $1}')
    if [ -z "$WORKLOAD" ]; then
      continue
    fi

    ok_regex="Admitted by"
    error_regex="FailedCreateSlice|EvictedDueToAdmissionCheck|couldn't assign flavors|LocalQueue lq doesn't exist"
    until kubectl describe workload "$WORKLOAD" | egrep -q "$ok_regex|$error_regex"; do
      echo -n "."; sleep 1
    done
    if kubectl describe workload "$WORKLOAD" | egrep -q "$error_regex"; then
      kubectl describe workload "$WORKLOAD" | egrep "$error_regex"; continue
    fi
    kubectl describe workload "$WORKLOAD" | egrep "$ok_regex"

    # kubectl patch job $JOBSET_NAME-pathways-head-0 -p '{"spec":{"suspend":false}}' --type=merge
    # kubectl patch job $JOBSET_NAME-worker-0 -p '{"spec":{"suspend":false}}' --type=merge
    ;;
  server-stop)
    generate_jobset_yaml | kubectl delete -f - && echo "deleted $JOBSET_NAME" || continue

    while true; do
      kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" 2>&1 | grep -q "No resources found" && break
      echo -n "."
      sleep 1
    done
    echo "Terminated"
    ;;
  server-wait)
    verify_pods_running ${JOBSET_NAME} && echo "pods are running" || echo "pods are not running"
    ;;
  head-restart)
    kubectl exec -it "$HEAD_POD" -c pathways-rm -- /bin/sh -c "kill 1"
    ;;
  worker-restart)
    # one worker down will trigger all workers to restart
    WORKER_POD=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}')
    kubectl exec -it "$WORKER_POD" -c pathways-worker -- /bin/sh -c "kill 1"
    ;;
  ssh-init)
    echo -n "wait for head node ready"
    for i in {0..120}; do
      verify_head_running ${JOBSET_NAME} && { echo; break; }
      echo -n "."
      sleep 1
    done
    verify_head_running ${JOBSET_NAME} || { echo "error: head node not ready"; continue; }

    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
    if kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/sh -c "! [ -d '${WORKSPACE_REMOTE_ROOT}/rw-cli/' ]" 2>/dev/null; then
      echo "error: rw-cli not found on remote workspace disk, please run 'sync-init' to init disk."
      continue
    fi

    echo "[root] add user $USER to $HEAD_POD"
    kubectl exec -i "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/bash -s "$USER" < "${SCRIPT_ROOT}/scripts/add_user.sh" || continue
    echo "[$USER] init user home on $HEAD_POD"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "$USER" -c "export DISK_MOUNT_PATH=${WORKSPACE_REMOTE_ROOT}; bash -s" < "${SCRIPT_ROOT}/scripts/init_home.sh" || continue
    echo "[$USER] init venv on $HEAD_POD"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "$USER" -c "export GITHUB_ROOT=${WORKSPACE_REMOTE_ROOT}; bash -s" < "${SCRIPT_ROOT}/scripts/init_venv.sh"
    ;;
  ssh-root)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
    echo "ssh to $HEAD_POD"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/bash
    ;;
  ssh)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
    echo "ssh to $HEAD_POD"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /usr/bin/zsh -l "$USER"
    ;;
  sync-init)
    if [[ -z "$WORKSPACE_LOCAL_ROOT" ]]; then
      echo "Error: WORKSPACE_LOCAL_ROOT is not set."
      echo "Please set WORKSPACE_LOCAL_ROOT."
      exit 1
    fi
    if ps aux | grep "devspace sync" | grep -q -v grep; then
      echo "devspace sync is already running"
    else
      # for usage: https://www.devspace.sh/docs/cli/devspace_sync
      # for different sync strategy: https://www.devspace.sh/docs/configuration/dev/connections/file-sync
      devspace sync \
        --path="${WORKSPACE_LOCAL_ROOT}:${WORKSPACE_REMOTE_ROOT}" \
        --exclude="${WORKSPACE_SYNC_EXCLUDE}" \
        --namespace=default \
        --label-selector=batch.kubernetes.io/job-name=${JOBSET_NAME}-pathways-head-0 \
        --container="$WORKSPACE_CONTAINER" \
        --upload-only \
        --no-watch
    fi
    ;;
  sync)
    if [[ -z "$WORKSPACE_LOCAL_ROOT" ]]; then
      echo "Error: WORKSPACE_LOCAL_ROOT is not set."
      echo "Please set WORKSPACE_LOCAL_ROOT."
      exit 1
    fi
    if ps aux | grep "devspace sync" | grep -q -v grep; then
      echo "devspace sync is already running"
    else
      # for usage: https://www.devspace.sh/docs/cli/devspace_sync
      # for different sync strategy: https://www.devspace.sh/docs/configuration/dev/connections/file-sync
      devspace sync \
        --path="${WORKSPACE_LOCAL_ROOT}:${WORKSPACE_REMOTE_ROOT}" \
        --exclude="${WORKSPACE_SYNC_EXCLUDE}" \
        --namespace=default \
        --label-selector=batch.kubernetes.io/job-name=${JOBSET_NAME}-pathways-head-0 \
        --container="$WORKSPACE_CONTAINER" \
        --upload-only
    fi
    ;;
  log-head)
    kubectl logs -l jobset.sigs.k8s.io/jobset-name=$JOBSET_NAME,jobset.sigs.k8s.io/replicatedjob-name=pathways-head -c pathways-rm --tail=20
    ;;
  log-worker)
    WORKER_POD=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}')
    kubectl logs $WORKER_POD
    ;;
  desc-pods)
    kubectl describe pods -l jobset.sigs.k8s.io/jobset-name=$JOBSET_NAME
    ;;
  desc-head)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
    kubectl describe pods $HEAD_POD
    ;;
  desc-worker)
    WORKER_POD=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}')
    kubectl describe pods $WORKER_POD
    ;;
  desc-node)
    NODE_NAME=$(kubectl get nodes | grep gke-tpu- | head -n 1 | awk '{print $1}')
    kubectl describe node $NODE_NAME
    ;;
  desc-jobset)
    kubectl describe jobset "$JOBSET_NAME"
    ;;
  desc-workload)
    WORKLOAD=$(kubectl get workloads | grep "$JOBSET_NAME" | awk '{print $1}')
    kubectl describe workload "$WORKLOAD"
    ;;
  server-config)
    kubectl get jobset "$JOBSET_NAME" -o yaml
    ;;
  disk-register)
    if kubectl get pv | grep -q "$USER-pv"; then echo "$USER-pv already registered"; else
      generate_pv_yaml | kubectl apply -f - && echo "registered $USER-pv" || continue
    fi
    if kubectl get pvc | grep -q "$USER-pvc"; then echo "$USER-pvc already registered"; else
      generate_pvc_yaml | kubectl apply -f - && echo "registered $USER-pvc"
    fi
    ;;
  disk-unregister)
    generate_pvc_yaml | kubectl delete -f - && echo "unregistered $USER-pvc"
    # if fails, goto https://pantheon.corp.google.com/kubernetes/persistentvolume/$REGION/$CLUSTER/$USER-pv/details?project=$PROJECT
    # manually remove finalizer content. (be cautious, make sure you know what you are doing)
    generate_pv_yaml | kubectl delete -f - && echo "unregistered $USER-pv"
    ;;
  proxy-list)
    kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})"
    ;;
  proxy-kill)
    kubectl delete pods $(kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})" | awk '{print $1}')
    ;;
  port-forward)
    FORWARD_PORT="${FORWARD_PORT:-29000}"
    if ps aux | egrep "kubectl port-forward.*$FORWARD_PORT:$FORWARD_PORT" | grep -q -v grep; then
      echo "port-forward on port ${FORWARD_PORT} is already running"
    else
      HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
      # localhost:FORWARD_PORT <=> HEAD_POD:FORWARD_PORT
      kubectl port-forward ${HEAD_POD} ${FORWARD_PORT}:${FORWARD_PORT} >/dev/null 2>/dev/null &
      echo "port-forward started on port ${FORWARD_PORT}"
    fi
    ;;
  port-forward-kill)
    if ps aux | grep "kubectl port-forward" | grep -q -v grep; then
      pkill -f "kubectl port-forward"
      echo "port-forward stopped"
    fi
    ;;
  dash)
    echo "https://pantheon.corp.google.com/kubernetes/service/$REGION/$CLUSTER/default/$JOBSET_NAME/overview?project=$PROJECT"
    ;;
  dash-all)
    echo "jobs: https://pantheon.corp.google.com/kubernetes/service/$REGION/$CLUSTER/default/$JOBSET_NAME/overview?project=$PROJECT"
    echo "disk: https://pantheon.corp.google.com/compute/disksDetail/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME?project=$PROJECT"
    ;;
  quit)
    exit 0
    ;;
  *)
    echo "unknown command: $action"
    [ "$INTERACTIVE" = false ] && exit 1
    ;;
  esac
  trap - INT
done
