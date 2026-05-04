#!/bin/bash
#
# Usage:
#   ./rw-cli.sh [command1] [command2] ...
#
#   If JOBSET_NAME is not set, it will prompt to select a preset.
#   Selections are remembered per terminal session.
#   To override, manually source a preset: source presets/<cluster>.sh
#
# Interactive Mode:
#   If no commands are provided, the script runs in interactive mode.
#
# Available commands:
#
#   [Setup & Auth]
#     bootstrap       - One-step setup: server-start, disk-init, and ssh-init
#     disk-init       - Run once after disk creation, initial sync from local workspace root to remote workspace root
#     ssh-init        - Run once after server start or restart, initialize the remote workspace (add user, home, venv)
#                       Skip this if using `root` account is fine for you (in this case, use `ssh-root`).
#
#   [Lifecycle]
#     server-start    - Generate JobSet YAML, apply it, and start the server
#     server-stop     - Delete the JobSet and wait for termination
#     server-resume   - Resume a suspended server
#     server-wait     - Wait for pods to be in running state
#     server-yaml     - Generate and save JobSet YAML to a file
#     server-config   - Get current JobSet configuration in YAML format
#
#   [Development]
#     ssh             - SSH to the head node as the current user
#     ssh-run         - Run a command on the head node as the current user
#     ssh-worker      - SSH to one of the worker nodes
#     ssh-root        - SSH to the head node as root
#     sync            - Start continuous sync from local to remote workspace
#     port-forward    - Start port forwarding to the head node (default port: 8888, change via FORWARD_PORT)
#     port-forward-auto - Start auto-reconnecting port forwarding (change via FORWARD_PORT)
#     port-forward-kill - Stop port forwarding
#
#   [Inspection]
#     list-jobs       - List jobs for the current JobSet
#     list-jobs-all   - List all jobs in the namespace
#     list-pods       - List pods for the current JobSet
#     list-nodes      - List TPU nodes with specific topology labels
#     list-queues     - List Kueue queues
#     list-queues-all - List all cluster queues with TPU resources
#     log-head        - Show logs for the head node
#     log-worker      - Show logs for one of the worker nodes
#     desc-jobset     - Describe the current JobSet
#     desc-workload   - Describe the current workload
#     desc-pods       - Describe pods for the current JobSet
#     desc-head       - Describe the head pod
#     desc-worker     - Describe a worker pod
#     desc-node       - Describe a TPU node
#     dash            - Print the Google Cloud Console dashboard URL
#     dash-all        - Print dashboard URLs for jobs and disks
#
#   [Troubleshooting]
#     head-restart    - Restart the head node
#     worker-restart  - Restart all the worker nodes
#     proxy-list      - List proxy pods
#     proxy-kill      - Delete proxy pods
#     debug-ports     - List pods with hostPorts (defaults to 29000)
#     debug-labels    - Compare JobSet nodeSelectors with node and flavor labels
#
#   [Cleanup]
#     disk-cleanup    - Remove all disk resources.
#     disk-register   - On-demand. Register the persistent disk (PV and PVC)
#     disk-unregister - On-demand. Unregister the persistent disk (PV and PVC)
#
#   [Control]
#     quit            - Exit interactive mode
#
set -e

SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd $SCRIPT_ROOT

source "src/utils.sh"
[[ -z "${JOBSET_NAME}" ]] && { select_preset || exit 1; }

# ============= Environment Variables begin =============
# don't change these, set via presets/<cluster>.sh

## jobset

export PROJECT="${PROJECT:-}"
export REGION="${REGION:-}"
export ZONE="${ZONE:-}"
export CLUSTER="${CLUSTER:-}"

export JOBSET_TPU_TYPE="${JOBSET_TPU_TYPE:-}"
export JOBSET_TPU_TOPO="${JOBSET_TPU_TOPO:-}"

export JOBSET_NAME="${JOBSET_NAME:-}"
export JOBSET_NAMESPACE="${JOBSET_NAMESPACE:-}"

## container images

