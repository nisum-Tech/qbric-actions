#!/bin/bash
# ---------------------------------------------------------------------------
# Qbric Repository Scanner (reference implementation)
#
# Scans a repo, computes a heuristic coverage / untested-flow summary, checks
# for likely secrets, then reports a v1 scan-result payload to qbric-api.
#
# Reporting is best-effort: a failed POST logs a warning but does NOT fail the
# build. Secret findings DO fail the build when ENABLE_SECRETS=true.
#
# NOTE: the coverage / untested-flow numbers here are intentionally heuristic
# placeholders. Phase 3 should parse real reports (JaCoCo jacoco.xml, nyc
# coverage-final.json). See qbric-api/docs/SCAN_INGESTION_DESIGN.md.
# ---------------------------------------------------------------------------
set -uo pipefail

SCAN_PATH="${1:-.}"

# Env (provided by action.yml). Sensible fallbacks for local runs.
QBRIC_API_URL="${QBRIC_API_URL:-}"
QBRIC_SCAN_TOKEN="${QBRIC_SCAN_TOKEN:-}"
QBRIC_TENANT_ID="${QBRIC_TENANT_ID:-}"
ENABLE_JAVA="${ENABLE_JAVA:-true}"
ENABLE_NODE="${ENABLE_NODE:-true}"
ENABLE_SECRETS="${ENABLE_SECRETS:-true}"
REPO_FULL_NAME="${REPO_FULL_NAME:-unknown/unknown}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
REF_NAME="${REF_NAME:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
RUN_ID="${RUN_ID:-}"
EVENT_NAME="${EVENT_NAME:-manual}"

echo "================================="
echo " Qbric Repository Scanner"
echo "================================="
echo "repo:      $REPO_FULL_NAME"
echo "path:      $SCAN_PATH"
echo "commit:    $COMMIT_SHA"
echo "run:       $RUN_ID  (event: $EVENT_NAME)"
echo

