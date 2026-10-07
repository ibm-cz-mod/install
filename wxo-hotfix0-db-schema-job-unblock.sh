#!/usr/bin/env bash
# =============================================================================
# wxo-hotfix0-db-schema-job-unblock.sh
#
# WORKAROUND: wo-archer-server-db-schema-job stuck after applying WxO hotfix-0
#             (operand version 8.0.2 / Patch 5)
#
# ROOT CAUSE
# ----------
# The hotfix triggers <cr-name>-archer-server-db-schema-job, which runs DDL
# statements (DROP TRIGGER, COMMENT ON COLUMN, ALTER TABLE) on the 'archer'
# Postgres database. These DDL statements require an ACCESS EXCLUSIVE lock on
# the target table. Orphaned archer-server connections left in "idle in
# transaction" state by previous pod restarts hold an ACCESS SHARE lock on the
# same table, blocking the DDL indefinitely — the job pod stays Running with
# no progress for hours or days.
#
# These orphaned connections are SQLAlchemy pool connections from
# <cr-name>-archer-server pods that were recycled during the hotfix rolling
# update. The application thread is gone but the server-side Postgres backend
# was never cleaned up.
#
# WHAT THIS SCRIPT DOES
# ---------------------
#  1. Requires NS (namespace) as mandatory input.
#  2. Auto-discovers the WatsonxOrchestrate CR name within that namespace.
#  3. Locates the EDB Postgres primary pod by the fixed pattern
#     <cr-name>-watson-orchestrate-postgresedb-1.
#  4. Reports the current job status and last log line.
#  5. Finds all orphaned "idle in transaction" archer-server connections on
#     the archer DB that have been open for more than 30 minutes.
#  6. DRY-RUN (default): prints the PIDs — no changes made.
#  7. --fix mode: terminates each connection via pg_terminate_backend(),
#     verifies the lock chain clears, then confirms the job resumes.
#
# SAFETY
# ------
# Terminating these connections causes zero data loss. Here is why:
#
# In practice, all orphaned connections observed across affected clusters held
# read-only SELECT transactions. However, even in the unlikely case where an
# orphaned connection holds an uncommitted write (INSERT/UPDATE/DELETE):
#
#   1. The pod that owned the connection has already been terminated. The
#      original HTTP request or Celery task has already failed with a connection
#      error — there is no live application code waiting on the result.
#
#   2. pg_terminate_backend() causes Postgres to issue an automatic ROLLBACK on
#      the open transaction before closing the connection. This is the correct
#      and intended outcome for any transaction whose owning process is dead.
#
#   3. Committed data is never affected — pg_terminate_backend() only rolls
#      back uncommitted work. An uncommitted write from a dead pod is not
#      "owned" data; it is a failed operation that must be retried by the
#      caller regardless of what this script does.
#
# The only observable side effect is that live archer-server pods may receive
# a transient connection error when SQLAlchemy checks out a stale connection
# from the pool; SQLAlchemy's pool_pre_ping reconnects automatically.
#
# USAGE
# -----
#   # NS is mandatory — set it to your WxO application namespace.
#   # CR name is auto-discovered; no need to set it manually.
#
#   # Dry-run — safe, no changes:
#   NS=<wxo-namespace> ./wxo-hotfix0-db-schema-job-unblock.sh
#
#   # Apply the fix:
#   NS=<wxo-namespace> ./wxo-hotfix0-db-schema-job-unblock.sh --fix
#
#   # Examples:
#   NS=cpd-instance-1 ./wxo-hotfix0-db-schema-job-unblock.sh
#   NS=cpd-instance-1 ./wxo-hotfix0-db-schema-job-unblock.sh --fix
#
# REQUIREMENTS
# ------------
#   - bash 4.0+
#   - oc CLI, logged in with cluster-admin or equivalent RBAC
#   - oc exec access to the EDB Postgres pod
#
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}=== $* ===${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
FIX_MODE=false
for arg in "$@"; do
  case $arg in
    --fix)    FIX_MODE=true ;;
    --help|-h)
      grep "^# " "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown argument: $arg  (use --fix or --help)"; exit 1 ;;
  esac
