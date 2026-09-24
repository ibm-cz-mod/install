#!/usr/bin/env bash
set -eo pipefail

# ============================================================
# 542 Hotfix1 Verification Script
# Checks operator and operand deployments for expected
# image SHAs for the 5.4.2-Hotfix1 fix.
# Runs in a loop until all are verified or timeout is reached.
# ============================================================

# ---- Colour helpers ----------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Use printf throughout — echo -e is not POSIX-portable (breaks under sh/dash)
log()  { printf "[%s] %s\n"                             "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()   { printf "${GREEN}${BOLD}[%s] OK  %s${RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf "${YELLOW}[%s] WARN %s${RESET}\n"       "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf "${RED}[%s] ERR  %s${RESET}\n"          "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
info() { printf "${CYAN}[%s] INFO %s${RESET}\n"         "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ---- Configuration -----------------------------------------
PROJECT_CPD_INST_OPERATORS="${PROJECT_CPD_INST_OPERATORS:-}"
PROJECT_CPD_INST_OPERANDS="${PROJECT_CPD_INST_OPERANDS:-}"

if [ -z "$PROJECT_CPD_INST_OPERATORS" ]; then
  err "PROJECT_CPD_INST_OPERATORS is not set."
  exit 1
fi

if [ -z "$PROJECT_CPD_INST_OPERANDS" ]; then
  err "PROJECT_CPD_INST_OPERANDS is not set."
  exit 1
fi

# Poll interval (seconds) and overall timeout
POLL_INTERVAL="${POLL_INTERVAL:-30}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"   # 60 minutes

# ============================================================
# OPERATOR deployments (live in PROJECT_CPD_INST_OPERATORS)
# Format: "deployment-name=sha256digest"  — one entry per line, order preserved.
# From the hotfix patch script:
#   BOOTSTRAP_OPERATOR_IMAGE  -> wo-operator
#   COMPONENT_OPERATOR_IMAGE  -> ibm-wxo-componentcontroller-manager
# ============================================================
OPERATOR_ENTRIES=(
  "wo-operator=48d636029b579f41bc1baf4e5400bc585a1201a1a0f055cb1d6212b7cb75d2b9"
  "ibm-wxo-componentcontroller-manager=2516e5b84db6cbca9357a268d454361fb6dac880d44c6bf8e2e6a634af1e6ade"
)

# ============================================================
# OPERAND deployments (live in PROJECT_CPD_INST_OPERANDS)
# Format: "deployment-name=sha256digest"  — one entry per line, order preserved.
# ============================================================
OPERAND_ENTRIES=(
  "wo-ai-gateway=e2311681dca9da15bf0766eb4786d04869d08b24f7d7c998223f469dce5f5c3c"
  "wo-wxo-connections=04d1adea76a20e4aff886a227cbbc62110b0bdeb29ec82a1c82481fea65fcdc6"
  "wo-tenant-data-service=8f00aa42676b6f9cb76e1b49b3fd0df08971189c3a3eb95d91ffb5d090d32b08"
  "wo-channel-integrations=ffb193e1bc39d6400006220f299b729157b5a9205932b0feefa4a5e8f0780732"
  "wo-conversation-controller=34f68c8dbbb4792fff6171219573f755475117996a59ee03fc3a9ca7f837034c"
  "wo-skill-server=1f86f27749d8df98c40debcf5ec8b2e4953aa653c563696a5b7b2aa8743fb20b"
  "wo-ccaas-chat-connector=e52a2d1dc3ea1bad2167d5a3d79e9a7d91dc1686178d4cfc7cc4656b826fd32d"
  "wo-agentic-task-manager=2a1b47bc8d2c01e6ffe128627c0194ec4e00f35ec820292923c571116c72fee9"
  "wo-builder-ui=d2589f5b82198922fef13227ed6dbee048e0495dea63fbedc3b52a8ce51c9c87"
  "wo-wxo-connections-ui=ea536612ca93c32302d95c1cb89bce6af318267bbcec441f0bcf412f06c0393b"
  "wo-archer-server=798e25cd24ae0e3c9a06745870f3c580161b19e575d2dc7224d10b46f3e4278d"
  "wo-voice-controller=71739e526c17aa290fdcf5cf968a68e00462671fae6a20943767eebf95004bfe"
  "wo-socket-handler=6d296d32c2233e11bcfba17284af7a1acf04b716ce9f76a96d681372e2f8bd3b"
  "wo-tools-runtime-scheduler=49689057ca6c73e4b288c40213cc6a4523e2d985809d050c4e6cbf4016676036"
  "wo-tools-runtime-manager=928b77bf61156daa30d580d88c69f799d3a899e4b81605838e6b62b673d4f13f"
  "wo-wxo-knowledge=3919fd5b613db6121a9caee168515da09c1618fc4157135b2322de2b52169778"
  "wo-agentic-memory=694839c6c408a8c8bcaecbda4c50eeb09a2d66c357ac6639bf41a5bc62b76080"
  "wo-agent-gateway=758bd2348cb907f50e95b96ce5dd9abe27523d3bae7122db1f48cd8202a7f18a"
  "wo-uiproxy=65632b0b9f1c2022d025a5da30630f961de909f95a56d1c4c21c5ba77ccd3cb3"
)

# ============================================================
# OPERAND jobs (live in PROJECT_CPD_INST_OPERANDS)
# Format: "job-name=sha256digest"  — one entry per line, order preserved.
# Checks: image SHA matches AND job status.succeeded >= 1.
# ============================================================
JOB_ENTRIES=(
  "zen-addon-config-update-job=b99f2ce6e0deb1ad64e14b0858c27945691402d725559997022cf74b01d6e717"
  "wo-tenant-data-service-migration=b99f2ce6e0deb1ad64e14b0858c27945691402d725559997022cf74b01d6e717"
)

# ---- Helpers: extract name / sha from an "name=sha" entry --
entry_name() { echo "${1%%=*}"; }
entry_sha()  { echo "${1#*=}";  }

# ---- Pre-flight checks -------------------------------------
WO_CR_NAME="${WO_CR_NAME:-wo}"   # override if CR name differs: export WO_CR_NAME=mywo
EXPECTED_CR_VERSION="8.0.2"
EXPECTED_LABEL_KEY="Hotfix"
EXPECTED_LABEL_VALUE="5.4.2-Hotfix1"

if ! oc whoami &>/dev/null; then
  err "Not logged in to OpenShift. Please run 'oc login' first."
  exit 1
fi
ok "OpenShift login verified: $(oc whoami)"
log "Operators namespace : $PROJECT_CPD_INST_OPERATORS"
log "Operands namespace  : $PROJECT_CPD_INST_OPERANDS"
log "WO CR name          : $WO_CR_NAME"
log "Timeout             : ${TIMEOUT_SECONDS}s ($(( TIMEOUT_SECONDS / 60 )) minutes)"
log "Poll every          : ${POLL_INTERVAL}s"
printf "\n"

# Verify WO CR exists
log "Checking WO CR '${WO_CR_NAME}' in namespace: $PROJECT_CPD_INST_OPERANDS"
if ! oc -n "$PROJECT_CPD_INST_OPERANDS" get wo "$WO_CR_NAME" &>/dev/null; then
  err "WO CR '${WO_CR_NAME}' not found in namespace '$PROJECT_CPD_INST_OPERANDS'."
  err "Set WO_CR_NAME env var if your CR has a different name."
  exit 1
fi

# Verify spec.version == 8.0.2
CR_VERSION=$(oc -n "$PROJECT_CPD_INST_OPERANDS" get wo "$WO_CR_NAME" \
  -o jsonpath='{.spec.version}' 2>/dev/null || true)
if [ "$CR_VERSION" != "$EXPECTED_CR_VERSION" ]; then
  err "WO CR '${WO_CR_NAME}' spec.version is '${CR_VERSION:-<empty>}', expected '${EXPECTED_CR_VERSION}'."
  err "This script is only valid for 5.4.2-Hotfix1 (CR version ${EXPECTED_CR_VERSION})."
  exit 1
fi
ok "WO CR spec.version: ${CR_VERSION}"

# Verify Hotfix label == 5.4.2-Hotfix1
CR_LABEL=$(oc -n "$PROJECT_CPD_INST_OPERANDS" get wo "$WO_CR_NAME" \
  -o jsonpath="{.metadata.labels.${EXPECTED_LABEL_KEY}}" 2>/dev/null || true)
if [ "$CR_LABEL" != "$EXPECTED_LABEL_VALUE" ]; then
  err "WO CR label '${EXPECTED_LABEL_KEY}' is '${CR_LABEL:-<not set>}', expected '${EXPECTED_LABEL_VALUE}'."
  err "Run the hotfix patch script first before running this verify script."
  exit 1
fi
ok "WO CR label: ${EXPECTED_LABEL_KEY}=${CR_LABEL}"
printf "\n"

# Returns sha256 digest from deployment spec image (same as oc get deploy -o yaml).
# Staging/mirrored registries remap digests at pull time, so pod imageID is unreliable.
# Falls back to pod imageID only when spec image is a tag (not a digest ref).
get_running_sha() {
  local deploy="$1"
  local ns="$2"

  # Primary: spec image digest (authoritative — matches oc get deploy output)
  local spec_image=""
  spec_image=$(oc -n "$ns" get deploy "$deploy" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' \
      2>/dev/null || true)
  if [ "${spec_image#*@sha256:}" != "$spec_image" ]; then
    echo "${spec_image##*@sha256:}"
    return
  fi

  # Fallback: pod imageID (only when spec uses a tag, not a digest)
  local pod="" image_id=""
  pod=$(oc -n "$ns" get pods \
          --field-selector=status.phase=Running \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
          2>/dev/null \
        | grep "^${deploy}-" | head -1 || true)
  [ -z "$pod" ] && pod=$(oc -n "$ns" get pods -l "app=${deploy}" \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod" ]; then
    image_id=$(oc -n "$ns" get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)
    [ -n "$image_id" ] && echo "${image_id##*@sha256:}" && return
  fi

  echo ""
}

# ---- Helper: pod running status for a deployment -----------
# Returns "Running (N/N)" if all desired pods are ready,
# "Not Running (R/N)" otherwise. Empty if deploy is missing.
get_pod_status() {
  local deploy="$1"
  local ns="$2"

  local desired ready
  desired=$(oc -n "$ns" get deploy "$deploy" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  ready=$(oc -n "$ns" get deploy "$deploy" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  desired="${desired:-0}"
  ready="${ready:-0}"

  if (( desired > 0 && ready == desired )); then
    echo "Running (${ready}/${desired})"
  else
    echo "Not Running (${ready}/${desired})"
  fi
}

# ---- Helper: print one status row --------------------------
# $1 deploy/job name
# $2 SHA status   (VERIFIED | NOT UPDATED | MISSING | NOT COMPLETE)
# $3 current sha
# $4 expected sha
# $5 pod/job status string  (e.g. "Running (2/2)" | "Not Running (0/2)" | "Succeeded" | "")
print_row() {
  local deploy="$1"
  local status="$2"
  local current="$3"
  local expected="$4"
  local extra_status="$5"

  local color
  case "$status" in
    VERIFIED)                color="$GREEN"  ;;
    "NOT UPDATED" | MISSING) color="$RED"    ;;
    *)                       color="$YELLOW" ;;
  esac

  local extra_color
  case "$extra_status" in
    Running*|Succeeded*)  extra_color="$GREEN"  ;;
    Not\ Running*|Failed*) extra_color="$RED"   ;;
    *)                    extra_color="$YELLOW" ;;
  esac

  local got_display=""
  [ -n "$current" ] && got_display="${current:0:16}..."

  printf "  %-44s ${color}%-14s${RESET}  ${extra_color}%-22s${RESET}  expected: %.16s...  got: %s\n" \
    "$deploy" "$status" "${extra_status:--}" "$expected" "$got_display"
}

# ---- Helper: check one group of deployments ----------------
# Usage: check_group <namespace> <entries_array_ref>
# Sets globals: _GROUP_VERIFIED  _GROUP_PENDING  _GROUP_MISSING
check_group() {
  local ns="$1"
  local entries_ref="$2"   # name of the *_ENTRIES array

  _GROUP_VERIFIED=0
  _GROUP_PENDING=0
  _GROUP_MISSING=0

  local entry deploy expected current pod_status
  eval "local -a _entries=(\"\${${entries_ref}[@]}\")"
  for entry in "${_entries[@]}"; do
    deploy=$(entry_name "$entry")
    expected=$(entry_sha  "$entry")

    if ! oc -n "$ns" get deploy "$deploy" &>/dev/null; then
      print_row "$deploy" "MISSING" "" "$expected" ""
      _GROUP_MISSING=$(( _GROUP_MISSING + 1 ))
      continue
    fi

    current=$(get_running_sha "$deploy" "$ns")
    pod_status=$(get_pod_status "$deploy" "$ns")

    if [ "$current" = "$expected" ]; then
      print_row "$deploy" "VERIFIED" "$current" "$expected" "$pod_status"
      _GROUP_VERIFIED=$(( _GROUP_VERIFIED + 1 ))
    else
      print_row "$deploy" "NOT UPDATED" "$current" "$expected" "$pod_status"
      _GROUP_PENDING=$(( _GROUP_PENDING + 1 ))
    fi
  done
}

# ---- Helper: check one group of jobs -----------------------
# Jobs are verified on two criteria:
#   1. spec image SHA matches expected
#   2. status.succeeded >= 1 (job completed successfully)
# Sets globals: _GROUP_VERIFIED  _GROUP_PENDING  _GROUP_MISSING
check_jobs() {
  local ns="$1"
  local entries_ref="$2"   # name of the *_ENTRIES array

  _GROUP_VERIFIED=0
  _GROUP_PENDING=0
  _GROUP_MISSING=0

  local entry job expected spec_image current_sha succeeded failed active job_status
  eval "local -a _entries=(\"\${${entries_ref}[@]}\")"
  for entry in "${_entries[@]}"; do
    job=$(entry_name "$entry")
    expected=$(entry_sha  "$entry")

    if ! oc -n "$ns" get job "$job" &>/dev/null; then
      print_row "$job" "MISSING" "" "$expected" ""
      _GROUP_MISSING=$(( _GROUP_MISSING + 1 ))
      continue
    fi

    spec_image=$(oc -n "$ns" get job "$job" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' \
        2>/dev/null || true)
    current_sha="${spec_image##*@sha256:}"
    # If spec image has no digest, treat sha as empty
    [ "$spec_image" = "$current_sha" ] && current_sha=""

    succeeded=$(oc -n "$ns" get job "$job" \
        -o jsonpath='{.status.succeeded}' \
        2>/dev/null || true)
    failed=$(oc -n "$ns" get job "$job" \
        -o jsonpath='{.status.failed}' \
        2>/dev/null || true)
    active=$(oc -n "$ns" get job "$job" \
        -o jsonpath='{.status.active}' \
        2>/dev/null || true)
    succeeded="${succeeded:-0}"
    failed="${failed:-0}"
    active="${active:-0}"

    # Derive a human-readable job status
    if   (( succeeded >= 1 )); then job_status="Succeeded"
    elif (( active    >= 1 )); then job_status="Running (${active} active)"
    elif (( failed    >= 1 )); then job_status="Failed (${failed})"
    else                            job_status="Pending"
    fi

    if [ "$current_sha" = "$expected" ] && (( succeeded >= 1 )); then
      print_row "$job" "VERIFIED" "$current_sha" "$expected" "$job_status"
      _GROUP_VERIFIED=$(( _GROUP_VERIFIED + 1 ))
    else
      print_row "$job" "NOT COMPLETE" "$current_sha" "$expected" "$job_status"
      _GROUP_PENDING=$(( _GROUP_PENDING + 1 ))
    fi
  done
}

# ---- Main verification loop --------------------------------
START_TS=$(date +%s)
ITERATION=0

_GROUP_VERIFIED=0
_GROUP_PENDING=0
_GROUP_MISSING=0

while true; do
  ITERATION=$(( ITERATION + 1 ))
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TS ))

  if (( ELAPSED >= TIMEOUT_SECONDS )); then
    printf "\n"
    err "Timeout of ${TIMEOUT_SECONDS}s reached after ${ELAPSED}s."
    err "Deployments that did NOT reach the expected SHA:"

    printf "  ${BOLD}Operators (${PROJECT_CPD_INST_OPERATORS}):${RESET}\n"
    for entry in "${OPERATOR_ENTRIES[@]}"; do
      d=$(entry_name "$entry")
      _exp=$(entry_sha "$entry")
      _sha=$(get_running_sha "$d" "$PROJECT_CPD_INST_OPERATORS")
      [ "$_sha" != "$_exp" ] && printf "    ${RED}%s${RESET}\n" "$d"
    done

    printf "  ${BOLD}Operands (${PROJECT_CPD_INST_OPERANDS}):${RESET}\n"
    for entry in "${OPERAND_ENTRIES[@]}"; do
      d=$(entry_name "$entry")
      _exp=$(entry_sha "$entry")
      _sha=$(get_running_sha "$d" "$PROJECT_CPD_INST_OPERANDS")
      [ "$_sha" != "$_exp" ] && printf "    ${RED}%s${RESET}\n" "$d"
    done

    printf "  ${BOLD}Jobs (${PROJECT_CPD_INST_OPERANDS}):${RESET}\n"
    for entry in "${JOB_ENTRIES[@]}"; do
      d=$(entry_name "$entry")
      _exp=$(entry_sha "$entry")
      _spec=$(oc -n "$PROJECT_CPD_INST_OPERANDS" get job "$d" \
          -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
      _sha="${_spec##*@sha256:}"; [ "$_spec" = "$_sha" ] && _sha=""
      _succ=$(oc -n "$PROJECT_CPD_INST_OPERANDS" get job "$d" \
          -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
      { [ "$_sha" != "$_exp" ] || (( ${_succ:-0} < 1 )); } && printf "    ${RED}%s${RESET}\n" "$d"
    done
    exit 1
  fi

  REMAINING=$(( TIMEOUT_SECONDS - ELAPSED ))
  TOTAL_DEPLOYMENTS=$(( ${#OPERATOR_ENTRIES[@]} + ${#OPERAND_ENTRIES[@]} + ${#JOB_ENTRIES[@]} ))

  printf "\n"
  printf "${BOLD}================================================================${RESET}\n"
  printf "${BOLD} 5.4.2-Hotfix1 Verification -- iteration #%s${RESET}\n" "$ITERATION"
  printf "${BOLD} Elapsed : %ss  |  Remaining: %ss${RESET}\n"            "$ELAPSED" "$REMAINING"
  printf "${BOLD}================================================================${RESET}\n"

  # ---- OPERATORS section ------------------------------------
  printf "\n"
  printf "${BOLD}${CYAN}  [OPERATORS]  namespace: %s${RESET}\n" "$PROJECT_CPD_INST_OPERATORS"
  printf "${BOLD}${CYAN}  %-44s %-14s  %-22s  %s${RESET}\n" "Deployment" "SHA STATUS" "POD STATUS" "SHA (first 16 chars)"
  printf "  %s\n" "---------------------------------------------------------------------------------------------"

  check_group "$PROJECT_CPD_INST_OPERATORS" OPERATOR_ENTRIES
  OP_VERIFIED=$_GROUP_VERIFIED
  OP_PENDING=$_GROUP_PENDING
  OP_MISSING=$_GROUP_MISSING
  OP_TOTAL="${#OPERATOR_ENTRIES[@]}"

  printf "\n"
  printf "  Operators summary -> ${GREEN}Verified: %s${RESET}  |  ${RED}Pending: %s${RESET}  |  ${YELLOW}Missing: %s${RESET}  |  Total: %s\n" \
    "$OP_VERIFIED" "$OP_PENDING" "$OP_MISSING" "$OP_TOTAL"

  # ---- OPERANDS section -------------------------------------
  printf "\n"
  printf "${BOLD}${CYAN}  [OPERANDS]   namespace: %s${RESET}\n" "$PROJECT_CPD_INST_OPERANDS"
  printf "${BOLD}${CYAN}  %-44s %-14s  %-22s  %s${RESET}\n" "Deployment" "SHA STATUS" "POD STATUS" "SHA (first 16 chars)"
  printf "  %s\n" "---------------------------------------------------------------------------------------------"

  check_group "$PROJECT_CPD_INST_OPERANDS" OPERAND_ENTRIES
  OD_VERIFIED=$_GROUP_VERIFIED
  OD_PENDING=$_GROUP_PENDING
  OD_MISSING=$_GROUP_MISSING
  OD_TOTAL="${#OPERAND_ENTRIES[@]}"

  printf "\n"
  printf "  Operands summary  -> ${GREEN}Verified: %s${RESET}  |  ${RED}Pending: %s${RESET}  |  ${YELLOW}Missing: %s${RESET}  |  Total: %s\n" \
    "$OD_VERIFIED" "$OD_PENDING" "$OD_MISSING" "$OD_TOTAL"

  # ---- JOBS section -----------------------------------------
  printf "\n"
  printf "${BOLD}${CYAN}  [JOBS]       namespace: %s${RESET}\n" "$PROJECT_CPD_INST_OPERANDS"
  printf "${BOLD}${CYAN}  %-44s %-14s  %-22s  %s${RESET}\n" "Job" "SHA STATUS" "JOB STATUS" "SHA (first 16 chars)"
  printf "  %s\n" "---------------------------------------------------------------------------------------------"

  check_jobs "$PROJECT_CPD_INST_OPERANDS" JOB_ENTRIES
  JB_VERIFIED=$_GROUP_VERIFIED
  JB_PENDING=$_GROUP_PENDING
  JB_MISSING=$_GROUP_MISSING
  JB_TOTAL="${#JOB_ENTRIES[@]}"

  printf "\n"
  printf "  Jobs summary      -> ${GREEN}Verified: %s${RESET}  |  ${RED}Pending: %s${RESET}  |  ${YELLOW}Missing: %s${RESET}  |  Total: %s\n" \
    "$JB_VERIFIED" "$JB_PENDING" "$JB_MISSING" "$JB_TOTAL"

  # ---- Overall summary --------------------------------------
  TOTAL_VERIFIED=$(( OP_VERIFIED + OD_VERIFIED + JB_VERIFIED ))
  TOTAL_PENDING=$(( OP_PENDING + OD_PENDING + JB_PENDING ))
  TOTAL_MISSING=$(( OP_MISSING + OD_MISSING + JB_MISSING ))

  printf "\n"
  printf "${BOLD}----------------------------------------------------------------${RESET}\n"
  printf "${BOLD}  OVERALL  -> ${GREEN}Verified: %s${RESET}${BOLD}  |  ${RED}Pending: %s${RESET}${BOLD}  |  ${YELLOW}Missing: %s${RESET}${BOLD}  |  Total: %s${RESET}\n" \
    "$TOTAL_VERIFIED" "$TOTAL_PENDING" "$TOTAL_MISSING" "$TOTAL_DEPLOYMENTS"
  printf "${BOLD}----------------------------------------------------------------${RESET}\n"

  if (( TOTAL_PENDING == 0 && TOTAL_MISSING == 0 )); then
    ELAPSED=$(( $(date +%s) - START_TS ))
    printf "\n"
    ok "All ${TOTAL_DEPLOYMENTS} deployments updated to expected Hotfix1 SHA values."
    printf "\n"
    printf "${BOLD}================================================================${RESET}\n"
    printf "${GREEN}${BOLD}[%s] 5.4.2-Hotfix1 verification PASSED (completed in %ss)${RESET}\n" \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$ELAPSED"
    printf "${BOLD}================================================================${RESET}\n"
    exit 0
  fi

  if (( TOTAL_MISSING > 0 )); then
    warn "${TOTAL_MISSING} deployment(s) not found. They may still be deploying."
  fi

  info "Next check in ${POLL_INTERVAL}s -- press Ctrl+C to abort."
  sleep "$POLL_INTERVAL"
done

 
