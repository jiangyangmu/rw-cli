get_head_pod_name() {
  local jobset_name=$1
  kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$jobset_name" | grep pathways-head | head -n 1 | awk '{print $1}'
}

get_worker_pod_name() {
  local jobset_name=$1
  kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name="$JOBSET_NAME" | grep worker | head -n 1 | awk '{print $1}'
}

verify_pods_running() {
  local jobset_name=$1
  echo "Verifying pods for JobSet: ${jobset_name}..."

  # Check Head Pod
  local head_pod=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name=${jobset_name} -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | tr ' ' '\n' | grep 'head' || true)
  if [[ -z "$head_pod" ]]; then
    echo "[error] Head pod is not in Running state."
    return 1
  fi

  # Check 4 Worker Pods (worker-0-0 through worker-0-3)
  # TODO: should check all pods
  for i in {0..3}; do
    local worker_pod=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name=${jobset_name} -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | tr ' ' '\n' | grep "worker-0-$i" || true)
    if [[ -z "$worker_pod" ]]; then
      echo "[error] Worker pod worker-0-$i is not in Running state."
      return 1
    fi
  done

  return 0
}

verify_head_running() {
  local jobset_name=$1

  # Check Head Pod
  local head_pod=$(kubectl get pods --selector=jobset.sigs.k8s.io/jobset-name=${jobset_name} -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | tr ' ' '\n' | grep 'head' || true)
  if [[ -z "$head_pod" ]]; then
    return 1
  fi

  return 0
}
