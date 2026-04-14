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
#   port-forward    - Start port forwarding to the head node (port 29000)
#   port-forward-kill - Stop port forwarding
#   dash            - Print the Google Cloud Console dashboard URL
#   quit            - Exit the script
#
set -e

source "/mnt/disks/github/.venv/3.12/k8s/bin/activate"

# ============= Your TODOs begin =============

## jobset

export PROJECT="${PROJECT:-cloud-tpu-multipod-dev}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"
export CLUSTER="${CLUSTER:-bodaborg-super-alpha-cluster}"

export JOBSET_TPU_TYPE="${JOBSET_TPU_TYPE:-tpu7x}"
export JOBSET_TPU_TOPO="${JOBSET_TPU_TOPO:-4x4x4}"

export JOBSET_NAME="${JOBSET_NAME:-${USER}-workspace}"

export GCS_BUCKET="${GCS_BUCKET:-gs://$USER-$REGION}"

## container images

export IMAGE_PATHWAYS_SERVER="${IMAGE_PATHWAYS_SERVER:-us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_server:latest}"
export IMAGE_PATHWAYS_PROXY_SERVER="${IMAGE_PATHWAYS_PROXY_SERVER:-us-central1-docker.pkg.dev/cloud-tpu-multipod-dev/yangmu/tunix/unsanitized_proxy_server:latest}"
export IMAGE_WORKSPACE="${IMAGE_WORKSPACE:-vllm/vllm-tpu:latest}"

## remote workspace

export WORKSPACE_CONTAINER="${WORKSPACE_CONTAINER:-workspace-main}"

# disk settings
# TODO: create your own disk (must be in the same zone as jobset, otherwise, the jobset fails due to disk mount failure)
# $ gcloud compute disks create $USER-workspace-disk --size=512GB --zone=us-central1-ai1a --project=cloud-tpu-multipod-dev
export WORKSPACE_DISK_SIZE="${WORKSPACE_DISK_SIZE:-512Gi}"
export WORKSPACE_DISK_CSI_HANDLE="projects/cloud-tpu-multipod-dev/zones/us-central1-ai1a/disks/$USER-workspace-disk"
export WORKSPACE_DISK_PV_NAME="${USER}-pv"
export WORKSPACE_DISK_PVC_NAME="${USER}-pvc"

# sync settings
export WORKSPACE_REMOTE_ROOT="${WORKSPACE_REMOTE_ROOT:-/mnt/disks/github}" # mirrored remote codebase (disk mount path)
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # TODO: set your local codebase
export WORKSPACE_SYNC_EXCLUDE="lost\+found,.cache,.venv,.git,.jax_cache,.pytest_cache,.bin,.home,.old,.data,.models"

# ============= Your TODOs end =============

