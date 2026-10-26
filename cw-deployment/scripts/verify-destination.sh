#!/usr/bin/env bash
# Pre-flight checks on gc-gei-ollama BEFORE `docker compose up`.
# Read-only: changes nothing on the server, starts nothing, prints no secrets.
# Run from the cw-deployment directory:  bash scripts/verify-destination.sh
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "[PASS] $*"; }
warn() { echo "[WARN] $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }

echo "== host"
arch=$(uname -m)
[ "$arch" = "x86_64" ] && pass "architecture x86_64 (pinned images are amd64)" || bad "architecture is $arch; pinned images are amd64"
echo "     $(nproc) CPUs, $(free -h | awk '/^Mem:/ {print $7 " RAM available of " $2}')"
df -h --output=avail,target / /var/lib/docker 2>/dev/null | sed 's/^/     /'

echo "== docker"
if docker info >/dev/null 2>&1; then
  pass "docker reachable ($(docker version --format '{{.Server.Version}}'))"
else
  bad "cannot talk to docker (not in docker group?) - do NOT use sudo, report back"
fi
docker compose version >/dev/null 2>&1 && pass "docker compose available ($(docker compose version --short))" || bad "docker compose plugin missing"

echo "== tun device (needed by the Octelium sidecar)"
[ -c /dev/net/tun ] && pass "/dev/net/tun present" || bad "/dev/net/tun missing"

echo "== name collisions (must be empty before first deploy)"
c=$(docker ps -a --format '{{.Names}}' | grep -E '^cw-mcp' || true)
n=$(docker network ls --format '{{.Name}}' | grep -E '^cw-mcp' || true)
[ -z "$c" ] && pass "no existing cw-mcp* containers" || warn "existing containers: $c (redeploy? read ROLLBACK.md first)"
[ -z "$n" ] && pass "no existing cw-mcp* networks" || warn "existing networks: $n"

echo "== configuration files"
if [ -f .env ]; then
  pass ".env present"
  grep -vE '^[[:space:]]*(#|$)' .env | cut -d= -f1 | grep -qiE 'token|password|secret' \
    && bad ".env defines a token/password/secret variable - secrets belong in secrets/ only" \
    || pass ".env contains no secret-looking variables"
else
  bad ".env missing (cp .env.example .env)"
fi
s=secrets/octelium_auth_token
if [ -f "$s" ]; then
  perm=$(stat -c '%a' "$s")
  [ "$perm" = "600" ] && pass "$s mode 600" || bad "$s mode is $perm, expected 600 (chmod 600 $s)"
  [ -s "$s" ] && pass "$s is non-empty ($(wc -c < "$s") bytes)" || bad "$s is empty"
  [ "$(wc -l < "$s")" -le 1 ] && pass "$s is a single line" || bad "$s has multiple lines"
else
  bad "$s missing"
fi

echo "== compose file"
if out=$(docker compose config 2>&1); then
  pass "docker compose config resolves"
  echo "$out" | grep -qE '^\s+published:' && bad "compose publishes a host port - must be none" || pass "no host ports published"
  if [ -f "$s" ] && [ -s "$s" ] && echo "$out" | grep -qF -- "$(cat "$s")"; then
    bad "the auth token appears in the rendered compose config"
  else
    pass "auth token not present in rendered compose config"
  fi
else
  bad "docker compose config failed:"; echo "$out" | sed 's/^/     /'
fi

echo
[ "$fail" -eq 0 ] && echo "PRE-FLIGHT: OK" || echo "PRE-FLIGHT: FAILED - fix the [FAIL] items before deploying"
exit "$fail"
