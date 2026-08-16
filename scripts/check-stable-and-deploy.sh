#!/usr/bin/env bash
set -euo pipefail

image=${TREG_REGISTRY_IMAGE:-}
[ -n "$image" ] || { echo 'TREG_REGISTRY_IMAGE is required' >&2; exit 2; }
state_dir=${TREG_DEPLOY_STATE_DIR:-/var/lib/treg-registry-deploy}
state_file="$state_dir/last-successful-digest"

[ -s "$state_file" ] || {
  echo "no successful deployment state exists at $state_file; perform the first digest deployment manually" >&2
  exit 3
}

inspection=$(docker buildx imagetools inspect "$image:stable")
stable_digest=$(printf '%s\n' "$inspection" | awk '/^Digest:/ {print $2; exit}')
[[ "$stable_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo 'unable to resolve the stable image digest' >&2
  exit 1
}

deployed_digest=$(tr -d '\r\n' <"$state_file")
if [ "$stable_digest" = "$deployed_digest" ]; then
  echo "stable digest already deployed: $stable_digest"
  exit 0
fi

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
TREG_DEPLOY_CONFIRMED=1 exec "$script_dir/deploy-digest.sh" "$stable_digest"
