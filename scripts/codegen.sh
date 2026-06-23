#!/bin/bash
# ---------------------------------------------------------------------------
# Qbric — Step 1: Execute (Call API) New Code Generation
#
# Triggers a codegen job on qbric-api for the current repository. This is the
# real platform codegen (clone -> plan -> generate -> PR) — the Action only
# kicks it off; qbric-api runs it asynchronously on its own host using the
# tenant's stored git credentials and reports progress on the Generation page.
#
# Auth is the per-tenant scan token (same token used for test-run reporting).
# Best-effort: a failed trigger logs a warning but does not fail the build, so
# a transient API hiccup never breaks a pipeline. Set QBRIC_FAIL_ON_ERROR=true
# to make a failed trigger fail the step instead.
# ---------------------------------------------------------------------------
set -uo pipefail

QBRIC_API_URL="${QBRIC_API_URL:-}"
QBRIC_SCAN_TOKEN="${QBRIC_SCAN_TOKEN:-}"
QBRIC_TENANT_ID="${QBRIC_TENANT_ID:-}"
REPO_FULL_NAME="${REPO_FULL_NAME:-}"
REF_NAME="${REF_NAME:-}"

# Codegen knobs (all optional; qbric-api applies CI-friendly defaults).
INPUT_TYPE="${INPUT_TYPE:-}"           # ALL_UNIMPLEMENTED | FEATURE_FILE | JIRA | REQUIREMENT | SWAGGER
ACCELERATOR="${ACCELERATOR:-}"         # UI | API | MOBILE
CODEGEN_PROFILE="${CODEGEN_PROFILE:-}" # BASIC | ENHANCE
FEATURE_PATH="${FEATURE_PATH:-}"
JIRA_KEY="${JIRA_KEY:-}"
REQUIREMENT="${REQUIREMENT:-}"
AUTO_APPROVE="${AUTO_APPROVE:-}"       # true | false (CI default: true)
BUILD_SYSTEM="${BUILD_SYSTEM:-}"
TEST_FRAMEWORK="${TEST_FRAMEWORK:-}"
BASE_PACKAGE="${BASE_PACKAGE:-}"
QBRIC_FAIL_ON_ERROR="${QBRIC_FAIL_ON_ERROR:-false}"

echo "================================="
echo " Qbric — New Code Generation"
echo "================================="
echo "repo:   $REPO_FULL_NAME"
echo "branch: $REF_NAME"
echo

if [ -z "$QBRIC_API_URL" ] || [ -z "$QBRIC_SCAN_TOKEN" ] || [ -z "$QBRIC_TENANT_ID" ]; then
  echo "Codegen trigger skipped (set qbric-api-url, qbric-scan-token, tenant-id to enable)."
  exit 0
fi
if [ -z "$REPO_FULL_NAME" ]; then
  echo "Codegen trigger skipped: repository name is unknown."
  exit 0
fi

# --- build payload (only include fields that were provided) -----------------
# Escape a value for safe inclusion in a JSON string literal.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
fields=()
add_str()  { [ -n "$2" ] && fields+=("\"$1\": \"$(json_escape "$2")\""); }
add_raw()  { [ -n "$2" ] && fields+=("\"$1\": $2"); }

add_str repositoryFullName "$REPO_FULL_NAME"
add_str branch             "$REF_NAME"
add_str inputType          "$INPUT_TYPE"
add_str acceleratorType    "$ACCELERATOR"
add_str codegenProfile     "$CODEGEN_PROFILE"
add_str featurePath        "$FEATURE_PATH"
add_str jiraKey            "$JIRA_KEY"
add_str requirement        "$REQUIREMENT"
add_str buildSystem        "$BUILD_SYSTEM"
add_str testFramework      "$TEST_FRAMEWORK"
add_str basePackage        "$BASE_PACKAGE"
[ "$AUTO_APPROVE" = "true" ]  && add_raw autoApprove true
[ "$AUTO_APPROVE" = "false" ] && add_raw autoApprove false

payload="{ $(IFS=,; echo "${fields[*]}") }"

url="${QBRIC_API_URL%/}/v1/tenants/${QBRIC_TENANT_ID}/codegen/ci-jobs"
echo "Triggering codegen at $url"
http_code=$(curl -sS -m 60 -o /tmp/qbric-codegen-resp.txt -w "%{http_code}" \
  -X POST "$url" \
  -H "Authorization: Bearer ${QBRIC_SCAN_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$payload" 2>/dev/null || echo "000")

body=$(cat /tmp/qbric-codegen-resp.txt 2>/dev/null || true)
if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
  job_id=$(printf '%s' "$body" | sed -nE 's/.*"jobId"[ ]*:[ ]*"([^"]+)".*/\1/p')
  echo "  ✓ codegen job triggered (HTTP $http_code)${job_id:+ — jobId=$job_id}"
  echo "    Track progress on the Qbric Generation page."
  exit 0
fi

echo "  ⚠ codegen trigger failed (HTTP $http_code)"
printf '%s\n' "$body" | head -c 500
echo
if [ "$QBRIC_FAIL_ON_ERROR" = "true" ]; then
  echo "Failing the step (QBRIC_FAIL_ON_ERROR=true)."
  exit 1
fi
echo "Continuing — build not failed on codegen trigger."
exit 0