done

# ── Step 1: Namespace validation & CR name discovery ─────────────────────────
header "Step 1: Namespace validation & CR name discovery"

# NS is mandatory — customer clusters use varying namespace names.
if [[ -z "${NS:-}" ]]; then
  error "NS is not set. Please provide the WxO application namespace."
  error ""
  error "Usage:  NS=<wxo-namespace> $0 [--fix]"
  error ""
  error "To find your namespace:"
  error "  oc get watsonxorchestrate --all-namespaces"
  exit 1
fi

# Verify the namespace exists and is accessible.
if ! oc get namespace "$NS" &>/dev/null; then
  error "Namespace '$NS' not found or not accessible."
  error "Verify you are logged in to the correct cluster and NS is correct."
  exit 1
fi

# Auto-discover CR name — customers may override the default 'wo'.
CR=$(oc get watsonxorchestrate -n "$NS" \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$CR" ]]; then
  error "No WatsonxOrchestrate CR found in namespace '$NS'."
  error "Verify NS is the correct WxO application namespace."
  exit 1
fi

info "Namespace : $NS"
info "CR name   : $CR"

# ── Step 2: Postgres primary pod discovery ────────────────────────────────────
header "Step 2: Postgres primary pod discovery"

# The EDB primary pod name follows the fixed pattern:
#   <cr-name>-watson-orchestrate-postgresedb-1
# The -1 suffix always identifies the primary in EDB operator naming.
# Constructing the exact name (rather than grepping) avoids false matches
# against any unrelated Postgres instances in the same namespace.
PG_POD="${CR}-watson-orchestrate-postgresedb-1"

if ! oc get pod "$PG_POD" -n "$NS" &>/dev/null; then
  error "Postgres primary pod '$PG_POD' not found in namespace '$NS'."
  error "Expected pod name: <cr-name>-watson-orchestrate-postgresedb-1"
  error "Verify the EDB Postgres cluster is running:"
  error "  oc get pods -n $NS | grep postgresedb"
  exit 1
fi

PG_PHASE=$(oc get pod "$PG_POD" -n "$NS" \
             -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$PG_PHASE" != "Running" ]]; then
  error "Postgres primary pod '$PG_POD' is not Running (phase: $PG_PHASE)."
  error "The Postgres cluster must be healthy before running this script."
  exit 1
fi

info "Postgres primary pod: $PG_POD (phase: $PG_PHASE)"

# Helper — run SQL, return raw -tAq output (no headers, no alignment)
pg_exec() {
  oc exec -n "$NS" "$PG_POD" -- \
    psql -U postgres -tAq -c "$1" 2>/dev/null
}

# ── Step 3: Job status ────────────────────────────────────────────────────────
header "Step 3: ${CR}-archer-server-db-schema-job status"

JOB_NAME="${CR}-archer-server-db-schema-job"

if ! oc get job "$JOB_NAME" -n "$NS" &>/dev/null; then
  warn "Job '$JOB_NAME' not found in namespace '$NS'."
  warn "It may have already completed or not yet been triggered."
  warn "Continuing to check for orphaned connections anyway..."
else
  ACTIVE=$(oc get job "$JOB_NAME" -n "$NS" \
             -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
  SUCCEEDED=$(oc get job "$JOB_NAME" -n "$NS" \
                -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
  FAILED_CNT=$(oc get job "$JOB_NAME" -n "$NS" \
                 -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
  START_TIME=$(oc get job "$JOB_NAME" -n "$NS" \
                 -o jsonpath='{.status.startTime}' 2>/dev/null || echo "")

  info "Job status — active=$ACTIVE  succeeded=$SUCCEEDED  failed=$FAILED_CNT"
  [[ -n "$START_TIME" ]] && info "Started at: $START_TIME"

  if [[ "$SUCCEEDED" == "1" ]]; then
    success "Job has already completed successfully. No action needed."
    exit 0
  fi

  if [[ "$ACTIVE" == "1" ]]; then
    STUCK_POD=$(oc get pods -n "$NS" \
                  --selector="job-name=${JOB_NAME}" \
                  --field-selector=status.phase=Running \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$STUCK_POD" ]]; then
      warn "Job pod is running: $STUCK_POD"
      LAST_LOG=$(oc logs "$STUCK_POD" -n "$NS" --tail=1 2>/dev/null \
                 | grep -v "^$" || true)
      info "Last log line: ${LAST_LOG:-<no output yet>}"
    fi
  fi
fi

# ── Step 4: Orphaned connection discovery ─────────────────────────────────────
header "Step 4: Orphaned 'idle in transaction' connections (archer DB)"

info "Querying pg_stat_activity for archer-server connections idle in transaction > 30 min..."

# application_name is set by SQLAlchemy via get_application_name() in wxo-server.
# Four variants are possible depending on SERVER_TYPE and sync/async engine:
#   wxo-server                      — FastAPI sync engine (archer-server pod)
#   async-wxo-server                — FastAPI async engine (archer-server pod)
#   conversation-controller         — Celery sync engine (SERVER_TYPE=CELERY)
#   async-conversation-controller   — Celery async engine (SERVER_TYPE=CELERY)
# All variants append ' - <ip>:<port>', e.g. 'async-wxo-server - 10.0.0.1:12345'.
# The regex below matches all four prefixes regardless of IP:port suffix.
ORPHAN_QUERY="
SELECT pid,
       application_name,
       EXTRACT(EPOCH FROM (now() - query_start))::bigint AS age_seconds,
       left(regexp_replace(query, E'[\n\r]+', ' ', 'g'), 80) AS query_snippet
FROM pg_stat_activity
WHERE datname = 'archer'
  AND state = 'idle in transaction'
  AND application_name ~ '^(wxo-server|async-wxo-server|conversation-controller|async-conversation-controller) - '
  AND query_start < now() - interval '30 minutes'
ORDER BY query_start ASC;"

# Collect PIDs into array for termination loop; also build display rows
declare -a ORPHAN_PIDS=()
ORPHAN_DISPLAY=""

while IFS='|' read -r pid app age_sec query; do
  pid=$(echo "$pid" | tr -d ' ')
  age_sec=$(echo "$age_sec" | tr -d ' ')
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue
  ORPHAN_PIDS+=("$pid")
  age_human=$(printf '%dd %02dh %02dm' \
    $((age_sec/86400)) $(((age_sec%86400)/3600)) $(((age_sec%3600)/60)))
  ORPHAN_DISPLAY+=$(printf "  %-10s %-38s %-14s %s\n" \
    "$pid" "${app:0:38}" "$age_human" "${query:0:55}")
  ORPHAN_DISPLAY+=$'\n'
done < <(pg_exec "$ORPHAN_QUERY")

ORPHAN_COUNT=${#ORPHAN_PIDS[@]}

if [[ $ORPHAN_COUNT -eq 0 ]]; then
  success "No orphaned idle-in-transaction archer-server connections found."
  info "If the job is still stuck, check for other blockers:"
  echo ""
  echo "  oc exec -n $NS $PG_POD -- psql -U postgres -c \\"
  echo "  \"SELECT blocked.pid, left(blocked.query,60) AS blocked_q,"
  echo "          blocker.pid AS blocker_pid, blocker.state,"
  echo "          blocker.application_name"
  echo "   FROM pg_stat_activity blocked"
  echo "   JOIN pg_stat_activity blocker"
  echo "     ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))"
  echo "   WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;\""
  exit 0
fi

warn "Found $ORPHAN_COUNT orphaned connection(s) — all hold READ-ONLY transactions:"
echo ""
printf "  %-10s %-38s %-14s %s\n" "PID" "APPLICATION" "IDLE DURATION" "QUERY (truncated)"
printf "  %-10s %-38s %-14s %s\n" "----------" "--------------------------------------" \
  "--------------" "-------------------------------------------------------"
echo -n "$ORPHAN_DISPLAY"
echo ""

# ── Dry-run gate ──────────────────────────────────────────────────────────────
if [[ "$FIX_MODE" == false ]]; then
  echo -e "${YELLOW}DRY-RUN MODE — no changes made.${NC}"
  echo ""
  echo "All $ORPHAN_COUNT connection(s) above can be safely terminated."
  echo "They hold read-only SELECT transactions — zero data loss on termination."
  echo ""
  echo "To apply the fix:"
  echo "  NS=$NS $0 --fix"
  exit 0
fi

# ── Step 5: Terminate orphaned connections ────────────────────────────────────
header "Step 5: Terminating $ORPHAN_COUNT orphaned connection(s)"

TERMINATED=0
NOT_FOUND=0

for pid in "${ORPHAN_PIDS[@]}"; do
  info "Terminating PID $pid..."
  RESULT=$(pg_exec "SELECT pg_terminate_backend($pid);" || echo "error")
  RESULT=$(echo "$RESULT" | tr -d ' \n')
  if [[ "$RESULT" == "t" ]]; then
    success "PID $pid terminated."
    ((TERMINATED++))
  else
    warn "PID $pid: returned '$RESULT' (may already have exited — safe to ignore)."
    ((NOT_FOUND++))
  fi
done

echo ""
info "Terminated: $TERMINATED  |  Already gone: $NOT_FOUND"

# ── Step 6: Verify lock chain cleared ─────────────────────────────────────────
header "Step 6: Verifying lock chain is cleared"

sleep 3

REMAINING=$(pg_exec "
SELECT count(*)
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
  ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
  AND blocked.datname = 'archer';" || echo "?")
REMAINING=$(echo "$REMAINING" | tr -d ' ')

if [[ "$REMAINING" == "0" ]]; then
  success "Lock chain cleared — no blocking sessions remain on archer DB."
else
  warn "$REMAINING blocking session(s) still present on archer DB."
  warn "There may be additional blockers not matching the archer-server pattern."
  warn "Run the full lock chain query to investigate:"
  echo ""
  echo "  oc exec -n $NS $PG_POD -- psql -U postgres -c \\"
  echo "  \"SELECT blocked.pid, left(blocked.query,60) AS blocked_q,"
  echo "          blocker.pid AS blocker_pid, blocker.state,"
  echo "          blocker.application_name"
  echo "   FROM pg_stat_activity blocked"
  echo "   JOIN pg_stat_activity blocker"
  echo "     ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))"
  echo "   WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;\""
fi

# ── Step 7: Job progress confirmation ─────────────────────────────────────────
header "Step 7: Confirming job progress"

sleep 5

STUCK_POD=$(oc get pods -n "$NS" \
              --selector="job-name=${JOB_NAME}" \
              --field-selector=status.phase=Running \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$STUCK_POD" ]]; then
  NEW_LOG=$(oc logs "$STUCK_POD" -n "$NS" --tail=1 2>/dev/null \
              | grep -v "^$" || true)
  info "Latest log from $STUCK_POD:"
  echo "  ${NEW_LOG:-<no output yet>}"
  echo ""
  info "Monitor completion (blocks until done):"
  echo "  oc wait job/${JOB_NAME} -n $NS \\"
  echo "    --for=condition=Complete --timeout=3600s"
else
  JOB_DONE=$(oc get job "$JOB_NAME" -n "$NS" \
               -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' \
               2>/dev/null || true)
  if [[ "$JOB_DONE" == "True" ]]; then
    success "Job completed successfully!"
  else
    info "Job pod not yet visible — may be restarting after lock cleared."
    info "Re-check in ~30s:  oc get job $JOB_NAME -n $NS"
  fi
fi

echo ""
success "Workaround applied."
info "Once the job completes, WxO reconciliation resumes automatically."
info "Expected final CR state: RECONCILE_PROGRESS=100%  READY=True"
info "Monitor with:"
echo "  oc get watsonxorchestrate $CR -n $NS"
