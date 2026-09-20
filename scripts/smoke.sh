#!/usr/bin/env bash
# End-to-end install test: brings the stack up from docker-compose.yml with
# no .env, waits for health, creates the first admin through the same route
# the dashboard uses, signs in, sends an event, checks it is queryable, and
# verifies that signup closed after the first account. Exit 0 means a fresh
# `docker compose up -d` gives a working server.
#
#   IFOREVENTS_VERSION=1.2.3 scripts/smoke.sh
#
# Runs against an isolated project name so it never touches a real install.
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in docker curl jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-iforevents-smoke}"
export BIND_ADDRESS=127.0.0.1
export API_PORT="${API_PORT:-18000}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-18010}"
export PUBLIC_URL="http://127.0.0.1:${DASHBOARD_PORT}"
export API_PUBLIC_URL="http://127.0.0.1:${API_PORT}"
export DOCKER_SUBNET="${DOCKER_SUBNET:-172.29.0.0/16}"

API="http://127.0.0.1:${API_PORT}"
DASH="http://127.0.0.1:${DASHBOARD_PORT}"
COMPOSE=(docker compose -f docker-compose.yml)

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- api logs ---"; "${COMPOSE[@]}" logs --no-color --tail=100 api || true
    echo "--- dashboard logs ---"; "${COMPOSE[@]}" logs --no-color --tail=50 dashboard || true
  fi
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }

step "docker compose up (version ${IFOREVENTS_VERSION:-latest})"
"${COMPOSE[@]}" up -d --wait --wait-timeout 300

step "readiness"
curl -fsS "${API}/ready"; echo
curl -fsS -o /dev/null -w 'dashboard /api/health -> %{http_code}\n' "${DASH}/api/health"

step "first-run state"
STATUS=$(curl -fsS "${API}/v1/setup/status")
echo "$STATUS"
[ "$(echo "$STATUS" | jq -r .needs_setup)" = "true" ] || { echo "expected needs_setup=true on a fresh install" >&2; exit 1; }

step "create the first admin"
REG=$(curl -sS -X POST "${API}/v1/auth/register" -H 'Content-Type: application/json' \
  -d '{"full_name":"Smoke Admin","email":"admin@smoke.test","password":"Smoke-Test-Passw0rd!","organization_name":"Smoke Org"}')
echo "$REG" | jq -e '.user.uuid' >/dev/null || { echo "register failed: $REG" >&2; exit 1; }
[ "$(echo "$REG" | jq -r .user.email_verified)" = "true" ] || { echo "first admin must be verified without SMTP: $REG" >&2; exit 1; }
TOKEN=$(echo "$REG" | jq -r .token.token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "no access token in register response: $REG" >&2; exit 1; }

step "signup is closed afterwards"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API}/v1/auth/register" -H 'Content-Type: application/json' \
  -d '{"full_name":"Second","email":"second@smoke.test","password":"Smoke-Test-Passw0rd!","organization_name":"Other"}')
[ "$CODE" = "403" ] || { echo "expected 403 for a second signup, got $CODE" >&2; exit 1; }

step "sign in"
curl -fsS -X POST "${API}/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@smoke.test","password":"Smoke-Test-Passw0rd!"}' >/dev/null

step "create a project and send an event"
PROJECT=$(curl -fsS -X POST "${API}/v1/projects" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{"name":"Smoke App"}')
KEY=$(echo "$PROJECT" | jq -r .project.key)
PROJECT_UUID=$(echo "$PROJECT" | jq -r .project.uuid)
[ -n "$KEY" ] && [ "$KEY" != "null" ] || { echo "no project key: $PROJECT" >&2; exit 1; }
curl -fsS -X POST "${API}/v1/events/track" -H "X-Project-Key: ${KEY}" -H 'Content-Type: application/json' \
  -d '{"event_name":"smoke_test","custom_uuid":"smoke-user-1"}' >/dev/null

step "the event is queryable"
TOTAL=0
for _ in $(seq 1 30); do
  METRICS=$(curl -fsS "${API}/v1/analytics/metrics?project_uuid=${PROJECT_UUID}" -H "Authorization: Bearer ${TOKEN}" || echo '{}')
  TOTAL=$(echo "$METRICS" | jq -r '.metrics.total_events // 0')
  [ "$TOTAL" -ge 1 ] && break
  sleep 1
done
echo "$METRICS"
[ "$TOTAL" -ge 1 ] || { echo "event never showed up in metrics" >&2; exit 1; }

step "the dashboard renders the login page"
curl -fsSL -o /dev/null -w 'GET / -> %{http_code}\n' "${DASH}/"

step "the dashboard proxies the session (AUTH_MODE=local)"
DSTATUS=$(curl -fsS "${DASH}/api/setup/status")
echo "$DSTATUS"
[ "$(echo "$DSTATUS" | jq -r .auth_mode)" = "local" ] || { echo "dashboard is not in local auth mode" >&2; exit 1; }
[ "$(echo "$DSTATUS" | jq -r .needs_setup)" = "false" ] || { echo "dashboard still reports needs_setup after the first admin" >&2; exit 1; }
JAR=$(mktemp)
DLOGIN=$(curl -sS -c "$JAR" -X POST "${DASH}/api/v1/auth/login" \
  -H 'Content-Type: application/json' -H 'X-Requested-With: iforevents-dashboard' -H "Origin: ${DASH}" \
  -d '{"email":"admin@smoke.test","password":"Smoke-Test-Passw0rd!"}')
echo "$DLOGIN" | jq -e '.ok == true and .user.role_name == "admin"' >/dev/null || { echo "dashboard login failed: $DLOGIN" >&2; rm -f "$JAR"; exit 1; }
grep -q "auth_token" "$JAR" || { echo "no session cookie set by the dashboard" >&2; rm -f "$JAR"; exit 1; }
DME=$(curl -fsS -b "$JAR" "${DASH}/api/v1/auth/me" -H 'X-Requested-With: iforevents-dashboard')
echo "$DME" | jq -e '.user.email == "admin@smoke.test" and (.organizations | length) == 1' >/dev/null || { echo "dashboard /me wrong: $DME" >&2; rm -f "$JAR"; exit 1; }
DTEAM=$(curl -sS -b "$JAR" -X POST "${DASH}/api/v1/team" \
  -H 'Content-Type: application/json' -H 'X-Requested-With: iforevents-dashboard' -H "Origin: ${DASH}" \
  -d '{"email":"viewer@smoke.test","role":"viewer","full_name":"Smoke Viewer"}')
echo "$DTEAM" | jq -e '.invited == ["viewer@smoke.test"] and (.credentials[0].temporary_password | length) >= 12' >/dev/null || { echo "adding a member failed: $DTEAM" >&2; rm -f "$JAR"; exit 1; }
TMPPW=$(echo "$DTEAM" | jq -r '.credentials[0].temporary_password')
curl -fsS -X POST "${API}/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"viewer@smoke.test\",\"password\":\"${TMPPW}\"}" >/dev/null || { echo "the new member cannot sign in with the one-time password" >&2; rm -f "$JAR"; exit 1; }
rm -f "$JAR"

step "restart keeps the session secret"
"${COMPOSE[@]}" restart api >/dev/null
"${COMPOSE[@]}" up -d --wait api >/dev/null
curl -fsS "${API}/v1/auth/me" -H "Authorization: Bearer ${TOKEN}" >/dev/null || { echo "token invalid after restart: TOKEN_SECRET was not persisted" >&2; exit 1; }

printf '\nSMOKE OK\n'
