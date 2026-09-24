 #!/usr/bin/env bash
set -euo pipefail

# Function to print log messages with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

PROJECT_CPD_INST_OPERATORS="${PROJECT_CPD_INST_OPERATORS:-}"
PROJECT_CPD_INST_OPERANDS="${PROJECT_CPD_INST_OPERANDS:-}"

if [[ -z "$PROJECT_CPD_INST_OPERATORS" ]]; then
  log "ERROR: PROJECT_CPD_INST_OPERATORS is not set."
  exit 1
fi

if [[ -z "$PROJECT_CPD_INST_OPERANDS" ]]; then
  log "ERROR: PROJECT_CPD_INST_OPERANDS is not set."
  exit 1
fi

# Operator patch label configuration
OPERATOR_PATCH_LABEL_KEY="${OPERATOR_PATCH_LABEL_KEY:-Hotfix}"
OPERATOR_PATCH_LABEL_VALUE="${OPERATOR_PATCH_LABEL_VALUE:-5.4.2-Hotfix1}"
WO_CR_NAME="wo"

# Make sure oc login is done
if ! oc whoami &>/dev/null; then
  log "ERROR: Not logged in to OpenShift. Please run 'oc login' first."
  exit 1
fi

log "✅ OpenShift login verified: $(oc whoami)"

# Backup dir for deployments
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="$(oc whoami --show-console | sed 's/.*console-openshift-console\.apps\.\([^.]*\)\..*/\1/')"
BACKUP_DIR="${SCRIPT_DIR}/wxo_deployment_backups/$CLUSTER_NAME"
mkdir -p "$BACKUP_DIR"

log "📁 Backup directory: $BACKUP_DIR"

# Check WXO version
log "🔍 Checking WXO version in namespace: $PROJECT_CPD_INST_OPERANDS"
WXO_VERSION=$(oc get wo -n "$PROJECT_CPD_INST_OPERANDS" -o jsonpath='{.items[0].status.versionStatus.status}' 2>/dev/null || echo "")
CRVERSION=$(oc get wo wo -n $PROJECT_CPD_INST_OPERANDS -o jsonpath='{.spec.version}')

if [[ -z "$WXO_VERSION" ]]; then
  log "ERROR: Unable to retrieve WXO version. Please ensure WatsonxOrchestrate resource exists."
  exit 1
fi

log "   Current WXO version: $WXO_VERSION"

if [[ "$WXO_VERSION" != "5.4.0" || "$CRVERSION" != "8.0.2" ]]; then
  log "ERROR: This operator patch can only be applied when:"
  log "       WXO version  : 5.4.0"
  log "       CR version   : 8.0.2"
  log ""
  log "Current versions:"
  log "       WXO version  : ${WXO_VERSION}"
  log "       CR version   : ${CRVERSION}"
  exit 1
fi

log "✅ Version check passed (8.0.2)"
log ""

# Hardcode images here when you do not want to pass them as script arguments.
BOOTSTRAP_OPERATOR_IMAGE="icr.io/cpopen/ibm-watsonx-orchestrate-operator@sha256:48d636029b579f41bc1baf4e5400bc585a1201a1a0f055cb1d6212b7cb75d2b9"
COMPONENT_OPERATOR_IMAGE="icr.io/cpopen/ibm-wxo-component-operator@sha256:2516e5b84db6cbca9357a268d454361fb6dac880d44c6bf8e2e6a634af1e6ade"

