#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-digest.sh [--dry-run] sha256:<64-hex-digest>

Required environment:
  TREG_REGISTRY_IMAGE       Example: ghcr.io/OWNER/tools-registry

Write gate:
  TREG_DEPLOY_CONFIRMED=1   Required unless --dry-run is used

Optional environment:
  TREG_STACK_DIR            Default: /opt/gateway-stack
  TREG_COMPOSE_FILE         Default: $TREG_STACK_DIR/docker-compose.yml
  TREG_BACKUP_DIR           Default: $TREG_STACK_DIR/backup/treg
  TREG_DEPLOY_STATE_DIR     Default: /var/lib/treg-registry-deploy
  TREG_HEALTH_URL           Default: https://treg.jmsu.top/meta
  TREG_HEALTH_ATTEMPTS      Default: 36
  TREG_HEALTH_INTERVAL_SECONDS  Default: 5
EOF
}

dry_run=0
if [ "${1:-}" = --dry-run ]; then
  dry_run=1
  shift
fi

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
digest=$1
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "invalid image digest: $digest" >&2
  exit 2
}
image=${TREG_REGISTRY_IMAGE:-}
[ -n "$image" ] || { echo 'TREG_REGISTRY_IMAGE is required' >&2; exit 2; }
[[ "$image" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$ ]] || {
  echo "TREG_REGISTRY_IMAGE must be a lowercase, untagged registry image: $image" >&2
  exit 2
}

stack_dir=${TREG_STACK_DIR:-/opt/gateway-stack}
compose_file=${TREG_COMPOSE_FILE:-$stack_dir/docker-compose.yml}
backup_dir=${TREG_BACKUP_DIR:-$stack_dir/backup/treg}
state_dir=${TREG_DEPLOY_STATE_DIR:-/var/lib/treg-registry-deploy}
health_url=${TREG_HEALTH_URL:-https://treg.jmsu.top/meta}
attempts=${TREG_HEALTH_ATTEMPTS:-36}
interval=${TREG_HEALTH_INTERVAL_SECONDS:-5}
lock_file=${TREG_DEPLOY_LOCK_FILE:-/run/lock/treg-registry-deploy.lock}

case "$attempts" in *[!0-9]*|'') echo 'TREG_HEALTH_ATTEMPTS must be an integer' >&2; exit 2 ;; esac
case "$interval" in *[!0-9]*|'') echo 'TREG_HEALTH_INTERVAL_SECONDS must be an integer' >&2; exit 2 ;; esac
[ "$attempts" -gt 0 ] || { echo 'TREG_HEALTH_ATTEMPTS must be greater than zero' >&2; exit 2; }
[ -d "$stack_dir" ] || { echo "stack directory not found: $stack_dir" >&2; exit 1; }
[ -f "$compose_file" ] || { echo "compose file not found: $compose_file" >&2; exit 1; }

compose=(docker compose -f "$compose_file")
remote_ref="$image@$digest"
local_current=gateway-stack/treg:current
local_rollback=gateway-stack/treg:rollback

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' treg 2>/dev/null || true
}

wait_for_service() {
  local remaining=$attempts status
  while [ "$remaining" -gt 0 ]; do
    status=$(container_health)
    if [ "$status" = healthy ] && curl --fail --silent --show-error --max-time 8 "$health_url" >/dev/null; then
      return 0
    fi
    if [ "$status" = exited ] || [ "$status" = dead ]; then
      return 1
    fi
    remaining=$((remaining - 1))
    [ "$remaining" -gt 0 ] && sleep "$interval"
  done
  return 1
}

current_health=$(container_health)
[ "$current_health" = healthy ] || {
  echo "refusing deployment because current treg is not healthy: ${current_health:-unknown}" >&2
  exit 1
}

if [ "$dry_run" -eq 1 ]; then
  printf 'dry-run: would deploy %s\n' "$remote_ref"
  printf 'dry-run: stack=%s backup_dir=%s health_url=%s\n' "$stack_dir" "$backup_dir" "$health_url"
  exit 0
fi

[ "${TREG_DEPLOY_CONFIRMED:-0}" = 1 ] || {
  echo 'set TREG_DEPLOY_CONFIRMED=1 after reviewing the digest and rollback path' >&2
  exit 2
}

mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { echo 'another Treg registry deployment is running' >&2; exit 3; }

umask 077
mkdir -p "$backup_dir" "$state_dir"

echo "pulling immutable candidate: $remote_ref"
docker pull "$remote_ref"

remote_arch=$(docker image inspect --format '{{.Architecture}}' "$remote_ref")
remote_os=$(docker image inspect --format '{{.Os}}' "$remote_ref")
remote_revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$remote_ref")
[ "$remote_arch" = amd64 ] || { echo "unexpected image architecture: $remote_arch" >&2; exit 1; }
[ "$remote_os" = linux ] || { echo "unexpected image OS: $remote_os" >&2; exit 1; }
[[ "$remote_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'candidate is missing a full upstream revision label' >&2
  exit 1
}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
short_digest=${digest#sha256:}
short_digest=${short_digest:0:12}
dump_file="$backup_dir/treg-$stamp-before-$short_digest.dump"
dump_tmp="$dump_file.partial.$$"
trap 'rm -f -- "$dump_tmp"' EXIT

echo "creating PostgreSQL rollback dump: $dump_file"
"${compose[@]}" exec -T treg-db pg_dump -U treg -d treg -Fc >"$dump_tmp"
[ -s "$dump_tmp" ] || { echo 'PostgreSQL dump is empty' >&2; exit 1; }
"${compose[@]}" exec -T treg-db pg_restore --list <"$dump_tmp" >/dev/null
chmod 600 "$dump_tmp"
mv "$dump_tmp" "$dump_file"
trap - EXIT

docker image inspect "$local_current" >/dev/null
docker image tag "$local_current" "$local_rollback"
docker image tag "$remote_ref" "$local_current"

echo "recreating treg from $remote_ref"
if "${compose[@]}" up -d --no-deps --force-recreate treg && wait_for_service; then
  state_tmp="$state_dir/last-successful-digest.partial.$$"
  printf '%s\n' "$digest" >"$state_tmp"
  chmod 600 "$state_tmp"
  mv "$state_tmp" "$state_dir/last-successful-digest"
  printf 'deployment healthy: revision=%s digest=%s backup=%s\n' "$remote_revision" "$digest" "$dump_file"
  exit 0
fi

echo 'candidate failed health checks; restoring rollback image' >&2
docker image tag "$local_rollback" "$local_current"
if "${compose[@]}" up -d --no-deps --force-recreate treg && wait_for_service; then
  echo "rollback healthy; failed digest=$digest backup=$dump_file" >&2
  exit 1
fi

echo "rollback also failed; manual recovery required; backup=$dump_file" >&2
exit 2