# sanity check of environment variables
if [ ${#JOBSET_NAME} -gt 15 ]; then
  echo "Error: JOBSET_NAME '$JOBSET_NAME' is too long (${#JOBSET_NAME} chars). Max 15 chars allowed."
  echo "Please set JOBSET_NAME."
  exit 1
fi

SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# go to script root
cd $SCRIPT_ROOT
source "utils.sh"

# enter kube context
export KUBECONFIG="$HOME/.kube/config.$JOBSET_NAME" # use separate kube config for jobset (not fully tested, only happy paths)
if ! [ -f "$KUBECONFIG" ]; then
    gcloud container clusters get-credentials $CLUSTER --region=$REGION --project=$PROJECT --dns-endpoint && \
    kubectl config set-context --current --namespace=default && \
    kubectl get namespaces
fi
kubectl config use-context "gke_${PROJECT}_${REGION}_${CLUSTER}" >/dev/null && echo "cluster: ${CLUSTER}"

# detect run mode
if [ -z "$1" ]; then
  INTERACTIVE=true
  echo "jobset: ${JOBSET_NAME}"
  echo "tpu:    ${JOBSET_TPU_TYPE}:${JOBSET_TPU_TOPO}"
  echo "local:  ${WORKSPACE_LOCAL_ROOT}"
  echo "remote: ${WORKSPACE_REMOTE_ROOT}"
  echo
else
  INTERACTIVE=false
  ACTIONS=("$@")
fi

set +e

generate_jobset_yaml() {
  # TMPL_FILE="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.yaml"
  # TMPL_FLAGS=""

  TMPL_FILE="yamls/jobset-${JOBSET_TPU_TYPE}-tmpl.remote-workspace.yaml"
  TMPL_FLAGS=""
  TMPL_FLAGS+=" --user_container=${WORKSPACE_CONTAINER}"
  TMPL_FLAGS+=" --user_container_image=${IMAGE_WORKSPACE}"
  TMPL_FLAGS+=" --user_pvc_name=${WORKSPACE_DISK_PVC_NAME}"
  TMPL_FLAGS+=" --user_disk_mount_path=${WORKSPACE_REMOTE_ROOT}"

  python3 yaml_gen_jobset.py "$TMPL_FILE" \
    --jobset_name="$JOBSET_NAME" \
    --server_image="$IMAGE_PATHWAYS_SERVER" \
    --proxy_image="$IMAGE_PATHWAYS_PROXY_SERVER" \
    --tpu_type="$JOBSET_TPU_TYPE:$JOBSET_TPU_TOPO" \
    $TMPL_FLAGS
}

generate_pv_yaml() {
  TMPL_FILE="yamls/user-pv.yaml"
  python3 yaml_gen_pv.py "$TMPL_FILE" \
    --user_pv_name="${WORKSPACE_DISK_PV_NAME}" \
    --user_pv_handle="${WORKSPACE_DISK_CSI_HANDLE}" \
    --user_pv_size="${WORKSPACE_DISK_SIZE}"
}

generate_pvc_yaml() {
  TMPL_FILE="yamls/user-pvc.yaml"
  python3 yaml_gen_pvc.py "$TMPL_FILE" \
    --user_pvc_name="${WORKSPACE_DISK_PVC_NAME}" \
    --user_pvc_size="${WORKSPACE_DISK_SIZE}" \
    --user_pv_name="${WORKSPACE_DISK_PV_NAME}"
}

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
  list-nodes)
    kubectl get nodes -l cloud.google.com/gke-tpu-partition-$JOBSET_TPU_TOPO-id
    ;;
  server-start)
    generate_jobset_yaml | kubectl apply -f - && echo "applied $JOBSET_NAME"

    WORKLOAD=$(kubectl get workloads | grep "$JOBSET_NAME" | awk '{print $1}')
    if [ -z "$WORKLOAD" ]; then
      continue
    fi

    until kubectl describe workload "$WORKLOAD" | egrep -q "SlicesCreated|FailedCreateSlice|EvictedDueToAdmissionCheck"; do
      echo -n "."; sleep 1
    done
    if kubectl describe workload "$WORKLOAD" | egrep -q "FailedCreateSlice|EvictedDueToAdmissionCheck"; then
      kubectl describe workload "$WORKLOAD" | egrep "FailedCreateSlice|EvictedDueToAdmissionCheck"; continue
    fi
    echo "SlicesCreated"

    kubectl patch job $JOBSET_NAME-pathways-head-0 -p '{"spec":{"suspend":false}}' --type=merge
    kubectl patch job $JOBSET_NAME-worker-0 -p '{"spec":{"suspend":false}}' --type=merge

    while true; do
      kubectl describe workload "$WORKLOAD" | grep -q "Admitted" && break
      echo -n "."
      sleep 1
    done
    echo "Admitted"
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

    # TODO: maybe use local files (inline)
    echo "[root] add user $USER to $HEAD_POD (set password)"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/bash "${WORKSPACE_REMOTE_ROOT}/rw-cli/scripts/add_user.sh" "$USER" || continue
    echo "[$USER] init user home on $HEAD_POD (need password)"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "$USER" -c "export DISK_MOUNT_PATH=${WORKSPACE_REMOTE_ROOT}; bash ${WORKSPACE_REMOTE_ROOT}/rw-cli/scripts/init_home.sh" || continue
    echo "[$USER] init venv on $HEAD_POD (need password)"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "$USER" -c "export GITHUB_ROOT=${WORKSPACE_REMOTE_ROOT}; bash ${WORKSPACE_REMOTE_ROOT}/rw-cli/scripts/init_venv.sh"
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
        --container="$WORKSPACE_CONTAINER"
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
    generate_pv_yaml | kubectl delete -f - && echo "unregistered $USER-pv"
    ;;
  proxy-list)
    kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})"
    ;;
  proxy-kill)
    kubectl delete pods $(kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})" | awk '{print $1}')
    ;;
  port-forward)
    if ps aux | grep "kubectl port-forward" | grep -q -v grep; then
      echo "port-forward is already running"
    else
      FORWARD_PORT="${FORWARD_PORT:-29000}"
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