export IMAGE_PATHWAYS_SERVER="${IMAGE_PATHWAYS_SERVER:-}"
export IMAGE_PATHWAYS_PROXY_SERVER="${IMAGE_PATHWAYS_PROXY_SERVER:-}"
export IMAGE_WORKSPACE="${IMAGE_WORKSPACE:-}"

## remote workspace

export WORKSPACE_CONTAINER="${WORKSPACE_CONTAINER:-}"
export WORKSPACE_USER="${WORKSPACE_USER:-}"

export WORKSPACE_JOBSET_TMPL="${WORKSPACE_JOBSET_TMPL:-}"

# disk settings
export WORKSPACE_DISK_NAME="${WORKSPACE_DISK_NAME:-}"
export WORKSPACE_DISK_SIZE="${WORKSPACE_DISK_SIZE:-}"
export WORKSPACE_DISK_ZONE="${WORKSPACE_DISK_ZONE:-}"
export WORKSPACE_DISK_CSI_HANDLE="${WORKSPACE_DISK_CSI_HANDLE:-}"
export WORKSPACE_DISK_PV_NAME="${WORKSPACE_DISK_PV_NAME-}"
export WORKSPACE_DISK_PVC_NAME="${WORKSPACE_DISK_PVC_NAME-}"

# sync settings
export WORKSPACE_LOCAL_ROOT="${WORKSPACE_LOCAL_ROOT:-}" # your local codebase
export WORKSPACE_LOCAL_VENV="${WORKSPACE_LOCAL_VENV:-}"
export WORKSPACE_REMOTE_ROOT="${WORKSPACE_REMOTE_ROOT:-}" # mirrored remote codebase (disk mount path)
export WORKSPACE_REMOTE_VENV="${WORKSPACE_REMOTE_VENV:-}"
export WORKSPACE_SYNC_EXCLUDE="${WORKSPACE_SYNC_EXCLUDE:-}"

# ============= Environment Variables end =============

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
REQUIRED_VARS=(
  PROJECT REGION ZONE CLUSTER
  JOBSET_TPU_TYPE JOBSET_TPU_TOPO JOBSET_NAME JOBSET_NAMESPACE
  IMAGE_PATHWAYS_SERVER IMAGE_PATHWAYS_PROXY_SERVER IMAGE_WORKSPACE
  WORKSPACE_CONTAINER WORKSPACE_JOBSET_TMPL
  WORKSPACE_DISK_NAME WORKSPACE_DISK_SIZE WORKSPACE_DISK_ZONE
  WORKSPACE_DISK_CSI_HANDLE WORKSPACE_DISK_PV_NAME WORKSPACE_DISK_PVC_NAME
  WORKSPACE_REMOTE_ROOT WORKSPACE_LOCAL_ROOT
)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Environment variable $var is not set."
    exit 1
  fi
done

# add global ignores
GLOBAL_SYNC_EXCLUDE="lost\+found,"
GLOBAL_SYNC_EXCLUDE+=".local,.bin,*.swp,*.lock,"
GLOBAL_SYNC_EXCLUDE+=".cache,.jax_cache,.pytest_cache,__pycache__,"
GLOBAL_SYNC_EXCLUDE+=".venv,.vscode,.git,"
GLOBAL_SYNC_EXCLUDE+="*.tar,"
export WORKSPACE_SYNC_EXCLUDE="$WORKSPACE_SYNC_EXCLUDE,$GLOBAL_SYNC_EXCLUDE"

# check python3 is available
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is not installed or not in PATH."
  exit 1
fi

# gcloud auth check
if ! gcloud auth print-access-token &>/dev/null; then
  echo "No active gcloud account found. Please run 'gcloud auth login'."
  exit 1
fi
# if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
#   echo "No active gcloud account found. Please run 'gcloud auth login'."
#   exit 1
# fi

# workspace disk
if gcloud compute disks describe $WORKSPACE_DISK_NAME --zone=$WORKSPACE_DISK_ZONE --project=$PROJECT &>/dev/null; then
  :
