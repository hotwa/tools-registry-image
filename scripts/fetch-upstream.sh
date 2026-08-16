#!/usr/bin/env bash
set -euo pipefail

repo=${UPSTREAM_REPOSITORY:-https://github.com/superdesigndev/tools-registry.git}
ref=${1:-${UPSTREAM_DEFAULT_REF:-main}}
destination=${2:-upstream}

case "$ref" in
  *[!A-Za-z0-9._/-]*|'')
    echo "invalid upstream ref: $ref" >&2
    exit 2
    ;;
esac

case "$destination" in
  upstream|*/upstream) ;;
  *)
    echo "destination must be named upstream: $destination" >&2
    exit 2
    ;;
esac

if [ -e "$destination" ]; then
  echo "destination already exists: $destination" >&2
  exit 2
fi

git init --quiet "$destination"
git -C "$destination" remote add origin "$repo"
git -C "$destination" fetch --quiet --depth=1 origin "$ref"
git -C "$destination" checkout --quiet --detach FETCH_HEAD

revision=$(git -C "$destination" rev-parse HEAD)
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "resolved revision is not a full SHA: $revision" >&2
  exit 1
}
printf '%s\n' "$revision"
