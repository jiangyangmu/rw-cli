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
  echo "----------------------------------------------------------------------------------------------------------------"
  printf "%-45s %-25s %-25s %-25s\n" "LABEL KEY" "Jobset has" "Node wants" "How to fix"
  echo "----------------------------------------------------------------------------------------------------------------"

  # Iterate over union of keys
  jq -n --argjson js "$js_selectors" --argjson node "$node_labels" \
    '$js + $node | keys[]' | jq -r . | while read -r key; do
    local expected_val=$(echo "$js_selectors" | jq -r --arg K "$key" '.[$K]')
    local actual_val=$(echo "$node_labels" | jq -r --arg K "$key" '.[$K]')

    # Filter: only show if key is in js_selectors OR if it's a "TPU/GKE" relevant label
    if [[ "$expected_val" != "null" ]] || [[ "$key" =~ cloud.google.com/|kueue.x-k8s.io/ ]]; then
      if [ "$expected_val" == "$actual_val" ]; then
        printf "✅ %-43s %-25s %-25s\n" "$key" "$expected_val" "$actual_val"
      elif [ "$expected_val" == "null" ]; then
        :
        # printf "✅ %-43s %-25s %-25s\n" "$key" "(not set)" "$actual_val"
      elif [ "$actual_val" == "null" ]; then
        printf "❌ %-43s %-25s %-25s %-25s\n" "$key" "$expected_val" "(not set)" "remove"
      else
        printf "❌ %-43s %-25s %-25s %-25s\n" "$key" "$expected_val" "$actual_val" "update to match"
      fi
    fi
  done

  if [ -n "$flavor_name" ]; then
    local flavor_labels=$(kubectl get resourceflavors "$flavor_name" -o json | jq -r '.spec.nodeLabels // {}')
    echo -e "\n🔍 Comparing JobSet '$jobset_name' vs Flavor '$flavor_name'"
    echo "----------------------------------------------------------------------------------------------------------------"
    printf "%-45s %-25s %-25s %-25s\n" "LABEL KEY" "Jobset has" "Flavor wants" "How to fix"
    echo "----------------------------------------------------------------------------------------------------------------"

    # Iterate over union of keys
    jq -n --argjson js "$js_selectors" --argjson flavor "$flavor_labels" \
      '$js + $flavor | keys[]' | jq -r . | while read -r key; do
      local expected_val=$(echo "$js_selectors" | jq -r --arg K "$key" '.[$K]')
      local actual_val=$(echo "$flavor_labels" | jq -r --arg K "$key" '.[$K]')

      # Filter: only show if key is in js_selectors OR if it's a "TPU/GKE/Flavor" relevant label
      if [[ "$expected_val" != "null" ]] || [[ "$key" =~ cloud.google.com/|kueue.x-k8s.io/ ]]; then
        if [ "$expected_val" == "$actual_val" ]; then
          printf "✅ %-43s %-25s %-25s\n" "$key" "$expected_val" "$actual_val"
        elif [ "$expected_val" == "null" ]; then
          :
          # printf "✅ %-43s %-25s %-25s\n" "$key" "(not set)" "$actual_val"
        elif [ "$actual_val" == "null" ]; then
        printf "❌ %-43s %-25s %-25s %-25s\n" "$key" "$expected_val" "(not set)" "remove"
      else
        printf "❌ %-43s %-25s %-25s %-25s\n" "$key" "$expected_val" "$actual_val" "update to match"
        fi
      fi
    done
  fi
  echo ""
}

_generate_jobset_yaml() {
  local workspace_jobset_tmpl=$1
  local jobset_name=$2
  local jobset_tpu_type=$3
  local jobset_tpu_topo=$4
  local image_pathways_server=$5
  local image_pathways_proxy_server=$6
  local workspace_container=$7
  local image_workspace=$8
  local workspace_disk_pvc_name=$9
  local workspace_remote_root=${10}

  local tmpl_flags=""
  tmpl_flags+=" --user_container=${workspace_container}"
  tmpl_flags+=" --user_container_image=${image_workspace}"
  tmpl_flags+=" --user_pvc_name=${workspace_disk_pvc_name}"
  tmpl_flags+=" --user_disk_mount_path=${workspace_remote_root}"

  python3 src/yaml_gen_jobset.py "$workspace_jobset_tmpl" \
    --jobset_name="$jobset_name" \
    --server_image="$image_pathways_server" \
    --proxy_image="$image_pathways_proxy_server" \
    --tpu_type="$jobset_tpu_type:$jobset_tpu_topo" \
    $tmpl_flags
}

