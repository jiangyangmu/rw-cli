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
  echo "Verifying all pods for JobSet: ${jobset_name}..."

  # Get expected count from JobSet
  local expected=$(kubectl get jobset "$jobset_name" -o jsonpath='{.spec.replicatedJobs[*].replicas}' 2>/dev/null | awk '{for(i=1;i<=NF;i++)s+=$i;print s}')
  if [[ -z "$expected" ]]; then
    echo "[error] JobSet $jobset_name not found."
    return 1
  fi

  # Get all pods and their phases in one go
  local pods_output=$(kubectl get pods -l jobset.sigs.k8s.io/jobset-name="$jobset_name" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}')
  local running_count=$(echo "$pods_output" | grep -c " Running$" || echo 0)

  if [ "$running_count" -ge "$expected" ]; then
    return 0
  fi

  local actual_count=$(echo "$pods_output" | grep -c . || echo 0)
  echo "[error] Expected $expected running pods, but found $running_count running ($actual_count total)."
  if [ "$actual_count" -gt 0 ]; then
    echo "Current pod statuses:"
    echo "$pods_output" | sed 's/^/  /'
  fi
  return 1
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

debug_labels() {
  local jobset_name=$1
  local node_name=$2
  local flavor_name=$3

  if [ -z "$jobset_name" ] || [ -z "$node_name" ]; then
    echo "Usage: debug-labels <jobset-name> <node-name> [flavor-name]"
    return 1
  fi

  # Extract nodeSelector from the first replicatedJob (index 1 is usually the workers)
  local js_selectors=$(kubectl get jobset "$jobset_name" -o json | jq -r '.spec.replicatedJobs[1].template.spec.template.spec.nodeSelector // {}')
  local node_labels=$(kubectl get node "$node_name" -o json | jq -r '.metadata.labels')

  echo -e "\n🔍 Comparing JobSet '$jobset_name' vs Node '$node_name'"
  echo "--------------------------------------------------------------------------------"
  printf "%-45s %-15s %-15s\n" "LABEL KEY" "EXPECTED" "ACTUAL"
  echo "--------------------------------------------------------------------------------"

  echo "$js_selectors" | jq -r 'to_entries[] | .key + " " + .value' | while read -r key val; do
    local actual_val=$(echo "$node_labels" | jq -r --arg K "$key" '.[$K]')
    if [ "$actual_val" == "$val" ]; then
      printf "✅ %-43s %-15s %-15s\n" "$key" "$val" "$actual_val"
    elif [ "$actual_val" == "null" ]; then
      printf "❌ %-43s %-15s %-15s\n" "$key" "$val" "(missing)"
    else
      printf "❌ %-43s %-15s %-15s\n" "$key" "$val" "$actual_val"
    fi
  done

  if [ -n "$flavor_name" ]; then
    local flavor_labels=$(kubectl get resourceflavors "$flavor_name" -o json | jq -r '.spec.nodeLabels // {}')
    echo -e "\n🔍 Comparing JobSet '$jobset_name' vs Flavor '$flavor_name'"
    echo "--------------------------------------------------------------------------------"
    printf "%-45s %-15s %-15s\n" "LABEL KEY" "EXPECTED" "ACTUAL"
    echo "--------------------------------------------------------------------------------"

    echo "$js_selectors" | jq -r 'to_entries[] | .key + " " + .value' | while read -r key val; do
      local actual_val=$(echo "$flavor_labels" | jq -r --arg K "$key" '.[$K]')
      if [ "$actual_val" == "$val" ]; then
        printf "✅ %-43s %-15s %-15s\n" "$key" "$val" "$actual_val"
      elif [ "$actual_val" == "null" ]; then
        printf "❌ %-43s %-15s %-15s\n" "$key" "$val" "(missing)"
      else
        printf "❌ %-43s %-15s %-15s\n" "$key" "$val" "$actual_val"
      fi
    done
  fi
  echo ""
}