else
  echo -n "disk '$WORKSPACE_DISK_NAME' not found in '$PROJECT:$WORKSPACE_DISK_ZONE'. create it? (y/N) "
  read -r REPLY
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    gcloud compute disks create $WORKSPACE_DISK_NAME --size=${WORKSPACE_DISK_SIZE/Gi/GB} --zone=$WORKSPACE_DISK_ZONE --project=$PROJECT \
    && echo "$WORKSPACE_DISK_NAME created: https://pantheon.corp.google.com/compute/disksDetail/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME?project=$PROJECT" \
    || { echo "failed to create $WORKSPACE_DISK_NAME"; export WORKSPACE_DISK_NAME=""; }
  else
    export WORKSPACE_DISK_NAME=""
    echo "disk related features will be disabled."
  fi
fi

generate_jobset_yaml() {
  local workspace_disk_pvc_name=""
  local workspace_remote_root=""
  if [[ -n "$WORKSPACE_DISK_NAME" ]]; then
    workspace_disk_pvc_name="$WORKSPACE_DISK_PVC_NAME"
    workspace_remote_root="$WORKSPACE_REMOTE_ROOT"
  fi

  _generate_jobset_yaml "${WORKSPACE_JOBSET_TMPL}" "${JOBSET_NAME}" "${JOBSET_TPU_TYPE}" "${JOBSET_TPU_TOPO}" "${IMAGE_PATHWAYS_SERVER}" "${IMAGE_PATHWAYS_PROXY_SERVER}" "${WORKSPACE_CONTAINER}" "${IMAGE_WORKSPACE}" "${workspace_disk_pvc_name}" "${workspace_remote_root}"
}

generate_pv_yaml() {
  if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
    echo "error: disk doesn't exist."
    return 1
  fi
  _generate_pv_yaml "${WORKSPACE_DISK_PV_NAME}" "${WORKSPACE_DISK_CSI_HANDLE}" "${WORKSPACE_DISK_SIZE}"
}

generate_pvc_yaml() {
  if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
    echo "error: disk doesn't exist."
    return 1
  fi
  _generate_pvc_yaml "${WORKSPACE_DISK_PVC_NAME}" "${WORKSPACE_DISK_SIZE}" "${WORKSPACE_DISK_PV_NAME}"
}

register_disk() {
  if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
    echo "error: disk doesn't exist."
    return 1
  fi
  _register_disk "${WORKSPACE_DISK_PVC_NAME}" "${WORKSPACE_DISK_PV_NAME}" "${WORKSPACE_DISK_CSI_HANDLE}" "${WORKSPACE_DISK_SIZE}" "${JOBSET_NAMESPACE}"
}

unregister_disk() {
  _unregister_disk "${JOBSET_NAME}" "${WORKSPACE_DISK_PVC_NAME}" "${WORKSPACE_DISK_PV_NAME}" "${WORKSPACE_DISK_CSI_HANDLE}" "${WORKSPACE_DISK_SIZE}"
}

# enter kube context
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config.$PROJECT.$REGION.$CLUSTER}"
if ! [ -f "$KUBECONFIG" ] || ! kubectl get namespaces &>/dev/null; then
  gcloud container clusters get-credentials $CLUSTER --region=$REGION --project=$PROJECT --dns-endpoint &>/dev/null || { echo "gcloud get-credentials failed"; exit 1; }
  kubectl config use-context "gke_${PROJECT}_${REGION}_${CLUSTER}" >/dev/null || { echo "kubectl use-context failed"; exit 1; }
fi
kubectl config set-context --current --namespace=$JOBSET_NAMESPACE >/dev/null || { echo "kubectl set-context failed"; exit 1; }