if [[ $# -gt 1 ]]; then
  log "Usage: $0 [image1,image2,...]"
  exit 1
fi

if [[ $# -eq 1 ]]; then
  IFS=',' read -ra IMAGES <<< "$1"
else
  IMAGES=()
  [[ -n "$BOOTSTRAP_OPERATOR_IMAGE" ]] && IMAGES+=("$BOOTSTRAP_OPERATOR_IMAGE")
  [[ -n "$COMPONENT_OPERATOR_IMAGE" ]] && IMAGES+=("$COMPONENT_OPERATOR_IMAGE")

  if [[ ${#IMAGES[@]} -eq 0 ]]; then
    log "Usage: $0 [image1,image2,...]"
    log "Either pass images as an argument or hardcode BOOTSTRAP_OPERATOR_IMAGE / COMPONENT_OPERATOR_IMAGE in the script."
    exit 1
  fi
fi

# Track patched deployments for health verification
PATCHED_DEPLOYMENTS=()

# -----------------------------
# Check and remove digest overrides from WO CR
# -----------------------------
log "🔍 Checking for digest overrides in WO CR..."
DIGEST_OVERRIDES=$(oc get wo "$WO_CR_NAME" -n "$PROJECT_CPD_INST_OPERANDS" \
  -o jsonpath='{.spec.image.digestOverrides}' 2>/dev/null || echo "")

if [[ -n "$DIGEST_OVERRIDES" && "$DIGEST_OVERRIDES" != "null" ]]; then
  log "⚠️  Digest overrides found in WO CR. Removing them before patching..."
  log "   Current digest overrides: $DIGEST_OVERRIDES"
  
  if oc patch wo "$WO_CR_NAME" -n "$PROJECT_CPD_INST_OPERANDS" --type=merge \
    -p='{"spec":{"image":{"digestOverrides":null}}}'; then
    log "✅ Successfully removed digest overrides from WO CR"
    
    # Wait a moment for the change to propagate
    sleep 2
  else
    log "✗ ERROR: Failed to remove digest overrides from WO CR"
    log "   Please remove them manually before proceeding"
    exit 1
  fi
else
  log "✅ No digest overrides found in WO CR"
fi

log ""

for IMAGE in "${IMAGES[@]}"; do
  IMAGE="$(echo "$IMAGE" | xargs)"

  # Extract image name - handle both tag (:) and digest (@) formats
  IMAGE_NAME="$(basename "$IMAGE" | cut -d'@' -f1 | cut -d':' -f1)"

  # Map image → deployment
  case "$IMAGE_NAME" in
    ibm-wxo-component-operator)
      DEPLOYMENT="ibm-wxo-componentcontroller-manager"
      ;;
    ibm-watsonx-orchestrate-operator)
      DEPLOYMENT="wo-operator"
      ;;
    *)
      log "⚠️  No deployment mapping found for image: $IMAGE_NAME"
      continue
      ;;
  esac

  log "🔍 Checking deployment '$DEPLOYMENT' for image '$IMAGE_NAME'..."

  # Backup deployment YAML before patching
  BACKUP_FILE="${BACKUP_DIR}/${DEPLOYMENT}-$(date +%Y%m%d%H%M%S).yaml"
  if oc -n "$PROJECT_CPD_INST_OPERATORS" get deploy "$DEPLOYMENT" -o yaml > "$BACKUP_FILE" 2>/dev/null; then
    log "   Backed up deployment/$DEPLOYMENT → $BACKUP_FILE"
  else
    log "   WARNING: Failed to back up deployment/$DEPLOYMENT"
  fi

  CURRENT_IMAGE="$(oc get deploy "$DEPLOYMENT" -n "$PROJECT_CPD_INST_OPERATORS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"

  if [[ "$CURRENT_IMAGE" != *"$IMAGE_NAME"* ]]; then
    log "⚠️  Image '$IMAGE_NAME' not found in deployment '$DEPLOYMENT'. Skipping."
    continue
  fi

  log "✅ Match found. Patching deployment '$DEPLOYMENT'"
  log "   Old: $CURRENT_IMAGE"
  log "   New: $IMAGE"

  if oc patch deploy "$DEPLOYMENT" -n "$PROJECT_CPD_INST_OPERATORS" \
    --type='json' \
    -p="[{
      \"op\": \"replace\",
      \"path\": \"/spec/template/spec/containers/0/image\",
      \"value\": \"$IMAGE\"
    }]"; then
    log "🚀 Successfully patched $DEPLOYMENT"
    PATCHED_DEPLOYMENTS+=("$DEPLOYMENT")
  else
    log "✗ ERROR: Failed to patch $DEPLOYMENT"
  fi
  log ""
done

# -----------------------------
# Label WO CR with operator patch label
# -----------------------------
if [[ -n "$WO_CR_NAME" ]]; then
  log "🏷️  Managing hotfix label on WO CR..."
  
  # Check if any hotfix label exists (case-insensitive check)
  EXISTING_HOTFIX_LABEL=$(oc -n "$PROJECT_CPD_INST_OPERANDS" get wo "$WO_CR_NAME" \
    -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -i '"hotfix"' || true)
  
  # Remove existing hotfix label if found
  if [[ -n "$EXISTING_HOTFIX_LABEL" ]]; then
    log "   Existing hotfix label found. Removing it..."
    # Remove both possible variations (uppercase and lowercase)
    oc -n "$PROJECT_CPD_INST_OPERANDS" label wo "$WO_CR_NAME" "Hotfix-" >/dev/null 2>&1 || true
    oc -n "$PROJECT_CPD_INST_OPERANDS" label wo "$WO_CR_NAME" "hotfix-" >/dev/null 2>&1 || true
    log "   ✅ Existing hotfix labels removed"
  fi
  
  # Apply new label
  log "   Setting label ${OPERATOR_PATCH_LABEL_KEY}=${OPERATOR_PATCH_LABEL_VALUE} on WO CR ${WO_CR_NAME}"
  if oc -n "$PROJECT_CPD_INST_OPERANDS" label wo "$WO_CR_NAME" \
    "${OPERATOR_PATCH_LABEL_KEY}=${OPERATOR_PATCH_LABEL_VALUE}" >/dev/null 2>&1; then
    
    NEW_LABEL="$(oc -n "$PROJECT_CPD_INST_OPERANDS" get wo "$WO_CR_NAME" \
      -o jsonpath="{.metadata.labels.${OPERATOR_PATCH_LABEL_KEY}}" 2>/dev/null || true)"
    
    if [[ "$NEW_LABEL" == "$OPERATOR_PATCH_LABEL_VALUE" ]]; then
      log "   ✅ Label set successfully: ${OPERATOR_PATCH_LABEL_KEY}=${OPERATOR_PATCH_LABEL_VALUE}"
    else
      log "   ⚠️  WARNING: Could not confirm label was set"
    fi
  else
    log "   ⚠️  WARNING: Failed to set label on WO CR"
  fi
else
  log "⚠️  No WO CR found, skipping label."
fi

log ""

# -----------------------------
# Verify patched deployments are healthy
# -----------------------------
if [[ ${#PATCHED_DEPLOYMENTS[@]} -gt 0 ]]; then
  log "🔍 Verifying rollout status for patched deployments..."
  
  for DEPLOYMENT in "${PATCHED_DEPLOYMENTS[@]}"; do
    log "   Checking deployment/$DEPLOYMENT..."
    
    # Wait for rollout to complete
    if oc -n "$PROJECT_CPD_INST_OPERATORS" rollout status deploy/"$DEPLOYMENT" --timeout=300s; then
      # Check Ready/Desired replica ratio
      RATIO="$(oc -n "$PROJECT_CPD_INST_OPERATORS" get deploy "$DEPLOYMENT" \
        -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo '0/0')"
      log "   Ready/Desired: $RATIO"
      
      if [[ "$RATIO" == "1/1" ]] || [[ "$RATIO" == "2/2" ]]; then
        log "   ✅ Deployment $DEPLOYMENT is healthy (pods up and running)"
      else
        log "   ⚠️  WARNING: Deployment $DEPLOYMENT is not at 1/1 or 2/2; current $RATIO"
      fi
    else
      log "   ✗ ERROR: Rollout status for deployment/$DEPLOYMENT did not complete successfully"
    fi
  done
else
  log "ℹ️  No deployments were patched; skipping health verification."
fi

# -----------------------------
# uiproxy certificate fix
# -----------------------------
if oc get certificate wo-uiproxy-tls-icert \
    -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    DNS_NAMES=$(oc get certificate wo-uiproxy-tls-icert \
        -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.spec.dnsNames[*]}' 2>/dev/null)
    if echo "${DNS_NAMES}" | tr ' ' '\n' | grep -q '^wo-uiproxy-'; then
        echo "Deleting wo-uiproxy-tls-icert due to an incorrect SAN entry. The operator will recreate it with the correct SAN."
        oc delete certificate wo-uiproxy-tls-icert \
            -n "${PROJECT_CPD_INST_OPERANDS}"
    fi
else
    echo "Certificate wo-uiproxy-tls-icert not found. Skipping SAN validation."
fi

# -----------------------------
# tenant migration jobs to run
# -----------------------------
if oc get job zen-addon-config-update-job -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    echo "Found zen-addon-config-update-job. Deleting it..."
    oc delete job zen-addon-config-update-job -n "${PROJECT_CPD_INST_OPERANDS}"
else
    echo "zen-addon-config-update-job not found. Nothing to delete."
fi
if oc get job wo-tenant-data-service-migration -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    echo "Found wo-tenant-data-service-migration. Deleting it..."
    oc delete job wo-tenant-data-service-migration -n "${PROJECT_CPD_INST_OPERANDS}"
else
    echo "wo-tenant-data-service-migration not found. Nothing to delete."
fi

# -----------------------------
# wo-watson-orchestrate-trm-secret fix
# -----------------------------
if oc get secret "wo-watson-orchestrate-trm-secret" -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    oc delete secret "wo-watson-orchestrate-trm-secret"
fi

# -----------------------------
# watson-gateway fix
# -----------------------------
GW_SHA="sha256:ed87dfc283fd1bf29a078e5c91b20e86abd1fcd73dca89629a34d9ba7d826441"
GW_TAG="2.4.0"

# Hardcode gateway image here
GATEWAY_OPERATOR_IMAGE="icr.io/cpopen/watson-gateway-operator@sha256:2faa51ae7c013a41db2dc09a9b971374e61b84f267cedd086243a912b93de435"

if oc get deploy -n "$PROJECT_CPD_INST_OPERATORS" -lcomponent-id=watson-gateway >/dev/null 2>&1; then

  GW_OPERATOR_DEPLOYMENT=$(oc get deploy -n "$PROJECT_CPD_INST_OPERATORS" -lcomponent-id=watson-gateway -o jsonpath='{.items[0].metadata.name}')
  log "✅ Deployment '${GW_OPERATOR_DEPLOYMENT}' found."

  # Backup deployment YAML before patching
  BACKUP_FILE="${BACKUP_DIR}/${GW_OPERATOR_DEPLOYMENT}-$(date +%Y%m%d%H%M%S).yaml"
  if oc -n "$PROJECT_CPD_INST_OPERATORS" get deploy "$GW_OPERATOR_DEPLOYMENT" -o yaml > "$BACKUP_FILE" 2>/dev/null; then
    log "   Backed up deployment/$DEPLOYMENT → $BACKUP_FILE"
  else
    log "   WARNING: Failed to back up deployment/$GW_OPERATOR_DEPLOYMENT"
  fi

  CURRENT_IMAGE="$(oc get deploy "$GW_OPERATOR_DEPLOYMENT" -n "$PROJECT_CPD_INST_OPERATORS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"

  log "✅ Match found. Patching deployment '$GW_OPERATOR_DEPLOYMENT'"
  log "   Old: $CURRENT_IMAGE"
  log "   New: $GATEWAY_OPERATOR_IMAGE"

  if oc patch deploy "$GW_OPERATOR_DEPLOYMENT" -n "$PROJECT_CPD_INST_OPERATORS" \
    --type='json' \
    -p="[{
      \"op\": \"replace\",
      \"path\": \"/spec/template/spec/containers/0/image\",
      \"value\": \"$GATEWAY_OPERATOR_IMAGE\"
    }]"; then
    log "🚀 Successfully patched $GW_OPERATOR_DEPLOYMENT"

    # Patch the olm-utils configmap
    BACKUP_FILE="${BACKUP_DIR}/olm-utils-cm-$(date +%Y%m%d%H%M%S).yaml"
    oc get cm olm-utils-cm -n ${PROJECT_CPD_INST_OPERANDS} -o yaml > "$BACKUP_FILE"
    oc get cm olm-utils-cm -n ${PROJECT_CPD_INST_OPERANDS} -o yaml | yq ".data.release_components_meta |= (fromyaml | .watson_gateway.cr_version = \"${GW_TAG}\" | to_yaml)" | oc apply -f -

  else
    log "✗ ERROR: Failed to patch $GW_OPERATOR_DEPLOYMENT"
  fi
  log ""

  # Wait for rollout to complete
  if oc -n "$PROJECT_CPD_INST_OPERATORS" rollout status deploy/"$GW_OPERATOR_DEPLOYMENT" --timeout=300s; then
    # Check Ready/Desired replica ratio
    RATIO="$(oc -n "$PROJECT_CPD_INST_OPERATORS" get deploy "$GW_OPERATOR_DEPLOYMENT" \
      -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo '0/0')"
    log "   Ready/Desired: $RATIO"
    
    if [[ "$RATIO" == "1/1" ]] || [[ "$RATIO" == "2/2" ]]; then
      log "   ✅ Deployment $GW_OPERATOR_DEPLOYMENT is healthy (pods up and running)"
    else
      log "   ⚠️  WARNING: Deployment $GW_OPERATOR_DEPLOYMENT is not at 1/1 or 2/2; current $RATIO"
    fi
  else
    log "   ✗ ERROR: Rollout status for deployment/$GW_OPERATOR_DEPLOYMENT did not complete successfully"
  fi

  GW_DEPLOYMENT=$(oc get deploy -n "$PROJECT_CPD_INST_OPERANDS" -lcomponent=watson-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -n "$GW_DEPLOYMENT" ]]; then
    log "✅ Deployment '${GW_DEPLOYMENT}' found. Restarting..."

    oc -n "$PROJECT_CPD_INST_OPERANDS" rollout restart deploy/"$GW_DEPLOYMENT"
    # Wait for rollout to complete
    if oc -n "$PROJECT_CPD_INST_OPERANDS" rollout status deploy/"$GW_DEPLOYMENT" --timeout=300s; then
      # Check Ready/Desired replica ratio
      RATIO="$(oc -n "$PROJECT_CPD_INST_OPERANDS" get deploy "$GW_DEPLOYMENT" \
        -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo '0/0')"
      log "   Ready/Desired: $RATIO"
      
      if [[ "$RATIO" == "1/1" ]] || [[ "$RATIO" == "2/2" ]]; then
        log "   ✅ Deployment $GW_DEPLOYMENT is healthy (pods up and running)"
      else
        log "   ⚠️  WARNING: Deployment $GW_DEPLOYMENT is not at 1/1 or 2/2; current $RATIO"
      fi
    else
      log "   ✗ ERROR: Rollout status for deployment/$GW_DEPLOYMENT did not complete successfully"
    fi
  fi
fi

# -----------------------------
# create wo-custom-certs when customer uses cpd's cert management
# -----------------------------
if oc get secret cpd-custom-ca-certs -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1 && \
   ! oc get secret wo-custom-certs -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    oc get secret cpd-custom-ca-certs \
      -n "${PROJECT_CPD_INST_OPERANDS}" \
      -o yaml | \
    sed \
      -e 's/name: cpd-custom-ca-certs/name: wo-custom-certs/' \
      -e '/creationTimestamp:/d' \
      -e '/resourceVersion:/d' \
      -e '/uid:/d' \
      -e '/managedFields:/d' | \
    oc apply -f -
fi

# -----------------------------
# Legacy Cleanup
# -----------------------------

# Delete a named resource only if it exists
del() {
  local kind="$1" name="$2" ns_flag="${3:-}"
  if oc get "$kind" "$name" ${ns_flag:+-n "$ns_flag"} >/dev/null 2>&1; then
    oc delete "$kind" "$name" ${ns_flag:+-n "$ns_flag"} --ignore-not-found
  fi
}

# Delete resources by label selector; skip silently if none found
del_by_label() {
  local kind="$1" label="$2" ns="$3"
  if oc get "$kind" -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -q .; then
    oc delete "$kind" -n "$ns" -l "$label" --ignore-not-found
  fi
}

# Scale a deployment to 0 only if it exists
scale_down() {
  local deploy="$1" ns="$2"
  if oc get deploy "$deploy" -n "$ns" >/dev/null 2>&1; then
    oc scale deploy "$deploy" -n "$ns" --replicas=0
  fi
}

log "Starting legacy cleanup..."

# ── UAB ────────────────────────────────────────────────────────────────────────────
log "Disabling UAB..."
oc patch wo wo -n "${PROJECT_CPD_INST_OPERANDS}" --type=merge \
  -p '{"spec":{"uab":{"enabled":false}}}' 2>/dev/null || true

log "Scaling down UAB operators..."
scale_down ba-saas-uab-wf-operator-controller-manager "${PROJECT_CPD_INST_OPERATORS}"
scale_down ibm-uab-ads-operator                       "${PROJECT_CPD_INST_OPERATORS}"
sleep 20

log "Cleaning UAB CRs and CRDs..."
del uabautomationdecisionservices wo "${PROJECT_CPD_INST_OPERANDS}"
del uabwfservices                 wo "${PROJECT_CPD_INST_OPERANDS}"
del crd uabautomationdecisionservices.uab.ba.ibm.com
del crd uabwfservices.uab.ba.ibm.com
del crd wfpsauthorings.saas.ba.ibm.com

log "Cleaning UAB WF operator resources..."
for kind in job deploy secret cm svc; do
  del_by_label "$kind" "app.kubernetes.io/managed-by=ibm-uab-wf-operator" "${PROJECT_CPD_INST_OPERANDS}"
done

log "Cleaning ADS resources..."
for kind in deploy secret cm job svc; do
  del_by_label "$kind" "app.kubernetes.io/component=ads" "${PROJECT_CPD_INST_OPERANDS}"
done

log "UAB cleanup completed."

# ── Digital Employee ────────────────────────────────────────────────────────────
log "Cleaning Digital Employee..."
if oc api-resources 2>/dev/null | grep -q "^digitalemployees"; then
  oc delete digitalemployees.wo.watsonx.ibm.com de -n "${PROJECT_CPD_INST_OPERANDS}" --ignore-not-found
fi

scale_down digital-employee-operator-controller-manager "${PROJECT_CPD_INST_OPERATORS}"
sleep 20

for kind in deploy secret cm job svc; do
  del_by_label "$kind" "wo.watsonx.ibm.com/component=digital-employee" "${PROJECT_CPD_INST_OPERANDS}"
done

log "Digital Employee cleanup completed."

# ── Kafka ─────────────────────────────────────────────────────────────────────────────
log "Cleaning Kafka..."
if oc get kafka wo-watson-orchestrate-kafkaibm -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
  log "Kafka CR wo-watson-orchestrate-kafkaibm found. Deleting it..."
  del kafka wo-watson-orchestrate-kafkaibm "${PROJECT_CPD_INST_OPERANDS}"
  sleep 10

  if oc get deploy wo-archer-server -n "${PROJECT_CPD_INST_OPERANDS}" >/dev/null 2>&1; then
    log "Deleting Archer deployment wo-archer-server..."
    oc delete deploy wo-archer-server -n "${PROJECT_CPD_INST_OPERANDS}" --ignore-not-found
  else
    log "Archer deployment wo-archer-server not found; skipping."
  fi
else
  log "Kafka CR wo-watson-orchestrate-kafkaibm not found; skipping Kafka and Archer cleanup."
fi
log "Kafka cleanup completed."


# -----------------------------
# Final message
# -----------------------------
log ""
log "------------------------------------------------------------------"
log "✅ Operator patch steps completed (${OPERATOR_PATCH_LABEL_VALUE})"
log ""
log "📁 Backups saved under: ${BACKUP_DIR}"
log ""
log "📊 Monitor the watsonx Orchestrate CR status by running:"
log "   oc get wo -n ${PROJECT_CPD_INST_OPERANDS} -o yaml | grep -E 'watsonxOrchestrateStatus|${OPERATOR_PATCH_LABEL_KEY}'"
log ""
log "✓ Ensure the watsonx Orchestrate CR status is 'Completed'"
log "✓ Ensure label ${OPERATOR_PATCH_LABEL_KEY}=${OPERATOR_PATCH_LABEL_VALUE} is present"
log ""
log "⏱️  It will take another 15–20 minutes for the updated components"
log "   to be applied and restarted."
log "------------------------------------------------------------------"
