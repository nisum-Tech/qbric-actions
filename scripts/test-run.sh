#!/bin/bash
# ---------------------------------------------------------------------------
# Qbric Test-Run Reporter
#
# Parses the build's existing test reports (Maven/Gradle Surefire XML, or a
# Cucumber JSON report) and reports a pass/fail/duration summary to qbric-api,
# where it lands on the Test Runs page (test_run_results).
#
# Run this AFTER your test step (mvn test / gradle test / npm test). Reporting
# is best-effort: a failed POST logs a warning but never fails the build. The
# build's own test step decides pass/fail of the pipeline.
# ---------------------------------------------------------------------------
set -uo pipefail

SCAN_PATH="${1:-.}"

QBRIC_API_URL="${QBRIC_API_URL:-}"
QBRIC_SCAN_TOKEN="${QBRIC_SCAN_TOKEN:-}"
QBRIC_TENANT_ID="${QBRIC_TENANT_ID:-}"
REPO_FULL_NAME="${REPO_FULL_NAME:-unknown/unknown}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
REF_NAME="${REF_NAME:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
RUN_ID="${RUN_ID:-}"
EVENT_NAME="${EVENT_NAME:-manual}"

echo "================================="
echo " Qbric Test-Run Reporter"
echo "================================="
echo "repo:   $REPO_FULL_NAME"
echo "run:    $RUN_ID  (event: $EVENT_NAME)"
echo

total=0; failures=0; errors=0; skipped=0; time_total=0
report_source="none"

# --- JUnit XML: Maven Surefire/Failsafe + Gradle test-results --------------
# Surefire/Failsafe write */surefire-reports|failsafe-reports/TEST-*.xml;
# Gradle writes */build/test-results/<task>/TEST-*.xml. All share the JUnit
# <testsuite> schema, so one parser handles every build tool.
attr() { echo "$1" | sed -nE "s/.* $2=\"([0-9.]+)\".*/\1/p"; }
while IFS= read -r xml; do
  line=$(grep -m1 '<testsuite ' "$xml" 2>/dev/null || true)
  [ -z "$line" ] && continue
  t=$(attr "$line" tests);    f=$(attr "$line" failures)
  e=$(attr "$line" errors);   s=$(attr "$line" skipped)
  tm=$(attr "$line" time)
  total=$((total + ${t:-0})); failures=$((failures + ${f:-0}))
  errors=$((errors + ${e:-0})); skipped=$((skipped + ${s:-0}))
  time_total=$(awk "BEGIN{printf \"%.3f\", $time_total + ${tm:-0}}")
  report_source="junit-xml"
done < <(find "$SCAN_PATH" \( \
            -path '*/surefire-reports/TEST-*.xml' \
            -o -path '*/failsafe-reports/TEST-*.xml' \
            -o -path '*/build/test-results/*/TEST-*.xml' \
          \) -not -path '*/.git/*' 2>/dev/null || true)

# --- Cucumber JSON fallback (npm / cucumber-js) -----------------------------
if [ "$report_source" = "none" ]; then
  cjson=$(find "$SCAN_PATH" \( -name 'cucumber-report.json' -o -name 'cucumber.json' \) -not -path '*/.git/*' 2>/dev/null | head -1)
  if [ -n "$cjson" ] && command -v python3 >/dev/null 2>&1; then
    read -r total passed failed skipped < <(python3 - "$cjson" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0"); sys.exit()
total = passed = failed = skipped = 0
for feature in data if isinstance(data, list) else []:
    for el in feature.get("elements", []):
        steps = el.get("steps", [])
        statuses = [s.get("result", {}).get("status") for s in steps]
        if not statuses:
            continue
        total += 1
        if any(st == "failed" for st in statuses):
            failed += 1
        elif all(st in ("skipped", "undefined", "pending") for st in statuses):
            skipped += 1
        else:
            passed += 1
print(f"{total} {passed} {failed} {skipped}")
PY
)
    failures="$failed"; errors=0
    report_source="cucumber-json:$cjson"
  fi
fi

failed=$(( failures + errors ))
passed=$(( total - failed - skipped ))
[ "$passed" -lt 0 ] && passed=0
duration=$(awk "BEGIN{printf \"%d\", $time_total + 0.5}")

echo "report source: $report_source"
echo "tests: total=$total passed=$passed failed=$failed skipped=$skipped duration=${duration}s"
echo

if [ "$report_source" = "none" ]; then
  echo "No test reports found (looked for surefire/failsafe XML and cucumber JSON)."
  echo "Run your test step before this action, or point scan-path at the module root."
fi

# --- build payload ----------------------------------------------------------
ran_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
payload=$(cat <<JSON
{
  "schemaVersion": 1,
  "repository": { "fullName": "$REPO_FULL_NAME", "defaultBranch": "$DEFAULT_BRANCH" },
  "run": { "branch": "$REF_NAME", "commitSha": "$COMMIT_SHA", "runId": "$RUN_ID",
           "triggeredBy": "$EVENT_NAME", "ranAt": "$ran_at" },
  "summary": { "total": $total, "passed": $passed, "failed": $failed,
               "durationSeconds": $duration }
}
JSON
)

# --- report (best-effort) ---------------------------------------------------
if [ -n "$QBRIC_API_URL" ] && [ -n "$QBRIC_SCAN_TOKEN" ] && [ -n "$QBRIC_TENANT_ID" ]; then
  url="${QBRIC_API_URL%/}/v1/tenants/${QBRIC_TENANT_ID}/test-runs"
  echo "Reporting test run to $url"
  http_code=$(curl -sS -m 30 -o /tmp/qbric-testrun-resp.txt -w "%{http_code}" \
    -X POST "$url" \
    -H "Authorization: Bearer ${QBRIC_SCAN_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null || echo "000")
  if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
    echo "  ✓ reported (HTTP $http_code)"
  else
    echo "  ⚠ report failed (HTTP $http_code) — build not failed on reporting"
    head -c 400 /tmp/qbric-testrun-resp.txt 2>/dev/null || true
  fi
else
  echo "Reporting skipped (set qbric-api-url, qbric-scan-token, tenant-id). Payload:"
  echo "$payload"
fi

echo "Qbric test-run reporting completed."