# detect run mode
if [ -z "$1" ]; then
  INTERACTIVE=true
  echo
  echo "cluster:   ${CLUSTER}"
  echo "namespace: ${JOBSET_NAMESPACE}"
  echo "jobset:    ${JOBSET_NAME}"
  echo "tpu:       ${JOBSET_TPU_TYPE}:${JOBSET_TPU_TOPO}"
  echo "tmpl:      ${WORKSPACE_JOBSET_TMPL}"

  [[ -n "$WORKSPACE_DISK_NAME" ]] \
  && echo "disk:      ${WORKSPACE_DISK_CSI_HANDLE}" \
  || echo "disk:      null"

  echo "local:     ${USER}:${WORKSPACE_LOCAL_ROOT}"

  [[ -n "$WORKSPACE_DISK_NAME" ]] \
  && echo "remote:    ${WORKSPACE_USER}:${WORKSPACE_REMOTE_ROOT}" \
  || echo "remote:    null"

  [[ -n "$WORKSPACE_DISK_NAME" ]] \
  && echo "ignore:    ${WORKSPACE_SYNC_EXCLUDE}" \
  || echo "ignore:    n/a"
  echo
else
  INTERACTIVE=false
  ACTIONS=("$@")
fi

set +e

while true; do
  trap 'echo' INT
  if [ ${#ACTIONS[@]} -gt 0 ]; then
    action="${ACTIONS[0]}"; ACTIONS=("${ACTIONS[@]:1}")
  elif [ "$INTERACTIVE" = true ]; then
    read -e -p "${CLUSTER}:${JOBSET_NAME} > " action
  else
    break
  fi

  case $action in
  list-jobs)
    kubectl get jobs -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME"
    ;;
  list-jobs-all)
    kubectl get jobs -o wide
    ;;
  list-pods)
    kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME"
    ;;
  list-queues)
    kubectl get queues
    ;;
  list-queues-all)
    for q in $(kubectl get clusterqueues | grep -v NAME | awk '{print $1}'); do
      echo
      echo "======== $q ========"
      echo
      kubectl get clusterqueue $q -o yaml | egrep 'cpu|tpu'
    done
    ;;
  list-nodes)
    kubectl get nodes -l cloud.google.com/gke-tpu-partition-4x4x4-id
    ;;
  server-yaml)
    read -e -p "Output file [${JOBSET_NAME}.yaml]: " yaml_file
    yaml_file="${yaml_file:-${JOBSET_NAME}.yaml}"
    if [ -f "$yaml_file" ]; then
      echo -n "File $yaml_file already exists. Overwrite? (y/N) "
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
    # auto register disk
    if [[ -n "$WORKSPACE_DISK_NAME" ]]; then
      register_disk || { echo "error: failed to register disk"; continue; }
    fi

    generate_jobset_yaml | kubectl apply -f - && echo "applied $JOBSET_NAME"

    # run in a subshell to allow ctrl-c interrupt
    (
      until WORKLOAD=$(kubectl get workloads | grep "$JOBSET_NAME" | awk '{print $1}') && [ -n "$WORKLOAD" ]; do
        echo -n "."; sleep 1
      done
      echo

      if [[ "$CLUSTER" == "bodaborg-super-alpha-cluster" ]]; then
        error_regex="FailedCreateSlice|couldn't assign flavors|doesn't exist"

        until kubectl describe workload "$WORKLOAD" 2>/dev/null | egrep -q "SlicesCreated|$error_regex"; do
          echo -n "."; sleep 1
        done
        if kubectl describe workload "$WORKLOAD" | egrep -q "$error_regex"; then
          kubectl describe workload "$WORKLOAD" | egrep "$error_regex"; continue
        fi
        echo "SlicesCreated"

        kubectl patch job $JOBSET_NAME-pathways-head-0 -p '{"spec":{"suspend":false}}' --type=merge
        kubectl patch job $JOBSET_NAME-worker-0 -p '{"spec":{"suspend":false}}' --type=merge

        until kubectl describe workload "$WORKLOAD" 2>/dev/null | egrep -q "Admitted by|$error_regex"; do
          echo -n "."; sleep 1
        done
        if kubectl describe workload "$WORKLOAD" | egrep -q "$error_regex"; then
          kubectl describe workload "$WORKLOAD" | egrep "$error_regex"; continue
        fi
        echo "Admitted"
      else
        error_regex="FailedCreateSlice|EvictedDueToAdmissionCheck|couldn't assign flavors|doesn't exist"

        until kubectl describe workload "$WORKLOAD" 2>/dev/null | egrep -q "Admitted by|$error_regex"; do
          echo -n "."; sleep 1
        done
        if kubectl describe workload "$WORKLOAD" | egrep -q "$error_regex"; then
          kubectl describe workload "$WORKLOAD" | egrep "$error_regex"; continue
        fi
        echo "Admitted"
      fi
    )
    ;;
  server-resume)
    kubectl patch job $JOBSET_NAME-pathways-head-0 -p '{"spec":{"suspend":false}}' --type=merge
    kubectl patch job $JOBSET_NAME-worker-0 -p '{"spec":{"suspend":false}}' --type=merge
    ;;
  server-stop)
    generate_jobset_yaml | kubectl delete -f - && echo "deleted $JOBSET_NAME" || continue

    # run in a subshell to allow ctrl-c interrupt
    (
      while true; do
        kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" 2>&1 | grep -q "No resources found" && break
        echo -n "."
        sleep 1
      done
      echo "Terminated"
    )
    ;;
  server-wait)
    verify_pods_running ${JOBSET_NAME} && echo "pods are running" || echo "pods are not running"
    ;;
  head-restart)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    kubectl exec -it "$HEAD_POD" -c pathways-rm -- /bin/sh -c "kill 1"
    kubectl exec -it "$HEAD_POD" -c pathways-proxy -- /bin/sh -c "kill 1"
    ;;
  worker-restart)
    # one worker down will trigger all workers to restart
    WORKER_POD=$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}'); [[ -z "$WORKER_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    kubectl exec -it "$WORKER_POD" -c pathways-worker -- /bin/sh -c "kill 1"
    ;;
  ssh-init)
    if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
      echo "error: 'ssh-init' requires disk, you can still use 'ssh-root'."
      continue
    fi

    # run in a subshell to allow ctrl-c interrupt
    (
      echo -n "wait for head node ready"
      for i in {0..120}; do
        verify_head_running ${JOBSET_NAME} && { echo; break; }
        echo -n "."
        sleep 1
      done
      verify_head_running ${JOBSET_NAME} || { echo "error: head node not ready"; continue; }

      HEAD_POD=$(get_head_pod_name ${JOBSET_NAME})
      if kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/sh -c "! [ -d '${WORKSPACE_REMOTE_ROOT}/rw-cli/' ]" 2>/dev/null; then
        echo "error: rw-cli not found on remote workspace disk, please run 'disk-init' to do initial sync."
        continue
      fi

      echo "[root] add user ${WORKSPACE_USER} to $HEAD_POD"
      kubectl exec -i "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/bash -s "${WORKSPACE_USER}" < "${SCRIPT_ROOT}/scripts/add_user.sh" || continue
      echo "[${WORKSPACE_USER}] init user home on $HEAD_POD"
      kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "${WORKSPACE_USER}" -c "export DISK_MOUNT_PATH=${WORKSPACE_REMOTE_ROOT}; bash -s" < "${SCRIPT_ROOT}/scripts/init_home.sh" || continue
      echo "[${WORKSPACE_USER}] init venv on $HEAD_POD"
      kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /bin/bash -l "${WORKSPACE_USER}" -c "export GITHUB_ROOT=${WORKSPACE_REMOTE_ROOT}; export VENV_PATH=${WORKSPACE_REMOTE_VENV}; bash -s" < "${SCRIPT_ROOT}/scripts/init_venv.sh"
    )
    ;;
  ssh-root)
    # run in a subshell to allow ctrl-c interrupt
    (
      echo -n "wait for head node ready"
      for i in {0..120}; do
        verify_head_running ${JOBSET_NAME} && { echo; break; }
        echo -n "."
        sleep 1
      done
      verify_head_running ${JOBSET_NAME} || { echo "error: head node not ready"; continue; }
    )

    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    echo "ssh to $HEAD_POD as root"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- /bin/bash
    ;;
  ssh)
    if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
      echo "error: 'ssh' requires disk, you can still use 'ssh-root'."
      continue
    fi

    # run in a subshell to allow ctrl-c interrupt
    (
      echo -n "wait for head node ready"
      for i in {0..120}; do
        verify_head_running ${JOBSET_NAME} && { echo; break; }
        echo -n "."
        sleep 1
      done
      verify_head_running ${JOBSET_NAME} || { echo "error: head node not ready"; continue; }
    )

    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    echo "ssh to $HEAD_POD as ${WORKSPACE_USER}"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /usr/bin/zsh -l "${WORKSPACE_USER}"
    ;;
  ssh-run)
    if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
      echo "error: 'ssh-run' requires disk, you can still use 'ssh-root'."
      continue
    fi

    # run in a subshell to allow ctrl-c interrupt
    (
      echo -n "wait for head node ready"
      for i in {0..120}; do
        verify_head_running ${JOBSET_NAME} && { echo; break; }
        echo -n "."
        sleep 1
      done
      verify_head_running ${JOBSET_NAME} || { echo "error: head node not ready"; continue; }
    )

    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    if [ ${#ACTIONS[@]} -gt 0 ]; then
      run_cmd="${ACTIONS[*]}"
      ACTIONS=()
    else
      read -e -p "Command to run: " run_cmd
    fi
    echo "running '$run_cmd' on $HEAD_POD"
    kubectl exec -it "$HEAD_POD" -c "$WORKSPACE_CONTAINER" -- su -s /usr/bin/zsh -l "${WORKSPACE_USER}" -c "source ~/.zshrc 2>/dev/null; $run_cmd"
    ;;
  ssh-worker)
    WORKER_POD=$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}'); [[ -z "$WORKER_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    echo "ssh to $WORKER_POD"
    kubectl exec -it "$WORKER_POD" -- /bin/sh
    ;;
  bootstrap)
    if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
      echo "error: 'bootstrap' requires disk."
      continue
    fi
    if kubectl get jobset "$JOBSET_NAME" &>/dev/null; then
      echo "error: jobset '$JOBSET_NAME' is running. please run 'server-stop' first."
      continue
    fi
    ACTIONS=("server-start" "disk-init" "ssh-init" "${ACTIONS[@]}")
    ;;
  disk-init)
    if [[ -z "$WORKSPACE_DISK_NAME" ]]; then
      echo "error: 'disk-init' requires disk."
      continue
    fi
    if ! kubectl get jobset "$JOBSET_NAME" &>/dev/null; then
      echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."
      continue
    fi
    if kubectl get pv | grep -q "$WORKSPACE_DISK_PV_NAME"; then echo "$WORKSPACE_DISK_PV_NAME already registered"; else
      generate_pv_yaml | kubectl apply -f - && echo "registered $WORKSPACE_DISK_PV_NAME" || continue
    fi
    if kubectl get pvc | grep -q "$WORKSPACE_DISK_PVC_NAME"; then echo "$WORKSPACE_DISK_PVC_NAME already registered"; else
      generate_pvc_yaml | kubectl apply -f - && echo "registered $WORKSPACE_DISK_PVC_NAME"
    fi
    if [[ -z "$WORKSPACE_LOCAL_ROOT" ]]; then
      echo "error: WORKSPACE_LOCAL_ROOT is not set."
      exit 1
    fi
    # if ps aux | grep "devspace sync" | grep -q -v grep; then
    #   echo "devspace sync is already running"
    #   exit 1
    # fi
    # for usage: https://www.devspace.sh/docs/cli/devspace_sync
    # for different sync strategy: https://www.devspace.sh/docs/configuration/dev/connections/file-sync
    devspace sync \
      --path="${WORKSPACE_LOCAL_ROOT}:${WORKSPACE_REMOTE_ROOT}" \
      --exclude="${WORKSPACE_SYNC_EXCLUDE}" \
      --namespace="${JOBSET_NAMESPACE}" \
      --label-selector=batch.kubernetes.io/job-name=${JOBSET_NAME}-pathways-head-0 \
      --container="${WORKSPACE_CONTAINER}" \
      --upload-only \
      --no-watch
    ;;
  sync)
    if [[ -z "$WORKSPACE_LOCAL_ROOT" ]]; then
      echo "error: WORKSPACE_LOCAL_ROOT is not set."
      exit 1
    fi
    # if ps aux | grep "devspace sync" | grep -q -v grep; then
    #   echo "devspace sync is already running"
    #   continue
    # fi
    # for usage: https://www.devspace.sh/docs/cli/devspace_sync
    # for different sync strategy: https://www.devspace.sh/docs/configuration/dev/connections/file-sync
    devspace sync \
      --path="${WORKSPACE_LOCAL_ROOT}:${WORKSPACE_REMOTE_ROOT}" \
      --exclude="${WORKSPACE_SYNC_EXCLUDE}" \
      --namespace="${JOBSET_NAMESPACE}" \
      --label-selector=batch.kubernetes.io/job-name=${JOBSET_NAME}-pathways-head-0 \
      --container="$WORKSPACE_CONTAINER"
    ;;
  log-head)
    kubectl logs -l jobset.sigs.k8s.io/jobset-name=$JOBSET_NAME,jobset.sigs.k8s.io/replicatedjob-name=pathways-head -c pathways-rm --tail=20
    ;;
  log-worker)
    # WORKER_POD=$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}')
    # kubectl logs $WORKER_POD
    echo -n "https://pantheon.corp.google.com/logs/query;query="
    echo -n "resource.type%3D%22k8s_container"
    echo -n "%22%0Aresource.labels.project_id%3D%22$PROJECT"
    echo -n "%22%0Aresource.labels.location%3D%22$REGION"
    echo -n "%22%0Aresource.labels.cluster_name%3D%22$CLUSTER"
    echo -n "%22%0Aresource.labels.namespace_name%3D%22$JOBSET_NAMESPACE"
    echo -n "%22%0Alabels.k8s-pod%2Fjobset_sigs_k8s_io%2Fjobset-name%3D%22$JOBSET_NAME"
    echo -n "%22%0Aresource.labels.container_name%3D%22pathways-worker"
    echo -n "%22;duration=PT6H"
    echo "?project=$PROJECT"
    ;;
  desc-pods)
    kubectl describe pods -l jobset.sigs.k8s.io/jobset-name=$JOBSET_NAME
    ;;
  desc-head)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    kubectl describe pods $HEAD_POD
    ;;
  desc-worker)
    WORKER_POD=$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}'); [[ -z "$WORKER_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
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
    register_disk
    ;;
  disk-unregister)
    unregister_disk
    ;;
  disk-cleanup)
    echo -n "This will delete all disk resources ($WORKSPACE_DISK_PVC_NAME, $WORKSPACE_DISK_PV_NAME, and the GCE disk $WORKSPACE_DISK_NAME). Are you sure? (y/N) "
    read -r REPLY
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      continue
    fi
    unregister_disk

    gcloud compute disks delete "$WORKSPACE_DISK_NAME" --zone="$WORKSPACE_DISK_ZONE" --project="$PROJECT" --quiet && echo "deleted gcloud disk $DISK_NAME"
    ;;
  proxy-list)
    kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})"
    ;;
  proxy-kill)
    kubectl delete pods $(kubectl get pods | egrep "^isc-(proxy-$USER|${JOBSET_NAME})" | awk '{print $1}')
    ;;
  debug-ports)
    port="${2:-29000}"
    if [ "$INTERACTIVE" = false ] && [ ${#ACTIONS[@]} -gt 0 ]; then
      port="${ACTIONS[0]}"
      ACTIONS=("${ACTIONS[@]:1}")
    fi
    echo "Searching for pods with hostPort: $port"
    kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].ports[?(@.hostPort)].hostPort}{"\n"}{end}' | grep "$port" || echo "No pods found with hostPort $port."
    ;;
  debug-labels)
    # Try to find a node name automatically
    node_name=$(kubectl get nodes | grep gke-tpu- | head -n 1 | awk '{print $1}')
    echo "Node name: $node_name"
    # read -e -p "Node name [$node_name]: " input_node
    # node_name="${input_node:-$node_name}"

    # List and pick flavor
    echo "Available Resource Flavors:"
    flavors=($(kubectl get resourceflavors -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#flavors[@]} -eq 0 ]; then
      echo "No resource flavors found."
      flavor_name=""
    else
      for i in "${!flavors[@]}"; do
        echo "  [$i] ${flavors[$i]}"
      done
      read -p "Select flavor index [0]: " flavor_idx
      flavor_idx="${flavor_idx:-0}"
      flavor_name="${flavors[$flavor_idx]}"
    fi

    debug_labels "$JOBSET_NAME" "$node_name" "$flavor_name"
    ;;
  port-forward)
    FORWARD_PORT="${FORWARD_PORT:-8888}"
    if ps aux | egrep "kubectl port-forward.*$FORWARD_PORT:$FORWARD_PORT" | grep -q -v grep; then
      echo "port-forward on port ${FORWARD_PORT} is already running"
    else
      HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
      # localhost:FORWARD_PORT <=> HEAD_POD:FORWARD_PORT
      kubectl port-forward ${HEAD_POD} ${FORWARD_PORT}:${FORWARD_PORT} >/dev/null 2>/dev/null &
      echo "port-forward started on port ${FORWARD_PORT}"
    fi
    ;;
  port-forward-auto)
    FORWARD_PORT="${FORWARD_PORT:-8888}"
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    echo "Starting auto port-forward for $HEAD_POD on port $FORWARD_PORT..."

    # run in a subshell to allow ctrl-c interrupt
    (
      while true; do
        if ! ps aux | grep "kubectl port-forward" | grep "$FORWARD_PORT:$FORWARD_PORT" | grep -v grep > /dev/null; then
          echo "$(date): Starting port-forward..."
          kubectl port-forward "$HEAD_POD" "$FORWARD_PORT:$FORWARD_PORT" >/dev/null 2>&1 &
        fi
        sleep 5
        # Check if the pod still exists; if not, exit the loop
        kubectl get pod "$HEAD_POD" >/dev/null 2>&1 || { echo "Pod $HEAD_POD no longer exists. Stopping auto-forward."; break; }
      done
    )
    ;;
  port-forward-kill)
    if ps aux | grep "kubectl port-forward" | grep -q -v grep; then
      pkill -f "kubectl port-forward"
      echo "port-forward stopped"
    fi
    ;;
  dash)
    echo "https://pantheon.corp.google.com/kubernetes/service/$REGION/$CLUSTER/$JOBSET_NAMESPACE/$JOBSET_NAME/overview?project=$PROJECT"
    ;;
  dash-all)
    HEAD_POD=$(get_head_pod_name ${JOBSET_NAME}); [[ -z "$HEAD_POD" ]] && { echo "error: jobset '$JOBSET_NAME' is not running. please run 'server-start' first."; continue; }
    echo "jobs: https://pantheon.corp.google.com/kubernetes/service/$REGION/$CLUSTER/$JOBSET_NAMESPACE/$JOBSET_NAME/overview?project=$PROJECT"
    echo "evts: https://console.cloud.google.com/kubernetes/pod/$REGION/$CLUSTER/$JOBSET_NAMESPACE/$HEAD_POD/events?project=$PROJECT"
    [[ -n "$WORKSPACE_DISK_NAME" ]] && echo "disk: https://pantheon.corp.google.com/compute/disksDetail/zones/$WORKSPACE_DISK_ZONE/disks/$WORKSPACE_DISK_NAME?project=$PROJECT"
    ;;
  quit|exit)
    exit 0
    ;;
  *)
    echo "unknown command: $action"
    [ "$INTERACTIVE" = false ] && exit 1
    ;;
  esac
  trap - INT
done
