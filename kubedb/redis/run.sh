#!/usr/bin/env bash
set -euo pipefail

DB_DIR="/home/hiranmoy/go/src/HiranmoyChowdhury/chaos-mesh/kubedb/redis/db-yaml"
TEST_DIR="/home/hiranmoy/go/src/HiranmoyChowdhury/chaos-mesh/kubedb/redis/chaos-mesh/tests"
REPORT_DIR="${REPORT_DIR:-$TEST_DIR/reports}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
REPORT_FILE="$REPORT_DIR/redis-chaos-report-$RUN_ID.tsv"

mkdir -p "$REPORT_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need kubectl
need awk

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Parse basic fields from YAML (assumes single object in file)
yaml_kind() { awk '/^kind:/{print $2; exit}' "$1"; }
yaml_name() { awk '/^metadata:/,/^spec:/ { if ($1=="name:") {print $2; exit} }' "$1"; }
yaml_ns()   { awk '/^metadata:/,/^spec:/ { if ($1=="namespace:") {print $2; exit} }' "$1"; }

# Wait until a KubeDB Redis object reaches status.phase=Ready
wait_redis_ready() {
  local ns="$1" name="$2" timeout="${3:-900}" start now phase
  start="$(date +%s)"
  while true; do
    phase="$(kubectl -n "$ns" get redis "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Ready" ]]; then return 0; fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      log "Timeout waiting Redis/$name Ready in $ns (phase=$phase)"
      return 1
    fi
    sleep 5
  done
}

# Wait for Chaos Mesh experiment AllRecovered=True
wait_chaos_all_recovered() {
  local kind="$1" ns="$2" name="$3" timeout="${4:-900}" start now cond
  start="$(date +%s)"
  while true; do
    # If resource missing, consider recovered (cleanup or short-lived)
    if ! kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
      return 0
    fi
    cond="$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath="{range .status.conditions[*]}{.type}:{.status}{' '}{end}" 2>/dev/null || true)"
    if echo "$cond" | grep -q 'AllRecovered:True'; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      log "Timeout waiting AllRecovered=True for $kind/$name in $ns (conds: $cond)"
      return 1
    fi
    sleep 5
  done
}

apply_db_yamls() {
  local db_files=("$@")
  for f in "${db_files[@]}"; do
    log "Applying DB: $(basename "$f")"
    kubectl apply -f "$f"
    local ns name
    ns="$(yaml_ns "$f")"; name="$(yaml_name "$f")"
    [[ -z "$ns" || -z "$name" ]] && { log "Cannot parse ns/name from $f"; return 1; }
    wait_redis_ready "$ns" "$name" 1200 || return 1
  done
}

delete_db_yamls() {
  local db_files=("$@")
  for f in "${db_files[@]}"; do
    log "Deleting DB: $(basename "$f")"
    kubectl delete -f "$f" --ignore-not-found
  done
}

delete_test_yaml() {
  local f="$1"
  local kind name ns
  kind="$(yaml_kind "$f")"; name="$(yaml_name "$f")"; ns="$(yaml_ns "$f")"
  [[ -z "$ns" ]] && ns="chaos-mesh"
  if [[ -n "$kind" && -n "$name" ]]; then
    log "Deleting test: $kind/$name in $ns"
    kubectl -n "$ns" delete "$kind" "$name" --ignore-not-found || true
  else
    kubectl delete -f "$f" --ignore-not-found || true
  fi
}

run() {
  printf "run_id\tdb_yaml\tredis_ns\tredis_name\ttest_yaml\ttest_kind\ttest_ns\ttest_name\tapply_db\tapply_test\tredis_ready\tall_recovered\toverall\n" > "$REPORT_FILE"

  mapfile -t DBS < <(find "$DB_DIR" -type f -name '*.yaml' | sort)
  mapfile -t TESTS < <(find "$TEST_DIR" -maxdepth 1 -type f -name '*.yaml' | sort)

  if (( ${#DBS[@]} == 0 )); then log "No DB YAMLs found in $DB_DIR"; exit 1; fi
  if (( ${#TESTS[@]} == 0 )); then log "No test YAMLs found in $TEST_DIR"; exit 1; fi

  for db in "${DBS[@]}"; do
    local redis_ns redis_name
    redis_ns="$(yaml_ns "$db")"; redis_name="$(yaml_name "$db")"
    [[ -z "$redis_ns" || -z "$redis_name" ]] && { log "Skip DB (parse failed): $db"; continue; }

    # Apply DB
    local apply_db="FAIL"
    if apply_db_yamls "$db"; then apply_db="OK"; else apply_db="FAIL"; fi

    for test in "${TESTS[@]}"; do
      local tk tn tns apply_test="FAIL" redis_ready="FAIL" all_recovered="FAIL" overall="FAIL"
      tk="$(yaml_kind "$test")"; tn="$(yaml_name "$test")"; tns="$(yaml_ns "$test")"
      [[ -z "$tns" ]] && tns="chaos-mesh"

      log "Applying test: $(basename "$test") ($tk/$tn in $tns)"
      if kubectl apply -f "$test"; then
        apply_test="OK"
      else
        apply_test="FAIL"
      fi

      # Wait Redis ready again (post chaos start)
      if wait_redis_ready "$redis_ns" "$redis_name" 1200; then
        redis_ready="OK"
      fi

      # Wait Chaos AllRecovered=True
      if [[ "$apply_test" == "OK" && -n "$tk" && -n "$tn" ]]; then
        if wait_chaos_all_recovered "$tk" "$tns" "$tn" 1200; then
          all_recovered="OK"
        fi
      fi

      if [[ "$apply_db" == "OK" && "$apply_test" == "OK" && "$redis_ready" == "OK" && "$all_recovered" == "OK" ]]; then
        overall="OK"
      fi

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$RUN_ID" "$(basename "$db")" "$redis_ns" "$redis_name" "$(basename "$test")" "$tk" "$tns" "$tn" \
        "$apply_db" "$apply_test" "$redis_ready" "$all_recovered" "$overall" >> "$REPORT_FILE"

      # Cleanup test and DB for next cycle
      delete_test_yaml "$test"
      delete_db_yamls "$db"

      # Re-apply DB to start fresh for next test
      if apply_db_yamls "$db"; then
        apply_db="OK"
      else
        apply_db="FAIL"
        log "Failed to re-apply DB $db; continuing to next test."
      fi
    done

    # Final cleanup for this DB
    delete_db_yamls "$db"
  done

  log "Report written to $REPORT_FILE"
  column -t -s $'\t' "$REPORT_FILE" || cat "$REPORT_FILE"
}

run "$@"

