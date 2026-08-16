#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in \
  Dockerfile \
  pipeline.env \
  scripts/fetch-upstream.sh \
  scripts/deploy-digest.sh \
  scripts/check-stable-and-deploy.sh \
  .github/workflows/build-candidate.yml \
  .github/workflows/promote-stable.yml
do
  [ -s "$file" ] || fail "missing required file: $file"
done

bash -n scripts/fetch-upstream.sh
bash -n scripts/deploy-digest.sh
bash -n scripts/check-stable-and-deploy.sh

grep -qE '^FROM python:3\.12-slim@sha256:[0-9a-f]{64} AS builder$' Dockerfile || fail 'pinned builder stage missing'
grep -q '^FROM builder AS test$' Dockerfile || fail 'test stage missing'
grep -qE '^FROM python:3\.12-slim@sha256:[0-9a-f]{64} AS runtime$' Dockerfile || fail 'pinned runtime stage missing'
grep -q '^USER 10001:10001$' Dockerfile || fail 'runtime must be non-root'
grep -q 'pytest -q' Dockerfile || fail 'pytest gate missing'

if grep -RInE ':latest([^A-Za-z0-9_.-]|$)|docker\.io|index\.docker\.io' \
  Dockerfile pipeline.env .github scripts systemd; then
  fail 'moving latest tag or Docker Hub dependency found'
fi

python3 - <<'PY'
from pathlib import Path
import re

for workflow in Path('.github/workflows').glob('*.yml'):
    text = workflow.read_text()
    uses = re.findall(r'^\s*uses:\s*([^\s#]+)', text, re.MULTILINE)
    for item in uses:
        if '@' not in item:
            raise SystemExit(f'{workflow}: action is not pinned: {item}')
        ref = item.rsplit('@', 1)[1]
        if not re.fullmatch(r'[0-9a-f]{40}', ref):
            raise SystemExit(f'{workflow}: action is not pinned to a full SHA: {item}')
print('workflow action pins: OK')
PY

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/stack" "$tmp/bin" "$tmp/state" "$tmp/backups"
: >"$tmp/stack/docker-compose.yml"

cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$FAKE_DOCKER_LOG"

if [ "${1:-}" = inspect ]; then
  if [ -f "$FAKE_AFTER_UP" ] && [ ! -f "$FAKE_ROLLED_BACK" ] && [ "${FAKE_FAIL_NEW:-0}" = 1 ]; then
    echo unhealthy
  else
    echo healthy
  fi
  exit 0
fi

if [ "${1:-}" = pull ]; then exit 0; fi

if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  case "$*" in
    *Architecture*) echo amd64 ;;
    *'.Os'*) echo linux ;;
    *org.opencontainers.image.revision*) printf '%040d\n' 1 ;;
    *) : ;;
  esac
  exit 0
fi

if [ "${1:-}" = image ] && [ "${2:-}" = tag ]; then
  if [[ "$*" == *'gateway-stack/treg:rollback gateway-stack/treg:current'* ]]; then
    : >"$FAKE_ROLLED_BACK"
  fi
  exit 0
fi

if [ "${1:-}" = compose ]; then
  case "$*" in
    *'pg_dump'*) printf 'valid-dump\n'; exit 0 ;;
    *'pg_restore --list'*) cat >/dev/null; exit 0 ;;
    *'up -d --no-deps --force-recreate treg'*) : >"$FAKE_AFTER_UP"; exit 0 ;;
  esac
fi

echo "unhandled fake docker command: $*" >&2
exit 1
SH
chmod +x "$tmp/bin/docker"

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/bin/curl"

digest="sha256:$(printf 'a%.0s' {1..64})"
export PATH="$tmp/bin:$PATH"
export FAKE_DOCKER_LOG="$tmp/docker.log"
export FAKE_AFTER_UP="$tmp/after-up"
export FAKE_ROLLED_BACK="$tmp/rolled-back"
export TREG_REGISTRY_IMAGE=ghcr.io/example/tools-registry
export TREG_STACK_DIR="$tmp/stack"
export TREG_COMPOSE_FILE="$tmp/stack/docker-compose.yml"
export TREG_BACKUP_DIR="$tmp/backups"
export TREG_DEPLOY_STATE_DIR="$tmp/state"
export TREG_DEPLOY_LOCK_FILE="$tmp/deploy.lock"
export TREG_HEALTH_ATTEMPTS=1
export TREG_HEALTH_INTERVAL_SECONDS=0

scripts/deploy-digest.sh --dry-run "$digest" >/dev/null
if grep -Eq '^(pull|image tag|compose .* (pg_dump|pg_restore|up -d))' "$tmp/docker.log"; then
  fail 'dry-run invoked a mutating Docker command'
fi
: >"$tmp/docker.log"

TREG_DEPLOY_CONFIRMED=1 scripts/deploy-digest.sh "$digest" >/dev/null
[ "$(cat "$tmp/state/last-successful-digest")" = "$digest" ] || fail 'successful digest state missing'
[ "$(find "$tmp/backups" -type f -name '*.dump' | wc -l)" -eq 1 ] || fail 'validated database dump missing'
grep -q 'gateway-stack/treg:current gateway-stack/treg:rollback' "$tmp/docker.log" || fail 'rollback image was not preserved'

rm -f "$tmp/after-up" "$tmp/rolled-back" "$tmp/docker.log" "$tmp/state/last-successful-digest"
FAKE_FAIL_NEW=1 TREG_DEPLOY_CONFIRMED=1 scripts/deploy-digest.sh "$digest" >/dev/null 2>&1 && fail 'failed candidate unexpectedly succeeded'
[ -e "$tmp/rolled-back" ] || fail 'failed candidate did not trigger rollback'

echo 'contract tests: OK'