_generate_pv_yaml() {
  local workspace_disk_pv_name=$1
  local workspace_disk_csi_handle=$2
  local workspace_disk_size=$3
  local tmpl_file="yamls/user-pv.yaml"

  python3 src/yaml_gen_pv.py "$tmpl_file" \
    --user_pv_name="${workspace_disk_pv_name}" \
    --user_pv_handle="${workspace_disk_csi_handle}" \
    --user_pv_size="${workspace_disk_size}"
}

_generate_pvc_yaml() {
  local workspace_disk_pvc_name=$1
  local workspace_disk_size=$2
  local workspace_disk_pv_name=$3
  local tmpl_file="yamls/user-pvc.yaml"

  python3 src/yaml_gen_pvc.py "$tmpl_file" \
    --user_pvc_name="${workspace_disk_pvc_name}" \
    --user_pvc_size="${workspace_disk_size}" \
    --user_pv_name="${workspace_disk_pv_name}"
}

_register_disk() {
  local workspace_disk_pvc_name=$1
  local workspace_disk_pv_name=$2
  local workspace_disk_csi_handle=$3
  local workspace_disk_size=$4
  local jobset_namespace=$5

  # delete pvc if namespace not match
  for ns in $(kubectl get pvc --all-namespaces 2>/dev/null | grep "$workspace_disk_pvc_name" | grep -v "$jobset_namespace" | awk '{print $1}'); do
    echo "deleting existing pvc '$workspace_disk_pvc_name' in namespace '$ns'"
    kubectl delete pvc "$workspace_disk_pvc_name" -n "$ns"
  done
  # delete pv if claim not match
  for claim in $(kubectl get pv --all-namespaces 2>/dev/null | grep "$workspace_disk_pv_name" | grep -v "$jobset_namespace/$workspace_disk_pvc_name" | awk '{print $6}'); do
    echo "deleting existing pv '$workspace_disk_pv_name' with claim '$claim'"
    kubectl patch pv "$workspace_disk_pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null
    kubectl delete pv "$workspace_disk_pv_name"
  done

  if ! kubectl get pv "$workspace_disk_pv_name" &>/dev/null; then
    _generate_pv_yaml "$workspace_disk_pv_name" "$workspace_disk_csi_handle" "$workspace_disk_size" | kubectl apply -f - \
    && { echo "added pv '$workspace_disk_pv_name'"; } \
    || { echo "failed to register $workspace_disk_pv_name"; return 1; }
  else
    echo "found pv '$workspace_disk_pv_name'"
  fi
  if ! kubectl get pvc "$workspace_disk_pvc_name" &>/dev/null; then
    _generate_pvc_yaml "$workspace_disk_pvc_name" "$workspace_disk_size" "$workspace_disk_pv_name" | kubectl apply -f - \
    && { echo "added pvc '$workspace_disk_pvc_name' in namespace '$jobset_namespace'"; } \
    || { echo "failed to register $workspace_disk_pvc_name"; return 1; }
  else
    echo "found pvc '$workspace_disk_pvc_name'"
  fi

  return 0
}

_unregister_disk() {
  local jobset_name=$1
  local workspace_disk_pvc_name=$2
  local workspace_disk_pv_name=$3
  local workspace_disk_csi_handle=$4
  local workspace_disk_size=$5

  if kubectl get jobset "$jobset_name" &>/dev/null; then
    echo "Error: JobSet '$jobset_name' is still running. Please run 'server-stop' first."
    return 1
  fi

  if kubectl get pvc "$workspace_disk_pvc_name" &>/dev/null; then
    _generate_pvc_yaml "$workspace_disk_pvc_name" "$workspace_disk_size" "$workspace_disk_pv_name" | kubectl delete -f - --timeout=10s \
    && { echo "unregistered $workspace_disk_pvc_name"; } \
    || { echo "failed to unregister $workspace_disk_pvc_name"; return 1; }
  else
    echo "pvc '$workspace_disk_pvc_name' already deleted"
  fi

  if kubectl get pv "$workspace_disk_pv_name" &>/dev/null; then
    kubectl patch pv "$workspace_disk_pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null

    _generate_pv_yaml "$workspace_disk_pv_name" "$workspace_disk_csi_handle" "$workspace_disk_size" | kubectl delete -f - --timeout=10s \
    && { echo "unregistered $workspace_disk_pv_name"; } \
    || { echo "failed to unregister $workspace_disk_pv_name"; return 1; }
  else
    echo "pv '$workspace_disk_pv_name' already deleted"
  fi

  return 0
}