# --- inventory --------------------------------------------------------------
files_scanned=$(find "$SCAN_PATH" -type f -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')

langs=()
build_tool="unknown"
if [ "$ENABLE_JAVA" = "true" ]; then
  if find "$SCAN_PATH" -name '*.java' -not -path '*/.git/*' | grep -q .; then langs+=("Java"); fi
  if [ -f "$SCAN_PATH/pom.xml" ]; then build_tool="Maven";
  elif find "$SCAN_PATH" -name 'build.gradle*' | grep -q .; then build_tool="Gradle"; fi
fi
if [ "$ENABLE_NODE" = "true" ] && [ -f "$SCAN_PATH/package.json" ]; then
  langs+=("Node"); [ "$build_tool" = "unknown" ] && build_tool="npm"
fi

# source vs test files (heuristic)
source_files=$(find "$SCAN_PATH" \( -name '*.java' -o -name '*.js' -o -name '*.ts' \) \
  -not -path '*/.git/*' -not -path '*/test*/*' -not -path '*/*Test*' 2>/dev/null | wc -l | tr -d ' ')
test_files=$(find "$SCAN_PATH" \( -path '*/test/*' -o -name '*Test.java' -o -name '*.test.js' \
  -o -name '*.spec.ts' -o -path '*/features/*' \) -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')

# heuristic coverage + untested flows (placeholder until real reports are parsed)
if [ "$source_files" -gt 0 ]; then
  coverage=$(awk "BEGIN{printf \"%.1f\", ($test_files/$source_files)*100}")
  [ "$(awk "BEGIN{print ($coverage>100)}")" = "1" ] && coverage="100.0"
else
  coverage="0.0"
fi
untested=$(( source_files > test_files ? source_files - test_files : 0 ))

# Prefer real coverage reports when present (JaCoCo / nyc); else keep the heuristic.
coverage_source="heuristic"
jacoco=$(find "$SCAN_PATH" -name 'jacoco.xml' -not -path '*/.git/*' 2>/dev/null | head -1)
nyc=$(find "$SCAN_PATH" \( -name 'coverage-summary.json' -o -path '*/coverage/coverage-summary.json' \) \
      -not -path '*/.git/*' 2>/dev/null | head -1)
if [ -n "$jacoco" ]; then
  # JaCoCo writes report-level totals as the LAST counters in the file.
  lc=$(grep -oE '<counter type="LINE"[^/]*/>' "$jacoco" | tail -1)
  miss=$(echo "$lc" | grep -oE 'missed="[0-9]+"' | grep -oE '[0-9]+')
  cov=$(echo "$lc" | grep -oE 'covered="[0-9]+"' | grep -oE '[0-9]+')
  if [ -n "$miss" ] && [ -n "$cov" ] && [ $((miss + cov)) -gt 0 ]; then
    coverage=$(awk "BEGIN{printf \"%.1f\", ($cov/($miss+$cov))*100}")
    coverage_source="jacoco:$jacoco"
  fi
  # missed methods ≈ untested flows
  mm=$(grep -oE '<counter type="METHOD"[^/]*/>' "$jacoco" | tail -1 | grep -oE 'missed="[0-9]+"' | grep -oE '[0-9]+')
  [ -n "$mm" ] && untested="$mm"
elif [ -n "$nyc" ]; then
  pct=$(python3 -c "import json;print(json.load(open('$nyc'))['total']['lines']['pct'])" 2>/dev/null)
  if [ -n "$pct" ]; then coverage="$pct"; coverage_source="nyc:$nyc"; fi
fi

echo "languages:    ${langs[*]:-none}"
echo "build tool:   $build_tool"
echo "files:        $files_scanned (source=$source_files, test=$test_files)"
echo "coverage:     ${coverage}%  (source: $coverage_source)   untested flows~: $untested"
echo

# --- secret check -----------------------------------------------------------
findings_json="[]"
status="OK"
if [ "$ENABLE_SECRETS" = "true" ]; then
  echo "Checking for likely secrets..."
  hit=$(grep -RInE "password=|api[_-]?key=|secret=|token=" "$SCAN_PATH" \
        --include='*.java' --include='*.js' --include='*.ts' --include='*.properties' \
        --include='*.yml' --include='*.yaml' 2>/dev/null | head -1 || true)
  if [ -n "$hit" ]; then
    path=$(echo "$hit" | cut -d: -f1); line=$(echo "$hit" | cut -d: -f2)
    findings_json=$(printf '[{"type":"SECRET","severity":"HIGH","path":"%s","line":%s,"message":"Possible hardcoded credential"}]' "$path" "${line:-0}")
    status="FINDINGS"
    echo "  ⚠ potential secret at $path:$line"
  else
    echo "  none found"
  fi
fi

# --- build v1 payload -------------------------------------------------------
langs_json=$(printf '%s\n' "${langs[@]:-}" | sed '/^$/d' | awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')
scanned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
payload=$(cat <<JSON
{
  "schemaVersion": 1,
  "repository": { "provider": "GITHUB", "fullName": "$REPO_FULL_NAME", "defaultBranch": "$DEFAULT_BRANCH" },
  "run": { "branch": "$REF_NAME", "commitSha": "$COMMIT_SHA", "runId": "$RUN_ID",
           "triggeredBy": "$EVENT_NAME", "scannedAt": "$scanned_at" },
  "summary": { "filesScanned": $files_scanned, "languages": [${langs_json:-}], "buildTool": "$build_tool",
               "testFiles": $test_files, "sourceFiles": $source_files,
               "untestedFlows": $untested, "coveragePercent": $coverage, "status": "$status" },
  "findings": $findings_json
}
JSON
)

# --- report to qbric-api (best-effort) --------------------------------------
if [ -n "$QBRIC_API_URL" ] && [ -n "$QBRIC_SCAN_TOKEN" ] && [ -n "$QBRIC_TENANT_ID" ]; then
  url="${QBRIC_API_URL%/}/v1/tenants/${QBRIC_TENANT_ID}/scan-results"
  echo "Reporting results to $url"
  http_code=$(curl -sS -m 30 -o /tmp/qbric-scan-resp.txt -w "%{http_code}" \
    -X POST "$url" \
    -H "Authorization: Bearer ${QBRIC_SCAN_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null || echo "000")
  if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
    echo "  ✓ reported (HTTP $http_code)"
  else
    echo "  ⚠ report failed (HTTP $http_code) — continuing; build not failed on reporting"
    cat /tmp/qbric-scan-resp.txt 2>/dev/null | head -c 400 || true
  fi
else
  echo "Reporting skipped (set qbric-api-url, qbric-scan-token, tenant-id to enable). Payload:"
  echo "$payload"
fi

# --- exit policy ------------------------------------------------------------
if [ "$status" = "FINDINGS" ] && [ "$ENABLE_SECRETS" = "true" ]; then
  echo "Qbric scan FAILED: secret finding(s) present."
  exit 1
fi
echo "Qbric scan completed successfully."
